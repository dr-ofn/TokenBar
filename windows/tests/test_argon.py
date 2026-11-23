"""Each defect the independent review found in the Mac app's reference scripts and Swift code, in its correct form here."""
import json
import os
import shutil
import sqlite3

import pytest

from conftest import claude_line
from tokenbar.prices.engine import display, parse_aliases, Pricer
from tokenbar.prices.book import PriceBook, load_tables
from tokenbar.report import to_json
from tokenbar import extdb


def listing(folder):
    return sorted(os.listdir(folder))


# (a) Copilot Chat: a second kind:0 snapshot replaces the request list ---------------------------------------------
def test_copilot_chat_second_snapshot_replaces_requests(home):
    req = {"promptTokens": 4, "completionTokens": 2, "timestamp": 1793968800000, "modelId": "copilot/gpt-6-luna"}
    other = {"promptTokens": 9, "completionTokens": 1, "timestamp": 1793968900000, "modelId": "copilot/gpt-6-luna"}
    home.jsonl("AppData/Roaming/Code/User/workspaceStorage/w/chatSessions/s.jsonl",
               {"kind": 0, "v": {"requests": [req]}},
               {"kind": 0, "v": {"requests": [req, other]}})
    home.scan()
    # 6 + 10, not (6) + (6 + 10): the second snapshot is the whole list
    assert home.total("copilot-chat") == 16 and home.calls("copilot-chat") == 2


# (b) Codebuff: a message without an id counts once however far it was written ------------------------------------
def test_codebuff_message_without_id_counts_once(home):
    path = "/.config/manicode/projects/p/chats/2026-11-06T10-00-00.000Z/chat-messages.json"
    half = [{"variant": "ai", "metadata": {"model": "m", "usage": {"inputTokens": 5, "outputTokens": 1}}}]
    done = [{"variant": "ai", "metadata": {"model": "m", "usage": {"inputTokens": 5, "outputTokens": 40}}}]
    home.write(path.lstrip("/"), json.dumps(half))
    home.scan()
    os.utime(home.path(*path.lstrip("/").split("/")), (1, 1))
    home.write(path.lstrip("/"), json.dumps(done))
    home.scan()
    assert home.total("codebuff") == 45 and home.calls("codebuff") == 1


