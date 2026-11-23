"""Start with Windows (a fake registry), the window's model, and the window itself when this machine has a screen."""
import json
import os
import sys

import pytest

from fixture_home import make_fixture_home
from tokenbar.gui import startup
from tokenbar.gui.model import AppModel, Settings
from tokenbar.paths import Env
from tokenbar.store import Store


class FakeWinreg:
    HKEY_CURRENT_USER = "HKCU"
    KEY_SET_VALUE = 2
    REG_SZ = 1

    def __init__(self):
        self.values = {}

    class _Key:
        def __init__(self, outer):
            self.outer = outer

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    def OpenKey(self, root, path, reserved=0, access=0):
        assert root == "HKCU" and path == startup.RUN_KEY       # the current user's Run key, nothing machine-wide
        return self._Key(self)

    def CreateKeyEx(self, root, path, reserved=0, access=0):
        assert root == "HKCU" and path == startup.RUN_KEY       # makes the key when a fresh profile has none
        return self._Key(self)

    def SetValueEx(self, key, name, _r, kind, value):
        self.values[name] = value

    def QueryValueEx(self, key, name):
        if name not in self.values:
            raise FileNotFoundError(name)
        return self.values[name], 1

    def DeleteValue(self, key, name):
        if name not in self.values:
            raise FileNotFoundError(name)
        del self.values[name]


def test_start_with_windows_adds_and_removes_one_value():
    reg = FakeWinreg()
    assert not startup.is_enabled(reg)
    assert startup.set_enabled(True, reg) and startup.is_enabled(reg)
    assert reg.values["TokenBar"].startswith('"')
    assert startup.set_enabled(False, reg) and not startup.is_enabled(reg)
    assert startup.set_enabled(False, reg)                       # turning it off twice is fine


def test_start_command_for_the_packaged_exe(monkeypatch):
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "executable", r"C:\Apps\TokenBar\TokenBar.exe")
    assert startup.command() == r'"C:\Apps\TokenBar\TokenBar.exe"'


def test_settings_survive_a_restart_and_ignore_junk(tmp_path):
    p = str(tmp_path / "s" / "settings.json")
    s = Settings(p)
    s.set("period", "7d")
    s.set("offline", True)
    again = Settings(p)
    assert again["period"] == "7d" and again["offline"] is True
    open(p, "w").write('{"period": "yesterday", "offline": "yes", "language": "klingon"}')
    junk = Settings(p)
    assert junk["period"] == "24h" and junk["offline"] is False and junk["language"] == "auto"
    open(p, "w").write("not json")
    assert Settings(p)["period"] == "24h"


@pytest.fixture
def model(tmp_path):
    home = make_fixture_home(str(tmp_path / "home"))
    m = AppModel(env=Env.for_home(home), store=Store(str(tmp_path / "u.sqlite")))
    yield m
    m.close()


def test_model_scans_reports_and_remembers_the_period(model):
    assert model.rescan() is not None
    model.set_period("all")
    r = model.report()
    assert r.tokens == 34990 and r.calls == 72
    assert Settings(model.env.settings_path())["period"] == "all"
    found, not_countable = model.detected()
    assert "claude-code" in found and "warp" in not_countable


def test_a_second_scan_while_one_runs_is_refused(model):
    assert model._scan_lock.acquire(blocking=False)
    try:
        assert model.rescan() is None
    finally:
        model._scan_lock.release()


def test_offline_switch_is_remembered(model):
    model.set_offline(True)
    assert model.offline and Settings(model.env.settings_path())["offline"] is True
    assert model.update_prices() is None


def test_the_window_paints_a_report(model):
    tk = pytest.importorskip("tkinter")
    try:
        root = tk.Tk()
    except tk.TclError:
        pytest.skip("no display")
    root.withdraw()
    try:
        import time
        from tokenbar.gui.window import MainWindow
        w = MainWindow(root, model, on_quit=root.destroy)
        model.rescan()
        model.set_period("all")
        w.refresh()
        end = time.time() + 5
        while time.time() < end and w.report is None:
            root.update()
            time.sleep(0.02)
        assert w.report is not None and w.report.tokens == 34990
        assert w.total_money.cget("text") == "$0.01"
        assert "35K tokens" in w.total_tokens.cget("text")
        names = [w.tree.item(i, "text") for i in w.tree.get_children()]
        assert "Claude Code" in names and "Zed" in names
        assert "Warp" in w.detected_label.cget("text")
        w.show()
        root.update()
        w.hide()
    finally:
        root.destroy()


def test_tray_icon_image_is_drawn():
    from tokenbar.gui.icon import make_icon, make_ico_bytes
    img = make_icon(64)
    assert img.size == (64, 64) and img.getpixel((32, 32))[3] > 0
    assert make_ico_bytes()[:4] == b"\x00\x00\x01\x00"


def test_tooltip_fits_the_windows_limit(model):
    from tokenbar.gui.app import tooltip
    model.rescan()
    assert len(tooltip(model, model.report("all"))) <= 127 and tooltip(model, None) == "TokenBar"


def test_the_workflow_is_valid_yaml_with_the_steps_the_brief_asks_for():
    yaml = pytest.importorskip("yaml")
    path = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), ".github", "workflows", "windows.yml")
    if not os.path.exists(path):
        pytest.skip("not inside the repository")
    doc = yaml.safe_load(open(path, encoding="utf-8"))
    assert doc["jobs"]["build"]["runs-on"] == "windows-latest"
    steps = " ".join(str(s.get("run", "")) + str(s.get("uses", "")) for s in doc["jobs"]["build"]["steps"])
    for needle in ("pytest", "build.py", "smoke.py", "upload-artifact"):
        assert needle in steps
    assert "refs/tags/v" in doc["jobs"]["release"]["if"]
    assert doc["jobs"]["release"]["permissions"] == {"contents": "write"}


def test_version_matches_the_mac_app():
    root = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "VERSION")
    if os.path.exists(root):
        from tokenbar import __version__
        assert __version__ == open(root).read().strip()


def test_zip_holds_the_program_folder(tmp_path):
    import zipfile
    import build
    app = tmp_path / "TokenBar"
    app.mkdir()
    (app / "TokenBar.exe").write_bytes(b"x")
    out = build.make_zip(str(app), str(tmp_path / "z.zip"))
    assert zipfile.ZipFile(out).namelist() == ["TokenBar/TokenBar.exe"]
