"""Claude Code, Codex, opencode (and Kilo's CLI), oh-my-pi, Qwen Code, Kimi Code, Devin and Antigravity.

Each reader turns one file into model calls. What a row means is written where it is read; the counts follow the
Mac app's readers (and its independent Python twin) so the same files give the same totals.
"""
from __future__ import annotations

import json
import os
import stat
import re
import sqlite3

from .. import extdb
from ..util import (JSON_ERRORS, BadFile, epoch, iter_lines, line_hash, load_json_file, loads, note_unreadable, num, raw_num, read_json_file, text, walk_files,
                    seen_once, mtime, clamp, longpath, run_seconds, safe_text)
from .base import db_stamp, family

# ---------------------------------------------------------------------------------------------- helpers


def under(sub: str, match):
    def files(ctx, d):
        return [p for root in ctx.roots(d) for p in walk_files(os.path.join(root, *sub.split("/")) if sub else root, match)]
    return files


def base_model(raw: str) -> str:
    """The model without Claude Code's context-window suffix, as `claude-opus-5-5[1m]`."""
    return raw.split("[")[0] or raw


def _provider_of(model: str) -> str:
    return "anthropic" if model.startswith("claude") else "custom"


def _lines(ctx, path, offset, limit, settled):
    return iter_lines(path, offset, limit, settled)


# ---------------------------------------------------------------------------------------------- Claude Code
# <config>/projects/**/*.jsonl, subagent files included. One assistant line per request; a request streamed over
# several lines keeps its largest copy (the store's rule). `iterations` lists advisor calls that cost tokens of
# their own. A `cost-state` line is a run's cumulative record: what it holds beyond the transcript rows is added
# back (see `claude_adjust`).

@family("anthropic-jsonl", under("projects", lambda n: n.endswith(".jsonl")), mode="lines",
        after=lambda ctx, d, store, changed: claude_adjust(store) if changed or store.meta("cc-adjust-stale") else None)
def read_claude(ctx, d, path, offset, limit, settled, sink):
    end = offset
    for line, end in iter_lines(path, offset, limit, settled):
        if not line:
            continue
        if '"type":"cost-state"' in line[:300]:
            _cost_state(line, sink)
            continue
        if '"usage"' not in line or '"assistant"' not in line:
            continue
        o = loads(line)
        if not isinstance(o, dict):
            continue
        m = o.get("message")
        if o.get("type") != "assistant" or not isinstance(m, dict) or not isinstance(m.get("usage"), dict):
            continue
        model = base_model(text(m.get("model")) or "unknown")
        if model == "<synthetic>":
            continue
        ts = epoch(o.get("timestamp"))
        if not ts:
            continue
        mid = text(m.get("id")) or text(o.get("uuid")) or line_hash(line)
        key = f"cc:{mid}:{o.get('requestId') if isinstance(o.get('requestId'), str) else ''}"
        session = text(o.get("sessionId")) or ""

        def emit(k, md, usage):
            details = usage.get("output_tokens_details")
            out = num(usage, "output_tokens")
            cache = usage.get("cache_creation")
            sink.add(k, ts, _provider_of(md), md, num(usage, "input_tokens"), num(usage, "cache_read_input_tokens"),
                     num(usage, "cache_creation_input_tokens"), out, min(num(details, "thinking_tokens"), out),
                     num(cache, "ephemeral_1h_input_tokens"), session)

        u = m["usage"]
        emit(key, model, u)
        its = u.get("iterations")
        for i, it in enumerate(its if isinstance(its, list) else []):
            if not isinstance(it, dict):
                continue
            kind = text(it.get("type")) or "message"
            if kind != "message":
                emit(f"{key}:{kind}:{i}", base_model(text(it.get("model")) or model), it)
    return end


def _cost_state(line, sink):
    o = loads(line)
    if not isinstance(o, dict) or not isinstance(o.get("modelUsage"), dict):
        return
    session = text(o.get("sessionId"))
    if not session:          # the Mac reader skips a cost line without a session: it would be a row no transcript can match
        return
    started = run_seconds(epoch(o.get("startTime")))      # a run is whole seconds, 0 when the time does not fit (Mac Safe.seconds)
    for raw, u in o["modelUsage"].items():
        if isinstance(raw, str) and isinstance(u, dict):
            # The raw name keeps `claude-opus-5-5` and `claude-opus-5-5[1m]` apart inside one run (each is its own
            # cumulative counter, the larger copy of each stands); they are added together per model at `claude_adjust`.
            sink.costs.append((session, started, raw, num(u, "inputTokens"), num(u, "cacheReadInputTokens"),
                               num(u, "cacheCreationInputTokens"), num(u, "outputTokens")))