# (c) another tool's SQLite with a -wal -------------------------------------------------------------------------
def wal_pair(tmp_path, rows):
    """A WAL-mode opencode.db whose newest rows are only in its -wal, copied out while the writer was open (no -shm)."""
    live = tmp_path / "live"
    live.mkdir()
    con = sqlite3.connect(live / "opencode.db")
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA wal_autocheckpoint=0")
    con.execute("CREATE TABLE message(id TEXT, session_id TEXT, data TEXT, time_created INTEGER)")
    con.execute("CREATE TABLE session(id TEXT, directory TEXT)")
    con.commit()
    for i, tokens in enumerate(rows):
        data = json.dumps({"role": "assistant", "providerID": "openrouter", "modelID": "gpt-6-luna",
                           "tokens": {"input": tokens, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
                           "time": {"created": 1793968800}})
        con.execute("INSERT INTO message VALUES(?,?,?,?)", (f"m{i}", "s", data, 1))
        con.commit()
    return con, live


def test_wal_database_is_read_from_a_copy_and_the_folder_is_left_alone(home, tmp_path):
    con, live = wal_pair(tmp_path, [10, 20])
    target = home.path(".local", "share", "opencode")
    os.makedirs(target)
    shutil.copy(live / "opencode.db", target)
    shutil.copy(str(live / "opencode.db") + "-wal", target)
    con.close()
    before = listing(target)
    assert before == ["opencode.db", "opencode.db-wal"]
    wal_bytes = open(os.path.join(target, "opencode.db-wal"), "rb").read()
    home.scan()
    assert home.total("opencode") == 30                                # the rows only the -wal holds are counted
    assert listing(target) == before                                   # no -shm, nothing deleted
    assert open(os.path.join(target, "opencode.db-wal"), "rb").read() == wal_bytes
    left = [n for n in os.listdir(__import__("tempfile").gettempdir()) if n.startswith(extdb.SCRATCH_PREFIX)]
    assert left == [] or all(os.path.getmtime(os.path.join(__import__("tempfile").gettempdir(), n)) > 0 for n in left)


def test_empty_database_with_a_wal_never_loses_the_users_wal(home, tmp_path):
    con, live = wal_pair(tmp_path, [10])
    target = home.path(".local", "share", "opencode")
    os.makedirs(target)
    open(os.path.join(target, "opencode.db"), "wb").close()               # a 0-byte .db
    shutil.copy(str(live / "opencode.db") + "-wal", os.path.join(target, "opencode.db-wal"))
    con.close()
    wal_bytes = open(os.path.join(target, "opencode.db-wal"), "rb").read()
    home.scan()
    assert listing(target) == ["opencode.db", "opencode.db-wal"]
    assert open(os.path.join(target, "opencode.db-wal"), "rb").read() == wal_bytes


def test_database_with_a_wal_but_a_rollback_header_is_still_copied(home, tmp_path):
    con, live = wal_pair(tmp_path, [10])
    con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    con.execute("PRAGMA journal_mode=DELETE")
    con.close()
    target = home.path(".local", "share", "opencode")
    os.makedirs(target)
    shutil.copy(live / "opencode.db", target)
    open(os.path.join(target, "opencode.db-wal"), "wb").write(b"")         # a leftover -wal beside a non-WAL header
    assert extdb.uses_wal(os.path.join(target, "opencode.db"))
    home.scan()
    assert listing(target) == ["opencode.db", "opencode.db-wal"]
    assert home.total("opencode") == 10


# (d) user alias prices are bounded; nothing infinite reaches the cost or the JSON -------------------------------
@pytest.mark.parametrize("bad", [{"input": 1e308, "output": 1e308}, {"input": 1, "output": 2, "cacheRead": 1e9},
                                 {"input": 1, "output": 2, "cacheWrite": -5}, {"input": float("nan"), "output": 1}])
def test_alias_price_out_of_range_is_refused(bad):
    aliases, _ = parse_aliases({"aliases": {"claude-opus-5-5": bad}})
    book_pricer = Pricer([], [], aliases)
    assert book_pricer.resolve("anthropic", "claude-opus-5-5") is None


def test_infinite_alias_never_reaches_the_json(home):
    os.makedirs(home.env.config_dir())
    open(home.env.aliases_path(), "w").write('{"aliases": {"my-model": {"input": 1e308, "output": 1e308}}}')
    home.jsonl(".claude/projects/p/a.jsonl", claude_line(model="my-model", inp=2_000_000, out=1))
    home.scan()
    book = PriceBook(home.env, pinned=False, offline=True)
    from tokenbar.report import build_report
    report = build_report(home.store, book, "all")
    text = json.dumps(to_json(report, []), allow_nan=False)      # raises on Infinity or NaN
    assert report.cost == 0 and "my-model" in text and report.unpriced == ["custom/my-model"]


def test_good_alias_prices_the_model(home):
    os.makedirs(home.env.config_dir())
    open(home.env.aliases_path(), "w").write('{"aliases": {"my-model": {"input": 1, "output": 2}}}')
    home.jsonl(".claude/projects/p/a.jsonl", claude_line(model="my-model", inp=1_000_000, out=1_000_000))
    home.scan()
    from tokenbar.report import build_report
    assert build_report(home.store, PriceBook(home.env, pinned=False, offline=True), "all").cost == pytest.approx(3.0)


# (e) Claude [1m]: max per raw name inside a run, normalise and add at the model -------------------------------------
def test_claude_1m_and_plain_name_in_one_run_are_added_not_maxed(home):
    home.jsonl(".claude/projects/p/a.jsonl",
               claude_line(mid="m1", req="r1", inp=100, out=0, model="claude-opus-5-5[1m]"),
               {"type": "cost-state", "sessionId": "s1", "startTime": "2026-11-06T09:00:00.000Z",
                "modelUsage": {"claude-opus-5-5[1m]": {"inputTokens": 100}, "claude-opus-5-5": {"inputTokens": 80}}})
    # the cost-state line must start with the type key, as the writer's own lines do
    p = home.path(".claude", "projects", "p", "a.jsonl")
    lines = open(p).read().splitlines()
    lines[1] = '{"type":"cost-state",' + json.dumps({"sessionId": "s1", "startTime": "2026-11-06T09:00:00.000Z",
        "modelUsage": {"claude-opus-5-5[1m]": {"inputTokens": 100}, "claude-opus-5-5": {"inputTokens": 80}}})[1:]
    open(p, "w").write("\n".join(lines) + "\n")
    home.scan()
    assert home.total("claude-code") == 180            # 100 in the transcript + the 80 only the record holds


# (f) Cline / Roo / Kilo checkpoint restore ------------------------------------------------------------------------
def api_row(ts, tokens, say="api_req_started"):
    return {"type": "say", "say": say, "ts": ts, "text": json.dumps({"tokensIn": tokens, "tokensOut": 0, "cacheReads": 0, "cacheWrites": 0}),
            "modelInfo": {"modelId": "gpt-6-luna", "providerId": "openai"}}


@pytest.mark.parametrize("ext,harness", [("saoudrizwan.claude-dev", "cline"), ("rooveterinaryinc.roo-cline", "roo-code"),
                                         ("kilocode.kilo-code", "kilo-code")])
def test_checkpoint_restore_counts_each_call_once(home, ext, harness):
    rel = f"AppData/Roaming/Code/User/globalStorage/{ext}/tasks/t1/ui_messages.json"
    home.write(rel, json.dumps([api_row(1793968800, 120), api_row(1793968860, 250)]))
    home.scan()
    assert home.total(harness) == 370
    # the user goes back to a checkpoint: the second request is folded into one deleted_api_reqs row
    home.write(rel, json.dumps([api_row(1793968800, 120), api_row(1793968900, 250, "deleted_api_reqs")]))
    os.utime(home.path(*rel.split("/")), (2_000_000_000, 2_000_000_000))
    home.scan()
    assert home.total(harness) == 370


# (g) opencode / Kilo CLI database made again -------------------------------------------------------------------------
def make_opencode(path, rows):
    if os.path.exists(path):
        os.remove(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE message(id TEXT, session_id TEXT, data TEXT, time_created INTEGER)")
    con.execute("CREATE TABLE session(id TEXT, directory TEXT)")
    for rowid, mid, tokens in rows:
        data = json.dumps({"role": "assistant", "providerID": "p", "modelID": "gpt-6-luna", "tokens": {"input": tokens},
                           "time": {"created": 1793968800}})
        con.execute("INSERT INTO message(rowid, id, session_id, data, time_created) VALUES(?,?,?,?,?)", (rowid, mid, "s", data, 1))
    con.commit()
    con.close()


@pytest.mark.parametrize("sub,harness", [(".local/share/opencode/opencode.db", "opencode"), (".local/share/kilo/kilo.db", "kilo-code")])
def test_recreated_database_resets_the_watermark(home, sub, harness):
    path = home.path(*sub.split("/"))
    make_opencode(path, [(5000, "old", 15)])
    home.scan()
    assert home.total(harness) == 15
    make_opencode(path, [(1, "new", 100)])
    os.utime(path, (2_000_000_000, 2_000_000_000))
    home.scan()
    assert home.total(harness) == 115


# (h) Zed: one pass for db + wal; a reset thread's adjustment is retired --------------------------------------------
def make_zed(path, threads):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        os.remove(path)
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE threads(id TEXT PRIMARY KEY, summary TEXT NOT NULL, updated_at TEXT NOT NULL, data_type TEXT NOT NULL, data BLOB NOT NULL, created_at TEXT)")
    for tid, kind, doc in threads:
        con.execute("INSERT INTO threads VALUES(?,?,?,?,?,?)", (tid, "", "2026-11-06T10:00:00+00:00", kind, json.dumps(doc).encode(), None))
    con.commit()
    con.close()


def zed_thread(cumulative, imported=False):
    return {"model": {"model": "claude-sonnet-4-5", "provider": "zed.dev"}, "imported": imported,
            "cumulative_token_usage": {"input_tokens": cumulative}, "request_token_usage": {}}


def test_zed_adjustment_is_retired_when_the_thread_resets(home):
    path = home.path("AppData", "Local", "Zed", "threads", "threads.db")
    make_zed(path, [("t1", "json", zed_thread(1000))])
    home.scan()
    assert home.total("zed") == 1000
    make_zed(path, [("t1", "json", zed_thread(0))])
    os.utime(path, (2_000_000_000, 2_000_000_000))
    home.scan()
    assert home.total("zed") == 0
    make_zed(path, [("t1", "json", zed_thread(500))])
    os.utime(path, (2_100_000_000, 2_100_000_000))
    home.scan()
    make_zed(path, [("t1", "json", zed_thread(900, imported=True))])
    os.utime(path, (2_200_000_000, 2_200_000_000))
    home.scan()
    assert home.total("zed") == 0


def test_zed_db_with_a_wal_is_one_source_and_one_issue(home, tmp_path):
    path = home.path("AppData", "Local", "Zed", "threads", "threads.db")
    make_zed(path, [("t1", "lz4", zed_thread(10))])
    open(path + "-wal", "wb").close()
    result = home.scan()
    zed = [i for i in result.issues if i[0] == "Zed"]
    assert len(zed) == 1 and "unknown data_type" in zed[0][1]
    assert next(s for s in result.sources if s.name == "Zed").files_read == 1


# (i) readable model names ----------------------------------------------------------------------------------------------
@pytest.mark.parametrize("raw,name", [("claude-mythos-5-2", "Claude Mythos 5.2"), ("gpt-6.2-sol", "GPT-6.2 Sol"),
                                      ("google/gemini-4-neon", "Gemini 4 Neon"), ("qwen3.8-27b", "Qwen3.8 27B"),
                                      ("deepseek-v4-flash:free", "DeepSeek V4 Flash")])
def test_display_names(raw, name):
    assert display(raw) == name


def test_price_rows_without_a_name_get_a_readable_one():
    from tokenbar.prices.engine import Catalogue, Pricer as P
    cat = Catalogue("litellm", {"acme/mystery-model-7-1": [1.0, 2.0, 0, 0, 0, []]})
    entry = P([cat]).resolve("acme", "mystery-model-7-1")
    assert entry["name"] == "Mystery Model 7.1"


# nothing personal -----------------------------------------------------------------------------------------------------
def test_no_personal_sources_or_price_rows_ship():
    # Only the documented tools are built in (windows/docs/HARNESSES.md); anything a single user runs belongs in their
    # own config, and no price row is marked as one user's own.
    from tokenbar.catalog import BUILTIN
    documented = open(os.path.join(os.path.dirname(extdb.__file__), "..", "docs", "HARNESSES.md"), encoding="utf-8").read()
    for d in BUILTIN:
        assert d.name in documented, d.name
    assert len({d.name for d in BUILTIN}) == 32   # some tools have two sources (Qwen Code, Kilo Code)
    assert json.load(open(os.path.join(os.path.dirname(extdb.__file__), "data", "price-tables.json")))["personal"] == []
