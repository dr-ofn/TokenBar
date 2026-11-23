"""Cline, Roo Code, Kilo Code, Copilot Chat, Continue and Zed.

What each tool's rows mean: Cline keeps `tokensIn` apart from the cache counts; Roo Code and Kilo Code hold them inside
`tokensIn` from 2025-11-02T00:00:00Z on (before that only on the OpenAI protocol); Cline CLI's `inputTokens` holds them.
"""
from __future__ import annotations

import json
import math
import os
import re
import sqlite3

from .. import extdb
from ..util import (JSON_ERRORS, BadFile, finite, is_number, epoch, iter_lines, line_hash, load_json_file, loads, read_json_file, text, mtime, walk_files,
                    whole, clamp, longpath, to_seconds)
from .base import db_stamp, family

WHOLE_PROMPT_FROM_MS = 1_762_041_600_000  # 2025-11-02T00:00:00Z


def _listdir(path):
    try:
        return sorted(os.listdir(longpath(path)))
    except OSError:
        return []


def _isfile(p):
    return os.path.isfile(longpath(p))


# ---------------------------------------------------------------------------------------------- task logs

def _read_task_hints(folder):
    """(model switches, last <model> tag) of a task folder, as the sibling files name them."""
    switches = []
    meta = load_json_file(os.path.join(folder, "task_metadata.json"))
    if isinstance(meta, dict):
        for use in meta.get("model_usage") if isinstance(meta.get("model_usage"), list) else []:
            if isinstance(use, dict) and text(use.get("model_id")):
                ts = use.get("ts") if is_number(use.get("ts")) else 0
                switches.append((ts * 1000 if ts < 1e11 else ts, use["model_id"], text(use.get("model_provider_id"))))
    tag = None
    if not switches:
        try:
            with open(longpath(os.path.join(folder, "api_conversation_history.json")), encoding="utf-8", errors="replace") as f:
                raw = f.read()
        except OSError:
            raw = ""
        for m in re.finditer(r"<model>(.*?)</model>", raw, re.S):
            if m.group(1).strip():
                tag = m.group(1).strip()
    return switches, tag


def _ms_of(v):
    """Epoch milliseconds from a seconds-or-milliseconds number; None for anything that is not a finite number."""
    if not is_number(v) or not finite(v):
        return None
    try:
        t = float(v)
    except OverflowError:
        return None
    ms = t * 1000 if t < 1e11 else t
    return ms if math.isfinite(ms) else None


def _task_log(sink, path, prefix, roo, file_mtime):
    rows = read_json_file(path, strict=True)
    if rows is None:
        return                                  # no bytes (caught while the extension rewrites it): not a reading
    if not isinstance(rows, list):
        raise BadFile(f"{path}: not a JSON array")
    folder = os.path.dirname(path)
    task = os.path.basename(folder)
    hints = None
    seen = {}
    # The file is the whole truth of its task. A message the user rolled back (or a checkpoint restore, which Cline
    # folds into one `deleted_api_reqs` row) is gone from it: the rows this file wrote earlier are replaced by what it
    # holds now. Rows another copy of the task wrote (the same id in a second editor) are not touched.
    sink.retire_prefix(f"{prefix}:{task}:")
    for index, row in enumerate(rows):
        if not isinstance(row, dict) or row.get("type") != "say" or row.get("say") not in ("api_req_started", "deleted_api_reqs"):
            continue
        raw = row.get("text")
        if not isinstance(raw, str) or not raw:
            continue
        p = loads(raw)
        if not isinstance(p, dict):
            continue
        ms = _ms_of(row.get("ts"))
        cr, cw = max(0, whole(p.get("cacheReads"))), max(0, whole(p.get("cacheWrites")))
        inp = max(0, whole(p.get("tokensIn")))
        proto = text(p.get("apiProtocol"))
        if roo:
            gross = ms is not None and ms >= WHOLE_PROMPT_FROM_MS
            if not gross and proto:
                tail = [s for s in proto.split("/") if s]
                gross = bool(tail) and tail[-1].strip().lower() == "openai"
            if gross:
                inp = max(0, inp - cr - cw)
        out = max(0, whole(p.get("tokensOut")))
        if clamp(inp) + clamp(cr) + clamp(cw) + clamp(out) == 0:
            continue
        info = row.get("modelInfo") if isinstance(row.get("modelInfo"), dict) else {}
        model, provider = text(info.get("modelId")), text(info.get("providerId"))
        if model is None:
            if hints is None:
                hints = _read_task_hints(folder)
            earlier = [s for s in hints[0] if s[0] <= (ms or 0)]
            if earlier:
                model, provider = earlier[-1][1], provider or earlier[-1][2]
            else:
                model = hints[1]
        model = model or "unknown"
        if provider is None:
            # (empty pieces are dropped, as the Mac reader's `split` does: "/claude-opus-5-5" is `claude-opus-5-5`)
            first = [piece for piece in model.split("/") if piece] if "/" in model else []
            provider = first[0] if first else (proto or "")
        stamp = str(int(ms)) if ms is not None else f"i{index}"
        key = f"{prefix}:{task}:{'del:' if row['say'] == 'deleted_api_reqs' else ''}{stamp}"
        seen[key] = seen.get(key, 0) + 1
        if seen[key] > 1:
            key += f":{seen[key]}"
        sink.add(key, ms / 1000 if ms is not None else file_mtime, provider, model, inp, cr, cw, out, 0)