def claude_adjust(store):
    """What a session's own cost record holds beyond its transcript rows, dated at its latest run."""
    seen = store.sums("cc:", exclude="cc:adj:")
    totals, last = {}, {}
    for session, started, raw, i, cr, cw, o in store.cost_rows():
        model = base_model(raw)
        t = totals.setdefault((session, model), [0, 0, 0, 0])
        for n, v in enumerate((i, cr, cw, o)):
            t[n] = clamp(t[n] + v)
        last[session] = max(last.get(session, 0.0), started)
    events = []
    from .base import Event
    for (session, model), t in totals.items():
        s = seen.get((session, model), (0, 0, 0, 0))
        gap = [max(0, a - b) for a, b in zip(t, s)]
        if sum(gap) == 0:
            continue
        events.append(Event(f"cc:adj:{session}:{model}", float(int(last[session])), _provider_of(model), model,
                            gap[0], gap[1], gap[2], gap[3], 0, 0, session))
    store.replace_prefix("cc:adj:", events)
    store.set_meta("cc-adjust-stale", "")


# ---------------------------------------------------------------------------------------------- Codex
# <codex home>/sessions and archived_sessions: rollout-*.jsonl (and .jsonl.zst). `token_count` events carry the
# session's cumulative totals; a call is the difference of two of them. A total that goes down is a counter reset.

def codex_files(ctx, d):
    def match(n):
        return n.startswith("rollout-") and (n.endswith(".jsonl") or n.endswith(".jsonl.zst"))
    out = []
    for root in ctx.roots(d):
        out += walk_files(os.path.join(root, "sessions"), match) + walk_files(os.path.join(root, "archived_sessions"), match)
    return out


_CODEX_KINDS = ('"session_meta"', '"turn_context"', '"task_started"', '"token_count"')


def _codex_relevant(line):
    return bool(line) and any(t in line for t in _CODEX_KINDS)


def _total(t):
    return num(t, "total_tokens") or num(t, "input_tokens") + num(t, "output_tokens")


@family("codex-rollout", codex_files, mode="whole")
def read_codex(ctx, d, path, offset, limit, settled, sink):
    if path.endswith(".zst"):
        # A stream: what comes before a limit is read and counted (the totals are cumulative), as the Mac app does.
        failure = []

        def stream():
            try:
                for ln in extdb.zstd_lines(path):
                    if _codex_relevant(ln):
                        yield ln
            except (extdb.ZstdMissing, ValueError, OSError) as e:     # ZstdTooLarge is a ValueError
                failure.append(e)

        lines = stream()
    else:
        failure = []
        lines = (ln for ln, _ in iter_lines(path, 0, limit, True))
    session, provider, model, first_model, started, last, turn, reset = None, "openai", None, None, None, None, None, 0
    seen_meta = False
    pending = []
    for line in lines:
        if not _codex_relevant(line):
            continue
        o = loads(line)
        if not isinstance(o, dict):
            continue
        p = o.get("payload")
        if not isinstance(p, dict):
            continue
        kind = o.get("type")
        if kind == "session_meta" and not seen_meta:
            # Only the first session_meta describes this file (a fork appends its parent's after it), whether it
            # names an id or not: a missing id is the file name, as the Mac reader has it.
            seen_meta = True
            session = text(p.get("id")) or text(p.get("session_id")) or os.path.basename(path).split(".")[0]
            provider = text(p.get("model_provider")) or "openai"
            started = epoch(p.get("timestamp") or o.get("timestamp")) or None
        elif kind == "turn_context":
            if text(p.get("model")):
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
            t = _total(total)
            if t <= 0:
                continue
            line_ts = epoch(o.get("timestamp")) if isinstance(o.get("timestamp"), str) else 0.0
            if not line_ts:             # a token_count with no time of its own is no call (the Mac reader needs it too)
                continue
            ts = max(line_ts, turn or 0)
            if started and ts < started - 1:
                last = total
                continue
            if last is None:
                delta = total
            else:
                lt = _total(last)
                if t == lt:
                    continue
                if t > lt:
                    delta = {k: max(0, num(total, k) - num(last, k)) for k in
                             ("input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens",
                              "reasoning_output_tokens")}
                else:
                    reset += 1
                    lu = info.get("last_token_usage")
                    delta = lu if isinstance(lu, dict) else total
            last = total
            sid = session or os.path.basename(path).split(".")[0]
            pending.append((f"cx:{sid}{f':e{reset}' if reset else ''}:{t}", ts, delta, model))
    if failure:
        e = failure[0]
        if isinstance(e, extdb.ZstdTooLarge):     # named every pass, never unpacked again (the Mac app's way)
            sink.bad = f"{path}: unpacked content too large ({e}); the calls before that point are counted"
        elif isinstance(e, extdb.ZstdMissing):
            sink.issue(str(e))
            return None
        else:
            sink.issue(f"{path}: {e}")
            return None
    for key, ts, dl, md in pending:
        inp = num(dl, "input_tokens")
        cached = min(num(dl, "cached_input_tokens"), inp)
        writes = min(num(dl, "cache_write_input_tokens"), max(0, inp - cached))
        out = num(dl, "output_tokens")
        # Usage logged before the first turn_context belongs to the first model named, not the last.
        sink.add(key, ts, provider, md or first_model or "unknown", max(0, inp - cached - writes), cached, writes, out,
                 min(num(dl, "reasoning_output_tokens"), out))
    return limit


