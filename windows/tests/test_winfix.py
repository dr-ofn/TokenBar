"""Findings of the last review round, each reproduced first (see windows/tests of the same name in the log)."""
import builtins
import io
import json
import os
import sqlite3
import sys
import time

import pytest

from conftest import claude_line
from fixture_home import make_fixture_home
from tokenbar import cli, extdb, util
from tokenbar.catalog import Catalog
from tokenbar.paths import Env
from tokenbar.prices import feed as pfeed
from tokenbar.scanner import Scanner
from tokenbar.store import FileRecord, Store


def old(path, seconds=3600):
    """Makes a file look quiet for a while (the scanner reads an unterminated last line only then)."""
    t = time.time() - seconds
    os.utime(path, (t, t))
    return path


# ---------------------------------------------------------------------------------------------------- 1 --offline

def _network_spy(monkeypatch):
    calls = []

    def fetcher(source, etag):
        calls.append(source)
        raise pfeed.FetchError("test: no network")
    monkeypatch.setattr("tokenbar.prices.book.url_fetcher", fetcher)
    return calls


def _live_env(monkeypatch, tmp_path):
    for k in ("TOKENBAR_PRICES_PINNED", "TOKENBAR_OFFLINE"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("USERPROFILE", str(tmp_path))
    monkeypatch.setenv("APPDATA", str(tmp_path / "Roaming"))
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "Local"))


def test_cli_offline_flag_stops_the_price_refresh_without_home(monkeypatch, tmp_path):
    calls = _network_spy(monkeypatch)
    _live_env(monkeypatch, tmp_path)
    rc = cli.run_cli(["--offline", "--refresh-prices", "--no-scan", "--db", str(tmp_path / "i.sqlite"), "--output", str(tmp_path / "o.txt")])
    assert rc == 0 and calls == []
    assert "TOKENBAR_OFFLINE" not in os.environ          # the flag is not leaked into the process


def test_cli_refresh_without_offline_does_ask_the_catalogues(monkeypatch, tmp_path):
    calls = _network_spy(monkeypatch)
    _live_env(monkeypatch, tmp_path)
    cli.run_cli(["--refresh-prices", "--no-scan", "--db", str(tmp_path / "i.sqlite"), "--output", str(tmp_path / "o.txt")])
    assert sorted(calls) == ["litellm", "modelsdev", "openrouter"]


# ---------------------------------------------------------------------------------------------------- 2 NTFS inode

@pytest.mark.parametrize("inode", [0, 42, 2 ** 63 - 1, 2 ** 63, 2 ** 63 + 42, 2 ** 64 - 1])
def test_store_keeps_any_64_bit_file_id(inode):
    s = Store(":memory:")
    s.apply([(FileRecord("C:\\a.jsonl", inode, 100, 1.0, 100), [], ([], []), [])])
    assert s.file_records()["C:\\a.jsonl"].inode == inode
    s.close()


def test_a_scan_survives_a_file_id_above_2_63(home, monkeypatch):
    home.jsonl(".claude/projects/p/a.jsonl", claude_line(inp=5, out=5))
    real = os.stat

    class Fake:
        def __init__(self, st):
            self._st = st
            self.st_ino = (1 << 63) + 7

        def __getattr__(self, name):
            return getattr(self._st, name)

    monkeypatch.setattr("tokenbar.scanner.os.stat", lambda p, *a, **k: Fake(real(p, *a, **k)))
    r = home.scan()
    assert r.issues == [] and home.total("claude-code") == 10
    home.scan()                                       # the same id read back: nothing is read twice
    assert home.total("claude-code") == 10


# ---------------------------------------------------------------------------------------------------- protobuf helpers

def _varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def pv(field, value):
    return _varint(field << 3) + _varint(value)


def pb(field, data):
    return _varint(field << 3 | 2) + _varint(len(data)) + data


