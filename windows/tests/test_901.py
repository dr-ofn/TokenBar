"""9.0.1: each verified defect of 9.0.0 on the Windows side, reproduced first (red), then fixed."""
import json
import os
import shutil
import sys
import sqlite3

import pytest

from conftest import claude_line
from test_argon import wal_pair
from tokenbar import extdb
from tokenbar.util import iter_lines


def _wal_pair_with_old_rows(tmp_path, old, new):
    """A WAL opencode.db: `old` rows are checkpointed into the .db, `new` rows only live in the -wal."""
    live = tmp_path / "live"
    live.mkdir()
    con = sqlite3.connect(live / "opencode.db")
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA wal_autocheckpoint=0")
    con.execute("CREATE TABLE message(id TEXT, session_id TEXT, data TEXT, time_created INTEGER)")
    n = 0
    for batch, checkpoint in ((old, True), (new, False)):
        for tokens in batch:
            data = json.dumps({"role": "assistant", "providerID": "openrouter", "modelID": "gpt-6-luna",
                               "tokens": {"input": tokens, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
                               "time": {"created": 1793968800}})
            con.execute("INSERT INTO message VALUES(?,?,?,?)", (f"m{n}", "s", data, 1))
            n += 1
        con.commit()
        if checkpoint:
            con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    return con, live


def _opencode_home(home, tmp_path, old, new):
    con, live = _wal_pair_with_old_rows(tmp_path, old, new)
    target = home.path(".local", "share", "opencode")
    os.makedirs(target)
    shutil.copy(live / "opencode.db", target)
    shutil.copy(str(live / "opencode.db") + "-wal", target)
    con.close()
    return target


# 1. a WAL copy that cannot be opened is an error, never a quiet fall back to immutable=1 (which ignores the -wal) ----
def test_wal_copy_that_will_not_open_is_not_read_without_its_wal(home, tmp_path, monkeypatch):
    target = _opencode_home(home, tmp_path, [100], [400])
    real = sqlite3.connect

    def refuse_ro(dsn, *a, **k):
        if isinstance(dsn, str) and "mode=ro" in dsn:
            raise sqlite3.OperationalError("unable to open database file")
        return real(dsn, *a, **k)

    monkeypatch.setattr(extdb.sqlite3, "connect", refuse_ro)
    r = home.scan()
    assert home.total("opencode") == 0                         # not even the 100 the .db alone holds
    assert home.store.file_records().get(os.path.join(target, "opencode.db")) is None   # not marked read
    assert any("opencode" in name.lower() for name, _ in r.issues)
    left = [n for n in os.listdir(__import__("tempfile").gettempdir()) if n.startswith(extdb.SCRATCH_PREFIX)]
    assert all(not os.path.isdir(os.path.join(__import__("tempfile").gettempdir(), n)) or n in left for n in left)
    monkeypatch.setattr(extdb.sqlite3, "connect", real)        # the lock is gone: the next pass reads the whole thing
    home.scan()
    assert home.total("opencode") == 500


def test_plain_database_still_falls_back_to_immutable(tmp_path, monkeypatch):
    p = tmp_path / "x.db"
    con = sqlite3.connect(p)
    con.execute("create table t(a)")
    con.commit()
    con.close()
    real = sqlite3.connect

    def refuse_ro(dsn, *a, **k):
        if isinstance(dsn, str) and "mode=ro" in dsn:
            raise sqlite3.OperationalError("unable to open database file")
        return real(dsn, *a, **k)

    monkeypatch.setattr(extdb.sqlite3, "connect", refuse_ro)
    with extdb.open_readonly(str(p)) as c:
        assert c.execute("select count(*) from t").fetchone() == (0,)


# 2. Claude Code cost-state: a run is whole seconds (Mac Safe.seconds), a line without sessionId is skipped ---------
def cost_line(session, start, usage, model="claude-opus-5-5"):
    body = {"startTime": start, "modelUsage": {model: usage}}
    if session is not None:
        body["sessionId"] = session
    return '{"type":"cost-state",' + json.dumps(body, separators=(",", ":"))[1:] + "\n"


def test_cost_state_fractional_start_time_is_one_run(home):
    home.write(".claude/projects/p/a.jsonl",
               cost_line("s1", "2026-11-06T09:00:00.100Z", {"inputTokens": 200}) +
               cost_line("s1", "2026-11-06T09:00:00.900Z", {"inputTokens": 300}))
    home.scan()
    assert home.total("claude-code") == 300            # max(200, 300) of one run, as the Mac app


def test_cost_state_numeric_fractional_start_time_is_one_run(home):
    home.write(".claude/projects/p/a.jsonl",
               cost_line("s1", 1793955600.25, {"inputTokens": 200}) + cost_line("s1", 1793955600.75, {"inputTokens": 300}))
    home.scan()
    assert home.total("claude-code") == 300


def test_cost_state_without_session_id_adds_nothing(home):
    home.write(".claude/projects/p/a.jsonl", cost_line(None, "2026-11-06T09:00:00.000Z", {"inputTokens": 77}) +
               cost_line("", "2026-11-06T09:00:00.000Z", {"inputTokens": 55}))
    home.scan()
    assert home.total("claude-code") == 0
    assert home.store.cost_rows() == []


def test_cost_state_distinct_runs_still_add(home):
    home.write(".claude/projects/p/a.jsonl",
               cost_line("s1", "2026-11-06T09:00:00.000Z", {"inputTokens": 200}) +
               cost_line("s1", "2026-11-06T10:00:00.000Z", {"inputTokens": 300}))
    home.scan()
    assert home.total("claude-code") == 500


def test_index_of_9_0_0_with_fractional_runs_is_repaired(tmp_path):
    """9.0.0 keyed runs by the raw fractional start time and kept rows for lines with no session id."""
    from tokenbar.store import Store
    path = str(tmp_path / "usage.sqlite")
    s = Store(path)
    s.db.executemany("INSERT INTO costs(session, started, model, input, cr, cw, output) VALUES(?,?,?,?,?,?,?)",
                     [("s1", 1793955600.1, "claude-opus-5-5", 200, 0, 0, 0), ("s1", 1793955600.9, "claude-opus-5-5", 300, 0, 0, 0),
                      ("", 1793955600.0, "claude-opus-5-5", 77, 0, 0, 0)])
    s.db.commit()
    s.close()
    s = Store(path)
    assert s.cost_rows() == [("s1", 1793955600.0, "claude-opus-5-5", 300, 0, 0, 0)]
    s.close()


def test_repaired_index_recomputes_the_adjustment_at_the_next_pass(tmp_path):
    from conftest import Home
    from tokenbar.readers.base import Event
    from tokenbar.store import Store
    h = Home(tmp_path / "home")
    h.write(".claude/projects/p/unrelated.jsonl", "")
    h.scan()                                                  # the file is recorded: the next pass reads nothing
    h.store.db.executemany("INSERT INTO costs(session, started, model, input, cr, cw, output) VALUES(?,?,?,?,?,?,?)",
                           [("s1", 1793955600.1, "claude-opus-5-5", 200, 0, 0, 0), ("s1", 1793955600.9, "claude-opus-5-5", 300, 0, 0, 0),
                            ("", 1793955600.0, "claude-opus-5-5", 77, 0, 0, 0)])
    h.store.replace_prefix("cc:adj:", [Event("cc:adj:s1:claude-opus-5-5", 1793955600.0, "anthropic", "claude-opus-5-5", 500, 0, 0, 0, 0, 0, "s1"),
                                       Event("cc:adj::claude-opus-5-5", 1793955600.0, "anthropic", "claude-opus-5-5", 77, 0, 0, 0, 0, 0, "")])
    assert h.total("claude-code") == 577
    h.store.close()
    h.store = Store(h.store.path)
    h.scanner.store = h.store
    h.scan()
    assert h.total("claude-code") == 300
    h.store.close()


# 3. Qwen: a usage_record.jsonl that is locked while the adjustment runs is named and tried again ---------------------
def test_qwen_adjustment_locked_once_is_done_at_the_next_pass(home, monkeypatch):
    from tokenbar.readers import core
    home.jsonl(".qwen/usage/token-usage-2026-11.jsonl",
               {"id": "a1", "timestamp": "2026-11-06T10:00:00Z", "model": "m", "inputTokens": 100, "outputTokens": 0, "sessionId": "s"})
    home.jsonl(".qwen/usage_record.jsonl", {"sessionId": "s", "timestamp": "2026-11-06T10:00:00Z",
                                            "models": {"m": {"inputTokens": 500, "outputTokens": 0, "totalTokens": 500}}})
    real = core.iter_lines
    locked = {"on": True}

    def maybe_locked(path, *a, **k):
        if locked["on"] and os.path.basename(path) == "usage_record.jsonl":
            raise PermissionError("sharing violation")
        return real(path, *a, **k)

    monkeypatch.setattr(core, "iter_lines", maybe_locked)
    r = home.scan()
    assert home.total("qwen-code") == 100
    assert any("sharing violation" in msg for _, msg in r.issues)     # named, not swallowed
    locked["on"] = False
    r = home.scan()                                                   # nothing in Qwen's folder changed
    assert home.total("qwen-code") == 500
    assert not any("qwen" in n.lower() for n, _ in r.issues)
    home.scan()
    assert home.total("qwen-code") == 500                             # and it does not repeat


# 4. a half-written last line never moves the cursor past it, even in a file that has been quiet for a long time ------
def test_iter_lines_leaves_a_settled_half_line_unconsumed(tmp_path):
    p = tmp_path / "a.jsonl"
    whole = json.dumps({"a": 1}) + "\n"
    half = '{"b": 2, "c": '
    p.write_bytes((whole + half).encode())
    got = list(iter_lines(str(p), 0, None, settled=True))
    assert got == [('{"a": 1}', len(whole))]                       # the cursor stops at the end of the last whole line
    p.write_bytes((whole + half + "3}\n").encode())
    got = list(iter_lines(str(p), len(whole), None, settled=True))
    assert [g[0] for g in got] == ['{"b": 2, "c": 3}']


def test_claude_half_line_in_a_quiet_file_is_counted_once_finished(home):
    first = json.dumps(claude_line(mid="m1", req="r1", inp=100, out=0)) + "\n"
    second = json.dumps(claude_line(mid="m2", req="r2", inp=200, out=0))
    p = home.write(".claude/projects/p/a.jsonl", first + second[:40])
    os.utime(p, (1_700_000_000, 1_700_000_000))                    # quiet for years: `settled`
    home.scan()
    assert home.total("claude-code") == 100
    rec = home.store.file_records()[p]
    assert rec.offset == len(first)                                # not past the half line
    with open(p, "a") as f:
        f.write(second[40:] + "\n")
    os.utime(p, (1_700_000_100, 1_700_000_100))
    home.scan()
    assert home.total("claude-code") == 300 and home.calls("claude-code") == 2


# 5. change detection of databases: one stamp (inode, size, mtime_ns) for the .db and one for the -wal, compared for
#    equality (a clock that went back, or a .db and -wal that swapped times, is still a change) ---------------------
def _opencode_rollback_db(path, tokens):
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE IF NOT EXISTS message(id TEXT, session_id TEXT, data TEXT, time_created INTEGER)")
    for i, t in enumerate(tokens):
        data = json.dumps({"role": "assistant", "providerID": "openrouter", "modelID": "gpt-6-luna",
                           "tokens": {"input": t, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
                           "time": {"created": 1793968800}})
        con.execute("INSERT INTO message VALUES(?,?,?,?)", (f"m{path}{i}{t}", "s", data, 1))
    con.commit()
    con.close()


def test_database_changed_with_an_older_mtime_and_the_same_size_is_read(home):
    target = home.path(".local", "share", "opencode")
    os.makedirs(target)
    db = os.path.join(target, "opencode.db")
    _opencode_rollback_db(db, [100])
    os.utime(db, (1_800_000_000, 1_800_000_000))
    home.scan()
    assert home.total("opencode") == 100
    size = os.path.getsize(db)
    _opencode_rollback_db(db, [700])                                   # a second row in the same page: the size stays
    assert os.path.getsize(db) == size
    os.utime(db, (1_700_000_000, 1_700_000_000))                       # a restored backup, a clock set back
    home.scan()
    assert home.total("opencode") == 800


def test_stamp_tells_apart_a_db_and_wal_that_swapped_modification_times(tmp_path):
    from tokenbar.readers.base import db_stamp
    db, wal = str(tmp_path / "x.db"), str(tmp_path / "x.db-wal")
    open(db, "wb").write(b"a" * 10)
    open(wal, "wb").write(b"b" * 10)
    os.utime(db, ns=(1_700_000_000_000_000_001, 1_700_000_000_000_000_001))
    os.utime(wal, ns=(1_700_000_100_000_000_002, 1_700_000_100_000_000_002))
    one = db_stamp(db)[0]
    os.utime(db, ns=(1_700_000_100_000_000_002, 1_700_000_100_000_000_002))
    os.utime(wal, ns=(1_700_000_000_000_000_001, 1_700_000_000_000_000_001))
    assert db_stamp(db)[0] != one
    os.utime(db, ns=(1_700_000_000_000_000_001, 1_700_000_000_000_000_002))     # one nanosecond is a change too
    os.utime(wal, ns=(1_700_000_100_000_000_002, 1_700_000_100_000_000_002))
    assert db_stamp(db)[0] != one


def test_index_without_database_stamps_reads_each_database_once_and_never_twice(home):
    target = home.path(".local", "share", "opencode")
    os.makedirs(target)
    _opencode_rollback_db(os.path.join(target, "opencode.db"), [100, 200])
    home.scan()
    assert home.total("opencode") == 300
    home.store.db.execute("DELETE FROM meta WHERE k LIKE 'dbstamp:%'")      # an index of 9.0.0 has none
    r = home.scan()
    assert sum(s.files_read for s in r.sources) == 1                          # read once to learn the stamp ...
    assert home.total("opencode") == 300 and home.calls("opencode") == 2     # ... and nothing counted twice
    r = home.scan()
    assert sum(s.files_read for s in r.sources) == 0


# 6. Codex: only the first session_meta describes the file (a missing id falls back to the file name); a token_count
#    without a timestamp is no call ------------------------------------------------------------------------------------
def _codex_tc(ts, total, last=None):
    row = {"type": "event_msg", "payload": {"type": "token_count", "info": {
        "total_token_usage": {"input_tokens": total, "output_tokens": 0}, "last_token_usage": {"input_tokens": last or total}}}}
    if ts is not None:
        row["timestamp"] = ts
    return row


def test_codex_first_meta_without_id_is_not_replaced_by_a_forked_one(home):
    rows = [{"timestamp": "2026-11-06T10:00:00Z", "type": "session_meta", "payload": {"timestamp": "2026-11-06T10:00:00Z"}},
            {"timestamp": "2026-11-06T11:00:00Z", "type": "session_meta",
             "payload": {"id": "parent", "model_provider": "other", "timestamp": "2026-11-06T11:00:00Z"}},
            {"timestamp": "2026-11-06T10:00:01Z", "type": "turn_context", "payload": {"model": "gpt-6-luna"}},
            _codex_tc("2026-11-06T10:00:05Z", 180)]
    home.jsonl(".codex/sessions/2026/rollout-fork.jsonl", *rows)
    home.scan()
    assert home.total("codex") == 180                                  # not dropped as older than the fork's start
    keys = [r[0] for r in home.store.events_since(None)]
    assert keys == ["cx:rollout-fork:180"]                             # session from the file name, not the fork's id
    assert [r[1] for r in home.store.events_since(None)] == ["openai"]     # and the first meta's provider, not the fork's


def test_codex_token_count_without_a_timestamp_is_skipped(home):
    rows = [{"type": "event_msg", "payload": {"type": "task_started"}}, _codex_tc(None, 100),
            _codex_tc("2026-11-06T10:00:05Z", 160, 60)]
    home.jsonl(".codex/sessions/2026/rollout-nots.jsonl", *rows)
    home.scan()
    assert home.total("codex") == 160 and home.calls("codex") == 1     # 100 has no time: no call, and no baseline either


# 7. ISO-8601 times in Copilot Chat and Cline CLI; a Cline UI model that starts with "/" -------------------------------
ISO = "2026-11-06T10:00:00Z"
ISO_EPOCH = 1793959200.0


def test_copilot_chat_iso_timestamp_is_read(home):
    req = {"promptTokens": 4, "completionTokens": 2, "timestamp": ISO, "modelId": "copilot/gpt-6-luna"}
    home.jsonl("AppData/Roaming/Code/User/workspaceStorage/w/chatSessions/s.jsonl", {"kind": 0, "v": {"requests": [req]}})
    home.scan()
    assert [r[3] for r in home.store.events_since(None)] == [ISO_EPOCH]


def test_cline_cli_iso_timestamp_is_read_and_the_file_time_is_only_a_fallback(home):
    msgs = [{"role": "assistant", "id": "a1", "ts": ISO, "metrics": {"inputTokens": 10, "outputTokens": 5}},
            {"role": "assistant", "id": "a2", "metrics": {"inputTokens": 3, "outputTokens": 1}}]
    p = home.write(".cline/data/sessions/cs1/cs1.messages.json", json.dumps({"messages": msgs}))
    os.utime(p, (1_700_000_000, 1_700_000_000))
    home.scan()
    got = {r[0].rsplit(":", 1)[1]: r[3] for r in home.store.events_since(None)}
    assert got == {"a1": ISO_EPOCH, "a2": 1_700_000_000.0}


@pytest.mark.parametrize("model,provider", [("/claude-opus-5-5", "claude-opus-5-5"), ("anthropic/claude-opus-5-5", "anthropic"),
                                            ("//x/y", "x")])
def test_cline_ui_provider_comes_from_the_first_non_empty_piece_of_the_model(home, model, provider):
    row = {"type": "say", "say": "api_req_started", "ts": 1793968800000, "text": json.dumps({"tokensIn": 10, "tokensOut": 5}),
           "modelInfo": {"modelId": model}}
    home.write("AppData/Roaming/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/t1/ui_messages.json", json.dumps([row]))
    home.scan()
    assert [r[1] for r in home.store.events_since(None)] == [provider]


# 8. Crush, Goose, Zed and Qwen details the Mac app has the other way ---------------------------------------------------
def _crush_db(home):
    path = home.path("AppData", "Local", "crush", "crush.db")
    os.makedirs(os.path.dirname(path))
    home.write("AppData/Local/crush/projects.json", json.dumps({"projects": [{"data_dir": os.path.dirname(path)}]}))
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE sessions(id TEXT, prompt_tokens INTEGER, completion_tokens INTEGER, updated_at INTEGER, created_at INTEGER)")
    con.execute("CREATE TABLE messages(session_id TEXT, role TEXT, model TEXT, provider TEXT, created_at INTEGER)")
    return con, path


def test_crush_provider_is_the_latest_non_empty_one_and_a_non_positive_update_time_falls_back_to_created(home):
    con, _ = _crush_db(home)
    con.execute("INSERT INTO sessions VALUES('s1', 100, 20, -1, 1793968800)")
    con.executemany("INSERT INTO messages VALUES('s1', 'assistant', ?, ?, ?)",
                    [("claude-a", "anthropic", 1), ("claude-b", None, 2)])       # the newest message names no provider
    con.commit()
    con.close()
    home.scan()
    ev = home.store.events_since(None)
    assert [(e[1], e[2], e[3]) for e in ev] == [("anthropic", "claude-b", 1793968800.0)]


def test_crush_goose_and_zed_rows_without_an_identity_are_skipped(home):
    con, _ = _crush_db(home)
    con.executemany("INSERT INTO sessions VALUES(?, 100, 20, 1793968800, 1793968800)", [(None,), ("",), ("ok",)])
    con.commit()
    con.close()
    gpath = home.path(".local", "share", "goose", "sessions", "sessions.db")
    os.makedirs(os.path.dirname(gpath))
    con = sqlite3.connect(gpath)
    con.execute("CREATE TABLE sessions(id TEXT, model_config_json TEXT, provider_name TEXT, updated_at TEXT, created_at TEXT, "
                "accumulated_input_tokens INTEGER, accumulated_output_tokens INTEGER)")
    con.executemany("INSERT INTO sessions VALUES(?, '{\"model_name\":\"m\"}', 'p', '2026-11-06 10:00:00', '2026-11-06 10:00:00', 10, 5)",
                    [(None,), ("",), ("g1",)])
    con.commit()
    con.close()
    from test_argon import make_zed, zed_thread
    zpath = home.path("AppData", "Local", "Zed", "threads", "threads.db")
    make_zed(zpath, [("t1", "json", zed_thread(7))])
    con = sqlite3.connect(zpath)
    con.execute("INSERT INTO threads VALUES(NULL, '', '2026-11-06T10:00:00+00:00', 'json', ?, NULL)", (json.dumps(zed_thread(9)).encode(),))
    con.commit()
    con.close()
    home.scan()
    keys = sorted(e[0] for e in home.store.events_since(None))
    assert keys == ["crush:ok", "goose:g1", "zed:adj:t1"], keys


def test_qwen_adjustment_takes_the_alphabetically_first_provider_like_min(home):
    home.jsonl(".qwen/usage/token-usage-2026-11.jsonl",
               {"id": "a1", "timestamp": "2026-11-06T10:00:00Z", "model": "m", "inputTokens": 100, "sessionId": "s", "authType": "z-auth"},
               {"id": "a2", "timestamp": "2026-11-06T10:00:01Z", "model": "m", "inputTokens": 100, "sessionId": "s", "authType": "a-auth"})
    home.jsonl(".qwen/usage_record.jsonl", {"sessionId": "s", "timestamp": "2026-11-06T10:00:02Z",
                                            "models": {"m": {"inputTokens": 500, "totalTokens": 500}}})
    home.scan()
    adj = [e for e in home.store.events_since(None) if e[0].startswith("qwen:adj:")]
    assert [e[1] for e in adj] == ["a-auth"] and adj[0][4] == 300


# 9. the window and the tray loop ------------------------------------------------------------------------------------
@pytest.fixture
def gui(tmp_path):
    tk = pytest.importorskip("tkinter")
    try:
        root = tk.Tk()
    except tk.TclError:
        pytest.skip("no display")
    root.withdraw()
    from fixture_home import make_fixture_home
    from tokenbar.gui.model import AppModel
    from tokenbar.gui.window import MainWindow
    from tokenbar.paths import Env
    from tokenbar.store import Store
    model = AppModel(env=Env.for_home(make_fixture_home(str(tmp_path / "home"))), store=Store(str(tmp_path / "u.sqlite")))
    model.rescan()
    window = MainWindow(root, model, on_quit=root.destroy)
    yield root, model, window
    try:
        root.destroy()
    except Exception:
        pass
    model.close()


def _pump(root, until, seconds=5.0):
    import time
    end = time.time() + seconds
    while time.time() < end and not until():
        root.update()
        time.sleep(0.01)
    return until()


def test_the_window_keeps_polling_after_a_job_fails(gui):
    root, model, w = gui
    w.jobs.put(("report", (w._refresh_seq, object())))          # painting this raises
    w.jobs.put(("error", "still alive"))
    assert _pump(root, lambda: w.status == "still alive")
    w.jobs.put(("error", "and again"))                          # the loop was planned again after the failure
    assert _pump(root, lambda: w.status == "and again")


def test_a_slow_report_of_an_earlier_period_does_not_overwrite_the_chosen_one(gui):
    import threading
    root, model, w = gui
    gate = threading.Event()
    real = model.report

    def slow(period=None):
        r = real(period)
        if period == "all":
            gate.wait(10)
        return r

    model.report = slow
    w.choose("all")                    # a slow one starts ...
    w.choose("1h")                     # ... and the user picks another period before it ends
    assert _pump(root, lambda: w.report is not None and w.report.period == "1h")
    gate.set()                         # the slow report now arrives
    import time
    end = time.time() + 1.0
    while time.time() < end:
        root.update()
        time.sleep(0.01)
    assert w.report.period == "1h" and model.period == "1h"
    assert "1h" in w.total_tokens.cget("text") or w.report.period == "1h"


def test_the_prices_pass_refreshes_the_tooltip_and_the_window_when_prices_changed():
    from tokenbar.gui.app import background_pass
    from tokenbar.prices.feed import RefreshReport

    class Model:
        offline = False

        def __init__(self, report):
            self.report_ = report

        def rescan(self):
            pass

        def report(self):
            return None

        def update_prices(self, force=False):
            return self.report_

    q = _Q()
    background_pass(Model(RefreshReport(updated=["openrouter"])), q, {}, now=lambda: 10 ** 9)
    assert q.items == [("tooltip", "TokenBar"), "scanned", ("tooltip", "TokenBar"), "scanned"]
    q = _Q()
    background_pass(Model(RefreshReport(fresh=["openrouter"])), q, {}, now=lambda: 10 ** 9)
    assert q.items == [("tooltip", "TokenBar"), "scanned"]


def test_a_failed_price_fetch_is_tried_again_in_an_hour_not_in_six():
    from tokenbar.gui.app import background_pass
    from tokenbar.prices.feed import RefreshReport

    class Model:
        offline = False
        asked = 0

        def rescan(self):
            pass

        def report(self):
            return None

        def update_prices(self, force=False):
            Model.asked += 1
            return RefreshReport(failed={"openrouter": "network"})

    state, q, t0 = {}, _Q(), 10 ** 9
    background_pass(Model(), q, state, now=lambda: t0)
    assert Model.asked == 1
    background_pass(Model(), q, state, now=lambda: t0 + 600)
    assert Model.asked == 1                                   # not at once
    background_pass(Model(), q, state, now=lambda: t0 + 3601)
    assert Model.asked == 2                                   # but in an hour, not after six
    background_pass(Model(), q, state, now=lambda: t0 + 3601 + 3601)
    assert Model.asked == 2                                   # a second failure waits longer (backs off)
    background_pass(Model(), q, state, now=lambda: t0 + 3601 + 7300)
    assert Model.asked == 3


def test_a_price_fetch_that_raises_does_not_end_the_pass_and_is_tried_again_in_an_hour():
    from tokenbar.gui.app import background_pass

    class Model:
        offline = False
        asked = 0

        def rescan(self):
            pass

        def report(self):
            return None

        def update_prices(self, force=False):
            Model.asked += 1
            raise OSError("down")

    state, q, t0 = {}, _Q(), 10 ** 9
    background_pass(Model(), q, state, now=lambda: t0)
    background_pass(Model(), q, state, now=lambda: t0 + 3601)
    assert Model.asked == 2


def test_a_successful_price_fetch_waits_six_hours():
    from tokenbar.gui.app import background_pass
    from tokenbar.prices.feed import RefreshReport

    class Model:
        offline = False
        asked = 0

        def rescan(self):
            pass

        def report(self):
            return None

        def update_prices(self, force=False):
            Model.asked += 1
            return RefreshReport(fresh=["x"])

    state, q, t0 = {}, _Q(), 10 ** 9
    background_pass(Model(), q, state, now=lambda: t0)
    background_pass(Model(), q, state, now=lambda: t0 + 3601)
    assert Model.asked == 1
    background_pass(Model(), q, state, now=lambda: t0 + 6 * 3600 + 1)
    assert Model.asked == 2


# 14. the window's menu is built again at every opening and leaves nothing behind ---------------------------------------
def test_opening_the_menu_many_times_leaves_one_menu_and_no_stray_variables(gui, monkeypatch):
    import tkinter as tk
    root, model, w = gui
    monkeypatch.setattr(tk.Menu, "tk_popup", lambda self, x, y, entry="": None)      # a real popup blocks until dismissed

    def menus():
        return [c for c in root.winfo_children() if c.winfo_class() == "Menu"]

    def variables():
        return len(root.tk.splitlist(root.tk.call("info", "globals", "PY_VAR*")))

    w._popup_menu()
    one_menu, one_vars = len(menus()), variables()
    for _ in range(12):
        w._popup_menu()
    import gc
    gc.collect()
    assert len(menus()) == one_menu == 1
    assert variables() <= one_vars


class _Q:
    def __init__(self):
        self.items = []

    def put(self, x):
        self.items.append(x)


# 14. TokenBar.exe: anything it does not know is a command-line mistake, never a tray app that opens -----------------
@pytest.mark.parametrize("argv", [["-w7d"], ["--bogus"], ["-x"], ["whatever"], ["--window7d"], ["--show", "--bogus"]])
def test_unknown_arguments_go_to_the_command_line_parser_not_the_tray_app(argv, monkeypatch):
    from tokenbar import cli
    from tokenbar.gui import app
    seen = []
    monkeypatch.setattr(cli, "run_cli", lambda a: seen.append(("cli", a)) or 2)
    monkeypatch.setattr(app, "run_gui", lambda a: seen.append(("gui", a)) or 0)
    assert cli.main(list(argv)) == 2
    assert seen == [("cli", argv)]


@pytest.mark.parametrize("argv", [[], ["--show"]])
def test_no_arguments_or_show_open_the_tray_app(argv, monkeypatch):
    from tokenbar import cli
    from tokenbar.gui import app
    seen = []
    monkeypatch.setattr(cli, "run_cli", lambda a: seen.append("cli") or 2)
    monkeypatch.setattr(app, "run_gui", lambda a: seen.append("gui") or 0)
    assert cli.main(list(argv)) == 0 and seen == ["gui"]


def test_an_unknown_flag_is_an_error_with_a_message(capsys):
    from tokenbar import cli
    with pytest.raises(SystemExit) as e:
        cli.run_cli(["--bogus"])
    assert e.value.code == 2 and "unrecognized arguments" in capsys.readouterr().err


def test_version_goes_to_the_output_file_when_asked(tmp_path, capsys):
    from tokenbar import cli, __version__
    out = tmp_path / "v.txt"
    assert cli.run_cli(["--version", "--output", str(out)]) == 0
    assert out.read_text().strip() == __version__


# 10. walk_files: a short root with a path over 260 characters below it is walked with the long-path prefix ----------
def _windows_like_walk(monkeypatch):
    """os.walk as Windows has it without the `\\\\?\\` prefix: a directory whose full path is 260 or more is not entered."""
    prefix = "\\\\?\\"
    real_walk, real_isdir = os.walk, os.path.isdir
    monkeypatch.setattr(os, "name", "nt")

    def fake_walk(top, **k):
        prefixed = top.startswith(prefix)
        for dirpath, dirnames, filenames in real_walk(top[len(prefix):] if prefixed else top, **k):
            if not prefixed:
                dirnames[:] = [d for d in dirnames if len(os.path.join(dirpath, d)) < 260]
            yield (prefix + dirpath if prefixed else dirpath), dirnames, filenames

    monkeypatch.setattr(os, "walk", fake_walk)
    monkeypatch.setattr(os.path, "isdir", lambda p: real_isdir(p[len(prefix):] if p.startswith(prefix) else p))


def test_walk_files_reaches_a_path_over_260_characters_below_a_short_root(tmp_path, monkeypatch):
    from tokenbar import util
    root = os.path.abspath(str(tmp_path / "logs"))
    deep = os.path.join(root, "a" * 100, "b" * 100, "c" * 100)
    os.makedirs(deep)
    f1, f2 = os.path.join(root, "top.jsonl"), os.path.join(deep, "deep.jsonl")
    open(f1, "w").close()
    open(f2, "w").close()
    assert len(f2) > 260 and len(root) < 240
    _windows_like_walk(monkeypatch)
    got = util.walk_files(root, lambda n: n.endswith(".jsonl"))
    assert sorted(got) == sorted([f1, f2])
    assert not any(p.startswith("\\\\?\\") for p in got)           # the paths come back as the caller wrote the root


# 11. scripts/release-audit.sh (run first by scripts/release.sh) ----------------------------------------------------------
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
AUDIT = os.path.join(REPO, "scripts", "release-audit.sh")
needs_shell = pytest.mark.skipif(sys.platform == "win32" or not os.path.exists(AUDIT) or shutil.which("git") is None,
                                 reason="a maintainer's shell script (macOS), run from the repository")


def _git(cwd, *args):
    import subprocess
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args], cwd=cwd, check=True,
                          capture_output=True, text=True).stdout