# ---------------------------------------------------------------------------------------------- opencode, Kilo CLI
# opencode.db's `message` table: one JSON row per message; an assistant row holds the call's tokens. Reasoning is
# counted on top of output (opencode records them apart). Rows are appended in rowid order and updated when the
# call finishes, so a pass resumes a little before the last row id it saw.

OVERLAP_ROWS = 2000


def opencode_files(ctx, d):
    out = []
    for root in ctx.roots(d):
        lp = longpath(root)
        try:
            st = os.stat(lp)
        except FileNotFoundError:
            continue
        except PermissionError:
            note_unreadable(root)
            continue
        except OSError:
            continue
        if stat.S_ISREG(st.st_mode):
            out.append(root)
            continue
        if not stat.S_ISDIR(st.st_mode):
            continue
        if d.prefix == "kilo":
            try:
                names = sorted(n for n in os.listdir(lp) if n == "kilo.db" or (n.startswith("kilo-") and n.endswith(".db")))
            except PermissionError:
                note_unreadable(root)
                names = []
            except OSError:
                names = []
        else:
            names = []
            try:
                if stat.S_ISREG(os.stat(longpath(os.path.join(root, "opencode.db"))).st_mode):
                    names = ["opencode.db"]
            except PermissionError:
                note_unreadable(root)           # the folder is there but its files cannot be looked at
            except OSError:
                pass
        out += [os.path.join(root, n) for n in names]
    return seen_once(out)


@family("opencode-sqlite", opencode_files, mode="rowid", stamp=db_stamp)
def read_opencode(ctx, d, path, offset, limit, settled, sink):
    prefix = d.prefix
    try:
        with extdb.open_readonly(path) as con:
            newest = con.execute("select max(rowid) from message").fetchone()[0]
            # A database made again (reset, cleaned) starts its row ids over: the watermark would hide every new row.
            if not isinstance(newest, int) or newest < offset:
                offset = 0
            start = max(0, offset - OVERLAP_ROWS)
            last = offset
            cur = con.execute("select rowid, id, data from message where rowid > ? order by rowid", (start,))
            for rowid, mid, data in cur:
                if isinstance(rowid, int):
                    last = max(last, rowid)
                m = loads(data) if isinstance(data, str) else None
                if not isinstance(m, dict) or m.get("role") != "assistant":
                    continue
                provider, model = text(m.get("providerID")), text(m.get("modelID"))
                if not provider or not model:
                    continue
                t = m.get("tokens") if isinstance(m.get("tokens"), dict) else {}
                c = t.get("cache") if isinstance(t.get("cache"), dict) else {}
                tm = m.get("time") if isinstance(m.get("time"), dict) else {}
                reasoning = num(t, "reasoning")
                sink.add(f"{prefix}:{mid}", epoch(tm.get("created")), provider, model, num(t, "input"), num(c, "read"),
                         num(c, "write"), num(t, "output") + reasoning, reasoning)
    except (sqlite3.Error, OSError) as e:
        sink.issue(f"{path}: {e}")
        return None
    return last


