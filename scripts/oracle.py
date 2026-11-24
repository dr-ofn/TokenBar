#!/usr/bin/env python3
"""Independent reference implementation used to cross-check TokenBar totals.

Counts every model call the harnesses on this Mac logged, sharing no code with the
Swift scanners:

    scripts/oracle.py [window]        window: 1h 5h 24h 7d 30d all (default 24h)

Tools: the built-in ones below plus whatever `$HOME/.config/tokenbar/custom-sources.json` names
(families open-design-events and opencode-sqlite here). `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `XDG_DATA_HOME` and `QWEN_HOME` move the
built-in tools, but only for the real home: a synthetic `$HOME` ignores them, as the scanner does.

Prints JSON: {"window", "total", "calls", "harnesses": {harness: {"total", "calls",
"models": {provider/model: [total, calls, input, cacheRead, cacheWrite, output,
reasoning]}}}, "cost": USD, "unpriced": [models]}. A repeated key keeps the row with
the largest token total, as the SQLite store does. `$HOME` selects the tree, so a
synthetic one can be counted too. Prices follow scripts/pricelib.py (embedded snapshot, scripts/prices.json,
the user's alias file unless TOKENBAR_PRICES_PINNED=1).
"""
import glob, hashlib, json, os, pwd, re, sqlite3, subprocess, sys, time
from datetime import datetime
import oracle_db
import oracle_g3

import oracle_g1

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import oracle_g2

FUTURE_SLACK_SECONDS = 86400
WINDOW_SECONDS = {"1h": 3600, "5h": 5 * 3600, "24h": 24 * 3600,
                  "7d": 7 * 24 * 3600, "30d": 30 * 24 * 3600, "all": None}
HOME = os.path.expanduser("~")
HARNESS = {"cc": "claude-code", "cx": "codex", "oc": "opencode", "omp": "oh-my-pi", "qwen": "qwen-code",
           "kimi": "kimi-code", "devin": "devin", "ag": "antigravity"}
HARNESS.update(oracle_g3.HARNESS)
HARNESS.update(oracle_g2.HARNESS)
ENV = os.environ if os.path.realpath(HOME) == os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir) else {}


def root(default, env=None, below=""):
    """A built-in tool's folder: the variable's value when set, else the default under HOME."""
    base = ENV.get(env) if env else None
    base = (HOME + "/" + base[2:] if base.startswith("~/") else base) if base else HOME + "/" + default
    return base.rstrip("/") + ("/" + below if below else "")


def expand(path):
    return HOME + "/" + path[2:] if path.startswith("~/") else path


def custom_sources():
    """The user's entries as {id, family, paths, prefix, recursive}; a bad file or entry counts nothing."""
    try:
        entries = json.load(open(HOME + "/.config/tokenbar/custom-sources.json", encoding="utf-8"))["sources"]
    except (OSError, ValueError, KeyError, TypeError):
        return []
    out = []
    for e in entries if isinstance(entries, list) else []:
        if not isinstance(e, dict) or not isinstance(e.get("paths"), list) or not e["paths"]:
            continue
        if e.get("family") not in ("open-design-events", "opencode-sqlite") or not e.get("id"):
            continue
        out.append({"id": e["id"], "family": e["family"], "paths": [expand(p) for p in e["paths"]],
                    "prefix": e.get("keyPrefix") or str(e["id"]).lower(), "recursive": e.get("recursive", True)})
    return out


CUSTOM = custom_sources()
HARNESS.update(oracle_g1.HARNESS)
for _entry in CUSTOM:
    HARNESS.setdefault(_entry["prefix"], _entry["id"])


def epoch(value):
    if isinstance(value, (int, float)):
        return value / 1000 if value > 1e11 else float(value)
    if not value:
        return 0.0
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


def num(d, key):
    v = d.get(key) if isinstance(d, dict) else 0
    return int(v) if isinstance(v, (int, float)) else 0


best = {}
claude_session = {}
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pricelib  # the Python twin of the Swift price rules (ModelNames, PriceResolver)

# TOKENBAR_PRICES_PINNED=1: embedded snapshot + hand-made tables only, no alias file (what check.sh and TokenChecks use).
_aliases, _local = ({}, []) if os.environ.get("TOKENBAR_PRICES_PINNED") == "1" else \
    pricelib.load_aliases(HOME + "/.config/tokenbar/model-aliases.json")
