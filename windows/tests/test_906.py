"""9.0.6 Windows findings from the 9.0.5 scan (K1-K5, GUI index error, token units, models.dev name, README): each test reproduces one."""
import http.server
import json
import os
import sys
import threading

import pytest

from conftest import claude_line
from tokenbar import cli, fmt, util
from tokenbar.prices import engine
from tokenbar.prices import feed as pfeed

posix_only = pytest.mark.skipif(os.name == "nt" or (hasattr(os, "geteuid") and os.geteuid() == 0),
                                reason="needs POSIX permissions that bind the current user")

CLINE = "AppData/Roaming/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/{}/ui_messages.json"


def _named(result, folder):
    return [m for _, m in result.issues if m == f"{folder}: cannot be read"]


# ---------------------------------------------------------------- K1: a real call whose id is exactly `adj`
@pytest.mark.parametrize("key, expect", [
    ("cc:adj:r1", "cc:adj#gercek:r1"),
    ("cline:adj:1700000000000", "cline:adj#gercek:1700000000000"),
    ("qwen:adj", "qwen:adj#gercek"),                        # two parts: the id is the second one
    ("devin:adj:db:rid", "devin:adj#gercek:db:rid"),       # more than three parts
    ("cc:adj:s1:claude-haiku-5-5", "cc:adj#gercek:s1:claude-haiku-5-5"),
    ("cc:adjx:r1", "cc:adjx:r1"),                           # only the exact word
    ("cc:Adj:r1", "cc:Adj:r1"),
    ("cc:m1:adj", "cc:m1:adj"),                             # only the second part
    ("adj:cc:r1", "adj:cc:r1"),
    ("nocolon", "nocolon"),
])
def test_real_event_key_changes_only_a_second_part_that_is_exactly_adj(key, expect):
    from tokenbar.readers import base
    assert base.real_event_key(key) == expect


def test_sink_keeps_the_adjustment_writers_apart_from_real_calls():
    from tokenbar.readers.base import Sink
    sink = Sink()
    sink.add("zed:adj:t1", 1.0, "zed", "m", 5, 0, 0, 0, 0, adjustment=True)       # Zed's gap row: an adjustment
    sink.add("zed:adj:r1", 1.0, "zed", "m", 7, 0, 0, 0, 0)                         # a real request of a thread named `adj`
    assert [e.key for e in sink.events] == ["zed:adj:t1", "zed:adj#gercek:r1"]
    sink.retire_prefix("cline:adj:")
    assert sink.retire_prefixes == ["cline:adj:", "cline:adj#gercek:"]
    sink.retire_prefix("cline:t1:")
    assert sink.retire_prefixes[2:] == ["cline:t1:"]


def test_claude_message_id_adj_is_a_call_not_an_adjustment(home):
    cost = '{"type":"cost-state",' + json.dumps({"sessionId": "s1", "startTime": "2026-11-06T10:00:00.000Z",
        "modelUsage": {"claude-haiku-5-5": {"inputTokens": 620}}}, separators=(",", ":"))[1:] + "\n"
    home.write(".claude/projects/p/a.jsonl", json.dumps(claude_line("adj", "r1", 600, 0, model="claude-haiku-5-5")) + "\n" + cost)
    home.scan()
    assert home.calls("claude-code") == 1                              # was 0: the real row read as an adjustment
    assert home.total("claude-code") == 620                            # 600 real + the 20 the cost record holds beyond them
    keys = sorted(r[0] for r in home.store.events_since(None))
    assert keys == ["cc:adj#gercek:r1", "cc:adj:s1:claude-haiku-5-5"]   # the real row survives next to the adjustment
    home.scan()
    assert home.calls("claude-code") == 1 and home.total("claude-code") == 620


