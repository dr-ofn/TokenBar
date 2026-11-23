"""Independent counting of the G3 tools for scripts/oracle.py: Crush, Goose, Factory Droid, Amp,
OpenHands and the Devin CLI's sessions.db. Shares no code with the Swift scanners.

`collect(add, env, home, root, epoch, num)` reports every call through oracle.py's `add`. The
tools that log no token counts here (Warp, Amazon Q) report nothing.
"""
import glob, json, os, re, sqlite3

import oracle_db

HARNESS = {"crush": "crush", "goose": "goose", "droid": "factory-droid", "amp": "amp", "oh": "openhands"}


def _folder(env, home, name, default, below=""):
    base = env.get(name) if name else None
    base = (home + "/" + base[2:] if base.startswith("~/") else base) if base else home + "/" + default
    return base.rstrip("/") + ("/" + below if below else "")


def _rows(path, sql, args=()):
    """Rows of a database opened read-only; a file that is no database has none."""
    try:
        with oracle_db.readonly(path) as con:
            return con.execute(sql, args).fetchall()
    except sqlite3.Error:
        return []


def _columns(path, table):
    return {r[1] for r in _rows(path, "PRAGMA table_info(" + table + ")")}


def _seen_once(paths):
    seen, out = set(), []
    for p in paths:
        if os.path.isfile(p) and os.path.realpath(p) not in seen:
            seen.add(os.path.realpath(p))
            out.append(p)
    return out


def _when(value, epoch):
    """Seconds from a number, an ISO string, or a number written as text."""
    try:
        return epoch(float(value))
    except (TypeError, ValueError):
        # SQLite's CURRENT_TIMESTAMP has no zone and means UTC.
        if isinstance(value, str) and re.fullmatch(r"\d{4}-\d\d-\d\d[ T]\d\d:\d\d:\d\d", value):
            value += "+00:00"
        return epoch(value)


def crush(add, env, home, epoch):
    roots = [_folder(env, home, "XDG_DATA_HOME", ".local/share", "crush"),
             _folder(env, home, "CRUSH_GLOBAL_DATA", ".local/share/crush")]
    dbs = []
    for r in roots:
        try:
            projects = json.load(open(r + "/projects.json", encoding="utf-8"))["projects"]
        except (OSError, ValueError, KeyError, TypeError):
            continue
        for p in projects if isinstance(projects, list) else []:
            if isinstance(p, dict) and p.get("data_dir"):
                d = p["data_dir"]
                dbs.append(d if d.startswith("/") else (p.get("path") or "") + "/" + d)
    for db in _seen_once([d + "/crush.db" for d in dbs]):
        has_provider = "provider" in _columns(db, "messages")
        for sid, prompt, completion, updated, created in _rows(
                db, "select id, prompt_tokens, completion_tokens, updated_at, created_at from sessions "
                    "where prompt_tokens > 0 or completion_tokens > 0"):
            latest = _rows(db, "select model" + (", provider" if has_provider else ", null") +
                               " from messages where session_id = ? and role = 'assistant' "
                               "and model is not null and model != '' order by created_at desc, rowid desc limit 1", (sid,))
            model, provider = (latest[0] if latest else (None, None))
            add("crush:" + sid, epoch(updated or created), provider or "crush", model or "unknown",
                prompt, 0, 0, completion, 0)


def goose(add, env, home, epoch):
    roots = [home + "/.local/share/goose/sessions", home + "/Library/Application Support/goose/sessions",
             home + "/.local/share/Block/goose/sessions", home + "/Library/Application Support/Block/goose/sessions",
             _folder(env, home, "GOOSE_PATH_ROOT", ".local/share/goose")]
    candidates = []
    for r in roots:
        candidates += [r, r + "/sessions.db", r + "/sessions/sessions.db", r + "/data/sessions/sessions.db"]
    for db in _seen_once(candidates):
        have = _columns(db, "sessions")
        want = ["id", "model_config_json", "provider_name", "updated_at", "created_at",
                "accumulated_input_tokens", "accumulated_output_tokens", "accumulated_cache_read_tokens",
                "accumulated_cache_write_tokens", "input_tokens", "output_tokens", "cache_read_tokens",
                "cache_write_tokens"]
        for row in _rows(db, "select " + ", ".join(c if c in have else "null" for c in want) + " from sessions"):
            sid, config, provider, updated, created = row[:5]
            acc, plain = row[5:9], row[9:13]
            use = acc if (acc[0] is not None or acc[1] is not None) else plain
            inp, out, cr, cw = [max(0, v or 0) for v in use]
            cr = min(cr, inp)
            cw = min(cw, inp - cr)
            try:
                model = (json.loads(config)["model_name"] or "").strip() or "unknown"
            except (ValueError, KeyError, TypeError, AttributeError):
                model = "unknown"
            stamp = _when(updated, epoch)
            add("goose:" + str(sid), stamp or _when(created, epoch), provider or "goose", model, inp - cr - cw, cr, cw, out, 0)


