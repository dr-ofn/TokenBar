"""A made-up Windows home folder for the tests.

`fixture/home` holds the same files the Mac app's check fixture holds (made-up model calls of 25 tools, one file each
in the tool's own format), moved to where each tool keeps them on Windows (AppData\\Roaming, AppData\\Local, ...).
`data/swift-fixture-expected.json` is what the Swift command line counts in those files: the totals the Windows
version must reproduce exactly.
"""
import json
import os
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(HERE, "fixture", "home")
EXPECTED = os.path.join(HERE, "data", "swift-fixture-expected.json")


def make_fixture_home(dest: str) -> str:
    """Copies the fixture to `dest` (which must not exist) and returns it."""
    shutil.copytree(FIXTURE, dest)
    # Crush's projects.json holds an absolute project path: written for wherever the copy lives.
    path = os.path.join(dest, "AppData", "Local", "crush", "projects.json")
    with open(path, encoding="utf-8") as f:
        text = f.read()
    with open(path, "w", encoding="utf-8") as f:
        f.write(text.replace("@HOME@", json.dumps(dest)[1:-1]))
    # Folders that exist without a file in them (a tool that was installed but never used).
    for folder in (".codeium/windsurf", "AppData/Roaming/Trae"):
        os.makedirs(os.path.join(dest, *folder.split("/")), exist_ok=True)
    return dest


def expected() -> dict:
    with open(EXPECTED, encoding="utf-8") as f:
        return json.load(f)
