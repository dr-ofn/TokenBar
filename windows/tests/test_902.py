"""9.0.2: defects of 9.0.1 that an independent scan reproduced. Each test failed before its fix."""
import json
import os
import sys

import pytest

from tokenbar import extdb

NOUSE = {"input": 100, "output": 20}


def _omp_call(ts="2026-11-06T10:00:00Z", extra=None):
    m = {"role": "assistant", "provider": "anthropic", "model": "claude-sonnet-4-5", "usage": dict(NOUSE)}
    m.update(extra or {})
    return {"timestamp": ts, "message": m}


# 1. oh-my-pi: the session header is the first line parsed, spaced or not ------------------------------------------
def test_omp_spaced_session_header_names_the_session(home):
    call = json.dumps(_omp_call())                                   # no responseId: keyed by session + line text
    for name, sid in (("a/2026-11-06_same.jsonl", "sess-A"), ("b/2026-11-06_same.jsonl", "sess-B")):
        home.write(".omp/agent/sessions/" + name, '{"type": "session", "id": "%s", "cwd": "/x"}\n%s\n' % (sid, call))
    home.scan()
    assert home.calls("oh-my-pi") == 2                               # two sessions, two calls (was 1: both named "same")
    keys = sorted(k for k, *_ in home.store.events_since(None))
    assert keys[0].startswith("omp:sess-A:") and keys[1].startswith("omp:sess-B:")


def test_omp_header_after_a_blank_line_and_bom_is_still_the_header(home):
    call = json.dumps(_omp_call())
    home.write(".omp/agent/sessions/a/x_f.jsonl", b"\xef\xbb\xbf\n" + b'{ "type" : "session" , "id" : "sess-C" }\n' + call.encode() + b"\n")
    home.scan()
    assert [k.split(":")[1] for k, *_ in home.store.events_since(None)] == ["sess-C"]


def test_omp_a_first_line_that_is_no_header_leaves_the_name(home):
    call = json.dumps(_omp_call())
    home.write(".omp/agent/sessions/a/x_fname.jsonl", '{"type":"message","id":"not-a-header"}\n' + call + "\n")
    home.scan()
    assert [k.split(":")[1] for k, *_ in home.store.events_since(None)] == ["fname"]


# 2. Codex .jsonl.zst: what was read before a limit stays counted -------------------------------------------------
def _cx(ts, total, inp, out):
    info = {"total_token_usage": {"input_tokens": inp, "output_tokens": out, "total_tokens": total}}
    return {"timestamp": ts, "type": "event_msg", "payload": {"type": "token_count", "info": info}}


def _rollout(*extra_lines):
    meta = {"type": "session_meta", "payload": {"id": "zsid", "timestamp": "2026-11-06T09:00:00Z", "model_provider": "openai"}}
    rows = [meta, {"type": "turn_context", "payload": {"model": "gpt-6-luna"}},
            _cx("2026-11-06T10:00:00Z", 100, 80, 20), _cx("2026-11-06T10:01:00Z", 250, 200, 50)]
    return ("".join(json.dumps(r) + "\n" for r in rows) + "".join(extra_lines)).encode()


def test_oversize_rollout_keeps_the_calls_before_the_limit(home, monkeypatch):
    zstandard = pytest.importorskip("zstandard")
    big = _rollout("a" * 5000 + "\n", json.dumps(_cx("2026-11-06T10:02:00Z", 400, 300, 100)) + "\n")
    p = home.write(".codex/archived_sessions/rollout-big.jsonl.zst", zstandard.ZstdCompressor().compress(big))
    monkeypatch.setattr(extdb, "ZSTD_MAX_LINE", 1000)
    first = home.scan()
    assert home.calls("codex") == 2 and home.total("codex") == 250    # the two calls before the long line
    assert [m for _, m in first.issues if "rollout-big" in m and "too large" in m]
    assert p not in home.store.file_records()                        # as 9.0.1: named, never recorded ...
    calls = []
    real = extdb.zstd_lines
    monkeypatch.setattr(extdb, "zstd_lines", lambda path: calls.append(path) or real(path))
    again = home.scan()
    assert calls == []                                               # ... and not unpacked again
    assert [m for _, m in again.issues if "rollout-big" in m and "too large" in m]
    assert home.calls("codex") == 2


