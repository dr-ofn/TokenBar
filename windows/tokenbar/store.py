"""The index: every model call TokenBar has seen, in one SQLite file (`%LOCALAPPDATA%\\TokenBar\\usage.sqlite`).

Rows survive the deletion of the tool's own log, so history keeps accumulating. A repeated key keeps its most
complete counts (a streamed line can carry a partial output count). A database written by another version is
refused, never rebuilt: the index holds calls whose logs may be gone.
"""
from __future__ import annotations

import os
import sqlite3
import threading
from dataclasses import dataclass

from .readers.base import Event
from .util import FIELD_LIMIT, clamp

SCHEMA_VERSION = 1


# A repeated key keeps its most complete counts. A task found in two places (the same id in two editors) is counted
# once. `event_files` says which files hold a key (a set: both copies hold it); the copy that is read again retires the
# keys it holds and writes what it holds now, and leaves the keys only the other copy holds. `events.file` is the
# last writer, kept for an index made before that table existed (and is how such a row is still found).
_MORE = "(excluded.input + excluded.cr + excluded.cw + excluded.output) > (events.input + events.cr + events.cw + events.output)"
_UPSERT_SQL = (
    "INSERT INTO events(key, provider, model, ts, input, cr, cw, output, reasoning, session, cw1h, file) "
    "VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(key) DO UPDATE SET "
    + ", ".join(f"{c}=CASE WHEN {_MORE} THEN excluded.{c} ELSE events.{c} END"
                for c in ("input", "cr", "cw", "output", "reasoning", "cw1h", "model", "provider"))
    + ", file=excluded.file")


_EVENT_FILES_SQL = "CREATE TABLE IF NOT EXISTS event_files(key TEXT NOT NULL, file TEXT NOT NULL, PRIMARY KEY(key, file)) WITHOUT ROWID"


class StoreError(Exception):
    pass


def inode_to_db(inode: int) -> int:
    """A file id as SQLite's signed 64-bit INTEGER holds it (the Mac app's `Int64(bitPattern:)`): an NTFS file id
    can use all 64 bits, and its top bits (the MFT sequence number) are set for an entry reused 32768 times."""
    inode &= (1 << 64) - 1
    return inode - (1 << 64) if inode >= 1 << 63 else inode


def inode_from_db(value: int) -> int:
    return value + (1 << 64) if value < 0 else value


@dataclass
class FileRecord:
    path: str
    inode: int
    size: int
    mtime: float
    offset: int


