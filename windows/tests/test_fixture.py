"""The made-up Windows home, counted by the Windows version, against what the Swift command line counts in the same files."""
import io
import json
import os
import subprocess
import sys

import pytest

from fixture_home import expected, make_fixture_home
from tokenbar import cli
from tokenbar.paths import Env
from tokenbar.prices.book import PriceBook
from tokenbar.report import build_report, to_json
from tokenbar.scanner import Scanner
from tokenbar.store import Store

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


@pytest.fixture
def fx(tmp_path):
    home = make_fixture_home(str(tmp_path / "home"))
    env = Env.for_home(home)
    store = Store(str(tmp_path / "usage.sqlite"))
    yield home, env, store
    store.close()


def counted(env, store):
    result = Scanner(store, env).scan()
    book = PriceBook(env, pinned=True, offline=True)
    return result, to_json(build_report(store, book, "all"), result.detected)


def test_totals_match_swift_exactly(fx):
    home, env, store = fx
    result, got = counted(env, store)
    want = expected()
    assert result.issues == []
    assert got["total"] == want["total"] == 34990
    assert got["calls"] == want["calls"] == 72
    assert got["cost"] == pytest.approx(want["cost"], rel=1e-9)
    assert got["unpriced"] == want["unpriced"]
    assert got["detected"] == want["detected"]
    assert set(got["harnesses"]) == set(want["harnesses"])
    for name, h in want["harnesses"].items():
        mine = got["harnesses"][name]
        assert mine["models"] == h["models"], name
        assert (mine["total"], mine["calls"]) == (h["total"], h["calls"]), name
        assert mine["cost"] == pytest.approx(h["cost"], rel=1e-9), name


def test_second_scan_adds_nothing_and_reads_no_file(fx):
    home, env, store = fx
    counted(env, store)
    before = store.event_count()
    again = Scanner(store, env).scan()
    assert store.event_count() == before
    assert sum(s.files_read for s in again.sources) == 0


def test_environment_variables_point_at_the_made_up_folders(fx):
    """USERPROFILE, APPDATA and LOCALAPPDATA decide where everything is, as they do on a real PC."""
    home, _, store = fx
    env = Env.from_os({"USERPROFILE": home, "APPDATA": os.path.join(home, "AppData", "Roaming"),
                       "LOCALAPPDATA": os.path.join(home, "AppData", "Local")})
    _, got = counted(env, store)
    assert got["total"] == 34990 and got["calls"] == 72


def test_a_tool_folder_variable_is_followed_only_for_the_real_home(fx, tmp_path):
    home, _, store = fx
    moved = tmp_path / "moved-claude"
    (moved / "projects").mkdir(parents=True)
    line = {"type": "assistant", "timestamp": "2026-11-06T10:00:00.000Z", "message": {"id": "z", "model": "claude-opus-5-5",
            "usage": {"input_tokens": 7, "output_tokens": 0}}}
    (moved / "projects" / "a.jsonl").write_text(json.dumps(line) + "\n")
    real = Env.from_os({"USERPROFILE": home, "APPDATA": os.path.join(home, "AppData", "Roaming"),
                        "LOCALAPPDATA": os.path.join(home, "AppData", "Local"), "CLAUDE_CONFIG_DIR": str(moved)})
    _, got = counted(real, store)
    assert got["harnesses"]["claude-code"]["total"] == 7          # the moved folder replaces ~/.claude
    other = Store(str(tmp_path / "other.sqlite"))
    _, got2 = counted(Env.for_home(home), other)
    other.close()
    assert got2["harnesses"]["claude-code"]["total"] == 196       # --home ignores the variable


def test_command_line_json_has_the_mac_shape(fx, tmp_path, capsys):
    home, _, _ = fx
    rc = cli.run_cli(["--home", home, "--db", str(tmp_path / "cli.sqlite"), "--window", "all", "--json"])
    out = capsys.readouterr().out
    assert rc == 0
    data = json.loads(out)
    assert set(data) == {"window", "total", "calls", "cost", "unpriced", "harnesses", "detected"}
    assert data["total"] == 34990 and data["calls"] == 72
    models = data["harnesses"]["claude-code"]["models"]
    assert all(len(v) == 7 for v in models.values())


def test_module_entry_point_runs_as_a_process(fx, tmp_path):
    home, _, _ = fx
    env = dict(os.environ, PYTHONPATH=ROOT)
    p = subprocess.run([sys.executable, "-m", "tokenbar", "--home", home, "--db", str(tmp_path / "p.sqlite"), "--window", "all", "--json"],
                       capture_output=True, text=True, env=env, cwd=str(tmp_path))
    assert p.returncode == 0, p.stderr
    assert json.loads(p.stdout)["total"] == 34990


def test_text_report_names_tools_and_models(fx, tmp_path, capsys):
    home, _, _ = fx
    cli.run_cli(["--home", home, "--db", str(tmp_path / "t.sqlite"), "--window", "all"])
    out = capsys.readouterr().out
    assert "All time:" in out and "Claude Code" in out and "per M" in out


def test_rebuild_is_refused_for_the_live_index(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "Local"))
    monkeypatch.setenv("APPDATA", str(tmp_path / "Roaming"))
    monkeypatch.setenv("USERPROFILE", str(tmp_path))
    rc = cli.run_cli(["--rebuild", "--no-scan"])
    assert rc == 2


def test_a_program_without_stdout_still_writes_its_output_file(fx, tmp_path, monkeypatch):
    """TokenBar.exe has no console: `--output` is how its command-line mode answers."""
    home, _, _ = fx
    monkeypatch.setattr(sys, "stdout", None)
    monkeypatch.setattr(sys, "stderr", None)
    out = tmp_path / "answer.json"
    rc = cli.run_cli(["--home", home, "--db", str(tmp_path / "w.sqlite"), "--window", "all", "--json", "--output", str(out)])
    assert rc == 0 and json.loads(out.read_text())["calls"] == 72