PRICER = pricelib.shipped_pricer(_aliases, _local)
_entries = {}


def entry_for(provider_model):
    """The price row of "provider/model", or None."""
    if provider_model not in _entries:
        provider, _, model = provider_model.partition("/")
        _entries[provider_model] = PRICER.resolve(provider, model)
    return _entries[provider_model]


def call_cost(model, counts, cw1h, tiered=True):
    """USD of one call; None when the model has no price. A summed row has no tier."""
    entry = entry_for(model)
    if entry is None:
        return None
    inp, cr, cw, out, _ = counts
    prompt = inp + cr + cw
    rate = entry
    for tier in entry["tiers"] if tiered else []:
        if prompt >= tier["minPrompt"]:
            rate = tier
    return (inp * rate["input"] + cr * rate["cacheRead"] + (cw - cw1h) * rate["cacheWrite"]
            + cw1h * rate["cacheWrite1h"] + out * rate["output"]) / 1_000_000


def real_key(key):
    """The key a REAL call is stored under. Adjustment rows are `<prefix>:adj:...`; a call whose own id (a Claude message.id,
    a Cline task id ...) is exactly `adj` is written `<prefix>:adj#gercek...` so it is not taken for one (the app does the same)."""
    head, sep, rest = key.partition(":")
    second, sep2, tail = rest.partition(":")
    return f"{head}:adj#gercek{sep2}{tail}" if sep and second == "adj" else key


def add(key, ts, provider, model, inp, cr, cw, out, rz, cw1h=0, adjustment=False):
    if inp + cr + cw + out == 0:
        return
    if not adjustment:
        key = real_key(key)
    counts = (inp, cr, cw, out, rz, cw1h)
    old = best.get(key)
    if old is None or sum(counts[:4]) > sum(old[2][:4]):
        best[key] = (ts, f"{provider}/{model}", counts)


def lines_of(path):
    """Decoded JSON objects of a .jsonl or .jsonl.zst file."""
    if path.endswith(".zst"):
        try:
            proc = subprocess.run(["zstd", "-dc", "--", path], capture_output=True)
        except OSError:
            return  # no zstd on this machine: the archive is left unread, as the app leaves it
        raw = proc.stdout.decode("utf-8", "replace").split("\n")
    else:
        raw = open(path, encoding="utf-8", errors="replace")
    for line in raw:
        yield line


def base_model(raw):
    """The model without Claude Code's context-window suffix, as `claude-opus-5-5[1m]`."""
    return raw.split("[")[0] or raw


def claude():
    records = {}
    for path in oracle_g1.claude_files(sys.modules[__name__]):
        for line in lines_of(path):
            if line.startswith('{"type":"cost-state"'):
                note_cost_state(line, records)
                continue
            if '"usage"' not in line or '"assistant"' not in line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            m = o.get("message")
            if o.get("type") != "assistant" or not isinstance(m, dict) or not isinstance(m.get("usage"), dict):
                continue
            model = base_model(m.get("model") or "unknown")
            if model == "<synthetic>":
                continue
            u = m["usage"]
            ts = epoch(o.get("timestamp"))
            if not ts:
                continue
            provider = "anthropic" if model.startswith("claude") else "custom"
            mid = m.get("id") or o.get("uuid") or hashlib.sha1(line.encode()).hexdigest()
            key = f"cc:{mid}:{o.get('requestId') or ''}"

            def emit(k, md, usage):
                details = usage.get("output_tokens_details") or {}
                claude_session[real_key(k)] = o.get("sessionId") or ""
                add(k, ts, "anthropic" if md.startswith("claude") else "custom", md,
                    num(usage, "input_tokens"), num(usage, "cache_read_input_tokens"),
                    num(usage, "cache_creation_input_tokens"), num(usage, "output_tokens"),
                    min(num(details, "thinking_tokens"), num(usage, "output_tokens")),
                    num(usage.get("cache_creation") or {}, "ephemeral_1h_input_tokens"))

            emit(key, model, u)
            for i, it in enumerate(u.get("iterations") or []):
                kind = it.get("type") or "message"
                if kind != "message":
                    emit(f"{key}:{kind}:{i}", base_model(it.get("model") or model), it)


    claude_gaps(records)