def _cline_row(tokens, ts=1793968800000):
    return {"type": "say", "say": "api_req_started", "ts": ts,
            "text": json.dumps({"tokensIn": tokens, "tokensOut": 100, "cacheReads": 0, "cacheWrites": 0}),
            "modelInfo": {"modelId": "claude-sonnet-4-20250514", "providerId": "anthropic"}}


def test_cline_task_named_adj_counts_and_prices_like_any_other_task(home, tmp_path):
    from conftest import Home
    home.write(CLINE.format("adj"), json.dumps([_cline_row(250_000)]))
    home.scan()
    other = Home(tmp_path / "other")
    other.write(CLINE.format("t1"), json.dumps([_cline_row(250_000)]))
    other.scan()
    mine, theirs = home.report(), other.report()
    other.store.close()
    assert (mine.calls, mine.tokens) == (theirs.calls, theirs.tokens) == (1, 250_100)
    assert mine.cost == pytest.approx(theirs.cost) and mine.cost > 0     # the >200K tier applies to a real call


def test_cline_task_named_adj_follows_a_checkpoint_restore(home):
    path = home.write(CLINE.format("adj"), json.dumps([_cline_row(1000, 1793968800000), _cline_row(2000, 1793968900000)]))
    home.scan()
    assert (home.calls("cline"), home.total("cline")) == (2, 3200)
    home.write(CLINE.format("adj"), json.dumps([_cline_row(2000, 1793968900000)]))
    os.utime(path, (2_000_000_000, 2_000_000_000))
    home.scan()
    assert (home.calls("cline"), home.total("cline")) == (1, 2100)       # the row the user rolled back is gone


def _steps():
    return [{"step_id": 1, "timestamp": "2026-11-06T10:00:00Z", "metrics": {"prompt_tokens": 100, "completion_tokens": 20}}]


@pytest.mark.parametrize("session", ["adj", "s1"])
def test_devin_transcript_after_sessions_db_replaces_its_rows_even_for_a_session_named_adj(home, session):
    from test_winfix import _devin_db
    _devin_db(home, session)
    home.scan()
    assert (home.calls("devin"), home.total("devin")) == (1, 120)
    home.write(f".local/share/devin/cli/transcripts/{session}.json", json.dumps({"session_id": session, "steps": _steps()}))
    home.scan()
    assert (home.calls("devin"), home.total("devin")) == (1, 120)           # the same call once, not 240 / 2
    keys = [r[0] for r in home.store.events_since(None)]
    assert not [k for k in keys if ":db:" in k], keys                        # the database rows are gone


@pytest.mark.skipif(sys.platform == "win32", reason="scripts/oracle.py is the macOS twin (it reads the macOS tool folders and imports pwd)")
def test_devin_session_named_adj_counts_like_the_oracle(home):
    from test_winfix import _devin_db
    _devin_db(home, "adj")
    home.scan()
    assert _oracle(home) == (home.report().tokens, home.report().calls) == (120, 1)       # no transcript: the database row counts
    home.write(".local/share/devin/cli/transcripts/adj.json", json.dumps({"session_id": "adj", "steps": _steps()}))
    home.scan()
    assert _oracle(home) == (home.report().tokens, home.report().calls) == (120, 1)       # transcript: the database is left out


def _oracle(home):
    import subprocess
    import sys
    scripts = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "scripts")
    env = {"HOME": home.root, "PATH": os.environ.get("PATH", ""), "TOKENBAR_PRICES_PINNED": "1"}
    proc = subprocess.run([sys.executable, os.path.join(scripts, "oracle.py"), "all"], capture_output=True, text=True, env=env, cwd=home.root)
    assert proc.returncode == 0, proc.stderr
    out = json.loads(proc.stdout)
    return out["total"], out["calls"]


