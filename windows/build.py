"""Builds TokenBar for Windows: `python build.py` -> dist/TokenBar/ and dist/TokenBar-Windows-<version>.zip.

Run it on Windows with the dev requirements installed (`pip install -r requirements-dev.txt`). Steps: draw the icon,
run PyInstaller on TokenBar.spec, copy the licence and the READMEs next to the exe, zip the folder.
`python build.py --zip-only` only zips an existing dist/TokenBar (what the tests use)."""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tokenbar import __version__  # noqa: E402

DIST = os.path.join(HERE, "dist")
APP = os.path.join(DIST, "TokenBar")
# What the READMEs link to by a relative path (README.md <-> README.tr.md, docs/HARNESSES.md): all of it must be in the zip.
# Anything above this folder (the Mac README) is linked by its full GitHub URL: `../README.md` leads nowhere once unzipped.
EXTRAS = ["README.md", "README.tr.md", "LICENSE", os.path.join("docs", "HARNESSES.md")]


def make_icon() -> str:
    from tokenbar.gui.icon import make_ico_bytes
    path = os.path.join(HERE, "build", "tokenbar.ico")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(make_ico_bytes())
    return path


def zip_name() -> str:
    return os.path.join(DIST, f"TokenBar-Windows-{__version__}.zip")


def make_zip(app: str = APP, out: str | None = None) -> str:
    out = out or zip_name()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for folder, _, files in os.walk(app):
            for name in files:
                full = os.path.join(folder, name)
                z.write(full, os.path.join("TokenBar", os.path.relpath(full, app)))
    return out


def copy_extras(app: str = APP, source: str = HERE) -> list[str]:
    """The licence and the documents next to the exe (the README's links must work inside the zip). Returns what was copied."""
    copied = []
    for name in EXTRAS:
        src = os.path.join(source, name)
        if os.path.exists(src):
            dst = os.path.join(app, name)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy(src, dst)
            copied.append(name)
    return copied


def main(argv: list[str]) -> int:
    if "--zip-only" not in argv:
        make_icon()
        subprocess.run([sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean", "--distpath", DIST,
                        "--workpath", os.path.join(HERE, "build", "pyi"), "TokenBar.spec"], cwd=HERE, check=True)
    copy_extras()
    print(make_zip())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
