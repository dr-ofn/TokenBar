"""9.0.3: Windows defects of 9.0.2 that an independent scan reported. Each test failed before its fix."""
import http.client
import json
import os

import pytest

from tokenbar import extdb
from tokenbar.prices import feed as pfeed
from tokenbar.prices.feed import FetchError, PriceFeed


# 1. a download cut short or a garbled HTTP answer is one failed source, not a crash of the whole pass ------------
class _Resp:
    def __init__(self, exc):
        self.exc = exc
        self.headers = {}

    def read(self, n):
        raise self.exc

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def read1(self, n):
        raise self.exc


@pytest.mark.parametrize("exc", [http.client.IncompleteRead(b"abc", 7), http.client.BadStatusLine("garbage"),
                                 http.client.LineTooLong("header"), http.client.HTTPException("generic")])
def test_url_fetcher_wraps_http_client_errors(monkeypatch, exc):
    monkeypatch.setattr(pfeed.urllib.request, "urlopen", lambda req, timeout=None: _Resp(exc))
    with pytest.raises(FetchError):
        pfeed.url_fetcher("litellm", None)


def test_refresh_goes_on_with_the_other_catalogues_after_a_cut_download(tmp_path, monkeypatch):
    asked = []

    def urlopen(req, timeout=None):
        asked.append(req.full_url)
        return _Resp(http.client.IncompleteRead(b"x", 5))

    monkeypatch.setattr(pfeed.urllib.request, "urlopen", urlopen)
    feed = PriceFeed(str(tmp_path), now=lambda: 10 ** 9)           # the real url_fetcher
    rep = feed.refresh()
    assert len(asked) == 3                                           # none of the sources was skipped
    assert sorted(rep.failed) == ["litellm", "modelsdev", "openrouter"]
    with open(feed._state_path()) as f:
        assert set(json.load(f)["failed"]) == {"litellm", "modelsdev", "openrouter"}


# 2. Codex .jsonl.zst: a UTF-8 BOM in front of the first line is no content (the Mac reader's JSON parser skips it) --
def _cx(ts, total, inp, out):
    info = {"total_token_usage": {"input_tokens": inp, "output_tokens": out, "total_tokens": total}}
    return {"timestamp": ts, "type": "event_msg", "payload": {"type": "token_count", "info": info}}


def _forked_rollout():
    """A fork: its own session starts at 10:00; the parent's 09:00 call is repeated in it and must not count."""
    meta = {"type": "session_meta", "payload": {"id": "child", "timestamp": "2026-11-06T10:00:00Z",
                                                "model_provider": "anthropic"}}
    rows = [meta, {"type": "turn_context", "payload": {"model": "claude-sonnet-4-5"}},
            _cx("2026-11-06T09:00:00Z", 600, 500, 100), _cx("2026-11-06T10:05:00Z", 800, 650, 150)]
    return "".join(json.dumps(r) + "\n" for r in rows).encode()


@pytest.mark.parametrize("bom", [b"", b"\xef\xbb\xbf"])
@pytest.mark.parametrize("name", ["rollout-child.jsonl.zst", "rollout-child.jsonl"])
def test_codex_rollout_with_a_bom_reads_like_one_without(home, name, bom):
    raw = bom + _forked_rollout()
    if name.endswith(".zst"):
        zstandard = pytest.importorskip("zstandard")
        raw = zstandard.ZstdCompressor().compress(raw)
    home.write(".codex/archived_sessions/" + name, raw)
    home.scan()
    rows = home.store.events_since(None)
    assert len(rows) == 1, rows                                  # the parent's 09:00 call is before the fork's start
    assert rows[0][1] == "anthropic" and home.total("codex") == 200


# 3. a -wal whose stat() is refused (not: is missing) is an error, never a .db read without its newest rows ----------
def test_a_wal_that_cannot_be_stat_ed_is_named_and_the_db_is_not_called_read(home, tmp_path, monkeypatch):
    import shutil
    from test_901 import _wal_pair_with_old_rows
    con, live = _wal_pair_with_old_rows(tmp_path, [10], [20])       # 10 is in the .db itself, 20 only in the -wal
    target = home.path(".local", "share", "opencode")
    os.makedirs(target)
    shutil.copy(live / "opencode.db", target)
    shutil.copy(str(live / "opencode.db") + "-wal", target)
    con.close()
    db = os.path.join(target, "opencode.db")
    state = {"denied": True}

    class Os:                                   # extdb's view of `os`: only a stat of the live -wal is refused
        def __getattr__(self, name):
            return getattr(os, name)

        @staticmethod
        def stat(path, *a, **k):
            if state["denied"] and str(path).endswith("-wal") and "tokenbar-extdb-" not in str(path):
                raise PermissionError(13, "Access is denied")
            return os.stat(path, *a, **k)

    monkeypatch.setattr(extdb, "os", Os())
    first = home.scan()
    assert db not in home.store.file_records()                      # not recorded as read
    assert home.total("opencode") == 0                              # and the .db alone (10) was not counted
    assert any(db in m for _, m in first.issues)                    # named
    state["denied"] = False
    home.scan()
    assert home.total("opencode") == 30                             # (10 + 20) read once the -wal can be looked at


