"""Reference counts for the group-1 tools, sharing no code with the Swift scanners.

Gemini CLI, Pi, GitHub Copilot CLI, Junie, Codebuff, Mistral Vibe, Augment, and Qwen Code's chat
files. `oracle.py` imports this and calls `run(oracle)` with its own module, so the rows land in the
same `best` table and the same report. Each function says in a line what the tool's format means.
"""
import glob
import hashlib
import os
from datetime import datetime, timezone
import json

HARNESS = {"gem": "gemini-cli", "pi": "pi", "cop": "copilot-cli", "jun": "junie", "cbuf": "codebuff",
           "vibe": "mistral-vibe", "aug": "augment", "qwenc": "qwen-code"}


def sha(text):
    return hashlib.sha1(text.encode("utf-8", "replace")).hexdigest()


def text(v):
    """A non-empty string, else None."""
    return v if isinstance(v, str) and v else None


def count(d, key):
    """A count held at zero or above; a fraction is cut off, as the Swift reader's JSON number is."""
    v = d.get(key) if isinstance(d, dict) else None
    if isinstance(v, bool):
        return int(v)
    return min(max(int(v), 0), 2 ** 61) if isinstance(v, (int, float)) else 0


def whole(d, key):
    """Pi's lines are read as digits: a value with a decimal point is a cost, not a count."""
    v = d.get(key) if isinstance(d, dict) else None
    return count(d, key) if isinstance(v, int) else 0


def when(v):
    """Unix seconds from a number (milliseconds above 1e11) or an ISO string; no zone means UTC."""
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return v / 1000 if v > 1e11 else float(v)
    if isinstance(v, str) and v:
        try:
            t = datetime.fromisoformat(v.replace("Z", "+00:00"))
        except ValueError:
            return 0.0
        return (t if t.tzinfo else t.replace(tzinfo=timezone.utc)).timestamp()
    return 0.0


