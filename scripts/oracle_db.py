"""Read-only access to another tool's SQLite database for the oracles: the Python twin of Sources/LocalCore/ExternalDB.swift.

A database in WAL mode (or with a `-wal` next to it) is not opened in place: even `mode=ro` makes SQLite create a `-shm`
in the tool's folder (and it deletes the `-wal` of a 0-byte database). So the `.db` and the `-wal` are copied into a
private temporary folder and read there; the copy is deleted when the connection closes.

    with readonly(path) as con:
        rows = con.execute("select ...").fetchall()

A database that is a symbolic link is read at the file the link leads to: SQLite opens the `-wal` beside THAT file, so
it is the one looked for and copied (the one beside the link does not exist). A pipe, socket or device under the name
of the database or of a side file is never opened.

Raises sqlite3.Error (never another exception) when the file cannot be opened or copied, like a plain connect.
"""
import contextlib
import os
import shutil
import sqlite3
import stat
import tempfile
from urllib.parse import quote


def special_file(path):
    """The first of the database and its side files (beside the link and beside the file it leads to) that is a pipe, a
    socket or a device, or None: looked at with stat, because opening a pipe waits for a writer."""
    for spelling in dict.fromkeys((path, os.path.realpath(path))):
        for suffix in ("", "-journal", "-wal", "-shm"):
            try:
                mode = os.stat(spelling + suffix).st_mode
            except (OSError, ValueError):
                continue
            if stat.S_ISFIFO(mode) or stat.S_ISSOCK(mode) or stat.S_ISCHR(mode) or stat.S_ISBLK(mode):
                return spelling + suffix
    return None


def give_empty_main_a_page(copy):
    """A 0-byte database with a `-wal` (no checkpoint yet): SQLite deletes the `-wal` of a file with no page, so the
    copy gets one page of zeros and the frames of the `-wal` replace it."""
    try:
        if os.path.getsize(copy) != 0 or os.path.getsize(copy + "-wal") < 32:
            return
        with open(copy + "-wal", "rb") as f:
            head = f.read(32)
        size = int.from_bytes(head[8:12], "big")
        if head[:4] not in (b"\x37\x7f\x06\x82", b"\x37\x7f\x06\x83") or size < 512 or size > 65536 or size & (size - 1):
            return
    except OSError:
        return                  # the header cannot be read: the copy is opened as it is
    with open(copy, "wb") as f:    # a failed write raises: SQLite would drop the -wal and read the database as empty
        f.write(bytes(size))


def uses_wal(path):
    """A `-wal` next to the file settles it; otherwise bytes 18 and 19 of the header say 2 for WAL."""
    if os.path.exists(path + "-wal"):
        return True
    try:
        with open(path, "rb") as f:
            head = f.read(20)
    except OSError:
        return False
    return len(head) == 20 and head[:15] == b"SQLite format 3" and (head[18] == 2 or head[19] == 2)


def uri(path, query):
    return f"file:{quote(path, safe='/')}?{query}"


@contextlib.contextmanager
def readonly(path):
    odd = special_file(path)
    if odd is not None:
        raise sqlite3.OperationalError(f"{odd}: not a regular file, the database was not opened")
    path = os.path.realpath(path)
    if not uses_wal(path):
        con = sqlite3.connect(uri(path, "mode=ro"), uri=True)
        try:
            yield con
        finally:
            con.close()
        return
    try:
        no_wal = os.path.getsize(path + "-wal") == 0
    except FileNotFoundError:
        no_wal = True
    if no_wal:
        # A WAL database whose last connection checkpointed and closed it (no `-wal`, or an empty one) holds everything in its
        # main file; a read-only connection cannot open a copy of it (it would have to make a `-shm`): it is read as it is,
        # `immutable`, like the apps' ExternalDB.
        con = sqlite3.connect(uri(path, "immutable=1"), uri=True)
        try:
            yield con
        finally:
            con.close()
        return
    folder = tempfile.mkdtemp(prefix="tokenbar-oracle-")
    try:
        copy = os.path.join(folder, os.path.basename(path))
        try:
            shutil.copy2(path, copy)
            if os.path.exists(path + "-wal"):
                shutil.copy2(path + "-wal", copy + "-wal")
        except OSError as e:
            raise sqlite3.OperationalError(str(e))
        give_empty_main_a_page(copy)
        con = sqlite3.connect(uri(copy, "mode=ro"), uri=True)
        try:
            yield con
        finally:
            con.close()
    finally:
        shutil.rmtree(folder, ignore_errors=True)