class Store:
    def __init__(self, path: str):
        self.path = path
        self._lock = threading.RLock()
        try:
            if path != ":memory:":
                os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
            self.db = sqlite3.connect(path, timeout=30, check_same_thread=False, isolation_level=None)
            self.db.execute("PRAGMA journal_mode=WAL")
            self.db.execute("PRAGMA synchronous=NORMAL")
            self._migrate()
        except (sqlite3.Error, OSError) as e:
            raise StoreError(f"{path}: {e}") from e

    def close(self) -> None:
        with self._lock:
            self.db.close()

    # ---------------------------------------------------------------------------------- schema

    def _migrate(self) -> None:
        version = self.db.execute("PRAGMA user_version").fetchone()[0]
        if version == SCHEMA_VERSION:
            if "file" not in {r[1] for r in self.db.execute("PRAGMA table_info(events)")}:
                self.db.execute("ALTER TABLE events ADD COLUMN file TEXT NOT NULL DEFAULT ''")
            self.db.execute(_EVENT_FILES_SQL)
            return
        has_events = self.db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='events'").fetchone()
        if version != 0 or has_events:
            raise StoreError(f"index schema {version}, expected {SCHEMA_VERSION}: left untouched ({self.path})")
        self.db.executescript(f"""
        CREATE TABLE IF NOT EXISTS events(
            key TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            ts REAL NOT NULL,
            input INTEGER NOT NULL,
            cr INTEGER NOT NULL,
            cw INTEGER NOT NULL,
            output INTEGER NOT NULL,
            reasoning INTEGER NOT NULL,
            session TEXT NOT NULL DEFAULT '',
            cw1h INTEGER NOT NULL DEFAULT 0,
            file TEXT NOT NULL DEFAULT ''
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS events_ts ON events(ts);
        {_EVENT_FILES_SQL};
        CREATE TABLE IF NOT EXISTS files(
            path TEXT PRIMARY KEY,
            inode INTEGER NOT NULL,
            size INTEGER NOT NULL,
            mtime REAL NOT NULL,
            offset INTEGER NOT NULL
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS costs(
            session TEXT NOT NULL, started REAL NOT NULL, model TEXT NOT NULL,
            input INTEGER NOT NULL, cr INTEGER NOT NULL, cw INTEGER NOT NULL, output INTEGER NOT NULL,
            PRIMARY KEY(session, started, model)
        ) WITHOUT ROWID;
        PRAGMA user_version = {SCHEMA_VERSION};
        """)

    # ---------------------------------------------------------------------------------- files and meta

    def file_records(self) -> dict[str, FileRecord]:
        with self._lock:
            rows = self.db.execute("SELECT path, inode, size, mtime, offset FROM files").fetchall()
        return {r[0]: FileRecord(r[0], inode_from_db(r[1]), *r[2:]) for r in rows}

    def meta(self, key: str) -> str | None:
        with self._lock:
            row = self.db.execute("SELECT v FROM meta WHERE k = ?", (key,)).fetchone()
        return row[0] if row else None

    def set_meta(self, key: str, value: str) -> None:
        with self._lock:
            self.db.execute("INSERT INTO meta(k, v) VALUES(?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v", (key, value))

    # ---------------------------------------------------------------------------------- writes

    _UPSERT = _UPSERT_SQL

    @staticmethod
    def _row(e: Event, file: str = ""):
        return (e.key, e.provider, e.model, e.ts, e.inp, e.cr, e.cw, e.out, e.rz, e.session, e.cw1h, file)

    def apply(self, updates) -> None:
        """updates: list of (FileRecord | None, [Event], retire keys, cost rows), written in one transaction."""
        with self._lock:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                for record, events, retire, costs in updates:
                    keys, prefixes = retire if isinstance(retire, tuple) else (retire, [])
                    for key in keys:
                        self.db.execute("DELETE FROM events WHERE key = ?", (key,))
                        self.db.execute("DELETE FROM event_files WHERE key = ?", (key,))
                    for prefix in prefixes:
                        self._retire_prefix(prefix, record.path if record else "")
                    self.db.executemany(self._UPSERT, [self._row(e, record.path if record else "") for e in events])
                    if record is not None and prefixes:
                        self.db.executemany("INSERT OR IGNORE INTO event_files(key, file) VALUES(?,?)",
                                            [(e.key, record.path) for e in events])
                    for prefix in prefixes:
                        # Only now: a key this file wrote back has its row again, so the other copies keep their claim on it.
                        self._forget_owners(prefix, self._upper(prefix))
                    for c in costs:
                        self.db.execute("""
                            INSERT INTO costs(session, started, model, input, cr, cw, output) VALUES(?,?,?,?,?,?,?)
                            ON CONFLICT(session, started, model) DO UPDATE SET input=max(input, excluded.input),
                              cr=max(cr, excluded.cr), cw=max(cw, excluded.cw), output=max(output, excluded.output)""", c)
                    if record is not None:
                        self.db.execute(
                            "INSERT OR REPLACE INTO files(path, inode, size, mtime, offset) VALUES(?,?,?,?,?)",
                            (record.path, inode_to_db(record.inode), record.size, record.mtime, record.offset))
                self.db.execute("COMMIT")
            except BaseException:
                self.db.execute("ROLLBACK")
                raise

    def _retire_prefix(self, prefix: str, file: str) -> None:
        """Deletes the rows under a key prefix that `file` holds: the ones it is named for, and the ones nobody is named
        for (an index made before owners were kept). What another copy of the task alone holds stays."""
        upper = self._upper(prefix)
        self.db.execute(
            "DELETE FROM events WHERE key >= ?1 AND key < ?2 AND (file = ?3 OR key IN "
            "(SELECT key FROM event_files WHERE file = ?3 AND key >= ?1 AND key < ?2) OR (file = '' AND NOT EXISTS "
            "(SELECT 1 FROM event_files o WHERE o.key = events.key)))", (prefix, upper, file))
        self.db.execute("DELETE FROM event_files WHERE file = ? AND key >= ? AND key < ?", (file, prefix, upper))

    @staticmethod
    def _upper(prefix: str) -> str:
        return prefix[:-1] + chr(ord(prefix[-1]) + 1)

    def _forget_owners(self, prefix: str, upper: str) -> None:
        self.db.execute("DELETE FROM event_files WHERE key >= ? AND key < ? AND NOT EXISTS "
                        "(SELECT 1 FROM events e WHERE e.key = event_files.key)", (prefix, upper))

    def replace_prefix(self, prefix: str, events: list[Event]) -> None:
        """Replaces every row under a key prefix: rows computed from others, which may shrink."""
        upper = prefix[:-1] + chr(ord(prefix[-1]) + 1)
        with self._lock:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                self.db.execute("DELETE FROM events WHERE key >= ? AND key < ?", (prefix, upper))
                self._forget_owners(prefix, upper)
                self.db.executemany(self._UPSERT, [self._row(e) for e in events])
                self.db.execute("COMMIT")
            except BaseException:
                self.db.execute("ROLLBACK")
                raise

    def reset(self) -> None:
        with self._lock:
            self.db.execute("BEGIN IMMEDIATE")
            for t in ("events", "event_files", "files", "meta", "costs"):
                self.db.execute(f"DELETE FROM {t}")
            self.db.execute("COMMIT")

    # ---------------------------------------------------------------------------------- reads

    def has_prefix(self, prefix: str) -> bool:
        upper = prefix[:-1] + chr(ord(prefix[-1]) + 1)
        with self._lock:
            return self.db.execute("SELECT 1 FROM events WHERE key >= ? AND key < ? LIMIT 1", (prefix, upper)).fetchone() is not None

    def cost_rows(self) -> list[tuple]:
        with self._lock:
            return self.db.execute("SELECT session, started, model, input, cr, cw, output FROM costs").fetchall()

    def sums(self, prefix: str, exclude: str | None = None, with_provider: bool = False) -> dict:
        """(session, model) -> (input, cacheRead, cacheWrite, output[, reasoning, provider]) over a key prefix."""
        upper = prefix[:-1] + chr(ord(prefix[-1]) + 1)
        out: dict = {}
        with self._lock:
            rows = self.db.execute(
                "SELECT session, model, provider, input, cr, cw, output, reasoning, key FROM events WHERE key >= ? AND key < ?",
                (prefix, upper)).fetchall()
        for session, model, provider, i, cr, cw, o, rz, key in rows:
            if exclude and key.startswith(exclude):
                continue
            s = out.get((session, model))
            if s is None:
                s = out[(session, model)] = [0, 0, 0, 0, 0, provider]
            for n, v in enumerate((i, cr, cw, o, rz)):
                s[n] = clamp(s[n] + v)
        return {k: (tuple(v) if with_provider else tuple(v[:4])) for k, v in out.items()}

    def events_since(self, cutoff: float | None):
        """Rows (key, provider, model, ts, input, cr, cw, output, reasoning, cw1h) of one window."""
        sql = "SELECT key, provider, model, ts, input, cr, cw, output, reasoning, cw1h FROM events"
        with self._lock:
            if cutoff is None:
                return self.db.execute(sql).fetchall()
            return self.db.execute(sql + " WHERE ts >= ?", (cutoff,)).fetchall()

    def event_count(self) -> int:
        with self._lock:
            return self.db.execute("SELECT count(*) FROM events").fetchone()[0]
