"""9.0.1 (third batch): data and reader defects found by the independent review of the 9.0.1 candidate.
Each test failed before its fix."""
import json
import os
import shutil
import sqlite3

import pytest

from tokenbar import extdb


def _closed_wal_db(path, rows):
    """A WAL-mode opencode.db as a tool leaves it after a clean exit: header says WAL, no -wal and no -shm."""
    con = sqlite3.connect(path)
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("CREATE TABLE message(id TEXT, session_id TEXT, data TEXT, time_created INTEGER)")
    con.execute("CREATE TABLE session(id TEXT, directory TEXT)")
    for i, tokens in enumerate(rows):
        data = json.dumps({"role": "assistant", "providerID": "openrouter", "modelID": "gpt-6-luna",
                           "tokens": {"input": tokens, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
                           "time": {"created": 1793968800}})
        con.execute("INSERT INTO message VALUES(?,?,?,?)", (f"m{i}", "s", data, 1))
    con.commit()
    con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    con.close()
    for leftover in ("-wal", "-shm"):
        if os.path.exists(str(path) + leftover):
            os.remove(str(path) + leftover)


def _refuse_ro(monkeypatch):
    """A Windows read-only handle on a WAL file with no -shm: SQLite cannot make the -shm and refuses to open."""
    real = sqlite3.connect
    seen = []

    def refuse(dsn, *a, **k):
        seen.append(dsn)
        if isinstance(dsn, str) and "mode=ro" in dsn:
            raise sqlite3.OperationalError("unable to open database file")
        return real(dsn, *a, **k)

    monkeypatch.setattr(extdb.sqlite3, "connect", refuse)
    return seen


# 1. a WAL database closed cleanly (no -wal) is read as it is: no copy, immutable=1 --------------------------------
def test_clean_wal_database_without_wal_is_read_in_place(home, tmp_path, monkeypatch):
    target = home.path(".local", "share", "opencode")
    os.makedirs(target)
    db = os.path.join(target, "opencode.db")
    _closed_wal_db(db, [100, 400])
    assert extdb.uses_wal(db) and not os.path.exists(db + "-wal")
    _refuse_ro(monkeypatch)
    r = home.scan()
    assert home.total("opencode") == 500
    assert not any("opencode" in name.lower() for name, _ in r.issues)
    assert not os.path.exists(db + "-shm") and not os.path.exists(db + "-wal")      # the tool's folder is as it was


def test_clean_wal_database_with_an_empty_wal_is_read_in_place(tmp_path, monkeypatch):
    db = str(tmp_path / "x.db")
    _closed_wal_db(db, [100])
    open(db + "-wal", "wb").close()
    seen = _refuse_ro(monkeypatch)
    with extdb.open_readonly(db) as con:
        assert con.execute("select count(*) from message").fetchone() == (1,)
    assert not any("mode=ro" in dsn for dsn in seen)


def test_wal_database_with_a_full_wal_is_still_copied_and_a_refused_copy_is_an_error(home, tmp_path, monkeypatch):
    from test_901 import _opencode_home
    target = _opencode_home(home, tmp_path, [100], [400])
    _refuse_ro(monkeypatch)
    r = home.scan()
    assert home.total("opencode") == 0                                              # no quiet immutable=1 read
    assert any("opencode" in name.lower() for name, _ in r.issues)


# 4. a row stored with no date (9.0.0: 1970) gets its date when its file is read again ---------------------------------
def _reopen(home):
    from tokenbar.scanner import Scanner
    from tokenbar.store import Store
    path = home.store.path
    home.store.close()
    home.store = Store(path)
    home.scanner = Scanner(home.store, home.env)


def _zero_dates(home):
    """The index as 9.0.0 left it: every row dated 1970, none of the repairs done, the tools' files unchanged."""
    home.store.db.execute("UPDATE events SET ts = 0")
    home.store.db.execute("DELETE FROM meta WHERE k LIKE 'repair:%'")
    _reopen(home)


def _dates(home):
    return home.store.db.execute("SELECT count(*), sum(ts <= 0) FROM events").fetchone()


def test_rows_dated_1970_by_9_0_0_get_their_date_when_read_again(home, tmp_path):
    from test_901 import _opencode_home
    from conftest import claude_line
    home.write(".claude/projects/p/a.jsonl", json.dumps(claude_line("m1", "r1", 70, 3)) + "\n")
    _opencode_home(home, tmp_path, [100], [400])
    home.scan()
    good = (home.total("claude-code"), home.total("opencode"), _dates(home))
    assert good[2][0] >= 3 and good[2][1] == 0
    _zero_dates(home)
    assert _dates(home)[1] == good[2][0]                       # the index looks like 9.0.0's
    home.scan()
    assert _dates(home) == good[2]                             # dated again
    assert (home.total("claude-code"), home.total("opencode")) == good[:2]     # and nothing counted twice
    home.scan()
    assert (home.total("claude-code"), home.total("opencode"), _dates(home)) == good


def test_a_later_read_does_not_replace_a_date_the_row_has(home):
    from tokenbar.readers.base import Event
    from tokenbar.store import Store
    s = home.store
    e = Event("k1", 1000.0, "anthropic", "claude-opus-5-5", 5, 0, 0, 5, 0, 0, "s")
    s.apply([(None, [e], [], [])])
    e2 = Event("k1", 2000.0, "anthropic", "claude-opus-5-5", 9, 0, 0, 9, 0, 0, "s")
    s.apply([(None, [e2], [], [])])
    assert s.db.execute("SELECT ts FROM events").fetchone()[0] == 1000.0


# 6. the repair of 9.0.0's cost rows reads inside its transaction -----------------------------------------------------
def test_cost_repair_does_not_delete_a_row_written_between_its_read_and_its_transaction(tmp_path, monkeypatch):
    from tokenbar import store as store_mod
    path = str(tmp_path / "usage.sqlite")
    s = store_mod.Store(path)
    s.db.execute("INSERT INTO costs VALUES('s1', 100.5, 'm', 10, 0, 0, 5)")
    s.close()
    real_connect = sqlite3.connect
    other = real_connect(path, isolation_level=None)

    class Spy:
        """The Store's connection, with another program (9.0.0 still running) writing a cost row the moment the
        repair opens its transaction."""

        def __init__(self, con):
            self._con, self.done = con, False

        def execute(self, sql, *a):
            if sql.startswith("BEGIN IMMEDIATE") and not self.done:
                self.done = True
                other.execute("INSERT INTO costs VALUES('s2', 200.25, 'm', 7, 0, 0, 3)")
            return self._con.execute(sql, *a)

        def __getattr__(self, name):
            return getattr(self._con, name)

    monkeypatch.setattr(store_mod.sqlite3, "connect", lambda *a, **k: Spy(real_connect(*a, **k)))
    s2 = store_mod.Store(path)
    rows = sorted(s2.cost_rows())
    assert rows == [("s1", 100.0, "m", 10, 0, 0, 5), ("s2", 200.0, "m", 7, 0, 0, 3)]


# 7. scripts/release-audit.sh and the Windows workflow -----------------------------------------------------------------
def _audit_helpers():
    import test_901
    return test_901


def _needs_shell(fn):
    return _audit_helpers().needs_shell(fn)


@_needs_shell
@pytest.mark.parametrize("how", ["missing", "no key", "empty"])
def test_audit_stops_when_the_plist_cannot_be_read(tmp_path, how):
    t = _audit_helpers()
    work = t._release_repo(tmp_path)
    plist = os.path.join(work, "Resources", "Info.plist")
    if how == "missing":
        os.remove(plist)
    elif how == "no key":
        open(plist, "w").write("<plist><dict><key>CFBundleName</key><string>TokenBar</string></dict></plist>\n")
    else:
        open(plist, "w").close()
    t._git(work, "add", "-A")
    t._git(work, "commit", "-q", "-m", "plist")
    t._git(work, "push", "-q", "origin", "main")
    r = t._audit(work)
    assert r.returncode == 1 and "Info.plist" in r.stderr, (r.returncode, r.stderr)


@_needs_shell
def test_audit_stops_when_git_status_fails(tmp_path):
    t = _audit_helpers()
    work = t._release_repo(tmp_path)
    open(os.path.join(work, ".git", "index"), "wb").write(b"not an index")      # status cannot be read; rev-parse still can
    r = t._audit(work)
    assert r.returncode == 1 and "git status" in r.stderr, (r.returncode, r.stderr)


@_needs_shell
def test_audit_still_passes_a_pre_release_and_a_real_plist(tmp_path):
    t = _audit_helpers()
    work = t._release_repo(tmp_path)
    plist = os.path.join(work, "Resources", "Info.plist")
    open(plist, "w").write("<plist><dict><key>CFBundleShortVersionString</key>\n<string>9.9.9</string></dict></plist>\n")
    t._git(work, "add", "-A")
    t._git(work, "commit", "-q", "-m", "plist")
    t._git(work, "push", "-q", "origin", "main")
    assert t._audit(work).returncode == 0
    assert t._audit(work, "9.9.9-rc1").returncode == 0


def test_the_windows_workflow_lets_a_pre_release_tag_differ_from_the_version_like_the_audit():
    import yaml
    path = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), ".github", "workflows", "windows.yml")
    with open(path, encoding="utf-8") as f:
        wf = yaml.safe_load(f)
    steps = [s for job in wf["jobs"].values() for s in job.get("steps", []) if s.get("id") == "version"]
    assert len(steps) == 1
    script = steps[0]["run"]
    assert '-like "*-*"' in script and "throw" in script        # a hyphenated tag is a pre-release; any other must match
