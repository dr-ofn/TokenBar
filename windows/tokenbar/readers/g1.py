"""Gemini CLI, Pi, GitHub Copilot CLI, Junie, Codebuff, Mistral Vibe, Augment and Qwen Code's chat files."""
from __future__ import annotations

import os
import re

from ..util import (count, epoch, iter_lines, line_hash, load_json_file, loads, read_json_file, text, mtime, walk_files, whole,
                    clamp, is_number, json_lines)
from ..util import longpath
from .base import family
from .core import under


def _json_name(n):
    return n.endswith(".json")


def _in_folder(path, name):
    return (os.sep + name + os.sep) in path or ("/" + name + "/") in path


# ---------------------------------------------------------------------------------------------- Gemini CLI
# <home>\.gemini\tmp\<project>\chats\*.json[l]. A message {"id","type":"gemini","model","tokens"} repeats whenever it
# changes; the last copy stands. tokens.input is the whole prompt (cache inside); output excludes thoughts.

def gemini_files(ctx, d):
    out = []
    for root in ctx.roots(d):
        out += [p for p in walk_files(root, lambda n: n.endswith((".json", ".jsonl"))) if _in_folder(p, "chats")]
    return out


@family("gemini-chats", gemini_files, mode="whole")
def read_gemini(ctx, d, path, offset, limit, settled, sink):
    stem = os.path.splitext(os.path.basename(path))[0]
    records = []
    if path.endswith(".jsonl"):
        for line in json_lines(path):
            r = loads(line)
            if r is not None:
                records.append(r)
    else:
        doc = read_json_file(path)
        if doc is not None:
            records = [doc]
    session, last = None, {}
    for rec in records:
        if not isinstance(rec, dict):
            continue
        if isinstance(rec.get("$set"), dict):
            session = text(rec["$set"].get("sessionId")) or session
            candidates = rec["$set"].get("messages")
        elif "$rewindTo" in rec or "$patch" in rec:
            continue
        elif text(rec.get("id")) and text(rec.get("type")):
            candidates = [rec]
        else:
            session = text(rec.get("sessionId")) or session
            candidates = rec.get("messages")
        for m in candidates if isinstance(candidates, list) else []:
            if not (isinstance(m, dict) and text(m.get("id")) and m.get("type") == "gemini" and isinstance(m.get("tokens"), dict)):
                continue
            t = m["tokens"]
            prompt, cached, thoughts = count(t, "input"), count(t, "cached"), count(t, "thoughts")
            inp = prompt - min(cached, prompt) + count(t, "tool")
            out = count(t, "output") + thoughts
            if inp + cached + out > 0:
                last[m["id"]] = (text(m.get("model")) or "unknown", epoch(m.get("timestamp")), inp, cached, out, thoughts)
    for mid, (model, ts, inp, cr, out, rz) in last.items():
        sink.add(f"gem:{session or stem}:{mid}", ts, "google", model, inp, cr, 0, out, rz)
    return limit


# ---------------------------------------------------------------------------------------------- Pi
# <home>\.pi\agent\sessions\**\*.jsonl. Usage lines as in oh-my-pi; reasoning is part of output, cacheWrite1h part of
# cacheWrite; a call is its responseId, else its own line (a forked session copies lines unchanged).

def _pi_whole(d, key):
    """Pi's lines are read as digits: a value with a decimal point is a cost, not a count, and `true` is no number."""
    v = d.get(key) if isinstance(d, dict) else None
    return count(d, key) if isinstance(v, int) and not isinstance(v, bool) else 0