def _droid_model(raw):
    if not isinstance(raw, str) or not raw.strip():
        return "unknown"
    name = raw.strip()
    if name.startswith("custom:"):
        name = name[len("custom:"):]
    name = re.sub(r"\[[^\[\]]*\]", "", name)
    name = name.strip(" -").lower()
    return name or "unknown"


def _droid_provider(locked, model):
    key = (locked or "").lower().replace("-", "_") if isinstance(locked, str) else ""
    table = {"claude": "anthropic", "anthropic": "anthropic", "openai": "openai", "google": "google",
             "google_ai": "google", "gemini": "google", "xai": "xai", "x_ai": "xai", "grok": "xai"}
    if key:
        return table.get(key, key)
    if any(w in model for w in ("claude", "opus", "sonnet", "haiku")):
        return "anthropic"
    if model.startswith("gpt-") or "-gpt-" in model:
        return "openai"
    return "google" if "gemini" in model else "xai" if "grok" in model else "factory"


def droid(add, home, epoch, num):
    for path in sorted(set(glob.glob(home + "/.factory/sessions/**/*.settings.json", recursive=True))):
        try:
            o = json.load(open(path, encoding="utf-8"))
        except (OSError, ValueError):
            continue
        usage = o.get("tokenUsage") if isinstance(o, dict) else None
        if not isinstance(usage, dict):
            continue
        thinking = max(0, num(usage, "thinkingTokens"))
        model = _droid_model(o.get("model"))
        stamp = epoch(o.get("providerLockTimestamp")) if isinstance(o.get("providerLockTimestamp"), str) else 0.0
        add("droid:" + os.path.basename(path)[:-len(".settings.json")], stamp or os.path.getmtime(path),
            _droid_provider(o.get("providerLock"), model), model, max(0, num(usage, "inputTokens")),
            max(0, num(usage, "cacheReadTokens")), max(0, num(usage, "cacheCreationTokens")),
            max(0, num(usage, "outputTokens")) + thinking, thinking)


def _amp_split(inp, out, write, read, total):
    inp, out, write, read = max(0, inp), max(0, out), max(0, write), max(0, read)
    if inp + out == 0 and total > write + read:
        inp = total - write - read
    return inp, read, write, out


