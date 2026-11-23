"""9.0.2 (second pass): what the independent review of 9.0.2 found. Each test failed before its fix.

Invalid UTF-8 and lone surrogates (a JSON "\\udc80", a Windows file name with a broken pair) become U+FFFD on the Mac app
(`J.parse`); here every text that reaches SQLite goes through `safe_text`, and a text that is only compared has to as well.
"""
import json
import os
import re
import sqlite3
import subprocess
import sys
from types import SimpleNamespace

import pytest

import test_901 as t
from tokenbar.readers import g3
from tokenbar.readers.base import Event
from tokenbar.store import FileRecord

SURROGATE = "\udc80"


def _event(key, n=100, session=""):
    return Event(key, 1_700_000_000.0, "p", "m", n, 0, 0, 0, 0, 0, session)


# 1. Zed: a thread with an invalid UTF-8 byte is read with U+FFFD, as the Mac app does --------------------------------
def _zed_db(path, threads):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE threads(id TEXT PRIMARY KEY, summary TEXT NOT NULL, updated_at TEXT NOT NULL, data_type TEXT NOT NULL, data BLOB NOT NULL, created_at TEXT)")
    for tid, blob in threads:
        con.execute("INSERT INTO threads VALUES(?,?,?,?,?,?)", (tid, "", "2026-11-06T10:00:00+00:00", "json", blob, None))
    con.commit()
    con.close()


def _zed_blob(model=b"claude-sonnet-4-5", bom=False):
    body = (b'{"model": {"model": "' + model + b'", "provider": "zed.dev"}, "cumulative_token_usage": {"input_tokens": 700, "output_tokens": 70},'
            b' "request_token_usage": {"r1": {"input_tokens": 100, "output_tokens": 10}, "r2": {"input_tokens": 200, "output_tokens": 20}}}')
    return (b"\xef\xbb\xbf" if bom else b"") + body


def test_zed_thread_with_invalid_utf8_is_read_not_dropped(home):
    _zed_db(home.path("AppData", "Local", "Zed", "threads", "threads.db"), [("t1", _zed_blob(b"claude-\xff-x"))])
    r = home.scan()
    assert home.total("zed") == 700 + 70 and home.calls("zed") == 2, (home.total("zed"), home.calls("zed"), r.issues)   # as the Mac app: 770 tokens, 2 calls


def test_zed_thread_with_invalid_utf8_names_its_model_with_u_fffd(home):
    _zed_db(home.path("AppData", "Local", "Zed", "threads", "threads.db"), [("t1", _zed_blob(b"claude-\xff-x"))])
    home.scan()
    assert {row[2] for row in home.store.events_since(None)} == {"claude-�-x"}


def test_zed_thread_with_a_bom_is_still_read(home):
    _zed_db(home.path("AppData", "Local", "Zed", "threads", "threads.db"), [("t1", _zed_blob(bom=True))])
    home.scan()
    assert home.total("zed") == 770


# 2. Qwen: a session name with a lone surrogate is one session in the lines and in the record -----------------------
def test_qwen_adjustment_does_not_count_again_a_session_whose_name_has_a_lone_surrogate(home):
    session = "s" + SURROGATE
    home.jsonl(".qwen/usage/token-usage-2026-11.jsonl",
               {"id": "a", "timestamp": "2026-11-06T10:00:00Z", "sessionId": session, "model": "qwen-m" + SURROGATE,
                "inputTokens": 100, "cachedTokens": 0, "outputTokens": 20})
    home.jsonl(".qwen/usage_record.jsonl", {"sessionId": session, "timestamp": "2026-11-06T10:00:00Z", "models": {
        "qwen-m" + SURROGATE: {"inputTokens": 100, "cachedTokens": 0, "outputTokens": 20, "totalTokens": 120}}})
    r = home.scan()
    keys = [row[0] for row in home.store.events_since(None)]
    assert keys == ["qwen:a"], (keys, r.issues)                    # no qwen:adj: row: the same tokens, counted once
    assert home.total("qwen-code") == 120


