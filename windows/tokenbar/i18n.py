"""Turkish and English. The language comes from the Windows display language; `TOKENBAR_LANG=tr|en` overrides it."""
from __future__ import annotations

import os
import sys

_override: str | None = None


def set_language(code: str | None) -> None:
    global _override
    _override = code if code in ("tr", "en") else None


def _windows_ui_language() -> str | None:
    if sys.platform != "win32":
        return None
    try:
        import ctypes
        langid = ctypes.windll.kernel32.GetUserDefaultUILanguage()
    except Exception:
        return None
    return "tr" if (langid & 0x3FF) == 0x1F else "en"


def lang() -> str:
    env = os.environ.get("TOKENBAR_LANG", "").strip().lower()
    if env in ("tr", "en"):
        return env
    if _override:
        return _override
    win = _windows_ui_language()
    if win:
        return win
    for var in ("LC_ALL", "LC_MESSAGES", "LANG"):
        v = os.environ.get(var, "").lower()
        if v:
            return "tr" if v.startswith("tr") else "en"
    return "en"


def t(tr: str, en: str) -> str:
    return tr if lang() == "tr" else en
