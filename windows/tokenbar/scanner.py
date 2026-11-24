"""Finds and reads every tool's log under one home into the index, incrementally.

A file is read again only when its size or modification time changed; an append-only log resumes at the byte it
stopped at, a database at the last row id it saw. A file that cannot be read is named as an issue and read again on
the next pass: nothing is ever silently dropped. Nothing is written into a tool's folder.
"""
from __future__ import annotations

import json
import os
import time
import traceback
from dataclasses import dataclass, field

from . import readers as _readers  # noqa: F401  (registers the families)
from .catalog import Catalog
from .paths import Env
from .readers import core, g1, g2, g3  # noqa: F401
from .readers.base import REGISTRY, Sink
from .store import FileRecord, Store
from .util import SETTLE_SECONDS, BadFile, Retry, longpath, safe_text

BADFILE = "badfile:"     # meta key prefix: a recorded file that was named bad (too large to unpack) stays named after a restart
BATCH_FILES = 200
BATCH_EVENTS = 20000


@dataclass
class SourceStat:
    name: str
    files_read: int = 0
    events: int = 0


@dataclass
class ScanResult:
    issues: list = field(default_factory=list)
    sources: list = field(default_factory=list)
    bytes_read: int = 0
    detected: list = field(default_factory=list)
    not_countable: list = field(default_factory=list)


class Context:
    def __init__(self, env: Env, catalog: Catalog):
        self.env = env
        self.catalog = catalog

    def roots(self, d) -> list[str]:
        return self.catalog.roots_of(d)


def _file_info(path: str):
    try:
        st = os.stat(longpath(path))
    except OSError:
        return None
    return st


