"""Read-only access to another tool's SQLite database, and zstd for the files that need it.

TokenBar never writes into the folder of a tool it reads. A database in WAL mode is the catch: SQLite opens even a
read-only handle on it through a `-shm` file next to it and makes that file when it is missing, and `immutable=1`
would ignore the `-wal` that holds the newest rows. So a WAL database is read from a copy of its `.db` and `-wal` in
a private temporary folder (deleted again); a WAL database with no `-wal` (or an empty one) is read in place with
`immutable=1` (a copy could not be opened read-only without a `-shm`); a WAL database too large to copy likewise;
any other database is opened `mode=ro` in place, and `immutable=1` when that fails (never for a copy: that would
drop the `-wal`).

A database that is a symbolic link is read at the file the link leads to (`real_path`): SQLite opens the `-wal`, `-shm`
and `-journal` beside THAT file, so those are what is looked for, copied and stamped, never the ones beside the link
(there are none: the newest rows would be missed, and SQLite would delete the `-wal` of a 0-byte database it opens in
place). A pipe, socket or device under the name of the database or of one of those files is never opened.
"""
from __future__ import annotations

import contextlib
import io
import os
import re
import shutil
import sqlite3
import stat
import subprocess
import tempfile
import threading
import time
import urllib.parse
from pathlib import Path, PureWindowsPath

from .util import longpath

COPY_LIMIT = 4 << 30
SCRATCH_PREFIX = "tokenbar-extdb-"
ZSTD_OUTPUT_LIMIT = 256 << 20    # what a zstd blob held in memory (a Zed thread) may unpack to: the Mac app's (ScannerG2.swift)
# Rollout archives are read as a stream, with the Mac app's limits (Zstd.swift): one line, and the whole output.
# A small archive can unpack to gigabytes; past either limit it is named and not read.
ZSTD_MAX_LINE = 64 << 20
ZSTD_MAX_OUTPUT = 4 << 30
ZSTD_CHUNK = 1 << 16


class ZstdMissing(Exception):
    """Neither the `zstandard` package nor a `zstd` program is available."""


class ZstdTooLarge(ValueError):
    """One line, or the whole output, is larger than any log of a tool is: not read."""


def real_path(path: str) -> str:
    """The file a database path leads to (a symbolic link, relative or not, followed): where SQLite looks for the
    `-wal`, `-shm` and `-journal`. A name that cannot be resolved is returned as it is."""
    try:
        return os.path.realpath(longpath(path))
    except (OSError, ValueError):
        return path


SIDE_SUFFIXES = ("", "-journal", "-wal", "-shm")


def special_file(path: str) -> str | None:
    """The first of the database and its side files (beside the path and beside the file a link leads to) that is a
    pipe, a socket or a device, or None. Looked at with `stat` before anything opens them: opening a pipe waits for a
    writer, and SQLite opens the `-journal` to look for a hot one (the Mac app's ExternalDB)."""
    spellings = [path]
    real = real_path(path)
    if real != path:
        spellings.append(real)
    for spelling in spellings:
        for suffix in SIDE_SUFFIXES:
            p = spelling + suffix
            try:
                mode = os.stat(longpath(p)).st_mode
            except (OSError, ValueError):
                continue
            if stat.S_ISFIFO(mode) or stat.S_ISSOCK(mode) or stat.S_ISCHR(mode) or stat.S_ISBLK(mode):
                return p
    return None


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
    """(size, mtime_ns), or None for a file that is not there. Any other failure to look (a permission error) raises:
    a -wal that cannot be seen is not a -wal that does not exist, and the .db read without it would be called read."""
    try:
        st = os.stat(longpath(path))
    except FileNotFoundError:
        return None
    return (st.st_size, st.st_mtime_ns)


def _wal_is_empty(path: str) -> bool:
    """True when there is no `-wal` beside the database, or one of 0 bytes. Any other failure to look (a permission
    error) is not "empty": the copy is tried, and raises."""
    try:
        return os.stat(longpath(path + "-wal")).st_size == 0
    except FileNotFoundError:
        return True
    except OSError:
        return False


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


def _give_empty_main_a_page(target: str) -> None:
    """A database of 0 bytes with a `-wal` (its first checkpoint has not happened: every page, the schema's too, is in the
    `-wal`): SQLite deletes the `-wal` of a file with no page, so the copy would read as an empty database and the rows
    would be lost. One page of zeros makes SQLite open the `-wal`, whose frames replace that page. Only ever the copy."""
    try:
        if os.path.getsize(target) != 0 or os.path.getsize(target + "-wal") < 32:
            return
        with open(target + "-wal", "rb") as f:
            head = f.read(32)
        size = int.from_bytes(head[8:12], "big")
        if head[:4] not in (b"\x37\x7f\x06\x82", b"\x37\x7f\x06\x83") or size < 512 or size > 65536 or size & (size - 1):
            return
    except OSError:
        return                  # the header cannot be read: the copy is opened as it is
    with open(target, "wb") as f:    # a failed write raises: SQLite would drop the -wal and read the database as empty
        f.write(bytes(size))


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
            _give_empty_main_a_page(target)
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
    odd = special_file(path)
    if odd is not None:
        raise sqlite3.OperationalError(f"{odd}: not a regular file, the database was not opened")
    path = real_path(path)          # a link is followed once, here: every side file below is the one beside the real file
    target, query = path, ("immutable=1" if immutable else "mode=ro")
    if not immutable and uses_wal(path):
        if _wal_is_empty(path):
            # A WAL database with no -wal (or an empty one) holds everything in its main file: the tool's last
            # connection checkpointed and closed it. A read-only connection cannot open the copy of such a file (it
            # would have to make a -shm), and there is nothing newer to copy: the file is read as it is (the Mac app too).
            query = "immutable=1"
        else:
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
            if query == "immutable=1" or scratch is not None:
                # A copy of a WAL database that will not open read-only is an error: `immutable=1` would ignore the
                # copied -wal, count only what the .db holds and let the file be called read (the Mac app raises too).
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


