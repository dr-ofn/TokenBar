"""`TokenBar.exe --selftest-gui`: the real tray path (scanner thread, pump loop, window and icon calls) with a fake Tk and a
fake pystray, so it runs headless on any machine."""
import os
import sys
import time
import types

import pytest

from fixture_home import expected, make_fixture_home
from tokenbar import cli
from tokenbar.gui import app


class FakeRoot:
    """Just enough of tk.Tk: `after` queues, `mainloop` runs the queue in time order until `destroy`."""

    def __init__(self):
        self.queue = []
        self.destroyed = False
        self.window_state = "withdrawn"
        self.report_callback_exception = None

    def withdraw(self):
        self.window_state = "withdrawn"

    def iconphoto(self, *a):
        pass

    def after(self, ms, fn):
        self.queue.append((time.monotonic() + ms / 1000.0, fn))

    def state(self):
        return self.window_state

    def destroy(self):
        self.destroyed = True

    def mainloop(self):
        while not self.destroyed:
            if not self.queue:
                time.sleep(0.01)
                continue
            self.queue.sort(key=lambda item: item[0])
            due, fn = self.queue.pop(0)
            time.sleep(max(0.0, due - time.monotonic()))
            try:
                fn()
            except Exception as e:                      # Tk reports a callback's error and goes on
                if self.report_callback_exception:
                    self.report_callback_exception(type(e), e, None)


class FakeWindow:
    def __init__(self, root, model, on_quit, on_hide=None):
        self.root, self.model = root, model
        self.on_offline_changed = None
        self.shown = 0
        self.visible = False

    def show(self):
        self.shown += 1
        self.visible = True
        self.root.window_state = "normal"

    def hide(self):
        self.visible = False
        self.root.window_state = "withdrawn"

    def toggle(self):
        self.hide() if self.visible else self.show()

    def refresh(self):
        pass

    def update_prices(self):
        pass

    def background_scan_done(self):
        pass


class FakeIcon:
    last = None

    def __init__(self, name, image, title, menu=None):
        self.visible = False
        self.title = title
        self.stopped = False
        self.menu = menu
        FakeIcon.last = self

    def run_detached(self):
        self.visible = True

    def stop(self):
        self.stopped = True
        self.visible = False

    def update_menu(self):
        pass


@pytest.fixture
def fakes(monkeypatch):
    pystray = types.SimpleNamespace(Icon=FakeIcon, Menu=lambda *items: items, MenuItem=lambda *a, **k: (a, k))
    monkeypatch.setitem(sys.modules, "pystray", pystray)
    monkeypatch.setattr(app, "tk", types.SimpleNamespace(Tk=FakeRoot, PhotoImage=lambda **k: object()))
    monkeypatch.setattr(app, "MainWindow", FakeWindow)
    monkeypatch.setattr(app, "make_icon", lambda size: None)
    monkeypatch.setattr(app, "SCAN_SECONDS", 1)
    FakeIcon.last = None


def run(tmp_path, extra=(), timeout=None):
    home = make_fixture_home(os.path.abspath(str(tmp_path / "home")))
    out = os.path.abspath(str(tmp_path / "out.txt"))
    db = os.path.abspath(str(tmp_path / "usage.sqlite"))
    argv = ["--selftest-gui", "--home", home, "--db", db, "--selftest-out", out, *extra]
    code = app.selftest_gui(argv, **({"timeout": timeout} if timeout else {}))
    text = open(out, encoding="utf-8").read() if os.path.exists(out) else ""
    return code, text, home


def test_the_tray_path_runs_scans_shows_hides_and_quits_and_writes_its_result(tmp_path, fakes):
    code, text, _ = run(tmp_path)
    want = expected()
    assert code == 0 and "GUI SELFTEST OK" in text, text
    assert f"tokens={want['total']} calls={want['calls']}" in text
    assert FakeIcon.last.stopped                                  # the menu's Quit stopped the icon through the loop


def test_main_routes_the_flag_to_the_self_test_before_the_command_line_mode(tmp_path, fakes):
    home = make_fixture_home(os.path.abspath(str(tmp_path / "home")))
    out = os.path.abspath(str(tmp_path / "out.txt"))
    code = cli.main(["--selftest-gui", "--home", home, "--db", os.path.abspath(str(tmp_path / "u.sqlite")), "--selftest-out", out])
    assert code == 0 and "GUI SELFTEST OK" in open(out, encoding="utf-8").read()