@family("pi-jsonl", under("sessions", lambda n: n.endswith(".jsonl")), mode="lines")
def read_pi(ctx, d, path, offset, limit, settled, sink):
    end = offset
    for line, end in iter_lines(path, offset, limit, settled):
        if '"usage":{' not in line or '"role":"toolResult"' in line or '"type":"session"' in line[:80]:
            continue
        row = loads(line)
        if not isinstance(row, dict):
            continue
        m = row.get("message") if isinstance(row.get("message"), dict) else row
        u = m.get("usage")
        if not isinstance(u, dict):
            continue
        provider, model = text(m.get("provider")) or "", text(m.get("model")) or "unknown"
        if "/" in model:
            head, tail = model.split("/", 1)
            if not provider or head == provider:
                provider, model = head, tail
        out = _pi_whole(u, "output")
        cw = _pi_whole(u, "cacheWrite")
        rid = text(m.get("responseId"))
        sink.add(f"pi:{rid}" if rid else "pi:line:" + line_hash(line), epoch(row.get("timestamp", m.get("timestamp"))),
                 provider, model, _pi_whole(u, "input"), _pi_whole(u, "cacheRead"), cw, out,
                 min(_pi_whole(u, "reasoning") or _pi_whole(u, "reasoningTokens"), out), min(_pi_whole(u, "cacheWrite1h"), cw))
    return end


# ---------------------------------------------------------------------------------------------- Copilot CLI
# <home>\.copilot\session-state\<session>\events.jsonl. One `session.usage_record` per call; inputTokens holds the
# cache reads and writes. Only a file without records (and without accounting watermarks in its shutdowns) falls
# back to its shutdown metrics.

@family("copilot-events", under("session-state", lambda n: n == "events.jsonl"), mode="whole")
def read_copilot(ctx, d, path, offset, limit, settled, sink):
    session = os.path.basename(os.path.dirname(path))
    records, shutdowns, watermarked = [], [], False
    for line in json_lines(path):
        if '"session.usage_record"' not in line and '"session.shutdown"' not in line:
            continue
        e = loads(line)
        data = e.get("data") if isinstance(e, dict) and isinstance(e.get("data"), dict) else None
        if data is None:
            continue
        ts = epoch(e.get("timestamp"))
        if e.get("type") == "session.usage_record":
            u = data.get("usage")
            if not isinstance(u, dict):
                continue
            acc = u.get("accounting") if isinstance(u.get("accounting"), dict) else {}
            if text(acc.get("sourceSessionId")) and count(acc, "sequence") > 0:
                key = f"cop:{acc['sourceSessionId']}:{count(acc, 'sequence')}"
            elif text(e.get("id")):
                key = f"cop:{session}:e:{e['id']}"
            else:
                key = f"cop:{session}:l:" + line_hash(line)
            records.append((key, ts, text(u.get("model")) or "unknown", u))
        elif e.get("type") == "session.shutdown":
            marks = data.get("usageAccountingWatermarks")
            if isinstance(marks, dict) and any(is_number(v) and whole(v) > 0 for v in marks.values()):
                watermarked = True
            metrics = data.get("modelMetrics") if isinstance(data.get("modelMetrics"), dict) else {}
            for model, value in metrics.items():
                if isinstance(value, dict) and isinstance(value.get("usage"), dict):
                    ident = text(e.get("id")) or str(int(ts))
                    shutdowns.append((f"cop:{session}:sd:{ident}:{model}", ts, model, value["usage"]))
    for key, ts, model, u in (shutdowns if not records and not watermarked else records):
        read, write, out = count(u, "cacheReadTokens"), count(u, "cacheWriteTokens"), count(u, "outputTokens")
        sink.add(key, ts, "github-copilot", model, max(0, count(u, "inputTokens") - read - write), read, write, out,
                 min(count(u, "reasoningTokens"), out))
    return limit


# ---------------------------------------------------------------------------------------------- Junie
# <home>\.junie\sessions\<session>\events.jsonl. A LlmResponseMetadataEvent lists one usage per model call; no event
# id, so a call is its line plus its place in the list.