@pytest.mark.parametrize("mid", ["adj", "m1"])
def test_claude_file_that_grows_and_is_rewritten_counts_the_same_for_an_adj_id(tmp_path, mid):
    from conftest import Home
    h = Home(tmp_path / mid)
    try:
        path = h.write(".claude/projects/p/a.jsonl", json.dumps(claude_line(mid, "r1", 100, 5)) + "\n")
        h.scan()
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(claude_line(mid, "r2", 200, 7)) + "\n")
        h.scan()
        assert (h.calls("claude-code"), h.total("claude-code")) == (2, 312)
        with open(path, "w", encoding="utf-8") as f:                         # rewritten: one row changed, one new
            f.write(json.dumps(claude_line(mid, "r1", 100, 5)) + "\n" + json.dumps(claude_line(mid, "r3", 50, 1)) + "\n")
        os.utime(path, (2_000_000_000, 2_000_000_000))
        h.scan()
        assert (h.calls("claude-code"), h.total("claude-code")) == (3, 363)  # same as a message id that is no `adj`
    finally:
        h.store.close()


def test_devin_and_cline_prefixes_come_from_the_same_mapping():
    from tokenbar.readers import base
    assert base.real_event_prefixes("devin:adj:db:") == ["devin:adj:db:", "devin:adj#gercek:db:"]
    assert base.real_event_prefixes("cline:adj:") == ["cline:adj:", "cline:adj#gercek:"]
    assert base.real_event_prefixes("cline:t1:") == ["cline:t1:"]


