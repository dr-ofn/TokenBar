"""9.0.4 Windows findings from the 9.0.3 scan: each test reproduces one."""
import json
import os
import time

import pytest

from tokenbar import report as report_mod
from tokenbar.report import FUTURE_SLACK_SECONDS


def _cline(home, ts, name="t1", tokens=100):
    text = json.dumps({"tokensIn": tokens, "tokensOut": 20})
    row = {"type": "say", "say": "api_req_started", "ts": ts, "text": text,
           "modelInfo": {"modelId": "claude-sonnet-4-5", "providerId": "anthropic"}}
    p = home.write(f"AppData/Roaming/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/{name}/ui_messages.json", json.dumps([row]))
    os.utime(p, (1577836800, 1577836800))
    return p


# 1. A bounded window counts rows in since <= ts <= now + FUTURE_SLACK_SECONDS; "all" counts everything.
def test_future_slack_constant_is_one_day():
    assert FUTURE_SLACK_SECONDS == 86400


@pytest.mark.parametrize("label,ts", [("now+3y ms", lambda n: (n + 3 * 365 * 86400) * 1000),
                                      ("now+3y s", lambda n: n + 3 * 365 * 86400),
                                      ("2100 ms", lambda n: 4102444800000),
                                      ("2100 s", lambda n: 4102444800)])
def test_far_future_call_is_in_all_only(home, label, ts):
    _cline(home, ts(time.time()))
    home.scan()
    assert home.report("all").tokens == 120
    for period in ("1h", "5h", "24h", "7d", "30d"):
        assert home.report(period).tokens == 0, (label, period)


def test_call_one_hour_ahead_is_still_counted_and_two_days_ahead_is_not(home):
    now = time.time()
    _cline(home, (now + 3600) * 1000, "soon")
    _cline(home, (now + 2 * 86400) * 1000, "later")
    home.scan()
    assert home.report("1h").tokens == 120 and home.report("1h").calls == 1
    assert home.report("all").tokens == 240


# 2. Codex rollout: the Mac reader parses every line on its own, so a UTF-8 BOM in front of ANY line is no content
# (not only in front of the file's first line).
def _bom_rollout(layout):
    from test_903 import _cx
    bom = b"\xef\xbb\xbf"
    meta = {"type": "session_meta", "payload": {"id": "child", "timestamp": "2026-11-06T10:00:00Z", "model_provider": "anthropic"}}
    rows = [meta, {"type": "turn_context", "payload": {"model": "claude-sonnet-4-5"}},
            _cx("2026-11-06T09:00:00Z", 600, 500, 100), _cx("2026-11-06T10:05:00Z", 800, 650, 150)]
    lines = [json.dumps(r).encode() for r in rows]
    return {"blank_then_bom": b"\n" + bom + b"\n".join(lines) + b"\n",
            "bom_every_line": b"".join(bom + l + b"\n" for l in lines),
            "blank_then_bom_every_line": b"\n" + b"".join(bom + l + b"\n" for l in lines),
            "bom_second_line": lines[0] + b"\n" + bom + b"\n".join(lines[1:]) + b"\n"}[layout]


@pytest.mark.parametrize("layout", ["blank_then_bom", "bom_every_line", "blank_then_bom_every_line", "bom_second_line"])
@pytest.mark.parametrize("name", ["rollout-child.jsonl.zst", "rollout-child.jsonl"])
def test_codex_bom_in_front_of_any_line_reads_like_none(home, name, layout):
    raw = _bom_rollout(layout)
    if name.endswith(".zst"):
        zstandard = pytest.importorskip("zstandard")
        raw = zstandard.ZstdCompressor().compress(raw)
    home.write(".codex/archived_sessions/" + name, raw)
    home.scan()
    rows = home.store.events_since(None)
    assert len(rows) == 1, rows                                   # the Mac app: 1 call, 200 tokens, in every layout
    assert home.total("codex") == 200 and home.calls("codex") == 1


# 3. A "badfile:<path>" meta row goes when the file does, and is written in the same transaction as the file's record.
def _scan_with_oversize_archive(home, monkeypatch):
    from test_903 import _oversize_archive
    p = _oversize_archive(home, monkeypatch)
    result = home.scan()
    assert [m for _, m in result.issues if "too large" in m]
    return p


