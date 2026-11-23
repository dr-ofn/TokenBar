#!/bin/bash
# Builds dist/TokenBar.app (release, ad-hoc signed; arm64 by default).
#   scripts/build-app.sh             build + run tests (veri + arayüz değişmezleri)
#   scripts/build-app.sh --install   also copy to ~/Applications and (re)launch
#   scripts/build-app.sh --no-test   skip the test suite
#   scripts/build-app.sh --universal build a universal binary (arm64 + x86_64)
# Not Developer-ID signed or notarized: see README "Install" for the Gatekeeper steps.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
# TOKENBAR_VERSION overrides the VERSION file (release.sh uses it for test builds).
VERSION="${TOKENBAR_VERSION:-$(cat VERSION)}"
APP="$ROOT/dist/TokenBar.app"
INSTALL=0
TESTS=1
ARCH_FLAGS=()
KIND=arm64
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw Resources/Info.plist)"
for a in "$@"; do
  case "$a" in
    --install) INSTALL=1 ;;
    --no-test) TESTS=0 ;;
    --universal) ARCH_FLAGS=(--arch arm64 --arch x86_64); KIND=universal ;;
    *) echo "unknown option $a" >&2; exit 2 ;;
  esac
done

if [ "$TESTS" = 1 ]; then
  echo "==> tests"
  # Prices pinned to the embedded snapshot: this Mac's price cache and model-aliases.json must not change a check.
  export TOKENBAR_PRICES_PINNED=1
  swift run TokenChecks
  swift run UISnapshot selfcheck
fi

echo "==> swift build (release, $KIND)"
swift build -c release --product TokenBar ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release --product TokenBar ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/TokenBar"

echo "==> bundle $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TokenBar"
# The debug map of a release build names every source and object file by its full path,
# which includes the builder's home folder. Strip it, then make sure no such path is left.
strip -S -x "$APP/Contents/MacOS/TokenBar" 2>/dev/null
if LC_ALL=C grep -a -q -F -e "$PWD/" -e "$HOME/" "$APP/Contents/MacOS/TokenBar"; then
  echo "error: the app binary still names a path on this machine" >&2
  exit 1
fi
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - --options runtime --timestamp=none "$APP" 2>/dev/null
codesign --verify --strict "$APP"
echo "==> built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/TokenBar"))"

if [ "$INSTALL" = 1 ]; then
  DEST="$HOME/Applications/TokenBar.app"
  mkdir -p "$HOME/Applications"
  # Quit by bundle id: a process name can match someone else's job.
  osascript -e 'tell application id "'"$BUNDLE_ID"'" to quit' 2>/dev/null || true
  sleep 1
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "==> installed and launched $DEST"
fi
