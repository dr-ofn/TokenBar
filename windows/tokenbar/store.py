"""The index: every model call TokenBar has seen, in one SQLite file (`%LOCALAPPDATA%\\TokenBar\\usage.sqlite`).

Rows survive the deletion of the tool's own log, so history keeps accumulating. A repeated key keeps its most
complete counts (a streamed line can carry a partial output count). A database written by another version is
refused, never rebuilt: the index holds calls whose logs may be gone.
"""
from __future__ import annotations

import os
import sqlite3
import threading
from dataclasses import dataclass, replace

from .readers.base import Event
from .util import FIELD_LIMIT, clamp, run_seconds, safe_text

SCHEMA_VERSION = 1
DBSTAMP = "dbstamp:"


# A repeated key keeps its most complete counts. A task found in two places (the same id in two editors) is counted
# once. `event_files` says which files hold a key (a set: both copies hold it); the copy that is read again retires the
# keys it holds and writes what it holds now, and leaves the keys only the other copy holds. `events.file` is the
# last writer, kept for an index made before that table existed (and is how such a row is still found).
_MORE = "(excluded.input + excluded.cr + excluded.cw + excluded.output) > (events.input + events.cr + events.cw + events.output)"
# A row written as `unknown` (the model was not named yet) takes the model a later read names, with the same counts or
# more (the Mac app's upsert); a known model is never replaced by `unknown`.
_MODEL = (f"model=CASE WHEN excluded.model <> 'unknown' AND (events.model = 'unknown' OR {_MORE}) "
          f"THEN excluded.model ELSE events.model END")