# ---------------------------------------------------------------------------------------------- oh-my-pi
# <home>/.omp/agent/sessions/**/*.jsonl: assistant lines carry `usage`; `toolResult` lines do not count.

def _omp_n(u, key):
    """A whole number; a decimal value is a cost field, never a token count (the Mac reader skips it)."""
    v = u.get(key)
    return clamp(v) if isinstance(v, int) and not isinstance(v, bool) else 0


def _omp_session(path):
    """The id in the file's session header (its first line, whatever the spacing), else its name: it keys a line that has no responseId."""
    stem = os.path.splitext(os.path.basename(path))[0].rsplit("_", 1)[-1]      # as the Mac reader names a session
    try:
        for line, _ in iter_lines(path, 0, 65536, True):
            if not line:                 # a blank line is no first line
                continue
            o = loads(line)
            if isinstance(o, dict) and o.get("type") == "session":      # spaced or not, as the Mac reader parses it
                return text(o.get("id")) or stem
            break
    except OSError:
        pass
    return stem


@family("omp-jsonl", under("agent/sessions", lambda n: n.endswith(".jsonl")), mode="lines")
def read_omp(ctx, d, path, offset, limit, settled, sink):
    session = _omp_session(path)
    end = offset
    for line, end in iter_lines(path, offset, limit, settled):
        if '"usage"' not in line:          # a cheap first look; every decision below is made on the parsed line
            continue
        o = loads(line)
        if not isinstance(o, dict) or o.get("type") == "session":
            continue
        m = o.get("message") if isinstance(o.get("message"), dict) else o
        # A `task` result repeats its subagents' usage; their own transcripts already count it.
        if m.get("role") == "toolResult" or o.get("role") == "toolResult":
            continue
        u = m.get("usage")
        if not isinstance(u, dict):
            continue
        provider, model = text(m.get("provider")) or "", text(m.get("model")) or "unknown"
        if "/" in model:
            head, tail = model.split("/", 1)
            if not provider or head == provider:
                provider, model = head, tail
        rid = text(m.get("responseId"))
        key = f"omp:{rid}" if rid else f"omp:{session}:" + line_hash(line)
        sink.add(key, epoch(o.get("timestamp", m.get("timestamp"))), provider, model, _omp_n(u, "input"), _omp_n(u, "cacheRead"),
                 _omp_n(u, "cacheWrite"), _omp_n(u, "output"), _omp_n(u, "reasoningTokens"))
    return end


# ---------------------------------------------------------------------------------------------- Qwen Code
# usage/token-usage-*.jsonl: one line per call. usage_record.jsonl: cumulative per session; what it holds beyond
# the per-call lines becomes an adjustment row (see `qwen_adjust`). Input includes cached tokens.

def qwen_files(ctx, d):
    out = []
    for root in ctx.roots(d):
        out += walk_files(os.path.join(root, "usage"), lambda n: n.startswith("token-usage-") and n.endswith(".jsonl"))
        out.append(os.path.join(root, "usage_record.jsonl"))
    return [p for p in out if os.path.isfile(longpath(p))]


@family("qwen-usage", qwen_files, mode="lines",
        after=lambda ctx, d, store, changed: qwen_adjust(ctx, d, store, changed))
def read_qwen(ctx, d, path, offset, limit, settled, sink):
    if os.path.basename(path) == "usage_record.jsonl":
        with open(longpath(path), "rb"):   # read whole by the adjustment pass; only its offset moves. A locked file raises
            return limit
    end = offset
    for line, end in iter_lines(path, offset, limit, settled):
        o = loads(line) if line else None
        if not isinstance(o, dict):
            continue
        if not text(o.get("id")):                   # the Mac reader needs an id too: without one the call has no key
            continue
        inp, cached = num(o, "inputTokens"), num(o, "cachedTokens")
        sink.add(f"qwen:{o.get('id')}", epoch(o.get("timestamp")), text(o.get("authType")) or "qwen",
                 text(o.get("model")) or "unknown", max(0, inp - cached), min(cached, inp), 0, num(o, "outputTokens"),
                 num(o, "thoughtsTokens"), 0, text(o.get("sessionId")) or "")
    return end


