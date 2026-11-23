#!/bin/bash
# Tek komutlu doğrulama: derleme, birim kontrolleri, CLI↔oracle eşitliği, arayüz değişmezleri.
# Kurmaca ev birebir tutmalı. Canlı evde loglar iki okuma arasında büyür, payı aşağıda.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
live_tolerance=0.005
# Prices pinned to the embedded snapshot and the hand-made tables (no cache file, alias file or network), so the CLI,
# the oracle and TokenChecks price the same on every machine.
export TOKENBAR_PRICES_PINNED=1
fixture="$PWD/.build/release/tokenbar-fixture"

say_fail() { echo "BAŞARISIZ: $1"; fail=1; }

echo "== derleme =="
swift build -c release 2>&1 | tail -1 | grep -q 'Build complete' || say_fail derleme

echo "== kontroller =="
swift run -c release TokenChecks 2>&1 | tail -1 | grep -q 'ALL CHECKS PASS' || say_fail TokenChecks

summary='import json,sys; d=json.load(sys.stdin); print(d["total"], d["calls"], round(d["cost"], 6))'

echo "== kurmaca ev: CLI ↔ oracle, birebir =="
cli=$(.build/release/tokenbar-cli --home "$fixture" --db "$fixture/check.sqlite" --rebuild --window all --json | python3 -c "$summary")
orc=$(HOME="$fixture" python3 scripts/oracle.py all | python3 -c "$summary")
echo "cli    : $cli"
echo "oracle : $orc"
if [ -z "$cli" ] || [ "$cli" != "$orc" ]; then say_fail "kurmaca ev uyuşmuyor"; fi

echo "== canlı: CLI ↔ oracle, pay $live_tolerance =="
db=$(mktemp -d)/usage.sqlite
cli=$(.build/release/tokenbar-cli --db "$db" --rebuild --window all --json | python3 -c "$summary")
orc=$(python3 scripts/oracle.py all | python3 -c "$summary")
rm -rf "$(dirname "$db")"
echo "cli    : $cli"
echo "oracle : $orc"
python3 - "$cli" "$orc" "$live_tolerance" <<'PY' || say_fail "canlı uyuşmuyor"
import sys
a, b, tol = sys.argv[1].split(), sys.argv[2].split(), float(sys.argv[3])
sys.exit(0 if a and b and all(abs(float(x) - float(y)) <= tol * max(float(x), float(y)) for x, y in zip(a, b)) else 1)
PY

echo "== arayüz değişmezleri =="
.build/release/UISnapshot selfcheck 2>&1 | tail -1 | grep -q 'UI SELF-CHECK OK' || say_fail "UI self-check"

if [ "$fail" -eq 0 ]; then echo "CHECKS OK"; else echo "CHECKS FAILED"; exit 1; fi
