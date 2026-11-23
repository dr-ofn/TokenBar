"""The 9.0.1 price findings of the second review, on both Python price engines (the Windows app's and scripts/pricelib.py,
the oracle's), so they keep giving the answers the Swift engine gives (scripts/price-parity.py compares them name by name)."""
import json
import os
import sys

import pytest

from tokenbar.prices import engine
from tokenbar.prices.feed import FetchError, PriceFeed

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import pricelib  # noqa: E402

ENGINES = [pytest.param(engine, id="windows-engine"), pytest.param(pricelib, id="pricelib")]


def rates(e):
    return None if e is None else (e["input"], e["output"])


# ------------------------------------------------------------------------------------------------ 1  cache round trip

OR_SAME_ROUTE = {"data": [
    {"id": "acme/m", "name": "Acme: M", "pricing": {"prompt": "0.000001", "completion": "0.000002"}},
    {"id": "acme/m:nitro", "name": "Acme: M", "pricing": {"prompt": "0.000001", "completion": "0.000002"}},
]}
LL_NITRO = {"acme/m": {"mode": "chat", "input_cost_per_token": 3e-6, "output_cost_per_token": 6e-6},
            "acme/m:nitro": {"mode": "chat", "input_cost_per_token": 5e-6, "output_cost_per_token": 1e-5}}
LL_ONLY_ROUTE = {"acme/m:nitro": {"mode": "chat", "input_cost_per_token": 5e-6, "output_cost_per_token": 1e-5}}


@pytest.mark.parametrize("lib", ENGINES)
def test_a_route_row_that_says_what_the_winner_says_still_reaches_the_cache(lib):
    """OpenRouter lists acme/m:nitro at the price of acme/m, LiteLLM lists it at another: whole, OpenRouter's exact id wins.
    A cache that left the OpenRouter row out would hand the name to LiteLLM."""
    or_rows, ll_rows = lib.openrouter_rows(OR_SAME_ROUTE), lib.litellm_rows(LL_NITRO)
    whole = lib.Pricer([lib.Catalogue("openrouter", or_rows), lib.Catalogue("litellm", ll_rows)])
    assert rates(whole.resolve("", "acme/m:nitro")) == (1.0, 2.0)
    cut = []
    for source, rows in (("openrouter", or_rows), ("litellm", ll_rows)):
        winners, exact = lib.split(source, rows)
        cut.append(lib.Catalogue(source, winners, exact))
    cached = lib.Pricer(cut)
    for name in ("acme/m", "acme/m:nitro", "ACME/M:NITRO"):
        assert rates(cached.resolve("", name)) == rates(whole.resolve("", name)), name
    assert rates(cached.resolve("", "acme/m:nitro")) == (1.0, 2.0)


@pytest.mark.parametrize("lib", ENGINES)
def test_ids_that_differ_only_in_case_give_the_same_row_whole_and_cut(lib):
    """Two ids that fold to one lower-case id: the row the id index holds must not depend on insertion order or on the
    winner/exact split."""
    cheap = [1.0, 2.0, 0.0, 0.0, 0.0, [], "Cheap"]
    dear = [3.0, 4.0, 0.0, 0.0, 0.0, [], "Dear"]
    for rows in ({"Acme/M": cheap, "acme/m": dear}, {"acme/m": dear, "Acme/M": cheap}):
        whole = lib.Catalogue("litellm", rows)
        winners, exact = lib.split("litellm", rows)
        cut = lib.Catalogue("litellm", winners, exact)
        assert cut.by_id["acme/m"] == whole.by_id["acme/m"]
    a = lib.Catalogue("litellm", {"Acme/M": cheap, "acme/m": dear})
    b = lib.Catalogue("litellm", {"acme/m": dear, "Acme/M": cheap})
    assert a.by_id["acme/m"] == b.by_id["acme/m"]