def amp(add, env, home, epoch, num):
    base = _folder(env, home, "AMP_DATA_DIR", ".local/share/amp")
    for path in sorted(glob.glob(base + "/threads/**/T-*.json", recursive=True)):
        try:
            o = json.load(open(path, encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(o, dict):
            continue
        thread = o.get("id") if isinstance(o.get("id"), str) and o.get("id") else os.path.basename(path)[:-5]
        messages = [m for m in (o.get("messages") or []) if isinstance(m, dict)]
        mtime = os.path.getmtime(path)

        def mid(v):
            return str(int(v)) if isinstance(v, (int, float)) and not isinstance(v, bool) else (v if isinstance(v, str) and v else None)

        ledger = o.get("usageLedger")
        if isinstance(ledger, dict) and isinstance(ledger.get("events"), list):
            cache = {}
            for m in messages:
                if m.get("role") == "assistant" and mid(m.get("messageId")) and isinstance(m.get("usage"), dict):
                    cache[mid(m["messageId"])] = (num(m["usage"], "cacheCreationInputTokens"), num(m["usage"], "cacheReadInputTokens"))
            for i, e in enumerate(ledger["events"]):
                if not isinstance(e, dict) or not isinstance(e.get("tokens"), dict):
                    continue
                w, r = cache.get(mid(e.get("toMessageId")), (0, 0))
                t = e["tokens"]
                inp, cr, cw, out = _amp_split(num(t, "input"), num(t, "output"), w, r, num(t, "total"))
                add(f"amp:{thread}:{e['id'] if isinstance(e.get('id'), str) and e.get('id') else 'i' + str(i)}",
                    epoch(e.get("timestamp")) or mtime, "amp", e.get("model") or "unknown", inp, cr, cw, out, 0)
        else:
            for i, m in enumerate(messages):
                u = m.get("usage")
                if m.get("role") != "assistant" or not isinstance(u, dict):
                    continue
                inp, cr, cw, out = _amp_split(num(u, "inputTokens"), num(u, "outputTokens"), num(u, "cacheCreationInputTokens"),
                                              num(u, "cacheReadInputTokens"), num(u, "totalTokens"))
                stamp = epoch(u.get("timestamp")) or epoch(m.get("timestamp")) or mtime
                ident = ("m" + mid(m.get("messageId"))) if mid(m.get("messageId")) else "i" + str(i)
                add(f"amp:{thread}:{ident}", stamp, "amp", u.get("model") or m.get("model") or "unknown", inp, cr, cw, out, 0)


def openhands(add, env, home, epoch, num):
    folders = [_folder(env, home, "OPENHANDS_CONVERSATIONS_DIR", ".openhands/conversations"),
               _folder(env, home, "OPENHANDS_PERSISTENCE_DIR", ".openhands", "conversations")]
    states = []
    for f in folders:
        states += sorted(glob.glob(f + "/*/base_state.json"))
    for path in _seen_once(states):
        try:
            o = json.load(open(path, encoding="utf-8"))
            metrics = o["stats"]["usage_to_metrics"]
        except (OSError, ValueError, KeyError, TypeError):
            continue
        if not isinstance(metrics, dict):
            continue
        conversation = os.path.basename(os.path.dirname(path))
        for usage_id, m in metrics.items():
            if not isinstance(m, dict):
                continue
            model = m.get("model_name") or "unknown"
            keys = ("prompt_tokens", "completion_tokens", "cache_read_tokens", "cache_write_tokens", "reasoning_tokens")
            acc = m.get("accumulated_token_usage")
            total = [max(0, num(acc, k)) for k in keys] if isinstance(acc, dict) else [0] * 5
            if isinstance(acc, dict) and isinstance(acc.get("model"), str) and acc["model"]:
                model = acc["model"]
            if sum(total[:4]) == 0:
                for u in m.get("token_usages") or []:
                    total = [a + max(0, num(u, k)) for a, k in zip(total, keys)]
            prompt, completion, cr, cw, rz = total
            if cr > prompt:
                inp = prompt
            else:
                cw = min(cw, prompt - cr)
                inp = prompt - cr - cw
            costs = [c.get("timestamp") for c in (m.get("costs") or []) if isinstance(c, dict) and isinstance(c.get("timestamp"), (int, float))]
            stamp = epoch(max(costs)) if costs else os.path.getmtime(path)
            provider = "openhands"
            if "/" in model:
                provider, model = model.split("/", 1)
            add(f"oh:{conversation}:{usage_id}", stamp, provider, model, inp, cr, cw, completion, min(rz, completion))


def devin_sessions(add, home, epoch):
    """Assistant requests of `sessions.db` for the sessions that have no transcript."""
    path = home + "/.local/share/devin/cli/sessions.db"
    if not os.path.isfile(path):
        return
    covered = {os.path.basename(p)[:-5] for p in glob.glob(home + "/.local/share/devin/cli/transcripts/*.json")}
    for session, node, chat, created, session_model, directory in _rows(
            path, "select m.session_id, m.node_id, m.chat_message, m.created_at, s.model, s.working_directory "
                  "from message_nodes m join sessions s on s.id = m.session_id"):
        if session in covered:
            continue
        try:
            o = json.loads(chat)
            meta = o["metadata"]
            metrics = meta["metrics"]
        except (ValueError, KeyError, TypeError):
            continue
        if o.get("role") != "assistant" or not isinstance(metrics, dict):
            continue

        def n(key):
            v = metrics.get(key)
            return max(0, int(v)) if isinstance(v, (int, float)) and not isinstance(v, bool) else 0

        def real(m):
            return m if isinstance(m, str) and m and m != "adaptive" else None

        rid = meta.get("request_id") if isinstance(meta.get("request_id"), str) and meta.get("request_id") else "n" + str(node)
        add(f"devin:{session}:db:{rid}", epoch(created), "devin", real(meta.get("generation_model")) or real(session_model) or "unknown",
            n("input_tokens"), n("cache_read_tokens"), n("cache_creation_tokens"), n("output_tokens"), 0)


def collect(add, env, home, epoch, num):
    crush(add, env, home, epoch)
    goose(add, env, home, epoch)
    droid(add, home, epoch, num)
    amp(add, env, home, epoch, num)
    openhands(add, env, home, epoch, num)
    devin_sessions(add, home, epoch)