# ---------------------------------------------------------------- K2: an unwritable price cache costs no second download
class _Catalogues:
    """A local server that serves the three catalogues and counts the requests per path."""

    BODIES = {
        "openrouter": {"data": [{"id": "acme/m", "pricing": {"prompt": "0.000001", "completion": "0.000002"}}]},
        "litellm": {"acme-m": {"input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6}},
        "modelsdev": {"p": {"models": {"m": {"cost": {"input": 1, "output": 2}}}}},
    }

    def __init__(self, status=200):
        self.hits = {}
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                name = self.path.strip("/")
                outer.hits[name] = outer.hits.get(name, 0) + 1
                body = json.dumps(outer.BODIES[name]).encode() if status == 200 else b"no"
                self.send_response(status)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.base = f"http://127.0.0.1:{self.httpd.server_address[1]}/"
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *a):
        self.httpd.shutdown()
        self.httpd.server_close()


def _unwritable(tmp_path):
    blocker = tmp_path / "blocker"
    blocker.write_text("a file where the cache folder should be")
    return str(blocker / "cache")                  # makedirs fails on every platform: nothing can be written there


def test_unwritable_price_cache_asks_each_catalogue_once_and_says_so_once(tmp_path, monkeypatch):
    with _Catalogues() as server:
        for source in pfeed.URLS:
            monkeypatch.setitem(pfeed.URLS, source, server.base + source)
        clock = [1_900_000_000.0]
        feed = pfeed.PriceFeed(_unwritable(tmp_path), now=lambda: clock[0])
        first = feed.refresh()
        assert sorted(first.updated) == sorted(pfeed.SOURCES)
        assert first.notes == [f"price cache cannot be written: {feed.cache_dir}"]
        for _ in range(3):                                      # the six-hourly pass, a return from Offline, "Update prices" ...
            clock[0] += 6 * 3600
            again = feed.refresh()
            assert again.updated == [] and sorted(again.fresh) == sorted(pfeed.SOURCES)
            assert again.notes == []                            # said once
        assert server.hits == {"openrouter": 1, "litellm": 1, "modelsdev": 1}
        cats, origins = feed.load_local()                        # and what was downloaded is what prices
        assert {c.source for c in cats} == set(pfeed.SOURCES) and all(o.startswith("cache") for o in origins.values())
        clock[0] += 25 * 3600                                    # after the day it is asked again, once
        feed.refresh()
        assert server.hits == {"openrouter": 2, "litellm": 2, "modelsdev": 2}


def test_unwritable_state_file_still_waits_out_a_failure(tmp_path, monkeypatch):
    with _Catalogues(status=500) as server:
        for source in pfeed.URLS:
            monkeypatch.setitem(pfeed.URLS, source, server.base + source)
        clock = [1_900_000_000.0]
        feed = pfeed.PriceFeed(_unwritable(tmp_path), now=lambda: clock[0])
        assert set(feed.refresh().failed) == set(pfeed.SOURCES)
        clock[0] += 600                                          # inside the hour a failed catalogue is not asked again
        later = feed.refresh()
        assert later.failed == {} and sorted(later.skipped) == sorted(pfeed.SOURCES)
        assert server.hits == {"openrouter": 1, "litellm": 1, "modelsdev": 1}


def test_writable_price_cache_behaves_as_before(tmp_path, monkeypatch):
    with _Catalogues() as server:
        for source in pfeed.URLS:
            monkeypatch.setitem(pfeed.URLS, source, server.base + source)
        clock = [1_900_000_000.0]
        feed = pfeed.PriceFeed(str(tmp_path / "cache"), now=lambda: clock[0])
        assert feed.refresh().notes == []
        clock[0] += 3600
        assert sorted(feed.refresh().fresh) == sorted(pfeed.SOURCES)
        assert all(os.path.exists(os.path.join(feed.cache_dir, f"prices-{s}.json")) for s in pfeed.SOURCES)
        assert server.hits == {"openrouter": 1, "litellm": 1, "modelsdev": 1}


def test_unwritable_price_cache_reaches_the_window_from_the_background_pass(tmp_path, monkeypatch):
    monkeypatch.delenv("TOKENBAR_OFFLINE")                          # conftest keeps the suite offline; this test asks (a fake fetcher)
    """The background pass asks for prices first and its report is not shown: the problem must still be listed, and stay."""
    from conftest import Home
    from tokenbar.gui import app
    from tokenbar.gui.model import AppModel
    from tokenbar.prices.book import PriceBook
    home = Home(tmp_path / "home")
    answers = {s: json.dumps(b).encode() for s, b in _Catalogues.BODIES.items()}

    def fetch(source, etag):
        return "ok", answers[source], None

    feed = pfeed.PriceFeed(_unwritable(tmp_path), fetcher=fetch)
    model = AppModel(env=home.env, store=home.store, book=PriceBook(home.env, pinned=False, offline=False, feed=feed))

    class _Q:
        def put(self, item):
            pass

    app.background_pass(model, _Q(), {})                       # the pass that asks, and consumes the one-time note
    wanted = [("prices", "price cache cannot be written: " + feed.cache_dir)]
    assert [i for i in model.last_scan.issues if "price cache" in i[1]] == [(wanted[0][0], wanted[0][1])]
    assert model.update_prices(force=True).notes == []         # said once to the report ...
    model.rescan()
    assert [i for i in model.last_scan.issues if "price cache" in i[1]] == wanted     # ... but listed on every scan, once
    home.store.close()


def test_price_problem_goes_away_when_the_cache_can_be_written_again(tmp_path):
    feed = pfeed.PriceFeed(_unwritable(tmp_path), fetcher=lambda s, e: ("ok", json.dumps(_Catalogues.BODIES[s]).encode(), None))
    assert feed.refresh().updated and feed.cache_problem
    feed.cache_dir = str(tmp_path / "fine")
    feed.refresh(force=True)
    assert feed.cache_problem is None


def test_price_problem_is_tracked_per_catalogue(tmp_path, monkeypatch):
    """One catalogue that writes must not hide another that does not (the flag was one for the whole feed)."""
    ok = {"openrouter": False}
    real = pfeed._write_json

    def write(path, obj):
        if os.path.basename(path) == "prices-openrouter.json" and not ok["openrouter"]:
            return False
        return real(path, obj)

    monkeypatch.setattr(pfeed, "_write_json", write)
    feed = pfeed.PriceFeed(str(tmp_path / "cache"), fetcher=lambda s, e: ("ok", json.dumps(_Catalogues.BODIES[s]).encode(), None))
    report = feed.refresh()                                      # openrouter fails to write, litellm and modelsdev write after it
    assert sorted(report.updated) == sorted(pfeed.SOURCES) and report.notes
    assert feed.cache_problem and "cannot be written" in feed.cache_problem
    ok["openrouter"] = True
    feed.refresh(force=True)
    assert feed.cache_problem is None


def test_price_problem_leaves_the_window_list_when_the_cache_works_again(tmp_path, monkeypatch):
    monkeypatch.delenv("TOKENBAR_OFFLINE")
    from conftest import Home
    from tokenbar.gui import app
    from tokenbar.gui.model import AppModel
    from tokenbar.prices.book import PriceBook
    home = Home(tmp_path / "home")
    feed = pfeed.PriceFeed(_unwritable(tmp_path), fetcher=lambda s, e: ("ok", json.dumps(_Catalogues.BODIES[s]).encode(), None))
    model = AppModel(env=home.env, store=home.store, book=PriceBook(home.env, pinned=False, offline=False, feed=feed))

    class _Q:
        def put(self, item):
            pass

    app.background_pass(model, _Q(), {})
    assert [i for i in model.last_scan.issues if "price cache" in i[1]]
    feed.cache_dir = str(tmp_path / "fine")
    model.update_prices(force=True)                              # the next price pass writes: the entry goes now, not at the next scan
    assert not [i for i in model.last_scan.issues if "price cache" in i[1]]
    home.store.close()


def test_cli_home_or_db_the_system_cannot_resolve_is_one_filtered_line_and_exit_2(tmp_path, monkeypatch, capsys):
    _cli_env(monkeypatch, tmp_path)
    assert cli.run_cli(["--home", "bad\x00name\x1b[31m", "--db", str(tmp_path / "i.sqlite"), "--offline"]) == 2
    err = capsys.readouterr().err
    assert err.startswith("tokenbar: ") and "Traceback" not in err and "\x1b" not in err and "\u001b" not in err and err.count("\n") == 1
    assert cli.run_cli(["--db", "bad\x00\x1b[31m", "--rebuild", "--offline"]) == 2
    err = capsys.readouterr().err
    assert err.startswith("tokenbar: ") and "\x1b" not in err and "Traceback" not in err


def test_memory_catalogues_are_written_when_the_cache_folder_works_again_without_asking_the_network(tmp_path, monkeypatch):
    with _Catalogues() as server:
        for source in pfeed.URLS:
            monkeypatch.setitem(pfeed.URLS, source, server.base + source)
        clock = [1_900_000_000.0]
        blocker = tmp_path / "cache"
        blocker.write_text("a file where the cache folder should be")
        feed = pfeed.PriceFeed(str(blocker), now=lambda: clock[0])
        assert feed.refresh().notes and feed.cache_problem
        blocker.unlink()                                         # the folder can be made now
        clock[0] += 3600                                         # inside the day: a normal pass, nothing is due
        again = feed.refresh()                                   # not forced
        assert sorted(again.fresh) == sorted(pfeed.SOURCES) and again.updated == []
        assert all(os.path.exists(blocker / f"prices-{s}.json") for s in pfeed.SOURCES)    # what was in memory is on disk
        assert feed.cache_problem is None
        assert server.hits == {"openrouter": 1, "litellm": 1, "modelsdev": 1}
        cats, origins = pfeed.PriceFeed(str(blocker)).load_local()                         # a new process finds it
        assert {c.source for c in cats} == set(pfeed.SOURCES) and all(o.startswith("cache") for o in origins.values())


def test_a_state_file_that_could_not_be_written_is_tried_again_without_a_new_failure(tmp_path, monkeypatch):
    real = pfeed._write_json
    working = {"state": False}

    def write(path, obj):
        if os.path.basename(path) == "prices-state.json" and not working["state"]:
            return False
        return real(path, obj)

    monkeypatch.setattr(pfeed, "_write_json", write)
    with _Catalogues(status=500) as server:
        for source in pfeed.URLS:
            monkeypatch.setitem(pfeed.URLS, source, server.base + source)
        clock = [1_900_000_000.0]
        feed = pfeed.PriceFeed(str(tmp_path / "cache"), now=lambda: clock[0])
        assert set(feed.refresh().failed) == set(pfeed.SOURCES) and feed.cache_problem
        working["state"] = True
        clock[0] += 600                                          # inside the hour: nothing is asked, nothing new to record
        later = feed.refresh()
        assert later.failed == {} and server.hits == {"openrouter": 1, "litellm": 1, "modelsdev": 1}
        state = json.load(open(tmp_path / "cache" / "prices-state.json"))
        assert set(state["failed"]) == set(pfeed.SOURCES)        # the remembered failures reached the disk
        assert feed.cache_problem is None


# ---------------------------------------------------------------- K3: a permission error on a listed folder is named, a missing one is not
@posix_only
@pytest.mark.parametrize("rel, inside", [
    (".local/share/opencode", "opencode.db"),
    (".local/share/kilo", "kilo.db"),
    (".continue", "dev_data/0.2.0/tokensGenerated.jsonl"),
    ("AppData/Roaming/Code/User/workspaceStorage", "abc/chatSessions/s.json"),
], ids=["opencode", "kilo", "continue", "copilot-chat"])
def test_unreadable_tool_root_is_named(home, rel, inside):
    home.write(f"{rel}/{inside}", "x")
    root = home.path(*rel.split("/"))
    os.chmod(root, 0)
    try:
        result = home.scan()
        assert _named(result, root), result.issues
    finally:
        os.chmod(root, 0o755)
    assert not _named(home.scan(), root)                         # readable again: no complaint


@posix_only
def test_unreadable_folder_inside_a_chat_store_is_named(home):
    home.write("AppData/Roaming/Code/User/workspaceStorage/abc/chatSessions/s.json", "{}")
    sessions = home.path("AppData", "Roaming", "Code", "User", "workspaceStorage", "abc", "chatSessions")
    os.chmod(sessions, 0)
    try:
        assert _named(home.scan(), sessions)
    finally:
        os.chmod(sessions, 0o755)


def test_missing_tool_roots_are_silent(home):
    home.write(".local/share/opencode/other.txt", "no database here")      # a folder without the database is no problem either
    result = home.scan()
    assert not [m for _, m in result.issues if "cannot be read" in m], result.issues


def test_listing_a_folder_that_vanished_or_is_a_file_is_silent(home):
    from tokenbar.readers import g2
    util.take_walk_errors()
    home.write("AppData/Roaming/afile", "x")
    assert g2._listdir(home.path("AppData", "Roaming", "nowhere")) == []
    assert g2._listdir(home.path("AppData", "Roaming", "afile")) == []     # ENOTDIR
    assert not g2._isfile(home.path("AppData", "Roaming", "afile", "below"))
    assert util.take_walk_errors() == []


# ---------------------------------------------------------------- K4: names printed on a terminal carry no controls or direction marks
EVIL = "evil\u001b]0;PWNED\u0007‮abc‎؜  "
BAD = ("\u001b", "\u0007", "‮", "‎", "؜", " ", " ")


def _cli_env(monkeypatch, tmp_path):
    for var in ("USERPROFILE", "HOME"):
        monkeypatch.setenv(var, str(tmp_path / "me"))
    monkeypatch.setenv("APPDATA", str(tmp_path / "me" / "AppData" / "Roaming"))
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "me" / "AppData" / "Local"))