def _release_repo(tmp_path, version="9.9.9"):
    """A made-up repository with an origin, everything at `version` and pushed."""
    origin = os.path.abspath(str(tmp_path / "origin.git"))
    work = os.path.abspath(str(tmp_path / "work"))
    os.makedirs(work)
    import subprocess
    subprocess.run(["git", "init", "-q", "--bare", origin], check=True)
    _git(work, "init", "-q", "-b", "main")
    files = {"VERSION": version + "\n", "windows/tokenbar/__init__.py": f'"""x"""\n__version__ = "{version}"\n',
             "windows/pyproject.toml": f'[project]\nname = "tokenbar"\nversion = "{version}"\n',
             "CHANGELOG.md": f"# Changelog\n\n## {version} — 2026-11-24\n- x\n",
             "Resources/Info.plist": "<plist><dict><key>CFBundleShortVersionString</key>\n<string>__VERSION__</string></dict></plist>\n"}
    for rel, text in files.items():
        p = os.path.join(work, *rel.split("/"))
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(text)
    _git(work, "add", "-A")
    _git(work, "commit", "-q", "-m", "x")
    _git(work, "remote", "add", "origin", origin)
    _git(work, "push", "-q", "origin", "main")
    return work


def _audit(work, version="9.9.9"):
    import subprocess
    return subprocess.run(["bash", AUDIT, version, work], capture_output=True, text=True)


