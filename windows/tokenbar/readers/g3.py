"""Crush, Goose, Factory Droid, Amp, OpenHands and the Devin CLI's sessions.db."""
from __future__ import annotations

import os
import re
import sqlite3

from .. import extdb
from ..util import (clamp, epoch, is_number, load_json_file, mtime, read_json_file, num, seen_once, text, walk_files, whole, loads, longpath, safe_text)
from .base import db_stamp, family, real_event_prefixes
from .core import read_devin as _read_devin_transcript, under


def _when(value):
    """Seconds from a number, an ISO string, or a number written as text; SQLite's CURRENT_TIMESTAMP means UTC."""
    try:
        return epoch(float(value))
    except (TypeError, ValueError, OverflowError):
        if isinstance(value, str) and re.fullmatch(r"\d{4}-\d\d-\d\d[ T]\d\d:\d\d:\d\d", value):
            value += "+00:00"
        return epoch(value)


def _int(v):
    return clamp(int(v)) if isinstance(v, (int, float)) and not isinstance(v, bool) and v == v and abs(v) != float("inf") else 0


# ---------------------------------------------------------------------------------------------- Crush
# Crush's global data folder holds projects.json; each project names its own data folder, whose crush.db keeps one row
# per session with running prompt and completion counts. The model is the newest assistant message's.

def crush_files(ctx, d):
    dbs = []
    for r in ctx.roots(d):
        doc = load_json_file(os.path.join(r, "projects.json"))
        projects = doc.get("projects") if isinstance(doc, dict) else None
        for p in projects if isinstance(projects, list) else []:
            if isinstance(p, dict) and text(p.get("data_dir")):
                data = p["data_dir"]
                if not (os.path.isabs(data) or data.startswith(("/", "\\"))):
                    data = os.path.join(text(p.get("path")) or "", data)
                dbs.append(os.path.join(data, "crush.db"))
    return seen_once(dbs)


@family("crush-sqlite", crush_files, mode="whole", stamp=db_stamp)
def read_crush(ctx, d, path, offset, limit, settled, sink):
    try:
        with extdb.readable(path) as con:          # one connection (one copy of a WAL database) for every query
            has_provider = "provider" in extdb.table_columns(con, "messages")
            sessions = extdb.query(con, "select id, prompt_tokens, completion_tokens, updated_at, created_at from sessions "
                                        "where prompt_tokens > 0 or completion_tokens > 0")
            for sid, prompt, completion, updated, created in sessions:
                if sid is None or str(sid) == "":          # a session with no identity has no key (the Mac reader skips it)
                    continue

                def latest(column):
                    # the newest assistant message that names one (the model and the provider are looked up apart, as on Mac)
                    got = extdb.query(con, f"select {column} from messages where session_id = ? and role = 'assistant' "
                                           f"and {column} is not null and {column} != '' order by created_at desc, rowid desc limit 1", (sid,))
                    return got[0][0] if got else None
                model = latest("model")
                provider = latest("provider") if has_provider else None
                stamp = _when(updated)
                if stamp <= 0:
                    stamp = _when(created)
                sink.add("crush:" + str(sid), stamp, provider or "crush", model or "unknown",
                         _int(prompt), 0, 0, _int(completion), 0)
    except OSError as e:                           # held by another program right now: read again next pass
        sink.issue(f"{path}: {e}")
        return None
    except sqlite3.Error as e:                     # not a database (or not this tool's): named every pass, never recorded
        sink.issue(f"{path}: {e}")
        return None
    return limit


# ---------------------------------------------------------------------------------------------- Goose
# sessions.db: one row per session with accumulated counts (or the plain ones); cache is inside the input.

def goose_files(ctx, d):
    candidates = []
    for r in ctx.roots(d):
        candidates += [r, os.path.join(r, "sessions.db"), os.path.join(r, "sessions", "sessions.db"),
                       os.path.join(r, "data", "sessions", "sessions.db")]
    return seen_once(candidates)


@family("goose-sqlite", goose_files, mode="whole", stamp=db_stamp)
def read_goose(ctx, d, path, offset, limit, settled, sink):
    want = ["id", "model_config_json", "provider_name", "updated_at", "created_at",
            "accumulated_input_tokens", "accumulated_output_tokens", "accumulated_cache_read_tokens",
            "accumulated_cache_write_tokens", "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens"]
    try:
        with extdb.readable(path) as con:
            have = extdb.table_columns(con, "sessions")
            data = extdb.query(con, "select " + ", ".join(c if c in have else "null" for c in want) + " from sessions")
    except OSError as e:                           # held by another program right now: read again next pass
        sink.issue(f"{path}: {e}")
        return None
    except sqlite3.Error as e:                     # not a database (or not this tool's): named every pass, never recorded
        sink.issue(f"{path}: {e}")
        return None
    for row in data:
        sid, config, provider, updated, created = row[:5]
        if sid is None or str(sid) == "":
            continue
        acc, plain = row[5:9], row[9:13]
        use = acc if (acc[0] is not None or acc[1] is not None) else plain
        inp, out, cr, cw = [max(0, _int(v)) for v in use]
        cr = min(cr, inp)
        cw = min(cw, inp - cr)
        cfg = loads(config) if isinstance(config, str) else None
        model = (text(cfg.get("model_name")) or "").strip() if isinstance(cfg, dict) else ""
        model = model or "unknown"
        stamp = _when(updated)
        sink.add("goose:" + str(sid), stamp if stamp > 0 else _when(created), provider or "goose", model, inp - cr - cw, cr, cw, out, 0)
    return limit