def test_cli_text_report_strips_controls_from_the_logged_model_name_and_json_keeps_it(home, tmp_path, monkeypatch, capsys):
    _cli_env(monkeypatch, tmp_path)
    home.jsonl(".claude/projects/p/a.jsonl", claude_line("m1", "r1", 8, 1, model=EVIL))
    argv = ["--home", home.root, "--db", str(tmp_path / "idx.sqlite"), "--offline", "--window", "all"]
    assert cli.run_cli(argv) == 0
    text = capsys.readouterr()
    assert "PWNED" in text.out and not [c for c in BAD if c in text.out + text.err]
    assert cli.run_cli(argv + ["--json"]) == 0
    raw = capsys.readouterr().out
    assert "\u001b" not in raw                                 # JSON escapes it
    models = [m for h in json.loads(raw)["harnesses"].values() for m in h["models"]]
    assert any("PWNED" in m and "\u001b" in m and "\u202e" in m for m in models), models   # unchanged data, not display


@posix_only
def test_cli_names_an_unreadable_folder_without_its_control_characters(home, tmp_path, monkeypatch, capsys):
    _cli_env(monkeypatch, tmp_path)
    home.write(".claude/projects/good/a.jsonl", json.dumps(claude_line("m1", "r1", 8, 1)) + "\n")
    locked = home.path(".claude", "projects", "q\u001b[31m-red‮")
    os.makedirs(locked)
    os.chmod(locked, 0)
    try:
        assert cli.run_cli(["--home", home.root, "--db", str(tmp_path / "idx.sqlite"), "--offline", "--window", "all"]) == 0
    finally:
        os.chmod(locked, 0o755)
    err = capsys.readouterr().err
    assert "-red" in err and "cannot be read" in err and not [c for c in BAD if c in err]


