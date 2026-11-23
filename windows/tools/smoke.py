"""A headless smoke test of a built TokenBar: runs its console program on the made-up home folder and checks the totals.

    python tools/smoke.py dist/TokenBar/tokenbar-cli.exe

Never starts the tray app or the window. Exit code 0 when the JSON says what the Swift command line says for the same files."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "tests"))
from fixture_home import expected, make_fixture_home  # noqa: E402


def main(exe: str) -> int:
    want = expected()
    with tempfile.TemporaryDirectory() as tmp:
        home = make_fixture_home(os.path.join(tmp, "home"))
        env = dict(os.environ, TOKENBAR_PRICES_PINNED="1", TOKENBAR_OFFLINE="1", TOKENBAR_LANG="en")
        proc = subprocess.run([exe, "--home", home, "--db", os.path.join(tmp, "usage.sqlite"), "--window", "all", "--json"],
                              capture_output=True, text=True, encoding="utf-8", errors="replace", env=env, timeout=300)
        if proc.returncode != 0:
            print(proc.stdout, proc.stderr, file=sys.stderr)
            return 1
        got = json.loads(proc.stdout)
    problems = []
    for key in ("total", "calls", "unpriced", "detected"):
        if got[key] != want[key]:
            problems.append(f"{key}: {got[key]!r} != {want[key]!r}")
    if abs(got["cost"] - want["cost"]) > 1e-9:
        problems.append(f"cost: {got['cost']} != {want['cost']}")
    for name, h in want["harnesses"].items():
        if got["harnesses"].get(name, {}).get("models") != h["models"]:
            problems.append(f"{name}: models differ")
    if problems:
        print("SMOKE FAILED\n" + "\n".join(problems), file=sys.stderr)
        return 1
    print(f"SMOKE OK: {got['total']} tokens, {got['calls']} calls, ${got['cost']:.6f}, {len(got['harnesses'])} tools")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