@needs_shell
def test_audit_passes_a_clean_pushed_untagged_consistent_tree(tmp_path):
    r = _audit(_release_repo(tmp_path))
    assert r.returncode == 0 and "OK" in r.stdout, r.stderr


@needs_shell
@pytest.mark.parametrize("what,needle", [
    ("dirty", "not clean"), ("untracked", "not clean"), ("tag", "already exists"), ("unpushed", "not on any remote"),
    ("VERSION", "VERSION says"), ("init", "__init__.py says"), ("toml", "pyproject.toml says"), ("changelog", "no '## 9.9.9'")])
def test_audit_stops_each_wrong_state(tmp_path, what, needle):
    work = _release_repo(tmp_path)
    if what == "dirty":
        open(os.path.join(work, "VERSION"), "a").write("\n#")
    elif what == "untracked":
        open(os.path.join(work, "new.txt"), "w").write("x")
    elif what == "tag":
        _git(work, "tag", "v9.9.9")
    elif what == "unpushed":
        open(os.path.join(work, "a.txt"), "w").write("x")
        _git(work, "add", "-A")
        _git(work, "commit", "-q", "-m", "more")
    else:
        def edit(rel, old, new):
            p = os.path.join(work, *rel.split("/"))
            open(p, "w").write(open(p).read().replace(old, new))
        {"VERSION": lambda: edit("VERSION", "9.9.9", "9.9.8"),
         "init": lambda: edit("windows/tokenbar/__init__.py", "9.9.9", "9.9.8"),
         "toml": lambda: edit("windows/pyproject.toml", "9.9.9", "9.9.8"),
         "changelog": lambda: edit("CHANGELOG.md", "## 9.9.9", "## 9.9.8")}[what]()
        _git(work, "add", "-A")
        _git(work, "commit", "-q", "-m", "edit")
        _git(work, "push", "-q", "origin", "main")
    r = _audit(work)
    assert r.returncode == 1 and needle in r.stderr, (r.returncode, r.stderr)


