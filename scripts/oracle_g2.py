"""Oracle for the editor extensions and IDEs (group G2): Cline, Roo Code, Kilo Code, Copilot Chat,
Continue and Zed. Written apart from the Swift readers and sharing no code with them; oracle.py hands
in its own `add` (which keeps the row with the largest token total for a repeated key), `opencode`
(the opencode-schema reader, used for Kilo's databases), `root`, `HOME`, `epoch` and `num`.

Tools found but never counted (Kiro, Cursor, Windsurf, Trae) are not here: nothing is read for them.

What each tool's rows mean is written at the Swift parsers (Sources/LocalCore/Parsers/*): Cline keeps
`tokensIn` apart from the cache counts; Roo Code and Kilo Code hold them inside `tokensIn` from
2025-11-02T00:00:00Z on (before that only on the OpenAI protocol); Cline CLI's `inputTokens` holds them.
"""
import glob
import hashlib
import json
import os
import re
import sqlite3
import subprocess

import oracle_db

# dedup-key prefix -> harness, merged into oracle.py's table
HARNESS = {"cline": "cline", "roo": "roo-code", "kilocode": "kilo-code", "kilo": "kilo-code",
           "copilot-chat": "copilot-chat", "continue": "continue", "zed": "zed"}

EDITORS = ["Code", "Code - Insiders", "Cursor", "Windsurf", "VSCodium", "Kiro", "Positron", "Trae", "Antigravity"]
WHOLE_PROMPT_FROM_MS = 1_762_041_600_000  # 2025-11-02T00:00:00Z


def number(v):
    return isinstance(v, (int, float))


def whole(v):
    """A JSON number as the scanner reads it: truncated, and 0 for anything else."""
    return int(v) if number(v) else 0


def text(v):
    return v if isinstance(v, str) and v else None


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def to_seconds(v):
    if not number(v):
        return 0.0
    return v / 1000 if v > 1e11 else float(v)


def extension_roots(HOME, ext):
    return [f"{HOME}/Library/Application Support/{e}/User/globalStorage/{ext}" for e in EDITORS]


# MARK: Cline, Roo Code, Kilo Code task logs

def read_task_hints(folder):
    """(model switches, last <model> tag) of a task folder, as the sibling files name them."""
    switches = []
    meta = load(folder + "/task_metadata.json")
    if isinstance(meta, dict):
        for use in meta.get("model_usage") or []:
            if isinstance(use, dict) and text(use.get("model_id")):
                ts = use.get("ts") if number(use.get("ts")) else 0
                switches.append((ts * 1000 if ts < 1e11 else ts, use["model_id"], text(use.get("model_provider_id"))))
    tag = None
    if not switches:
        try:
            raw = open(folder + "/api_conversation_history.json", encoding="utf-8", errors="replace").read()
        except OSError:
            raw = ""
        for m in re.finditer(r"<model>(.*?)</model>", raw, re.S):
            if m.group(1).strip():
                tag = m.group(1).strip()
    return switches, tag


def task_log(add, path, prefix, roo, mtime):
    rows = load(path)
    if not isinstance(rows, list):
        return
    folder = os.path.dirname(path)
    task = os.path.basename(folder)
    hints = None
    seen = {}
    for index, row in enumerate(rows):
        if not isinstance(row, dict) or row.get("type") != "say" or row.get("say") not in ("api_req_started", "deleted_api_reqs"):
            continue
        raw = row.get("text")
        if not isinstance(raw, str) or not raw:
            continue
        try:
            p = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(p, dict):
            continue
        ms = None
        if number(row.get("ts")):
            ms = row["ts"] * 1000 if row["ts"] < 1e11 else row["ts"]
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
        if inp + cr + cw + out == 0:
            continue
        info = row.get("modelInfo") if isinstance(row.get("modelInfo"), dict) else {}
        model, provider = text(info.get("modelId")), text(info.get("providerId"))
        if model is None:
            if hints is None:
                hints = read_task_hints(folder)
            earlier = [s for s in hints[0] if s[0] <= (ms or 0)]
            if earlier:
                model, provider = earlier[-1][1], provider or earlier[-1][2]
            else:
                model = hints[1]
        model = model or "unknown"
        if provider is None:
            provider = model.split("/")[0] if "/" in model else (proto or "")
        stamp = str(int(ms)) if ms is not None else f"i{index}"
        key = f"{prefix}:{task}:{'del:' if row['say'] == 'deleted_api_reqs' else ''}{stamp}"
        seen[key] = seen.get(key, 0) + 1
        if seen[key] > 1:
            key += f":{seen[key]}"
        add(key, ms / 1000 if ms is not None else mtime, provider, model, inp, cr, cw, out, 0)


