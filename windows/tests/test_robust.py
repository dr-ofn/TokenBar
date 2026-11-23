"""Bad input never raises past the reader, never gives a wrong number, and never writes into a tool's folder."""
import json
import os
import threading

import pytest

from conftest import claude_line
from tokenbar import util
from tokenbar.util import FIELD_LIMIT


def put(home, *lines, name="a.jsonl"):
    return home.write(f".claude/projects/p/{name}", "\n".join(lines) + "\n")


def test_empty_and_garbage_files_count_nothing_and_do_not_raise(home):
    home.write(".claude/projects/p/empty.jsonl", "")
    home.write(".claude/projects/p/bin.jsonl", bytes(range(256)) * 50)
    home.write(".claude/projects/p/text.jsonl", "not json\n{\n[1,2\n\n\n")
    result = home.scan()
    assert home.total() == 0 and result.issues == []


def test_a_valid_line_among_garbage_still_counts(home):
    put(home, "garbage", json.dumps(claude_line(inp=5, out=5)), "}{", '{"type":"assistant"}')
    home.scan()
    assert home.total("claude-code") == 10


@pytest.mark.parametrize("value", ["1e20", "NaN", "Infinity", "-Infinity", "-5", "null", '"12"', "true", "[1]", "{}", "1" + "0" * 400])
def test_odd_numbers_where_a_count_belongs_are_held(home, value):
    line = ('{"type":"assistant","timestamp":"2026-11-06T10:00:00.000Z","message":{"id":"x","model":"claude-opus-5-5",'
            '"usage":{"input_tokens":3,"output_tokens":%s}}}' % value)
    put(home, line)
    home.scan()
    total = home.total("claude-code")
    assert 3 <= total <= 3 + FIELD_LIMIT
    # the report and the cost stay finite whatever the log said
    r = home.report()
    assert r.cost >= 0 and r.cost != float("inf")


@pytest.mark.parametrize("stamp", ["1e20", "-1e20", "NaN", "1" + "0" * 30, '"9999-99-99T99:99:99Z"', '"not a time"'])
def test_absurd_times_do_not_crash(home, stamp):
    line = ('{"type":"assistant","timestamp":%s,"message":{"id":"x","model":"claude-opus-5-5","usage":{"input_tokens":3}}}' % stamp)
    put(home, line)
    home.scan()          # no timestamp means no call: nothing counted, nothing raised
    home.write("AppData/Roaming/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/t/ui_messages.json", json.dumps(
        [{"type": "say", "say": "api_req_started", "ts": json.loads(stamp) if stamp[0] != '"' else 1,
          "text": json.dumps({"tokensIn": 3, "tokensOut": 3})}]).replace("NaN", "null"))
    home.scan()
    assert home.total("cline") in (0, 6)


def test_deeply_nested_json_is_skipped_not_fatal(home):
    deep = "[" * 60000 + "]" * 60000
    put(home, '{"type":"assistant","usage":' + deep + "}", json.dumps(claude_line(inp=2, out=2)))
    home.write("AppData/Roaming/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/t/ui_messages.json", deep)
    home.write(".gemini/tmp/p/chats/c.json", deep)
    result = home.scan()
    assert home.total("claude-code") == 4 and result.issues == []


def test_bom_and_crlf_lines_are_read(home):
    a = json.dumps(claude_line(mid="m1", req="r1", inp=1, out=1))
    b = json.dumps(claude_line(mid="m2", req="r2", inp=2, out=2))
    home.write(".claude/projects/p/a.jsonl", "﻿" + a + "\r\n" + b + "\r\n")
    home.scan()
    assert home.total("claude-code") == 6 and home.calls("claude-code") == 2


def test_lf_and_crlf_copies_of_a_file_are_one_set_of_calls(home):
    line = json.dumps({"type": "assistant", "timestamp": "2026-11-06T10:00:00.000Z",
                       "message": {"model": "claude-opus-5-5", "usage": {"input_tokens": 5}}})        # no id: keyed by its line
    home.write(".claude/projects/p/a.jsonl", line + "\n")
    home.write(".claude/projects/p/b.jsonl", line + "\r\n")
    home.scan()
    assert home.calls("claude-code") == 1


def test_a_line_over_the_limit_is_skipped_and_the_next_one_counts(home, monkeypatch):
    monkeypatch.setattr(util, "MAX_LINE_BYTES", 2000)
    huge = '{"type":"assistant","x":"' + "a" * 5000 + '"}'
    put(home, huge, json.dumps(claude_line(inp=4, out=4)))
    home.scan()
    assert home.total("claude-code") == 8


def test_turkish_and_special_characters_in_paths_and_names(home):
    odd = home.path("Kullanıcılar", "Şükrü Çağlar # 100%")
    from tokenbar.paths import Env
    from tokenbar.scanner import Scanner
    env = Env.for_home(odd)
    line = json.dumps(claude_line(model="ünïcode-模型", inp=3, out=3))
    p = os.path.join(odd, ".claude", "projects", "ğüşiöç İ")
    os.makedirs(p)
    open(os.path.join(p, "ç.jsonl"), "w", encoding="utf-8").write(line + "\n")
    Scanner(home.store, env).scan()
    assert home.total("claude-code") == 6
    assert "ünïcode-模型" in [m.model for h in home.report().harnesses for m in h.models]


