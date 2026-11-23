#!/bin/bash
# Pre-release audit, run first by scripts/release.sh (and usable alone): stops a release that would ship the wrong thing.
#   scripts/release-audit.sh VERSION [ROOT]
# Checks, all of them, then exits 1 if any failed:
#   - the git work tree is clean (nothing modified, staged or untracked): the zip is built from the work tree, the tag
#     names a commit, and the two must be the same code;
#   - the tag v VERSION does not exist yet;
#   - HEAD is on a remote branch (it has been pushed; judged from the remote-tracking refs, no network is used);
#   - VERSION (the file), windows/tokenbar/__init__.py and windows/pyproject.toml all say VERSION, CHANGELOG.md has a
#     "## VERSION" heading, and Resources/Info.plist is either the __VERSION__ placeholder or VERSION.
# A pre-release VERSION (contains "-", e.g. 9.0.1-rc1) may differ in the version files and lack a CHANGELOG heading;
# .github/workflows/windows.yml accepts such a tag the same way (any other tag must equal v + tokenbar.__version__).
set -uo pipefail
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "usage: scripts/release-audit.sh VERSION [ROOT]" >&2
  exit 2
fi
ROOT="${2:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 2
PRERELEASE=0; [[ "$VERSION" == *-* ]] && PRERELEASE=1
bad=0
fail() { echo "release audit: $1" >&2; bad=1; }

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  dirty="$(git status --porcelain --untracked-files=normal 2>/dev/null)"
  status_rc=$?
  if [ "$status_rc" -ne 0 ]; then
    # An unreadable index or a broken repository would leave $dirty empty, and an empty answer would read as "clean".
    fail "git status failed (exit $status_rc): the work tree cannot be judged clean"
  elif [ -n "$dirty" ]; then
    fail "the git work tree is not clean (commit, stash or remove these first):"
    echo "$dirty" | head -10 >&2
  fi
  if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null 2>&1; then
    fail "the tag v$VERSION already exists (a release is made once; pick a new version)"
  fi
  if [ -z "$(git branch -r --contains HEAD 2>/dev/null)" ]; then
    fail "HEAD is not on any remote branch: push it first (judged from the last fetch; run 'git fetch' if it was pushed from elsewhere)"
  fi
else
  fail "$ROOT is not a git work tree"
fi

trim() { tr -d '[:space:]'; }
from_file="$(trim < VERSION 2>/dev/null)"
from_windows="$(sed -n 's/^__version__ *= *"\(.*\)".*/\1/p' windows/tokenbar/__init__.py 2>/dev/null | head -1)"
from_toml="$(sed -n 's/^version *= *"\(.*\)".*/\1/p' windows/pyproject.toml 2>/dev/null | head -1)"
plist="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist 2>/dev/null \
  || sed -n '/CFBundleShortVersionString/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' Resources/Info.plist 2>/dev/null | head -1)"

check_version() {   # name, value
  if [ "$2" != "$VERSION" ]; then
    if [ "$PRERELEASE" = 1 ]; then
      echo "release audit: note: $1 says '${2:-?}', not $VERSION (pre-release: allowed)" >&2
    else
      fail "$1 says '${2:-?}', the release is $VERSION"
    fi
  fi
}
check_version "VERSION" "$from_file"
check_version "windows/tokenbar/__init__.py" "$from_windows"
check_version "windows/pyproject.toml" "$from_toml"
if [ -z "$plist" ]; then
  # Missing or damaged: an empty answer must not pass for "the placeholder".
  fail "Resources/Info.plist is missing or has no CFBundleShortVersionString"
elif [ "$plist" != "__VERSION__" ]; then
  check_version "Resources/Info.plist" "$plist"
fi

if ! awk -v v="$VERSION" '/^## / { split($0, h, " "); if (h[2] == v) found = 1 } END { exit !found }' CHANGELOG.md 2>/dev/null; then
  if [ "$PRERELEASE" = 1 ]; then
    echo "release audit: note: CHANGELOG.md has no '## $VERSION' heading (pre-release: allowed)" >&2
  else
    fail "CHANGELOG.md has no '## $VERSION' heading"
  fi
fi

if [ "$bad" -ne 0 ]; then
  echo "release audit: FAILED, nothing was built" >&2
  exit 1
fi
echo "release audit: OK ($VERSION)"