def test_the_cache_file_round_trip_of_the_route_row_and_the_schema(tmp_path):
    def fetch(source, etag):
        if source == "modelsdev":
            raise FetchError("none")
        return "ok", json.dumps(OR_SAME_ROUTE if source == "openrouter" else LL_NITRO).encode(), "tag-" + source

    feed = PriceFeed(str(tmp_path), fetcher=fetch, now=lambda: 1_000_000.0)
    feed.refresh()
    root = json.load(open(tmp_path / "prices-openrouter.json"))
    assert root["schema"] == 2
    whole = engine.Pricer([engine.Catalogue("openrouter", engine.openrouter_rows(OR_SAME_ROUTE)),
                           engine.Catalogue("litellm", engine.litellm_rows(LL_NITRO))])
    cats, _ = feed.load_local()
    cached = engine.Pricer(cats)
    for name in ("acme/m", "acme/m:nitro"):
        assert rates(cached.resolve("", name)) == rates(whole.resolve("", name))
    # a 304 keeps them too, and a schema 2 cache is asked with its ETag
    seen = []

    def later(source, etag):
        seen.append(etag)
        return ("notmodified",)

    PriceFeed(str(tmp_path), fetcher=later, now=lambda: 1_000_000.0 + 7200 * 24).refresh()
    assert "tag-openrouter" in seen
    cats, _ = feed.load_local()
    assert rates(engine.Pricer(cats).resolve("", "acme/m:nitro")) == (1.0, 2.0)


def test_a_catalogue_that_has_only_route_rows_is_still_a_cache(tmp_path):
    """No winner at all (every row is a route): the cache file is the exact rows alone, and is read, not thrown away."""
    feed = PriceFeed(str(tmp_path), fetcher=lambda s, e: ("ok", json.dumps(LL_ONLY_ROUTE).encode(), None) if s == "litellm"
                     else (_ for _ in ()).throw(FetchError("none")), now=lambda: 1_000_000.0)
    feed.refresh()
    cache = feed.read_cache("litellm")
    assert cache is not None and cache.rows == {} and set(cache.exact) == {"acme/m:nitro"}
    cats, origins = feed.load_local()
    assert origins["litellm"].startswith("cache")
    assert rates(engine.Pricer(cats).resolve("", "acme/m:nitro")) == (5.0, 10.0)


def test_a_schema_1_cache_is_read_but_asked_again_in_full(tmp_path):
    """A 9.0.0 cache has no exact rows and its ETag would only ever bring a 304: it is read (the prices stay) and the next
    refresh sends no ETag and asks for the whole catalogue, whatever the age of the file."""
    (tmp_path / "prices-openrouter.json").write_text(json.dumps({
        "schema": 1, "source": "openrouter", "fetched": 1_000_000.0, "etag": "old-tag",
        "rows": {"acme/m": [1.0, 2.0, 0.0, 0.0, 0.0, [], "Acme: M"]}}))
    seen = []

    def fetch(source, etag):
        seen.append((source, etag))
        if source != "openrouter":
            raise FetchError("none")
        return "ok", json.dumps(OR_SAME_ROUTE).encode(), "new-tag"

    feed = PriceFeed(str(tmp_path), fetcher=fetch, now=lambda: 1_000_000.0 + 60)
    assert set(feed.read_cache("openrouter").rows) == {"acme/m"}
    report = feed.refresh()
    assert ("openrouter", None) in seen and report.updated == ["openrouter"]
    assert json.load(open(tmp_path / "prices-openrouter.json"))["schema"] == 2
    assert "acme/m:nitro" in feed.read_cache("openrouter").exact


# ------------------------------------------------------------------------------------------------ 2, 3  alias chains and loops

CATALOGUE = {"gpt-4o": {"mode": "chat", "input_cost_per_token": 2.5e-6, "output_cost_per_token": 1e-5},
             "azure/gpt-4o": {"mode": "chat", "input_cost_per_token": 9e-6, "output_cost_per_token": 9e-6},
             "acme-cat": {"mode": "chat", "input_cost_per_token": 7e-6, "output_cost_per_token": 8e-6}}


def alias_pricer(lib, aliases):
    return lib.Pricer([lib.Catalogue("litellm", lib.litellm_rows(CATALOGUE))], aliases=aliases)


@pytest.mark.parametrize("lib", ENGINES)
def test_an_alias_chain_of_four_steps_is_priced_and_five_are_not(lib):
    p = alias_pricer(lib, {"a": "b", "b": "c", "c": "d", "d": "e", "e": {"input": 5, "output": 10},
                           "f1": "f2", "f2": "f3", "f3": "f4", "f4": "f5", "f5": "f6", "f6": {"input": 5, "output": 10}})
    assert rates(p.resolve("", "a")) == (5.0, 10.0)            # a to e: four steps
    assert rates(p.resolve("", "b")) == (5.0, 10.0)
    assert p.resolve("", "f1") is None                          # f1 to f6: five steps
    assert rates(p.resolve("", "f2")) == (5.0, 10.0)           # four steps again


