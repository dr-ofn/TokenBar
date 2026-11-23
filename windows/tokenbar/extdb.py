"""Read-only access to another tool's SQLite database, and zstd for the files that need it.

TokenBar never writes into the folder of a tool it reads. A database in WAL mode is the catch: SQLite opens even a
read-only handle on it through a `-shm` file next to it and makes that file when it is missing, and `immutable=1`
would ignore the `-wal` that holds the newest rows. So a WAL database is read from a copy of its `.db` and `-wal` in
a private temporary folder (deleted again); any other database is opened `mode=ro` in place, and `immutable=1`
when that fails.
"""
from __future__ import annotations

import contextlib
import io
import os
import re
import shutil
import sqlite3
import subprocess
import tempfile
import time
import urllib.parse
from pathlib import Path, PureWindowsPath

from .util import longpath

COPY_LIMIT = 4 << 30
SCRATCH_PREFIX = "tokenbar-extdb-"
ZSTD_OUTPUT_LIMIT = 1 << 30


class ZstdMissing(Exception):
    """Neither the `zstandard` package nor a `zstd` program is available."""


def uses_wal(path: str) -> bool:
    """Bytes 18 and 19 of the file header are the format versions: 2 means WAL mode."""
    try:
        with open(longpath(path), "rb") as f:
            head = f.read(20)
    except OSError:
        head = b""
    if len(head) == 20 and head[:15] == b"SQLite format 3" and (head[18] == 2 or head[19] == 2):
        return True
    # A -wal beside the file means the newest rows are in it, whatever the header says (an empty .db included):
    # opened in place, SQLite would delete or rebuild it, and make a -shm. Only a copy is ever opened.
    return os.path.exists(longpath(path + "-wal"))


def _stamp(path: str):
    try:
        st = os.stat(longpath(path))
    except OSError:
        return None
    return (st.st_size, st.st_mtime_ns)


def _sweep_old_scratch() -> None:
    """Copies a crashed run left behind: a day old is nobody's."""
    base = tempfile.gettempdir()
    try:
        entries = os.listdir(base)
    except OSError:
        return
    for name in entries:
        if name.startswith(SCRATCH_PREFIX):
            p = os.path.join(base, name)
            try:
                if time.time() - os.path.getmtime(p) > 86400:
                    shutil.rmtree(p, ignore_errors=True)
            except OSError:
                pass


def _copy_pair(path: str):
    """(folder, copy of the db) with its -wal beside it, or None when it is too large or has gone.
    Raises OSError when the copy fails (Windows: the other program holds the file): the newest rows live in the -wal,
    so reading the original without it would count too little and call the file read."""
    _sweep_old_scratch()
    folder = tempfile.mkdtemp(prefix=SCRATCH_PREFIX)
    target = os.path.join(folder, os.path.basename(path))
    try:
        for _ in range(3):
            before = (_stamp(path), _stamp(path + "-wal"))
            if before[0] is None or before[0][0] + (before[1][0] if before[1] else 0) > COPY_LIMIT:
                break
            for p in (target, target + "-wal"):
                with contextlib.suppress(OSError):
                    os.remove(p)
            shutil.copyfile(longpath(path), target)
            if before[1] is not None:
                # Only a -wal that has just gone (a checkpoint removed it) is no error. A -wal another program holds
                # raises: the .db alone would read without the newest rows and the file would be called read.
                with contextlib.suppress(FileNotFoundError):
                    shutil.copyfile(longpath(path + "-wal"), target + "-wal")
            if (_stamp(path), _stamp(path + "-wal")) == before:
                return folder, target
        else:
            return folder, target     # kept changing while copied: the last copy is the best there is
    except OSError:
        shutil.rmtree(folder, ignore_errors=True)
        raise
    shutil.rmtree(folder, ignore_errors=True)
    return None


_WINDOWS_PATH = re.compile(r"^(\\\\|[A-Za-z]:[\\/])")


def file_uri(absolute: str) -> str:
    """The `file:` URI SQLite takes for an absolute path. A network path (`\\\\server\\share\\x.db`) is written
    `file:////server/share/x.db`: the authority stays empty, because SQLite refuses any host but `localhost`."""
    if absolute.startswith("\\\\?\\UNC\\"):
        absolute = "\\\\" + absolute[8:]
    elif absolute.startswith("\\\\?\\"):
        absolute = absolute[4:]
    if absolute.startswith("\\\\"):
        return "file:////" + urllib.parse.quote(absolute[2:].replace("\\", "/"), safe="/:")
    if _WINDOWS_PATH.match(absolute):
        return PureWindowsPath(absolute).as_uri()
    return Path(absolute).as_uri()


def _uri(path: str, query: str) -> str:
    return file_uri(os.path.abspath(path)) + "?" + query


