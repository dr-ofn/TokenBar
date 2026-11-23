#!/usr/bin/env python3
"""Regenerates what TokenBar ships for prices. Run it before a release.

    scripts/update-prices.py                       fetch the live sources, rewrite everything
    scripts/update-prices.py --only snapshot       the embedded snapshot only
    scripts/update-prices.py --only table          the hand-corrected tables only
    scripts/update-prices.py --check-drift         name the table rows that are off the live OpenRouter catalogue (exit 1)
    scripts/update-prices.py --keep-prices         re-render the tables from scripts/prices.json, no network
                                                   (a row newly added to price-map.json is resolved from the catalogue: --openrouter FILE)
    options: --openrouter FILE  --litellm FILE  --modelsdev FILE   read these instead of fetching

Two outputs:
  1. The override layer: scripts/price-map.json (name -> where its price comes from; "near" proxies, other
     published prices) resolved against OpenRouter -> scripts/prices.json (read by oracle.py) and
     Sources/LocalCore/PriceTable.swift. A user's own model names belong in ~/.config/tokenbar/model-aliases.json.
  2. The embedded snapshot of the two MIT-licensed catalogues (LiteLLM, models.dev), cut down to the fields
     the app reads: Sources/LocalCore/Resources/prices-snapshot.json, and the same text as a Swift string in
     Sources/LocalCore/PriceSnapshotData.swift (a string literal compiles in 3 s; a 1.4 MB byte array in 40 s).
     OpenRouter is never embedded: its catalogue licence is not verified; the app only reads it at run time.

Prices are USD per 1M tokens. A cache price a catalogue leaves out or zeroes on a paid model falls back to
the input price. Nothing is free in the tables: a model offered only for free takes its nearest paid model.
"""
import argparse
import gzip
import json
import os
import sys
import urllib.request
from datetime import date

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pricelib  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
URLS = {
    "openrouter": "https://openrouter.ai/api/v1/models",
    "litellm": "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json",
    "modelsdev": "https://models.dev/api.json",
}
LICENSES = {
    "litellm": {"license": "MIT, Copyright (c) 2023 Berri AI (content outside litellm/enterprise/)",
                "licenseUrl": "https://raw.githubusercontent.com/BerriAI/litellm/main/LICENSE"},
    "modelsdev": {"license": "MIT, Copyright (c) 2025 models.dev",
                  "licenseUrl": "https://raw.githubusercontent.com/anomalyco/models.dev/dev/LICENSE"},
}
DELISTED = "OpenRouter listeden kaldırdı"


def fetch(url):
    request = urllib.request.Request(url, headers={"Accept-Encoding": "gzip", "User-Agent": "TokenBar-update-prices"})
    with urllib.request.urlopen(request, timeout=120) as response:
        body = response.read()
        if response.headers.get("Content-Encoding") == "gzip":
            body = gzip.decompress(body)
    return json.loads(body)


def source(name, path):
    if path:
        return json.load(open(path, encoding="utf-8"))
    print(f"fetching {URLS[name]}")
    return fetch(URLS[name])


# ---------------------------------------------------------------------------------------------
# 1. The override layer

def per_million(value):
    return round(float(value or 0) * 1_000_000, 6)


def rates(p, fallback=None):
    base = fallback or {}
    inp = per_million(p.get("prompt")) if "prompt" in p else base.get("input", 0)
    out = per_million(p.get("completion")) if "completion" in p else base.get("output", 0)
    read = per_million(p.get("input_cache_read"))
    write = per_million(p.get("input_cache_write"))
    write1h = per_million(p.get("input_cache_write_1h"))
    return {"input": inp, "output": out, "cacheRead": read or inp, "cacheWrite": write or inp,
            "cacheWrite1h": write1h or write or inp}


