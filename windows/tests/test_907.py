"""9.0.7: each verified defect of the 9.0.6 sixth scan, Windows side, reproduced first (red), then fixed.

Tests that run scripts/oracle*.py are skipped on Windows (the oracle is the macOS twin: it loads `pwd`); CI runs them on
the POSIX runners."""
import http.server
import importlib
import json
import os
import shutil
import sqlite3
import stat
import subprocess
import sys
import threading
import time

import pytest

from conftest import Home, claude_line
from tokenbar import cli, extdb, fmt
from tokenbar.prices import engine
from tokenbar.prices import feed as pfeed

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPTS = os.path.join(ROOT, "scripts")
POSIX_ONLY = pytest.mark.skipif(sys.platform == "win32", reason="the oracle is the macOS twin (it loads pwd); CI runs it on POSIX")
NEEDS_LINKS = pytest.mark.skipif(sys.platform == "win32", reason="a symbolic link needs a privilege on Windows; CI runs it on POSIX")


def _message(tokens):
    return json.dumps({"role": "assistant", "providerID": "openrouter", "modelID": "gpt-6-luna",
                       "tokens": {"input": tokens, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
                       "time": {"created": 1793968800}})


class LiveDB:
    """An opencode database a running tool holds in WAL mode: its rows live in the -wal until a checkpoint."""

    def __init__(self, folder, name="real.db"):
        os.makedirs(folder, exist_ok=True)
        self.path = os.path.join(str(folder), name)
        self.con = sqlite3.connect(self.path)
        self.con.execute("PRAGMA journal_mode=WAL")
        self.con.execute("PRAGMA wal_autocheckpoint=0")
        self.con.execute("CREATE TABLE message(id TEXT, session_id TEXT, data TEXT, time_created INTEGER)")
        self.n = 0

    def add(self, *tokens):
        for t in tokens:
            self.con.execute("INSERT INTO message VALUES(?,?,?,?)", (f"m{self.n}", "s", _message(t), 1))
            self.n += 1
        self.con.commit()

    def close(self):
        self.con.close()


def _link(home, db_path, relative):
    """~/.local/share/opencode/opencode.db -> the database elsewhere (absolute or relative link)."""
    folder = home.path(".local", "share", "opencode")
    os.makedirs(folder, exist_ok=True)
    link = os.path.join(folder, "opencode.db")
    os.symlink(os.path.relpath(db_path, folder) if relative else db_path, link)
    return link


def _tree(*folders):
    """(name, size, mtime_ns) of every entry of the folders: what 'nothing was written, moved or deleted' compares."""
    out = {}
    for folder in folders:
        for name in sorted(os.listdir(folder)):
            st = os.lstat(os.path.join(folder, name))
            out[os.path.join(folder, name)] = (st.st_size, st.st_mtime_ns)
    return out


# ---------------------------------------------------------------- S1: a database file that is a symbolic link
@NEEDS_LINKS
@pytest.mark.parametrize("relative", [False, True])
def test_symlinked_database_counts_the_rows_that_live_in_the_wal_beside_the_target(home, tmp_path, relative):
    live = LiveDB(tmp_path / "elsewhere")
    live.add(100)
    live.con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    live.add(400)                                               # only in real.db-wal
    assert os.path.getsize(live.path + "-wal") > 0
    _link(home, live.path, relative)
    before = _tree(tmp_path / "elsewhere", home.path(".local", "share", "opencode"))
    r = home.scan()
    assert home.total("opencode") == 500 and home.calls("opencode") == 2, r.issues
    assert not [i for i in r.issues if "opencode" in i[0].lower() or "opencode" in i[1].lower()]
    assert _tree(tmp_path / "elsewhere", home.path(".local", "share", "opencode")) == before    # nothing written, moved or deleted
    live.close()


@NEEDS_LINKS
def test_symlinked_database_is_read_again_when_only_the_wal_beside_the_target_changes(home, tmp_path):
    live = LiveDB(tmp_path / "elsewhere")
    live.add(100)
    live.con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    live.add(400)
    _link(home, live.path, relative=False)
    home.scan()
    assert home.total("opencode") == 500
    live.add(30)                                                # the main file does not change; the -wal does
    home.scan()
    assert home.total("opencode") == 530
    live.close()


@NEEDS_LINKS
@pytest.mark.parametrize("relative", [False, True])
def test_symlinked_empty_main_file_with_a_wal_is_counted_and_nothing_of_the_user_changes(home, tmp_path, relative):
    live = LiveDB(tmp_path / "elsewhere")
    live.add(100, 200)                                          # everything (the schema too) is in the -wal
    # what a tool leaves when it stops before its first checkpoint: a 0-byte .db and the -wal
    keep = tmp_path / "frozen"
    keep.mkdir()
    shutil.copy(live.path, keep / "real.db")
    shutil.copy(live.path + "-wal", keep / "real.db-wal")
    live.close()
    with open(keep / "real.db", "wb"):
        pass
    _link(home, str(keep / "real.db"), relative)
    before = _tree(keep, home.path(".local", "share", "opencode"))
    assert before[str(keep / "real.db")][0] == 0 and before[str(keep / "real.db-wal")][0] > 0
    r = home.scan()
    assert home.total("opencode") == 300 and home.calls("opencode") == 2, r.issues
    assert _tree(keep, home.path(".local", "share", "opencode")) == before      # the -wal is still there, every file as it was


def test_empty_main_file_with_a_wal_is_counted_without_a_link_too(home, tmp_path):
    live = LiveDB(tmp_path / "x")
    live.add(100, 200)
    target = home.path(".local", "share", "opencode")
    os.makedirs(target)
    shutil.copy(live.path + "-wal", os.path.join(target, "opencode.db-wal"))
    live.close()
    with open(os.path.join(target, "opencode.db"), "wb"):
        pass
    before = _tree(target)
    r = home.scan()
    assert home.total("opencode") == 300, r.issues
    assert _tree(target) == before


@NEEDS_LINKS
def test_symlinked_database_through_a_linked_folder_and_a_chain_of_links(home, tmp_path):
    live = LiveDB(tmp_path / "elsewhere")
    live.add(100)
    live.con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    live.add(400)
    hop = tmp_path / "hop.db"
    os.symlink(live.path, hop)                                  # link -> link -> file
    _link(home, str(hop), relative=False)
    home.scan()
    assert home.total("opencode") == 500
    live.close()


@NEEDS_LINKS
def test_open_readonly_on_a_link_never_leaves_a_file_beside_the_link_or_the_target(tmp_path):
    live = LiveDB(tmp_path / "elsewhere")
    live.add(1, 2, 3)
    os.makedirs(tmp_path / "links")
    os.symlink(live.path, tmp_path / "links" / "x.db")
    before = _tree(tmp_path / "elsewhere", tmp_path / "links")
    with extdb.open_readonly(str(tmp_path / "links" / "x.db")) as con:
        assert con.execute("select count(*) from message").fetchone()[0] == 3
    assert _tree(tmp_path / "elsewhere", tmp_path / "links") == before
    live.close()


@POSIX_ONLY
@NEEDS_LINKS
def test_oracle_db_follows_a_link_to_the_wal_beside_the_target(tmp_path):
    sys.path.insert(0, SCRIPTS)
    try:
        oracle_db = importlib.import_module("oracle_db")
    finally:
        sys.path.remove(SCRIPTS)
    live = LiveDB(tmp_path / "elsewhere")
    live.add(100, 200)
    keep = tmp_path / "frozen"
    keep.mkdir()
    shutil.copy(live.path, keep / "real.db")
    shutil.copy(live.path + "-wal", keep / "real.db-wal")
    with open(keep / "zero.db", "wb"):
        pass
    shutil.copy(keep / "real.db-wal", keep / "zero.db-wal")
    live.close()
    os.makedirs(tmp_path / "links")
    os.symlink(str(keep / "real.db"), tmp_path / "links" / "a.db")
    os.symlink(str(keep / "zero.db"), tmp_path / "links" / "z.db")
    before = _tree(keep, tmp_path / "links")
    for name in ("a.db", "z.db"):
        with oracle_db.readonly(str(tmp_path / "links" / name)) as con:
            assert con.execute("select count(*) from message").fetchone()[0] == 2, name
    assert _tree(keep, tmp_path / "links") == before


# ---------------------------------------------------------------- a pipe under the database or its side files is never opened
def _release(fifo):
    """Lets a reader that is blocked on the pipe (the failing case) return, so a regression fails instead of hanging the run."""
    for _ in range(3):
        try:
            os.close(os.open(fifo, os.O_WRONLY | os.O_NONBLOCK))
            return
        except OSError:
            time.sleep(0.02)


def _scan_with_a_deadline(home, seconds=20):
    out = {}

    def run():
        out["result"] = home.scan()

    t = threading.Thread(target=run, daemon=True)
    t.start()
    t.join(seconds)
    return out.get("result")


@pytest.mark.skipif(not hasattr(os, "mkfifo"), reason="no named pipes here")
@pytest.mark.parametrize("suffix", ["-journal", "-wal", "-shm"])
def test_a_pipe_beside_the_database_is_named_and_the_scan_does_not_wait(home, tmp_path, suffix):
    target = home.path(".local", "share", "opencode")
    os.makedirs(target)
    db = os.path.join(target, "opencode.db")
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE message(id TEXT, session_id TEXT, data TEXT, time_created INTEGER)")
    con.execute("INSERT INTO message VALUES('m0','s',?,1)", (_message(100),))
    con.commit()
    con.close()
    fifo = db + suffix
    os.mkfifo(fifo)
    try:
        r = _scan_with_a_deadline(home)
        assert r is not None, f"the scan waits for a writer on {suffix}"
        assert any("opencode.db" in why and "not a regular file" in why for _, why in r.issues), r.issues
        assert home.total("opencode") == 0                      # named and left alone, never counted
    finally:
        _release(fifo)


@pytest.mark.skipif(not hasattr(os, "mkfifo"), reason="no named pipes here")
def test_a_pipe_beside_the_file_a_link_leads_to_is_refused_too(tmp_path):
    db = tmp_path / "elsewhere" / "real.db"
    db.parent.mkdir()
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE t(a)")
    con.commit()
    con.close()
    os.mkfifo(str(db) + "-journal")
    os.symlink(db, tmp_path / "link.db")
    try:
        with pytest.raises(sqlite3.Error, match="not a regular file"):
            with extdb.open_readonly(str(tmp_path / "link.db")):
                pass
    finally:
        _release(str(db) + "-journal")


# ---------------------------------------------------------------- S2: the price cache warning follows the folder, not the price pass
BODIES = {
    "openrouter": {"data": [{"id": "acme/m", "pricing": {"prompt": "0.000001", "completion": "0.000002"}}]},
    "litellm": {"acme-m": {"input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6}},
    "modelsdev": {"p": {"models": {"m": {"cost": {"input": 1, "output": 2}}}}},
}


class _Queue:
    def __init__(self):
        self.items = []

    def put(self, item):
        self.items.append(item)


def _price_issues(model):
    return [i for i in model.last_scan.issues if "price cache" in i[1]]


def _model_with_a_blocked_cache(tmp_path, monkeypatch):
    """(model, feed, blocker, calls): an AppModel whose price cache folder is a file until `blocker` is removed."""
    monkeypatch.delenv("TOKENBAR_OFFLINE", raising=False)           # conftest keeps the suite offline; this asks (a fake fetcher)
    from tokenbar.gui.model import AppModel
    from tokenbar.prices.book import PriceBook
    home = Home(tmp_path / "home")
    calls = []

    def fetch(source, etag):
        calls.append(source)
        return "ok", json.dumps(BODIES[source]).encode(), None

    blocker = tmp_path / "cache"
    blocker.write_text("a file where the cache folder should be")
    feed = pfeed.PriceFeed(str(blocker), fetcher=fetch)
    model = AppModel(env=home.env, store=home.store, book=PriceBook(home.env, pinned=False, offline=False, feed=feed))
    return model, feed, blocker, calls, home


def test_cache_warning_leaves_at_the_next_scan_when_the_folder_works_again(tmp_path, monkeypatch):
    from tokenbar.gui import app
    model, feed, blocker, calls, home = _model_with_a_blocked_cache(tmp_path, monkeypatch)
    app.background_pass(model, _Queue(), {})                        # the price pass: the cache cannot be written
    assert _price_issues(model) and sorted(calls) == sorted(pfeed.SOURCES)
    model.rescan()
    assert _price_issues(model)                                     # still unwritable: the warning stays
    blocker.unlink()                                                # the folder can be made now
    model.rescan()                                                  # a scan, not a price pass
    assert not _price_issues(model), model.last_scan.issues
    assert all(os.path.exists(blocker / f"prices-{s}.json") for s in pfeed.SOURCES)    # what was held is on disk
    assert sorted(calls) == sorted(pfeed.SOURCES)                   # and the network was not asked again
    home.store.close()


def test_cache_warning_leaves_at_the_next_scan_while_offline_too(tmp_path, monkeypatch):
    from tokenbar.gui import app
    model, feed, blocker, calls, home = _model_with_a_blocked_cache(tmp_path, monkeypatch)
    app.background_pass(model, _Queue(), {})
    assert _price_issues(model)
    model.set_offline(True)                                         # no price pass will come
    assert model.update_prices(force=True) is None
    assert _price_issues(model)                                     # "Update prices" does not wipe a warning that still holds
    blocker.unlink()
    model.rescan()
    assert not _price_issues(model), model.last_scan.issues
    home.store.close()


def test_update_prices_while_offline_writes_what_was_held_and_drops_the_warning(tmp_path, monkeypatch):
    from tokenbar.gui import app
    model, feed, blocker, calls, home = _model_with_a_blocked_cache(tmp_path, monkeypatch)
    app.background_pass(model, _Queue(), {})
    model.set_offline(True)
    blocker.unlink()
    assert model.update_prices(force=True) is None
    assert not _price_issues(model)
    home.store.close()


def test_a_scan_does_not_wait_for_a_price_pass_that_holds_the_gate(tmp_path, monkeypatch):
    model, feed, blocker, calls, home = _model_with_a_blocked_cache(tmp_path, monkeypatch)
    assert pfeed._gate.acquire(blocking=False)                      # a download is running somewhere
    try:
        done = []
        t = threading.Thread(target=lambda: (model.rescan(), done.append(1)), daemon=True)
        t.start()
        t.join(10)
        assert done, "a scan waited for the price lock"
    finally:
        pfeed._gate.release()
    home.store.close()


# ---------------------------------------------------------------- CLI: argument errors are filtered; --output and --db failures are one line
def _run(argv, capsys):
    rc = None
    try:
        rc = cli.run_cli(argv)
    except SystemExit as e:                 # argparse's own exit
        rc = e.code
    return rc, capsys.readouterr()


def test_unrecognized_argument_is_filtered_like_every_other_cli_line(capsys):
    rc, out = _run(["--bogus\x1b[31mRED‮"], capsys)
    assert rc == 2
    err = out.err.splitlines()[-1]
    assert err.startswith("tokenbar: error: unrecognized arguments: --bogus")
    assert "\x1b" not in out.err and "‮" not in out.err and "RED" in err


def test_an_error_about_a_bad_value_keeps_its_message(capsys):
    rc, out = _run(["--window", "9y\x1b[0m"], capsys)
    assert rc == 2 and "\x1b" not in out.err and "invalid choice" in out.err


@pytest.mark.parametrize("flags", [["--no-scan", "--offline"], ["--no-scan", "--offline", "--rebuild"], ["--index"]])
def test_db_with_an_embedded_nul_is_one_line_and_exit_2_with_or_without_rebuild(tmp_path, capsys, flags):
    rc, out = _run(["--home", str(tmp_path), "--db", str(tmp_path / "a\x00b.sqlite")] + flags, capsys)
    assert rc == 2 and out.err.startswith("tokenbar: ") and "Traceback" not in out.err
    assert len(out.err.strip().splitlines()) == 1


def _cli_args(tmp_path):
    home = tmp_path / "home"
    home.mkdir(exist_ok=True)
    return ["--home", str(home), "--db", str(tmp_path / "idx.sqlite"), "--no-scan", "--offline"]


@pytest.mark.parametrize("where", ["missing_folder", "a_folder"])
@pytest.mark.parametrize("extra", [[], ["--json"]])
def test_output_that_cannot_be_written_is_one_line_and_exit_2(tmp_path, capsys, where, extra):
    target = str(tmp_path / "nope" / "o.json") if where == "missing_folder" else str(tmp_path)
    rc, out = _run(_cli_args(tmp_path) + extra + ["--output", target], capsys)
    assert rc == 2 and "Traceback" not in out.err
    lines = out.err.strip().splitlines()
    assert len(lines) == 1 and lines[0].startswith("tokenbar: ") and "--output" in lines[0]


def test_version_to_an_output_that_cannot_be_written_is_one_line_and_exit_2(tmp_path, capsys):
    rc, out = _run(["--version", "--output", str(tmp_path / "nope" / "v.txt")], capsys)
    assert rc == 2 and "Traceback" not in out.err and len(out.err.strip().splitlines()) == 1


def test_output_that_can_be_written_still_is(tmp_path, capsys):
    target = tmp_path / "o.json"
    rc, out = _run(_cli_args(tmp_path) + ["--json", "--output", str(target)], capsys)
    assert rc == 0 and json.loads(target.read_text(encoding="utf-8")) is not None and out.out == ""


def test_output_name_with_control_characters_is_filtered(tmp_path, capsys):
    rc, out = _run(_cli_args(tmp_path) + ["--output", str(tmp_path / "no\x1b[31m" / "o.json")], capsys)
    assert rc == 2 and "\x1b" not in out.err


# ---------------------------------------------------------------- a price download follows a redirect only to an HTTPS address
class _Redirecting:
    """Server A answers every GET with a 302 to `location(b_port)`; server B counts what reaches it."""

    def __init__(self, location):
        self.b_hits = 0
        outer = self

        class B(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                outer.b_hits += 1
                body = json.dumps(BODIES["litellm"]).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        self.b = http.server.ThreadingHTTPServer(("127.0.0.1", 0), B)
        target = location(self.b.server_address[1])

        class A(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(302)
                self.send_header("Location", target)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *a):
                pass

        self.a = http.server.ThreadingHTTPServer(("127.0.0.1", 0), A)
        self.url = f"http://127.0.0.1:{self.a.server_address[1]}/start"
        self.threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in (self.a, self.b)]

    def __enter__(self):
        for t in self.threads:
            t.start()
        return self

    def __exit__(self, *exc):
        for s in (self.a, self.b):
            s.shutdown()
            s.server_close()


def test_a_redirect_to_plain_http_is_refused_before_a_request_is_made(monkeypatch):
    with _Redirecting(lambda port: f"http://127.0.0.1:{port}/catalogue.json") as srv:
        monkeypatch.setitem(pfeed.URLS, "litellm", srv.url)
        with pytest.raises(pfeed.FetchError, match="HTTPS"):
            pfeed.url_fetcher("litellm", None)
        assert srv.b_hits == 0                                      # the second address was never asked


def test_a_redirect_to_ftp_is_refused_and_not_even_tried(monkeypatch):
    with _Redirecting(lambda port: f"ftp://127.0.0.1:{port}/x.json") as srv:
        monkeypatch.setitem(pfeed.URLS, "litellm", srv.url)
        with pytest.raises(pfeed.FetchError) as caught:
            pfeed.url_fetcher("litellm", None)
        assert "HTTPS" in str(caught.value) and "refused" in str(caught.value).lower()      # not 'Connection refused' from a dial


def test_a_redirect_to_https_is_followed():
    import urllib.request
    handler = pfeed._HttpsOnlyRedirects()
    req = urllib.request.Request("https://catalogue.example/a.json")
    follow = handler.redirect_request(req, None, 302, "Found", {}, "https://mirror.example/b.json")
    assert follow is not None and follow.full_url == "https://mirror.example/b.json"
    for bad in ("http://mirror.example/b.json", "ftp://mirror.example/b.json", "file:///etc/passwd", "HTTP://MIRROR.example/b.json"):
        with pytest.raises(Exception, match="HTTPS"):
            handler.redirect_request(req, None, 302, "Found", {}, bad)


# ---------------------------------------------------------------- scripts/oracle.py and oracle_g3.py apply the apps' rules (app <-> oracle equality)
def _oracle_report(home, window="all"):
    env = {"HOME": home.root, "PATH": os.environ.get("PATH", ""), "TOKENBAR_PRICES_PINNED": "1"}
    proc = subprocess.run([sys.executable, os.path.join(SCRIPTS, "oracle.py"), window], capture_output=True, text=True, env=env, cwd=home.root)
    assert proc.returncode == 0, proc.stderr
    return json.loads(proc.stdout)


def _same_as_the_app(home, expected_total, expected_calls, window="all"):
    home.scan()
    mine = home.report(window)
    oracle = _oracle_report(home, window)
    assert (mine.tokens, mine.calls) == (expected_total, expected_calls), "the app"
    assert (oracle["total"], oracle["calls"]) == (expected_total, expected_calls), "the oracle"


def _qwen_home(home, call_id):
    call = {"id": call_id, "timestamp": "2026-11-06T10:00:00.000Z", "authType": "qwen-oauth", "model": "qwen3-coder", "sessionId": "S",
            "inputTokens": 100, "cachedTokens": 0, "outputTokens": 10, "thoughtsTokens": 0}
    home.write(".qwen/usage/token-usage-1.jsonl", json.dumps(call) + "\n" + json.dumps(call) + "\n")      # the same call logged twice
    summary = {"sessionId": "S", "timestamp": "2026-11-06T11:00:00.000Z",
               "models": {"qwen3-coder": {"inputTokens": 250, "cachedTokens": 0, "outputTokens": 50, "thoughtsTokens": 0, "totalTokens": 300}}}
    home.write(".qwen/usage_record.jsonl", json.dumps(summary) + "\n")


@POSIX_ONLY
@pytest.mark.parametrize("call_id", ["q1", "adk", "adj"])
def test_oracle_counts_a_qwen_call_logged_twice_once_in_what_the_summary_adds(home, call_id):
    _qwen_home(home, call_id)
    _same_as_the_app(home, 300, 1)              # the call (110) and the rest of the summary (150 + 40), never 80 of it


def _cost_home(home, *cost_lines, session="s1"):
    row = claude_line("m1", "r1", 100, 10)
    row["sessionId"] = session
    home.write(".claude/projects/p/a.jsonl", json.dumps(row) + "\n" + "".join(cost_lines))


def _cost(started, tokens, out, session="s1"):
    record = {"type": "cost-state", "startTime": started, "modelUsage": {"claude-opus-5-5": {"inputTokens": tokens, "outputTokens": out}}}
    if session is not None:
        record["sessionId"] = session
    # the oracle looks for the line's literal start (`{"type":"cost-state"`), as the Mac app's reader does
    return json.dumps(record, separators=(",", ":")) + "\n"


@POSIX_ONLY
def test_oracle_skips_a_cost_record_without_a_session_like_the_apps(home):
    line = _cost("2026-11-06T10:00:00.000Z", 500, 50, session=None)
    assert line.startswith('{"type":"cost-state"')
    _cost_home(home, line)
    _same_as_the_app(home, 110, 1)


@POSIX_ONLY
def test_oracle_makes_two_cost_records_of_one_second_one_run_like_the_apps(home):
    _cost_home(home, _cost("2026-11-06T10:00:00.100Z", 300, 50), _cost("2026-11-06T10:00:00.900Z", 400, 60))
    _same_as_the_app(home, 460, 1)              # the larger counter of the run (400 + 60), not 300 + 50 + 400 + 60


def _crush_both_layouts(home, rows, messages=()):
    """One Crush database found by the Windows app (AppData/Local/crush) and by the oracle (~/.local/share/crush)."""
    path = home.path("AppData", "Local", "crush", "crush.db")
    os.makedirs(os.path.dirname(path))
    doc = json.dumps({"projects": [{"data_dir": os.path.dirname(path)}]})
    home.write("AppData/Local/crush/projects.json", doc)
    home.write(".local/share/crush/projects.json", doc)
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE sessions(id TEXT, prompt_tokens INTEGER, completion_tokens INTEGER, updated_at, created_at)")
    con.execute("CREATE TABLE messages(session_id TEXT, role TEXT, model TEXT, provider TEXT, created_at INTEGER)")
    con.executemany("INSERT INTO sessions VALUES(?,?,?,?,?)", rows)
    con.executemany("INSERT INTO messages VALUES(?,?,?,?,?)", messages)
    con.commit()
    con.close()


@POSIX_ONLY
def test_oracle_dates_a_crush_session_by_its_creation_when_the_update_time_is_no_time(home):
    now = int(__import__("time").time())
    _crush_both_layouts(home, [("s1", 500, 0, "garbage", now - 60), ("s2", 100, 0, 0, now - 60), ("s3", 7, 0, -5, now - 60)])
    _same_as_the_app(home, 607, 3, window="24h")          # all three inside the last day: none falls out with a time of 0


def _wal_antigravity(home, tmp_path, steps, zero_main=False):
    """An Antigravity conversation as a running tool leaves it: the schema is in the .db, the newest steps only in the -wal."""
    from test_winfix import pb, pv
    live = tmp_path / "live-ag"
    live.mkdir()
    con = sqlite3.connect(live / "c.db")
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA wal_autocheckpoint=0")
    con.execute("CREATE TABLE gen_metadata(idx INTEGER, data BLOB)")
    con.execute("CREATE TABLE steps(idx INTEGER, step_type INTEGER, metadata BLOB)")
    con.execute("INSERT INTO gen_metadata VALUES(0, ?)", (pb(1, pv(3, 1) + pb(19, b"model-a")),))
    con.commit()
    con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    for i, (inp, out) in enumerate(steps):
        con.execute("INSERT INTO steps VALUES(?,15,?)", (i, pb(9, pv(1, 1) + pv(2, inp) + pv(3, out)) + pb(8, pv(1, 1793968800))))
    con.commit()
    target = home.path(".gemini", "antigravity-cli", "conversations")
    os.makedirs(target)
    shutil.copy(live / "c.db", target)
    shutil.copy(str(live / "c.db") + "-wal", os.path.join(target, "c.db-wal"))
    con.close()


@POSIX_ONLY
def test_oracle_reads_the_wal_beside_an_antigravity_database(home, tmp_path):
    _wal_antigravity(home, tmp_path, [(300, 40)])
    assert os.path.getsize(home.path(".gemini", "antigravity-cli", "conversations", "c.db-wal")) > 0
    _same_as_the_app(home, 340, 1)


@POSIX_ONLY
def test_oracle_finds_a_custom_recursive_opencode_database_wherever_it_is(home):
    folder = home.path("work", "fork", "sub")
    os.makedirs(folder)
    con = sqlite3.connect(os.path.join(folder, "opencode.db"))          # not under data/opencode/
    con.execute("CREATE TABLE message(id TEXT, session_id TEXT, data TEXT, time_created INTEGER)")
    con.execute("INSERT INTO message VALUES('m0','s',?,1)", (_message(550),))
    con.commit()
    con.close()
    home.write(".config/tokenbar/custom-sources.json", json.dumps(
        {"sources": [{"id": "my-fork", "family": "opencode-sqlite", "paths": ["~/work/fork"], "keyPrefix": "myfork", "recursive": True}]}))
    oracle = _oracle_report(home)                                       # custom sources are the Mac app's: the oracle has no Windows twin to equal
    assert (oracle["total"], oracle["calls"]) == (550, 1)


# ---------------------------------------------------------------- scripts/update-prices.py: a negative OpenRouter price is never written into the table
@pytest.fixture(scope="module")
def update_prices():
    sys.path.insert(0, SCRIPTS)
    try:
        spec = importlib.util.spec_from_file_location("update_prices_907", os.path.join(SCRIPTS, "update-prices.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        yield module
    finally:
        sys.path.remove(SCRIPTS)


def test_update_prices_reads_a_negative_base_cache_price_as_not_said(update_prices):
    got = update_prices.rates({"prompt": "0.000001", "completion": "0.000002", "input_cache_read": "-1", "input_cache_write": "-0.5",
                               "input_cache_write_1h": "-0.5"})
    assert got == {"input": 1.0, "output": 2.0, "cacheRead": 1.0, "cacheWrite": 1.0, "cacheWrite1h": 1.0}     # the input price, like the apps


@pytest.mark.parametrize("bad", [{"input_cache_read": "-1"}, {"prompt": "-0.000001"}, {"completion": "-1"}])
def test_update_prices_refuses_a_tier_that_holds_a_negative_rate(update_prices, bad):
    base = {"prompt": "0.000001", "completion": "0.000002"}
    with pytest.raises(ValueError):
        update_prices.rates({**base, **bad}, {"input": 1.0, "output": 2.0})       # a tier (it has a fallback): the apps drop the row


def test_update_prices_entry_stops_on_a_negative_price_instead_of_writing_it(update_prices):
    catalogue = {"a/m": {"pricing": {"prompt": "0.000001", "completion": "0.000002",
                                     "overrides": [{"min_prompt_tokens": 200000, "input_cache_read": "-1"}]}}}
    with pytest.raises(SystemExit, match="negatif"):
        update_prices.entry("k", {"name": "K", "or": "a/m"}, catalogue, {"entries": {}, "date": "2026-11-01"})
    good = update_prices.entry("k", {"name": "K", "or": "a/m"}, {"a/m": {"pricing": {"prompt": "0.000001", "completion": "0.000002"}}},
                               {"entries": {}, "date": "2026-11-01"})
    assert (good["input"], good["output"], good["cacheRead"]) == (1.0, 2.0, 1.0)


# ---------------------------------------------------------------- price names and catalogue keys: the Mac's rules
def _pricer():
    return engine.Pricer([engine.Catalogue("openrouter", {"claude-opus-5-5": [4.0, 20.0, 0, 0, 0, [], "Claude Opus 5.5"]}, {})], [], {}, [])


@pytest.mark.parametrize("suffix", ["\n", "\r", "\x0b", "\x0c", "\x1c", "\x85", "\u2028", "\u2029"])
def test_a_name_that_ends_in_a_line_break_or_control_character_has_no_price_like_on_the_mac(suffix):
    assert _pricer().resolve("anthropic", "claude-opus-5-5") is not None
    assert _pricer().resolve("anthropic", "claude-opus-5-5" + suffix) is None
    assert _pricer().resolve("anthropic", suffix + "claude-opus-5-5") is None


@pytest.mark.parametrize("space", ["\t", " ", "\u00a0", "\u1680", "\u2000", "\u2005", "\u200a", "\u200b", "\u202f", "\u205f", "\u3000"])
def test_the_spaces_the_mac_trims_are_trimmed(space):
    assert _pricer().resolve("anthropic", space + "claude-opus-5-5" + space) is not None


@pytest.mark.parametrize("digits", ["\u0662\u0660\u0662\u0665\u0660\u0661\u0660\u0661", "\u0966" * 8])
def test_a_date_of_non_ascii_digits_is_no_date(digits):
    assert engine.identity("minimax-m2-5-" + digits) == "minimax-m2-5-" + digits
    assert engine.identity("minimax-m2-5-20250101") == "minimax-m2-5"


def _litellm(**extra):
    base = {"input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6}
    return {"good-model": dict(base, input_cost_per_token_above_200k_tokens=2e-6),
            "evil-model": dict(base, **{"input_cost_per_token_above_" + "9" * 5000 + "k_tokens": 3e-6}),
            "arabic-tier": dict(base, **{"input_cost_per_token_above_\u0662\u0660\u0660k_tokens": 3e-6}), **extra}


def test_one_corrupt_tier_key_spoils_its_row_not_the_whole_catalogue():
    rows = engine.litellm_rows(_litellm())
    assert set(rows) == {"good-model", "arabic-tier"}                    # evil-model is dropped, the rest is kept (the Mac's answer)
    assert rows["good-model"][5][0][0] == 200_001
    assert rows["arabic-tier"][5] == []                                  # a tier key of non-ASCII digits is no tier


def test_a_catalogue_with_one_corrupt_tier_key_is_still_the_catalogue(tmp_path):
    feed = pfeed.PriceFeed(str(tmp_path / "c"), fetcher=lambda s, e: ("ok", json.dumps(_litellm() if s == "litellm" else BODIES[s]).encode(), None))
    report = feed.refresh()
    assert "litellm" in report.updated and "litellm" not in report.failed


@POSIX_ONLY
def test_pricelib_has_the_same_rules():
    sys.path.insert(0, SCRIPTS)
    try:
        pricelib = importlib.import_module("pricelib")
    finally:
        sys.path.remove(SCRIPTS)
    assert set(pricelib.litellm_rows(_litellm())) == {"good-model", "arabic-tier"}
    assert pricelib.identity("minimax-m2-5-\u0662\u0660\u0662\u0665\u0660\u0661\u0660\u0661") == "minimax-m2-5-\u0662\u0660\u0662\u0665\u0660\u0661\u0660\u0661"
    assert pricelib.trim("\n x \n") == "\n x \n" and pricelib.trim("\u200b x\u3000") == "x"
    p = pricelib.Pricer([pricelib.Catalogue("openrouter", {"claude-opus-5-5": [4.0, 20.0, 0, 0, 0, [], ""]}, {})], [], {}, []) \
        if hasattr(pricelib, "Catalogue") else None
    if p is not None:
        assert p.resolve("anthropic", "claude-opus-5-5\n") is None


@pytest.mark.parametrize("value, shown", [(0.001, "0.001"), (0.0023, "0.002"), (0.005, "0.005"), (0.05, "0.05"), (0.0004, "0.000"),
                                          (0.1, "0.1"), (2.0, "2"), (3.5, "3.5"), (15.0, "15"), (150.0, "150"), (0, "0")])
def test_a_paid_rate_below_one_cent_is_not_shown_as_zero(value, shown):
    assert fmt.rate(value) == shown


# ---------------------------------------------------------------- a folder deleted during the walk is silent even where Windows says "access denied"
def test_walk_does_not_name_a_folder_that_was_deleted_when_the_error_is_a_permission_error(tmp_path, monkeypatch):
    from tokenbar import util
    (tmp_path / "gone").mkdir()
    (tmp_path / "keep").mkdir()
    (tmp_path / "keep" / "x.jsonl").write_text("{}\n")
    real = os.scandir

    def scandir(p="."):
        if os.fspath(p).endswith("gone"):
            os.rmdir(p)                                          # deleted while it was being opened (delete pending)
            raise PermissionError(13, "Access is denied", os.fspath(p))
        return real(p)

    monkeypatch.setattr(os, "scandir", scandir)
    util.take_walk_errors()
    found = util.walk_files(str(tmp_path), lambda n: n.endswith(".jsonl"))
    assert [os.path.basename(p) for p in found] == ["x.jsonl"]
    assert util.take_walk_errors() == []


# ---------------------------------------------------------------- scripts/check-paths.sh (the check.sh path audit)
CHECK_PATHS = os.path.join(SCRIPTS, "check-paths.sh")
BASH = shutil.which("bash")
GIT = shutil.which("git")
needs_bash_git = pytest.mark.skipif(not (BASH and GIT) or sys.platform == "win32", reason="needs bash and git (CI runs it on POSIX)")


def _git_repo(tmp_path, files):
    repo = tmp_path / "repo"
    repo.mkdir()
    for name, body in files.items():
        p = repo / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body, encoding="utf-8")
    env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull}
    for cmd in (["init", "-q"], ["add", "-A"]):
        subprocess.run([GIT, *cmd], cwd=repo, env=env, check=True, capture_output=True)
    return repo


def _check(repo):
    return subprocess.run([BASH, CHECK_PATHS, str(repo)], capture_output=True, text=True)


# The traps are written in pieces so that this file itself holds no machine path.
LINUX_HOME = "/ho" + "me/alice/proj"
WINDOWS_HOME = "C:\\" + "\\Us" + "ers\\\\bob\\\\x"
MAC_DOCS = "see /Us" + "ers/carol/secret/"


@needs_bash_git
@pytest.mark.parametrize("where, body", [("Sources/x.swift", f'let a = "{LINUX_HOME}"\n'),
                                         ("Sources/y.swift", f'let a = "{WINDOWS_HOME}"\n'),
                                         ("docs/a.md", MAC_DOCS + "\n"),
                                         ("windows/tokenbar/z.py", "p = 'C:/Us" + "ers/dave/x'\n"),
                                         ("packaging/p.sh", "cd " + LINUX_HOME + "\n")])
def test_check_paths_catches_a_home_folder_of_every_shape_everywhere(tmp_path, where, body):
    repo = _git_repo(tmp_path, {where: body, "README.md": "clean\n"})
    run = _check(repo)
    assert run.returncode == 1 and where in run.stdout and "makineye özgü yol" in run.stdout, run.stdout


@needs_bash_git
def test_check_paths_passes_on_a_clean_tree_and_on_placeholders(tmp_path):
    repo = _git_repo(tmp_path, {"README.md": "unzip to `C:\\" + "Us" + "ers\\you\\TokenBar`, run /ho" + "me/.claude/x\n",
                                "Sources/a.swift": 'let d = dir + "/ho' + 'me/.claude/projects"\n'})
    run = _check(repo)
    assert run.returncode == 0 and "temiz" in run.stdout, run.stdout


@needs_bash_git
def test_check_paths_without_git_says_it_could_not_look_and_fails(tmp_path):
    tarball = tmp_path / "tarball"
    tarball.mkdir()
    (tarball / "a.txt").write_text("clean\n")
    run = subprocess.run([BASH, CHECK_PATHS, str(tarball)], capture_output=True, text=True, env={**os.environ, "GIT_CEILING_DIRECTORIES": str(tmp_path)})
    assert run.returncode == 1 and "denetlenemedi" in run.stdout, run.stdout


@needs_bash_git
def test_check_paths_passes_on_this_repository():
    run = subprocess.run([BASH, CHECK_PATHS], capture_output=True, text=True)
    if "denetlenemedi" in run.stdout:
        pytest.skip("not a git checkout")
    assert run.returncode == 0, run.stdout


@POSIX_ONLY
def test_oracle_db_reads_a_wal_database_that_was_closed_cleanly(tmp_path):
    """Header says WAL, no -wal and no -shm (a tool that exited): read in place, immutable, as the apps do (a copy cannot be opened)."""
    sys.path.insert(0, SCRIPTS)
    try:
        oracle_db = importlib.import_module("oracle_db")
    finally:
        sys.path.remove(SCRIPTS)
    path = str(tmp_path / "closed.db")
    con = sqlite3.connect(path)
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("CREATE TABLE t(a)")
    con.execute("INSERT INTO t VALUES (1), (2)")
    con.commit()
    con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    con.close()
    for leftover in ("-wal", "-shm"):
        if os.path.exists(path + leftover):
            os.remove(path + leftover)
    before = _tree(tmp_path)
    with oracle_db.readonly(path) as c:
        assert c.execute("select count(*) from t").fetchone()[0] == 2
    assert _tree(tmp_path) == before


def test_empty_main_file_whose_page_cannot_be_given_is_named_not_read_as_empty(home, tmp_path, monkeypatch):
    """The copy of a 0-byte database gets one page so SQLite opens its -wal; if that write fails (a full temporary
    folder), the file is a problem of the scan, as on the Mac, never an empty database counted as read."""
    from tokenbar import extdb
    live = LiveDB(tmp_path / "x")
    live.add(100, 200)
    target = home.path(".local", "share", "opencode")
    os.makedirs(target)
    shutil.copy(live.path + "-wal", os.path.join(target, "opencode.db-wal"))
    live.close()
    with open(os.path.join(target, "opencode.db"), "wb"):
        pass
    real_open = open

    def failing_open(path, mode="r", *a, **k):
        if ("w" in mode and extdb.SCRATCH_PREFIX in str(path) and not str(path).endswith("-wal")
                and os.path.exists(path) and os.path.getsize(path) == 0):        # the page for the copied 0-byte main
            raise OSError(28, "No space left on device")
        return real_open(path, mode, *a, **k)
    monkeypatch.setattr("builtins.open", failing_open)
    r = home.scan()
    monkeypatch.undo()
    assert [i for i in r.issues if "opencode" in i[0].lower() and "No space left" in i[1]], r.issues
    r = home.scan()                                              # the next scan, with room again, reads it
    assert home.total("opencode") == 300, r.issues
