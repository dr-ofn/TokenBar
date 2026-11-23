"""The tools TokenBar knows, and where each keeps its data on Windows.

Every root below was checked against the tool's own documentation or source where that was possible (see
docs/HARNESSES.md for the link and for what could not be verified). The list and its order follow the Mac app's catalog.
"""
from __future__ import annotations

import os
from dataclasses import dataclass

from .paths import Env, Root
from .util import longpath

# VS Code and its forks keep user data in %APPDATA%\<product name> (Electron's `appData`).
EDITORS = ["Code", "Code - Insiders", "Cursor", "Windsurf", "VSCodium", "Kiro", "Positron", "Trae", "Antigravity"]


@dataclass(frozen=True)
class Descriptor:
    id: str
    name: str
    prefix: str
    family: str
    roots: tuple
    hue: int = 0
    countable: bool = True


def _ext(ext: str, editors=EDITORS) -> tuple:
    return tuple(Root("appdata", f"{e}/User/globalStorage/{ext}") for e in editors)


def _d(id, name, prefix, family, roots, hue=0, countable=True):
    return Descriptor(id, name, prefix, family, tuple(roots), hue, countable)


BUILTIN: tuple[Descriptor, ...] = (
    _d("claude-code", "Claude Code", "cc", "anthropic-jsonl",
       [Root("home", ".claude", env="CLAUDE_CONFIG_DIR"), Root("home", ".config", env="XDG_CONFIG_HOME", below="claude")], 21),
    _d("codex", "Codex", "cx", "codex-rollout", [Root("home", ".codex", env="CODEX_HOME")], 158),
    _d("oh-my-pi", "oh-my-pi", "omp", "omp-jsonl", [Root("home", ".omp")], 270),
    _d("qwen-code", "Qwen Code", "qwen", "qwen-usage", [Root("home", ".qwen", env="QWEN_HOME")], 195),
    _d("kimi-code", "Kimi Code", "kimi", "kimi-wire", [Root("home", ".kimi-code", env="KIMI_CODE_HOME")], 46),
    _d("devin", "Devin", "devin", "devin-transcripts", [Root("home", ".local/share/devin")], 88),
    _d("antigravity", "Antigravity", "ag", "antigravity-sqlite", [Root("home", ".gemini/antigravity-cli")], 352),
    _d("opencode", "opencode", "oc", "opencode-sqlite", [Root("home", ".local/share", env="XDG_DATA_HOME", below="opencode")], 224),
    # `projects.json` of Crush's global data folder names each project's own data folder.
    _d("crush", "Crush", "crush", "crush-sqlite",
       [Root("local", "", env="XDG_DATA_HOME", below="crush"), Root("local", "crush", env="CRUSH_GLOBAL_DATA")], 290),
    _d("goose", "Goose", "goose", "goose-sqlite",
       [Root("appdata", "Block/goose/data/sessions"), Root("home", ".local/share/goose/sessions"),
        Root("home", ".local/share/Block/goose/sessions"), Root("appdata", "Block/goose/data", env="GOOSE_PATH_ROOT")], 135),
    _d("factory-droid", "Factory Droid", "droid", "droid-settings", [Root("home", ".factory")], 62),
    _d("amp", "Amp", "amp", "amp-threads", [Root("home", ".local/share/amp", env="AMP_DATA_DIR")], 5),
    _d("openhands", "OpenHands", "oh", "openhands-state",
       [Root("home", ".openhands/conversations", env="OPENHANDS_CONVERSATIONS_DIR"),
        Root("home", ".openhands", env="OPENHANDS_PERSISTENCE_DIR", below="conversations")], 175),
    _d("warp", "Warp", "warp", "not-countable", [Root("local", "warp")], 210, False),
    _d("amazon-q", "Amazon Q", "amq", "not-countable", [Root("local", "amazon-q")], 35, False),
    # GEMINI_CLI_HOME replaces the home folder: the data is in <GEMINI_CLI_HOME>\.gemini\tmp.
    _d("gemini-cli", "Gemini CLI", "gem", "gemini-chats", [Root("home", "", env="GEMINI_CLI_HOME", below=".gemini/tmp")], 217),
    _d("pi", "Pi", "pi", "pi-jsonl", [Root("home", ".pi/agent", env="PI_CODING_AGENT_DIR")], 300),
    _d("copilot-cli", "GitHub Copilot CLI", "cop", "copilot-events", [Root("home", ".copilot", env="COPILOT_HOME")], 262),
    _d("junie", "Junie", "jun", "junie-events", [Root("home", ".junie")], 140),
    _d("codebuff", "Codebuff", "cbuf", "codebuff-chats",
       [Root("home", ".config/manicode", env="CODEBUFF_DATA_DIR"), Root("home", ".config/manicode-dev", env="CODEBUFF_DATA_DIR"),
        Root("home", ".config/manicode-staging", env="CODEBUFF_DATA_DIR")], 120),
    _d("mistral-vibe", "Mistral Vibe", "vibe", "vibe-sessions", [Root("home", ".vibe", env="VIBE_HOME")], 28),
    _d("augment", "Augment", "aug", "augment-sessions", [Root("home", ".augment")], 175),
    # Qwen Code's newer chat files: read only where Qwen's own usage files are absent.
    _d("qwen-code", "Qwen Code", "qwenc", "qwen-chats", [Root("home", ".qwen", env="QWEN_HOME")], 195),
    _d("cline", "Cline", "cline", "cline-tasks", list(_ext("saoudrizwan.claude-dev")) + [Root("home", ".cline/data")], 120),
    _d("roo-code", "Roo Code", "roo", "roo-tasks", _ext("rooveterinaryinc.roo-cline"), 60),
    _d("kilo-code", "Kilo Code", "kilocode", "roo-tasks", _ext("kilocode.kilo-code"), 280),
    _d("kilo-code", "Kilo Code", "kilo", "opencode-sqlite", [Root("home", ".local/share", env="XDG_DATA_HOME", below="kilo")], 280),
    _d("copilot-chat", "Copilot Chat", "copilot-chat", "copilot-chat",
       [Root("appdata", f"{e}/{b}") for e in ("Code", "Code - Insiders")
        for b in ("User/workspaceStorage", "User/globalStorage/emptyWindowChatSessions")], 240),
    _d("continue", "Continue", "continue", "continue-tokens", [Root("home", ".continue", env="CONTINUE_GLOBAL_DIR")], 175),
    _d("zed", "Zed", "zed", "zed-threads", [Root("local", "Zed")], 35),
    # Found, never counted: their logs hold no token counts.
    _d("kiro", "Kiro", "kiro", "not-countable", [Root("home", ".kiro"), Root("local", "kiro-cli"), Root("appdata", "Kiro")], 305, False),
    _d("cursor", "Cursor", "cursor", "not-countable", [Root("appdata", "Cursor"), Root("home", ".cursor")], 210, False),
    _d("windsurf", "Windsurf", "windsurf", "not-countable", [Root("home", ".codeium/windsurf"), Root("appdata", "Windsurf")], 150, False),
    _d("trae", "Trae", "trae", "not-countable", [Root("appdata", "Trae")], 335, False),
)

