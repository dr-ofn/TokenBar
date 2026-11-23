"""What every reader shares: where events go, and how a family describes itself."""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Callable

from ..util import FIELD_LIMIT, clamp, longpath


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
        self.retry = False        # keep what was read, but do not mark the file read: it is read again next pass

    def add(self, key: str, ts: float, provider: str, model: str, inp: int, cr: int, cw: int, out: int, rz: int = 0,
            cw1h: int = 0, session: str = "") -> None:
        inp, cr, cw, out = clamp(inp), clamp(cr), clamp(cw), clamp(out)
        if inp + cr + cw + out == 0:
            return
        self.events.append(Event(key, ts if ts == ts else 0.0, provider or "", model or "unknown", inp, cr, cw, out,
                                 clamp(rz), min(clamp(cw1h), cw), session))

    def retire(self, key: str) -> None:
        """A row this read recomputes: deleted first, so a figure that shrank does not stay at its old value."""
        self.retire_keys.append(key)

    def retire_prefix(self, prefix: str) -> None:
        """Every row under a key prefix: the file now says the whole task differently (a checkpoint restore)."""
        self.retire_prefixes.append(prefix)

    def issue(self, message: str) -> None:
        self.issues.append(message)


@dataclass
class Family:
    name: str
    files: Callable            # (ctx, descriptor) -> list of paths
    read: Callable             # (ctx, descriptor, path, offset, limit, settled, sink) -> new offset
    mode: str = "whole"        # "lines" resumes at a byte offset, "rowid" at a stored row id, "whole" re-reads
    stamp: Callable | None = None   # (path) -> (size, mtime) for databases that have a -wal file
    after: Callable | None = None   # (ctx, descriptor, store, changed) -> None: cross-file adjustments


REGISTRY: dict[str, Family] = {}


def family(name: str, files: Callable, mode: str = "whole", stamp=None, after=None):
    def deco(fn):
        REGISTRY[name] = Family(name, files, fn, mode, stamp, after)
        return fn
    return deco


def db_stamp(path: str) -> tuple[int, float]:
    """Size and newest modification time of a SQLite file together with its -wal."""
    size, newest = 0, 0.0
    for p in (path, path + "-wal"):
        try:
            st = os.stat(longpath(p))
        except OSError:
            continue
        size += st.st_size
        newest = max(newest, st.st_mtime)
    return size, newest