# A row stored with no date (9.0.0 wrote 1970 for the ISO text dates of Crush, Devin, Copilot Chat and Cline) takes the
# date a later read gives it; a date the row has is never replaced (the Mac app's upsert).
_TS = "ts=CASE WHEN events.ts <= 0 AND excluded.ts > 0 THEN excluded.ts ELSE events.ts END"
_UPSERT_SQL = (
    "INSERT INTO events(key, provider, model, ts, input, cr, cw, output, reasoning, session, cw1h, file) "
    "VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(key) DO UPDATE SET "
    + ", ".join(f"{c}=CASE WHEN {_MORE} THEN excluded.{c} ELSE events.{c} END"
                for c in ("input", "cr", "cw", "output", "reasoning", "cw1h", "provider"))
    + ", " + _MODEL + ", " + _TS + ", file=excluded.file")


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
    stamp: str | None = None      # a database's `inode:size:mtime_ns|...` stamp, kept in `meta` (see Scanner)


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
            self._repair_costs()
            self._repair_zero_dates()
        except (sqlite3.Error, OSError) as e:
            raise StoreError(f"{path}: {e}") from e

    def close(self) -> None:
        with self._lock:
            self.db.close()

    # ---------------------------------------------------------------------------------- schema

    def _repair_costs(self) -> None:
        """9.0.0 keyed a Claude Code run by its raw (fractional) start time and kept rows for cost lines without a
        session id. The Mac app keys a run by whole seconds and skips such a line: the rows are folded the same way
        (the larger count of each stands), and the session adjustment is computed again at the next pass."""
        odd_sql = ("SELECT session, started, model, input, cr, cw, output FROM costs "
                   "WHERE session = '' OR started <> CAST(started AS INTEGER)")
        if not self.db.execute(odd_sql).fetchall():
            return                  # nothing to repair: no write lock taken
        self.db.execute("BEGIN IMMEDIATE")
        try:
            # Read inside the transaction: a row another program wrote after an earlier read would be deleted unread.
            odd = self.db.execute(odd_sql).fetchall()
            self.db.execute("DELETE FROM costs WHERE session = '' OR started <> CAST(started AS INTEGER)")
            for session, started, model, i, cr, cw, o in odd:
                if not session:
                    continue
                self.db.execute("""
                    INSERT INTO costs(session, started, model, input, cr, cw, output) VALUES(?,?,?,?,?,?,?)
                    ON CONFLICT(session, started, model) DO UPDATE SET input=max(input, excluded.input),
                      cr=max(cr, excluded.cr), cw=max(cw, excluded.cw), output=max(output, excluded.output)""",
                                (session, run_seconds(started), model, i, cr, cw, o))
            self.db.execute("INSERT INTO meta(k, v) VALUES('cc-adjust-stale', '1') ON CONFLICT(k) DO UPDATE SET v = '1'")
            self.db.execute("COMMIT")
        except BaseException:
            self.db.execute("ROLLBACK")
            raise

    def _repair_zero_dates(self) -> None:
        """Once, for an index 9.0.0 made: rows dated 1970 get their date when the file or database they came from is read
        again, but a file that did not change is not read again. So the files those rows name are forgotten (their
        `files` record and database stamp) and the next pass reads them whole. The keys are the same: nothing is counted
        twice, the upsert only fills in the date."""
        flag = "repair:ts-zero-901"
        if self.db.execute("SELECT 1 FROM meta WHERE k = ?", (flag,)).fetchone() is not None:
            return
        self.db.execute("BEGIN IMMEDIATE")
        try:
            if self.db.execute("SELECT 1 FROM meta WHERE k = ?", (flag,)).fetchone() is None:
                self.db.execute("DELETE FROM files WHERE path IN (SELECT DISTINCT file FROM events WHERE ts <= 0)")
                self.db.execute("DELETE FROM meta WHERE k IN (SELECT ? || file FROM events WHERE ts <= 0)", (DBSTAMP,))
                self.db.execute("INSERT INTO meta(k, v) VALUES(?, '1') ON CONFLICT(k) DO UPDATE SET v = '1'", (flag,))
            self.db.execute("COMMIT")
        except BaseException:
            self.db.execute("ROLLBACK")
            raise

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
        key = safe_text(key)
        with self._lock:
            row = self.db.execute("SELECT v FROM meta WHERE k = ?", (key,)).fetchone()
        return row[0] if row else None

    def db_stamps(self) -> dict[str, str]:
        """path -> the stamp a database had when it was last read to the end."""
        with self._lock:
            rows = self.db.execute("SELECT k, v FROM meta WHERE k >= ? AND k < ?", (DBSTAMP, DBSTAMP[:-1] + ";")).fetchall()
        return {k[len(DBSTAMP):]: v for k, v in rows}

    def meta_prefix(self, prefix: str) -> list[tuple[str, str]]:
        """(key, value) of every meta row whose key starts with `prefix` (a prefix that ends in ':')."""
        with self._lock:
            return self.db.execute("SELECT k, v FROM meta WHERE k >= ? AND k < ?", (prefix, prefix[:-1] + chr(ord(prefix[-1]) + 1))).fetchall()

    def del_meta(self, key: str) -> None:
        with self._lock:
            self.db.execute("DELETE FROM meta WHERE k = ?", (safe_text(key),))

    def set_meta(self, key: str, value: str) -> None:
        key, value = safe_text(key), safe_text(value)
        with self._lock:
            self.db.execute("INSERT INTO meta(k, v) VALUES(?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v", (key, value))

    # ---------------------------------------------------------------------------------- writes

    _UPSERT = _UPSERT_SQL

    @staticmethod
    def _row(e: Event, file: str = ""):
        return (safe_text(e.key), safe_text(e.provider), safe_text(e.model), e.ts, e.inp, e.cr, e.cw, e.out, e.rz,
                safe_text(e.session), e.cw1h, safe_text(file))

    def apply(self, updates) -> None:
        """updates: list of (FileRecord | None, [Event], retire keys, cost rows[, [(meta key, value)]]), written in one
        transaction: a file's record and the meta rows that belong to it (a bad-file verdict) stand or fall together."""
        with self._lock:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                for record, events, retire, costs, *extra in updates:
                    keys, prefixes = retire if isinstance(retire, tuple) else (retire, [])
                    keys, prefixes = [safe_text(k) for k in keys], [safe_text(p) for p in prefixes]
                    if record is not None:
                        record = replace(record, path=safe_text(record.path))
                    costs = [(safe_text(c[0]), c[1], safe_text(c[2])) + tuple(c[3:]) for c in costs]
                    for key in keys:
                        self.db.execute("DELETE FROM events WHERE key = ?", (key,))
                        self.db.execute("DELETE FROM event_files WHERE key = ?", (key,))
                    for prefix in prefixes:
                        self._retire_prefix(prefix, record.path if record else "")
                    self.db.executemany(self._UPSERT, [self._row(e, record.path if record else "") for e in events])
                    if record is not None and prefixes:
                        self.db.executemany("INSERT OR IGNORE INTO event_files(key, file) VALUES(?,?)",
                                            [(safe_text(e.key), record.path) for e in events])
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
                        if record.stamp is not None:
                            self.db.execute("INSERT INTO meta(k, v) VALUES(?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v",
                                            (DBSTAMP + record.path, record.stamp))
                    for k, v in (extra[0] if extra else []):
                        self.db.execute("INSERT INTO meta(k, v) VALUES(?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v",
                                        (safe_text(k), safe_text(v)))
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
        prefix = safe_text(prefix)
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
        prefix = safe_text(prefix)
        upper = prefix[:-1] + chr(ord(prefix[-1]) + 1)
        with self._lock:
            return self.db.execute("SELECT 1 FROM events WHERE key >= ? AND key < ? LIMIT 1", (prefix, upper)).fetchone() is not None

    def cost_rows(self) -> list[tuple]:
        with self._lock:
            return self.db.execute("SELECT session, started, model, input, cr, cw, output FROM costs").fetchall()

    def sums(self, prefix: str, exclude: str | None = None, with_provider: bool = False) -> dict:
        """(session, model) -> (input, cacheRead, cacheWrite, output[, reasoning, provider]) over a key prefix."""
        prefix, exclude = safe_text(prefix), safe_text(exclude)
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
            s[5] = min(s[5], provider)       # MIN(provider), as the Mac app: not whichever row came first
        return {k: (tuple(v) if with_provider else tuple(v[:4])) for k, v in out.items()}

    def events_since(self, cutoff: float | None, until: float | None = None):
        """Rows (key, provider, model, ts, input, cr, cw, output, reasoning, cw1h) of one window: cutoff <= ts <= until
        (no `cutoff` = every row, `until` ignored)."""
        sql = "SELECT key, provider, model, ts, input, cr, cw, output, reasoning, cw1h FROM events"
        with self._lock:
            if cutoff is None:
                return self.db.execute(sql).fetchall()
            if until is None:
                return self.db.execute(sql + " WHERE ts >= ?", (cutoff,)).fetchall()
            return self.db.execute(sql + " WHERE ts >= ? AND ts <= ?", (cutoff, until)).fetchall()

    def event_count(self) -> int:
        with self._lock:
            return self.db.execute("SELECT count(*) FROM events").fetchone()[0]