def test_display_safe_covers_the_marks_added_in_906():
    assert engine.display_safe("a‎b‏c؜d") == "abcd"
    assert engine.display_safe("x y z") == "xyz"
    assert engine.display_safe("e‮⁦f⁩\u001b\u007f\u009fg") == "efg"     # what was already removed still is
    assert engine.display_safe("Türkçe é​ ok") == "Türkçe é​ ok"    # ordinary text (U+200B was never in the set)


# ---------------------------------------------------------------- K5: a folder that vanished during the walk is no "cannot be read"
@pytest.mark.parametrize("error", [FileNotFoundError(2, "No such file or directory"), NotADirectoryError(20, "Not a directory")],
                         ids=["ENOENT", "ENOTDIR"])
def test_walk_does_not_name_a_folder_that_went_away(tmp_path, monkeypatch, error):
    (tmp_path / "a" / "b").mkdir(parents=True)
    (tmp_path / "a" / "c").mkdir()
    (tmp_path / "a" / "b" / "x.jsonl").write_text("{}\n")
    real = os.scandir

    def scandir(p="."):
        if os.fspath(p).endswith("c"):
            raise type(error)(error.errno, error.strerror, os.fspath(p))
        return real(p)

    monkeypatch.setattr(os, "scandir", scandir)
    util.take_walk_errors()
    found = util.walk_files(str(tmp_path), lambda n: n.endswith(".jsonl"))
    assert [os.path.basename(p) for p in found] == ["x.jsonl"]
    assert util.take_walk_errors() == []