HARNESS_OF_PREFIX = {d.prefix: d.id for d in BUILTIN}
NAMES = {d.id: d.name for d in BUILTIN}
HUES = {d.id: d.hue for d in BUILTIN}


def harness_of_key(key: str) -> str:
    prefix = key.split(":", 1)[0]
    return HARNESS_OF_PREFIX.get(prefix, prefix)


def harness_name(hid: str) -> str:
    return NAMES.get(hid, hid)


class Catalog:
    """The descriptors resolved for one `Env`."""

    def __init__(self, env: Env, descriptors=BUILTIN):
        self.env = env
        self.descriptors = tuple(descriptors)

    def roots_of(self, d: Descriptor) -> list[str]:
        seen, out = set(), []
        for r in d.roots:
            p = r.resolve(self.env)
            key = os.path.normcase(os.path.normpath(p))
            if key not in seen:
                seen.add(key)
                out.append(p)
        return out

    def detected(self) -> list[str]:
        """Tool ids whose folder exists, in catalog order, each once."""
        seen, out = set(), []
        for d in self.descriptors:
            if d.id not in seen and any(os.path.exists(longpath(p)) for p in self.roots_of(d)):
                seen.add(d.id)
                out.append(d.id)
        return out

    def not_countable(self) -> list[str]:
        seen, out = set(), []
        for d in self.descriptors:
            if not d.countable and d.id not in seen and any(os.path.exists(longpath(p)) for p in self.roots_of(d)):
                seen.add(d.id)
                out.append(d.id)
        return out