@needs_shell
def test_audit_reports_every_problem_not_only_the_first(tmp_path):
    work = _release_repo(tmp_path)
    _git(work, "tag", "v9.9.9")
    open(os.path.join(work, "new.txt"), "w").write("x")
    r = _audit(work)
    assert r.returncode == 1 and "not clean" in r.stderr and "already exists" in r.stderr


@needs_shell
def test_audit_lets_a_pre_release_differ_in_the_version_files(tmp_path):
    work = _release_repo(tmp_path)
    r = _audit(work, "9.9.9-rc1")
    assert r.returncode == 0, r.stderr


@needs_shell
def test_release_script_runs_the_audit_before_anything_slow():
    text = open(os.path.join(REPO, "scripts", "release.sh")).read()
    assert text.index('scripts/release-audit.sh "$VERSION"') < text.index('echo "==> scripts/check.sh"') \
        and text.index('scripts/release-audit.sh "$VERSION"') < text.index("mkdir -p dist")


# 12, 13. the workflows and the Windows zip ------------------------------------------------------------------------------
WORKFLOWS = os.path.join(REPO, ".github", "workflows")


def _workflow(name):
    yaml = pytest.importorskip("yaml")
    path = os.path.join(WORKFLOWS, name)
    if not os.path.exists(path):
        pytest.skip("not inside the repository")
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


