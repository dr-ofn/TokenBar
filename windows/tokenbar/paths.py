"""Where things live on this PC.

`Env` is the only place that knows about USERPROFILE, APPDATA and LOCALAPPDATA, so the readers are tested on any
OS by pointing an `Env` at a made-up folder. The variables that move a tool's folder (`CLAUDE_CONFIG_DIR`,
`CODEX_HOME`, `XDG_DATA_HOME`, ...) are followed only for the real home, never for a home passed to `--home`:
a scan of a backup or a test folder must not wander into the real one.
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field


def _clean(path: str) -> str:
    stripped = path.rstrip("\\/")
    # A drive root ("C:\") or "/" keeps its separator.
    return stripped if stripped and not stripped.endswith(":") else path


@dataclass
class Env:
    home: str
    appdata: str
    localappdata: str
    environ: dict = field(default_factory=dict)
    real: bool = False

    @classmethod
    def from_os(cls, environ: dict | None = None) -> "Env":
        """The running user's folders. USERPROFILE, APPDATA and LOCALAPPDATA win when set (tests point them at a
        made-up folder); otherwise the Windows defaults below the home folder."""
        e = dict(os.environ if environ is None else environ)
        home = e.get("USERPROFILE") or e.get("HOME") or os.path.expanduser("~")
        appdata = e.get("APPDATA") or os.path.join(home, "AppData", "Roaming")
        local = e.get("LOCALAPPDATA") or os.path.join(home, "AppData", "Local")
        return cls(_clean(home), _clean(appdata), _clean(local), e, True)

    @classmethod
    def for_home(cls, home: str) -> "Env":
        """Another home folder (`--home`): its AppData folders sit below it and no variable is followed."""
        home = _clean(os.path.abspath(home))
        return cls(home, os.path.join(home, "AppData", "Roaming"), os.path.join(home, "AppData", "Local"), {}, False)

    def base(self, kind: str) -> str:
        return {"home": self.home, "appdata": self.appdata, "local": self.localappdata}[kind]

    def var(self, name: str | None) -> str | None:
        """A non-empty variable that moves a tool's folder; `~` is the home folder. Relative values are ignored."""
        if not name or not self.real:
            return None
        v = (self.environ.get(name) or "").strip()
        if not v:
            return None
        if v == "~":
            return self.home
        if v.startswith(("~/", "~\\")):
            return os.path.join(self.home, *v[2:].replace("\\", "/").split("/"))
        return v if os.path.isabs(v) else None

    # Where TokenBar keeps its own files.
    def data_dir(self) -> str:
        return os.path.join(self.localappdata, "TokenBar")

    def config_dir(self) -> str:
        return os.path.join(self.appdata, "TokenBar")

    def db_path(self) -> str:
        return os.path.join(self.data_dir(), "usage.sqlite")

    def cache_dir(self) -> str:
        return os.path.join(self.data_dir(), "cache")

    def aliases_path(self) -> str:
        return os.path.join(self.config_dir(), "model-aliases.json")

    def settings_path(self) -> str:
        return os.path.join(self.config_dir(), "settings.json")


@dataclass(frozen=True)
class Root:
    """One place a tool keeps data: `rel` (posix-style) below `base` (home, appdata or local), replaced by the
    variable `env` when that is set, plus a fixed `below`."""
    base: str
    rel: str = ""
    env: str | None = None
    below: str = ""

    def resolve(self, e: Env) -> str:
        path = e.var(self.env) or os.path.join(e.base(self.base), *[p for p in self.rel.split("/") if p])
        path = _clean(path)
        return os.path.join(path, *[p for p in self.below.split("/") if p]) if self.below else path