def _cline_cli(sink, path, prefix, file_mtime):
    folder = os.path.dirname(path)
    name = os.path.basename(folder)
    doc = read_json_file(path, strict=True)
    if doc is None:
        return
    if not isinstance(doc, dict):
        raise BadFile(f"{path}: not a JSON object")
    head = load_json_file(os.path.join(folder, f"{name}.json"))
    head = head if isinstance(head, dict) else {}
    session = text(doc.get("sessionId")) or text(head.get("session_id")) or name
    model, provider = text(head.get("model")) or "unknown", text(head.get("provider")) or ""
    ordinal = 0
    for m in doc.get("messages") if isinstance(doc.get("messages"), list) else []:
        if not isinstance(m, dict) or m.get("role") != "assistant":
            continue
        info = m.get("modelInfo")
        if isinstance(info, dict):
            model, provider = text(info.get("id")) or model, text(info.get("provider")) or provider
        metrics = m.get("metrics")
        if not isinstance(metrics, dict):
            continue
        cr, cw = max(0, whole(metrics.get("cacheReadTokens"))), max(0, whole(metrics.get("cacheWriteTokens")))
        inp = max(0, whole(metrics.get("inputTokens")) - cr - cw)
        out = max(0, whole(metrics.get("outputTokens")))
        mine = ordinal
        ordinal += 1
        if clamp(inp) + clamp(cr) + clamp(cw) + clamp(out) == 0:
            continue
        ts = to_seconds(m.get("ts"))
        mid = m.get("id")
        sink.add(f"{prefix}:{session}:{mid if isinstance(mid, str) and mid else mine}", ts if ts > 0 else file_mtime,
                 provider, model, inp, cr, cw, out, 0)


def task_files(ctx, d):
    out = []
    for r in ctx.roots(d):
        tasks = os.path.join(r, "tasks")
        for t in _listdir(tasks):
            p = os.path.join(tasks, t, "ui_messages.json")
            if _isfile(p):
                out.append(p)
        if d.prefix == "cline":
            sessions = os.path.join(r, "sessions")
            for s in _listdir(sessions):
                p = os.path.join(sessions, s, f"{s}.messages.json")
                if _isfile(p):
                    out.append(p)
    return out


def _read_tasks(ctx, d, path, offset, limit, settled, sink):
    if path.endswith(".messages.json"):
        _cline_cli(sink, path, d.prefix, mtime(path))
    else:
        _task_log(sink, path, d.prefix, d.prefix in ("roo", "kilocode"), mtime(path))
    return limit


family("cline-tasks", task_files, mode="whole")(_read_tasks)
family("roo-tasks", task_files, mode="whole")(_read_tasks)


# ---------------------------------------------------------------------------------------------- Copilot Chat
# VS Code's chatSessions\<id>.jsonl (a snapshot plus patch lines) or .json. Only requests that name a Copilot model.

def _set_path(target, path, value, depth=0):
    """The value at `path` inside `target`; objects and arrays are made on the way, a bad step changes nothing."""
    if not path:
        return value
    if depth > 256:
        return target
    head, rest = path[0], path[1:]
    if isinstance(head, str):
        obj = target if isinstance(target, dict) else {}
        obj[head] = _set_path(obj.get(head, {}), rest, value, depth + 1)
        return obj
    if is_number(head):
        i = whole(head)
        if 0 <= i <= 4096:
            arr = target if isinstance(target, list) else []
            while len(arr) <= i:
                arr.append(None)
            arr[i] = _set_path(arr[i], rest, value, depth + 1)
            return arr
    return target


