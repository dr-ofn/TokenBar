#!/usr/bin/env python3
"""Dev check: the Swift price rules and scripts/pricelib.py give the same answer.

    scripts/price-parity.py [NAMES.txt] [--swift .build/release/TokenChecks] [--raw LITELLM.json MODELSDEV.json]
                            [--aliases FILE]

NAMES.txt holds "provider|model" lines. Without it every model the embedded snapshot and the hand-made tables know is
checked, with a few names that match nothing. Both sides run pinned (embedded snapshot + hand-made tables): no network,
no cache file, no alias file of this Mac. The TokenChecks binary comes from `swift build -c release` (or debug).
With --raw the two catalogue files are cut down by both implementations and the kept row ids compared.
Exits 1 when anything differs.
"""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pricelib  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIELDS = ("input", "output", "cacheRead", "cacheWrite", "cacheWrite1h")


def same(a, b, slack=0.0):
    return abs(a - b) <= max(slack, 1e-9 * max(1.0, abs(a), abs(b)))


def default_names():
    """Every model of the embedded snapshot and the hand-made tables, plus names no catalogue has."""
    snapshot = json.load(open(pricelib.SNAPSHOT, encoding="utf-8"))
    names = [f"|{i}" for i in snapshot["litellm"]]
    names += [f"{i.split('/', 1)[0]}|{i.split('/', 1)[1]}" for i in snapshot["modelsdev"] if "/" in i]
    names += [f"|{e['key']}" for e in pricelib.load_tables()]
    names += ["anthropic|claude-mythos-5-2", "google|gemini-4-neon", "openai|gpt-6.2-sol-high", "|zz-unknown-model",
              "ollama|llama-9b-q4", "studio|zz-local-only"]
    return sorted(set(names))


def main():
    args = sys.argv[1:]
    swift = next((p for p in (os.path.join(ROOT, f".build/{c}/TokenChecks") for c in ("release", "debug")) if os.path.exists(p)),
                 os.path.join(ROOT, ".build/release/TokenChecks"))
    raw = None
    names = args[0] if args and not args[0].startswith("--") else None
    if "--swift" in args:
        swift = args[args.index("--swift") + 1]
    if "--raw" in args:
        i = args.index("--raw")
        raw = args[i + 1:i + 3]
    env = dict(os.environ, TOKENBAR_PRICES_PINNED="1")
    if names:
        lines = [l.rstrip("\n") for l in open(names, encoding="utf-8") if "|" in l]
    else:
        lines = default_names()
    options = []
    if "--aliases" in args:
        options += ["--aliases", args[args.index("--aliases") + 1]]
    out = subprocess.run([swift, "priceprobe"] + options, input="\n".join(lines) + "\n", capture_output=True, text=True, env=env)
    answers = [json.loads(l) for l in out.stdout.splitlines() if l.startswith("{")]
    assert len(answers) == len(lines), (len(answers), len(lines), out.stderr[-300:])
    aliases, local = pricelib.load_aliases(args[args.index("--aliases") + 1]) if "--aliases" in args else ({}, [])
    pricer = pricelib.shipped_pricer(aliases, local)
    bad = 0
    for line, ans in zip(lines, answers):
        provider, model = line.split("|", 1)
        want = pricer.resolve(provider, model)
        got = ans["entry"]
        problems = []
        if want is None or got is None:
            if (want is None) != (got is None):
                problems.append(f"swift={got and got['kind']} python={want and want['kind']}")
        else:
            if got["kind"] != want["kind"]:
                problems.append(f"kind {got['kind']} != {want['kind']}")
            if got["source"] != want["source"]:
                problems.append(f"source {got['source']!r} != {want['source']!r}")
            if got["name"] != want["name"]:
                problems.append(f"name {got['name']!r} != {want['name']!r}")
            for f in FIELDS:
                if not same(got[f], want[f]):
                    problems.append(f"{f} {got[f]} != {want[f]}")
            if len(got["tiers"]) != len(want["tiers"]):
                problems.append("tier count")
            else:
                for gt, wt in zip(got["tiers"], want["tiers"]):
                    if gt["minPrompt"] != wt["minPrompt"] or not all(same(gt[f], wt[f]) for f in FIELDS):
                        problems.append(f"tier {gt} != {wt}")
        if problems:
            bad += 1
            print(f"DIFF {line}: " + "; ".join(problems))
    print(f"names: {len(lines)} checked, {bad} different")
    if raw:
        ll, md = (json.load(open(p, encoding="utf-8")) for p in raw)
        out = subprocess.run([swift, "priceparity", raw[0], raw[1]], capture_output=True, text=True, env=env)
        swift_kept = json.loads(out.stdout)
        py = {"litellm": pricelib.litellm_rows(ll), "modelsdev": pricelib.modelsdev_rows(md)}
        for source, rows in py.items():
            kept = pricelib.thin(source, rows)
            a, b = set(kept), set(swift_kept[source])
            print(f"{source}: python keeps {len(a)}, swift keeps {len(b)}, only-python {len(a - b)}, only-swift {len(b - a)}")
            if a != b:
                bad += 1
                print("  e.g. only-python", sorted(a - b)[:5], "only-swift", sorted(b - a)[:5])
            for rid in a & b:
                sw, pr = swift_kept[source][rid], kept[rid]
                flat = lambda r: [x for x in r[:5]] + [t for tier in r[5] for t in tier]
                if len(flat(sw)) != len(flat(pr)) or not all(same(x, y, 2e-6) for x, y in zip(flat(sw), flat(pr))):  # ties of the 6th decimal round differently
                    bad += 1
                    print("  row differs", source, rid, sw[:5], pr[:5])
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