# 4. Cline/Roo/Kilo: a time no Int64 can hold (1e20) is a corrupt one; the row is dated by the file (the Mac reader) --
def _cline_task(home, ts, tokens=100):
    text = json.dumps({"tokensIn": tokens, "tokensOut": 20})
    row = {"type": "say", "say": "api_req_started", "ts": ts, "text": text, "modelInfo": {"modelId": "claude-sonnet-4-5", "providerId": "anthropic"}}
    p = home.write("AppData/Roaming/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/t1/ui_messages.json", json.dumps([row]))
    os.utime(p, (1577836800, 1577836800))                          # 2020-01-01
    return p


def test_cline_ts_beyond_int64_is_dated_by_the_file_not_the_far_future(home):
    _cline_task(home, 1e20)
    home.scan()
    rows = home.store.events_since(None)
    assert [r[0] for r in rows] == ["cline:t1:i0"]                 # no 1e20 in the key
    assert rows[0][3] == 1577836800                                 # the file's time
    assert home.report("24h").tokens == 0 and home.report("all").tokens == 120


@pytest.mark.parametrize("ts", [float(2 ** 63), 1e19, -1e20])
def test_cline_ts_outside_int64_after_scaling_is_corrupt(home, ts):
    _cline_task(home, ts)
    home.scan()
    assert [r[0] for r in home.store.events_since(None)] == ["cline:t1:i0"]


def test_cline_ts_inside_int64_is_kept(home):
    _cline_task(home, 1.7e12)
    home.scan()
    assert [r[0] for r in home.store.events_since(None)] == ["cline:t1:1700000000000"]


# 5. model-aliases.json: a cacheRead/cacheWrite that is no number or text is "not given" -> priced like input (Mac) ---
def _alias_entry(tmp_path, alias):
    from tokenbar.paths import Env
    from tokenbar.prices.book import PriceBook
    env = Env.for_home(str(tmp_path / "h"))
    os.makedirs(env.config_dir(), exist_ok=True)
    with open(env.aliases_path(), "w") as f:
        json.dump({"mymodel": alias}, f)
    return PriceBook(env, pinned=False, offline=True).resolve("x", "mymodel")


@pytest.mark.parametrize("given,rate", [([], 10.0), ({}, 10.0), (None, 10.0), (True, 1.0), (False, 0.0),
                                        ("abc", 0.0), ("5", 5.0), (0, 0.0), (2.5, 2.5)])
def test_alias_cache_rate_follows_the_mac_rule(tmp_path, given, rate):
    e = _alias_entry(tmp_path, {"input": 10, "output": 20, "cacheRead": given, "cacheWrite": given})
    assert e["cacheRead"] == rate and e["cacheWrite"] == rate        # the same on Mac (tokenbar-cli): 1M cacheRead -> $10 for []


def test_alias_with_no_cache_keys_prices_cache_like_input(tmp_path):
    e = _alias_entry(tmp_path, {"input": 10, "output": 20})
    assert e["cacheRead"] == 10.0 and e["cacheWrite"] == 10.0


# 6. an oversize Codex archive is recorded (the Mac app's way): what came before the limit counts, the problem is named,
#    and it is not unpacked again after a restart either, until the file changes -----------------------------------------
def _oversize_archive(home, monkeypatch, name="rollout-big.jsonl.zst"):
    zstandard = pytest.importorskip("zstandard")
    big = _forked_rollout() + b"a" * 5000 + b"\n"
    p = home.write(".codex/archived_sessions/" + name, zstandard.ZstdCompressor().compress(big))
    monkeypatch.setattr(extdb, "ZSTD_MAX_LINE", 1000)
    return p


def _count_unpacks(monkeypatch):
    calls = []
    real = extdb.zstd_lines
    monkeypatch.setattr(extdb, "zstd_lines", lambda path: calls.append(path) or real(path))
    return calls