def json_lines(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.strip():
                yield line


def files(pattern):
    return [p for p in glob.iglob(pattern, recursive=True) if os.path.isfile(p)]


def claude_files(o):
    """Claude Code transcripts: `$CLAUDE_CONFIG_DIR` (else `~/.claude`) and the XDG folder `claude`, subagent files included."""
    seen = set()
    for base in (o.root(".claude", "CLAUDE_CONFIG_DIR"), o.root(".config", "XDG_CONFIG_HOME", "claude")):
        for path in glob.iglob(base + "/projects/**/*.jsonl", recursive=True):
            if path not in seen:
                seen.add(path)
                yield path


def run(o):
    gemini(o)
    pi(o)
    copilot(o)
    junie(o)
    codebuff(o)
    vibe(o)
    augment(o)
    qwen_chats(o)


# Gemini CLI: ~/.gemini/tmp/<project>/chats/*.json[l]. $GEMINI_CLI_HOME replaces the home folder.
# A message {"id","type":"gemini","model","tokens"} repeats whenever it changes; the last copy
# stands. tokens.input is the whole prompt (cache inside); output excludes thoughts.
def gemini(o):
    home = o.ENV.get("GEMINI_CLI_HOME") or o.HOME
    for path in files(home + "/.gemini/tmp/**/*"):
        if "/chats/" not in path or not path.endswith((".json", ".jsonl")):
            continue
        stem = os.path.splitext(os.path.basename(path))[0]
        if path.endswith(".jsonl"):
            records = []
            for line in json_lines(path):
                try:
                    records.append(json.loads(line))
                except ValueError:
                    pass
        else:
            try:
                records = [json.load(open(path, encoding="utf-8"))]
            except ValueError:
                records = []
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
                if not (isinstance(m, dict) and text(m.get("id")) and m.get("type") == "gemini"
                        and isinstance(m.get("tokens"), dict)):
                    continue
                t = m["tokens"]
                prompt, cached, thoughts = count(t, "input"), count(t, "cached"), count(t, "thoughts")
                inp = prompt - min(cached, prompt) + count(t, "tool")
                out = count(t, "output") + thoughts
                if inp + cached + out > 0:
                    last[m["id"]] = (text(m.get("model")) or "unknown", when(m.get("timestamp")), inp, cached, out, thoughts)
        for mid, (model, ts, inp, cr, out, rz) in last.items():
            o.add(f"gem:{session or stem}:{mid}", ts, "google", model, inp, cr, 0, out, rz)


# Pi: ~/.pi/agent/sessions/**.jsonl ($PI_CODING_AGENT_DIR is the agent folder). Usage lines as in
# oh-my-pi; reasoning is part of output, cacheWrite1h part of cacheWrite; a call is its responseId,
# else its own line (a forked session copies lines unchanged).
def pi(o):
    agent = o.ENV.get("PI_CODING_AGENT_DIR")
    agent = (o.HOME + "/" + agent[2:] if agent.startswith("~/") else agent) if agent else o.HOME + "/.pi/agent"
    for path in files(agent.rstrip("/") + "/sessions/**/*.jsonl"):
        for line in json_lines(path):
            if '"usage":{' not in line or '"role":"toolResult"' in line or '"type":"session"' in line[:80]:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            m = row.get("message") if isinstance(row.get("message"), dict) else row
            u = m.get("usage") if isinstance(m, dict) else None
            if not isinstance(u, dict):
                continue
            provider, model = m.get("provider") or "", m.get("model") or "unknown"
            if "/" in model:
                head, tail = model.split("/", 1)
                if not provider or head == provider:
                    provider, model = head, tail
            out = whole(u, "output")
            cw = whole(u, "cacheWrite")
            rid = text(m.get("responseId"))
            o.add(f"pi:{rid}" if rid else "pi:line:" + sha(line.rstrip("\r\n")), o.epoch(row.get("timestamp", m.get("timestamp"))),
                  provider, model, whole(u, "input"), whole(u, "cacheRead"), cw, out,
                  min(whole(u, "reasoning") or whole(u, "reasoningTokens"), out), min(whole(u, "cacheWrite1h"), cw))


# GitHub Copilot CLI: ~/.copilot/session-state/<session>/events.jsonl ($COPILOT_HOME). One
# `session.usage_record` per call; inputTokens holds the cache reads and writes. Only a file without
# records (and without accounting watermarks in its shutdowns) falls back to its shutdown metrics.
def copilot(o):
    base = o.ENV.get("COPILOT_HOME") or o.HOME + "/.copilot"
    for path in files(base.rstrip("/") + "/session-state/**/events.jsonl"):
        session = os.path.basename(os.path.dirname(path))
        records, shutdowns, watermarked = [], [], False
        for line in json_lines(path):
            if '"session.usage_record"' not in line and '"session.shutdown"' not in line:
                continue
            try:
                e = json.loads(line)
            except ValueError:
                continue
            data = e.get("data") if isinstance(e, dict) and isinstance(e.get("data"), dict) else None
            if data is None:
                continue
            ts = when(e.get("timestamp"))
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
                    key = f"cop:{session}:l:" + sha(line.rstrip("\r\n"))
                records.append((key, ts, text(u.get("model")) or "unknown", u))
            elif e.get("type") == "session.shutdown":
                marks = data.get("usageAccountingWatermarks")
                if isinstance(marks, dict) and any(isinstance(v, (int, float)) and int(v) > 0 for v in marks.values()):
                    watermarked = True
                metrics = data.get("modelMetrics") if isinstance(data.get("modelMetrics"), dict) else {}
                for model, value in metrics.items():
                    if isinstance(value, dict) and isinstance(value.get("usage"), dict):
                        ident = text(e.get("id")) or str(int(ts))
                        shutdowns.append((f"cop:{session}:sd:{ident}:{model}", ts, model, value["usage"]))
        for key, ts, model, u in (shutdowns if not records and not watermarked else records):
            read, write, out = count(u, "cacheReadTokens"), count(u, "cacheWriteTokens"), count(u, "outputTokens")
            o.add(key, ts, "github-copilot", model, max(0, count(u, "inputTokens") - read - write), read, write, out,
                  min(count(u, "reasoningTokens"), out))


# Junie: ~/.junie/sessions/<session>/events.jsonl. A LlmResponseMetadataEvent lists one usage per
# model call; no event id, so a call is its line plus its place in the list.
def junie(o):
    for path in files(o.HOME + "/.junie/sessions/**/events.jsonl"):
        session = os.path.basename(os.path.dirname(path))
        for line in json_lines(path):
            if "LlmResponseMetadataEvent" not in line:
                continue
            try:
                e = json.loads(line)
            except ValueError:
                continue
            event = e.get("event") if isinstance(e, dict) else None
            agent = event.get("agentEvent") if isinstance(event, dict) else None
            if not isinstance(agent, dict) or agent.get("kind") != "LlmResponseMetadataEvent" or not isinstance(agent.get("modelUsage"), list):
                continue
            ms = e.get("timestampMs")
            ts = ms / 1000 if isinstance(ms, (int, float)) and not isinstance(ms, bool) and ms > 0 else os.path.getmtime(path)
            for i, u in enumerate(agent["modelUsage"]):
                if not isinstance(u, dict) or not text(u.get("model")):
                    continue

                def first(*keys):
                    return next((count(u, k) for k in keys if k in u), 0)
                out = first("outputTokens", "output")
                o.add(f"jun:{session}:{sha(line.rstrip(chr(13) + chr(10)))}:{i}", ts, (text(u.get("provider")) or "junie").lower(),
                      u["model"], first("inputTokens", "input"), first("cacheInputTokens", "cacheReadInputTokens", "cacheRead"),
                      first("cacheCreateTokens", "cacheCreationInputTokens", "cacheWrite"), out,
                      min(first("reasoningTokens", "reasoningOutputTokens", "thinkingTokens"), out))


# Codebuff: ~/.config/manicode[-dev|-staging]/projects/**/chats/<chat>/chat-messages.json, a message
# array. Assistant messages carry metadata.usage, metadata.codebuff.usage, or (routed calls) the last
# assistant entries' providerOptions under metadata.runState. First positive value per field wins.
def codebuff(o):
    data_dir = o.ENV.get("CODEBUFF_DATA_DIR")
    data_dir = (o.HOME + "/" + data_dir[2:] if data_dir.startswith("~/") else data_dir).rstrip("/") if data_dir else None
    for base in [data_dir] if data_dir else [f"{o.HOME}/.config/{c}" for c in ("manicode", "manicode-dev", "manicode-staging")]:
        for path in files(f"{base}/projects/**/chat-messages.json"):
            try:
                messages = json.load(open(path, encoding="utf-8"))
            except ValueError:
                continue
            parts = path.split("/")
            chat = parts[-2]
            session = f"{parts[-6]}/{parts[-4]}/{chat}"
            chat_time = chat_ts(chat)
            for ordinal, msg in enumerate(messages if isinstance(messages, list) else []):
                if not isinstance(msg, dict) or (text(msg.get("variant")) or text(msg.get("role")) or "") not in ("ai", "agent", "assistant"):
                    continue
                meta = msg.get("metadata") if isinstance(msg.get("metadata"), dict) else {}
                u = {"model": text(meta.get("model"))}
                fill(u, usage_of(meta.get("usage")))
                fill(u, usage_of((meta.get("codebuff") or {}).get("usage") if isinstance(meta.get("codebuff"), dict) else None))
                try:
                    history = meta["runState"]["sessionState"]["mainAgentState"]["messageHistory"]
                except (KeyError, TypeError):
                    history = None
                for entry in reversed(history) if isinstance(history, list) else []:
                    if not isinstance(entry, dict) or entry.get("role") != "assistant" or not isinstance(entry.get("providerOptions"), dict):
                        continue
                    options = entry["providerOptions"]
                    found = {"model": None}
                    fill(found, usage_of(options.get("usage")))
                    cb = options.get("codebuff") if isinstance(options.get("codebuff"), dict) else {}
                    fill(found, usage_of(cb.get("usage")))
                    found["model"] = text(cb.get("model")) or found["model"]
                    fill(u, found)
                inp, out, cr, cw = (u.get(k, 0) for k in ("input", "output", "cacheRead", "cacheWrite"))
                if not (inp > 0 or out > 0 or cr > 0 or cw > 0):
                    continue
                if u.get("inside"):
                    inp = max(0, inp - cr)
                ts = when(msg.get("timestamp")) or when(msg.get("createdAt")) or when(meta.get("timestamp")) or chat_time or os.path.getmtime(path)
                key = f"cbuf:{msg['id']}" if text(msg.get("id")) else f"cbuf:{session}:{ordinal}"
                o.add(key, ts, "codebuff", u.get("model") or "codebuff-unknown", inp, cr, cw, out, 0)


def chat_ts(chat):
    """`2025-12-14T10-00-00.000Z`: the two dashes after the T are colons."""
    if "T" not in chat:
        return 0.0
    date, rest = chat.split("T", 1)
    return when(date + "T" + rest.replace("-", ":", 2))


def first_pos(d, *keys):
    for k in keys:
        v = count(d, k)
        if v > 0:
            return v
    return 0


def usage_of(v):
    if not isinstance(v, dict):
        return {}
    u = {"input": first_pos(v, "inputTokens", "input_tokens", "promptTokens", "prompt_tokens"),
         "output": first_pos(v, "outputTokens", "output_tokens", "completionTokens", "completion_tokens"),
         "cacheRead": first_pos(v, "cacheReadInputTokens", "cache_read_input_tokens", "cachedTokensCreated", "cached_tokens_created"),
         "cacheWrite": first_pos(v, "cacheCreationInputTokens", "cache_creation_input_tokens", "cacheCreationTokens", "cache_creation_tokens"),
         "model": text(v.get("model"))}
    if u["cacheRead"] == 0:
        details = v.get("promptTokensDetails") or v.get("prompt_tokens_details")
        if isinstance(details, dict):
            u["cacheRead"] = max(count(details, "cachedTokens"), 0) if "cachedTokens" in details else count(details, "cached_tokens")
            u["inside"] = u["cacheRead"] > 0
    return u


def fill(target, other):
    for k in ("input", "output", "cacheWrite"):
        if target.get(k, 0) <= 0:
            target[k] = other.get(k, 0)
    if target.get("cacheRead", 0) <= 0:
        target["cacheRead"] = other.get("cacheRead", 0)
        target["inside"] = other.get("inside", False)
    if target.get("model") is None:
        target["model"] = other.get("model")


# Mistral Vibe: ~/.vibe/logs/session/session_*/meta.json ($VIBE_HOME) or flat session_*.json with a
# "metadata" key. Cumulative per session: one row, key vibe:<session>; cached is inside the prompt.
def vibe(o):
    base = o.ENV.get("VIBE_HOME") or o.HOME + "/.vibe"
    for path in files(base.rstrip("/") + "/logs/session/**/*.json"):
        name = os.path.basename(path)
        if not (name == "meta.json" or name.startswith("session_")):
            continue
        try:
            root = json.load(open(path, encoding="utf-8"))
        except ValueError:
            continue
        if not isinstance(root, dict):
            continue
        meta = root["metadata"] if isinstance(root.get("metadata"), dict) else root
        stats = meta.get("stats")
        if not isinstance(stats, dict):
            continue
        prompt, cached = count(stats, "session_prompt_tokens"), count(stats, "session_cached_tokens")
        out = count(stats, "session_completion_tokens")
        if max(0, prompt - cached) + cached + out == 0:
            continue
        fallback = os.path.basename(os.path.dirname(path)) if name == "meta.json" else os.path.splitext(name)[0]
        config = meta.get("config") if isinstance(meta.get("config"), dict) else {}
        model = text(config.get("active_model")) or text(meta.get("active_model")) or text(meta.get("model"))
        if not model:
            models = config.get("models") if isinstance(config.get("models"), dict) else {}
            aliases = sorted(text(v.get("alias") if isinstance(v, dict) else None) or k for k, v in models.items())
            aliases = [a for a in aliases if a]
            model = aliases[0] if len(aliases) == 1 else ("mistral-medium-latest" if not aliases or "mistral-medium-latest" in aliases else aliases[0])
        ts = when(meta.get("end_time")) or when(meta.get("start_time")) or os.path.getmtime(path)
        o.add(f"vibe:{text(meta.get('session_id')) or fallback}", ts, "mistral", model, max(0, prompt - cached), cached, 0, out, 0)


# Augment: ~/.augment/sessions/<session>.json. Completed turns only; the last non-empty usage of a
# turn's response nodes stands; input and cache are separate buckets.
def augment(o):
    for path in files(o.HOME + "/.augment/sessions/**/*.json"):
        try:
            root = json.load(open(path, encoding="utf-8"))
        except ValueError:
            continue
        if not isinstance(root, dict):
            continue
        session = text(root.get("sessionId")) or os.path.splitext(os.path.basename(path))[0]
        default = text((root.get("agentState") or {}).get("modelId")) if isinstance(root.get("agentState"), dict) else None
        for index, turn in enumerate(root.get("chatHistory") if isinstance(root.get("chatHistory"), list) else []):
            if not isinstance(turn, dict) or turn.get("completed") is not True or not isinstance(turn.get("exchange"), dict):
                continue
            ex = turn["exchange"]
            usage = None
            for node in reversed(ex.get("response_nodes") if isinstance(ex.get("response_nodes"), list) else []):
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
            o.add(key, when(turn.get("finishedAt")) or os.path.getmtime(path), "anthropic" if model.startswith("claude") else "augment",
                  model, count(usage, "input_tokens"), count(usage, "cache_read_input_tokens"),
                  count(usage, "cache_creation_input_tokens"), count(usage, "output_tokens"), 0)


# Qwen Code chat files: ~/.qwen/projects/**/chats/*.jsonl, read only where Qwen's own accounting
# (usage/token-usage-*.jsonl, usage_record.jsonl) is absent, or the same calls would count twice.
def qwen_chats(o):
    base = o.root(".qwen", "QWEN_HOME")
    if os.path.exists(base + "/usage_record.jsonl") or glob.glob(base + "/usage/token-usage-*.jsonl"):
        return
    for path in files(base + "/projects/**/*.jsonl"):
        if "/chats/" not in path:
            continue
        parts = path.split("/")
        fallback = f"{parts[-3]}-{os.path.splitext(parts[-1])[0]}"
        for line in json_lines(path):
            if '"usageMetadata"' not in line:
                continue
            try:
                e = json.loads(line)
            except ValueError:
                continue
            u = e.get("usageMetadata") if isinstance(e, dict) else None
            if e.get("type") != "assistant" or not isinstance(u, dict):
                continue
            prompt, cand, thoughts, cached = (count(u, k) for k in
                                              ("promptTokenCount", "candidatesTokenCount", "thoughtsTokenCount", "cachedContentTokenCount"))
            total = u.get("totalTokenCount")
            inside = False
            if thoughts > 0 and isinstance(total, (int, float)) and not isinstance(total, bool):
                inside = cand > 0 if total == 0 else total == prompt + cand
            session = text(e.get("sessionId")) or fallback
            ident = text(e.get("uuid")) or "l" + sha(line.rstrip("\r\n"))
            o.add(f"qwenc:{session}:{ident}", when(e.get("timestamp")), "qwen", text(e.get("model")) or "unknown",
                  prompt - cached if cached <= prompt else prompt, cached, 0,
                  cand if inside else cand + thoughts, min(thoughts, cand) if inside else thoughts)
