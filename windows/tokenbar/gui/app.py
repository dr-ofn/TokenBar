"""The tray app: an icon with the total in its tooltip, a click opens the window."""
from __future__ import annotations

import ctypes
import math
import os
import queue
import sys
import threading
import tkinter as tk

from .. import __version__
from ..fmt import money, period_short, tokens
from ..i18n import t
from . import startup
from .icon import make_icon, make_ico_bytes
from .model import AppModel
from .window import MainWindow

SCAN_SECONDS = 30
PRICE_CHECK_SECONDS = 6 * 3600
PRICE_RETRY_SECONDS = 3600      # after a failed fetch: an hour, doubling with every failure in a row, never past the six hours


ERROR_ACCESS_DENIED = 5
ERROR_ALREADY_EXISTS = 183
MUTEX_NAME = "Local\\TokenBar-single-instance"


def acquire_single_instance(kernel32=None, get_last_error=None, name: str = MUTEX_NAME):
    """A named mutex: a second TokenBar quietly exits. Returns a handle to keep alive, or None when another runs.

    The error code is read with `ctypes.get_last_error()` from a `WinDLL(use_last_error=True)`: Python itself makes
    Win32 calls between `CreateMutexW` and a plain `GetLastError()`, which can overwrite the code."""
    if kernel32 is None:
        if sys.platform != "win32":
            return object()
        from ctypes import wintypes
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateMutexW.restype = wintypes.HANDLE
        kernel32.CreateMutexW.argtypes = [wintypes.LPVOID, wintypes.BOOL, wintypes.LPCWSTR]
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        get_last_error = ctypes.get_last_error
    handle = kernel32.CreateMutexW(None, False, name)
    error = get_last_error()
    if error == ERROR_ALREADY_EXISTS or (not handle and error == ERROR_ACCESS_DENIED):   # another TokenBar holds it
        if handle:
            kernel32.CloseHandle(handle)
        return None
    # Any other failure (no handle for another reason) must not stop the only copy from starting.
    return handle or object()


def release_single_instance(handle, kernel32=None) -> None:
    """Close a handle from `acquire_single_instance` (the self-test does; the app keeps its own until it exits)."""
    if handle is None or not isinstance(handle, int):
        return
    if kernel32 is None:
        if sys.platform != "win32":
            return
        from ctypes import wintypes
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle(handle)


def tooltip(model: AppModel, report) -> str:
    if report is None:
        return "TokenBar"
    return f"TokenBar · {money(report.cost)} · {tokens(report.tokens)} · {period_short(report.period)}"[:127]


def _tray(call) -> None:
    """A tray call. pystray's window may not exist yet (the icon was just started) or may be gone (Explorer restarted):
    that costs one update, never the loop."""
    try:
        call()
    except Exception:
        pass


def tray_refresher(icon):
    """What the window's Offline switch calls to tick the tray menu: a tray that is not ready costs the tick, not the window."""
    def refresh() -> None:
        _tray(icon.update_menu)
    return refresh


def drain(requests, window, model, icon) -> bool:
    """Does what the other threads asked for. Called from the Tk main loop only: the window (tkinter) and the tray
    icon are touched here and nowhere else. Returns True when the app should quit. One request that fails is lost,
    the ones behind it are still served."""
    while True:
        try:
            what = requests.get_nowait()
        except queue.Empty:
            return False
        kind, arg = what if isinstance(what, tuple) else (what, None)
        if kind == "quit":
            return True
        try:
            if kind == "show":
                window.toggle()
            elif kind == "prices":
                window.update_prices()
            elif kind == "offline":
                model.set_offline(not model.offline)
                _tray(icon.update_menu)
                window.refresh()
                if not model.offline:
                    window.prices_when_online()
            elif kind == "tooltip":
                _tray(lambda: setattr(icon, "title", arg))
            elif kind == "scanned":
                window.background_scan_done()
        except Exception:
            pass


PUMP_TURNS = 0          # turns of the main loop so far (the self-test waits for a few)


def pump(requests, window, model, icon, root, delay: int = 150) -> None:
    """One turn of the main loop: serve the requests, then plan the next turn. Whatever a turn does, the next one is
    planned (a loop that stops takes the tray menu and every scan notice with it)."""
    global PUMP_TURNS
    PUMP_TURNS += 1
    try:
        quit_now = drain(requests, window, model, icon)
    except Exception:
        quit_now = False
    if quit_now:
        _tray(icon.stop)
        try:
            root.destroy()
        except Exception:
            pass
        return
    root.after(delay, lambda: pump(requests, window, model, icon, root, delay))


