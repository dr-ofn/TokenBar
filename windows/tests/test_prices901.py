"""The 9.0.1 price findings, on both Python price engines (the Windows app's and scripts/pricelib.py, the oracle's),
so they keep giving the answers the Swift engine gives (scripts/price-parity.py compares them name by name)."""
import json
import os
import sys
import time

import pytest

from tokenbar.prices import engine
from tokenbar.prices.feed import FetchError, PriceFeed

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import pricelib  # noqa: E402

ENGINES = [pytest.param(engine, id="windows-engine"), pytest.param(pricelib, id="pricelib")]

OPENROUTER = {"data": [
    {"id": "acme/alpha-1", "name": "Acme: Alpha 1", "pricing": {"prompt": "0.000003", "completion": "0.000015"}},
    {"id": "acme/alpha-1:batch", "name": "Acme: Alpha 1 (batch)", "pricing": {"prompt": "0.0000015", "completion": "0.0000075"}},
    {"id": "acme/alpha-1:nitro", "name": "Acme: Alpha 1 (nitro)", "pricing": {"prompt": "0.000004", "completion": "0.00002"}},
    {"id": "acme/plain-9", "name": "Acme: Plain 9", "pricing": {"prompt": "0.000001", "completion": "0.000002"}},
]}
LITELLM = {
    "delta-4": {"mode": "chat", "input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6},
    "vertex_ai/delta-4@20250929": {"mode": "chat", "input_cost_per_token": 1.1e-6, "output_cost_per_token": 2.2e-6},
    "gpt-fix-2024-05-13": {"mode": "chat", "input_cost_per_token": 5e-6, "output_cost_per_token": 1.5e-5},
    "gpt-fix": {"mode": "chat", "input_cost_per_token": 2.5e-6, "output_cost_per_token": 1e-5},
}
NAMES = ["acme/alpha-1", "acme/alpha-1:batch", "acme/alpha-1:nitro", "acme/plain-9", "delta-4", "vertex_ai/delta-4@20250929",
         "gpt-fix", "gpt-fix-2024-05-13"]


def rates(e):
    return None if e is None else (e["input"], e["output"])


def test_cache_roundtrip_keeps_what_the_whole_catalogue_priced(tmp_path):
    rows = {"openrouter": engine.openrouter_rows(OPENROUTER), "litellm": engine.litellm_rows(LITELLM)}

    def fetch(source, etag):
        if source == "modelsdev":
            raise FetchError("none")
        return "ok", json.dumps(OPENROUTER if source == "openrouter" else LITELLM).encode(), None

    feed = PriceFeed(str(tmp_path), fetcher=fetch, now=lambda: 1_000_000.0)
    feed.refresh()
    whole = engine.Pricer([engine.Catalogue("openrouter", rows["openrouter"]), engine.Catalogue("litellm", rows["litellm"])])
    cats, _ = feed.load_local()
    cached = engine.Pricer(cats)
    fresh = [rates(whole.resolve("", n)) for n in NAMES]
    assert fresh[1] == (1.5, 7.5) and fresh[2] == (4.0, 20.0) and fresh[5] == (1.1, 2.2) and fresh[7] == (5.0, 15.0)
    assert [rates(cached.resolve("", n)) for n in NAMES] == fresh
    # a 304 keeps them too
    later = PriceFeed(str(tmp_path), fetcher=lambda s, e: ("notmodified",), now=lambda: 1_000_000.0 + 7200)
    later.refresh()
    cats, _ = later.load_local()
    assert [rates(engine.Pricer(cats).resolve("", n)) for n in NAMES] == fresh


@pytest.mark.parametrize("lib", ENGINES)
def test_split_keeps_winners_apart_from_exact_rows(lib):
    rows = lib.litellm_rows(LITELLM)
    winners, exact = lib.split("litellm", rows)
    assert "delta-4" in winners and "vertex_ai/delta-4@20250929" in exact
    # a catalogue built again from the two chooses the same winners and still finds the exact ids
    again = lib.Catalogue("litellm", winners, exact)
    whole = lib.Catalogue("litellm", rows)
    assert again.by_key == whole.by_key
    assert again.by_id["vertex_ai/delta-4@20250929"][1] == rows["vertex_ai/delta-4@20250929"]


@pytest.mark.parametrize("lib", ENGINES)
def test_table_row_copied_from_openrouter_gives_way_to_the_live_row(lib):
    table = [dict(key="glm-5.2", name="GLM-5.2", kind="openrouter", catalog=None, catalogID=None, source="OpenRouter: z-ai/glm-5.2",
                  tiers=[], input=0.007, output=6.8, cacheRead=0.006, cacheWrite=0.007, cacheWrite1h=0.007),
             dict(key="crouton-alpha", name="Crouton", kind="near", catalog=None, catalogID=None, source="s", tiers=[],
                  input=1.0, output=2.0, cacheRead=1.0, cacheWrite=1.0, cacheWrite1h=1.0)]
    live = lib.openrouter_rows({"data": [
        {"id": "z-ai/glm-5.2", "name": "Z.ai: GLM 5.2", "pricing": {"prompt": "0.00000999", "completion": "0.00001999"}},
        {"id": "x/crouton-alpha", "name": "X: Crouton", "pricing": {"prompt": "0.000009", "completion": "0.000009"}}]})
    p = lib.Pricer([lib.Catalogue("openrouter", live)], override=table)
    e = p.resolve("", "glm-5.2")
    assert (e["input"], e["output"]) == (9.99, 19.99) and "z-ai/glm-5.2" in e["source"]
    assert p.resolve("", "crouton-alpha")["kind"] == "near"                   # a stand-in stays what the table says
    no_live = lib.Pricer([lib.Catalogue("litellm", lib.litellm_rows(LITELLM))], override=table)
    assert no_live.resolve("", "glm-5.2")["input"] == 0.007                   # nothing live lists it: the table's price


@pytest.mark.parametrize("lib", ENGINES)
def test_alias_cache_zero_is_a_price_and_chains_resolve(lib):
    aliases = {"free-cache": {"input": 10, "output": 20, "cacheRead": 0, "cacheWrite": 0},
               "no-cache": {"input": 10, "output": 20},
               "chain-a": {"as": "chain-b"}, "chain-b": {"as": "chain-c"}, "chain-c": {"input": 5, "output": 10},
               "chain-text": "chain-a", "loop-a": {"as": "loop-b"}, "loop-b": {"as": "loop-a"}}
    p = lib.Pricer([], aliases=aliases)
    free = p.resolve("", "free-cache")
    assert free["cacheRead"] == 0 and free["cacheWrite"] == 0 and free["cacheWrite1h"] == 0
    none = p.resolve("", "no-cache")
    assert none["cacheRead"] == 10 and none["cacheWrite"] == 10
    assert p.resolve("", "chain-a")["input"] == 5 and p.resolve("", "chain-text")["output"] == 10
    assert p.resolve("", "loop-a") is None


@pytest.mark.parametrize("lib", ENGINES)
def test_tier_without_cache_fields_keeps_the_base_cache_price(lib):
    openrouter = lib.openrouter_rows({"data": [{"id": "acme/tier-1", "name": "Acme: Tier 1", "pricing": {
        "prompt": "0.000001", "completion": "0.000004", "input_cache_read": "0.0000001",
        "overrides": [{"min_prompt_tokens": 200000, "prompt": "0.000002"}]}}]})
    modelsdev = lib.modelsdev_rows({"acme": {"models": {"tier-2": {"name": "Tier 2", "cost": {
        "input": 1, "output": 4, "cache_read": 0.1, "context_over_200k": {"input": 2, "output": 8}}}}}})
    for source, rows, name in (("openrouter", openrouter, "acme/tier-1"), ("modelsdev", modelsdev, "acme/tier-2")):
        e = lib.Pricer([lib.Catalogue(source, rows)]).resolve("", name)
        assert e["tiers"][0]["input"] == 2.0 and e["tiers"][0]["cacheRead"] == pytest.approx(0.1), source


def test_embedded_snapshot_tiers_keep_the_base_cache_price():
    snapshot = json.load(open(os.path.join(ROOT, "Sources", "LocalCore", "Resources", "prices-snapshot.json"), encoding="utf-8"))
    lost = [(s, k) for s in ("litellm", "modelsdev") for k, r in snapshot[s].items() if len(r) > 5 and r[2] > 0
            for t in r[5] if t[3] == 0]
    assert lost == []
    same = json.load(open(os.path.join(ROOT, "windows", "tokenbar", "data", "prices-snapshot.json"), encoding="utf-8"))
    assert same == snapshot


@pytest.mark.parametrize("lib", ENGINES)
def test_a_very_long_name_costs_time_in_proportion_to_its_length(lib):
    p = lib.Pricer([lib.Catalogue("litellm", lib.litellm_rows(LITELLM))])
    started = time.time()
    for name in ("a-q4" * 10_000, "(a)" * 13_000, "x@" * 20_000):
        lib.Keys(name)
        p.resolve("", name)
    assert time.time() - started < 1.0
    assert p.resolve("", "delta-4[" + "x" * 300 + "]") is None and p.resolve("", "delta-4[" + "x" * 100 + "]") is not None
