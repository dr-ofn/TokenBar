"""The app's state and the work behind the window, with no Tk and no tray in it."""
from __future__ import annotations

import json
import os
import threading
import time

from ..catalog import Catalog
from ..i18n import set_language
from ..paths import Env
from ..prices.book import PriceBook
from ..report import PERIOD_ORDER, Report, build_report
from ..scanner import ScanResult, Scanner
from ..store import Store

DEFAULT_SETTINGS = {"period": "24h", "offline": False, "language": "auto", "scanSeconds": 30}


class Settings:
    """`%APPDATA%\\TokenBar\\settings.json`: the period last shown, the Offline switch and the language."""

    def __init__(self, path: str):
        self.path = path
        self.values = dict(DEFAULT_SETTINGS)
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict):
                if data.get("period") in PERIOD_ORDER:
                    self.values["period"] = data["period"]
                if isinstance(data.get("offline"), bool):
                    self.values["offline"] = data["offline"]
                if data.get("language") in ("auto", "tr", "en"):
                    self.values["language"] = data["language"]
        except (OSError, ValueError):
            pass

    def __getitem__(self, key):
        return self.values[key]

    def set(self, key, value) -> None:
        self.values[key] = value
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            tmp = self.path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self.values, f, indent=1)
            os.replace(tmp, self.path)
        except OSError:
            pass


class AppModel:
    def __init__(self, env: Env | None = None, store: Store | None = None, book: PriceBook | None = None):
        self.env = env or Env.from_os()
        self.settings = Settings(self.env.settings_path())
        set_language(self.settings["language"] if self.settings["language"] != "auto" else None)
        self.store = store or Store(self.env.db_path())
        self.book = book or PriceBook(self.env, offline=self.settings["offline"])
        self.scanner = Scanner(self.store, self.env)
        self.last_scan: ScanResult | None = None
        self.last_scan_time = 0.0
        self.scanning = False
        self._scan_lock = threading.Lock()

    @property
    def period(self) -> str:
        return self.settings["period"]

    def set_period(self, period: str) -> None:
        if period in PERIOD_ORDER:
            self.settings.set("period", period)

    @property
    def offline(self) -> bool:
        return self.book.is_offline

    def set_offline(self, value: bool) -> None:
        self.settings.set("offline", bool(value))
        self.book.set_offline(value)

    def set_language(self, code: str) -> None:
        """Saved for the next start (the window says so): switching the running texts at once would leave the
        fixed titles in one language and the live ones in the other."""
        self.settings.set("language", code)

    def rescan(self) -> ScanResult | None:
        """One scan pass (one at a time; a second call while one runs returns None)."""
        if not self._scan_lock.acquire(blocking=False):
            return None
        self.scanning = True
        try:
            result = self.scanner.scan()
            self.last_scan, self.last_scan_time = result, time.time()
            return result
        finally:
            self.scanning = False
            self._scan_lock.release()

    def report(self, period: str | None = None) -> Report:
        return build_report(self.store, self.book, period or self.period)

    def update_prices(self, force: bool = False):
        """Fetches the price lists (a day's cache is respected unless `force`, the menu's "Update prices"); returns the
        feed's report or None when offline."""
        return self.book.refresh(force)

    def detected(self) -> tuple[list[str], list[str]]:
        """(countable tools found, found but not countable), from the last scan or the folders now."""
        cat = Catalog(self.env)
        if self.last_scan is not None:
            return self.last_scan.detected, self.last_scan.not_countable
        return cat.detected(), cat.not_countable()

    def close(self) -> None:
        self.store.close()