@family("junie-events", under("sessions", lambda n: n == "events.jsonl"), mode="whole")
def read_junie(ctx, d, path, offset, limit, settled, sink):
    session = os.path.basename(os.path.dirname(path))
    for line in json_lines(path):
        if "LlmResponseMetadataEvent" not in line:
            continue
        e = loads(line)
        event = e.get("event") if isinstance(e, dict) else None
        agent = event.get("agentEvent") if isinstance(event, dict) else None
        if not isinstance(agent, dict) or agent.get("kind") != "LlmResponseMetadataEvent" or not isinstance(agent.get("modelUsage"), list):
            continue
        ms = e.get("timestampMs")
        ts = ms / 1000 if is_number(ms) and ms > 0 and ms < 1e17 else mtime(path)
        for i, u in enumerate(agent["modelUsage"]):
            if not isinstance(u, dict) or not text(u.get("model")):
                continue

            def first(*keys, _u=u):
                return next((count(_u, k) for k in keys if k in _u), 0)
            out = first("outputTokens", "output")
            sink.add(f"jun:{session}:{line_hash(line)}:{i}", ts, (text(u.get("provider")) or "junie").lower(), u["model"],
                     first("inputTokens", "input"), first("cacheInputTokens", "cacheReadInputTokens", "cacheRead"),
                     first("cacheCreateTokens", "cacheCreationInputTokens", "cacheWrite"), out,
                     min(first("reasoningTokens", "reasoningOutputTokens", "thinkingTokens"), out))
    return limit


# ---------------------------------------------------------------------------------------------- Codebuff
# <home>\.config\manicode[-dev|-staging]\projects\**\chats\<chat>\chat-messages.json, a message array. Assistant
# messages carry metadata.usage, metadata.codebuff.usage, or (routed calls) the last assistant entries'
# providerOptions under metadata.runState. The first positive value per field wins.

def chat_ts(chat):
    """`2025-12-14T10-00-00.000Z`: the two dashes after the T are colons."""
    if "T" not in chat:
        return 0.0
    date, rest = chat.split("T", 1)
    return epoch(date + "T" + rest.replace("-", ":", 2))


def _first_pos(d, *keys):
    for k in keys:
        v = count(d, k)
        if v > 0:
            return v
    return 0


def _usage_of(v):
    if not isinstance(v, dict):
        return {}
    u = {"input": _first_pos(v, "inputTokens", "input_tokens", "promptTokens", "prompt_tokens"),
         "output": _first_pos(v, "outputTokens", "output_tokens", "completionTokens", "completion_tokens"),
         "cacheRead": _first_pos(v, "cacheReadInputTokens", "cache_read_input_tokens", "cachedTokensCreated", "cached_tokens_created"),
         "cacheWrite": _first_pos(v, "cacheCreationInputTokens", "cache_creation_input_tokens", "cacheCreationTokens", "cache_creation_tokens"),
         "model": text(v.get("model"))}
    if u["cacheRead"] == 0:
        details = v.get("promptTokensDetails") or v.get("prompt_tokens_details")
        if isinstance(details, dict):
            u["cacheRead"] = count(details, "cachedTokens") if "cachedTokens" in details else count(details, "cached_tokens")
            u["inside"] = u["cacheRead"] > 0
    return u


def _fill(target, other):
    for k in ("input", "output", "cacheWrite"):
        if target.get(k, 0) <= 0:
            target[k] = other.get(k, 0)
    if target.get("cacheRead", 0) <= 0:
        target["cacheRead"] = other.get("cacheRead", 0)
        target["inside"] = other.get("inside", False)
    if target.get("model") is None:
        target["model"] = other.get("model")


def codebuff_files(ctx, d):
    out = []
    for root in ctx.roots(d):
        out += walk_files(os.path.join(root, "projects"), lambda n: n == "chat-messages.json")
    return out