def test_oversize_total_output_keeps_the_calls_before_the_limit(home, monkeypatch):
    zstandard = pytest.importorskip("zstandard")
    head = _rollout()
    big = head + b"x\n" * 20000
    home.write(".codex/archived_sessions/rollout-big2.jsonl.zst", zstandard.ZstdCompressor().compress(big))
    monkeypatch.setattr(extdb, "ZSTD_MAX_OUTPUT", len(head) + 5000)
    r = home.scan()
    assert home.calls("codex") == 2
    assert [m for _, m in r.issues if "rollout-big2" in m and "too large" in m]


# 3. a lone surrogate in a log (a JSON "\udc80") must not stop the index write of the other files ----------------
def _pi_line(rid, inp=10):
    return '{"timestamp":"2026-11-06T10:00:00Z","message":{"role":"assistant","provider":"p","model":"m","usage":{"input":%d,"output":1},"responseId":"%s"}}\n' % (inp, rid)


def test_a_lone_surrogate_does_not_zero_the_other_files(home):
    home.write(".pi/agent/sessions/a/good.jsonl", _pi_line("ok-1") + _pi_line("ok-2", 20))
    home.write(".pi/agent/sessions/b/bad.jsonl", _pi_line("r\\udc80x", 40))
    r = home.scan()
    assert not [m for _, m in r.issues if "index write failed" in m], r.issues
    assert home.calls("pi") == 3 and home.total("pi") == 11 + 21 + 41
    keys = sorted(k for k, *_ in home.store.events_since(None))
    assert keys == ["pi:ok-1", "pi:ok-2", "pi:r�x"]               # the bad character is U+FFFD, the others keep their key


def test_a_lone_surrogate_in_model_and_session_is_replaced(home):
    row = {"type": "assistant", "timestamp": "2026-11-06T10:00:00.000Z", "sessionId": "s\udc80", "requestId": "q\ud800",
           "message": {"id": "m\udfff", "model": "claude-\udc80opus", "usage": {"input_tokens": 5, "output_tokens": 1}}}
    home.write(".claude/projects/p/s.jsonl", json.dumps(row) + "\n")           # json.dumps writes the surrogates as \udc80
    r = home.scan()
    assert not [m for _, m in r.issues if "index write failed" in m], r.issues
    assert home.total() == 6


def test_one_failing_file_does_not_take_the_batch_with_it(home, monkeypatch):
    home.write(".pi/agent/sessions/a/good.jsonl", _pi_line("ok-1"))
    home.write(".pi/agent/sessions/b/boom.jsonl", _pi_line("boom"))
    real = type(home.store)._row

    def row(e, file=""):
        if e.key == "pi:boom":
            raise ValueError("a row the database refuses")
        return real(e, file)

    monkeypatch.setattr(type(home.store), "_row", staticmethod(row))
    r = home.scan()
    assert home.calls("pi") == 1 and home.total("pi") == 11               # the good file is in
    assert [m for _, m in r.issues if "boom" in m and "index write failed" in m]


# 4. Zed: a zstd thread that cannot be unpacked is named, not dropped without a word ------------------------------
def _zed_db(path, threads):
    import sqlite3
    os.makedirs(os.path.dirname(path), exist_ok=True)
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE threads(id TEXT PRIMARY KEY, summary TEXT NOT NULL, updated_at TEXT NOT NULL, data_type TEXT NOT NULL, data BLOB NOT NULL, created_at TEXT)")
    for tid, kind, blob in threads:
        con.execute("INSERT INTO threads VALUES(?,?,?,?,?,?)", (tid, "", "2026-11-06T10:00:00+00:00", kind, blob, None))
    con.commit()
    con.close()


def _thread(n):
    return json.dumps({"model": {"model": "claude-sonnet-4-5", "provider": "zed.dev"}, "cumulative_token_usage": {"input_tokens": n},
                       "request_token_usage": {}}).encode()


def test_zed_a_corrupt_zstd_thread_is_named_and_the_rest_counts(home):
    zstandard = pytest.importorskip("zstandard")
    path = home.path("AppData", "Local", "Zed", "threads", "threads.db")
    _zed_db(path, [("t-bad", "zstd", b"this is not zstd"), ("t-ok", "zstd", zstandard.ZstdCompressor().compress(_thread(700)))])
    r = home.scan()
    assert home.total("zed") == 700
    assert [m for _, m in r.issues if "t-bad" in m], r.issues


