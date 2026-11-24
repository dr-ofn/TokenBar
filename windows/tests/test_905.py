"""9.0.5 Windows findings from the 9.0.4 scan, and the rules the Mac app got in the same release: each test reproduces one."""
import http.client
import http.server
import json
import os
import stat
import threading

import pytest

from conftest import claude_line
from tokenbar import util
from tokenbar.prices import engine
from tokenbar.prices import feed as pfeed
from tokenbar.prices.feed import FetchError

posix_only = pytest.mark.skipif(os.name == "nt" or (hasattr(os, "geteuid") and os.geteuid() == 0),
                                reason="needs POSIX permissions that bind the current user")


def _claude(home, rel, *rows):
    return home.jsonl(".claude/projects/" + rel, *rows)


# ---------------------------------------------------------------- 1. K1: an unreadable folder under a tool's root is named
def test_walk_files_names_a_folder_it_cannot_read(tmp_path, monkeypatch):
    root = tmp_path / "root"
    (root / "ok").mkdir(parents=True)
    (root / "locked").mkdir()
    (root / "ok" / "a.jsonl").write_text("{}\n")
    (root / "locked" / "b.jsonl").write_text("{}\n")
    real = os.scandir

    def scandir(p="."):
        if os.fspath(p).endswith("locked"):
            raise PermissionError(13, "Permission denied", os.fspath(p))
        return real(p)

    monkeypatch.setattr(os, "scandir", scandir)
    util.take_walk_errors()
    found = util.walk_files(str(root), lambda n: n.endswith(".jsonl"))
    assert [os.path.basename(p) for p in found] == ["a.jsonl"]
    assert util.take_walk_errors() == [str(root / "locked")]
    assert util.take_walk_errors() == []                                 # taken once


def test_a_missing_root_is_no_problem(tmp_path):
    util.take_walk_errors()
    assert util.walk_files(str(tmp_path / "nowhere"), lambda n: True) == []
    assert util.take_walk_errors() == []


@posix_only
def test_scan_names_an_unreadable_project_folder_and_counts_the_rest(home):
    _claude(home, "good/a.jsonl", claude_line("m1", "r1", 10, 5))
    _claude(home, "locked/b.jsonl", claude_line("m2", "r2", 100, 50))
    locked = os.path.dirname(home.path(".claude", "projects", "locked", "b.jsonl"))
    os.chmod(locked, 0)
    try:
        result = home.scan()
    finally:
        os.chmod(locked, 0o755)
    assert [m for _, m in result.issues if m == f"{locked}: cannot be read"], result.issues
    assert home.total("claude-code") == 15                                       # the readable file still counts
    os.chmod(locked, 0)                                                     # named on every pass while it stays unreadable
    try:
        assert [m for _, m in home.scan().issues if "cannot be read" in m]
    finally:
        os.chmod(locked, 0o755)
    assert not [m for _, m in home.scan().issues if "cannot be read" in m]  # readable again: no complaint
    assert home.total("claude-code") == 165


def test_scan_without_any_tool_folder_reports_no_unreadable_folder(home):
    result = home.scan()
    assert not [m for _, m in result.issues if "cannot be read" in m]


# ---------------------------------------------------------------- 2. K2: a line over the limit is skipped, once named
def test_overlong_line_is_skipped_and_the_file_named_once(home, monkeypatch):
    monkeypatch.setattr(util, "MAX_LINE_BYTES", 400)
    long_row = claude_line("m-long", "r-long", 7, 7)
    long_row["pad"] = "x" * 2000
    p = _claude(home, "p/a.jsonl", claude_line("m1", "r1", 10, 5), long_row, claude_line("m3", "r3", 20, 5))
    result = home.scan()
    named = [m for _, m in result.issues if p in m]
    assert len(named) == 1 and "400" in named[0] and "skipped" in named[0], result.issues
    assert home.total("claude-code") == 40                                       # the lines either side of it count
    assert home.store.file_records()[p].offset == os.path.getsize(p)        # the offset moved past it
    assert len(home.store.events_since(None)) == 2
    home.scan()                                                              # nothing is read twice
    assert home.total("claude-code") == 40 and len(home.store.events_since(None)) == 2