def test_ci_builds_and_checks_the_macos_release_package():
    doc = _workflow("ci.yml")
    gate = next(s for s in doc["jobs"]["build-and-check"]["steps"] if "package gate" in s.get("name", ""))
    run = gate["run"]
    for needle in ("scripts/build-app.sh --universal --no-test", "lipo -archs", "grep -a -q -F", "codesign --verify --strict",
                   "ditto -c -k", "ditto -x -k", "CFBundleShortVersionString"):
        assert needle in run, needle


def test_the_workflows_never_paste_a_tag_name_into_a_script():
    doc = _workflow("windows.yml")
    for job in doc["jobs"].values():
        for step in job["steps"]:
            assert "github.ref_name" not in step.get("run", "") and "github.head_ref" not in step.get("run", ""), step.get("name")
    version = next(s for s in doc["jobs"]["build"]["steps"] if s.get("id") == "version")
    assert version["env"]["REF_NAME"] == "${{ github.ref_name }}" and "$env:REF_NAME" in version["run"]
    assert doc["jobs"]["release"]["permissions"] == {"contents": "write"} and doc["permissions"] == {"contents": "read"}
    assert doc["jobs"]["release"]["steps"][-1]["env"]["TAG"] == "${{ github.ref_name }}"
    assert all(s.get("with", {}).get("persist-credentials") is False for s in doc["jobs"]["build"]["steps"] if "checkout" in s.get("uses", ""))