def test_walk_still_names_a_permission_error(tmp_path, monkeypatch):
    (tmp_path / "locked").mkdir()
    real = os.scandir

    def scandir(p="."):
        if os.fspath(p).endswith("locked"):
            raise PermissionError(13, "Permission denied", os.fspath(p))
        return real(p)

    monkeypatch.setattr(os, "scandir", scandir)
    util.take_walk_errors()
    util.walk_files(str(tmp_path), lambda n: True)
    assert util.take_walk_errors() == [str(tmp_path / "locked")]


# ---------------------------------------------------------------- GUI: an index that cannot be opened ends in a message, not a crash
def _broken_index_error(tmp_path):
    from tokenbar.store import Store, StoreError
    path = tmp_path / "usage.sqlite"
    path.write_text("this is not a database")
    with pytest.raises(StoreError) as caught:
        Store(str(path))
    return path, caught.value


def test_run_gui_shows_the_index_error_and_returns_without_starting_the_tray(tmp_path, monkeypatch):
    import tkinter.messagebox as mb
    from tokenbar.gui import app
    path, error = _broken_index_error(tmp_path)
    shown = {}

    class _Root:
        def withdraw(self): pass
        def destroy(self): shown["destroyed"] = True

    def no_model(*a, **k):
        raise error

    monkeypatch.setattr(app, "acquire_single_instance", lambda: object())
    monkeypatch.setattr(app, "AppModel", no_model)
    monkeypatch.setattr(app, "_run", lambda *a, **k: pytest.fail("the tray must not start without an index"))
    monkeypatch.setattr(app.tk, "Tk", _Root)
    monkeypatch.setattr(mb, "showerror", lambda title, msg, parent=None: shown.update(title=title, msg=msg))
    assert app.run_gui([]) == 1
    assert str(path) in shown["msg"] and "not a database" in shown["msg"] and shown["destroyed"]


