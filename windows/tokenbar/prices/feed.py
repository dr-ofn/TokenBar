"""The price catalogues on disk and, once a day at most, on the network.

Order of trust for each source: the cache file (any age), then the embedded snapshot (LiteLLM and models.dev only;
OpenRouter's catalogue licence is not verified, so it is never embedded). The network is asked only when the cache
is older than `ttl`, with `If-None-Match`; an answer that is not that catalogue's JSON never replaces the cache.
After a failed attempt the next one waits `retry_after_failure`. A plain GET: no cookies, no credentials, nothing
about the user. `TOKENBAR_OFFLINE=1` switches the network off for good.
"""
from __future__ import annotations

import json
import os
import tempfile
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field

from .engine import (CATALOGUE_NAMES, PARSERS, SOURCES, Catalogue, compact_rows)

SCHEMA = 1
URLS = {
    "openrouter": "https://openrouter.ai/api/v1/models",
    "litellm": "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json",
    "modelsdev": "https://models.dev/api.json",
}
MAX_RESPONSE_BYTES = 128 * 1024 * 1024
USER_AGENT = "TokenBar"


class FetchError(Exception):
    pass


def environment_offline(environ=None) -> bool:
    v = (environ if environ is not None else os.environ).get("TOKENBAR_OFFLINE", "").lower()
    return v in ("1", "true", "yes", "on")


def url_fetcher(source: str, etag: str | None):
    """One anonymous GET. Returns ("ok", bytes, etag) or ("notmodified",); raises FetchError."""
    req = urllib.request.Request(URLS[source], method="GET")
    req.add_header("Accept", "application/json")
    req.add_header("User-Agent", USER_AGENT)
    if etag:
        req.add_header("If-None-Match", etag)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read(MAX_RESPONSE_BYTES + 1)
            if len(body) > MAX_RESPONSE_BYTES:
                raise FetchError("response too large")
            return "ok", body, resp.headers.get("ETag")
    except urllib.error.HTTPError as e:
        if e.code == 304:
            return ("notmodified",)
        raise FetchError(f"HTTP {e.code}") from e
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise FetchError(str(e)) from e


def file_fetcher(directory: str):
    """Feeds the catalogues from openrouter.json, litellm.json and modelsdev.json in a folder: no network."""
    def fetch(source: str, etag: str | None):
        try:
            with open(os.path.join(directory, f"{source}.json"), "rb") as f:
                return "ok", f.read(), None
        except OSError as e:
            raise FetchError(f"{source}.json not found") from e
    return fetch


@dataclass
class RefreshReport:
    updated: list = field(default_factory=list)
    not_modified: list = field(default_factory=list)
    fresh: list = field(default_factory=list)
    failed: dict = field(default_factory=dict)
    skipped: list = field(default_factory=list)

    @property
    def changed(self) -> bool:
        return bool(self.updated or self.not_modified)


@dataclass
class CacheFile:
    etag: str | None
    fetched: float
    rows: dict


_gate = threading.Lock()


def _write_json(path: str, obj) -> None:
    """Atomic write; a NaN or Infinity anywhere means nothing is written (JSON cannot hold it)."""
    try:
        data = json.dumps(obj, sort_keys=True, allow_nan=False)
    except (ValueError, TypeError):
        return
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tb-", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(data)
            os.replace(tmp, path)
        except BaseException:
            try:
                os.remove(tmp)
            except OSError:
                pass
            raise
    except OSError:
        pass


