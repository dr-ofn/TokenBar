#!/bin/bash
# Builds a release artifact. Uploads and pushes NOTHING; it prints the command to publish at the end.
#   scripts/release.sh VERSION            (a release is always a universal build: arm64 + x86_64; --universal is accepted and means the same)
# Steps: scripts/check.sh -> scripts/build-app.sh -> dist/TokenBar-VERSION.zip (+ .sha256) -> dist/RELEASE_NOTES.md
# First scripts/release-audit.sh: clean git tree, tag not made yet (here or on origin), HEAD pushed, VERSION = Windows version = X.Y.Z.
# After the build scripts/check-archs.sh stops the release when the app is not exactly arm64 + x86_64 (the cask and the README
# say universal), and looks at the unpacked zip again.
# VERSION is stamped into the app (Info.plist) and must have a "## VERSION" section in CHANGELOG.md.
# The version rule (the audit and windows.yml apply the same): the tag is vX.Y.Z or vX.Y.Z-pre and the version files say X.Y.Z.
# A pre-release VERSION (contains "-", e.g. 9.0.0-test) may lack a CHANGELOG section; it then gets a placeholder note.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VERSION="${1:-}"
# Universal always: a release zip that is arm64 only would break the cask and the README's promise. Local builds
# for development are scripts/build-app.sh (arm64 unless --universal).
UNIVERSAL=(--universal)
if [ -z "$VERSION" ] || [[ "$VERSION" == -* ]]; then
  echo "usage: scripts/release.sh VERSION   (example: scripts/release.sh 9.0.0; always a universal build)" >&2
  exit 2
fi
shift
for a in "$@"; do
  case "$a" in
    --universal) ;;                      # the default; accepted for the commands people already have
    *) echo "unknown option $a" >&2; exit 2 ;;
  esac
done
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
  echo "VERSION must look like 1.2.3 or 1.2.3-rc1, got: $VERSION" >&2
  exit 2
fi
PRERELEASE=0; [[ "$VERSION" == *-* ]] && PRERELEASE=1

# Before anything is built: clean pushed tree, no tag yet, VERSION / Windows version / CHANGELOG all say $VERSION.
# One audit (scripts/release-audit.sh); it names every problem, and a failed audit stops the release.
scripts/release-audit.sh "$VERSION" || exit 1

# Release notes first: fail early, before a slow build, when a real release has no changelog entry.
mkdir -p dist
NOTES="dist/RELEASE_NOTES.md"
awk -v v="$VERSION" '
  /^## / { if (on) exit; split($0, h, " "); if (h[2] == v) { on = 1; next } }
  on { print }
' CHANGELOG.md | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "$NOTES"
if [ ! -s "$NOTES" ]; then
  if [ "$PRERELEASE" = 1 ]; then
    echo "warning: CHANGELOG.md has no '## $VERSION' section; writing a placeholder note (pre-release)." >&2
    printf 'Pre-release %s. No changelog entry.\n' "$VERSION" > "$NOTES"
  else
    echo "error: CHANGELOG.md has no '## $VERSION' section. Add it, then rerun." >&2
    exit 1
  fi
fi

echo "==> scripts/check.sh"
scripts/check.sh

echo "==> scripts/build-app.sh ${UNIVERSAL[*]:-}"
TOKENBAR_VERSION="$VERSION" scripts/build-app.sh --no-test ${UNIVERSAL[@]+"${UNIVERSAL[@]}"}

echo "==> universal? (the cask and the README say so)"
scripts/check-archs.sh dist/TokenBar.app/Contents/MacOS/TokenBar || { echo "error: the app is not universal: nothing was zipped" >&2; exit 1; }

ZIP="dist/TokenBar-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
echo "==> $ZIP"
ditto -c -k --keepParent dist/TokenBar.app "$ZIP"
( cd dist && shasum -a 256 "TokenBar-$VERSION.zip" > "TokenBar-$VERSION.zip.sha256" )

echo "==> verify the zip unpacks to a valid bundle"
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
ditto -x -k "$ZIP" "$CHECK_DIR"
codesign --verify --strict "$CHECK_DIR/TokenBar.app"
[ "$(plutil -extract CFBundleShortVersionString raw "$CHECK_DIR/TokenBar.app/Contents/Info.plist")" = "$VERSION" ]
scripts/check-archs.sh "$CHECK_DIR/TokenBar.app/Contents/MacOS/TokenBar" >/dev/null

SHA="$(cut -d' ' -f1 "$ZIP.sha256")"
ARCHS="$(lipo -archs dist/TokenBar.app/Contents/MacOS/TokenBar)"
echo
echo "version : $VERSION"
echo "archs   : $ARCHS"
echo "zip     : $ZIP"
echo "sha256  : $SHA"
echo "notes   : $NOTES"
echo
echo "Nothing was pushed or uploaded. To publish, review the notes, then run:"
echo
PRE=""; [ "$PRERELEASE" = 1 ] && PRE=" --prerelease"
echo "  git tag v$VERSION && git push origin v$VERSION"
echo
echo "The tag also starts .github/workflows/windows.yml, which adds the Windows zip (and its .sha256) to the release of"
echo "that tag and makes the release itself if it is not there yet. So run this, which works whichever comes first:"
echo
echo "  if gh release view v$VERSION --repo dr-ofn/TokenBar >/dev/null 2>&1; then"
echo "    gh release upload v$VERSION $ZIP $ZIP.sha256 --repo dr-ofn/TokenBar --clobber \\"
echo "      && gh release edit v$VERSION --repo dr-ofn/TokenBar --title \"TokenBar $VERSION\" --notes-file $NOTES$PRE"
echo "  else"
echo "    gh release create v$VERSION $ZIP $ZIP.sha256 --repo dr-ofn/TokenBar --title \"TokenBar $VERSION\" --notes-file $NOTES$PRE"
echo "  fi"
echo
echo "Then update the Homebrew cask (packaging/homebrew/tokenbar.rb): version \"$VERSION\", sha256 \"$SHA\"."