def entry(key, spec, catalogue, previous):
    out = {"key": key, "name": spec["name"], "tiers": []}
    slug = spec.get("or") or spec.get("near")
    if slug and slug not in catalogue:
        # Delisted since the last run: the calls were made at the last price the catalogue showed.
        if key not in previous["entries"]:
            sys.exit(f"{key}: {slug} OpenRouter kataloğunda yok ve eski fiyatı da yok")
        out = dict(previous["entries"][key], name=spec["name"])
        if DELISTED not in out["source"]:
            out["source"] += f" ({DELISTED}; son fiyat {previous['date']})"
        print(f"katalogda yok, son fiyat kaldı: {key} ({slug})")
    elif slug:
        pricing = catalogue[slug]["pricing"]
        out.update(rates(pricing))
        # Only prompt-length overrides are tiers; time-of-day ones (utc_start/utc_end) keep the base price.
        tiers = [t for t in pricing.get("overrides") or [] if "min_prompt_tokens" in t]
        for t in sorted(tiers, key=lambda t: t["min_prompt_tokens"]):
            out["tiers"].append({"minPrompt": t["min_prompt_tokens"], **rates(t, out)})
        note = spec.get("note")
        if spec.get("or"):
            out["kind"] = "openrouter"
            out["source"] = f"OpenRouter: {slug}" + (f" ({note})" if note else "")
        else:
            out["kind"] = "near"
            out["source"] = f"OpenRouter en yakın: {slug} ({note})"
    elif "other" in spec:
        p = spec["other"]
        inp = p["input"]
        out.update(input=inp, output=p["output"], cacheRead=p.get("cacheRead", inp), cacheWrite=inp, cacheWrite1h=inp)
        out["kind"] = "other"
        out["source"] = f"{spec['url']} \"{spec['quote']}\"" + (f" ({spec['note']})" if spec.get("note") else "")
    else:
        sys.exit(f"{key}: fiyat kaynağı yok (or, near ya da other gerekli)")
    # Nothing is free in the table: a free route or preview is priced like its nearest paid model.
    if out["input"] <= 0 or out["output"] <= 0:
        sys.exit(f"{key}: sıfır fiyat ({out['source']}); en yakın ücretli modeli bağla")
    return out


def literal(text):
    return json.dumps(text, ensure_ascii=False)


def rate_args(e):
    return ", ".join(f"{k}: {e[k]}" for k in ("input", "output", "cacheRead", "cacheWrite", "cacheWrite1h"))


def swift_line(e):
    tiers = ", ".join(f".init(minPrompt: {t['minPrompt']}, {rate_args(t)})" for t in e["tiers"])
    return (f"    .init(key: {literal(e['key'])}, name: {literal(e['name'])}, kind: .{e['kind']}, "
            f"source: {literal(e['source'])}, {rate_args(e)}, tiers: [{tiers}]),")


def write_tables(entries, today):
    json.dump({"date": today, "entries": entries},
              open(f"{ROOT}/scripts/prices.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    general = ["// Generated by scripts/update-prices.py. Do not edit.", "",
               "/// The hand-corrected layer: it wins over every catalogue. Rows are \"near\" proxies for models no catalogue lists,",
               "/// prices published elsewhere, and a few table-pinned OpenRouter prices.",
               f'let priceTableDate = "{today}"', "", "let priceTable: [PriceEntry] = ["]
    general += [swift_line(e) for e in entries] + ["]", ""]
    open(f"{ROOT}/Sources/LocalCore/PriceTable.swift", "w", encoding="utf-8").write("\n".join(general))
    write_windows_tables(entries, today)
    print(f"table: {len(entries)} rows, {today}")


def write_windows_tables(entries, today):
    """The Windows app reads the same rows from windows/tokenbar/data/price-tables.json (compact JSON; the `personal`
    list the file may carry is left as it is)."""
    path = f"{ROOT}/windows/tokenbar/data/price-tables.json"
    try:
        personal = json.load(open(path, encoding="utf-8")).get("personal", [])
    except (OSError, ValueError):
        personal = []
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"date": today, "entries": entries, "personal": personal}, f, ensure_ascii=False, separators=(",", ":"))


def build_table(path, keep):
    spec = json.load(open(f"{ROOT}/scripts/price-map.json", encoding="utf-8"))
    spec.pop("_")
    old = json.load(open(f"{ROOT}/scripts/prices.json", encoding="utf-8"))
    previous = {"date": old["date"], "entries": {e["key"]: e for e in old["entries"]}}
    if keep:
        # Rows already in prices.json keep their price; a row added to price-map.json since is resolved from the
        # catalogue (--openrouter FILE, or the network) and the existing rows stay as they were.
        added = [k for k in spec if k not in previous["entries"]]
        catalogue = {m["id"]: m for m in source("openrouter", path)["data"]} if added else {}
        rows = {k: dict(previous["entries"][k], name=v["name"]) if k in previous["entries"] else entry(k, v, catalogue, previous)
                for k, v in spec.items()}
        today = old["date"]
        if added:
            print("yeni satırlar:", ", ".join(added))
    else:
        catalogue = {m["id"]: m for m in source("openrouter", path)["data"]}
        rows = {k: entry(k, v, catalogue, previous) for k, v in spec.items()}
        today = date.today().isoformat()
    write_tables([rows[k] for k in spec], today)


# ---------------------------------------------------------------------------------------------
# 2. The snapshot

