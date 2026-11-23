#!/bin/bash
# Replaces the placeholder GitHub owner "OWNER" (as in OWNER/TokenBar, OWNER/tap) in every tracked text file,
# and removes the "set-owner" note at the top of the READMEs.
#   scripts/set-owner.sh YOUR_GITHUB_NAME          OWNER -> YOUR_GITHUB_NAME
#   scripts/set-owner.sh NEW_NAME OLD_NAME         change an owner that was set earlier
set -euo pipefail
cd "$(dirname "$0")/.."

NEW="${1:-}"
OLD="${2:-OWNER}"
if [ -z "$NEW" ] || [ "$#" -gt 2 ]; then
  echo "usage: scripts/set-owner.sh GITHUB_OWNER [CURRENT_OWNER (default: OWNER)]" >&2
  exit 2
fi
valid='^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$'
if ! [[ "$NEW" =~ $valid ]] || ! [[ "$OLD" =~ $valid ]]; then
  echo "not a valid GitHub user or organization name: $NEW / $OLD" >&2
  exit 2
fi

count=0
while IFS= read -r f; do
  [ "$f" = "scripts/set-owner.sh" ] && continue
  [ -f "$f" ] || continue
  grep -Iq . "$f" || continue                 # skip binary and empty files
  if grep -q "$OLD/" "$f" || grep -q "set-owner:begin" "$f"; then
    OLD="$OLD" NEW="$NEW" perl -0pi -e '
      s{<!-- set-owner:begin -->.*?<!-- set-owner:end -->\n*}{}s;
      s{(?<![\w.-])\Q$ENV{OLD}\E/}{$ENV{NEW}/}g;
    ' "$f"
    count=$((count + 1))
    echo "updated $f"
  fi
done < <(git ls-files)

echo "==> $count file(s) updated: $OLD/ -> $NEW/"