@pytest.mark.parametrize("lib", ENGINES)
def test_an_alias_chain_ending_at_a_catalogue_model_counts_alias_steps_only(lib):
    p = alias_pricer(lib, {"m1": {"as": "m2"}, "m2": "m3", "m3": {"as": "m4"}, "m4": "m5", "m5": "acme-cat",
                           "n1": "n2", "n2": "n3", "n3": "n4", "n4": "n5", "n5": "n6", "n6": "acme-cat"})
    assert rates(p.resolve("", "m1")) == (7.0, 8.0)            # four alias-to-alias steps, then the catalogue
    assert p.resolve("", "n1") is None                          # five


@pytest.mark.parametrize("lib", ENGINES)
def test_an_alias_loop_is_unpriced_not_priced_from_the_catalogue(lib):
    p = alias_pricer(lib, {"loop": "gpt-4o", "gpt-4o": "loop", "x": {"as": "y"}, "y": {"as": "z"}, "z": "x"})
    assert p.resolve("", "loop") is None
    assert p.resolve("", "gpt-4o") is None
    assert p.resolve("", "x") is None and p.resolve("", "y") is None and p.resolve("", "z") is None
    assert rates(alias_pricer(lib, {}).resolve("", "gpt-4o")) == (2.5, 10.0)     # the catalogue itself is fine


@pytest.mark.parametrize("lib", ENGINES)
def test_an_alias_that_names_the_catalogue_row_of_its_own_name_is_not_a_loop(lib):
    p = alias_pricer(lib, {"gpt-4o": "azure/gpt-4o"})
    e = p.resolve("", "gpt-4o")
    assert rates(e) == (9.0, 9.0) and e["kind"] == "alias"


# ------------------------------------------------------------------------------------------------ 4  JSON null is "not given"

@pytest.mark.parametrize("lib", ENGINES)
def test_a_null_cache_price_in_an_alias_is_not_given(lib):
    p = lib.Pricer([], aliases={"nulls": {"input": 10, "output": 20, "cacheRead": None, "cacheWrite": None},
                                "zero": {"input": 10, "output": 20, "cacheRead": 0, "cacheWrite": 0},
                                "half": {"input": 10, "output": 20, "cacheRead": 2, "cacheWrite": None}})
    nulls, zero, half = p.resolve("", "nulls"), p.resolve("", "zero"), p.resolve("", "half")
    assert (nulls["cacheRead"], nulls["cacheWrite"], nulls["cacheWrite1h"]) == (10, 10, 10)    # priced like input
    assert (zero["cacheRead"], zero["cacheWrite"]) == (0, 0)                                    # an explicit 0 is a price
    assert (half["cacheRead"], half["cacheWrite"]) == (2, 10)


@pytest.mark.parametrize("lib", ENGINES)
def test_a_null_in_a_tier_override_keeps_the_base_row_price(lib):
    openrouter = lib.openrouter_rows({"data": [{"id": "acme/tier-1", "name": "Acme: Tier 1", "pricing": {
        "prompt": "0.000001", "completion": "0.000004", "input_cache_read": "0.0000001", "input_cache_write": "0.00000125",
        "overrides": [{"min_prompt_tokens": 200000, "prompt": "0.000002", "completion": None, "input_cache_read": None,
                       "input_cache_write": None, "input_cache_write_1h": None}]}}]})
    modelsdev = lib.modelsdev_rows({"acme": {"models": {
        "tier-2": {"name": "Tier 2", "cost": {"input": 1, "output": 4, "cache_read": 0.1, "cache_write": 1.25, "tiers": [
            {"tier": {"type": "context", "size": 200000}, "input": 2, "output": None, "cache_read": None, "cache_write": None}]}},
        "tier-3": {"name": "Tier 3", "cost": {"input": 1, "output": 4, "cache_read": 0.1, "cache_write": 1.25,
                                               "context_over_200k": {"input": 2, "output": None, "cache_read": None, "cache_write": None}}}}}})
    for source, rows, name in (("openrouter", openrouter, "acme/tier-1"), ("modelsdev", modelsdev, "acme/tier-2"),
                               ("modelsdev", modelsdev, "acme/tier-3")):
        t = lib.Pricer([lib.Catalogue(source, rows)]).resolve("", name)["tiers"][0]
        assert (t["input"], t["output"]) == (2.0, 4.0), name
        assert (t["cacheRead"], t["cacheWrite"]) == (pytest.approx(0.1), pytest.approx(1.25)), name
