import os

import pytest

from tokenbar.catalog import BUILTIN, Catalog, harness_of_key
from tokenbar.paths import Env, Root

# A home folder that is absolute on the OS running the tests (on Windows it gets a drive letter).
HOME = os.path.abspath(os.path.join(os.sep, "u", "me"))


def test_default_windows_folders_hang_off_the_home_folder():
    env = Env.from_os({"USERPROFILE": os.path.join(os.sep, "u", "me")})
    assert env.home == os.path.join(os.sep, "u", "me")
    assert env.appdata == os.path.join(env.home, "AppData", "Roaming")
    assert env.localappdata == os.path.join(env.home, "AppData", "Local")


def test_appdata_variables_win_when_set():
    env = Env.from_os({"USERPROFILE": HOME, "APPDATA": "/x/roam", "LOCALAPPDATA": "/x/loc"})
    assert env.db_path() == os.path.join("/x/loc", "TokenBar", "usage.sqlite")
    assert env.cache_dir() == os.path.join("/x/loc", "TokenBar", "cache")
    assert env.aliases_path() == os.path.join("/x/roam", "TokenBar", "model-aliases.json")


def test_tool_variables_move_a_folder_only_for_the_real_home(tmp_path):
    moved = str(tmp_path / "elsewhere")
    real = Env.from_os({"USERPROFILE": HOME, "CODEX_HOME": moved, "CLAUDE_CONFIG_DIR": "relative/dir"})
    assert Root("home", ".codex", env="CODEX_HOME").resolve(real) == moved
    assert Root("home", ".claude", env="CLAUDE_CONFIG_DIR").resolve(real) == os.path.join(HOME, ".claude")   # relative: ignored
    other = Env.for_home(HOME)
    other.environ["CODEX_HOME"] = moved
    assert Root("home", ".codex", env="CODEX_HOME").resolve(other) == os.path.join(HOME, ".codex")


def test_tilde_in_a_variable_means_the_home_folder():
    env = Env.from_os({"USERPROFILE": HOME, "AMP_DATA_DIR": "~/amp-data"})
    assert Root("home", ".local/share/amp", env="AMP_DATA_DIR").resolve(env) == os.path.join(HOME, "amp-data")


def test_the_windows_locations_of_the_tools():
    env = Env.for_home(HOME)
    cat = Catalog(env)
    by = {}
    for d in BUILTIN:
        by.setdefault(d.id, []).extend(cat.roots_of(d))

    def has(tool, *parts):
        return os.path.join(*parts) in by[tool]
    assert has("claude-code", HOME, ".claude")
    assert has("codex", HOME, ".codex")
    assert has("opencode", HOME, ".local", "share", "opencode")
    assert has("cline", HOME, "AppData", "Roaming", "Code", "User", "globalStorage", "saoudrizwan.claude-dev")
    assert has("copilot-chat", HOME, "AppData", "Roaming", "Code - Insiders", "User", "workspaceStorage")
    assert has("zed", HOME, "AppData", "Local", "Zed")
    assert has("crush", HOME, "AppData", "Local", "crush")
    assert has("goose", HOME, "AppData", "Roaming", "Block", "goose", "data", "sessions")
    assert has("warp", HOME, "AppData", "Local", "warp")
    assert has("cursor", HOME, "AppData", "Roaming", "Cursor")


def test_every_family_has_a_reader_and_every_key_prefix_a_tool():
    from tokenbar.readers.base import REGISTRY
    import tokenbar.scanner  # noqa: F401  (registers the readers)
    for d in BUILTIN:
        if d.countable:
            assert d.family in REGISTRY, d.family
    assert harness_of_key("cc:abc") == "claude-code"
    assert harness_of_key("kilocode:t:1") == "kilo-code" and harness_of_key("kilo:x") == "kilo-code"
    assert harness_of_key("somethingnew:1") == "somethingnew"


def test_detection_lists_only_what_exists(tmp_path):
    env = Env.for_home(str(tmp_path))
    assert Catalog(env).detected() == []
    os.makedirs(tmp_path / ".codex")
    os.makedirs(tmp_path / "AppData" / "Roaming" / "Cursor")
    cat = Catalog(env)
    assert cat.detected() == ["codex", "cursor"] and cat.not_countable() == ["cursor"]


def test_two_roots_that_resolve_to_one_folder_are_read_once():
    env = Env.from_os({"USERPROFILE": HOME, "CODEBUFF_DATA_DIR": "/data/cb"})
    d = next(x for x in BUILTIN if x.id == "codebuff")
    assert Catalog(env).roots_of(d) == ["/data/cb"]