def test_zed_a_thread_past_the_limit_is_named_as_too_large(home, monkeypatch):
    zstandard = pytest.importorskip("zstandard")
    path = home.path("AppData", "Local", "Zed", "threads", "threads.db")
    _zed_db(path, [("t-big", "zstd", zstandard.ZstdCompressor().compress(b" " * 100000 + _thread(5))),
                   ("t-ok", "json", _thread(300))])
    monkeypatch.setattr(extdb, "ZSTD_OUTPUT_LIMIT", 5000)
    r = home.scan()
    assert home.total("zed") == 300
    assert [m for _, m in r.issues if "t-big" in m and "too large" in m], r.issues


def test_zed_blob_limit_is_the_mac_apps():
    assert extdb.ZSTD_OUTPUT_LIMIT == 256 << 20                       # Sources/LocalCore/ScannerG2.swift: maxOutput 256 << 20


# 5. Claude cost-state: a start time that does not fit a whole number of seconds is run "0" (the Mac app's Safe.seconds) -
def _cost_line(session, start, usage):
    body = {"startTime": start, "modelUsage": {"claude-opus-5-5": usage}, "sessionId": session}
    return '{"type":"cost-state",' + json.dumps(body, separators=(",", ":"))[1:] + "\n"


def test_cost_state_start_time_too_large_is_run_zero_and_repair_runs_no_more(home):
    from tokenbar.store import Store
    home.write(".claude/projects/p/a.jsonl", _cost_line("s1", 1e23, {"inputTokens": 200}) + _cost_line("s1", 1793955600, {"inputTokens": 50}))
    home.scan()
    assert sorted((r[0], r[1]) for r in home.store.cost_rows()) == [("s1", 0.0), ("s1", 1793955600.0)]
    assert home.total("claude-code") == 250
    path = home.store.path
    home.store.close()
    for _ in range(2):                                       # every start of the app opens the index again
        s = Store(path)
        assert s.meta("cc-adjust-stale") != "1"              # nothing to repair, so nothing marked stale
        assert sorted(r[1] for r in s.cost_rows()) == [0.0, 1793955600.0]
        s.close()
    home.store = Store(path)
    home.scanner.store = home.store


def test_index_of_9_0_1_with_an_oversize_run_is_repaired_once(tmp_path):
    from tokenbar.store import Store
    path = str(tmp_path / "usage.sqlite")
    s = Store(path)
    s.db.executemany("INSERT INTO costs(session, started, model, input, cr, cw, output) VALUES(?,?,?,?,?,?,?)",
                     [("s1", 1e20, "claude-opus-5-5", 200, 0, 0, 0), ("s1", 1793955600.0, "claude-opus-5-5", 50, 0, 0, 0)])
    s.db.commit()
    s.close()
    s = Store(path)
    assert sorted(s.cost_rows()) == [("s1", 0.0, "claude-opus-5-5", 200, 0, 0, 0), ("s1", 1793955600.0, "claude-opus-5-5", 50, 0, 0, 0)]
    s.set_meta("cc-adjust-stale", "")                        # the adjustment was recomputed
    s.close()
    s = Store(path)
    assert s.meta("cc-adjust-stale") != "1"                  # and the repair does not come back
    s.close()


# 6. a failed price fetch is asked again within the hour even when the app was restarted in between ------------------
class _Q:
    def __init__(self):
        self.items = []

    def put(self, x):
        self.items.append(x)


def test_a_failed_price_fetch_is_retried_within_the_hour_after_a_restart(tmp_path):
    from tokenbar.gui.app import background_pass
    from tokenbar.prices.feed import FetchError, PriceFeed

    clock = {"t": 10 ** 9}
    calls = []

    def fetch(source, etag):
        calls.append((source, clock["t"]))
        raise FetchError("network down")

    class Model:
        offline = False

        def __init__(self):
            self.feed = PriceFeed(str(tmp_path), fetcher=fetch, now=lambda: clock["t"])

        def rescan(self):
            pass

        def report(self):
            return None

        def update_prices(self, force=False):
            return self.feed.refresh(force)

    background_pass(Model(), _Q(), {}, now=lambda: clock["t"])           # the first run: every source fails
    assert len(calls) == 3
    clock["t"] += 600                                                    # the app is started again 10 minutes later
    state = {}
    background_pass(Model(), _Q(), state, now=lambda: clock["t"])        # the failure is remembered: not asked yet
    assert len(calls) == 3
    clock["t"] = 10 ** 9 + 3601                                          # an hour after the failure, not six
    background_pass(Model(), _Q(), state, now=lambda: clock["t"])
    assert len(calls) == 6