def qwen_adjust(ctx, d, store, changed):
    records = [os.path.join(r, "usage_record.jsonl") for r in ctx.roots(d)]
    records = [p for p in records if os.path.isfile(longpath(p))]
    if not records or not (changed or store.meta("qwen-adjust-stale") or not store.has_prefix("qwen:adj:")):
        return
    from .base import Event
    latest = {}
    for path in records:
        try:
            for line, _ in iter_lines(path, 0, None, True):
                r = loads(line) if line else None
                if not isinstance(r, dict) or not isinstance(r.get("models"), dict):
                    continue
                # As the rows were stored (a lone surrogate is U+FFFD there): the figures held under the same name are
                # looked up in `seen` below, and an unequal name would count the same tokens twice.
                session = safe_text(r.get("sessionId")) if isinstance(r.get("sessionId"), str) else ""
                for model, m in r["models"].items():
                    if isinstance(m, dict) and isinstance(model, str):
                        key = (session, safe_text(model))
                        if key not in latest or num(m, "totalTokens") >= num(latest[key][0], "totalTokens"):
                            latest[key] = (m, r.get("timestamp"))
        except OSError:
            # Locked just now. The scanner has already recorded the file as read, so nothing would bring the pass back:
            # note that the adjustment is owed (done at the next pass, whatever changed) and name the file.
            store.set_meta("qwen-adjust-stale", "1")
            raise
    seen = store.sums("qwen:", exclude="qwen:adj:", with_provider=True)
    events = []
    for (session, model), (m, ts) in latest.items():
        s = seen.get((session, model), (0, 0, 0, 0, 0, "qwen"))
        # s = input, cacheRead, cacheWrite, output, reasoning, provider
        inp = max(0, num(m, "inputTokens") - (s[0] + s[1]))
        cached = max(0, num(m, "cachedTokens") - s[1])
        ev = Event(f"qwen:adj:{session}:{model}", epoch(ts), s[5], model, max(0, inp - cached), min(cached, inp), 0,
                   max(0, num(m, "outputTokens") - s[3]), max(0, num(m, "thoughtsTokens") - s[4]), 0, session)
        if ev.total > 0:
            events.append(ev)
    store.replace_prefix("qwen:adj:", events)
    store.set_meta("qwen-adjust-stale", "")


# ---------------------------------------------------------------------------------------------- Kimi Code
# <home>/.kimi-code/sessions/<wd>/<session>/agents/<agent>/wire.jsonl: `llm.request` names the model, each
# `step.end` carries one call's usage.

@family("kimi-wire", under("sessions", lambda n: n == "wire.jsonl"), mode="whole")
def read_kimi(ctx, d, path, offset, limit, settled, sink):
    parts = re.split(r"[\\/]", path)
    session = parts[-4] if len(parts) >= 4 else path
    model = "unknown"
    for line, _ in iter_lines(path, 0, limit, True):
        o = loads(line) if line else None
        if not isinstance(o, dict):
            continue
        if o.get("type") == "llm.request":
            model = text(o.get("modelAlias")) or text(o.get("model")) or model
            continue
        e = o.get("event")
        if not isinstance(e, dict) or e.get("type") != "step.end" or not isinstance(e.get("usage"), dict):
            continue
        u = e["usage"]
        provider, name = model.split("/", 1) if "/" in model else ("", model)
        ident = text(e.get("messageId")) or text(e.get("uuid")) or line_hash(line)
        sink.add(f"kimi:{session}:{ident}", epoch(o.get("time")), provider, name, num(u, "inputOther"),
                 num(u, "inputCacheRead"), num(u, "inputCacheCreation"), num(u, "output"), 0)
    return limit


# ---------------------------------------------------------------------------------------------- Devin
# <home>/.local/share/devin/cli/transcripts/*.json: a transcript lists steps, each with `metrics`.

def _devin_step_key(s):
    """`step_id`, or the step's timestamp when a transcript has none (two steps must not share a key)."""
    step = num(s, "step_id")
    if step:
        return str(step)
    stamp = s.get("timestamp")
    return stamp if isinstance(stamp, str) and stamp else str(epoch(stamp))