def test_index_error_without_a_display_goes_to_stderr(tmp_path, monkeypatch, capsys):
    from tokenbar.gui import app
    _, error = _broken_index_error(tmp_path)

    def no_display():
        raise RuntimeError("no display name and no $DISPLAY environment variable")

    monkeypatch.setattr(app.tk, "Tk", no_display)
    assert app.index_error_dialog(error) == 1
    assert "usage.sqlite" in capsys.readouterr().err


# ---------------------------------------------------------------- token units are chosen after the rounding (the Mac's 999 950 rule)
@pytest.mark.parametrize("n, expect", [
    (999, "999"), (1000, "1K"), (113_600, "114K"), (999_499, "999K"),
    (999_500, "999.5K"), (999_949, "999.9K"),                    # still thousands, as the Mac says "999.5K" and "999.9K"
    (999_950, "1M"), (999_999, "1M"), (1_000_000, "1M"), (1_186_548, "1.19M"),
    (999_500_000, "999.5M"), (999_949_999, "999.9M"),
    (999_950_000, "1B"), (999_999_999, "1B"), (1_404_730_925, "1.4B"),
])
def test_token_units(n, expect):
    assert fmt.tokens(n) == expect


def test_token_units_never_show_a_thousand_of_a_unit():
    assert not [n for n in range(999_000, 1_001_000) if fmt.tokens(n).startswith("1000")]
    assert not [n for n in range(999_000_000, 1_001_000_000, 997) if fmt.tokens(n).startswith("1000")]


# ---------------------------------------------------------------- models.dev: a name that is not a string is no name
@pytest.mark.parametrize("bad", [12345, {"a": 1}, True, ["x"], 1.5])
def test_modelsdev_ignores_a_name_that_is_not_a_string(bad):
    rows = engine.modelsdev_rows({"p": {"models": {"bad": {"cost": {"input": 1, "output": 2}, "name": bad},
                                                   "good": {"cost": {"input": 1, "output": 2}, "name": "Nice"}}}})
    assert rows["p/good"][6] == "Nice" and rows["p/bad"][6] == ""
    entry = engine.entry_from_row("modelsdev", "models.dev", "p/bad", rows["p/bad"], "bad")
    assert entry["name"] == engine.display_safe(engine.display("bad"))


# ---------------------------------------------------------------- READMEs say what --home does since 9.0.5
@pytest.mark.parametrize("name", ["README.md", "README.tr.md"])
def test_readme_tells_the_home_index_rule(name):
    text = open(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), name), encoding="utf-8").read()
    assert "homes" in text and "usage.sqlite" in text
    assert "index stays in your own" not in text and "indeks kendi %LOCALAPPDATA%'nda kalır" not in text