def cline_cli(add, path, prefix, mtime):
    folder = os.path.dirname(path)
    name = os.path.basename(folder)
    doc = load(path)
    if not isinstance(doc, dict):
        return
    head = load(f"{folder}/{name}.json")
    head = head if isinstance(head, dict) else {}
    session = text(doc.get("sessionId")) or text(head.get("session_id")) or name
    model, provider = text(head.get("model")) or "unknown", text(head.get("provider")) or ""
    ordinal = 0
    for m in doc.get("messages") or []:
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
        if inp + cr + cw + out == 0:
            continue
        ts = to_seconds(m.get("ts")) if number(m.get("ts")) else 0.0
        add(f"{prefix}:{session}:{text(m.get('id')) or mine}", ts if ts > 0 else mtime, provider, model, inp, cr, cw, out, 0)


def tasks(add, HOME):
    for ext, prefix, roo in (("saoudrizwan.claude-dev", "cline", False), ("rooveterinaryinc.roo-cline", "roo", True),
                             ("kilocode.kilo-code", "kilocode", True)):
        roots = extension_roots(HOME, ext) + ([HOME + "/.cline/data"] if prefix == "cline" else [])
        for r in roots:
            for path in sorted(glob.glob(glob.escape(r) + "/tasks/*/ui_messages.json")):
                task_log(add, path, prefix, roo, os.path.getmtime(path))
            if prefix == "cline":
                for path in sorted(glob.glob(glob.escape(r) + "/sessions/*/*.messages.json")):
                    folder = os.path.basename(os.path.dirname(path))
                    if os.path.basename(path) == folder + ".messages.json":
                        cline_cli(add, path, prefix, os.path.getmtime(path))


# MARK: Copilot Chat

def index_of(v):
    return int(v) if number(v) else None


def set_path(target, path, value):
    """The value at `path` inside `target`; objects and arrays are made on the way, a bad step changes nothing."""
    if not path:
        return value
    head, rest = path[0], path[1:]
    if isinstance(head, str):
        obj = target if isinstance(target, dict) else {}
        child = obj.get(head, {})
        obj[head] = set_path(child, rest, value)
        return obj
    i = index_of(head)
    if i is not None and 0 <= i <= 4096:
        arr = target if isinstance(target, list) else []
        while len(arr) <= i:
            arr.append(None)
        arr[i] = set_path(arr[i], rest, value)
        return arr
    return target


def prune(r):
    if not isinstance(r, dict):
        return {}
    out = {k: r[k] for k in ("promptTokens", "completionTokens", "timestamp", "modelId") if k in r}
    result = r.get("result")
    meta = result.get("metadata") if isinstance(result, dict) else None
    if isinstance(meta, dict):
        out["result"] = {"metadata": {k: meta[k] for k in ("promptTokens", "outputTokens", "resolvedModel") if k in meta}}
    return out


def copilot_requests(path):
    reqs = []
    if path.endswith(".jsonl"):
        for line in open(path, encoding="utf-8", errors="replace"):
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if not isinstance(o, dict) or not number(o.get("kind")):
                continue
            kind, k = int(o["kind"]), o.get("k")
            if kind == 0:
                v = o.get("v")
                if isinstance(v, dict) and isinstance(v.get("requests"), list):
                    # A snapshot is the whole document as it stands: it replaces the requests read so far.
                    reqs = [prune(r) for r in v["requests"]]
            elif kind == 1:
                if not (isinstance(k, list) and len(k) >= 2 and k[0] == "requests" and "v" in o):
                    continue
                i = index_of(k[1])
                if i is None or not 0 <= i < len(reqs):
                    continue
                reqs[i] = prune(set_path(reqs[i], k[2:], o["v"]))
            elif kind == 2:
                if isinstance(k, list) and k == ["requests"] and isinstance(o.get("v"), list):
                    reqs += [prune(r) for r in o["v"]]
    else:
        doc = load(path)
        if isinstance(doc, dict) and isinstance(doc.get("requests"), list):
            reqs = [prune(r) for r in doc["requests"]]
    return reqs


