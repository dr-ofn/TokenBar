#!/bin/bash
# Pre-release audit, run first by scripts/release.sh (and usable alone): stops a release that would ship the wrong thing.
#   scripts/release-audit.sh VERSION [ROOT]
# Checks, all of them, then exits 1 if any failed:
#   - the git work tree is clean (nothing modified, staged or untracked): the zip is built from the work tree, the tag
#     names a commit, and the two must be the same code;
#   - the tag v VERSION does not exist yet, here or on origin (git ls-remote; when origin cannot be reached the audit FAILS:
#     a release is made once, and that cannot be vouched for without looking at origin);
#   - HEAD is on a remote branch (it has been pushed; judged from the remote-tracking refs, no network is used);
#   - VERSION (the file), windows/tokenbar/__init__.py and windows/pyproject.toml all say VERSION, CHANGELOG.md has a
#     "## VERSION" heading, and Resources/Info.plist is either the __VERSION__ placeholder or VERSION.
# One rule for the version, the same in scripts/release.sh and .github/workflows/windows.yml: the tag is vX.Y.Z or
# vX.Y.Z-pre, and the files (VERSION, windows/tokenbar/__init__.py, windows/pyproject.toml, Info.plist) say X.Y.Z. A
# pre-release (contains "-", e.g. 9.0.1-rc1) differs from a release in two ways only: it may lack a CHANGELOG heading, and
# its zips are named from the tag (TokenBar-9.0.1-rc1.zip, TokenBar-Windows-9.0.1-rc1.zip).
set -uo pipefail
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "usage: scripts/release-audit.sh VERSION [ROOT]" >&2
  exit 2
fi
ROOT="${2:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 2
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
  echo "release audit: VERSION must be X.Y.Z or X.Y.Z-pre (letters, digits and '.' after the dash), got: $VERSION" >&2
  exit 2
fi
BASE="${VERSION%%-*}"            # X.Y.Z: what every version file says, whatever the suffix of the tag
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
  # The tag may exist on origin only (made and pushed from another clone): the local refs would not show it.
  # stderr is kept apart from the tag list: an SSH or HTTP warning on a reachable origin is not a tag.
  remote_err_file="$(mktemp 2>/dev/null)" || remote_err_file=/dev/null
  remote_tags="$(GIT_TERMINAL_PROMPT=0 git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 ls-remote --tags origin "refs/tags/v$VERSION" 2>"$remote_err_file")"
  remote_rc=$?
  remote_err="$(head -c 2000 "$remote_err_file" 2>/dev/null)"
  [ "$remote_err_file" = /dev/null ] || rm -f "$remote_err_file"
  if [ "$remote_rc" -ne 0 ]; then
    fail "could not look at origin for the tag v$VERSION (git ls-remote exit $remote_rc): the remote tag was NOT checked, so the audit cannot pass (reach origin and run it again)"
    [ -z "$remote_err" ] || echo "$remote_err" | head -5 | sed 's/^/release audit:   git said: /' >&2
  elif [ -n "$remote_tags" ]; then
    fail "the tag v$VERSION already exists on origin (a release is made once; pick a new version)"
  elif [ -n "$remote_err" ]; then
    echo "release audit: note: origin answered with a warning (the tag list is empty): $(echo "$remote_err" | head -3)" >&2
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

check_version() {   # name, value: the files say X.Y.Z, also for a pre-release X.Y.Z-pre
  if [ "$2" != "$BASE" ]; then
    fail "$1 says '${2:-?}', the release is $VERSION (the files must say $BASE)"
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