def _prune(r):
    if not isinstance(r, dict):
        return {}
    out = {k: r[k] for k in ("promptTokens", "completionTokens", "timestamp", "modelId") if k in r}
    result = r.get("result")
    meta = result.get("metadata") if isinstance(result, dict) else None
    if isinstance(meta, dict):
        out["result"] = {"metadata": {k: meta[k] for k in ("promptTokens", "outputTokens", "resolvedModel") if k in meta}}
    return out


def _copilot_requests(path):
    reqs = []
    if path.endswith(".jsonl"):
        for line, _ in iter_lines(path):
            o = loads(line) if line else None
            if not isinstance(o, dict) or not is_number(o.get("kind")):
                continue
            kind, k = whole(o["kind"]), o.get("k")
            if kind == 0:
                v = o.get("v")
                if isinstance(v, dict) and isinstance(v.get("requests"), list):
                    reqs = [_prune(r) for r in v["requests"]]      # a snapshot replaces the requests
            elif kind == 1:
                if not (isinstance(k, list) and len(k) >= 2 and k[0] == "requests" and "v" in o):
                    continue
                i = whole(k[1]) if is_number(k[1]) else None
                if i is None or not 0 <= i < len(reqs):
                    continue
                reqs[i] = _prune(_set_path(reqs[i], k[2:], o["v"]))
            elif kind == 2:
                if isinstance(k, list) and k == ["requests"] and isinstance(o.get("v"), list):
                    reqs += [_prune(r) for r in o["v"]]
    else:
        doc = read_json_file(path, strict=True)
        if doc is not None and not isinstance(doc, dict):
            raise BadFile(f"{path}: not a JSON object")
        if isinstance(doc, dict) and isinstance(doc.get("requests"), list):
            reqs = [_prune(r) for r in doc["requests"]]
    return reqs


def copilot_chat_files(ctx, d):
    out = []
    for r in ctx.roots(d):
        if os.path.basename(r) == "workspaceStorage":
            for w in _listdir(r):
                for f in _listdir(os.path.join(r, w, "chatSessions")):
                    out.append(os.path.join(r, w, "chatSessions", f))
        else:
            out += [os.path.join(r, f) for f in _listdir(r)]
    return [p for p in out if p.endswith((".json", ".jsonl")) and _isfile(p)]


@family("copilot-chat", copilot_chat_files, mode="whole")
def read_copilot_chat(ctx, d, path, offset, limit, settled, sink):
    session = os.path.splitext(os.path.basename(path))[0]
    for index, r in enumerate(_copilot_requests(path)):
        meta = ((r.get("result") or {}).get("metadata")) or {}
        prompt = whole(r["promptTokens"]) if is_number(r.get("promptTokens")) else whole(meta.get("promptTokens"))
        done = whole(r["completionTokens"]) if is_number(r.get("completionTokens")) else whole(meta.get("outputTokens"))
        prompt, done = max(0, prompt), max(0, done)
        if clamp(prompt) + clamp(done) == 0:
            continue
        resolved = (text(meta.get("resolvedModel")) or "").strip(" \t")
        named = (text(r.get("modelId")) or "").strip(" \t")
        if not resolved and not named.startswith("copilot/"):
            continue
        model = next((m for m in (resolved, named[8:] if named.startswith("copilot/") else named) if m), "auto")
        ms = whole(r["timestamp"]) if is_number(r.get("timestamp")) else 0
        stamp = str(ms) if ms > 0 else f"i{index}"
        sink.add(f"copilot-chat:{session}:{stamp}", max(0.0, to_seconds(r.get("timestamp"))), "github-copilot",
                 model, prompt, 0, 0, done, 0)
    return limit


# ---------------------------------------------------------------------------------------------- Continue
# <continue>\dev_data\0.2.0\tokensGenerated.jsonl: one line per generation, no cache counts.

def continue_files(ctx, d):
    return [p for p in (os.path.join(r, "dev_data", "0.2.0", "tokensGenerated.jsonl") for r in ctx.roots(d)) if _isfile(p)]


@family("continue-tokens", continue_files, mode="lines")
def read_continue(ctx, d, path, offset, limit, settled, sink):
    end = offset
    for line, end in iter_lines(path, offset, limit, settled):
        o = loads(line) if line else None
        if not isinstance(o, dict) or not text(o.get("model")):
            continue
        sink.add("continue:" + line_hash(line), to_seconds(o.get("timestamp")), text(o.get("provider")) or "", o["model"],
                 max(0, whole(o.get("promptTokens"))), 0, 0, max(0, whole(o.get("generatedTokens"))), 0)
    return end