def test_qwen_adjustment_still_adds_what_the_record_holds_beyond_the_lines_for_such_a_session(home):
    session = "s" + SURROGATE
    home.jsonl(".qwen/usage/token-usage-2026-11.jsonl",
               {"id": "a", "timestamp": "2026-11-06T10:00:00Z", "sessionId": session, "model": "m", "inputTokens": 100, "outputTokens": 20})
    home.jsonl(".qwen/usage_record.jsonl", {"sessionId": session, "timestamp": "2026-11-06T10:00:00Z", "models": {
        "m": {"inputTokens": 150, "outputTokens": 20, "totalTokens": 170}}})
    home.scan()
    assert home.total("qwen-code") == 170
    assert [row[0] for row in home.store.events_since(None)].count("qwen:adj:s�:m") == 1


# 3. the store: a key, a prefix or a name with a lone surrogate is stored, compared and looked up as U+FFFD ----------------
def test_store_apply_with_a_task_prefix_and_a_surrogate_key_keeps_the_calls(home):
    store = home.store
    key = "cline:task" + SURROGATE + ":1"
    record = FileRecord(home.path("t" + SURROGATE, "ui_messages.json"), 1, 10, 1.0, 10)
    store.apply([(record, [_event(key), _event("cline:task" + SURROGATE + ":2", 50)], ([], ["cline:task" + SURROGATE + ":"]), [])])
    assert sorted(r[0] for r in store.events_since(None)) == ["cline:task�:1", "cline:task�:2"]
    assert sorted(r[0] for r in store.db.execute("SELECT key FROM event_files")) == ["cline:task�:1", "cline:task�:2"]
    # the same task read again with one call fewer: the first reading is replaced (the owners were recorded under the stored key)
    store.apply([(record, [_event(key)], ([], ["cline:task" + SURROGATE + ":"]), [])])
    assert [r[0] for r in store.events_since(None)] == ["cline:task�:1"]


def test_store_lookups_by_a_name_with_a_lone_surrogate_find_what_was_stored(home):
    store = home.store
    store.apply([(None, [_event("devin:ab" + SURROGATE + "cd:db:r1")], ([], []), [])])
    assert store.has_prefix("devin:ab" + SURROGATE + "cd:db:")
    assert store.sums("devin:ab" + SURROGATE) == {("", "m"): (100, 0, 0, 0)}
    assert store.sums("devin:", exclude="devin:ab" + SURROGATE) == {}
    store.set_meta("k" + SURROGATE, "v" + SURROGATE)
    assert store.meta("k" + SURROGATE) == "v�"
    store.replace_prefix("devin:ab" + SURROGATE + "cd:db:", [])
    assert store.event_count() == 0


# 4. Devin: a transcript whose name has a lone surrogate retires its sessions.db rows, and the loop goes on -------------
def test_devin_after_retires_the_database_rows_of_a_transcript_with_a_lone_surrogate_in_its_name(home, monkeypatch):
    store = home.store
    store.apply([(None, [_event("devin:ab�cd:db:r1"), _event("devin:zz:db:r1", 7)], ([], []), [])])
    names = ["ab" + SURROGATE + "cd.json", "zz.json"]               # the first would stop the loop with UnicodeEncodeError
    monkeypatch.setattr(g3, "walk_files", lambda root, pred: [os.path.join(root, n) for n in names])
    ctx = SimpleNamespace(roots=lambda d: [home.path("devin-root")])
    g3.devin_after(ctx, None, store, 0)
    assert store.event_count() == 0, store.events_since(None)