def read_devin(ctx, d, path, offset, limit, settled, sink):
    o = read_json_file(path)
    if not isinstance(o, dict):
        return limit
    session = text(o.get("session_id")) or os.path.basename(path)[:-5]
    agent = text((o.get("agent") or {}).get("model_name")) if isinstance(o.get("agent"), dict) else None
    for s in o.get("steps") if isinstance(o.get("steps"), list) else []:
        if not isinstance(s, dict) or not isinstance(s.get("metrics"), dict):
            continue
        m = s["metrics"]
        prompt, cached = num(m, "prompt_tokens"), num(m, "cached_tokens")
        sink.add(f"devin:{session}:{_devin_step_key(s)}", epoch(s.get("timestamp")), "devin",
                 text(s.get("model_name")) or agent or "unknown", max(0, prompt - cached), min(cached, prompt), 0,
                 num(m, "completion_tokens"), 0)
    return limit


# ---------------------------------------------------------------------------------------------- Antigravity
# <home>/.gemini/antigravity-cli/conversations/*.db: protobuf inside SQLite. `gen_metadata` names the models,
# `steps` of type 15 carry the usage message.

def proto(data):
    """{field: first value} of one protobuf message: varints as int, length-delimited as bytes."""
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
            if s > 70:
                raise IndexError

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


IMPOSSIBLE_COUNT = 1 << 40      # no single call reaches this: a larger number means Antigravity moved its fields


def _pint(v):
    return clamp(v) if isinstance(v, int) else 0


@family("antigravity-sqlite", under("conversations", lambda n: n.endswith(".db")), mode="whole", stamp=db_stamp)
def read_antigravity(ctx, d, path, offset, limit, settled, sink):
    conversation = os.path.basename(path)[:-3]
    models: dict[int, str] = {}
    try:
        with extdb.readable(path) as con:
            # `gen_metadata` names the models: the enum at 1.3, the name at 1.19 (as the Mac reader does). A step
            # carries only the enum, so a row's position says nothing about which model it used.
            for (blob,) in con.execute("select data from gen_metadata order by idx"):
                first = proto(blob if isinstance(blob, (bytes, bytearray)) else (blob or "").encode("utf-8", "replace"))
                inner = first.get(1)
                f = proto(inner) if isinstance(inner, bytes) else {}
                enum, name = f.get(3), f.get(19)
                if isinstance(enum, int) and isinstance(name, bytes) and name:
                    models[enum] = name.decode("utf-8", "replace")
            steps = con.execute("select idx, metadata from steps where step_type = 15 order by idx").fetchall()
    except OSError as e:                      # held by another program right now: read again next pass
        sink.issue(f"{path}: {e}")
        return None
    except sqlite3.Error as e:                # not a database: named (as the Mac app does), not marked read
        sink.issue(f"{path}: {e}")
        return None
    pending = []
    for idx, meta in steps:
        top = proto(meta if isinstance(meta, (bytes, bytearray)) else (meta or "").encode("utf-8", "replace"))
        u = top.get(9)
        if not isinstance(u, bytes):
            continue
        f = proto(u)
        if any(isinstance(f.get(n), int) and f[n] >= IMPOSSIBLE_COUNT for n in (2, 3, 4, 5, 9)):
            sink.issue(f"{path}: step {idx}: usage fields not understood")      # Antigravity moved its fields: the Mac app refuses the file
            return None
        enum = f.get(1, 0)
        name = models.get(enum) or f"antigravity-model-{enum}"
        ts = 0.0
        for field in (8, 7, 1):
            stamp = top.get(field)
            seconds = proto(stamp).get(1) if isinstance(stamp, bytes) else None
            if isinstance(seconds, int) and seconds > 1_000_000_000:
                ts = float(min(seconds, 10 ** 12))
                break
        pending.append((f"ag:{conversation}:{idx}", ts, name, _pint(f.get(2, 0)), _pint(f.get(5, 0)),
                        _pint(f.get(4, 0)), _pint(f.get(3, 0)), _pint(f.get(9, 0))))
    for key, ts, name, inp, cr, cw, out, rz in pending:
        sink.add(key, ts, "google-antigravity", name, inp, cr, cw, out, rz)
    return limit