def test_oversize_archive_is_recorded_and_not_unpacked_again_after_a_restart(home, monkeypatch):
    from tokenbar.scanner import Scanner
    p = _oversize_archive(home, monkeypatch)
    first = home.scan()
    assert [m for _, m in first.issues if "rollout-big" in m and "too large" in m]
    assert home.calls("codex") == 1 and p in home.store.file_records()        # the call before the long line, and a record
    calls = _count_unpacks(monkeypatch)
    home.scan()
    restarted = Scanner(home.store, home.env).scan()                          # a new process: no memory of the file
    assert calls == []                                                        # never opened again
    assert [m for _, m in restarted.issues if "rollout-big" in m and "too large" in m]   # and still named
    assert home.calls("codex") == 1


def test_oversize_archive_that_changes_is_read_again(home, monkeypatch):
    from tokenbar.scanner import Scanner
    zstandard = pytest.importorskip("zstandard")
    p = _oversize_archive(home, monkeypatch)
    home.scan()
    monkeypatch.setattr(extdb, "ZSTD_MAX_LINE", 64 << 20)                     # the limit is no more in the way ...
    fresh = zstandard.ZstdCompressor().compress(_forked_rollout() + b"a" * 5000 + b"\n" + b"b\n")
    with open(p, "wb") as f:
        f.write(fresh)                                                        # ... and the archive is another file now
    os.utime(p, (2_000_000_000, 2_000_000_000))
    calls = _count_unpacks(monkeypatch)
    again = Scanner(home.store, home.env).scan()
    assert calls == [p]
    assert not [m for _, m in again.issues if "too large" in m]


# 7. model-aliases.json written by PowerShell's `>` (UTF-16 LE with a BOM) is read, as the Mac app's JSON reader does;
#    a file that cannot be read at all is said, not ignored ----------------------------------------------------------
ALIASES = json.dumps({"mymodel": {"input": 3, "output": 9}})


@pytest.mark.parametrize("encoding", ["utf-8", "utf-8-sig", "utf-16", "utf-16-le", "utf-16-be"])
def test_alias_file_in_any_unicode_encoding_is_read(tmp_path, encoding):
    from tokenbar.paths import Env
    from tokenbar.prices.book import PriceBook
    env = Env.for_home(str(tmp_path / "h"))
    os.makedirs(env.config_dir())
    with open(env.aliases_path(), "wb") as f:
        f.write(ALIASES.encode(encoding))                       # "utf-16" writes the BOM; the -le/-be ones do not
    book = PriceBook(env, pinned=False, offline=True)
    assert book.resolve("x", "mymodel")["output"] == 9.0
    assert book.alias_problem() is None


@pytest.mark.parametrize("content", [b"{broken", b"\xff\xfe{\x00b\x00", b"[1, 2]", b"\xef\xbb\xbfnot json", ALIASES.encode("utf-32")])
def test_unreadable_alias_file_is_said_not_ignored(tmp_path, content):
    from tokenbar.paths import Env
    from tokenbar.prices.book import PriceBook
    env = Env.for_home(str(tmp_path / "h"))
    os.makedirs(env.config_dir())
    with open(env.aliases_path(), "wb") as f:
        f.write(content)
    book = PriceBook(env, pinned=False, offline=True)
    assert book.resolve("x", "mymodel") is None
    assert "model-aliases.json" in (book.alias_problem() or "")


def test_missing_or_empty_alias_file_is_no_problem(tmp_path):
    from tokenbar.paths import Env
    from tokenbar.prices.book import PriceBook
    env = Env.for_home(str(tmp_path / "h"))
    assert PriceBook(env, pinned=False, offline=True).alias_problem() is None
    os.makedirs(env.config_dir())
    open(env.aliases_path(), "wb").close()
    assert PriceBook(env, pinned=False, offline=True).alias_problem() is None


def test_cli_names_an_unreadable_alias_file(tmp_path, capsys, monkeypatch):
    from tokenbar import cli
    monkeypatch.setenv("TOKENBAR_PRICES_PINNED", "0")
    for var, sub in (("USERPROFILE", ""), ("APPDATA", "r"), ("LOCALAPPDATA", "l")):
        monkeypatch.setenv(var, str(tmp_path / "own" / sub))
    h = tmp_path / "h"
    cfg = h / "AppData" / "Roaming" / "TokenBar"
    cfg.mkdir(parents=True)
    (cfg / "model-aliases.json").write_bytes(b"{broken")
    cli.run_cli(["--home", str(h), "--db", str(tmp_path / "u.sqlite"), "--offline", "--window", "all", "--json"])
    assert "model-aliases.json" in capsys.readouterr().err