def test_a_line_being_written_is_picked_up_when_it_is_finished(home):
    p = home.path(".claude", "projects", "p", "live.jsonl")
    os.makedirs(os.path.dirname(p))
    full = json.dumps(claude_line(inp=7, out=7))
    open(p, "w").write(full[:30])                 # an unterminated, still-written line, modified just now
    home.scan()
    assert home.total() == 0
    open(p, "w").write(full + "\n")
    home.scan()
    assert home.total("claude-code") == 14
    home.scan()
    assert home.total("claude-code") == 14        # and never twice


def test_appended_lines_are_read_from_where_the_last_pass_stopped(home):
    p = put(home, json.dumps(claude_line(mid="m1", req="r1", inp=1, out=1)))
    r1 = home.scan()
    with open(p, "a") as f:
        f.write(json.dumps(claude_line(mid="m2", req="r2", inp=2, out=2)) + "\n")
    r2 = home.scan()
    assert home.total("claude-code") == 6
    assert r2.bytes_read < os.path.getsize(p)      # only the tail was read


def test_a_file_that_shrinks_or_is_rewritten_is_read_again_without_double_counting(home):
    p = put(home, json.dumps(claude_line(mid="m1", req="r1", inp=1, out=1)), json.dumps(claude_line(mid="m2", req="r2", inp=2, out=2)))
    home.scan()
    open(p, "w").write(json.dumps(claude_line(mid="m1", req="r1", inp=1, out=1)) + "\n")
    os.utime(p, (2_000_000_000, 2_000_000_000))
    home.scan()
    assert home.total("claude-code") == 6          # history stays: the index keeps calls whose log lines are gone


def test_a_streamed_request_keeps_its_most_complete_copy(home):
    put(home, json.dumps(claude_line(mid="m1", req="r1", inp=10, out=1)), json.dumps(claude_line(mid="m1", req="r1", inp=10, out=50)),
        json.dumps(claude_line(mid="m1", req="r1", inp=10, out=2)))
    home.scan()
    assert home.total("claude-code") == 60 and home.calls("claude-code") == 1


def test_deleted_logs_keep_their_history(home):
    p = put(home, json.dumps(claude_line(inp=5, out=5)))
    home.scan()
    os.remove(p)
    home.scan()
    assert home.total("claude-code") == 10


def test_two_scans_at_once_count_every_call_once(home):
    for i in range(20):
        home.write(f".claude/projects/p/f{i}.jsonl", json.dumps(claude_line(mid=f"m{i}", req=f"r{i}", inp=1, out=1)) + "\n")
    errors = []

    def go():
        try:
            from tokenbar.scanner import Scanner
            from tokenbar.store import Store
            s = Store(home.store.path)
            Scanner(s, home.env).scan()
            s.close()
        except Exception as e:      # pragma: no cover
            errors.append(e)
    threads = [threading.Thread(target=go) for _ in range(4)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert not errors
    assert home.total("claude-code") == 40 and home.calls("claude-code") == 20


def test_a_corrupt_index_is_reported_not_rebuilt(tmp_path):
    from tokenbar.store import Store, StoreError
    p = tmp_path / "bad.sqlite"
    import sqlite3
    c = sqlite3.connect(p)
    c.execute("CREATE TABLE events(x)")
    c.execute("PRAGMA user_version=99")
    c.commit()
    c.close()
    with pytest.raises(StoreError):
        Store(str(p))
    assert os.path.getsize(p) > 0


def test_a_database_that_is_not_a_database_is_skipped(home):
    home.write(".local/share/opencode/opencode.db", "this is not sqlite" * 100)
    home.write("AppData/Local/Zed/threads/threads.db", b"\x00" * 5000)
    result = home.scan()
    assert home.total() == 0
    assert all(isinstance(i, tuple) for i in result.issues)


def test_nothing_is_written_next_to_the_tools_files(home):
    home.jsonl(".claude/projects/p/a.jsonl", claude_line())
    home.write(".gemini/antigravity-cli/conversations/x.db", b"")
    before = sorted(os.path.join(d, f) for d, _, fs in os.walk(home.root) for f in fs if "_index" not in d)
    home.scan()
    after = sorted(os.path.join(d, f) for d, _, fs in os.walk(home.root) for f in fs if "_index" not in d)
    assert before == after


def test_codex_counter_reset_counts_the_new_run(home):
    def tc(ts, total, inp, out, last=None):
        info = {"total_token_usage": {"input_tokens": inp, "output_tokens": out, "total_tokens": total}}
        if last:
            info["last_token_usage"] = last
        return {"timestamp": ts, "type": "event_msg", "payload": {"type": "token_count", "info": info}}
    home.jsonl(".codex/sessions/2026/rollout-a.jsonl",
               {"type": "session_meta", "payload": {"id": "sid", "timestamp": "2026-11-06T09:00:00Z", "model_provider": "openai"}},
               {"type": "turn_context", "payload": {"model": "gpt-6-luna"}},
               tc("2026-11-06T10:00:00Z", 100, 80, 20), tc("2026-11-06T10:01:00Z", 250, 200, 50),
               tc("2026-11-06T10:02:00Z", 30, 20, 10, {"input_tokens": 20, "output_tokens": 10}))
    home.scan()
    assert home.total("codex") == 100 + 150 + 30 and home.calls("codex") == 3


def test_zstd_rollout_without_a_decoder_is_one_named_issue(home, monkeypatch):
    from tokenbar import extdb
    monkeypatch.setattr(extdb, "zstd_decompress", lambda data: (_ for _ in ()).throw(extdb.ZstdMissing("zstd is not available")))
    home.write(".codex/archived_sessions/rollout-z.jsonl.zst", b"\x28\xb5\x2f\xfd")
    result = home.scan()
    assert [i[1] for i in result.issues].count("zstd is not available") == 1