# ---------------------------------------------------------------------------------------------- Zed
# <Zed data folder>\threads\threads.db: one row per thread, the thread JSON plain or zstd-compressed. Per-request
# token usage; what the thread's cumulative usage holds beyond them becomes an adjustment row.

def _zed_usage(u):
    u = u if isinstance(u, dict) else {}
    return [max(0, whole(u.get(k))) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens")]


def zed_files(ctx, d):
    return [p for p in (os.path.join(r, "threads", "threads.db") for r in ctx.roots(d)) if _isfile(p)]


@family("zed-threads", zed_files, mode="whole", stamp=db_stamp)
def read_zed(ctx, d, path, offset, limit, settled, sink):
    try:
        with extdb.open_readonly(path) as con:
            columns = {r[1] for r in con.execute("PRAGMA table_info(threads)")}
            created = "created_at" if "created_at" in columns else "NULL"
            rows = con.execute(f"SELECT id, updated_at, {created}, data_type, data FROM threads").fetchall()
    except (sqlite3.Error, OSError) as e:
        sink.issue(f"{path}: {e}")
        return None
    unknown = 0
    unreadable = []                          # threads that could not be unpacked: the thread is lost, not the file
    for tid, updated, made, kind, blob in rows:
        if tid is None:                     # a thread with no id has no key (the Mac reader skips it)
            continue
        kind = (kind or "").strip().lower() if isinstance(kind, str) else ""
        raw = bytes(blob) if isinstance(blob, (bytes, bytearray)) else (blob or "").encode("utf-8", "replace") if isinstance(blob, str) else b""
        if kind == "zstd":
            try:
                raw = extdb.zstd_decompress(raw)
            except extdb.ZstdMissing as e:
                sink.issue(str(e))
                sink.retry = True            # left unrecorded: the whole database is read again once zstd is there
                continue
            except extdb.ZstdTooLarge as e:
                unreadable.append(f"{tid}: unpacked content too large ({e}), not read")
                continue
            except ValueError as e:
                unreadable.append(f"{tid}: {e}")
                continue
        elif kind != "json":
            unknown += 1
            continue
        try:
            # Text, not bytes: json.loads on invalid UTF-8 bytes raises and the thread would be dropped without a word,
            # where the Mac app (J.parse) reads it with U+FFFD for the bad bytes. A BOM is skipped, as json.loads did.
            thread = json.loads(raw.decode("utf-8-sig", "replace"))
        except JSON_ERRORS:
            continue
        if not isinstance(thread, dict):
            continue
        sink.retire(f"zed:adj:{tid}")       # recomputed below; a thread reset to zero (or imported) leaves no old figure
        if thread.get("imported") is True:
            continue
        model = thread.get("model") if isinstance(thread.get("model"), dict) else {}
        name, provider = text(model.get("model")) or "unknown", text(model.get("provider")) or "zed"
        when = 0.0
        for candidate in (made, updated, thread.get("updated_at")):
            if isinstance(candidate, str) and candidate and epoch(candidate):
                when = epoch(candidate)
                break
        reqs = thread.get("request_token_usage")
        pairs = list(reqs.items()) if isinstance(reqs, dict) else list(enumerate(reqs)) if isinstance(reqs, list) else []
        sums = [0, 0, 0, 0]
        for rid, u in pairs:
            c = _zed_usage(u)
            if sum(c) == 0:
                continue
            sums = [a + b for a, b in zip(sums, c)]
            sink.add(f"zed:{tid}:{rid}", when, provider, name, c[0], c[1], c[2], c[3], 0)
        total = _zed_usage(thread.get("cumulative_token_usage"))
        gap = [max(0, a - b) for a, b in zip(total, sums)]
        if sum(gap):
            sink.add(f"zed:adj:{tid}", when, provider, name, gap[0], gap[1], gap[2], gap[3], 0)
    for message in dict.fromkeys(unreadable[:5]):      # the first five, as the Mac app names them
        sink.issue(f"{path}: {message}")
    if len(unreadable) > 5:
        sink.issue(f"{path}: (+{len(unreadable) - 5} more threads)")
    if unknown:
        sink.issue(f"{path}: {unknown} thread(s) with an unknown data_type were skipped")
    return limit