def test_the_self_test_refuses_to_run_without_a_home_and_an_index_of_its_own(tmp_path, fakes):
    out = os.path.abspath(str(tmp_path / "out.txt"))
    assert app.selftest_gui(["--selftest-gui", "--selftest-out", out]) == 2
    assert "GUI SELFTEST FAILED" in open(out, encoding="utf-8").read()
    assert FakeIcon.last is None                                  # nothing was started


def test_it_writes_nothing_outside_the_made_up_home_and_the_index(tmp_path, fakes, monkeypatch):
    real = tmp_path / "real"
    monkeypatch.setenv("USERPROFILE", str(real))
    monkeypatch.setenv("APPDATA", str(real / "AppData" / "Roaming"))
    monkeypatch.setenv("LOCALAPPDATA", str(real / "AppData" / "Local"))
    code, text, _ = run(tmp_path)
    assert code == 0, text
    assert not real.exists()


def test_a_tray_icon_that_never_appears_fails_with_the_reason(tmp_path, fakes, monkeypatch):
    monkeypatch.setattr(FakeIcon, "run_detached", lambda self: None)
    code, text, _ = run(tmp_path, timeout=2)
    assert code == 1 and "GUI SELFTEST FAILED" in text and "icon visible=False" in text, text


def test_a_window_that_does_not_open_fails(tmp_path, fakes, monkeypatch):
    monkeypatch.setattr(FakeWindow, "show", lambda self: None)
    code, text, _ = run(tmp_path, timeout=5)
    assert code == 1 and "the window did not open" in text, text


def test_an_exception_while_starting_is_written_and_the_exit_code_is_not_zero(tmp_path, fakes, monkeypatch):
    def boom(*a, **k):
        raise RuntimeError("no display")
    monkeypatch.setattr(app, "tk", types.SimpleNamespace(Tk=boom, PhotoImage=boom))
    code, text, _ = run(tmp_path)
    assert code == 1 and "RuntimeError: no display" in text


def test_the_second_instance_lock_is_taken_for_real_on_the_self_test_name(tmp_path, fakes, monkeypatch):
    seen = []
    monkeypatch.setattr(app, "acquire_single_instance", lambda *a, **k: seen.append(k.get("name")) or None)
    code, text, _ = run(tmp_path)
    assert code == 1 and seen == [app.MUTEX_NAME + "-selftest"] and "lock" in text


def test_the_windows_workflow_runs_the_tray_mode_self_test_and_reads_its_verdict_file():
    here = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    with open(os.path.join(here, ".github", "workflows", "windows.yml"), encoding="utf-8") as f:
        text = f.read()
    step = text[text.index("Smoke test, TokenBar.exe tray mode"):text.index("- name: Zip contents")]
    for needle in ("--selftest-gui", "--selftest-out", "GUI SELFTEST OK", "ExitCode", "--home", "--db", "WaitForExit"):
        assert needle in step, needle
    assert text.index("Smoke test, TokenBar.exe tray mode") > text.index("TokenBar.exe in command-line mode")


def test_the_selftest_lets_go_of_its_lock_so_a_second_run_in_the_same_process_starts(tmp_path, fakes, monkeypatch):
    # On Windows the named mutex lives as long as its handle: a self-test that kept it made the next one fail
    # ("the single-instance lock is already held") when the tests ran on a real Windows runner.
    taken = []

    def acquire(*a, **k):
        if taken:
            return None
        taken.append(1234)
        return 1234

    monkeypatch.setattr(app, "acquire_single_instance", acquire)
    monkeypatch.setattr(app, "release_single_instance", lambda h, **k: taken.remove(h) if h in taken else None)
    for n in range(2):
        sub = tmp_path / str(n)
        sub.mkdir()
        code, text, _ = run(sub)
        assert code == 0 and "GUI SELFTEST OK" in text, text
    assert taken == []


def test_release_single_instance_closes_only_real_handles():
    calls = []
    k32 = type("K", (), {"CloseHandle": staticmethod(lambda h: calls.append(h))})()
    app.release_single_instance(None, kernel32=k32)
    app.release_single_instance(object(), kernel32=k32)
    app.release_single_instance(77, kernel32=k32)
    assert calls == [77]
