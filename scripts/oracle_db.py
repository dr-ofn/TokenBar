"""Read-only access to another tool's SQLite database for the oracles: the Python twin of Sources/LocalCore/ExternalDB.swift.

A database in WAL mode (or with a `-wal` next to it) is not opened in place: even `mode=ro` makes SQLite create a `-shm`
in the tool's folder (and it deletes the `-wal` of a 0-byte database). So the `.db` and the `-wal` are copied into a
private temporary folder and read there; the copy is deleted when the connection closes.

    with readonly(path) as con:
        rows = con.execute("select ...").fetchall()

Raises sqlite3.Error (never another exception) when the file cannot be opened or copied, like a plain connect.
"""
import contextlib
import os
import shutil
import sqlite3
import tempfile
from urllib.parse import quote


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
    if not uses_wal(path):
        con = sqlite3.connect(uri(path, "mode=ro"), uri=True)
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
        con = sqlite3.connect(uri(copy, "mode=ro"), uri=True)
        try:
            yield con
        finally:
            con.close()
    finally:
        shutil.rmtree(folder, ignore_errors=True)