@family("codebuff-chats", codebuff_files, mode="whole")
def read_codebuff(ctx, d, path, offset, limit, settled, sink):
    messages = read_json_file(path)
    parts = re.split(r"[\\/]", path)
    if len(parts) < 6:
        return limit
    chat = parts[-2]
    session = f"{parts[-6]}/{parts[-4]}/{chat}"
    chat_time = chat_ts(chat)
    for ordinal, msg in enumerate(messages if isinstance(messages, list) else []):
        if not isinstance(msg, dict) or (text(msg.get("variant")) or text(msg.get("role")) or "") not in ("ai", "agent", "assistant"):
            continue
        meta = msg.get("metadata") if isinstance(msg.get("metadata"), dict) else {}
        u = {"model": text(meta.get("model"))}
        _fill(u, _usage_of(meta.get("usage")))
        _fill(u, _usage_of((meta.get("codebuff") or {}).get("usage") if isinstance(meta.get("codebuff"), dict) else None))
        try:
            history = meta["runState"]["sessionState"]["mainAgentState"]["messageHistory"]
        except (KeyError, TypeError):
            history = None
        for entry in reversed(history) if isinstance(history, list) else []:
            if not isinstance(entry, dict) or entry.get("role") != "assistant" or not isinstance(entry.get("providerOptions"), dict):
                continue
            options = entry["providerOptions"]
            found = {"model": None}
            _fill(found, _usage_of(options.get("usage")))
            cb = options.get("codebuff") if isinstance(options.get("codebuff"), dict) else {}
            _fill(found, _usage_of(cb.get("usage")))
            found["model"] = text(cb.get("model")) or found["model"]
            _fill(u, found)
        inp, out, cr, cw = (u.get(k, 0) for k in ("input", "output", "cacheRead", "cacheWrite"))
        if not (inp > 0 or out > 0 or cr > 0 or cw > 0):
            continue
        if u.get("inside"):
            inp = max(0, inp - cr)
        ts = epoch(msg.get("timestamp")) or epoch(msg.get("createdAt")) or epoch(meta.get("timestamp")) or chat_time or mtime(path)
        key = f"cbuf:{msg['id']}" if text(msg.get("id")) else f"cbuf:{session}:{ordinal}"   # the counts are not in the key: a half-read message counts once
        sink.add(key, ts, "codebuff", u.get("model") or "codebuff-unknown", inp, cr, cw, out, 0)
    return limit


# ---------------------------------------------------------------------------------------------- Mistral Vibe
# <home>\.vibe\logs\session\session_*\meta.json or flat session_*.json with a "metadata" key. Cumulative per
# session: one row, key vibe:<session>; cached is inside the prompt.

def vibe_files(ctx, d):
    out = []
    for root in ctx.roots(d):
        out += walk_files(os.path.join(root, "logs", "session"), lambda n: n.endswith(".json") and (n == "meta.json" or n.startswith("session_")))
    return out


@family("vibe-sessions", vibe_files, mode="whole")
def read_vibe(ctx, d, path, offset, limit, settled, sink):
    root = read_json_file(path)
    if not isinstance(root, dict):
        return limit
    name = os.path.basename(path)
    meta = root["metadata"] if isinstance(root.get("metadata"), dict) else root
    stats = meta.get("stats")
    if not isinstance(stats, dict):
        return limit
    prompt, cached = count(stats, "session_prompt_tokens"), count(stats, "session_cached_tokens")
    out = count(stats, "session_completion_tokens")
    if max(0, prompt - cached) + cached + out == 0:
        return limit
    fallback = os.path.basename(os.path.dirname(path)) if name == "meta.json" else os.path.splitext(name)[0]
    config = meta.get("config") if isinstance(meta.get("config"), dict) else {}
    model = text(config.get("active_model")) or text(meta.get("active_model")) or text(meta.get("model"))
    if not model:
        models = config.get("models") if isinstance(config.get("models"), dict) else {}
        aliases = sorted(text(v.get("alias") if isinstance(v, dict) else None) or k for k, v in models.items())
        aliases = [a for a in aliases if a]
        model = aliases[0] if len(aliases) == 1 else ("mistral-medium-latest" if not aliases or "mistral-medium-latest" in aliases else aliases[0])
    ts = epoch(meta.get("end_time")) or epoch(meta.get("start_time")) or mtime(path)
    sink.add(f"vibe:{text(meta.get('session_id')) or fallback}", ts, "mistral", model, max(0, prompt - cached), cached, 0, out, 0)
    return limit


# ---------------------------------------------------------------------------------------------- Augment
# <home>\.augment\sessions\<session>.json. Completed turns only; the last non-empty usage of a turn's response nodes
# stands; input and cache are separate buckets.

