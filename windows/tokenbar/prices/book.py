"""The price book: the catalogues, the hand-corrected table and the user's aliases, resolved once and reloaded when
something changes. `TOKENBAR_PRICES_PINNED=1` (what the tests use) means the embedded snapshot and the tables only:
no cache file, no alias file, no network, the same prices on every machine."""
from __future__ import annotations

import json
import os
import threading

from ..paths import Env
from ..util import load_optional_json
from .engine import Pricer, call_cost, parse_aliases
from .feed import PriceFeed, environment_offline, url_fetcher

DATA = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data")


def load_tables(path: str | None = None) -> list:
    """The hand-corrected price rows shipped with the app (pinned at their date)."""
    try:
        with open(path or os.path.join(DATA, "price-tables.json"), encoding="utf-8") as f:
            return json.load(f)["entries"]
    except (OSError, ValueError, KeyError):
        return []


class PriceBook:
    def __init__(self, env: Env | None = None, pinned: bool | None = None, offline: bool | None = None, feed: PriceFeed | None = None,
                 aliases_env: Env | None = None):
        self.env = env or Env.from_os()
        self.aliases_env = aliases_env or self.env     # whose model-aliases.json is read (`--home`: the inspected home's)
        e = self.env.environ if self.env.real else os.environ
        self.pinned = (e.get("TOKENBAR_PRICES_PINNED") == "1") if pinned is None else pinned
        self._offline_setting = False if offline is None else offline
        self.feed = feed or PriceFeed(self.env.cache_dir(), offline=self.is_offline, should_stop=lambda: self.is_offline,
                                      fetcher=url_fetcher)
        self._lock = threading.RLock()
        self._pricer: Pricer | None = None
        self._cache: dict = {}
        self.origins: dict = {}
        self.revision = 0
        self.alias_issue: str | None = None      # why model-aliases.json was not used, when it is there and cannot be read
        self.date = ""
        self._refresh_started = False

    # ---- offline switch (the window's menu and TOKENBAR_OFFLINE)
    @property
    def is_offline(self) -> bool:
        return self._offline_setting or environment_offline(self.env.environ if self.env.real else None)

    def set_offline(self, value: bool) -> None:
        self._offline_setting = bool(value)
        self.feed.offline = self.is_offline

    # ---- lookup
    def reload(self) -> None:
        with self._lock:
            cats, origins = self.feed.load_local(use_cache=not self.pinned)
            self.alias_issue = None
            if self.pinned:
                aliases, local = {}, []
            else:
                data, problem = load_optional_json(self.aliases_env.aliases_path())
                if problem is None and data is not None and not isinstance(data, dict):
                    problem = f"{self.aliases_env.aliases_path()}: not a JSON object"
                self.alias_issue = problem      # said (scan issues), not skipped: the prices it would have set are then the catalogue's
                aliases, local = parse_aliases(data)
            self._pricer = Pricer(cats, load_tables(), aliases, local)
            self._cache = {}
            self.origins = origins
            days = [v.split(" ", 1)[1] for v in origins.values() if " " in v and v.split(" ", 1)[1]]
            self.date = max(days) if days else ""
            self.revision += 1

    def alias_problem(self) -> str | None:
        """Why the user's model-aliases.json is not in use (it is there and cannot be read), or None."""
        with self._lock:
            if self._pricer is None:
                self.reload()
            return self.alias_issue

    def resolve(self, provider: str, model: str):
        with self._lock:
            if self._pricer is None:
                self.reload()
            key = (provider, model)
            if key not in self._cache:
                self._cache[key] = self._pricer.resolve(provider, model)
            return self._cache[key]

    def cost(self, provider, model, inp, cr, cw, out, cw1h=0, tiered=True):
        """(USD, priced?) of one call or one summed row."""
        entry = self.resolve(provider, model)
        if entry is None:
            return 0.0, False
        return call_cost(entry, inp, cr, cw, out, cw1h, tiered), True

    # ---- refreshing
    def refresh(self, force: bool = False):
        """Asks the network (at most once a day per source, unless `force`); reloads when something changed."""
        if self.pinned or self.is_offline:
            return None
        self.feed.offline = self.is_offline
        report = self.feed.refresh(force)
        if report.changed:
            self.reload()
        return report
