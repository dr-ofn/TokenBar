"""9.0.1 (second batch): the Windows readers brought level with the Mac app's. Each test failed before its fix."""
import json
import os
import shutil
import sys
import types

import pytest

from tokenbar import cli, extdb
from tokenbar.readers.base import Event
from tokenbar.store import Store


def _spaced(row):
    """JSON with the spacing a person (or another tool) writes: a space after every colon and comma."""
    return json.dumps(row)


def _usage(inp=10, out=5, **extra):
    u = {"input": inp, "output": out}
    u.update(extra)
    return u


# ------------------------------------------------------------------ 1. Pi and oh-my-pi: the parsed line decides

@pytest.mark.parametrize("rel,harness", [(".pi/agent/sessions/x/s.jsonl", "pi"), (".omp/agent/sessions/x/s_abc.jsonl", "oh-my-pi")])
def test_a_usage_line_with_spacing_is_counted(home, rel, harness):
    row = {"type": "message", "timestamp": "2026-11-06T10:00:01.000Z",
           "message": {"role": "assistant", "provider": "anthropic", "model": "claude-haiku-5-5", "responseId": "r1",
                       "usage": _usage(30, 12)}}
    assert '"usage": {' in _spaced(row)
    home.write(rel, _spaced(row) + "\n")
    home.scan()
    assert home.total(harness) == 42


@pytest.mark.parametrize("rel,harness", [(".pi/agent/sessions/x/s.jsonl", "pi"), (".omp/agent/sessions/x/s_abc.jsonl", "oh-my-pi")])
def test_an_assistant_line_with_a_nested_role_field_is_not_swallowed(home, rel, harness):
    row = {"type": "message", "timestamp": "2026-11-06T10:00:01.000Z",
           "message": {"role": "assistant", "provider": "anthropic", "model": "claude-haiku-5-5", "responseId": "r1",
                       "usage": _usage(30, 12), "details": {"role": "toolResult"}}}
    line = json.dumps(row, separators=(",", ":"))
    assert '"role":"toolResult"' in line
    home.write(rel, line + "\n")
    home.scan()
    assert home.total(harness) == 42


@pytest.mark.parametrize("rel,harness", [(".pi/agent/sessions/x/s.jsonl", "pi"), (".omp/agent/sessions/x/s_abc.jsonl", "oh-my-pi")])
def test_a_tool_result_is_still_skipped_with_any_spacing(home, rel, harness):
    base = {"type": "message", "timestamp": "2026-11-06T10:00:01.000Z"}
    inside = dict(base, message={"role": "toolResult", "usage": _usage(500, 500), "responseId": "t1"})
    outer = dict(base, role="toolResult", message={"usage": _usage(700, 700), "responseId": "t2"})
    ok = dict(base, message={"role": "assistant", "model": "m", "usage": _usage(1, 2), "responseId": "r9"})
    home.write(rel, "\n".join([json.dumps(inside), json.dumps(inside, separators=(",", ":")), json.dumps(outer),
                               json.dumps(ok)]) + "\n")
    home.scan()
    assert home.total(harness) == 3


def test_a_session_header_line_is_not_a_call(home):
    header = '{"type": "session", "id": "abc", "cwd": "/x", "usage":{"input":99,"output":99}}'      # spaced header, compact usage
    ok = {"type": "message", "message": {"role": "assistant", "model": "m", "usage": _usage(1, 1), "responseId": "r1"}}
    home.write(".pi/agent/sessions/x/s.jsonl", header + "\n" + json.dumps(ok) + "\n")
    home.scan()
    assert home.total("pi") == 2


# ------------------------------------------------------------------ 2. a model named late reaches the earlier call

def _ev(key, model, inp):
    return Event(key, 1.0, "openai", model, inp, 0, 0, 0, 0, 0, "s")


def _models(store):
    return dict(store.db.execute("SELECT key, model FROM events"))


def test_store_gives_a_known_model_to_a_row_written_as_unknown():
    s = Store(":memory:")
    s.apply([(None, [_ev("a", "unknown", 100)], [], [])])
    s.apply([(None, [_ev("a", "gpt-6-luna", 100)], [], [])])          # the same counts, now with a name
    assert _models(s)["a"] == "gpt-6-luna"
    s.close()