def make_ag_db(path, models, steps):
    """models: [(enum, name)] in gen_metadata order; steps: [(enum, input, output)] in step order."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE gen_metadata(idx INTEGER, data BLOB)")
    con.execute("CREATE TABLE steps(idx INTEGER, step_type INTEGER, metadata BLOB)")
    for i, (enum, name) in enumerate(models):
        con.execute("INSERT INTO gen_metadata VALUES(?,?)", (i, pb(1, pv(3, enum) + pb(19, name.encode()))))
    for i, (enum, inp, out) in enumerate(steps):
        con.execute("INSERT INTO steps VALUES(?,15,?)", (i, pb(9, pv(1, enum) + pv(2, inp) + pv(3, out)) + pb(8, pv(1, 1793968800))))
    con.commit()
    con.close()


# ---------------------------------------------------------------------------------------------------- 3 Antigravity

def test_antigravity_names_a_call_by_its_model_enum_not_by_row_order(home):
    # gen_metadata lists enum 2 first, but the first call used enum 1 (the Mac reader maps enum -> name).
    make_ag_db(home.path(".gemini", "antigravity-cli", "conversations", "c.db"),
               models=[(2, "model-b"), (1, "model-a")], steps=[(1, 1000, 10), (2, 200, 20)])
    assert home.scan().issues == []
    r = home.report()
    names = {m.name: m.tokens for h in r.harnesses for m in h.models}
    assert names == {"model-a": 1010, "model-b": 220}


def test_antigravity_unknown_enum_gets_the_placeholder_name(home):
    make_ag_db(home.path(".gemini", "antigravity-cli", "conversations", "c.db"), models=[(1, "model-a")], steps=[(7, 5, 5)])
    home.scan()
    names = {m.name for h in home.report().harnesses for m in h.models}
    assert names == {"antigravity-model-7"}


# ---------------------------------------------------------------------------------------------------- 4 oh-my-pi toolResult

def test_omp_tool_result_lines_are_not_counted_twice(home):
    call = {"type": "message", "timestamp": "2026-11-06T10:00:00.000Z",
            "message": {"role": "assistant", "provider": "p", "model": "m", "responseId": "r1",
                        "usage": {"input": 100, "output": 50}}}
    echo = {"type": "message", "timestamp": "2026-11-06T10:00:01.000Z",
            "message": {"role": "toolResult", "provider": "p", "model": "m", "responseId": "r2",
                        "usage": {"input": 600, "output": 100}}}
    compact = lambda x: json.dumps(x, separators=(",", ":"))
    spaced = compact(dict(echo, message=dict(echo["message"], responseId="r3"))).replace('"role":"toolResult"', '"role": "toolResult"')
    home.write(".omp/agent/sessions/p/s.jsonl", "".join(compact(x) + "\n" for x in (call, echo)) + spaced + "\n")
    home.scan()
    assert home.total("oh-my-pi") == 150 and home.calls("oh-my-pi") == 1


# ---------------------------------------------------------------------------------------------------- 5 unreadable files

class _Lock:
    """Windows-style sharing violations: every file under `root` refuses to open, and so does every database."""

    def __init__(self, monkeypatch, root, spare=("projects.json",)):
        self.on = True
        real_open, real_connect = builtins.open, sqlite3.connect
        root = os.path.realpath(root)

        def locked(p):
            return self.on and isinstance(p, (str, os.PathLike)) and os.path.realpath(os.fspath(p)).startswith(root) \
                and os.path.basename(os.fspath(p)) not in spare

        def fake_open(file, *a, **k):
            if locked(file):
                raise PermissionError(13, "The process cannot access the file because it is being used by another process")
            return real_open(file, *a, **k)

        def fake_connect(target, *a, **k):
            if self.on and k.get("uri"):
                raise sqlite3.OperationalError("unable to open database file")
            return real_connect(target, *a, **k)
        real_popen = extdb.subprocess.Popen

        def fake_popen(cmd, *a, **k):
            # Without the `zstandard` package a .zst file is opened by the `zstd` program, a process of its own that the
            # patched `open` above cannot reach. On Windows that program meets the same sharing violation, says so and
            # exits 1 with no output: a program that does exactly that stands in for it.
            if self.on and isinstance(cmd, (list, tuple)) and "-dc" in cmd and locked(cmd[-1]):
                cmd = [sys.executable, "-c", "import sys; sys.exit(1)"]
            return real_popen(cmd, *a, **k)
        monkeypatch.setattr(builtins, "open", fake_open)
        monkeypatch.setattr(extdb.sqlite3, "connect", fake_connect)
        monkeypatch.setattr(extdb.subprocess, "Popen", fake_popen)


def test_locked_files_are_not_recorded_as_scanned_and_are_read_once_free(tmp_path, monkeypatch):
    root = make_fixture_home(str(tmp_path / "home"))
    env = Env.for_home(root)
    store = Store(str(tmp_path / "idx" / "usage.sqlite"))
    scanner = Scanner(store, env)
    lock = _Lock(monkeypatch, root)
    first = scanner.scan()
    assert store.file_records() == {}, sorted(store.file_records())      # nothing was read, so nothing may be marked read
    assert store.event_count() == 0
    assert first.issues, "a locked file must be named, not hidden"
    lock.on = False
    second = scanner.scan()
    from tokenbar.prices.book import PriceBook
    from tokenbar.report import build_report
    report = build_report(store, PriceBook(env, pinned=True, offline=True), "all")
    assert (report.tokens, report.calls) == (34990, 72), second.issues
    store.close()


def test_a_half_written_json_file_is_read_again_when_it_is_whole(home):
    rows = [{"type": "say", "say": "api_req_started", "ts": 1793968800000,
             "text": json.dumps({"tokensIn": 10, "tokensOut": 5})}]
    whole = json.dumps(rows)
    base = "AppData/Roaming/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/t/ui_messages.json"
    p = home.write(base, whole[: len(whole) // 2])                   # the writer is in the middle of it, just now
    home.scan()
    assert home.total("cline") == 0 and p not in home.store.file_records()
    home.write(base, whole)
    home.scan()
    assert home.total("cline") == 15


def test_an_old_corrupt_json_file_is_named_on_every_pass_and_never_recorded(home):
    # As the Mac app does: a file that has been quiet and still is no JSON is a source error each pass, not a reading.
    base = "AppData/Roaming/Code/User/globalStorage/saoudrizwan.claude-dev/tasks/t/ui_messages.json"
    p = old(home.write(base, "[{not json"))
    first = home.scan()
    assert [m for _, m in first.issues if p in m] and p not in home.store.file_records()
    assert [m for _, m in home.scan().issues if p in m]


def test_a_half_written_last_line_does_not_move_the_offset(home):
    a = json.dumps(claude_line(mid="m1", req="r1", inp=1, out=1))
    b = json.dumps(claude_line(mid="m2", req="r2", inp=2, out=2))
    p = home.write(".claude/projects/p/a.jsonl", a + "\n" + b[:30])       # no newline: the writer is not done
    old(p)                                                             # ... but it has been quiet for an hour
    home.scan()
    rec = home.store.file_records()[p]
    assert rec.offset == len(a) + 1 and home.total("claude-code") == 2
    with open(p, "w", encoding="utf-8", newline="") as f:
        f.write(a + "\n" + b + "\n")
    home.scan()
    assert home.total("claude-code") == 2 + 4 and home.calls("claude-code") == 2


def test_an_unterminated_but_complete_last_line_still_counts_once_quiet(home):
    a = json.dumps(claude_line(mid="m1", req="r1", inp=1, out=1))
    p = old(home.write(".claude/projects/p/a.jsonl", a))
    home.scan()
    assert home.total("claude-code") == 2


# ---------------------------------------------------------------------------------------------------- 6 console

class _FakeKernel:
    def __init__(self, ok=True):
        self.calls = []
        self.ok = ok

    def AttachConsole(self, pid):
        self.calls.append(pid)
        return self.ok


def _fake_ctypes(monkeypatch, kernel):
    class M:
        class windll:
            kernel32 = kernel
    monkeypatch.setitem(sys.modules, "ctypes", M)


def _console_open(monkeypatch):
    opened = []
    real = builtins.open

    def fake(file, *a, **k):
        if file == "CONOUT$":
            opened.append(file)
            return io.StringIO()
        return real(file, *a, **k)
    monkeypatch.setattr(builtins, "open", fake)
    return opened


def test_redirected_stdout_is_left_alone(monkeypatch):
    kernel = _FakeKernel()
    _fake_ctypes(monkeypatch, kernel)
    opened = _console_open(monkeypatch)
    monkeypatch.setattr(sys, "platform", "win32")
    pipe_out, pipe_err = io.StringIO(), io.StringIO()               # `> out.json 2> err.txt` or a pipe: not a tty, not None
    monkeypatch.setattr(sys, "stdout", pipe_out)
    monkeypatch.setattr(sys, "stderr", pipe_err)
    cli._attach_console()
    assert sys.stdout is pipe_out and sys.stderr is pipe_err and opened == [] and kernel.calls == []


def test_a_windowed_program_without_streams_borrows_the_console(monkeypatch):
    kernel = _FakeKernel()
    _fake_ctypes(monkeypatch, kernel)
    opened = _console_open(monkeypatch)
    monkeypatch.setattr(sys, "platform", "win32")
    monkeypatch.setattr(sys, "stdout", None)
    monkeypatch.setattr(sys, "stderr", None)
    cli._attach_console()
    assert kernel.calls == [-1] and opened == ["CONOUT$", "CONOUT$"]
    assert sys.stdout is not None and sys.stderr is not None


def test_only_the_missing_stream_is_replaced(monkeypatch):
    kernel = _FakeKernel()
    _fake_ctypes(monkeypatch, kernel)
    opened = _console_open(monkeypatch)
    monkeypatch.setattr(sys, "platform", "win32")
    pipe_out = io.StringIO()                                        # `TokenBar.exe --json > out.json`: stderr has no handle
    monkeypatch.setattr(sys, "stdout", pipe_out)
    monkeypatch.setattr(sys, "stderr", None)
    cli._attach_console()
    assert sys.stdout is pipe_out and sys.stderr is not None and opened == ["CONOUT$"]


# ---------------------------------------------------------------------------------------------------- 7 Devin

def _devin_db(home, session, tokens=(100, 20)):
    path = home.path(".local", "share", "devin", "cli", "sessions.db")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE sessions(id TEXT PRIMARY KEY, working_directory TEXT, model TEXT)")
    con.execute("CREATE TABLE message_nodes(row_id INTEGER PRIMARY KEY, session_id TEXT, node_id INTEGER, chat_message TEXT, created_at INTEGER)")
    con.execute("INSERT INTO sessions VALUES(?,?,?)", (session, "/w", "swe"))
    chat = {"role": "assistant", "metadata": {"request_id": "r1", "generation_model": "swe",
                                               "metrics": {"input_tokens": tokens[0], "output_tokens": tokens[1]}}}
    con.execute("INSERT INTO message_nodes VALUES(1,?,1,?,1793968800)", (session, json.dumps(chat)))
    con.commit()
    con.close()


def test_devin_steps_without_step_id_are_counted_each(home):
    steps = [{"timestamp": "2026-11-06T10:00:00Z", "metrics": {"prompt_tokens": 100, "completion_tokens": 20}},
             {"timestamp": "2026-11-06T10:01:00Z", "metrics": {"prompt_tokens": 250, "completion_tokens": 60}}]
    home.write(".local/share/devin/cli/transcripts/s1.json", json.dumps({"session_id": "s1", "steps": steps}))
    home.scan()
    assert home.total("devin") == 430 and home.calls("devin") == 2


def test_devin_transcript_arriving_after_sessions_db_replaces_its_rows(home):
    _devin_db(home, "s1")
    home.scan()
    assert home.total("devin") == 120
    steps = [{"step_id": 1, "timestamp": "2026-11-06T10:00:00Z", "metrics": {"prompt_tokens": 100, "completion_tokens": 20}}]
    home.write(".local/share/devin/cli/transcripts/s1.json", json.dumps({"session_id": "s1", "steps": steps}))
    home.scan()
    assert home.total("devin") == 120 and home.calls("devin") == 1          # not 240 / 2


def test_corrupt_antigravity_db_is_named_and_left_unrecorded(home):
    p = home.write(".gemini/antigravity-cli/conversations/bad.db", b"this is not a database" * 50)
    r = home.scan()
    assert any("bad.db" in m for _, m in r.issues) and p not in home.store.file_records()


def test_antigravity_impossible_counts_are_refused_not_counted(home):
    make_ag_db(home.path(".gemini", "antigravity-cli", "conversations", "big.db"), models=[(1, "m")], steps=[(1, 1 << 41, 5)])
    r = home.scan()
    assert home.total() == 0 and any("big.db" in m for _, m in r.issues)


# ---------------------------------------------------------------------------------------------------- A5 --home is read-only

def _tree(root):
    return sorted(os.path.relpath(os.path.join(d, n), root) for d, ds, fs in os.walk(root) for n in ds + fs)


def test_home_flag_never_writes_into_the_inspected_folder(monkeypatch, tmp_path):
    mine = tmp_path / "me"
    _live_env(monkeypatch, mine)
    monkeypatch.setenv("TOKENBAR_PRICES_PINNED", "1")
    backup = make_fixture_home(str(tmp_path / "backup"))
    before = _tree(backup)
    rc = cli.run_cli(["--home", backup, "--window", "all", "--json", "--output", str(tmp_path / "o.json")])
    assert rc == 0 and _tree(backup) == before
    # 9.0.5: the index lives with the person running it, as before, but is one of its own for that home: the backup's
    # calls are not mixed into the person's own index (the Mac's rule).
    assert not (mine / "Local" / "TokenBar" / "usage.sqlite").exists()
    assert os.path.exists(cli.home_index_path(cli.Env.from_os(), backup)) and str(mine) in cli.home_index_path(cli.Env.from_os(), backup)
    assert json.loads((tmp_path / "o.json").read_text())["total"] == 34990


@pytest.mark.skipif(os.name == "nt" or (hasattr(os, "geteuid") and os.geteuid() == 0), reason="needs POSIX permissions")
def test_home_flag_on_a_read_only_backup_does_not_crash(monkeypatch, tmp_path):
    _live_env(monkeypatch, tmp_path / "me")
    backup = make_fixture_home(str(tmp_path / "backup"))
    for d, ds, fs in os.walk(backup):
        os.chmod(d, 0o555)
    try:
        rc = cli.run_cli(["--home", backup, "--window", "all", "--json", "--output", str(tmp_path / "o.json")])
    finally:
        for d, ds, fs in os.walk(backup):
            os.chmod(d, 0o755)
    assert rc == 0


def test_unwritable_index_location_is_a_clean_error(tmp_path, capsys):
    blocker = tmp_path / "file"
    blocker.write_text("x")
    rc = cli.run_cli(["--no-scan", "--db", str(blocker / "sub" / "usage.sqlite")])
    assert rc == 1 and "tokenbar:" in capsys.readouterr().err


# ---------------------------------------------------------------------------------------------------- A4 Cline family

from test_argon import api_row, make_opencode, make_zed, zed_thread  # noqa: E402

CLINE = "AppData/Roaming/{editor}/User/globalStorage/{ext}/tasks/t1/ui_messages.json"


@pytest.mark.parametrize("ext,harness", [("saoudrizwan.claude-dev", "cline"), ("rooveterinaryinc.roo-cline", "roo-code"),
                                         ("kilocode.kilo-code", "kilo-code")])
def test_a_rolled_back_message_leaves_the_count(home, ext, harness):
    rel = CLINE.format(editor="Code", ext=ext)
    home.write(rel, json.dumps([api_row(1793968800, 120), api_row(1793968860, 250)]))
    home.scan()
    assert home.total(harness) == 370
    home.write(rel, json.dumps([api_row(1793968800, 120)]))             # the second message was deleted: no marker row
    os.utime(home.path(*rel.split("/")), (2_000_000_000, 2_000_000_000))
    home.scan()
    assert home.total(harness) == 120


def test_the_same_task_in_two_editors_is_not_cut_back_by_one_of_them(home):
    code = CLINE.format(editor="Code", ext="saoudrizwan.claude-dev")
    cursor = CLINE.format(editor="Cursor", ext="saoudrizwan.claude-dev")
    home.write(code, json.dumps([api_row(1793968800, 120)]))
    home.write(cursor, json.dumps([api_row(1793968800, 120), api_row(1793968860, 500)]))
    home.scan()
    assert home.total("cline") == 620
    # Code's copy is rewritten after a checkpoint restore and read again
    home.write(code, json.dumps([api_row(1793968800, 120), api_row(1793968900, 7, "deleted_api_reqs")]))
    os.utime(home.path(*code.split("/")), (2_000_000_000, 2_000_000_000))
    home.scan()
    assert home.total("cline") == 627                                   # Cursor's extra 500 is still counted


def test_a_corrupt_old_task_log_is_named_by_nothing_and_never_cuts_counts(home):
    rel = CLINE.format(editor="Code", ext="saoudrizwan.claude-dev")
    home.write(rel, json.dumps([api_row(1793968800, 120)]))
    home.scan()
    home.write(rel, "[{broken")
    old(home.path(*rel.split("/")))
    os.utime(home.path(*rel.split("/")), (2_100_000_000, 2_100_000_000))
    home.scan()
    assert home.total("cline") == 120


def test_an_index_made_before_the_file_column_is_upgraded(tmp_path):
    path = str(tmp_path / "old.sqlite")
    s = Store(path)
    s.db.execute("ALTER TABLE events DROP COLUMN file")
    s.close()
    s = Store(path)
    assert "file" in {r[1] for r in s.db.execute("PRAGMA table_info(events)")}
    s.close()


# ---------------------------------------------------------------------------------------------------- A6 Qwen accounting

def test_qwen_chat_rows_go_when_qwens_own_accounting_appears(home):
    chat = {"type": "assistant", "uuid": "u1", "sessionId": "s", "timestamp": "2026-11-06T10:00:00Z", "model": "qwen3",
            "usageMetadata": {"promptTokenCount": 100, "candidatesTokenCount": 30, "totalTokenCount": 130}}
    home.jsonl(".qwen/projects/p/chats/c.jsonl", chat)
    home.scan()
    assert home.total("qwen-code") == 130
    home.jsonl(".qwen/usage/token-usage-2026-11.jsonl", {"id": "a1", "timestamp": "2026-11-06T10:00:00Z", "model": "qwen3",
                                                          "inputTokens": 100, "outputTokens": 30, "sessionId": "s"})
    home.scan()
    assert home.total("qwen-code") == 130 and home.calls("qwen-code") == 1


# ---------------------------------------------------------------------------------------------------- A7 oh-my-pi sessions

def test_omp_lines_without_response_id_in_two_sessions_both_count(home):
    line = {"type": "message", "timestamp": "2026-11-06T10:00:00.000Z",
            "message": {"role": "assistant", "provider": "p", "model": "m", "usage": {"input": 10, "output": 5}}}
    for name, sid in (("2026-11-06_a", "sess-a"), ("2026-11-06_b", "sess-b")):
        home.write(f".omp/agent/sessions/p/{name}.jsonl",
                   json.dumps({"type": "session", "id": sid}, separators=(",", ":")) + "\n" + json.dumps(line, separators=(",", ":")) + "\n")
    home.scan()
    assert home.total("oh-my-pi") == 30 and home.calls("oh-my-pi") == 2


# ---------------------------------------------------------------------------------------------------- A8 Codex

def test_codex_calls_before_the_first_turn_context_take_the_first_model(home):
    def tc(ts, total, last):
        return {"timestamp": ts, "type": "event_msg", "payload": {"type": "token_count", "info": {
            "total_token_usage": {"input_tokens": total, "output_tokens": 0}, "last_token_usage": {"input_tokens": last}}}}
    rows = [{"timestamp": "2026-11-06T10:00:00Z", "type": "session_meta", "payload": {"id": "cx1", "timestamp": "2026-11-06T10:00:00Z"}},
            tc("2026-11-06T10:00:01Z", 100, 100),
            {"timestamp": "2026-11-06T10:00:02Z", "type": "turn_context", "payload": {"model": "gpt-6-luna"}},
            {"timestamp": "2026-11-06T10:00:03Z", "type": "turn_context", "payload": {"model": "gpt-6-astra"}},
            tc("2026-11-06T10:00:04Z", 150, 50)]
    home.jsonl(".codex/sessions/2026/rollout-x.jsonl", *rows)
    home.scan()
    got = {m.name: m.tokens for h in home.report().harnesses for m in h.models}
    assert got == {"GPT-6 Luna": 100, "GPT-6 Astra": 50}, got


# ---------------------------------------------------------------------------------------------------- A9 Zed without zstd

def test_zed_threads_wait_for_zstd_instead_of_being_marked_read(home, monkeypatch):
    path = home.path("AppData", "Local", "Zed", "threads", "threads.db")
    make_zed(path, [("t1", "zstd", zed_thread(500))])
    real = extdb.zstd_decompress
    monkeypatch.setattr(extdb, "zstd_decompress", lambda data: (_ for _ in ()).throw(extdb.ZstdMissing("zstd is not available")))
    first = home.scan()
    assert any("zstd" in m for _, m in first.issues) and path not in home.store.file_records()
    monkeypatch.setattr(extdb, "zstd_decompress", lambda data: data)                  # zstd is there now (and the blob is plain)
    home.scan()
    assert home.total("zed") == 500


# ---------------------------------------------------------------------------------------------------- A13 rowid watermark

def test_opencode_watermark_survives_a_wal_checkpoint_shrinking_the_file(home):
    path = home.path(".local", "share", "opencode", "opencode.db")
    make_opencode(path, [(i, f"m{i}", 1) for i in range(1, 51)])
    home.scan()
    assert home.total("opencode") == 50
    rec = home.store.file_records()[path]
    assert rec.offset == 50
    # the stamp (db + wal) shrank but the file is the same file: the scanner must hand the old watermark on
    from tokenbar.scanner import REGISTRY
    fam = REGISTRY["opencode-sqlite"]
    got = []
    orig = fam.read
    fam.read = lambda ctx, d, p, offset, limit, settled, sink: (got.append(offset), orig(ctx, d, p, offset, limit, settled, sink))[1]
    try:
        home.store.db.execute("UPDATE files SET size = size + 4096, mtime = 0 WHERE path = ?", (path,))   # it was bigger before
        home.store.db.execute("UPDATE meta SET v = 'bigger-before' WHERE k = ?", ("dbstamp:" + path,))     # (the stamp is what says "changed")
        home.scan()
    finally:
        fam.read = orig
    assert got == [50], got


# ---------------------------------------------------------------------------------------------------- 9 single instance

class _Kernel:
    def __init__(self, handle):
        self.handle = handle
        self.closed = []

    def CreateMutexW(self, attrs, owner, name):
        assert name.startswith("Local\\") and owner is False
        return self.handle

    def CloseHandle(self, h):
        self.closed.append(h)


@pytest.mark.parametrize("handle,error,expect_none,closed", [
    (11, 0, False, []),          # first TokenBar
    (11, 183, True, [11]),       # ERROR_ALREADY_EXISTS: the handle to the other's mutex is closed again
    (0, 5, True, []),            # ERROR_ACCESS_DENIED: the mutex is another session's or another user's
    (0, 8, False, []),           # any other failure: run anyway, never lock the person out
])
def test_single_instance_reads_the_error_from_ctypes_not_from_a_later_call(handle, error, expect_none, closed):
    from tokenbar.gui.app import acquire_single_instance
    kernel = _Kernel(handle)
    got = acquire_single_instance(kernel, lambda: error)
    assert (got is None) == expect_none and kernel.closed == closed


# ---------------------------------------------------------------------------------------------------- 13 Run key

class _NoKeyWinreg:
    """A fresh Windows profile: the Run key does not exist until it is created."""
    HKEY_CURRENT_USER = "HKCU"
    KEY_SET_VALUE = 2
    REG_SZ = 1

    def __init__(self):
        self.created, self.values = False, {}

    class _Key:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    def OpenKey(self, root, path, reserved=0, access=0):
        if not self.created:
            raise FileNotFoundError(path)
        return self._Key()

    def CreateKeyEx(self, root, path, reserved=0, access=0):
        self.created = True
        return self._Key()

    def SetValueEx(self, key, name, _r, kind, value):
        self.values[name] = value

    def DeleteValue(self, key, name):
        raise FileNotFoundError(name)


def test_start_with_windows_works_when_the_run_key_does_not_exist_yet():
    from tokenbar.gui import startup
    reg = _NoKeyWinreg()
    assert startup.set_enabled(True, reg) is True and "TokenBar" in reg.values
    assert startup.set_enabled(False, _NoKeyWinreg()) is True      # nothing to remove is fine


# ---------------------------------------------------------------------------------------------------- 10 forced price refresh

def test_the_menus_update_prices_asks_again_after_a_failure_and_inside_the_day(tmp_path):
    from tokenbar.prices.feed import PriceFeed, FetchError
    online = {"on": False}
    asked = []

    def fetcher(source, etag):
        asked.append(source)
        if not online["on"]:
            raise FetchError("no wifi")
        return ("ok", json.dumps({"data": [{"id": "a/b", "pricing": {"prompt": "0.000001", "completion": "0.000002"}}]}).encode()
                if source == "openrouter" else b"{}", None)
    feed = PriceFeed(str(tmp_path / "cache"), fetcher=fetcher)
    r1 = feed.refresh()
    assert set(r1.failed) == {"openrouter", "litellm", "modelsdev"}
    online["on"] = True
    r2 = feed.refresh()
    assert r2.failed == {} and len(r2.skipped) == 3                     # inside the hour: skipped (the old behaviour of the menu)
    asked.clear()
    r3 = feed.refresh(force=True)
    assert sorted(asked) == ["litellm", "modelsdev", "openrouter"] and "openrouter" in r3.updated
    asked.clear()
    feed.refresh(force=True)                                            # the cache is fresh now, but the person asked
    assert len(asked) == 3
    asked.clear()
    feed.refresh()                                                      # the background pass still respects the day
    assert asked == []


def test_the_window_asks_for_a_forced_refresh(monkeypatch):
    tk = pytest.importorskip("tkinter")
    try:
        root = tk.Tk()
    except tk.TclError:
        pytest.skip("no display")
    root.withdraw()
    from tokenbar.gui.window import MainWindow

    class FakeModel:
        offline = False
        scanning = False
        period = "24h"
        settings = {"language": "auto"}
        last_scan = None

        def __init__(self):
            self.calls = []

        def update_prices(self, force=False):
            self.calls.append(force)
            return None

        def detected(self):
            return [], []

    try:
        m = FakeModel()
        w = MainWindow(root, m, on_quit=root.destroy)
        w.update_prices()
        import time
        end = time.time() + 3
        while not m.calls and time.time() < end:
            time.sleep(0.01)
        assert m.calls == [True]
    finally:
        root.destroy()


def test_changing_the_language_only_saves_it_for_the_next_start(tmp_path, monkeypatch):
    from tokenbar import i18n
    monkeypatch.delenv("TOKENBAR_LANG", raising=False)
    from tokenbar.gui.model import AppModel
    m = AppModel(env=Env.for_home(str(tmp_path / "h")), store=Store(str(tmp_path / "u.sqlite")))
    try:
        i18n.set_language("en")
        m.set_language("tr")
        assert i18n.t("Aç", "Open") == "Open" and m.settings["language"] == "tr"
    finally:
        i18n.set_language("en")
        m.close()


# ---------------------------------------------------------------------------------------------------- 15 threads

class _Q:
    def __init__(self):
        self.items = []

    def put(self, x):
        self.items.append(x)


def test_the_background_thread_only_posts_it_never_touches_the_window_or_tray():
    from tokenbar.gui.app import background_pass, tooltip

    class Model:
        offline = False

        def __init__(self):
            self.n = 0
            self.prices = 0

        def rescan(self):
            self.n += 1

        def report(self):
            return None

        def update_prices(self, force=False):
            self.prices += 1

    q, m, state = _Q(), Model(), {}
    background_pass(m, q, state, now=lambda: 10 ** 9)
    assert q.items == [("tooltip", "TokenBar"), "scanned"] and m.prices == 1
    background_pass(m, q, state, now=lambda: 10 ** 9 + 60)             # prices are asked once in a while, not every pass
    assert m.prices == 1 and m.n == 2


def test_the_main_loop_applies_what_the_threads_posted():
    import queue
    from tokenbar.gui.app import drain

    class Window:
        def __init__(self):
            self.log = []

        def toggle(self):
            self.log.append("toggle")

        def refresh(self):
            self.log.append("refresh")

        def background_scan_done(self):
            self.log.append("scan done")

        def update_prices(self):
            self.log.append("prices")

    class Icon:
        title = ""
        menu_updates = 0

        def update_menu(self):
            self.menu_updates += 1

    class Model:
        offline = False

        def set_offline(self, v):
            self.offline = v

    q, w, i, m = queue.Queue(), Window(), Icon(), Model()
    for item in ("show", ("tooltip", "TokenBar · $1"), "scanned", "offline"):
        q.put(item)
    assert drain(q, w, m, i) is False
    assert w.log == ["toggle", "scan done", "refresh"] and i.title == "TokenBar · $1" and i.menu_updates == 1 and m.offline
    q.put("quit")
    assert drain(q, w, m, i) is True


def test_the_windows_offline_switch_updates_the_tray_menu():
    tk = pytest.importorskip("tkinter")
    try:
        root = tk.Tk()
    except tk.TclError:
        pytest.skip("no display")
    root.withdraw()
    from tokenbar.gui.window import MainWindow

    class FakeModel:
        offline = False
        scanning = False
        period = "24h"
        settings = {"language": "auto"}
        last_scan = None

        def set_offline(self, v):
            self.offline = v

        def report(self, period=None):
            raise RuntimeError("not needed")

        def detected(self):
            return [], []

    try:
        w = MainWindow(root, FakeModel(), on_quit=root.destroy)
        hits = []
        w.on_offline_changed = lambda: hits.append(1)
        w._toggle_offline(True)
        assert hits == [1]
    finally:
        root.destroy()


# ---------------------------------------------------------------------------------------------------- 8 spec, 11 release

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _spec_calls():
    import ast
    tree = ast.parse(open(os.path.join(ROOT, "windows", "TokenBar.spec"), encoding="utf-8").read())
    return [n for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)]


def test_spec_has_no_merge_and_each_program_names_its_own_hidden_imports():
    import ast
    calls = _spec_calls()
    assert not [c for c in calls if c.func.id == "MERGE"]
    source = open(os.path.join(ROOT, "windows", "TokenBar.spec"), encoding="utf-8").read()
    names = {}
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name):
            try:
                names[node.targets[0].id] = ast.literal_eval(node.value)
            except ValueError:
                pass
    assert "zstandard.backend_c" in names["gui_hidden"] and "zstandard.backend_c" in names["cli_hidden"]
    assert "pystray" not in " ".join(names["cli_hidden"])
    analyses = [c for c in calls if c.func.id == "Analysis"]
    assert len(analyses) == 2
    for a in analyses:
        kw = {k.arg: k.value for k in a.keywords}
        hidden = names[kw["hiddenimports"].id]
        excluded = ast.literal_eval(kw["excludes"])
        assert not [h for h in hidden if h.split(".")[0] in excluded], "a hidden import that is also excluded"


def test_a_tag_push_is_not_filtered_by_paths_and_the_release_gets_the_checksum():
    yaml = pytest.importorskip("yaml")
    path = os.path.join(ROOT, ".github", "workflows", "windows.yml")
    if not os.path.exists(path):
        pytest.skip("not inside the repository")
    doc = yaml.safe_load(open(path, encoding="utf-8"))
    on = doc.get("on", doc.get(True))
    assert "paths" not in on["push"] and on["push"]["tags"] == ["v*"]      # a path filter would also skip a tag push
    assert "paths" in on["pull_request"]
    build = " ".join(str(s.get("run", "")) + str(s.get("with", "")) for s in doc["jobs"]["build"]["steps"])
    assert "sha256" in build.lower() and "Get-FileHash" in build
    release = " ".join(str(s.get("run", "")) for s in doc["jobs"]["release"]["steps"])
    assert ".zip.sha256" in release and "gh release view" in release and "${TAG#v}" in release


def test_release_script_prints_commands_that_work_whichever_comes_first():
    text = open(os.path.join(ROOT, "scripts", "release.sh"), encoding="utf-8").read()
    assert "gh release view" in text and "gh release upload" in text and "gh release edit" in text and "gh release create" in text


# ---------------------------------------------------------------------------------------------------- 14 / A10 paths

@pytest.mark.parametrize("path,uri", [
    ("C:\\Users\\a b\\x.db", "file:///C:/Users/a%20b/x.db"),
    ("\\\\fileserver\\users\\alice\\opencode.db", "file:////fileserver/users/alice/opencode.db"),
    ("\\\\?\\UNC\\fileserver\\users\\alice\\x.db", "file:////fileserver/users/alice/x.db"),
    ("\\\\?\\C:\\very\\long\\x.db", "file:///C:/very/long/x.db"),
    ("\\\\fileserver\\share\\caf\u00e9 #1.db", "file:////fileserver/share/caf%C3%A9%20%231.db"),
])
def test_sqlite_uri_for_drive_and_network_paths(path, uri):
    assert extdb.file_uri(path) == uri


def test_sqlite_accepts_the_uri_for_a_local_path(tmp_path):
    p = str(tmp_path / "caf\u00e9 #1.db")
    sqlite3.connect(p).execute("create table t(a)").connection.close()
    assert extdb.rows(p, "select count(*) from sqlite_master") == [(1,)]


def test_long_windows_paths_reach_the_file_system_with_the_prefix(monkeypatch, tmp_path):
    from tokenbar.readers.base import db_stamp
    monkeypatch.setattr(os, "name", "nt")
    long = str(tmp_path / ("d" * 250) / "x.db")
    asked = []
    real_stat = os.stat
    monkeypatch.setattr(os, "stat", lambda p, *a, **k: (asked.append(p), real_stat(p, *a, **k))[1])
    monkeypatch.setattr(os.path, "isfile", lambda p: asked.append(p) or False)
    monkeypatch.setattr(os.path, "isdir", lambda p: asked.append(p) or True)
    walked = []
    monkeypatch.setattr(os, "walk", lambda root, **k: walked.append(root) or iter(()))
    db_stamp(long)
    extdb._stamp(long)
    util.seen_once([long])
    util.walk_files(long, lambda n: True)
    assert asked and all(str(p).startswith("\\\\?\\") for p in asked), asked
    assert walked and walked[0].startswith("\\\\?\\")


def test_smoke_reads_the_program_output_as_utf8(monkeypatch):
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
    import smoke
    seen = {}

    def fake_run(cmd, **kw):
        seen.update(kw)
        raise RuntimeError("stop")
    monkeypatch.setattr(smoke.subprocess, "run", fake_run)
    with pytest.raises(RuntimeError):
        smoke.main("x.exe")
    assert seen["encoding"] == "utf-8" and seen["errors"] == "replace"


def test_rebuild_guard_ignores_the_case_of_the_live_index(monkeypatch, tmp_path, capsys):
    _live_env(monkeypatch, tmp_path)
    live = Env.from_os().db_path()
    monkeypatch.setattr(os.path, "normcase", lambda p: p.lower())          # what Windows does
    rc = cli.run_cli(["--rebuild", "--no-scan", "--db", live.upper()])
    assert rc == 2


# ---------------------------------------------------------------------------------------------------- 16 aliases

def test_alias_with_an_out_of_range_rate_is_not_an_alias_at_all():
    from tokenbar.prices.engine import parse_aliases
    aliases, _ = parse_aliases({"aliases": {"m1": {"input": 1e308, "output": 1}, "m2": {"input": 1, "output": 2},
                                            "m3": {"input": 1, "output": 2, "cacheRead": 1e9}, "m4": {"input": 1, "output": 2, "cacheWrite": -1}}})
    assert set(aliases) == {"m2"}


def test_qwen_line_without_an_id_is_skipped(home):
    home.jsonl(".qwen/usage/token-usage-2026-11.jsonl",
               {"timestamp": "2026-11-06T10:00:00Z", "model": "q", "inputTokens": 5, "outputTokens": 5},
               {"id": "ok", "timestamp": "2026-11-06T10:00:00Z", "model": "q", "inputTokens": 3, "outputTokens": 2})
    home.scan()
    assert home.total("qwen-code") == 5 and home.calls("qwen-code") == 1


# ---------------------------------------------------------------------------------------------------- A14 update-prices

def _load_update_prices():
    import importlib.util
    path = os.path.join(ROOT, "scripts", "update-prices.py")
    if not os.path.exists(path):
        pytest.skip("not inside the repository")
    spec = importlib.util.spec_from_file_location("update_prices_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    sys.path.insert(0, os.path.join(ROOT, "scripts"))
    spec.loader.exec_module(mod)
    return mod


def test_the_price_script_writes_the_windows_files_too(tmp_path, monkeypatch):
    up = _load_update_prices()
    monkeypatch.setattr(up, "ROOT", str(tmp_path))
    data = tmp_path / "windows" / "tokenbar" / "data"
    data.mkdir(parents=True)
    (tmp_path / "scripts").mkdir()
    (tmp_path / "Sources" / "LocalCore").mkdir(parents=True)
    (data / "price-tables.json").write_text(json.dumps({"date": "x", "entries": [], "personal": ["keep"]}))
    entry = {"key": "m", "name": "M", "kind": "near", "source": "s", "input": 1.0, "output": 2.0, "cacheRead": 0.1,
             "cacheWrite": 1.0, "cacheWrite1h": 2.0, "tiers": []}
    up.write_tables([entry], "2026-01-01")
    written = json.loads((data / "price-tables.json").read_text())
    assert written["date"] == "2026-01-01" and written["entries"] == [entry] and written["personal"] == ["keep"]
    assert json.loads((tmp_path / "scripts" / "prices.json").read_text())["entries"] == [entry]
    # the snapshot: the same bytes on both sides
    lite, models = tmp_path / "l.json", tmp_path / "m.json"
    lite.write_text(json.dumps({"gpt-x": {"input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6, "litellm_provider": "openai", "mode": "chat"}}))
    models.write_text(json.dumps({"acme": {"id": "acme", "models": {"m1": {"id": "m1", "name": "M1", "cost": {"input": 1, "output": 2}}}}}))
    up.build_snapshot(str(lite), str(models))
    mac = (tmp_path / "Sources" / "LocalCore" / "Resources" / "prices-snapshot.json").read_bytes()
    assert mac and (data / "prices-snapshot.json").read_bytes() == mac


def test_omp_decimal_usage_fields_are_not_token_counts(home):
    line = {"type": "message", "timestamp": "2026-11-06T10:00:00.000Z", "message": {
        "role": "assistant", "provider": "p", "model": "m", "responseId": "r9",
        "usage": {"input": 10, "output": 5, "cacheRead": 2.5, "reasoningTokens": 0.75}}}
    home.write(".omp/agent/sessions/p/s.jsonl", json.dumps(line, separators=(",", ":")) + "\n")
    home.scan()
    assert home.total("oh-my-pi") == 15