def note_cost_state(line, records):
    """Each record is cumulative for its run: per category the largest value stands."""
    try:
        o = json.loads(line)
    except ValueError:
        return
    for raw, u in (o.get("modelUsage") or {}).items():
        # The spelling stays as logged here: `m[1m]` and `m` are two counters of one run. They are folded below.
        key = (o.get("sessionId"), epoch(o.get("startTime")), raw)
        new = [num(u, "inputTokens"), num(u, "cacheReadInputTokens"), num(u, "cacheCreationInputTokens"), num(u, "outputTokens")]
        records[key] = [max(a, b) for a, b in zip(records.get(key, [0, 0, 0, 0]), new)]


def claude_gaps(records):
    """What a session's own record holds beyond its transcript rows, dated at its latest run."""
    sums = {}
    for key, (ts, model, counts) in best.items():
        if key.startswith("cc:"):
            s = sums.setdefault((claude_session[key], model.split("/", 1)[1]), [0, 0, 0, 0])
            for i in range(4):
                s[i] += counts[i]
    totals, last = {}, {}
    for (session, started, raw), values in records.items():
        t = totals.setdefault((session, base_model(raw)), [0, 0, 0, 0])
        for i in range(4):
            t[i] += values[i]
        last[session] = max(last.get(session, 0), started)
    for (session, model), t in totals.items():
        seen = sums.get((session, model), [0, 0, 0, 0])
        gap = [max(0, a - b) for a, b in zip(t, seen)]
        add(f"cc:adj:{session}:{model}", int(last[session]), "anthropic" if model.startswith("claude") else "custom",
            model, gap[0], gap[1], gap[2], gap[3], 0, adjustment=True)


def codex():
    home = root(".codex", "CODEX_HOME")
    names = glob.glob(home + "/sessions/**/rollout-*.jsonl", recursive=True)
    names += glob.glob(home + "/sessions/**/rollout-*.jsonl.zst", recursive=True)
    names += glob.glob(home + "/archived_sessions/**/rollout-*.jsonl*", recursive=True)
    for path in names:
        session, provider, model, first_model, cwd, started, last, turn, reset = None, "openai", None, None, None, None, None, None, 0
        pending = []
        for line in lines_of(path):
            if not any(t in line for t in ('"session_meta"', '"turn_context"', '"task_started"', '"token_count"')):
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            p = o.get("payload")
            if not isinstance(p, dict):
                continue
            kind = o.get("type")
            if kind == "session_meta" and session is None:
                session = p.get("id") or p.get("session_id")
                provider = p.get("model_provider") or "openai"
                started = epoch(p.get("timestamp") or o.get("timestamp")) or None
            elif kind == "turn_context":
                if p.get("model"):
                    model = p["model"]
                    first_model = first_model or model
            elif kind == "event_msg" and p.get("type") == "task_started":
                if isinstance(p.get("started_at"), (int, float)):
                    turn = epoch(p["started_at"])
            elif kind == "event_msg" and p.get("type") == "token_count":
                info = p.get("info")
                if not isinstance(info, dict) or not isinstance(info.get("total_token_usage"), dict):
                    continue
                total = info["total_token_usage"]
                t = num(total, "total_tokens") or num(total, "input_tokens") + num(total, "output_tokens")
                if t <= 0:
                    continue
                ts = max(epoch(o.get("timestamp")), turn or 0)
                if started and ts < started - 1:
                    last = total
                    continue
                if last is None:
                    delta = total
                else:
                    lt = num(last, "total_tokens") or num(last, "input_tokens") + num(last, "output_tokens")
                    if t == lt:
                        continue
                    if t > lt:
                        delta = {k: max(0, num(total, k) - num(last, k)) for k in
                                 ("input_tokens", "cached_input_tokens", "cache_write_input_tokens",
                                  "output_tokens", "reasoning_output_tokens")}
                    else:
                        reset += 1
                        lu = info.get("last_token_usage")
                        delta = lu if isinstance(lu, dict) else total
                last = total
                sid = session or os.path.basename(path).split(".")[0]
                pending.append((f"cx:{sid}{f':e{reset}' if reset else ''}:{t}", ts, delta, model))
        for key, ts, d, md in pending:
            inp = num(d, "input_tokens")
            cached = min(num(d, "cached_input_tokens"), inp)
            writes = min(num(d, "cache_write_input_tokens"), max(0, inp - cached))
            out = num(d, "output_tokens")
            # usage logged before the first turn_context belongs to the first model named, not the last
            add(key, ts, provider, md or first_model or "unknown", max(0, inp - cached - writes), cached, writes, out,
                min(num(d, "reasoning_output_tokens"), out))


