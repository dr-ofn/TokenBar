"""Safe readers for files someone else wrote.

Every number, time and nested value that comes out of a log goes through here, so a corrupt or hostile file
(1e20 where a count belongs, NaN, a 50000-deep array, a 5000-digit integer, a lone BOM) never raises past the reader.
Counts are held to 0..FIELD_LIMIT, which is the Mac app's `Int64.max / 4`: four of them still add up inside
SQLite's 64-bit INTEGER.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import time
from datetime import datetime, timezone
from typing import Any, Iterator

FIELD_LIMIT = (2 ** 63 - 1) // 4
MAX_LINE_BYTES = 256 * 1024 * 1024
MAX_JSON_FILE_BYTES = 512 * 1024 * 1024
JSON_ERRORS = (ValueError, RecursionError, MemoryError, OverflowError)
SETTLE_SECONDS = 10.0       # a file touched more recently than this may still be in the middle of being written


class BadFile(Exception):
    """A file that has been quiet for a while and still is not what its reader needs (not JSON, not a database): named
    as a source error on every pass and left unrecorded, as the Mac app does. Cheap: the scanner keeps the verdict
    while the file does not change."""


class Retry(Exception):
    """A file that cannot be judged right now (gone, or half written a moment ago): left unrecorded, read next pass.
    Not a problem worth naming: the file is simply not finished."""


def longpath(path: str) -> str:
    """Windows refuses paths over ~260 characters unless they carry the `\\\\?\\` prefix."""
    if os.name == "nt" and len(path) > 240 and not path.startswith("\\\\?\\"):
        path = os.path.abspath(path)
        return "\\\\?\\UNC\\" + path[2:] if path.startswith("\\\\") else "\\\\?\\" + path
    return path


def is_number(v: Any) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def finite(v: Any) -> bool:
    if isinstance(v, bool):
        return False
    if isinstance(v, int):
        return True
    return isinstance(v, float) and math.isfinite(v)


def clamp(n: int) -> int:
    return min(max(n, 0), FIELD_LIMIT)


def whole(v: Any) -> int:
    """A JSON number as the Mac reader sees it: a fraction is cut off, anything else (or NaN/Infinity) is 0.
    Negative values are kept: callers that subtract need them, `clamp` holds the rest."""
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return 0
    if isinstance(v, float):
        if not math.isfinite(v):
            return 0
        v = int(v)
    return max(-FIELD_LIMIT, min(v, FIELD_LIMIT))


def num(d: Any, key: str) -> int:
    """`d[key]` as a count: a number held to 0..FIELD_LIMIT, else 0."""
    return clamp(whole(d.get(key))) if isinstance(d, dict) else 0


def raw_num(d: Any, key: str) -> int:
    """`d[key]` as a signed whole number (for differences)."""
    return whole(d.get(key)) if isinstance(d, dict) else 0


def text(v: Any) -> str | None:
    """A non-empty string, else None."""
    return v if isinstance(v, str) and v else None


def epoch(value: Any) -> float:
    """Unix seconds from a number (milliseconds above 1e11) or an ISO string; 0.0 when it is neither or absurd."""
    if isinstance(value, bool):
        return 0.0
    if isinstance(value, (int, float)):
        if not finite(value):
            return 0.0
        try:
            v = value / 1000 if value > 1e11 else float(value)
        except OverflowError:
            return 0.0
        return v if math.isfinite(v) else 0.0
    if not isinstance(value, str) or not value:
        return 0.0
    try:
        t = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        try:
            return epoch(float(value))
        except ValueError:
            return 0.0
    try:
        return (t if t.tzinfo else t.replace(tzinfo=timezone.utc)).timestamp()
    except (OverflowError, OSError, ValueError):
        return 0.0


def to_seconds(v: Any) -> float:
    """A time as seconds, as the Mac app's `J.time` reads it: a number of seconds or milliseconds, or an ISO-8601
    string (0.0 for anything else)."""
    return epoch(v)


def sha(s: str) -> str:
    return hashlib.sha1(s.encode("utf-8", "replace")).hexdigest()


def line_hash(line: str) -> str:
    """Hash of a log line without its line ending, so LF and CRLF copies of a file give one key."""
    return sha(line.rstrip("\r\n"))


def loads(s: str | bytes) -> Any:
    """json.loads that returns None for anything unparsable, however deep or long."""
    try:
        return json.loads(s)
    except JSON_ERRORS:
        return None


def load_json_file(path: str) -> Any:
    """The decoded JSON document at `path`, or None (missing, unreadable, too large, not JSON).
    For files that are optional or only hint at something; a file that is counted uses `read_json_file`."""
    try:
        if os.path.getsize(longpath(path)) > MAX_JSON_FILE_BYTES:
            return None
        with open(longpath(path), encoding="utf-8-sig", errors="replace") as f:
            return json.load(f)
    except (OSError, *JSON_ERRORS):
        return None


def read_json_file(path: str, strict: bool = False) -> Any:
    """The decoded JSON document at `path` for a file whose numbers are counted.

    A file that cannot be opened (Windows: another program holds it, a sharing violation) raises OSError, so the
    scanner names it and reads it again next pass instead of marking it read. A file that is not JSON yet because it
    was touched a moment ago raises Retry; one that has been quiet and still is not JSON (or is too large) is final
    and gives None, like the Mac app's empty result. With `strict` (the readers whose Mac twin names such a file) it
    raises BadFile instead; a file of no bytes is still no reading and no problem."""
    try:
        if os.path.getsize(longpath(path)) > MAX_JSON_FILE_BYTES:
            return None
        with open(longpath(path), encoding="utf-8-sig", errors="replace") as f:
            data = json.load(f)
        if data is None and strict:             # a file of `null` is not "no bytes": it holds no data of the shape asked for
            raise BadFile(f"{path}: not valid JSON data (null)")
        return data
    except FileNotFoundError as e:
        raise Retry(path) from e
    except JSON_ERRORS:
        # abs(): a clock that is wrong, or an archive unpacked with a date in the future, must not mean "touched just now" forever
        if abs(time.time() - mtime(path)) < SETTLE_SECONDS:
            raise Retry(path) from None
        if strict:
            try:
                size = os.path.getsize(longpath(path))
            except FileNotFoundError:           # gone since it was read: no verdict, like the open above
                raise Retry(path) from None
            if size > 0:
                raise BadFile(f"{path}: not valid JSON") from None
        return None


def _is_json(chunk: bytes) -> bool:
    try:
        json.loads(chunk.decode("utf-8-sig", "replace"))
        return True
    except JSON_ERRORS:
        return False


def iter_lines(path: str, start: int = 0, limit: int | None = None, settled: bool = True) -> Iterator[tuple[str, int]]:
    """(line, offset just past it) for every complete line from byte `start` up to `limit`.

    A final line without a newline is delivered only when `settled` (the file has been quiet long enough
    that it is complete). Lines over MAX_LINE_BYTES are skipped, not loaded. CR before LF is removed;
    the very first line loses a UTF-8 BOM. Raises OSError when the file cannot be opened.
    """
    with open(longpath(path), "rb") as f:
        if start:
            f.seek(start)
        pos = start
        while limit is None or pos < limit:
            chunk = f.readline(MAX_LINE_BYTES + 1)
            if not chunk:
                return
            if len(chunk) > MAX_LINE_BYTES:
                # An absurdly long line: drop the rest of it without keeping it in memory.
                while not chunk.endswith(b"\n"):
                    chunk = f.readline(1 << 20)
                    pos += len(chunk)
                    if not chunk:
                        return
                pos += MAX_LINE_BYTES + 1
                continue
            end = pos + len(chunk)
            if limit is not None and end > limit:
                return
            if not chunk.endswith(b"\n"):
                # The last line has no end yet. A quiet file's is delivered only if it is whole JSON: a line cut in
                # half by a writer must not be consumed (the offset would move past it for good).
                if not settled:
                    return
                # (a BOM at the very start is no content: BOM and blanks alone leave nothing to wait for)
                body = chunk[3:] if pos == 0 and chunk.startswith(b"\xef\xbb\xbf") else chunk
                if body.strip():
                    if not _is_json(chunk):
                        return
                # (blanks only: nothing is left to wait for, the cursor moves to the end)
            pos = end
            if chunk.startswith(b"\xef\xbb\xbf") and end - len(chunk) == 0:
                chunk = chunk[3:]
            line = chunk.decode("utf-8", "replace").rstrip("\r\n")
            if line.strip():
                yield line, pos
            else:
                yield "", pos


def json_lines(path: str) -> Iterator[str]:
    """Every non-blank line of a whole text file. A file that cannot be opened raises OSError (see `read_json_file`)."""
    for line, _ in iter_lines(path):
        if line:
            yield line


def mtime(path: str) -> float:
    try:
        return os.path.getmtime(longpath(path))
    except OSError:
        return 0.0


def _always_long(path: str) -> str:
    """`longpath` without the length condition: for a walk, whose paths grow below the root by an unknown amount."""
    if os.name == "nt" and not path.startswith("\\\\?\\"):
        path = os.path.abspath(path)
        return "\\\\?\\UNC\\" + path[2:] if path.startswith("\\\\") else "\\\\?\\" + path
    return path


def walk_files(root: str, match, max_depth: int | None = None) -> list[str]:
    """Every file under `root` whose base name `match(name)` accepts, sorted. A missing root has none.

    On Windows the walk runs on the `\\\\?\\` form of the root whatever its length: a short root with a path of 260
    characters or more below it would otherwise be skipped, without a word (os.walk swallows the error). The paths
    come back written as the caller wrote the root."""
    out: list[str] = []
    shown = root
    root = _always_long(root)
    if not os.path.isdir(root):
        return out
    base_depth = root.rstrip("\\/").count(os.sep)
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        if max_depth is not None and dirpath.rstrip("\\/").count(os.sep) - base_depth >= max_depth:
            dirnames[:] = []
        dirnames.sort()
        if dirpath.startswith(root):
            rel = dirpath[len(root):].lstrip("\\/")
            here = os.path.join(shown, rel) if rel else shown
        else:
            here = dirpath
        for name in sorted(filenames):
            if match(name):
                out.append(os.path.join(here, name))
    return out


def seen_once(paths) -> list[str]:
    """The files among `paths` that exist, each real file once."""
    seen, out = set(), []
    for p in paths:
        try:
            real = os.path.realpath(longpath(p))
        except (OSError, ValueError):
            continue
        if os.path.isfile(longpath(p)) and real not in seen:
            seen.add(real)
            out.append(p)
    return out


def count(d: Any, key: str) -> int:
    """`d[key]` as a count held to 0..FIELD_LIMIT; a fraction is cut off and a boolean counts as 0/1."""
    v = d.get(key) if isinstance(d, dict) else None
    if isinstance(v, bool):
        return int(v)
    return clamp(whole(v))