def test_store_never_replaces_a_known_model_with_unknown():
    s = Store(":memory:")
    s.apply([(None, [_ev("a", "gpt-6-luna", 100)], [], [])])
    s.apply([(None, [_ev("a", "unknown", 100)], [], [])])
    s.apply([(None, [_ev("a", "unknown", 900)], [], [])])             # even with more tokens
    assert _models(s)["a"] == "gpt-6-luna"
    s.apply([(None, [_ev("a", "gpt-6-sol", 1500)], [], [])])           # a known model with more still wins, as before
    assert _models(s)["a"] == "gpt-6-sol"
    s.close()


def _cx(ts, total, inp, out):
    info = {"total_token_usage": {"input_tokens": inp, "output_tokens": out, "total_tokens": total}}
    return {"timestamp": ts, "type": "event_msg", "payload": {"type": "token_count", "info": info}}


def test_codex_model_named_after_the_first_call_reaches_the_call_written_before_it(home):
    meta = {"type": "session_meta", "payload": {"id": "sid", "timestamp": "2026-11-06T09:00:00Z", "model_provider": "openai"}}
    p = home.jsonl(".codex/sessions/2026/rollout-late.jsonl", meta, _cx("2026-11-06T10:00:00Z", 100, 80, 20))
    home.scan()
    assert set(_models(home.store).values()) == {"unknown"}
    with open(p, "a", encoding="utf-8", newline="") as f:             # the model arrives with a later turn
        for row in ({"type": "turn_context", "payload": {"model": "gpt-6-luna"}}, _cx("2026-11-06T10:01:00Z", 250, 200, 50)):
            f.write(json.dumps(row) + "\n")
    home.scan()
    assert list(_models(home.store).values()) == ["gpt-6-luna", "gpt-6-luna"]
    assert home.total("codex") == 250 and home.calls("codex") == 2


# ------------------------------------------------------------------ 3. zstd output limits on every decoder path

def _pack(tmp_path, payload: bytes):
    zstandard = pytest.importorskip("zstandard")
    p = tmp_path / "a.jsonl.zst"
    p.write_bytes(zstandard.ZstdCompressor().compress(payload))
    return str(p)


def _no_zstandard(monkeypatch):
    monkeypatch.setitem(sys.modules, "zstandard", None)               # `import zstandard` raises ImportError


def _fake_stdlib_zstd(monkeypatch):
    """Python 3.14's compression.zstd, as far as the reader uses it: a file object of the decoded bytes."""
    import zstandard
    mod = types.ModuleType("compression.zstd")

    def zstd_file(file, mode="rb"):
        src = open(file, "rb") if isinstance(file, (str, os.PathLike)) else file
        return zstandard.ZstdDecompressor().stream_reader(src, read_across_frames=True)

    mod.ZstdFile = zstd_file
    pkg = types.ModuleType("compression")
    pkg.zstd = mod
    monkeypatch.setitem(sys.modules, "compression", pkg)
    monkeypatch.setitem(sys.modules, "compression.zstd", mod)


PATHS = ["zstandard", "cli", "stdlib"]


def _prepare(path_name, monkeypatch):
    if path_name == "cli":
        if not shutil.which("zstd"):
            pytest.skip("no zstd program")
        _no_zstandard(monkeypatch)
    elif path_name == "stdlib":
        pytest.importorskip("zstandard")
        _fake_stdlib_zstd(monkeypatch)
        _no_zstandard(monkeypatch)
        monkeypatch.setattr(extdb.shutil, "which", lambda name: None)


@pytest.mark.parametrize("path_name", PATHS)
def test_zstd_lines_read_a_normal_archive(tmp_path, monkeypatch, path_name):
    f = _pack(tmp_path, b'{"a":1}\r\n{"b":2}\n\n{"c":3}')
    _prepare(path_name, monkeypatch)
    assert list(extdb.zstd_lines(f)) == ['{"a":1}', '{"b":2}', "", '{"c":3}']


@pytest.mark.parametrize("path_name", PATHS)
def test_a_line_past_the_limit_is_refused(tmp_path, monkeypatch, path_name):
    f = _pack(tmp_path, b"ok\n" + b"a" * 5000 + b"\nafter\n")
    _prepare(path_name, monkeypatch)
    monkeypatch.setattr(extdb, "ZSTD_MAX_LINE", 1000)
    with pytest.raises(extdb.ZstdTooLarge):
        list(extdb.zstd_lines(f))


