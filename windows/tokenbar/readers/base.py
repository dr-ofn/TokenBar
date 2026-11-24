"""What every reader shares: where events go, and how a family describes itself."""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Callable

from ..extdb import real_path
from ..util import FIELD_LIMIT, clamp, longpath


def real_event_key(key: str) -> str:
    """The key a REAL call is stored under. Adjustment rows are `<prefix>:adj:...`; a call whose own id (a Claude
    message.id, a Cline task id ...) is exactly `adj` would read as one, so that second part is written `adj#gercek`.
    The adjustment writers (`claude_adjust`, `qwen_adjust`, Zed's gap row) never pass through here."""
    head, sep, rest = key.partition(":")
    second, sep2, tail = rest.partition(":")
    if sep and second == "adj":
        return f"{head}:adj#gercek{sep2}{tail}"
    return key


def real_event_prefixes(prefix: str) -> list[str]:
    """Every prefix that can hold the REAL rows a key prefix built from a raw id stands for: the prefix itself (rows an
    older index wrote, and everything that is no `adj`) and its `adj#gercek` form. For prefixes made of an id (`cline:<task>:`,
    `devin:<session>:db:`), never for the adjustment prefixes (`cc:adj:`, `qwen:adj:`, `zed:adj:`), which are fixed names."""
    real = real_event_key(prefix)
    return [prefix] if real == prefix else [prefix, real]


@dataclass
class Event:
    key: str
    ts: float
    provider: str
    model: str
    inp: int
    cr: int
    cw: int
    out: int
    rz: int
    cw1h: int
    session: str = ""

    @property
    def total(self) -> int:
        return self.inp + self.cr + self.cw + self.out


class Sink:
    """Collects what one read of one file produced."""

    def __init__(self) -> None:
        self.events: list[Event] = []
        self.retire_keys: list[str] = []
        self.retire_prefixes: list[str] = []
        self.costs: list[tuple] = []     # Claude cost-state runs: (session, started, model, inp, cr, cw, out)
        self.issues: list[str] = []
        self.bad: str | None = None   # keep what was read, name this problem every pass, never record the file (see Scanner)
        self.retry = False        # keep what was read, but do not mark the file read: it is read again next pass

    def add(self, key: str, ts: float, provider: str, model: str, inp: int, cr: int, cw: int, out: int, rz: int = 0,
            cw1h: int = 0, session: str = "", adjustment: bool = False) -> None:
        inp, cr, cw, out = clamp(inp), clamp(cr), clamp(cw), clamp(out)
        if inp + cr + cw + out == 0:
            return
        if not adjustment:
            key = real_event_key(key)
        self.events.append(Event(key, ts if ts == ts else 0.0, provider or "", model or "unknown", inp, cr, cw, out,
                                 clamp(rz), min(clamp(cw1h), cw), session))

    def retire(self, key: str) -> None:
        """A row this read recomputes: deleted first, so a figure that shrank does not stay at its old value."""
        self.retire_keys.append(key)

    def retire_prefix(self, prefix: str) -> None:
        """Every row under a key prefix: the file now says the whole task differently (a checkpoint restore)."""
        self.retire_prefixes += real_event_prefixes(prefix)       # `cline:adj:` also stands for the rows of a task named `adj`

    def issue(self, message: str) -> None:
        self.issues.append(message)


@dataclass
class Family:
    name: str
    files: Callable            # (ctx, descriptor) -> list of paths
    read: Callable             # (ctx, descriptor, path, offset, limit, settled, sink) -> new offset
    mode: str = "whole"        # "lines" resumes at a byte offset, "rowid" at a stored row id, "whole" re-reads
    stamp: Callable | None = None   # (path) -> (stamp text, size, newest mtime) for databases that have a -wal file
    after: Callable | None = None   # (ctx, descriptor, store, changed) -> None: cross-file adjustments


REGISTRY: dict[str, Family] = {}


def family(name: str, files: Callable, mode: str = "whole", stamp=None, after=None):
    def deco(fn):
        REGISTRY[name] = Family(name, files, fn, mode, stamp, after)
        return fn
    return deco


def db_stamp(path: str) -> tuple[str, int, float]:
    """(stamp, size, newest mtime) of a SQLite file together with its -wal.

    The stamp is one `inode:size:mtime_ns` per file, joined (as the Mac app's): each file on its own, because a sum of
    two sizes and the newest of two times are the same for different pairs, and compared for equality, because a
    clock set back or a restored backup moves a time backwards and is still a change.

    A database that is a symbolic link has its `-wal` beside the file the link leads to, and that is the one stamped:
    the one beside the link does not exist, and a stamp that never changed would keep the file from being read again."""
    parts, size, newest = [], 0, 0.0
    real = real_path(path)
    for p in (path, real + "-wal"):
        try:
            st = os.stat(longpath(p))
        except FileNotFoundError:
            parts.append("-")
            continue
        except OSError:
            # Seen but not looked at (a permission error): not the "-" of a file that is not there, or a -wal that
            # turned up unreadable would match the stamp taken without one and the read, which names it, never runs.
            parts.append("?")
            continue
        parts.append(f"{st.st_ino}:{st.st_size}:{st.st_mtime_ns}")
        size += st.st_size
        newest = max(newest, st.st_mtime)
    return "|".join(parts), size, newest