def opencode(db, prefix):
    try:
        with oracle_db.readonly(db) as con:
            rows = con.execute("select id, data from message").fetchall()
    except sqlite3.Error:
        return
    for mid, data in rows:
        try:
            m = json.loads(data)
        except ValueError:
            continue
        if m.get("role") != "assistant" or not m.get("providerID") or not m.get("modelID"):
            continue
        t = m.get("tokens") or {}
        c = t.get("cache") or {}
        add(f"{prefix}:{mid}", epoch((m.get("time") or {}).get("created")), m["providerID"], m["modelID"],
            num(t, "input"), num(c, "read"), num(c, "write"), num(t, "output") + num(t, "reasoning"), num(t, "reasoning"))


def open_design(folder, prefix):
    for path in glob.iglob(folder + "/**/events.jsonl", recursive=True):
        model = "unknown"
        for line in open(path, encoding="utf-8", errors="replace"):
            try:
                o = json.loads(line)
            except ValueError:
                continue
            d = o.get("data")
            if not isinstance(d, dict):
                continue
            if d.get("type") == "status" and d.get("model"):
                model = d["model"]
            elif d.get("type") == "request_usage" and d.get("requestId") and isinstance(d.get("usage"), dict):
                u = d["usage"]
                add(f"{prefix}:{d['requestId']}", epoch(o.get("timestamp")), "anthropic", model, num(u, "input_tokens"),
                    num(u, "cache_read_input_tokens"), num(u, "cache_creation_input_tokens"), num(u, "output_tokens"), 0)


def omp_whole(u, key):
    """A whole number; a decimal value is a cost field, never a token count (the Swift reader skips it)."""
    v = u.get(key)
    return v if isinstance(v, int) and not isinstance(v, bool) and v > 0 else 0


def omp_session(path, lines):
    """The id in the file's session header (its first non-blank line; whatever the spacing or key order), else the
    part of its name after the last `_`."""
    for line in lines:
        if not line.strip():
            continue
        try:
            o = json.loads(line)
        except ValueError:
            o = None
        if isinstance(o, dict) and o.get("type") == "session" and isinstance(o.get("id"), str) and o["id"]:
            return o["id"]
        break
    return os.path.splitext(os.path.basename(path))[0].rsplit("_", 1)[-1]


def omp():
    for path in glob.iglob(HOME + "/.omp/agent/sessions/**/*.jsonl", recursive=True):
        # (utf-8-sig: a BOM at the very start of the file is no content)
        all_lines = [ln.rstrip("\r\n") for ln in open(path, encoding="utf-8-sig", errors="replace")]
        session = omp_session(path, all_lines)
        for line in all_lines:
            # (the fields are read from the parsed message: spacing is free, and a "model" or "role" inside the content
            # is not the message's own)
            if '"usage"' not in line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if not isinstance(o, dict):
                continue
            m = o.get("message") if isinstance(o.get("message"), dict) else o
            # a `task` result repeats its subagents' usage; their own transcripts already count it
            if m.get("role") == "toolResult" or o.get("role") == "toolResult":
                continue
            u = m.get("usage")
            if not isinstance(u, dict):
                continue
            provider, model = m.get("provider") or "", m.get("model") or "unknown"
            if "/" in model:
                head, tail = model.split("/", 1)
                if not provider or head == provider:
                    provider, model = head, tail
            rid = m.get("responseId")
            key = f"omp:{rid}" if rid else f"omp:{session}:" + hashlib.sha1(line.encode()).hexdigest()
            add(key, epoch(o.get("timestamp", m.get("timestamp"))), provider, model, omp_whole(u, "input"),
                omp_whole(u, "cacheRead"), omp_whole(u, "cacheWrite"), omp_whole(u, "output"), omp_whole(u, "reasoningTokens"))


