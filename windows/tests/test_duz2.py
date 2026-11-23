"""Findings of the pre-release verification round (Neon and Argon), each reproduced first."""
import json
import os
import shutil
import time

import pytest

from conftest import claude_line
from test_argon import api_row, wal_pair
from tokenbar import cli, extdb, util
from tokenbar.gui import app
from tokenbar.store import Store

CLINE = "AppData/Roaming/{editor}/User/globalStorage/{ext}/tasks/t1/ui_messages.json"
CLINE_EXT = "saoudrizwan.claude-dev"


def touch(home, rel, stamp):
    os.utime(home.path(*rel.split("/")), (stamp, stamp))


def old(path, seconds=3600):
    t = time.time() - seconds
    os.utime(path, (t, t))
    return path


# ------------------------------------------------------------------------------------------ 1 locked -wal

def test_a_locked_wal_is_not_recorded_as_read_and_is_read_once_it_opens(home, tmp_path, monkeypatch):
    con, live = wal_pair(tmp_path, [10, 20])
    con.execute("PRAGMA wal_checkpoint(TRUNCATE)")                 # 10 and 20 are in the .db itself ...
    data = json.dumps({"role": "assistant", "providerID": "openrouter", "modelID": "gpt-6-luna",
                       "tokens": {"input": 120, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
                       "time": {"created": 1793968800}})
    con.execute("INSERT INTO message VALUES('m9', 's', ?, 1)", (data,))
    con.commit()                                                   # ... and 120 only in the -wal
    target = home.path(".local", "share", "opencode")
    os.makedirs(target)
    shutil.copy(live / "opencode.db", target)
    shutil.copy(str(live / "opencode.db") + "-wal", target)
    con.close()
    db = os.path.join(target, "opencode.db")
    real = shutil.copyfile
    state = {"locked": True}

    def copyfile(src, dst, *a, **k):
        if state["locked"] and str(src).endswith("-wal"):
            raise PermissionError(13, "The process cannot access the file because it is being used by another process")
        return real(src, dst, *a, **k)

    monkeypatch.setattr(extdb.shutil, "copyfile", copyfile)
    first = home.scan()
    assert db not in home.store.file_records()                  # not recorded: the rows only the -wal holds are not lost
    assert any(db in m for _, m in first.issues)
    state["locked"] = False
    home.scan()
    assert home.total("opencode") == 150


# ------------------------------------------------------------------------------------------ 2 legacy rows

def test_rows_of_an_index_made_before_the_file_column_are_retired_by_a_restore(home):
    code = CLINE.format(editor="Code", ext=CLINE_EXT)
    home.write(code, json.dumps([api_row(1793968800, 120), api_row(1793968860, 250)]))
    home.scan()
    assert home.total("cline") == 370
    # the same index as an older build wrote it: no owner on any row
    home.store.db.execute("UPDATE events SET file = ''")
    home.store.db.execute("DELETE FROM event_files")
    home.write(code, json.dumps([api_row(1793968800, 120), api_row(1793968900, 250, "deleted_api_reqs")]))
    touch(home, code, 2_000_000_000)
    home.scan()
    assert home.total("cline") == 370


def test_the_alter_table_upgrade_leaves_the_file_column_and_the_ownership_table(tmp_path):
    path = str(tmp_path / "old.sqlite")
    s = Store(path)
    s.db.execute("ALTER TABLE events DROP COLUMN file")
    s.db.execute("DROP TABLE event_files")
    s.close()
    s = Store(path)
    names = {r[1] for r in s.db.execute("PRAGMA table_info(events)")}
    tables = {r[0] for r in s.db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    assert "file" in names and "event_files" in tables
    s.close()


# ------------------------------------------------------------------------------------------ 3 same task, two editors

def scan_totals(home):
    home.scan()
    return home.total("cline")


def two_editors(home, code_rows, cursor_rows):
    code = CLINE.format(editor="Code", ext=CLINE_EXT)
    cursor = CLINE.format(editor="Cursor", ext=CLINE_EXT)
    home.write(code, json.dumps(code_rows))
    home.write(cursor, json.dumps(cursor_rows))
    return code, cursor


def test_identical_copies_count_once_and_a_restore_in_the_first_does_not_double_count(home):
    rows = [api_row(1793968800, 120), api_row(1793968860, 250)]
    code, cursor = two_editors(home, rows, rows)
    assert scan_totals(home) == 370
    home.write(code, json.dumps([api_row(1793968800, 120), api_row(1793968900, 250, "deleted_api_reqs")]))
    touch(home, code, 2_000_000_000)
    assert scan_totals(home) == 370


def test_identical_copies_a_restore_in_the_last_read_copy_does_not_double_count_either(home):
    rows = [api_row(1793968800, 120), api_row(1793968860, 250)]
    code, cursor = two_editors(home, rows, rows)
    assert scan_totals(home) == 370
    home.write(cursor, json.dumps([api_row(1793968800, 120), api_row(1793968900, 250, "deleted_api_reqs")]))
    touch(home, cursor, 2_000_000_000)
    assert scan_totals(home) == 370


def test_a_copy_with_extra_calls_keeps_them_whichever_copy_is_read_again(home):
    a = [api_row(1793968800, 120), api_row(1793968860, 250)]
    code, cursor = two_editors(home, a, a + [api_row(1793968920, 500)])
    assert scan_totals(home) == 870
    touch(home, code, 2_000_000_000)
    assert scan_totals(home) == 870                     # Code read again: Cursor's 500 stays
    touch(home, cursor, 2_000_000_100)
    assert scan_totals(home) == 870                     # Cursor read again: nothing doubled


def test_a_task_that_moved_between_editors_is_retired_by_the_new_copy(home):
    rows = [api_row(1793968800, 120), api_row(1793968860, 250)]
    code = CLINE.format(editor="Code", ext=CLINE_EXT)
    cursor = CLINE.format(editor="Cursor", ext=CLINE_EXT)
    home.write(cursor, json.dumps(rows))
    assert scan_totals(home) == 370
    shutil.rmtree(os.path.dirname(home.path(*cursor.split("/"))))
    home.write(code, json.dumps(rows))
    assert scan_totals(home) == 370
    home.write(code, json.dumps([api_row(1793968800, 120), api_row(1793968900, 250, "deleted_api_reqs")]))
    touch(home, code, 2_000_000_000)
    assert scan_totals(home) == 370


def test_a_message_rolled_back_in_one_of_two_identical_copies_is_not_counted_twice(home):
    rows = [api_row(1793968800, 120), api_row(1793968860, 250)]
    code, cursor = two_editors(home, rows, rows)
    assert scan_totals(home) == 370
    home.write(code, json.dumps(rows[:1]))                # no marker row: the copy that was read again decides
    touch(home, code, 2_000_000_000)
    assert scan_totals(home) == 120


def test_ownership_rows_do_not_outlive_the_events_they_name(home):
    rows = [api_row(1793968800, 120), api_row(1793968860, 250)]
    code, cursor = two_editors(home, rows, rows)
    home.scan()
    home.write(code, json.dumps(rows[:1]))
    touch(home, code, 2_000_000_000)
    home.scan()
    home.write(cursor, json.dumps(rows[:1]))
    touch(home, cursor, 2_000_000_100)
    home.scan()
    orphans = home.store.db.execute(
        "SELECT count(*) FROM event_files WHERE key NOT IN (SELECT key FROM events)").fetchone()[0]
    assert orphans == 0 and home.total("cline") == 120


# ------------------------------------------------------------------------------------------ 4 tray errors

class BrokenIcon:
    def __init__(self):
        self.stopped = False

    @property
    def title(self):
        return ""

    @title.setter
    def title(self, value):
        raise OSError("the tray window is not registered yet")

    def update_menu(self):
        raise RuntimeError("explorer restarted")

    def stop(self):
        self.stopped = True


class FakeWindow:
    def __init__(self):
        self.scanned = 0
        self.refreshed = 0

    def background_scan_done(self):
        self.scanned += 1

    def refresh(self):
        self.refreshed += 1

    def toggle(self):
        pass

    def update_prices(self):
        pass


class FakeModel:
    offline = False

    def set_offline(self, value):
        self.offline = value


class FakeRoot:
    def __init__(self):
        self.after_calls = []
        self.destroyed = False

    def after(self, ms, fn):
        self.after_calls.append((ms, fn))

    def destroy(self):
        self.destroyed = True


def test_a_tray_error_does_not_stop_the_loop_or_the_requests_behind_it():
    import queue
    requests = queue.Queue()
    for item in (("tooltip", "TokenBar"), "offline", "scanned"):
        requests.put(item)
    window, icon, model, root = FakeWindow(), BrokenIcon(), FakeModel(), FakeRoot()
    app.pump(requests, window, model, icon, root)
    assert window.scanned == 1 and window.refreshed == 1       # the requests after the failing ones were still served
    assert len(root.after_calls) == 1 and root.after_calls[0][0] == 150      # and the loop is planned again


def test_the_loop_is_planned_again_even_when_a_window_call_fails():
    import queue
    requests = queue.Queue()
    requests.put("scanned")
    window, root = FakeWindow(), FakeRoot()

    def boom():
        raise RuntimeError("tk")
    window.background_scan_done = boom
    app.pump(requests, window, FakeModel(), BrokenIcon(), root)
    assert len(root.after_calls) == 1


def test_quit_stops_the_icon_and_ends_the_loop():
    import queue
    requests = queue.Queue()
    requests.put("quit")
    icon, root = BrokenIcon(), FakeRoot()
    app.pump(requests, FakeWindow(), FakeModel(), icon, root)
    assert icon.stopped and root.destroyed and root.after_calls == []


# ------------------------------------------------------------------------------------------ 5 util

def test_a_broken_json_file_with_a_future_mtime_is_judged_not_retried_forever(tmp_path):
    p = tmp_path / "x.json"
    p.write_text("[{broken")
    os.utime(p, (time.time() + 7200, time.time() + 7200))
    with pytest.raises(util.BadFile):
        util.read_json_file(str(p), strict=True)
    assert util.read_json_file(str(p)) is None


def test_a_broken_json_file_touched_a_moment_ago_still_retries(tmp_path):
    p = tmp_path / "x.json"
    p.write_text("[{broken")
    with pytest.raises(util.Retry):
        util.read_json_file(str(p), strict=True)


def test_trailing_whitespace_without_a_newline_is_consumed_once_the_file_is_quiet(tmp_path):
    p = tmp_path / "a.jsonl"
    p.write_bytes(b'{"a":1}\n   ')
    old(str(p))
    got = list(util.iter_lines(str(p), 0, None, True))
    assert got[0] == ('{"a":1}', 8)
    assert got[-1][1] == p.stat().st_size                        # the cursor reaches the end: no re-read every pass
    assert list(util.iter_lines(str(p), 0, None, False))[-1][1] == 8        # a file still being written waits


def test_a_file_that_ends_in_blanks_is_not_read_again_every_pass(home):
    rel = ".claude/projects/p/a.jsonl"
    home.write(rel, json.dumps(claude_line(inp=5, out=5)) + "\n   ")
    old(home.path(*rel.split("/")))
    home.scan()
    rec = home.store.file_records()[home.path(*rel.split("/"))]
    assert rec.offset == os.path.getsize(home.path(*rel.split("/")))
    assert home.scan().bytes_read == 0


# ------------------------------------------------------------------------------------------ 6 prerelease

def test_the_windows_release_step_marks_hyphenated_tags_as_prereleases():
    here = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    with open(os.path.join(here, ".github", "workflows", "windows.yml"), encoding="utf-8") as f:
        text = f.read()
    assert "--prerelease" in text and '"$TAG" == *-*' in text


# ------------------------------------------------------------------------------------------ 7 --home aliases

def test_cli_home_reads_the_aliases_of_the_inspected_home_only(monkeypatch, tmp_path, capsys):
    for k in ("TOKENBAR_PRICES_PINNED", "TOKENBAR_OFFLINE"):
        monkeypatch.delenv(k, raising=False)
    mine = tmp_path / "me"
    monkeypatch.setenv("USERPROFILE", str(mine))
    monkeypatch.setenv("APPDATA", str(mine / "Roaming"))
    monkeypatch.setenv("LOCALAPPDATA", str(mine / "Local"))
    inspected = tmp_path / "other"
    jl = inspected / ".claude" / "projects" / "p" / "a.jsonl"
    jl.parent.mkdir(parents=True)
    jl.write_text(json.dumps(claude_line(model="my-house-model", inp=1_000_000, out=0)) + "\n")
    alias_file = inspected / "AppData" / "Roaming" / "TokenBar" / "model-aliases.json"
    alias_file.parent.mkdir(parents=True)
    alias_file.write_text(json.dumps({"aliases": {"my-house-model": {"input": 2, "output": 4}}}))
    own_alias = mine / "Roaming" / "TokenBar" / "model-aliases.json"
    own_alias.parent.mkdir(parents=True)
    own_alias.write_text(json.dumps({"aliases": {"my-house-model": {"input": 50, "output": 60}}}))
    rc = cli.run_cli(["--offline", "--json", "--window", "all", "--home", str(inspected), "--db", str(tmp_path / "i.sqlite")])
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    assert out["cost"] == pytest.approx(2.0)                      # the inspected home's price, not the user's own 50
    assert not (inspected / "AppData" / "Local").exists()         # nothing written into it


# ------------------------------------------------------------------------------------------ 8 Pi bool

def test_a_pi_boolean_is_not_a_count(home):
    line = {"type": "message", "timestamp": "2026-11-06T10:00:01.000Z",
            "message": {"role": "assistant", "provider": "anthropic", "model": "claude-haiku-5-5", "responseId": "r1",
                        "usage": {"input": True, "output": 5, "cacheRead": 2}}}
    home.write(".pi/agent/sessions/x/s.jsonl", json.dumps(line, separators=(",", ":")) + "\n")
    home.scan()
    assert home.total("pi") == 7


# ------------------------------------------------------------------------------------------ 10 bad files are named

def test_a_corrupt_old_task_log_is_named_every_pass_and_never_recorded(home):
    rel = CLINE.format(editor="Code", ext=CLINE_EXT)
    path = home.path(*rel.split("/"))
    home.write(rel, json.dumps([api_row(1793968800, 120)]))
    home.scan()
    good_size = os.path.getsize(path)
    home.write(rel, "[{broken")
    old(path)
    first = home.scan()
    second = home.scan()
    assert home.total("cline") == 120
    assert len([i for i in first.issues if path in i[1]]) == 1 and len([i for i in second.issues if path in i[1]]) == 1
    assert home.store.file_records()[path].size == good_size       # still the earlier, good record


def test_an_empty_task_log_is_not_a_problem(home):
    rel = CLINE.format(editor="Code", ext=CLINE_EXT)
    home.write(rel, "")
    old(home.path(*rel.split("/")))
    assert home.scan().issues == []


@pytest.mark.parametrize("sub,name", [("AppData/Local/crush/crush.db", "crush"), (".local/share/goose/sessions/sessions.db", "goose")])
def test_a_g3_file_that_is_no_database_is_named_and_left_unrecorded(home, sub, name):
    path = home.write(sub, "this is not a database at all")
    if name == "crush":
        home.write("AppData/Local/crush/projects.json", json.dumps({"projects": [{"data_dir": os.path.dirname(path)}]}))
    r = home.scan()
    assert any(path in m for _, m in r.issues)
    assert path not in home.store.file_records()


def test_a_devin_sessions_db_that_is_no_database_is_named(home):
    path = home.write(".local/share/devin/cli/sessions.db", "not a database")
    r = home.scan()
    assert any(path in m for _, m in r.issues)
    assert path not in home.store.file_records()


# ------------------------------------------------------------------------------------------ round 3 (Neon, last pass)

def test_a_normal_reread_of_one_copy_keeps_the_other_copys_ownership_so_a_later_restore_there_retires_the_old_call(home):
    rows = [api_row(1793968800, 120), api_row(1793968860, 250)]
    code, cursor = two_editors(home, rows, rows)
    assert scan_totals(home) == 370
    home.write(code, json.dumps(rows + [api_row(1793968920, 100)]))
    touch(home, code, 2_000_000_000)
    assert scan_totals(home) == 470
    home.write(cursor, json.dumps([api_row(1793968800, 120), api_row(1793968900, 250, "deleted_api_reqs")]))
    touch(home, cursor, 2_000_000_100)
    assert scan_totals(home) == 470


def test_a_copy_only_touched_keeps_the_other_copys_ownership_too(home):
    rows = [api_row(1793968800, 120), api_row(1793968860, 250)]
    code, cursor = two_editors(home, rows, rows)
    assert scan_totals(home) == 370
    touch(home, code, 2_000_000_000)
    assert scan_totals(home) == 370
    home.write(cursor, json.dumps([api_row(1793968800, 120), api_row(1793968900, 250, "deleted_api_reqs")]))
    touch(home, cursor, 2_000_000_100)
    assert scan_totals(home) == 370


def test_the_windows_offline_switch_survives_a_tray_that_is_not_ready():
    import inspect
    from tokenbar.gui import window as window_mod
    icon, win = BrokenIcon(), FakeWindow()
    model = FakeModel()
    win.model, win.on_offline_changed = model, app.tray_refresher(icon)
    window_mod.MainWindow._toggle_offline(win, True)
    assert model.offline is True and win.refreshed == 1        # the tray failing does not skip the window's own refresh
    assert "tray_refresher(icon)" in inspect.getsource(app._run)     # and the real window is wired through it


def test_a_log_dated_in_the_future_is_settled_so_its_last_line_without_a_newline_counts(home):
    rel = ".claude/projects/p/a.jsonl"
    home.write(rel, json.dumps(claude_line(inp=30, out=30)))               # no newline: complete, but only a quiet file's counts
    path = home.path(*rel.split("/"))
    os.utime(path, (time.time() + 7200, time.time() + 7200))
    home.scan()
    assert home.total() == 60


def test_a_log_dated_in_the_future_that_ends_in_blanks_is_not_read_again_every_pass(home):
    rel = ".claude/projects/p/a.jsonl"
    home.write(rel, json.dumps(claude_line(inp=5, out=5)) + "\n   ")
    path = home.path(*rel.split("/"))
    os.utime(path, (time.time() + 7200, time.time() + 7200))
    home.scan()
    assert home.store.file_records()[path].offset == os.path.getsize(path)
    assert home.scan().bytes_read == 0


def test_a_bom_followed_only_by_blanks_is_consumed_once_the_file_is_quiet(tmp_path):
    p = tmp_path / "a.jsonl"
    p.write_bytes(b"\xef\xbb\xbf   ")
    old(str(p))
    got = list(util.iter_lines(str(p), 0, None, True))
    assert got and got[-1][1] == p.stat().st_size


def test_a_file_replaced_by_a_good_one_of_the_same_size_and_date_is_read_again(home):
    rel = CLINE.format(editor="Code", ext=CLINE_EXT)
    good = json.dumps([api_row(1793968800, 99)])
    path = home.path(*rel.split("/"))
    home.write(rel, "X" + good[1:])                         # broken, same length as the good one
    stamp = time.time() - 7200
    os.utime(path, (stamp, stamp))
    first = home.scan()
    assert len(first.issues) == 1 and home.total("cline") == 0
    fresh = path + ".new"
    with open(fresh, "w", encoding="utf-8") as f:
        f.write(good)
    os.utime(fresh, (stamp, stamp))
    os.replace(fresh, path)                                 # a new inode, the same size and mtime
    second = home.scan()
    assert second.issues == [] and home.total("cline") == 99


def test_a_broken_json_file_deleted_between_the_parse_and_the_size_check_is_a_retry_not_an_error(tmp_path, monkeypatch):
    p = tmp_path / "x.json"
    p.write_text("[{broken")
    old(str(p))
    real, calls = os.path.getsize, []

    def getsize(path):
        calls.append(path)
        if len(calls) > 1:                      # the first call (the size limit) sees the file; the second finds it gone
            raise FileNotFoundError(path)
        return real(path)
    monkeypatch.setattr(util.os.path, "getsize", getsize)
    with pytest.raises(util.Retry):
        util.read_json_file(str(p), strict=True)


@pytest.mark.parametrize("rel", [
    CLINE.format(editor="Code", ext=CLINE_EXT),
    ".cline/data/sessions/cs1/cs1.messages.json",
    "AppData/Roaming/Code/User/workspaceStorage/w/chatSessions/s.json",
])
def test_a_quiet_json_file_that_holds_only_null_is_named_and_not_recorded_like_an_empty_array_is_not(home, rel):
    path = home.write(rel, "null")
    old(path)
    r = home.scan()
    assert any(path in m for _, m in r.issues)
    assert path not in home.store.file_records()


def test_json_null_is_a_bad_file_in_strict_reading_only(tmp_path):
    p = tmp_path / "x.json"
    p.write_text("null")
    old(str(p))
    with pytest.raises(util.BadFile):
        util.read_json_file(str(p), strict=True)
    assert util.read_json_file(str(p)) is None
    p.write_text("")
    old(str(p))
    assert util.read_json_file(str(p), strict=True) is None