@pytest.mark.parametrize("path_name", PATHS)
def test_a_line_without_a_break_past_the_limit_is_refused(tmp_path, monkeypatch, path_name):
    f = _pack(tmp_path, b"a" * (1 << 20))
    _prepare(path_name, monkeypatch)
    monkeypatch.setattr(extdb, "ZSTD_MAX_LINE", 4096)
    with pytest.raises(extdb.ZstdTooLarge):
        list(extdb.zstd_lines(f))


@pytest.mark.parametrize("path_name", PATHS)
def test_total_output_past_the_limit_is_refused(tmp_path, monkeypatch, path_name):
    f = _pack(tmp_path, b"abcdefgh\n" * 5000)
    _prepare(path_name, monkeypatch)
    monkeypatch.setattr(extdb, "ZSTD_MAX_OUTPUT", 10000)
    with pytest.raises(extdb.ZstdTooLarge):
        list(extdb.zstd_lines(f))


@pytest.mark.parametrize("path_name", PATHS)
def test_decompress_has_the_same_total_limit(tmp_path, monkeypatch, path_name):
    zstandard = pytest.importorskip("zstandard")
    data = zstandard.ZstdCompressor().compress(b"x" * 100000)
    _prepare(path_name, monkeypatch)
    monkeypatch.setattr(extdb, "ZSTD_OUTPUT_LIMIT", 5000)
    with pytest.raises(ValueError):
        extdb.zstd_decompress(data)


def test_an_oversize_rollout_is_named_once_a_pass_and_not_unpacked_again(home, monkeypatch):
    pytest.importorskip("zstandard")
    import zstandard
    big = b'{"type":"x"}\n' + b"a" * 5000 + b"\n"
    p = home.write(".codex/archived_sessions/rollout-big.jsonl.zst", zstandard.ZstdCompressor().compress(big))
    monkeypatch.setattr(extdb, "ZSTD_MAX_LINE", 1000)
    first = home.scan()
    assert [m for _, m in first.issues if "rollout-big" in m and "too large" in m]
    assert p not in home.store.file_records()
    calls = []
    real = extdb.zstd_lines
    monkeypatch.setattr(extdb, "zstd_lines", lambda path: calls.append(path) or real(path))
    again = home.scan()
    assert calls == []                                               # not opened again
    assert [m for _, m in again.issues if "rollout-big" in m and "too large" in m]   # still named


def test_the_default_limits_are_the_mac_apps():
    assert extdb.ZSTD_MAX_LINE == 64 << 20
    assert extdb.ZSTD_MAX_OUTPUT == 4 << 30


# ------------------------------------------------------------------ 4. --prices-now

def test_prices_now_is_the_same_flag_as_refresh_prices():
    a = cli.build_parser().parse_args(["--prices-now"])
    b = cli.build_parser().parse_args(["--refresh-prices"])
    assert a.refresh_prices is True and b.refresh_prices is True
    assert cli.build_parser().parse_args([]).refresh_prices is False
    assert "--prices-now" in cli.CLI_FLAGS and cli.is_cli(["--prices-now"])


def test_prices_now_runs_the_refresh_and_offline_still_parses(tmp_path, capsys, monkeypatch):
    from tokenbar.prices.book import PriceBook
    seen = []
    monkeypatch.setattr(PriceBook, "refresh", lambda self, *a, **k: seen.append(1))
    rc = cli.run_cli(["--offline", "--prices-now", "--no-scan", "--json", "--home", str(tmp_path / "h"),
                      "--db", str(tmp_path / "i.sqlite")])
    assert rc == 0 and seen == [1]
    assert cli.build_parser().parse_args(["--offline"]).offline is True


def test_prices_now_skips_the_one_day_wait_as_on_the_mac(tmp_path, monkeypatch):
    # Typing the flag is asking for prices now, like the menu's "Update prices": the daily wait must not swallow it.
    from tokenbar.prices.book import PriceBook
    seen = []
    monkeypatch.setattr(PriceBook, "refresh", lambda self, force=False: seen.append(force))
    rc = cli.run_cli(["--prices-now", "--no-scan", "--json", "--home", str(tmp_path / "h"), "--db", str(tmp_path / "i.sqlite")])
    assert rc == 0 and seen == [True]
