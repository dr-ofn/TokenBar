"""Colours and fonts. Follows the Windows light/dark setting."""
from __future__ import annotations

import colorsys
import sys

LIGHT = {"bg": "#f6f6f4", "card": "#ffffff", "fg": "#1d1d1f", "dim": "#6b6b70", "line": "#dcdcd8", "accent": "#d9531e",
         "sel": "#ffe8dc", "btn": "#ececE8", "btn_on": "#1d1d1f", "btn_on_fg": "#ffffff", "warn": "#b4590a"}
DARK = {"bg": "#1c1c1e", "card": "#262628", "fg": "#f2f2f4", "dim": "#9a9aa0", "line": "#3a3a3d", "accent": "#ff7a45",
        "sel": "#4a2d20", "btn": "#303033", "btn_on": "#f2f2f4", "btn_on_fg": "#1c1c1e", "warn": "#f0a050"}
FONT = "Segoe UI"


def windows_dark() -> bool:
    """True when Windows apps are set to the dark theme."""
    if sys.platform != "win32":
        return False
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize") as key:
            return winreg.QueryValueEx(key, "AppsUseLightTheme")[0] == 0
    except OSError:
        return False


def palette() -> dict:
    return DARK if windows_dark() else LIGHT


def hue_color(hue: float, dark: bool) -> str:
    """The colour of a tool: its hue in degrees, kept readable on the background."""
    r, g, b = colorsys.hsv_to_rgb((hue % 360) / 360, 0.55 if dark else 0.75, 0.95 if dark else 0.62)
    return "#%02x%02x%02x" % (int(r * 255), int(g * 255), int(b * 255))