# 8. the documents in the Windows zip link only to what is in the zip (or to GitHub): ../README.md is not there ---------
def test_relative_links_of_the_zipped_documents_resolve_inside_the_zip(tmp_path):
    import re
    import sys
    import zipfile
    here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    sys.path.insert(0, here)
    import build
    app = tmp_path / "TokenBar"
    app.mkdir()
    (app / "TokenBar.exe").write_bytes(b"x")
    build.copy_extras(str(app), here)
    names = set(zipfile.ZipFile(build.make_zip(str(app), str(tmp_path / "z.zip"))).namelist())
    docs = [n for n in names if n.endswith(".md")]
    assert "TokenBar/README.md" in docs and "TokenBar/README.tr.md" in docs
    for name in docs:
        with zipfile.ZipFile(str(tmp_path / "z.zip")) as z:
            text = z.read(name).decode("utf-8")
        text = re.sub(r"```.*?```", "", text, flags=re.S)
        for url in re.findall(r"\]\(([^)\s]+)\)", text):
            if re.match(r"[a-z]+:", url) or url.startswith("#"):
                continue
            target = os.path.normpath(os.path.join(os.path.dirname(name), url.split("#")[0])).replace(os.sep, "/")
            assert target in names, f"{name}: link {url} leads out of the zip"


# 9. a catalogue that fails now does not hide another one that may be asked again sooner ------------------------------
def test_a_new_price_failure_does_not_mask_the_nearer_retry_of_another_catalogue():
    from tokenbar.gui.app import background_pass
    from tokenbar.prices.feed import RefreshReport

    class Q:
        def put(self, item):
            pass

    class Model:
        offline = False
        asked = 0

        def rescan(self):
            pass

        def report(self):
            return None

        def update_prices(self, force=False):
            Model.asked += 1
            # openrouter failed just now; litellm and modelsdev failed 55 minutes ago and are due again in 300 s
            return RefreshReport(failed={"openrouter": "network"}, skipped=["litellm", "modelsdev"], retry_in=300.0)

    state, t0 = {}, 10 ** 9
    background_pass(Model(), Q(), state, now=lambda: t0)
    assert Model.asked == 1
    background_pass(Model(), Q(), state, now=lambda: t0 + 200)
    assert Model.asked == 1                                    # not yet
    background_pass(Model(), Q(), state, now=lambda: t0 + 305)
    assert Model.asked == 2                                    # litellm's and modelsdev's hour is over: asked again (was: after 3600 s)


# 10. the tray tooltip follows the window's report (new prices after "Update prices" / Offline off) -------------------
from test_901 import _pump, gui  # noqa: E402,F401  (the window fixture)


def test_the_tray_tooltip_is_set_from_every_report_the_window_paints(gui):
    from tokenbar.gui.app import follow_reports, tooltip

    class Icon:
        title = "old numbers"

    root, model, w = gui
    icon = Icon()
    follow_reports(w, model, icon)
    w.prices_when_online()                      # what the tray's Offline switch calls: ends in a report job
    assert _pump(root, lambda: icon.title != "old numbers")
    assert icon.title == tooltip(model, w.report) and icon.title.startswith("TokenBar · ")


def test_the_turkish_readme_says_what_the_english_one_says_about_redirected_output():
    here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    en = open(os.path.join(here, "README.md"), encoding="utf-8").read()
    tr = open(os.path.join(here, "README.tr.md"), encoding="utf-8").read()
    assert "`>` or `|`" in en and "`>` ya da `|`" in tr
    assert "kendi konsolu olmadığından" not in tr


def test_db_stamp_does_not_take_a_wal_it_cannot_look_at_for_no_wal(tmp_path, monkeypatch):
    """A -wal whose stat fails with a permission error is not "no -wal": the stamp must differ from the one taken
    when there was no -wal, or the scanner skips the file and never names the problem (9.0.3 pre-release review)."""
    import tokenbar.readers.base as base
    db = str(tmp_path / "opencode.db")
    open(db, "wb").write(b"a" * 10)
    before = base.db_stamp(db)[0]
    assert before.endswith("|-")
    open(db + "-wal", "wb").write(b"b" * 10)
    real = os.stat

    def stat(p, *a, **k):
        if str(p).endswith("-wal"):
            raise PermissionError(13, "Access is denied")
        return real(p, *a, **k)

    monkeypatch.setattr(base.os, "stat", stat)
    after = base.db_stamp(db)[0]
    assert after != before
    os.remove(db + "-wal")
    monkeypatch.setattr(base.os, "stat", real)
    assert base.db_stamp(db)[0] == before          # a -wal that is really gone is still "-"