# 7. turning Offline off asks for the prices at once (the Mac app's startBackgroundRefresh), from the window and the tray -
def test_window_offline_switch_off_refreshes_the_prices_now():
    from tokenbar.gui import window as window_mod

    class Model:
        offline = True

        def set_offline(self, v):
            self.offline = v

    class Win:
        on_offline_changed = None

        def __init__(self):
            self.model, self.log = Model(), []

        def refresh(self):
            self.log.append("refresh")

        def prices_when_online(self):
            self.log.append("prices")

    w = Win()
    window_mod.MainWindow._toggle_offline(w, False)
    assert w.model.offline is False and "prices" in w.log and "refresh" in w.log
    w = Win()
    w.model.offline = False
    window_mod.MainWindow._toggle_offline(w, True)
    assert "prices" not in w.log                                        # going offline asks for nothing


def test_tray_offline_switch_off_refreshes_the_prices_now():
    import queue
    from tokenbar.gui.app import drain

    class Window:
        def __init__(self):
            self.log = []

        def refresh(self):
            self.log.append("refresh")

        def prices_when_online(self):
            self.log.append("prices")

    class Icon:
        def update_menu(self):
            pass

    class Model:
        offline = True

        def set_offline(self, v):
            self.offline = v

    q, w, m = queue.Queue(), Window(), Model()
    q.put("offline")                                                     # Offline was on: now off
    drain(q, w, m, Icon())
    assert m.offline is False and w.log == ["refresh", "prices"]
    q.put("offline")                                                     # and on again: no price request
    drain(q, w, m, Icon())
    assert m.offline is True and w.log == ["refresh", "prices", "refresh"]


def test_prices_when_online_asks_without_force_and_says_nothing_when_nothing_changed():
    pytest.importorskip("tkinter")
    from tokenbar.gui.window import MainWindow
    from tokenbar.prices.feed import RefreshReport
    import threading

    asked, jobs = [], []

    class Model:
        offline = False

        def update_prices(self, force=False):
            asked.append(force)
            return RefreshReport(fresh=["openrouter"])

    class Win:
        model = Model()

        class jobs_:
            @staticmethod
            def put(x):
                jobs.append(x)

        jobs = jobs_

    MainWindow.prices_when_online(Win())
    for t_ in threading.enumerate():
        if t_ is not threading.main_thread():
            t_.join(2)
    assert asked == [False] and jobs == [("refresh", None)]


# 8. the price cache: a `fetched` that no clock can show is an old cache; a download has a total time limit -----------
@pytest.mark.parametrize("bad", ["Infinity", "-Infinity", "NaN", "1e300", "-1e300", "-5"])
def test_a_cache_with_an_impossible_fetched_time_is_an_old_cache_not_a_crash(tmp_path, bad):
    from tokenbar.prices.feed import FetchError, PriceFeed
    row = [0.000001, 0.000002, 0, 0, 0]
    good = '{"schema":2,"source":"openrouter","fetched":%s,"rows":{"acme/x":%s}}' % (bad, json.dumps(row))
    (tmp_path / "prices-openrouter.json").write_text(good)
    feed = PriceFeed(str(tmp_path), fetcher=lambda s, e: (_ for _ in ()).throw(FetchError("down")), now=lambda: 10 ** 9)
    cats, origins = feed.load_local()                       # gmtime(1e300) raised OverflowError here
    assert "openrouter" in origins and origins["openrouter"].startswith("cache ")
    seen = []

    def fetch(source, etag):
        seen.append(source)
        raise FetchError("down")

    feed = PriceFeed(str(tmp_path), fetcher=fetch, now=lambda: 10 ** 9)
    report = feed.refresh()
    assert "openrouter" in seen and "openrouter" not in report.fresh      # asked again: the copy counts as old


def test_a_download_that_drips_is_stopped_at_the_total_limit(monkeypatch):
    from tokenbar.prices import feed
    clock = {"t": 0.0}

    class Resp:
        headers = {}

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read1(self, n=-1):
            clock["t"] += 10.0                        # every read is within the 30 s socket timeout
            return b"x"

        read = read1

    monkeypatch.setattr(feed, "_clock", lambda: clock["t"])
    monkeypatch.setattr(feed.urllib.request, "urlopen", lambda req, timeout=None: Resp())
    with pytest.raises(feed.FetchError, match="timed out"):
        feed.url_fetcher("openrouter", None)
    assert clock["t"] <= feed.FETCH_DEADLINE + 10.0
    assert feed.FETCH_DEADLINE == 120                  # the Mac app's timeoutIntervalForResource