def test_overlong_line_is_skipped_by_iter_lines_without_losing_the_cursor(tmp_path, monkeypatch):
    monkeypatch.setattr(util, "MAX_LINE_BYTES", 50)
    f = tmp_path / "x.jsonl"
    f.write_bytes(b'{"a":1}\n' + b"y" * 500 + b'\n{"b":2}\n')
    got = list(util.iter_lines(str(f)))
    # (the skipped line moves the cursor as a blank line would: delivered as "", never with its content)
    assert [l for l, _ in got if l] == ['{"a":1}', '{"b":2}'] and all(len(l) < 50 for l, _ in got)
    assert got[-1][1] == f.stat().st_size
    assert util.take_overlong() == [str(f)]


# ---------------------------------------------------------------- 2. K3: a .jsonl that is no regular file is not opened
@pytest.mark.skipif(not hasattr(os, "mkfifo"), reason="no named pipes here")
def test_fifo_named_jsonl_is_skipped_without_opening_it(home):
    _claude(home, "p/a.jsonl", claude_line("m1", "r1", 10, 5))
    fifo = home.path(".claude", "projects", "p", "pipe.jsonl")
    os.mkfifo(fifo)
    assert stat.S_ISFIFO(os.stat(fifo).st_mode)
    out = {}
    t = threading.Thread(target=lambda: out.update(r=home.scan()), daemon=True)
    t.start()
    t.join(20)
    assert not t.is_alive(), "the scan opened the pipe and hangs"
    assert not [m for _, m in out["r"].issues if "pipe.jsonl" in m]        # skipped, not even a complaint
    assert home.total("claude-code") == 15


@pytest.mark.skipif(not hasattr(os, "mkfifo"), reason="no named pipes here")
def test_fifo_named_json_for_a_whole_file_reader_is_skipped_too(home):
    os.makedirs(home.path("AppData", "Roaming", "Code", "User", "globalStorage", "saoudrizwan.claude-dev", "tasks", "t1"))
    os.mkfifo(home.path("AppData", "Roaming", "Code", "User", "globalStorage", "saoudrizwan.claude-dev", "tasks", "t1", "ui_messages.json"))
    out = {}
    t = threading.Thread(target=lambda: out.update(r=home.scan()), daemon=True)
    t.start()
    t.join(20)
    assert not t.is_alive(), "the scan opened the pipe and hangs"