# ---------------------------------------------------------------------------------------------- Factory Droid
# <home>\.factory\sessions\**\*.settings.json: one `tokenUsage` summary per session.

def _droid_model(raw):
    if not isinstance(raw, str) or not raw.strip():
        return "unknown"
    name = raw.strip()
    if name.startswith("custom:"):
        name = name[len("custom:"):]
    name = re.sub(r"\[[^\[\]]*\]", "", name)
    return name.strip(" -").lower() or "unknown"


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


@family("droid-settings", under("sessions", lambda n: n.endswith(".settings.json")), mode="whole")
def read_droid(ctx, d, path, offset, limit, settled, sink):
    o = read_json_file(path)
    usage = o.get("tokenUsage") if isinstance(o, dict) else None
    if not isinstance(usage, dict):
        return limit
    thinking = num(usage, "thinkingTokens")
    model = _droid_model(o.get("model"))
    stamp = epoch(o.get("providerLockTimestamp")) if isinstance(o.get("providerLockTimestamp"), str) else 0.0
    sink.add("droid:" + os.path.basename(path)[:-len(".settings.json")], stamp or mtime(path),
             _droid_provider(o.get("providerLock"), model), model, num(usage, "inputTokens"), num(usage, "cacheReadTokens"),
             num(usage, "cacheCreationTokens"), num(usage, "outputTokens") + thinking, thinking)
    return limit


# ---------------------------------------------------------------------------------------------- Amp
# <amp data>\threads\**\T-*.json. A thread with a usage ledger counts its events; an older one counts its assistant
# messages' usage.

def _amp_split(inp, out, write, read, total):
    inp, out, write, read = max(0, inp), max(0, out), max(0, write), max(0, read)
    if inp + out == 0 and total > write + read:
        inp = total - write - read
    return inp, read, write, out


def _mid(v):
    if is_number(v):
        return str(whole(v))
    return v if isinstance(v, str) and v else None


@family("amp-threads", under("threads", lambda n: n.startswith("T-") and n.endswith(".json")), mode="whole")
def read_amp(ctx, d, path, offset, limit, settled, sink):
    o = read_json_file(path)
    if not isinstance(o, dict):
        return limit
    thread = text(o.get("id")) or os.path.basename(path)[:-5]
    messages = [m for m in (o.get("messages") if isinstance(o.get("messages"), list) else []) if isinstance(m, dict)]
    file_time = mtime(path)
    ledger = o.get("usageLedger")
    if isinstance(ledger, dict) and isinstance(ledger.get("events"), list):
        cache = {}
        for m in messages:
            if m.get("role") == "assistant" and _mid(m.get("messageId")) and isinstance(m.get("usage"), dict):
                cache[_mid(m["messageId"])] = (num(m["usage"], "cacheCreationInputTokens"), num(m["usage"], "cacheReadInputTokens"))
        for i, e in enumerate(ledger["events"]):
            if not isinstance(e, dict) or not isinstance(e.get("tokens"), dict):
                continue
            w, r = cache.get(_mid(e.get("toMessageId")), (0, 0))
            t = e["tokens"]
            inp, cr, cw, out = _amp_split(num(t, "input"), num(t, "output"), w, r, num(t, "total"))
            sink.add(f"amp:{thread}:{e['id'] if isinstance(e.get('id'), str) and e.get('id') else 'i' + str(i)}",
                     epoch(e.get("timestamp")) or file_time, "amp", text(e.get("model")) or "unknown", inp, cr, cw, out, 0)
    else:
        for i, m in enumerate(messages):
            u = m.get("usage")
            if m.get("role") != "assistant" or not isinstance(u, dict):
                continue
            inp, cr, cw, out = _amp_split(num(u, "inputTokens"), num(u, "outputTokens"), num(u, "cacheCreationInputTokens"),
                                          num(u, "cacheReadInputTokens"), num(u, "totalTokens"))
            stamp = epoch(u.get("timestamp")) or epoch(m.get("timestamp")) or file_time
            ident = ("m" + _mid(m.get("messageId"))) if _mid(m.get("messageId")) else "i" + str(i)
            sink.add(f"amp:{thread}:{ident}", stamp, "amp", text(u.get("model")) or text(m.get("model")) or "unknown",
                     inp, cr, cw, out, 0)
    return limit


# ---------------------------------------------------------------------------------------------- OpenHands
# <conversations>\<id>\base_state.json: stats.usage_to_metrics holds each usage id's accumulated token usage.