def test_badfile_row_is_removed_when_the_file_is_deleted(home, monkeypatch):
    p = _scan_with_oversize_archive(home, monkeypatch)
    assert [k for k, _ in home.store.meta_prefix("badfile:")] == ["badfile:" + p]
    os.remove(p)
    result = home.scan()
    assert home.store.meta_prefix("badfile:") == []
    assert not [m for _, m in result.issues if "too large" in m]


def test_badfile_row_of_a_file_still_there_stays(home, monkeypatch):
    p = _scan_with_oversize_archive(home, monkeypatch)
    home.scan()
    assert [k for k, _ in home.store.meta_prefix("badfile:")] == ["badfile:" + p]


def test_badfile_row_is_written_with_the_files_record_not_after_it(home, monkeypatch):
    from tokenbar.store import Store

    def refuse(self, key, value):
        raise AssertionError("badfile row written outside the record's transaction")
    monkeypatch.setattr(Store, "set_meta", refuse)
    p = _scan_with_oversize_archive(home, monkeypatch)
    assert p in home.store.file_records()
    assert [k for k, _ in home.store.meta_prefix("badfile:")] == ["badfile:" + p]


# 4. The release audit fails when origin cannot be reached: "a release is made once" cannot be vouched for without it.
import test_901 as t  # noqa: E402


@t.needs_shell
def test_audit_fails_when_origin_cannot_be_reached(tmp_path):
    work = t._release_repo(tmp_path)
    t._git(work, "remote", "set-url", "origin", str(tmp_path / "nowhere.git"))
    t._git(work, "update-ref", "refs/remotes/origin/main", "HEAD")      # HEAD still counts as pushed (the last fetch)
    r = t._audit(work)
    assert r.returncode == 1, (r.returncode, r.stdout, r.stderr)
    assert "could not look at origin" in r.stderr and "NOT checked" in r.stderr and "cannot pass" in r.stderr, r.stderr
    assert "FAILED" in r.stderr and "OK" not in r.stdout


@t.needs_shell
def test_audit_fails_when_there_is_no_origin_at_all(tmp_path):
    work = t._release_repo(tmp_path)
    t._git(work, "remote", "remove", "origin")
    t._git(work, "update-ref", "refs/remotes/origin/main", "HEAD")
    r = t._audit(work)
    assert r.returncode == 1 and "could not look at origin" in r.stderr, (r.returncode, r.stderr)


# 5. model-aliases.json that is not valid UTF-8 is not read (the Mac app names it unreadable): said, no alias loaded.
def _alias_book(tmp_path, raw: bytes):
    from tokenbar.paths import Env
    from tokenbar.prices.book import PriceBook
    env = Env.for_home(str(tmp_path / "h"))
    os.makedirs(env.config_dir(), exist_ok=True)
    with open(env.aliases_path(), "wb") as f:
        f.write(raw)
    return PriceBook(env, pinned=False, offline=True)


def test_alias_file_with_invalid_utf8_is_named_and_no_alias_is_loaded(tmp_path):
    raw = b'{"mymodel": {"input": 1, "output": 2, "name": "\xe9"}}'            # Latin-1 e-acute: not UTF-8
    book = _alias_book(tmp_path, raw)
    assert book.resolve("x", "mymodel") is None
    assert "not valid UTF-8" in (book.alias_problem() or ""), book.alias_problem()


@pytest.mark.parametrize("raw", [
    '{"mymodel": {"input": 1, "output": 2, "name": "é"}}'.encode("utf-8"),
    b"\xef\xbb\xbf" + '{"mymodel": {"input": 1, "output": 2, "name": "é"}}'.encode("utf-8"),
    b"\xff\xfe" + '{"mymodel": {"input": 1, "output": 2, "name": "é"}}'.encode("utf-16-le"),
    b"\xfe\xff" + '{"mymodel": {"input": 1, "output": 2, "name": "é"}}'.encode("utf-16-be"),
    '{"mymodel": {"input": 1, "output": 2, "name": "é"}}'.encode("utf-16-le"),
    '{"mymodel": {"input": 1, "output": 2, "name": "é"}}'.encode("utf-16-be")])
def test_alias_file_in_utf8_or_utf16_is_still_read(tmp_path, raw):
    book = _alias_book(tmp_path, raw)
    assert book.alias_problem() is None
    assert book.resolve("x", "mymodel")["input"] == 1.0


def test_log_reads_keep_replacing_invalid_utf8():
    from tokenbar.util import decode_json_bytes
    assert decode_json_bytes(b'{"a": "\xe9"}') == '{"a": "�"}'