def background_pass(model, requests, state, now=None) -> None:
    """One round of the scanning thread: scan, then hand the tooltip and the news to the main loop (never touch the
    window or the tray from here), and ask for new price lists once in a while."""
    import time
    now = now or time.time
    model.rescan()
    requests.put(("tooltip", tooltip(model, model.report())))
    requests.put("scanned")
    if now() - state.get("last_prices", 0.0) > PRICE_CHECK_SECONDS and not model.offline:
        asked = now()
        try:
            report = model.update_prices()
            failed = bool(getattr(report, "failed", None))
        except Exception:
            report, failed = None, True
        if failed:
            # asked again after an hour (twice as long after each failure in a row), not after the six hours of a success
            state["price_failures"] = state.get("price_failures", 0) + 1
            wait = min(PRICE_CHECK_SECONDS, PRICE_RETRY_SECONDS << (state["price_failures"] - 1))
        elif getattr(report, "retry_in", None) is not None:
            # a failure the feed remembers on disk (an earlier run of the app): asked again when its hour is over, not in six
            wait = min(PRICE_CHECK_SECONDS, math.ceil(report.retry_in))
        else:
            state["price_failures"] = 0
            wait = PRICE_CHECK_SECONDS
        state["last_prices"] = asked - PRICE_CHECK_SECONDS + wait
        if getattr(report, "changed", False):
            # new prices change what the tooltip says and what an open window shows: tell the main loop now
            try:
                requests.put(("tooltip", tooltip(model, model.report())))
                requests.put("scanned")
            except Exception:
                pass


def run_gui(argv) -> int:
    if "--selftest-gui" in argv:
        return selftest_gui(argv)
    if acquire_single_instance() is None:
        return 0
    return _run(argv, AppModel(), None)


def _run(argv, model: AppModel, probe) -> int:
    """The tray app. `probe` (the self-test) is told once everything stands, before the loop starts."""
    import pystray

    if sys.platform == "win32":
        try:        # sharp text on high-DPI screens
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except Exception:
            pass
    root = tk.Tk()
    root.withdraw()
    try:
        photo = tk.PhotoImage(data=_png_base64())
        root.iconphoto(True, photo)
    except Exception:
        pass
    requests: queue.Queue = queue.Queue()
    state = {"quit": False}

    def quit_app():
        state["quit"] = True
        requests.put("quit")

    window = MainWindow(root, model, on_quit=quit_app)
    icon = pystray.Icon("TokenBar", make_icon(64), "TokenBar", menu=pystray.Menu(
        pystray.MenuItem(t("Aç", "Open"), lambda *_: requests.put("show"), default=True),
        pystray.MenuItem(t("Fiyatları güncelle", "Update prices"), lambda *_: requests.put("prices")),
        pystray.MenuItem(t("Çevrimdışı", "Offline"), lambda *_: requests.put("offline"), checked=lambda _i: model.offline),
        pystray.MenuItem(t("Çık", "Quit"), lambda *_: requests.put("quit"))))

    window.on_offline_changed = tray_refresher(icon)          # the window's Offline switch ticks the tray menu too

    def handle():
        pump(requests, window, model, icon, root)

    def background():
        """Scans every SCAN_SECONDS and tells the main loop; it never touches the window or the tray itself."""
        import time
        prices: dict = {}
        while not state["quit"]:
            try:
                background_pass(model, requests, prices)
            except Exception:
                pass
            for _ in range(SCAN_SECONDS * 2):
                if state["quit"]:
                    return
                time.sleep(0.5)

    icon.run_detached()
    threading.Thread(target=background, daemon=True).start()
    root.after(150, handle)
    if "--show" in argv:
        window.show()
    if probe is not None:
        probe.attach(root, window, icon, model, requests, quit_app)
    try:
        root.mainloop()
    finally:
        state["quit"] = True
        model.close()
    return 0


# ------------------------------------------------------------------------------------------ the packaged app's self-test

SELFTEST_SECONDS = 30