@family("augment-sessions", under("sessions", _json_name), mode="whole")
def read_augment(ctx, d, path, offset, limit, settled, sink):
    root = read_json_file(path)
    if not isinstance(root, dict):
        return limit
    session = text(root.get("sessionId")) or os.path.splitext(os.path.basename(path))[0]
    default = text((root.get("agentState") or {}).get("modelId")) if isinstance(root.get("agentState"), dict) else None
    history = root.get("chatHistory") if isinstance(root.get("chatHistory"), list) else []
    for index, turn in enumerate(history):
        if not isinstance(turn, dict) or turn.get("completed") is not True or not isinstance(turn.get("exchange"), dict):
            continue
        ex = turn["exchange"]
        usage = None
        nodes = ex.get("response_nodes") if isinstance(ex.get("response_nodes"), list) else []
        for node in reversed(nodes):
            u = node.get("token_usage") if isinstance(node, dict) else None
            if isinstance(u, dict) and sum(count(u, k) for k in ("input_tokens", "cache_read_input_tokens",
                                                                "cache_creation_input_tokens", "output_tokens")) > 0:
                usage = u
                break
        if usage is None:
            continue
        model = text(ex.get("model_id")) or default or "unknown"
        seq = turn.get("sequenceId")
        if text(ex.get("request_id")):
            key = f"aug:{session}:req:{ex['request_id']}"
        elif seq is not None and str(seq) != "":
            key = f"aug:{session}:seq:{seq}"
        else:
            key = f"aug:{session}:turn:{index}"
        sink.add(key, epoch(turn.get("finishedAt")) or mtime(path), "anthropic" if model.startswith("claude") else "augment",
                 model, count(usage, "input_tokens"), count(usage, "cache_read_input_tokens"),
                 count(usage, "cache_creation_input_tokens"), count(usage, "output_tokens"), 0)
    return limit


# ---------------------------------------------------------------------------------------------- Qwen Code chats
# <home>\.qwen\projects\**\chats\*.jsonl, read only where Qwen's own accounting (usage\token-usage-*.jsonl,
# usage_record.jsonl) is absent, or the same calls would count twice.

def _qwen_keeps_own_accounting(base):
    return os.path.exists(longpath(os.path.join(base, "usage_record.jsonl"))) or bool(walk_files(
        os.path.join(base, "usage"), lambda n: n.startswith("token-usage-") and n.endswith(".jsonl")))


def qwen_chat_files(ctx, d):
    out = []
    for base in ctx.roots(d):
        if _qwen_keeps_own_accounting(base):
            continue
        out += [p for p in walk_files(os.path.join(base, "projects"), lambda n: n.endswith(".jsonl")) if _in_folder(p, "chats")]
    return out


def qwen_chats_after(ctx, d, store, changed):
    """Qwen's own usage files appeared after the chat rows were counted: they are the same calls, so the chat rows go."""
    if any(_qwen_keeps_own_accounting(b) for b in ctx.roots(d)) and store.has_prefix("qwenc:"):
        store.replace_prefix("qwenc:", [])


@family("qwen-chats", qwen_chat_files, mode="whole", after=qwen_chats_after)
def read_qwen_chats(ctx, d, path, offset, limit, settled, sink):
    parts = re.split(r"[\\/]", path)
    fallback = f"{parts[-3]}-{os.path.splitext(parts[-1])[0]}" if len(parts) >= 3 else os.path.basename(path)
    for line in json_lines(path):
        if '"usageMetadata"' not in line:
            continue
        e = loads(line)
        u = e.get("usageMetadata") if isinstance(e, dict) else None
        if not isinstance(e, dict) or e.get("type") != "assistant" or not isinstance(u, dict):
            continue
        prompt, cand, thoughts, cached = (count(u, k) for k in
                                          ("promptTokenCount", "candidatesTokenCount", "thoughtsTokenCount", "cachedContentTokenCount"))
        total = u.get("totalTokenCount")
        inside = False
        if thoughts > 0 and is_number(total):
            inside = cand > 0 if total == 0 else total == prompt + cand
        session = text(e.get("sessionId")) or fallback
        ident = text(e.get("uuid")) or "l" + line_hash(line)
        sink.add(f"qwenc:{session}:{ident}", epoch(e.get("timestamp")), "qwen", text(e.get("model")) or "unknown",
                 prompt - cached if cached <= prompt else prompt, cached, 0,
                 cand if inside else cand + thoughts, min(thoughts, cand) if inside else thoughts)
    return limit