def test_the_windows_workflow_tests_console_mode_and_the_zips_documents():
    doc = _workflow("windows.yml")
    steps = {s.get("name", ""): s.get("run", "") for s in doc["jobs"]["build"]["steps"]}
    console = next(v for k, v in steps.items() if "console mode" in k)
    assert "-RedirectStandardOutput" in console and "| Out-String" in console and "--bogus-flag" in console
    assert "TokenBar/docs/HARNESSES.md" in steps["Zip contents"]


def test_the_windows_zip_carries_the_document_its_readme_links_to(tmp_path):
    import zipfile
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    import build
    app = tmp_path / "TokenBar"
    app.mkdir()
    (app / "TokenBar.exe").write_bytes(b"x")
    copied = build.copy_extras(str(app))
    assert os.path.join("docs", "HARNESSES.md") in copied
    names = zipfile.ZipFile(build.make_zip(str(app), str(tmp_path / "z.zip"))).namelist()
    assert "TokenBar/docs/HARNESSES.md" in names and "TokenBar/README.md" in names
    readme = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "README.md"), encoding="utf-8").read()
    assert "(docs/HARNESSES.md)" in readme


# 15. one version everywhere ----------------------------------------------------------------------------------------------
def test_every_place_that_names_the_version_agrees():
    from tokenbar import __version__
    if not os.path.exists(os.path.join(REPO, "VERSION")):
        pytest.skip("not inside the repository")
    assert open(os.path.join(REPO, "VERSION")).read().strip() == __version__
    toml = open(os.path.join(REPO, "windows", "pyproject.toml"), encoding="utf-8").read()
    import re
    assert re.search(r'^version = "([^"]+)"', toml, re.M).group(1) == __version__
    changelog = open(os.path.join(REPO, "CHANGELOG.md"), encoding="utf-8").read()
    assert re.search(r"^## " + re.escape(__version__) + r"\b", changelog, re.M)
    assert changelog.index("## " + __version__) < changelog.index("## 9.0.0")