def copilot(add, HOME):
    files = []
    for editor in ("Code", "Code - Insiders"):
        base = f"{HOME}/Library/Application Support/{editor}/User"
        files += glob.glob(glob.escape(base) + "/workspaceStorage/*/chatSessions/*")
        files += glob.glob(glob.escape(base) + "/globalStorage/emptyWindowChatSessions/*")
    for path in files:
        if not (path.endswith(".jsonl") or path.endswith(".json")) or not os.path.isfile(path):
            continue
        session = os.path.splitext(os.path.basename(path))[0]
        for index, r in enumerate(copilot_requests(path)):
            meta = ((r.get("result") or {}).get("metadata")) or {}
            prompt = r["promptTokens"] if number(r.get("promptTokens")) else whole(meta.get("promptTokens"))
            done = r["completionTokens"] if number(r.get("completionTokens")) else whole(meta.get("outputTokens"))
            prompt, done = max(0, int(prompt)), max(0, int(done))
            if prompt + done == 0:
                continue
            resolved = (text(meta.get("resolvedModel")) or "").strip(" \t")
            named = (text(r.get("modelId")) or "").strip(" \t")
            if not resolved and not named.startswith("copilot/"):
                continue
            model = next((m for m in (resolved, named[8:] if named.startswith("copilot/") else named) if m), "auto")
            ms = r["timestamp"] if number(r.get("timestamp")) else 0
            stamp = str(int(ms)) if ms > 0 else f"i{index}"
            add(f"copilot-chat:{session}:{stamp}", to_seconds(ms), "github-copilot", model, prompt, 0, 0, done, 0)


# MARK: Continue

def continue_dev(add, root):
    path = root(".continue", "CONTINUE_GLOBAL_DIR") + "/dev_data/0.2.0/tokensGenerated.jsonl"
    if not os.path.isfile(path):
        return
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n").rstrip("\r")
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if not isinstance(o, dict) or not text(o.get("model")):
            continue
        add("continue:" + hashlib.sha1(line.encode()).hexdigest(), to_seconds(o["timestamp"]) if number(o.get("timestamp")) else 0.0,
            text(o.get("provider")) or "", o["model"], max(0, whole(o.get("promptTokens"))), 0, 0, max(0, whole(o.get("generatedTokens"))), 0)


# MARK: Zed

def zed_usage(u):
    u = u if isinstance(u, dict) else {}
    return [max(0, whole(u.get(k))) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens")]


def zed(add, HOME, epoch):
    path = HOME + "/Library/Application Support/Zed/threads/threads.db"
    if not os.path.isfile(path):
        return
    try:
        with oracle_db.readonly(path) as con:
            columns = {r[1] for r in con.execute("PRAGMA table_info(threads)")}
            created = "created_at" if "created_at" in columns else "NULL"
            rows = con.execute(f"SELECT id, updated_at, {created}, data_type, data FROM threads").fetchall()
    except sqlite3.Error:
        return
    for tid, updated, made, kind, blob in rows:
        kind = (kind or "").strip().lower()
        raw = bytes(blob or b"")
        if kind == "zstd":
            try:
                proc = subprocess.run(["zstd", "-dc"], input=raw, capture_output=True)
            except OSError:
                continue  # no zstd on this machine: the thread is left unread, as the app leaves it
            if proc.returncode != 0:
                continue
            raw = proc.stdout
        elif kind != "json":
            continue
        try:
            thread = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(thread, dict) or thread.get("imported") is True:
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
            c = zed_usage(u)
            if sum(c) == 0:
                continue
            sums = [a + b for a, b in zip(sums, c)]
            add(f"zed:{tid}:{rid}", when, provider, name, c[0], c[1], c[2], c[3], 0)
        total = zed_usage(thread.get("cumulative_token_usage"))
        gap = [max(0, a - b) for a, b in zip(total, sums)]
        if sum(gap):
            add(f"zed:adj:{tid}", when, provider, name, gap[0], gap[1], gap[2], gap[3], 0)


def collect(add, opencode, root, HOME, epoch, num):
    tasks(add, HOME)
    kilo = root(".local/share", "XDG_DATA_HOME", "kilo")
    if os.path.isdir(kilo):
        for db in sorted(glob.glob(glob.escape(kilo) + "/kilo*.db")):
            name = os.path.basename(db)
            if name == "kilo.db" or (name.startswith("kilo-") and name.endswith(".db")):
                opencode(db, "kilo")
    copilot(add, HOME)
    continue_dev(add, root)
    zed(add, HOME, epoch)