class _SelfTest:
    """Runs the real tray path (a Tk root, the pystray icon, the scanning thread, the main loop) for a few turns,
    shows and hides the window the way a tray click does, then quits through the same request the menu's Quit makes.
    The outcome is a line in `out` (a windowed program has no stderr) and the exit code."""

    def __init__(self, timeout: float = SELFTEST_SECONDS):
        import time
        self.clock = time.monotonic
        self.deadline = self.clock() + timeout
        self.failure: str | None = None
        self.phase = "start"
        self.turns0 = PUMP_TURNS
        self.summary = ""

    def attach(self, root, window, icon, model, requests, quit_app) -> None:
        self.root, self.window, self.icon, self.model = root, window, icon, model
        self.requests, self.quit_app = requests, quit_app
        self.turns_at_phase = PUMP_TURNS
        root.report_callback_exception = lambda exc, val, tb: self.fail(f"Tk callback: {type(val).__name__}: {val}")
        root.after(200, self.step)

    def fail(self, why: str) -> None:
        if self.failure is None:
            self.failure = why
        try:
            self.quit_app()
        except Exception:
            pass

    def _later(self, ms: int = 100) -> None:
        self.root.after(ms, self.step)

    def _turns_since(self) -> int:
        return PUMP_TURNS - self.turns_at_phase

    def _next(self, phase: str) -> None:
        self.phase, self.turns_at_phase = phase, PUMP_TURNS

    def step(self) -> None:
        if self.failure is not None:
            return
        try:
            if self.clock() > self.deadline:
                self.fail(f"timeout in phase '{self.phase}' (scanned={self.model.last_scan is not None}, "
                          f"icon visible={getattr(self.icon, 'visible', None)}, turns={PUMP_TURNS - self.turns0})")
                return
            if self.phase == "start":
                if self.model.last_scan is not None and PUMP_TURNS - self.turns0 >= 3 and getattr(self.icon, "visible", False):
                    report = self.model.report("all")
                    self.summary = f"tokens={report.tokens} calls={report.calls} turns={PUMP_TURNS - self.turns0}"
                    self.window.show()
                    self._next("shown")
            elif self.phase == "shown":
                if self._turns_since() >= 2:
                    if self.root.state() != "normal":
                        self.fail(f"the window did not open (state {self.root.state()})")
                        return
                    self.requests.put("show")       # the tray icon's click: the window closes again
                    self._next("hidden")
            elif self.phase == "hidden":
                if self._turns_since() >= 2:
                    if self.root.state() != "withdrawn":
                        self.fail(f"the window did not close (state {self.root.state()})")
                        return
                    self.quit_app()                 # the menu's Quit
                    self._next("quit")
                    return
            elif self.phase == "quit":
                return
        except Exception as e:
            self.fail(f"{type(e).__name__}: {e}")
            return
        self._later()


def _write_result(path: str | None, text: str) -> None:
    for stream in (sys.stdout, sys.stderr):
        if stream is not None:
            try:
                print(text, file=stream)
                break
            except Exception:
                pass
    if path:
        try:
            with open(path, "w", encoding="utf-8") as f:
                f.write(text + "\n")
        except OSError:
            pass


def selftest_gui(argv, timeout: float = SELFTEST_SECONDS, hard_exit=None) -> int:
    """`TokenBar.exe --selftest-gui --home DIR --db FILE [--selftest-out FILE]`: starts the tray app for real on a made-up
    home folder with its own index, quits it the way the menu does and exits 0 only when every step worked.
    It never touches the user's own folders, the registry or the network."""
    import argparse
    import traceback

    p = argparse.ArgumentParser(add_help=False)
    p.add_argument("--selftest-gui", action="store_true")
    p.add_argument("--selftest-out")
    p.add_argument("--home")
    p.add_argument("--db")
    args, _ = p.parse_known_args(argv)
    out = args.selftest_out
    if not args.home or not args.db:
        _write_result(out, "GUI SELFTEST FAILED: --home and --db are required (the test never uses the real folders)")
        return 2
    watchdog = None
    handle = None

    def die():
        _write_result(out, "GUI SELFTEST FAILED: the program did not end by itself")
        (hard_exit or os._exit)(3)

    try:
        import threading as _t
        watchdog = _t.Timer(timeout + 15, die)
        watchdog.daemon = True
        watchdog.start()
        handle = acquire_single_instance(name=MUTEX_NAME + "-selftest")
        if handle is None:
            _write_result(out, "GUI SELFTEST FAILED: the single-instance lock is already held")
            return 1
        from ..paths import Env
        from ..prices.book import PriceBook
        from ..store import Store
        env = Env.for_home(args.home)
        model = AppModel(env=env, store=Store(args.db), book=PriceBook(env, offline=True))
        probe = _SelfTest(timeout)
        code = _run([a for a in argv if a != "--show"], model, probe)
        if probe.failure is not None:
            _write_result(out, f"GUI SELFTEST FAILED: {probe.failure}")
            return 1
        if probe.phase != "quit":
            _write_result(out, f"GUI SELFTEST FAILED: the loop ended in phase '{probe.phase}'")
            return 1
        _write_result(out, f"GUI SELFTEST OK {probe.summary}")
        return code
    except BaseException as e:
        _write_result(out, f"GUI SELFTEST FAILED: {type(e).__name__}: {e}\n{traceback.format_exc()}")
        return 1
    finally:
        if watchdog is not None:
            watchdog.cancel()
        release_single_instance(handle)


def _png_base64() -> str:
    import base64
    import io
    buf = io.BytesIO()
    make_icon(64).save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode("ascii")
