"""Start with Windows: one value in HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run, written for the current user only
(no administrator rights, no service, no scheduled task). Turning it off removes the value."""
from __future__ import annotations

import sys

RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
VALUE = "TokenBar"


def command() -> str:
    """What Windows runs at sign-in: the packaged exe, or this Python module when running from source."""
    if getattr(sys, "frozen", False):
        return f'"{sys.executable}"'
    exe = sys.executable
    if exe.lower().endswith("python.exe"):
        exe = exe[:-len("python.exe")] + "pythonw.exe"
    return f'"{exe}" -m tokenbar'


def available() -> bool:
    return sys.platform == "win32"


def is_enabled(winreg=None) -> bool:
    winreg = winreg or _winreg()
    if winreg is None:
        return False
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
            value, _ = winreg.QueryValueEx(key, VALUE)
        return bool(value)
    except OSError:
        return False


def set_enabled(enabled: bool, winreg=None) -> bool:
    winreg = winreg or _winreg()
    if winreg is None:
        return False
    try:
        if enabled:
            # The Run key is missing on a fresh profile: CreateKeyEx makes it, OpenKey would fail.
            with winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as key:
                winreg.SetValueEx(key, VALUE, 0, winreg.REG_SZ, command())
        else:
            try:
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as key:
                    winreg.DeleteValue(key, VALUE)
            except FileNotFoundError:        # no key, or no value: it is already off
                pass
        return True
    except OSError:
        return False


def _winreg():
    if sys.platform != "win32":
        return None
    import winreg
    return winreg