def qwen():
    """Per-call lines, plus what a session's cumulative summary holds beyond them."""
    seen = {}
    home = root(".qwen", "QWEN_HOME")
    for path in glob.iglob(home + "/usage/token-usage-*.jsonl"):
        for line in open(path, encoding="utf-8", errors="replace"):
            try:
                o = json.loads(line)
            except ValueError:
                continue
            inp, cached = num(o, "inputTokens"), num(o, "cachedTokens")
            model = o.get("model") or "unknown"
            auth = o.get("authType") or "qwen"
            add(f"qwen:{o.get('id')}", epoch(o.get("timestamp")), auth, model,
                max(0, inp - cached), min(cached, inp), 0, num(o, "outputTokens"), num(o, "thoughtsTokens"))
            s = seen.setdefault((o.get("sessionId"), model), [0, 0, 0, 0, auth])
            s[0] += inp
            s[1] += cached
            s[2] += num(o, "outputTokens")
            s[3] += num(o, "thoughtsTokens")
    path = home + "/usage_record.jsonl"
    if not os.path.exists(path):
        return
    latest = {}
    for line in open(path, encoding="utf-8", errors="replace"):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        for model, m in (r.get("models") or {}).items():
            key = (r.get("sessionId"), model)
            if key not in latest or num(m, "totalTokens") >= num(latest[key][0], "totalTokens"):
                latest[key] = (m, r.get("timestamp"))
    for (session, model), (m, ts) in latest.items():
        s = seen.get((session, model), [0, 0, 0, 0, "qwen"])
        inp = max(0, num(m, "inputTokens") - s[0])
        cached = max(0, num(m, "cachedTokens") - s[1])
        add(f"qwen:adj:{session}:{model}", epoch(ts), s[4], model, max(0, inp - cached), min(cached, inp), 0,
            max(0, num(m, "outputTokens") - s[2]), max(0, num(m, "thoughtsTokens") - s[3]), adjustment=True)


def kimi():
    for path in glob.iglob(HOME + "/.kimi-code/sessions/*/*/agents/*/wire.jsonl"):
        session = path.split("/sessions/")[1].split("/")[1]
        model = "unknown"
        for line in open(path, encoding="utf-8", errors="replace"):
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if o.get("type") == "llm.request":
                model = o.get("modelAlias") or o.get("model") or model
                continue
            e = o.get("event")
            if not isinstance(e, dict) or e.get("type") != "step.end" or not isinstance(e.get("usage"), dict):
                continue
            u = e["usage"]
            provider, name = model.split("/", 1) if "/" in model else ("", model)
            ident = e.get("messageId") or e.get("uuid") or hashlib.sha1(line.encode()).hexdigest()
            add(f"kimi:{session}:{ident}", epoch(o.get("time")), provider, name, num(u, "inputOther"),
                num(u, "inputCacheRead"), num(u, "inputCacheCreation"), num(u, "output"), 0)


def devin():
    for path in glob.iglob(HOME + "/.local/share/devin/cli/transcripts/*.json"):
        o = json.load(open(path, encoding="utf-8"))
        session = o.get("session_id") or os.path.basename(path)[:-5]
        agent = (o.get("agent") or {}).get("model_name")
        for s in o.get("steps") or []:
            m = s.get("metrics")
            if not isinstance(m, dict):
                continue
            prompt, cached = num(m, "prompt_tokens"), num(m, "cached_tokens")
            # a transcript without step ids keys its steps by their timestamp (two steps must not share a key)
            step = num(s, "step_id")
            stamp = s.get("timestamp")
            step_key = str(step) if step else (stamp if isinstance(stamp, str) and stamp else str(epoch(stamp)))
            add(f"devin:{session}:{step_key}", epoch(s.get("timestamp")), "devin",
                s.get("model_name") or agent or "unknown", max(0, prompt - cached), min(cached, prompt), 0,
                num(m, "completion_tokens"), 0)


def proto(data):
    """{field: first value} of one protobuf message: varints as int, bytes as bytes."""
    out, i = {}, 0

    def varint(i):
        r, s = 0, 0
        while True:
            b = data[i]
            i += 1
            r |= (b & 0x7F) << s
            if b < 0x80:
                return r, i
            s += 7

    try:
        while i < len(data):
            key, i = varint(i)
            field, wire = key >> 3, key & 7
            if wire == 0:
                v, i = varint(i)
            elif wire == 2:
                n, i = varint(i)
                v, i = data[i:i + n], i + n
            elif wire == 1:
                v, i = None, i + 8
            elif wire == 5:
                v, i = None, i + 4
            else:
                return out
            out.setdefault(field, v)
    except IndexError:
        pass
    return out