@contextlib.contextmanager
def open_readonly(path: str, immutable: bool = False):
    """A read-only sqlite3 connection on someone else's database; raises sqlite3.Error when it cannot be read."""
    scratch = None
    target, query = path, ("immutable=1" if immutable else "mode=ro")
    if not immutable and uses_wal(path):
        pair = _copy_pair(path)
        if pair:
            scratch, target = pair
        else:
            query = "immutable=1"
    con = None
    try:
        try:
            con = sqlite3.connect(_uri(target, query), uri=True, timeout=3)
            con.execute("select 1 from sqlite_master limit 1").fetchall()
        except sqlite3.Error:
            if con is not None:
                con.close()
            if query == "immutable=1":
                raise
            con = sqlite3.connect(_uri(target, "immutable=1"), uri=True, timeout=3)
            con.execute("select 1 from sqlite_master limit 1").fetchall()
        con.text_factory = lambda b: b.decode("utf-8", "replace")
        yield con
    finally:
        if con is not None:
            con.close()
        if scratch:
            shutil.rmtree(scratch, ignore_errors=True)


_TRANSIENT = ("locked", "busy", "unable to open", "disk i/o", "disk image", "cannot open", "readonly database")


def is_transient(error: BaseException) -> bool:
    """True when reading may work later: another program holds the file (a Windows sharing violation, a database
    lock). A file that is no database, or lacks the table, will not get better and is final."""
    if isinstance(error, OSError):
        return True
    return isinstance(error, sqlite3.DatabaseError) and any(w in str(error).lower() for w in _TRANSIENT)


def query(con, sql: str, args=()) -> list:
    """All rows of one query; a missing table or column is an empty answer, a lock or an I/O error is raised
    (as OSError) so the file is read again next pass instead of being marked read."""
    try:
        return con.execute(sql, args).fetchall()
    except sqlite3.Error as e:
        if is_transient(e):
            raise OSError(str(e)) from e
        return []


def table_columns(con, table: str) -> set[str]:
    return {r[1] for r in query(con, f"PRAGMA table_info({table})")}


@contextlib.contextmanager
def readable(path: str, immutable: bool = False):
    """`open_readonly` for a reader that counts the file: what cannot be opened right now raises OSError (retried next
    pass); what is no database at all raises sqlite3.Error (final)."""
    try:
        with open_readonly(path, immutable) as con:
            yield con
    except sqlite3.Error as e:
        if is_transient(e):
            raise OSError(str(e)) from e
        raise


def rows(path: str, sql: str, args=(), immutable: bool = False, strict: bool = False) -> list:
    """All rows of one query on a database opened read-only. A file that is no database has none (with `strict` it
    raises sqlite3.Error, for the reader that names it); a file that is locked raises OSError."""
    try:
        with readable(path, immutable) as con:
            return query(con, sql, args)
    except sqlite3.Error:
        if strict:
            raise
        return []


def columns(path: str, table: str) -> set[str]:
    return {r[1] for r in rows(path, f"PRAGMA table_info({table})")}


# ---------------------------------------------------------------------------------------------- zstd

def zstd_available() -> bool:
    try:
        import zstandard  # noqa: F401
        return True
    except ImportError:
        pass
    try:
        from compression import zstd  # noqa: F401  (Python 3.14)
        return True
    except ImportError:
        return shutil.which("zstd") is not None


def zstd_decompress(data: bytes) -> bytes:
    """The decompressed bytes of a zstd stream (up to a gigabyte); raises ZstdMissing / ValueError."""
    try:
        import zstandard
    except ImportError:
        zstandard = None
    if zstandard is not None:
        try:
            with zstandard.ZstdDecompressor().stream_reader(io.BytesIO(data), read_across_frames=True) as r:
                out = r.read(ZSTD_OUTPUT_LIMIT + 1)
        except zstandard.ZstdError as e:
            raise ValueError(f"zstd: {e}") from e
        if len(out) > ZSTD_OUTPUT_LIMIT:
            raise ValueError("zstd: output too large")
        return out
    try:
        from compression import zstd as std
        return std.decompress(data)
    except ImportError:
        pass
    exe = shutil.which("zstd")
    if not exe:
        raise ZstdMissing("zstd is not available (pip install zstandard)")
    proc = subprocess.run([exe, "-dc"], input=data, capture_output=True)
    if proc.returncode != 0:
        raise ValueError("zstd: not a valid zstd stream")
    return proc.stdout


def zstd_lines(path: str):
    """Decoded text lines of a .zst file."""
    with open(longpath(path), "rb") as f:
        data = f.read()
    text = zstd_decompress(data).decode("utf-8", "replace")
    for line in text.split("\n"):
        yield line.rstrip("\r")