def openhands_files(ctx, d):
    states = []
    for r in ctx.roots(d):
        try:
            names = sorted(os.listdir(longpath(r)))
        except OSError:
            continue
        states += [os.path.join(r, n, "base_state.json") for n in names]
    return seen_once(states)


@family("openhands-state", openhands_files, mode="whole")
def read_openhands(ctx, d, path, offset, limit, settled, sink):
    o = read_json_file(path)
    try:
        metrics = o["stats"]["usage_to_metrics"]
    except (KeyError, TypeError):
        return limit
    if not isinstance(metrics, dict):
        return limit
    conversation = os.path.basename(os.path.dirname(path))
    for usage_id, m in metrics.items():
        if not isinstance(m, dict):
            continue
        model = text(m.get("model_name")) or "unknown"
        keys = ("prompt_tokens", "completion_tokens", "cache_read_tokens", "cache_write_tokens", "reasoning_tokens")
        acc = m.get("accumulated_token_usage")
        total = [num(acc, k) for k in keys] if isinstance(acc, dict) else [0] * 5
        if isinstance(acc, dict) and text(acc.get("model")):
            model = acc["model"]
        if sum(total[:4]) == 0:
            for u in m.get("token_usages") if isinstance(m.get("token_usages"), list) else []:
                total = [clamp(a + num(u, k)) for a, k in zip(total, keys)]
        prompt, completion, cr, cw, rz = total
        if cr > prompt:
            inp = prompt
        else:
            cw = min(cw, prompt - cr)
            inp = prompt - cr - cw
        costs = [c.get("timestamp") for c in (m.get("costs") if isinstance(m.get("costs"), list) else [])
                 if isinstance(c, dict) and is_number(c.get("timestamp"))]
        stamp = max((epoch(c) for c in costs), default=0.0) or mtime(path)
        provider = "openhands"
        if "/" in model:
            provider, model = model.split("/", 1)
        sink.add(f"oh:{conversation}:{usage_id}", stamp, provider, model, inp, cr, cw, completion, min(rz, completion))
    return limit


# ---------------------------------------------------------------------------------------------- Devin sessions.db
# The CLI's own database, for the sessions that have no transcript.

def _devin_sessions(ctx, d, path, sink):
    covered = {safe_text(os.path.basename(p)[:-5]) for p in walk_files(os.path.join(os.path.dirname(path), "transcripts"),
                                                           lambda n: n.endswith(".json"))}
    for session, node, chat, created, session_model, directory in extdb.rows(     # OSError when locked, sqlite3.Error when no database: named, read again
            path, "select m.session_id, m.node_id, m.chat_message, m.created_at, s.model, s.working_directory "
                  "from message_nodes m join sessions s on s.id = m.session_id", strict=True):
        if session in covered:
            continue
        o = loads(chat) if isinstance(chat, str) else None
        if not isinstance(o, dict) or not isinstance(o.get("metadata"), dict):
            continue
        meta = o["metadata"]
        metrics = meta.get("metrics")
        if o.get("role") != "assistant" or not isinstance(metrics, dict):
            continue

        def n(key):
            v = metrics.get(key)
            return max(0, clamp(whole(v))) if is_number(v) else 0

        def real(m):
            return m if isinstance(m, str) and m and m != "adaptive" else None

        rid = text(meta.get("request_id")) or "n" + str(node)
        sink.add(f"devin:{session}:db:{rid}", _when(created), "devin",
                 real(meta.get("generation_model")) or real(session_model) or "unknown",
                 n("input_tokens"), n("cache_read_tokens"), n("cache_creation_tokens"), n("output_tokens"), 0)


def devin_files(ctx, d):
    out = []
    for r in ctx.roots(d):
        out += walk_files(os.path.join(r, "cli", "transcripts"), lambda n: n.endswith(".json"))
        db = os.path.join(r, "cli", "sessions.db")
        if os.path.isfile(longpath(db)):
            out.append(db)
    return out


def devin_after(ctx, d, store, changed):
    """A transcript that appeared after its session was read from sessions.db replaces those rows: the same calls
    would otherwise count twice (the Mac app retires `devin:<session>:db:` when it sees the transcript)."""
    for r in ctx.roots(d):
        for p in walk_files(os.path.join(r, "cli", "transcripts"), lambda n: n.endswith(".json")):
            for prefix in real_event_prefixes(f"devin:{os.path.basename(p)[:-5]}:db:"):      # a session named `adj` is stored as `adj#gercek`
                if store.has_prefix(prefix):
                    store.replace_prefix(prefix, [])


@family("devin-transcripts", devin_files, mode="whole", stamp=db_stamp, after=devin_after)
def read_devin_all(ctx, d, path, offset, limit, settled, sink):
    if path.endswith("sessions.db"):
        _devin_sessions(ctx, d, path, sink)
        return limit
    return _read_devin_transcript(ctx, d, path, offset, limit, settled, sink)