def test_devin_sessions_with_a_transcript_whose_name_has_a_lone_surrogate_are_not_read_twice(home, monkeypatch):
    covered_name = "ab" + SURROGATE + "cd.json"
    monkeypatch.setattr(g3, "walk_files", lambda root, pred: [os.path.join(root, covered_name)])
    db = home.path("cli", "sessions.db")
    os.makedirs(os.path.dirname(db))
    con = sqlite3.connect(db)
    con.execute("create table sessions(id text, model text, working_directory text)")
    con.execute("create table message_nodes(session_id text, node_id text, chat_message text, created_at text)")
    con.execute("insert into sessions values('ab�cd', 'm', '/x')")
    msg = {"role": "assistant", "metadata": {"request_id": "r1", "metrics": {"input_tokens": 10, "output_tokens": 5}}}
    con.execute("insert into message_nodes values('ab�cd', 'n1', ?, '2026-11-06T10:00:00Z')", (json.dumps(msg),))
    con.commit()
    con.close()
    from tokenbar.readers.base import Sink
    sink = Sink()
    g3._devin_sessions(None, None, db, sink)
    assert sink.events == []                                         # the transcript has them: counting these too would double


# 5. the release audit: a warning on stderr from the remote is not a tag --------------------------------------------------
@t.needs_shell
def test_audit_does_not_take_a_warning_of_the_remote_for_a_tag(tmp_path):
    work = t._release_repo(tmp_path)
    noisy = tmp_path / "noisy-upload-pack.sh"
    noisy.write_text('#!/bin/sh\necho "warning: Permanently added a host to the list of known hosts" >&2\nexec git upload-pack "$@"\n')
    noisy.chmod(0o755)
    t._git(work, "config", "remote.origin.uploadpack", str(noisy))
    r = t._audit(work)
    assert r.returncode == 0 and "already exists on origin" not in r.stderr, (r.returncode, r.stdout, r.stderr)


@t.needs_shell
def test_audit_still_stops_for_a_tag_on_origin_when_the_remote_also_warns(tmp_path):
    work = t._release_repo(tmp_path)
    t._git(work, "tag", "v9.9.9")
    t._git(work, "push", "-q", "origin", "v9.9.9")
    t._git(work, "tag", "-d", "v9.9.9")
    noisy = tmp_path / "noisy-upload-pack.sh"
    noisy.write_text('#!/bin/sh\necho "warning: noise" >&2\nexec git upload-pack "$@"\n')
    noisy.chmod(0o755)
    t._git(work, "config", "remote.origin.uploadpack", str(noisy))
    r = t._audit(work)
    assert r.returncode == 1 and "already exists on origin" in r.stderr, (r.returncode, r.stderr)


# 6. prices: a failure time no clock can show is no failure ------------------------------------------------------------------
@pytest.mark.parametrize("bad", ["1" + "0" * 400, "true", "NaN", "Infinity", "-5", "1e300"])
def test_price_failure_times_out_of_range_are_dropped_not_an_overflow(tmp_path, bad):
    from tokenbar.prices.feed import FetchError, PriceFeed

    def down(source, etag):
        raise FetchError("down")
    feed = PriceFeed(str(tmp_path), fetcher=down)
    with open(feed._state_path(), "w", encoding="utf-8") as f:
        f.write('{"failed": {"litellm": %s, "modelsdev": 1700000000}}' % bad)
    assert feed._failures() == {"modelsdev": 1700000000}
    feed.refresh()                                                   # was an OverflowError for the 400-digit number


# 7. the Windows workflow: the tag's "v" is a lowercase v -------------------------------------------------------------------
def test_the_windows_workflow_matches_the_tag_case_sensitively():
    doc = t._workflow("windows.yml")
    step = next(s for s in doc["jobs"]["build"]["steps"] if s.get("id") == "version")
    script = step["run"]
    assert re.search(r"-cmatch '\^v\(", script) and not re.search(r"(?<!c)-match '\^v", script), script
    # the release job starts for refs/tags/v tags; the version step must not let through a tag spelled otherwise (V9.0.2)
    assert any("startsWith(github.ref, 'refs/tags/v')" in str(job.get("if", "")) for job in doc["jobs"].values())