def _zstd_chunks(path: str | None = None, data: bytes | None = None):
    """The decoded bytes of a zstd file (or of `data`) in chunks, by whichever decoder is there: the `zstandard`
    package, Python 3.14's `compression.zstd`, or the `zstd` program. Raises ZstdMissing / ValueError."""
    try:
        import zstandard
    except ImportError:
        zstandard = None
    if zstandard is not None:
        src = open(longpath(path), "rb") if path is not None else io.BytesIO(data)
        try:
            with zstandard.ZstdDecompressor().stream_reader(src, read_across_frames=True) as r:
                while True:
                    chunk = r.read(ZSTD_CHUNK)
                    if not chunk:
                        return
                    yield chunk
        except zstandard.ZstdError as e:
            raise ValueError(f"zstd: {e}") from e
        finally:
            src.close()
    try:
        from compression import zstd as std
    except ImportError:
        std = None
    if std is not None:
        bad = (getattr(std, "ZstdError", ValueError), EOFError)
        try:
            with std.ZstdFile(longpath(path) if path is not None else io.BytesIO(data)) as f:
                while True:
                    chunk = f.read(ZSTD_CHUNK)
                    if not chunk:
                        return
                    yield chunk
        except bad as e:
            raise ValueError(f"zstd: {e}") from e
    exe = shutil.which("zstd")
    if not exe:
        raise ZstdMissing("zstd is not available (pip install zstandard)")
    cmd = [exe, "-dc", "--", longpath(path)] if path is not None else [exe, "-dc"]
    proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL if path is not None else subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
    try:
        if path is None:
            def feed():
                try:
                    proc.stdin.write(data)
                except OSError:                 # the program stopped reading (a limit, or a bad stream)
                    pass
                finally:
                    try:
                        proc.stdin.close()
                    except OSError:
                        pass
            threading.Thread(target=feed, daemon=True).start()
        while True:
            chunk = proc.stdout.read(ZSTD_CHUNK)
            if not chunk:
                break
            yield chunk
        if proc.wait() != 0:
            raise ValueError("zstd: not a valid zstd stream")
    finally:                                    # a read that gave up leaves a program that is still writing: end it
        if proc.poll() is None:
            proc.kill()
        proc.stdout.close()
        proc.wait()


def zstd_decompress(data: bytes) -> bytes:
    """The decompressed bytes of a zstd stream (up to `ZSTD_OUTPUT_LIMIT`); raises ZstdMissing / ValueError."""
    out = bytearray()
    for chunk in _zstd_chunks(data=data):
        out += chunk
        if len(out) > ZSTD_OUTPUT_LIMIT:
            raise ZstdTooLarge(f"output exceeds {ZSTD_OUTPUT_LIMIT >> 20} MiB")
    return bytes(out)


_EMPTY_FRAME = bytes.fromhex("28b52ffd2000010000")      # a zstd frame of no bytes


def zstd_lines(path: str):
    """Decoded text lines of a .zst file, read as a stream. A line longer than `ZSTD_MAX_LINE`, or output beyond
    `ZSTD_MAX_OUTPUT`, raises ZstdTooLarge (the Mac app's limits)."""
    zstd_decompress(_EMPTY_FRAME)                       # a missing decoder is one ZstdMissing, before the file is opened
    pending = bytearray()
    total = 0

    def decode(raw) -> str:
        raw = bytes(raw)
        # A UTF-8 BOM in front of a line is no content, in front of any line (the Mac app's JSON parser reads each line
        # on its own, as `iter_lines` does): left in, the session_meta line does not parse and a fork's repeated history
        # is counted again.
        if raw.startswith(b"\xef\xbb\xbf"):
            raw = raw[3:]
        return raw.decode("utf-8", "replace").rstrip("\r")

    for chunk in _zstd_chunks(path=path):
        total += len(chunk)
        pending += chunk
        start = 0
        while True:
            nl = pending.find(b"\n", start)
            if nl < 0:
                break
            if nl - start > ZSTD_MAX_LINE:
                raise ZstdTooLarge(f"a line exceeds {ZSTD_MAX_LINE >> 20} MiB")
            yield decode(pending[start:nl])
            start = nl + 1
        del pending[:start]
        if len(pending) > ZSTD_MAX_LINE:
            raise ZstdTooLarge(f"a line exceeds {ZSTD_MAX_LINE >> 20} MiB")
        # After the chunk's own lines have been handed over (the Mac app's order): what came before the limit counts.
        if total > ZSTD_MAX_OUTPUT:
            raise ZstdTooLarge(f"output exceeds {ZSTD_MAX_OUTPUT >> 20} MiB")
    yield decode(pending)