# ---------------------------------------------------------------- 2. K4: JSON true/false is no number in a catalogue
def test_catalogue_booleans_are_not_numbers():
    assert engine.num(True) == 0.0 and engine.num(False) == 0.0
    lite = {"bool-in": {"mode": "chat", "input_cost_per_token": True, "output_cost_per_token": 2e-6},
            "good": {"mode": "chat", "input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6},
            "tier-bool": {"mode": "chat", "input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6,
                          "input_cost_per_token_above_200k_tokens": True},
            "mode-bool": {"mode": True, "input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6},
            "mode-num": {"mode": 5, "input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6}}
    rows = engine.litellm_rows(lite)
    assert "good" in rows and "bool-in" not in rows and "mode-bool" not in rows and "mode-num" not in rows
    assert rows["tier-bool"][5] == []                                    # no tier from a boolean
    dev = {"prov": {"models": {"bool": {"cost": {"input": True, "output": 2}},
                               "good": {"cost": {"input": 1, "output": 2}},
                               "tiers-bool": {"cost": {"input": 1, "output": 2, "tiers": [
                                   {"tier": {"type": "context", "size": True}, "input": 5}]}}}}}
    rows = engine.modelsdev_rows(dev)
    assert "prov/good" in rows and "prov/bool" not in rows and "prov/tiers-bool" not in rows
    router = {"data": [{"id": "a/bool", "pricing": {"prompt": True, "completion": True}},
                       {"id": "a/good", "pricing": {"prompt": "0.000001", "completion": "0.000002"}}]}
    rows = engine.openrouter_rows(router)
    assert "a/good" in rows and "a/bool" not in rows


def test_aliases_still_read_a_boolean_as_one_or_zero(tmp_path):
    """model-aliases.json is the user's own file: true counts as 1 there (unchanged, as the Mac app)."""
    assert util.count({"n": True}, "n") == 1 and util.count({"n": False}, "n") == 0


# ---------------------------------------------------------------- 3. a bad-file verdict that goes with the file's absence
def test_badfile_warning_comes_back_when_the_file_returns_unchanged(home, monkeypatch):
    from test_903 import _oversize_archive
    p = _oversize_archive(home, monkeypatch)
    first = home.scan()
    assert [m for _, m in first.issues if "too large" in m]
    events = home.store.events_since(None)
    total = home.total("codex")
    assert len(events) == 1 and total > 0
    away = p + ".away"
    os.rename(p, away)
    gone = home.scan()
    assert not [m for _, m in gone.issues if "too large" in m]
    assert home.store.meta_prefix("badfile:") == [] and p not in home.store.file_records()
    os.rename(away, p)                                                  # the same inode, size and time
    back = home.scan()
    assert [m for _, m in back.issues if "rollout-big" in m and "too large" in m], back.issues
    again = home.scan()
    assert [m for _, m in again.issues if "rollout-big" in m and "too large" in m]
    assert home.store.events_since(None) == events                      # read twice, counted once
    assert home.total("codex") == total


# ---------------------------------------------------------------- 4. a body shorter than its Content-Length is an incomplete download
class _Server:
    def __init__(self, body: bytes, length: int, extra=()):
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Length", str(length))
                for k, v in extra:
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(body)
                self.wfile.flush()
                self.close_connection = True

            def log_message(self, *a):
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}/"
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *a):
        self.httpd.shutdown()
        self.httpd.server_close()


@pytest.mark.parametrize("extra", [(), (("Content-Encoding", "gzip"),)], ids=["plain", "gzip"])
def test_body_shorter_than_content_length_is_an_incomplete_download(monkeypatch, extra):
    with _Server(b"abc", 100, extra) as s:
        monkeypatch.setitem(pfeed.URLS, "litellm", s.url)
        with pytest.raises(FetchError, match="incomplete download"):
            pfeed.url_fetcher("litellm", None)


def test_complete_body_with_content_length_is_still_fine(monkeypatch):
    with _Server(b'{"a":1}', 7) as s:
        monkeypatch.setitem(pfeed.URLS, "litellm", s.url)
        assert pfeed.url_fetcher("litellm", None)[:2] == ("ok", b'{"a":1}')


def test_refresh_reports_the_cut_download_as_incomplete_not_as_a_wrong_catalogue(tmp_path, monkeypatch):
    with _Server(b"abc", 100) as s:
        for source in pfeed.URLS:
            monkeypatch.setitem(pfeed.URLS, source, s.url)
        rep = pfeed.PriceFeed(str(tmp_path), now=lambda: 10 ** 9).refresh()
    assert set(rep.failed.values()) == {"incomplete download"}


# ---------------------------------------------------------------- 5. the README tells the retry schedule the code keeps
def test_readme_retry_wording_matches_the_schedule():
    app = pytest.importorskip("tokenbar.gui.app")
    hours = [min(app.PRICE_CHECK_SECONDS, app.PRICE_RETRY_SECONDS << (n - 1)) / 3600 for n in range(1, 6)]
    assert hours == [1, 2, 4, 6, 6]
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    for name in ("README.md", "README.tr.md"):
        with open(os.path.join(base, name), encoding="utf-8") as f:
            text = f.read()
        assert "within the hour" not in text and "bir saat içinde" not in text, name      # the retry comes AFTER an hour
        assert "2, 4" in text and "6" in text, name


def test_catalogue_names_lose_terminal_and_direction_controls_as_on_the_mac():
    """9.0.5 pre-release review: the Mac strips C0/DEL/C1 and the bidi embedding/isolate controls from a catalogue's
    model name and source line (ModelNames.displaySafe); Windows printed them as they came."""
    from tokenbar.prices import engine
    e = engine.entry_from_row("openrouter", "OpenRouter", "acme/evil\x1b-1", [1e-6, 2e-6, None, None, None, [], "\x1b[31mEvil‮ One\x85"], "k")
    assert e["name"] == "[31mEvil One"
    assert e["source"] == "OpenRouter: acme/evil-1"
    only = engine.entry_from_row("openrouter", "OpenRouter", "acme/plain-model-2", [1e-6, 2e-6, None, None, None, [], "⁦\x07"], "k")
    assert only["name"] == engine.display("acme/plain-model-2".split("/", 1)[1]) or only["name"] == engine.display("acme/plain-model-2")
    assert engine.display_safe("Türkçe ğüşiöç ‍ ok") == "Türkçe ğüşiöç ‍ ok"


def test_overlong_last_line_moves_the_cursor_to_the_end_as_on_the_mac(tmp_path, monkeypatch):
    """9.0.5 pre-release review (Neon): a finished over-long LAST line left the cursor before it (the Mac's reader
    ends at the file's size), so the line was read and named again once anything was added."""
    monkeypatch.setattr(util, "MAX_LINE_BYTES", 50)
    f = tmp_path / "x.jsonl"
    f.write_bytes(b'{"a":1}\n' + b"y" * 500 + b"\n")
    got = list(util.iter_lines(str(f)))
    assert [l for l, _ in got if l] == ['{"a":1}']
    assert got[-1][1] == f.stat().st_size


def test_cli_home_without_db_keeps_its_index_inside_that_home_as_on_the_mac(tmp_path, monkeypatch):
    """9.0.5 pre-release review (Neon): `--home DIR` without `--db` wrote DIR's calls into the person's own index."""
    from tokenbar import cli
    from tokenbar.paths import Env
    own = tmp_path / "own"
    monkeypatch.setenv("LOCALAPPDATA", str(own / "Local"))
    monkeypatch.setenv("APPDATA", str(own / "Roaming"))
    monkeypatch.setenv("USERPROFILE", str(own))
    monkeypatch.setenv("HOME", str(own))
    fake = tmp_path / "fake"
    (fake / ".claude" / "projects" / "p").mkdir(parents=True)
    (fake / ".claude" / "projects" / "p" / "a.jsonl").write_text(json.dumps(claude_line("m1", "r1", 10, 5)) + "\n", encoding="utf-8")
    assert cli.main(["--home", str(fake), "--offline", "--window", "all", "--json"]) == 0
    assert not os.path.exists(Env.from_os().db_path())                     # not the person's own index
    assert os.path.exists(cli.home_index_path(Env.from_os(), str(fake)))     # an index of its own, beside it
    assert not os.path.exists(Env.for_home(str(fake)).db_path())             # and nothing written into the home read


def test_overlong_line_moves_the_cursor_even_with_a_limit_or_a_half_line_after_it(tmp_path, monkeypatch):
    """9.0.5 pre-release review, 2nd round (Neon): the scanner passes limit=size, so a finished over-long last line
    ended the loop before the cursor moved; a half-written line after it also left the cursor before it."""
    monkeypatch.setattr(util, "MAX_LINE_BYTES", 50)
    f = tmp_path / "x.jsonl"
    f.write_bytes(b'{"a":1}\n' + b"y" * 500 + b"\n")
    size = f.stat().st_size
    got = list(util.iter_lines(str(f), 0, size, True))
    assert got[-1][1] == size
    g = tmp_path / "y.jsonl"
    g.write_bytes(b'{"a":1}\n' + b"y" * 500 + b'\n{"b":')
    got = list(util.iter_lines(str(g), 0, g.stat().st_size, False))
    assert got[-1][1] == 8 + 501                      # past the long line, before the half one


def test_cli_home_by_two_spellings_is_one_set_of_files(tmp_path, monkeypatch):
    """9.0.5 pre-release review, 2nd round (Neon): one home given by a link and by its real path shared the index but
    was read under two spellings, so every file was recorded (and read) twice."""
    from tokenbar import cli
    from tokenbar.paths import Env
    from tokenbar.store import Store
    own = tmp_path / "own"
    for k, v in (("LOCALAPPDATA", own / "Local"), ("APPDATA", own / "Roaming"), ("USERPROFILE", own), ("HOME", own)):
        monkeypatch.setenv(k, str(v))
    fake = tmp_path / "fake"
    (fake / ".claude" / "projects" / "p").mkdir(parents=True)
    (fake / ".claude" / "projects" / "p" / "a.jsonl").write_text(json.dumps(claude_line("m1", "r1", 10, 5)) + "\n", encoding="utf-8")
    link = tmp_path / "link"
    os.symlink(fake, link, target_is_directory=True)
    assert cli.main(["--home", str(fake), "--offline", "--window", "all", "--json"]) == 0
    assert cli.main(["--home", str(link), "--offline", "--window", "all", "--json"]) == 0
    store = Store(cli.home_index_path(Env.from_os(), str(fake)))
    assert len(store.file_records()) == 1 and len(store.events_since(None)) == 1


def test_overlong_line_past_the_limit_does_not_move_the_cursor_beyond_it(tmp_path, monkeypatch):
    """9.0.5 pre-release review, 3rd round (Hydrogen): a long line that runs past `limit` gave an offset beyond it."""
    monkeypatch.setattr(util, "MAX_LINE_BYTES", 50)
    f = tmp_path / "x.jsonl"
    f.write_bytes(b'{"a":1}\n' + b"y" * 500 + b"\n")
    got = list(util.iter_lines(str(f), 0, 100, True))
    assert all(end <= 100 for _, end in got) and [l for l, _ in got if l] == ['{"a":1}']