def antigravity():
    for path in glob.iglob(HOME + "/.gemini/antigravity-cli/conversations/*.db"):
        conversation = os.path.basename(path)[:-3]
        try:
            con = sqlite3.connect(f"file:{path}?immutable=1", uri=True)
            # `gen_metadata` names the models: the enum at 1.3, the name at 1.19. A step carries only the enum.
            names = {}
            for (blob,) in con.execute("select data from gen_metadata order by idx"):
                inner = proto(blob).get(1)
                f = proto(inner) if isinstance(inner, bytes) else {}
                if isinstance(f.get(3), int) and isinstance(f.get(19), bytes) and f[19]:
                    names[f[3]] = f[19].decode("utf-8", "replace")
            steps = con.execute("select idx, metadata from steps where step_type = 15 order by idx").fetchall()
            con.close()
        except sqlite3.Error:
            continue
        rows = []
        refused = False
        for idx, meta in steps:
            top = proto(meta)
            u = top.get(9)
            if not isinstance(u, bytes):
                continue
            f = proto(u)
            if any(isinstance(f.get(n), int) and f[n] >= 1 << 40 for n in (2, 3, 4, 5, 9)):
                refused = True        # the fields moved: the whole file is refused, as the Swift reader does
                break
            enum = f.get(1, 0)
            name = names.get(enum) or f"antigravity-model-{enum}"
            ts = 0.0
            for field in (8, 7, 1):
                stamp = top.get(field)
                seconds = proto(stamp).get(1) if isinstance(stamp, bytes) else None
                if seconds and seconds > 1_000_000_000:
                    ts = float(seconds)
                    break
            rows.append((f"ag:{conversation}:{idx}", ts, name, f.get(2, 0), f.get(5, 0), f.get(4, 0), f.get(3, 0), f.get(9, 0)))
        if refused:
            continue
        for key, ts, name, inp, cr, cw, out, rz in rows:
            add(key, ts, "google-antigravity", name, inp, cr, cw, out, rz)


def main():
    window = sys.argv[1] if len(sys.argv) > 1 else "24h"
    if window not in WINDOW_SECONDS:
        sys.exit(f"unknown window: {window}")
    span = WINDOW_SECONDS[window]
    now = time.time()
    cutoff = now - span if span else None
    # A bounded window counts up to a day past now (a clock a little fast), never a call dated years ahead; `all` counts every call.
    # The same rule as UsageBook.futureSlackSeconds (Swift) and the Windows store.
    ceiling = now + FUTURE_SLACK_SECONDS if span else None

    claude()
    codex()
    opencode(root(".local/share", "XDG_DATA_HOME", "opencode") + "/opencode.db", "oc")
    omp()
    qwen()
    kimi()
    devin()
    antigravity()
    oracle_g3.collect(add, ENV, HOME, epoch, num)
    oracle_g1.run(sys.modules[__name__])
    oracle_g2.collect(add, opencode, root, HOME, epoch, num)
    for entry in CUSTOM:
        for path in entry["paths"]:
            if entry["family"] == "open-design-events":
                open_design(path, entry["prefix"])
            elif os.path.isfile(path):
                opencode(path, entry["prefix"])
            elif os.path.isdir(path):
                found = [path + "/opencode.db"] if os.path.isfile(path + "/opencode.db") else []
                if entry["recursive"]:
                    found += [db for db in glob.glob(path + "/**/opencode*.db", recursive=True)
                              if "/data/opencode/" in db and db not in found]
                for db in found:
                    opencode(db, entry["prefix"])

    harnesses, total, calls, cost, unpriced = {}, 0, 0, 0.0, set()
    for key, (ts, model, counts) in best.items():
        if cutoff is not None and not cutoff <= ts <= ceiling:
            continue
        t = sum(counts[:4])
        adjustment = key.split(":")[1] == "adj"
        price = call_cost(model, counts[:5], counts[5], not adjustment)
        if price is None:
            unpriced.add(model)
        else:
            cost += price
        h = harnesses.setdefault(HARNESS.get(key.split(":", 1)[0], key.split(":", 1)[0]), {"total": 0, "calls": 0, "models": {}})
        m = h["models"].setdefault(model, [0, 0, 0, 0, 0, 0, 0])
        m[0] += t
        m[1] += 0 if adjustment else 1
        for i in range(5):
            m[2 + i] += counts[i]
        h["total"] += t
        h["calls"] += 0 if adjustment else 1
        total += t
        calls += 0 if adjustment else 1
    print(json.dumps({"window": window, "total": total, "calls": calls, "cost": round(cost, 6),
                      "unpriced": sorted(unpriced), "harnesses": harnesses}, indent=1, sort_keys=True))


if __name__ == "__main__":
    main()
