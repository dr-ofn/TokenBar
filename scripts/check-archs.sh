#!/bin/bash
# Stops a release whose app is not universal. The cask and the README say "universal", so the binary of a release zip
# must hold exactly arm64 and x86_64.
#   scripts/check-archs.sh BINARY [EXPECTED]      EXPECTED defaults to "arm64 x86_64"; the order of the words does not matter
# Exit 0 when `lipo -archs BINARY` names exactly the expected architectures, 1 when it does not, 2 when it cannot be asked.
set -uo pipefail
BIN="${1:-}"
EXPECTED="${2:-arm64 x86_64}"
if [ -z "$BIN" ] || [ ! -f "$BIN" ]; then
  echo "check-archs: no such binary: ${BIN:-<none>}" >&2
  exit 2
fi
if ! ARCHS="$(lipo -archs "$BIN" 2>/dev/null)"; then
  echo "check-archs: lipo could not read $BIN" >&2
  exit 2
fi
norm() { tr ' ' '\n' | sed '/^$/d' | sort | paste -sd' ' -; }
have="$(printf '%s' "$ARCHS" | norm)"
want="$(printf '%s' "$EXPECTED" | norm)"
if [ "$have" != "$want" ]; then
  echo "check-archs: $BIN has '$have', a release needs '$want'" >&2
  exit 1
fi
echo "archs: $have"