def build_snapshot(litellm_path, modelsdev_path):
    today = date.today().isoformat()
    litellm = pricelib.litellm_rows(source("litellm", litellm_path))
    modelsdev = pricelib.modelsdev_rows(source("modelsdev", modelsdev_path))
    litellm_winners, litellm_exact = pricelib.split("litellm", litellm)
    modelsdev_winners, _ = pricelib.split("modelsdev", modelsdev)
    snapshot = {
        "schema": 1,
        "generated": today,
        "note": "Generated by scripts/update-prices.py. Prices are USD per 1M tokens; a row is "
                "[input, output, cacheRead, cacheWrite, cacheWrite1h, [[minPrompt, input, output, cacheRead, cacheWrite, cacheWrite1h]], name?]; "
                "0 means the catalogue does not say. Rows are cut to the ones the app's index would pick, plus (under \"exact\") the rows only an exact id reaches with a price of their own. "
                "OpenRouter is deliberately not embedded; the app reads it at run time only.",
        "sources": {name: {"url": URLS[name], "retrieved": today, **LICENSES[name]} for name in ("litellm", "modelsdev")},
        "litellm": litellm_winners,
        "modelsdev": modelsdev_winners,
    }
    # The rows an exact id reaches with a price of their own (a route, a provider, a dated id): kept apart from the winners
    # of the keys, which they must not change.
    if litellm_exact:
        snapshot["exact"] = {"litellm": litellm_exact}
    text = json.dumps(snapshot, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    if '"""' in text or "\\#" in text:
        sys.exit("snapshot text would break the Swift raw string literal")
    directory = f"{ROOT}/Sources/LocalCore/Resources"
    os.makedirs(directory, exist_ok=True)
    open(f"{directory}/prices-snapshot.json", "w", encoding="utf-8").write(text + "\n")
    windows_data = f"{ROOT}/windows/tokenbar/data"          # the Windows app embeds the very same snapshot
    os.makedirs(windows_data, exist_ok=True)
    open(f"{windows_data}/prices-snapshot.json", "w", encoding="utf-8").write(text + "\n")
    open(f"{ROOT}/Sources/LocalCore/PriceSnapshotData.swift", "w", encoding="utf-8").write(
        "// Generated by scripts/update-prices.py from Resources/prices-snapshot.json. Do not edit.\n\n"
        '/// The embedded LiteLLM + models.dev snapshot (both MIT; see "sources" inside).\n'
        'let priceSnapshotJSON = #"""\n' + text + '\n"""#\n')
    print(f"snapshot: {len(snapshot['litellm'])} LiteLLM (+{len(litellm_exact)} exact) + {len(snapshot['modelsdev'])} models.dev rows, "
          f"{len(text.encode('utf-8')) / 1e6:.2f} MB, {today}")


def check_drift(path, limit=0.05):
    """Table rows copied from OpenRouter against the catalogue now: a row whose input or output price moved by more than
    `limit` is named, and the exit status is 1. (The app prices such a model from the live catalogue when it has one, so
    this is about the table that prices it offline and when pinned.)"""
    spec = json.load(open(f"{ROOT}/scripts/price-map.json", encoding="utf-8"))
    spec.pop("_")
    table = {e["key"]: e for e in json.load(open(f"{ROOT}/scripts/prices.json", encoding="utf-8"))["entries"]}
    catalogue = {m["id"]: m for m in source("openrouter", path)["data"]}
    drifted = 0
    for key, v in spec.items():
        slug = v.get("or")
        if not slug or slug not in catalogue or key not in table:
            continue
        now = rates(catalogue[slug]["pricing"])
        moved = {f: (table[key][f], now[f]) for f in ("input", "output") if abs(now[f] - table[key][f]) > limit * max(table[key][f], 1e-12)}
        if moved:
            drifted += 1
            print(f"{key} ({slug}): " + ", ".join(f"{f} {a} -> {b}" for f, (a, b) in moved.items()))
    print(f"{drifted} table row(s) off the live OpenRouter catalogue by more than {limit:.0%}")
    return 1 if drifted else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", choices=["table", "snapshot"])
    ap.add_argument("--keep-prices", action="store_true")
    ap.add_argument("--check-drift", action="store_true", help="name the table rows that are off the live OpenRouter catalogue by more than 5%% (exit 1)")
    ap.add_argument("--openrouter")
    ap.add_argument("--litellm")
    ap.add_argument("--modelsdev")
    args = ap.parse_args()
    if args.check_drift:
        sys.exit(check_drift(args.openrouter))
    if args.only != "snapshot":
        build_table(args.openrouter, args.keep_prices)
    if args.only != "table":
        build_snapshot(args.litellm, args.modelsdev)


if __name__ == "__main__":
    main()