class Scanner:
    def __init__(self, store: Store, env: Env, catalog: Catalog | None = None):
        self.store = store
        self.env = env
        self.catalog = catalog or Catalog(env)
        self.ctx = Context(env, self.catalog)
        self._bad: dict[str, tuple] = {}     # path -> (inode, size, mtime, message): a file named bad stays named until it changes
        self._saved: dict[str, tuple] | None = None     # the same, as an earlier run left it in the index (see `_saved_bad`)

    def _saved_bad(self) -> dict:
        """path -> (inode, size, mtime, message) of the files an earlier run named bad (the index keeps them)."""
        if self._saved is None:
            self._saved = {}
            try:
                for k, v in self.store.meta_prefix(BADFILE):
                    try:
                        inode, size, mtime, message = json.loads(v)
                        self._saved[k[len(BADFILE):]] = (inode, size, mtime, message)
                    except (ValueError, TypeError):
                        continue
            except Exception:
                pass
        return self._saved

    def _forget_bad(self, path: str) -> None:
        self._saved_bad().pop(safe_text(path), None)
        try:
            self.store.del_meta(BADFILE + path)
        except Exception:
            pass

    def _forget_vanished_bad(self) -> None:
        """A bad-file verdict of a file that is gone is dropped: nothing will ever change it, and the index would keep it
        for good. Only a file that is surely absent counts (not one the program may merely not look at)."""
        try:
            rows = self.store.meta_prefix(BADFILE)
        except Exception:
            return
        for k, _ in rows:
            path = k[len(BADFILE):]
            try:
                os.stat(longpath(path))
                continue
            except (FileNotFoundError, NotADirectoryError):
                pass
            except OSError:
                continue
            self._bad.pop(path, None)
            self._forget_bad(path)

    def scan(self) -> ScanResult:
        result = ScanResult()
        for d in self.catalog.descriptors:
            if not d.countable:
                continue
            fam = REGISTRY.get(d.family)
            if fam is None:
                continue
            try:
                self._scan_descriptor(d, fam, result)
            except Exception as e:     # one tool's trouble never stops the others
                result.issues.append((d.name, f"{type(e).__name__}: {e}"))
        self._forget_vanished_bad()
        result.detected = self.catalog.detected()
        result.not_countable = self.catalog.not_countable()
        try:
            self.store.set_meta("lastScan", str(time.time()))
        except Exception:
            pass
        # One line per distinct problem.
        seen, unique = set(), []
        for item in result.issues:
            if item not in seen:
                seen.add(item)
                unique.append(item)
        result.issues = unique
        return result

    def _scan_descriptor(self, d, fam, result: ScanResult) -> None:
        stat = SourceStat(d.name if d.prefix not in ("qwenc", "kilo", "kilocode") else f"{d.name} ({d.prefix})")
        problems = []
        records = self.store.file_records()
        stamps = self.store.db_stamps() if fam.stamp else {}
        pending, pending_events = [], 0
        named = []                  # (meta key, value) of bad-file verdicts that have no record to be written with
        now = time.time()

        def flush():
            nonlocal pending, pending_events
            if pending:
                try:
                    self.store.apply(pending)
                except Exception as e:
                    # One file the index refuses must not take the others of its batch with it: each is written on its own.
                    if len(pending) == 1:
                        problems.append(f"{pending[0][0].path if pending[0][0] else ''}: index write failed: {e}")
                    else:
                        for item in pending:
                            try:
                                self.store.apply([item])
                            except Exception as e2:
                                problems.append(f"{item[0].path if item[0] else ''}: index write failed: {e2}")
            pending, pending_events = [], 0

        try:
            paths = list(dict.fromkeys(fam.files(self.ctx, d)))
        except Exception as e:
            problems.append(f"{type(e).__name__}: {e}")
            paths = []
        for path in paths:
            st = _file_info(path)
            if st is None or not os.path.isfile(longpath(path)):
                continue
            size, mtime = st.st_size, st.st_mtime
            stamp = None
            if fam.stamp:
                stamp, size, mtime = fam.stamp(path)
            inode = st.st_ino
            old = records.get(safe_text(path))
            same = old is not None and old.inode == inode
            verdict = self._bad.get(path)
            if verdict is None and same:
                verdict = self._saved_bad().get(safe_text(path))     # named by an earlier run, on a file recorded since
            if verdict is not None:
                if verdict[:3] == (inode, size, stamp or mtime):
                    problems.append(verdict[3])      # named again, without reading the file again
                    continue
                self._bad.pop(path, None)
                self._forget_bad(path)
            if stamp is not None:
                # A database: the stamp of the .db and of its -wal, each on its own, compared for equality. An index
                # that kept none (made by 9.0.0) reads each database once, which is safe: its rows have their keys.
                if old is not None and stamps.get(safe_text(path)) == stamp:
                    continue
            elif same and old.mtime >= mtime and old.size == size and (fam.mode != "lines" or old.offset >= size):
                continue
            if fam.mode == "lines":
                offset = old.offset if same and size > old.offset else 0
            elif fam.mode == "rowid":
                # Whatever happened to the file's size (a WAL checkpoint shrinks it), the watermark stays: it is a row id.
                offset = old.offset if same else 0
            else:
                offset = 0
            sink = Sink()
            try:
                end = fam.read(self.ctx, d, path, offset, size, abs(now - mtime) > SETTLE_SECONDS, sink)
            except BadFile as e:       # quiet and still unreadable: named on every pass, never recorded (the Mac app's way)
                self._bad[path] = (inode, size, stamp or mtime, str(e))
                problems.append(str(e))
                continue
            except Retry:              # not finished (or gone) a moment ago: unrecorded, read again next pass, no complaint
                continue
            except Exception as e:     # includes OSError: a file another program holds is named and read again next pass
                problems.append(f"{path}: {type(e).__name__}: {e}")
                if os.environ.get("TOKENBAR_DEBUG"):
                    traceback.print_exc()
                continue
            problems += sink.issues
            metas = []
            if sink.bad:               # what was read counts; the file is named on every pass and not unpacked again
                self._bad[path] = (inode, size, stamp or mtime, sink.bad)
                problems.append(sink.bad)
                metas = [(BADFILE + path, json.dumps(list(self._bad[path])))]    # written with the record, in one transaction
            if end is None:            # could not be read right now: left unrecorded, tried again next pass
                named += metas         # (no record to go with: written on their own)
                continue
            # A file that is only too large is recorded like any other (the Mac app's way): without a record every
            # restart, and every command-line call, would unpack it again, up to the output limit.
            record = None if sink.retry else FileRecord(path, inode, size, mtime, int(end), stamp)
            pending.append((record, sink.events, (sink.retire_keys, sink.retire_prefixes), sink.costs, metas))
            stat.files_read += 1
            stat.events += len(sink.events)
            result.bytes_read += max(0, int(end) - offset) if fam.mode == "lines" else size
            pending_events += len(sink.events)
            if len(pending) >= BATCH_FILES or pending_events >= BATCH_EVENTS:
                flush()
        flush()
        for key, value in named:
            try:
                self.store.set_meta(key, value)
            except Exception:
                pass
        if fam.after:
            try:
                fam.after(self.ctx, d, self.store, stat.files_read)
            except Exception as e:
                problems.append(f"{type(e).__name__}: {e}")
        result.issues += [(stat.name, p) for p in problems]
        result.sources.append(stat)