class PriceFeed:
    def __init__(self, cache_dir: str, offline: bool = False, ttl: float = 24 * 3600, retry_after_failure: float = 3600,
                 fetcher=url_fetcher, now=time.time, should_stop=lambda: False, snapshot_path: str | None = None):
        self.cache_dir = cache_dir
        self.offline = offline
        self.ttl = ttl
        self.retry_after_failure = retry_after_failure
        self.fetcher = fetcher
        self.now = now
        self.should_stop = should_stop
        self.snapshot_path = snapshot_path or os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", "prices-snapshot.json")

    # ---- disk
    def _cache_path(self, source):
        return os.path.join(self.cache_dir, f"prices-{source}.json")

    def _state_path(self):
        return os.path.join(self.cache_dir, "prices-state.json")

    def read_cache(self, source) -> CacheFile | None:
        """A cache file that is not ours, not this schema or has no priced row is as good as none."""
        try:
            with open(self._cache_path(source), encoding="utf-8") as f:
                root = json.load(f)
        except (OSError, ValueError, RecursionError):
            return None
        if not isinstance(root, dict) or root.get("schema") != SCHEMA or root.get("source") != source:
            return None
        fetched = root.get("fetched")
        if isinstance(fetched, bool) or not isinstance(fetched, (int, float)):
            return None
        rows = compact_rows(root.get("rows"))
        if rows is None:
            return None
        etag = root.get("etag")
        return CacheFile(etag if isinstance(etag, str) else None, float(fetched), rows)

    def write_cache(self, source, rows, etag, fetched) -> None:
        kept = {rid: row for rid, row in Catalogue(source, rows).by_key.values()}
        root = {"schema": SCHEMA, "source": source, "url": URLS[source], "fetched": fetched, "rows": kept}
        if etag:
            root["etag"] = etag
        _write_json(self._cache_path(source), root)

    def _failures(self) -> dict:
        try:
            with open(self._state_path(), encoding="utf-8") as f:
                failed = json.load(f).get("failed")
        except (OSError, ValueError, AttributeError, RecursionError):
            return {}
        return {k: v for k, v in failed.items() if isinstance(k, str) and isinstance(v, (int, float))} if isinstance(failed, dict) else {}

    # ---- reading
    def snapshot(self) -> tuple[dict, str]:
        """({source: rows}, generated date) of the embedded snapshot."""
        try:
            with open(self.snapshot_path, encoding="utf-8") as f:
                root = json.load(f)
        except (OSError, ValueError):
            return {}, ""
        rows = {s: compact_rows(root.get(s)) for s in ("litellm", "modelsdev")}
        return {s: r for s, r in rows.items() if r}, str(root.get("generated") or "")

    def load_local(self, use_cache: bool = True) -> tuple[list, dict]:
        """(catalogues in lookup order, {source: "cache YYYY-MM-DD" | "snapshot YYYY-MM-DD"}). No network."""
        embedded, generated = self.snapshot()
        cats, origins = [], {}
        for source in SOURCES:
            cache = self.read_cache(source) if use_cache else None
            if cache:
                cats.append(Catalogue(source, cache.rows))
                origins[source] = "cache " + time.strftime("%Y-%m-%d", time.gmtime(cache.fetched))
            elif source in embedded:
                cats.append(Catalogue(source, embedded[source]))
                origins[source] = "snapshot " + generated
        return cats, origins

    # ---- refreshing
    def refresh(self, force: bool = False) -> RefreshReport:
        """One pass over the three sources: network only for those whose cache is older than `ttl`.
        `force` (the menu's "Update prices") asks every source now, whatever the one-day wait or an earlier failure says."""
        with _gate:
            return self._pass(force)

    def _pass(self, force: bool = False) -> RefreshReport:
        report = RefreshReport()
        if self.offline or self.should_stop():
            report.skipped = list(SOURCES)
            return report
        failed = self._failures()
        start_failed = dict(failed)
        for source in SOURCES:
            if self.offline or self.should_stop():
                report.skipped.append(source)
                continue
            now = self.now()
            cache = self.read_cache(source)
            # A copy stamped in the future (the clock was set back) is not fresh: its age would be negative.
            if not force and cache and 0 <= now - cache.fetched < self.ttl:
                report.fresh.append(source)
                continue
            last = failed.get(source)
            if not force and last is not None and 0 <= now - last < self.retry_after_failure:
                report.skipped.append(source)
                continue
            try:
                answer = self.fetcher(source, cache.etag if cache else None)
                if answer[0] == "notmodified":
                    if cache is None:
                        raise FetchError("HTTP 304 without a cache")
                    self.write_cache(source, cache.rows, cache.etag, now)
                    report.not_modified.append(source)
                else:
                    try:
                        rows = PARSERS[source](json.loads(answer[1]))
                    except (ValueError, RecursionError):
                        rows = None
                    if rows is None:
                        report.failed[source] = f"answer is not the {CATALOGUE_NAMES[source]} catalogue"
                        failed[source] = now
                        continue
                    self.write_cache(source, rows, answer[2], now)
                    report.updated.append(source)
                failed.pop(source, None)
            except FetchError as e:
                report.failed[source] = str(e)
                failed[source] = now
        if failed != start_failed:
            _write_json(self._state_path(), {"failed": failed})
        return report
