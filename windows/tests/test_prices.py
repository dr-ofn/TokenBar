"""The price engine and the feed: no network anywhere (a fetcher is a function)."""
import json
import os
import time

import pytest

from tokenbar.prices import engine
from tokenbar.prices.book import PriceBook, load_tables
from tokenbar.prices.engine import Catalogue, Keys, Pricer, call_cost
from tokenbar.prices.feed import FetchError, PriceFeed, file_fetcher


def pricer(rows=None, source="litellm", **kw):
    cats = [Catalogue(source, rows)] if rows else []
    return Pricer(cats, kw.pop("override", []), kw.pop("aliases", None), kw.pop("local", ()))


ROW = [3.0, 15.0, 0.3, 3.75, 0, []]


def test_name_rules_fold_to_one_key():
    assert Keys("anthropic/Claude-Opus-5.5[1m]").key1 == "claude-opus-5-5"
    assert Keys("claude-opus-5-5-20261101").key1 == "claude-opus-5-5"
    assert Keys("openai/gpt-6.2-sol:free").key2 == "gpt-6-2-sol"
    assert Keys("qwen3.8-27b-q4_k_m").quantised


def test_catalogue_price_and_tiered_cost():
    rows = {"acme/m": [1.0, 4.0, 0.1, 1.25, 0, [[200001, 2.0, 8.0, 0.2, 2.5, 0]]]}
    e = pricer(rows).resolve("acme", "m")
    assert e["input"] == 1.0 and e["cacheRead"] == 0.1 and e["tiers"][0]["minPrompt"] == 200001
    assert call_cost(e, 100_000, 0, 0, 0, 0) == pytest.approx(0.1)                              # below the tier
    assert call_cost(e, 300_000, 0, 0, 0, 0) == pytest.approx(0.6)                              # above it: 2.0 / M
    assert call_cost(e, 300_000, 0, 0, 0, 0, tiered=False) == pytest.approx(0.3)                # a summed row has no tier


def test_cache_write_one_hour_share_is_priced_apart():
    e = pricer({"a/m": [1.0, 2.0, 0.1, 1.25, 2.0, []]}).resolve("a", "m")
    assert call_cost(e, 0, 0, 1_000_000, 0, 400_000) == pytest.approx(0.6 * 1.25 + 0.4 * 2.0)


def test_hand_table_wins_over_the_catalogue():
    over = [dict(key="m", name="Mine", kind="near", catalog=None, catalogID=None, source="s", tiers=[], input=9.0, output=9.0,
                 cacheRead=9.0, cacheWrite=9.0, cacheWrite1h=9.0)]
    e = pricer({"acme/m": ROW}, override=over).resolve("acme", "m")
    assert e["name"] == "Mine"


def test_local_model_costs_its_cloud_price_or_nothing():
    p = pricer({"acme/big-model": ROW})
    assert p.resolve("ollama", "big-model")["kind"] == "localCloud"
    assert p.resolve("ollama", "unheard-of-7b")["kind"] == "localFree"
    assert p.resolve("openrouter", "unheard-of-7b") is None             # a cloud model is never free
    assert p.resolve("x", "big-model-q4_k_m")["kind"] == "localCloud"   # a local quantisation suffix is enough


def test_family_proxy_drops_an_effort_word():
    p = pricer({"acme/some-model": ROW})
    e = p.resolve("acme", "some-model-high")
    assert e["kind"] == "approximate"


def test_user_alias_kinds():
    aliases = {"my-q4": "some-model", "house": {"input": 1, "output": 4}, "test-server": {"free": True}, "sidecar": {"as": "some-model"}}
    p = pricer({"acme/some-model": ROW}, aliases=aliases)
    assert p.resolve("x", "my-q4")["input"] == 3.0
    assert p.resolve("x", "house")["output"] == 4.0
    assert p.resolve("x", "test-server")["input"] == 0
    assert p.resolve("x", "sidecar")["kind"] == "alias"
    assert p.resolve("x", "my-q4-high")["kind"] == "approximate"       # an alias for a short name covers its variants


# ---- corrupt catalogue rows
def test_corrupt_litellm_rows_are_dropped_not_fatal():
    raw = {"good": {"input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6, "mode": "chat"},
           "huge": {"input_cost_per_token": 1e305, "output_cost_per_token": 1e305},
           "neg": {"input_cost_per_token": -1e-6, "output_cost_per_token": 2e-6},
           "tier": {"input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6, "input_cost_per_token_above_99999999999999999k_tokens": 1e-6},
           "embed": {"input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6, "mode": "embedding"},
           "sample_spec": {"input_cost_per_token": 1, "output_cost_per_token": 1}, "junk": 5}
    assert set(engine.litellm_rows(raw)) == {"good"}


def test_corrupt_modelsdev_and_openrouter_rows():
    md = {"p": {"models": {"ok": {"cost": {"input": 1, "output": 2}}, "zero-tier": {"cost": {"input": 1, "output": 2, "tiers": [{"tier": {"type": "context", "size": 0}, "input": 1, "output": 1}]}},
                           "neg": {"cost": {"input": -1, "output": 2}}}}}
    assert set(engine.modelsdev_rows(md)) == {"p/ok"}
    orr = {"data": [{"id": "a/b", "name": "Acme: B", "pricing": {"prompt": "0.000001", "completion": "0.000002"}},
                    {"id": "router", "pricing": {"prompt": "-1", "completion": "-1"}},
                    {"id": "free", "pricing": {"prompt": "0", "completion": "0"}}]}
    rows = engine.openrouter_rows(orr)
    assert set(rows) == {"a/b"} and rows["a/b"][6] == "B" and rows["a/b"][0] == 1.0
    assert engine.openrouter_rows({"nope": 1}) is None and engine.litellm_rows([1]) is None


def test_compact_rows_reject_infinity_and_overflowing_tiers():
    assert engine.compact_row([1, 2, 0, 0, 0, []]) is not None
    assert engine.compact_row([1e308, 2, 0, 0, 0, []]) is None
    assert engine.compact_row([1, 2, 0, 0, 0, [[10 ** 30, 1, 1, 0, 0, 0]]]) is None
    assert engine.compact_row([1, 2, 0, 0, 0, [[0, 1, 1, 0, 0, 0]]]) is None


def test_the_shipped_snapshot_and_tables_load_and_price_the_common_models():
    book = PriceBook(pinned=True, offline=True)
    book.reload()
    assert book.date
    for model in ("claude-opus-5-5", "gpt-6.1-sol", "gemini-3.8-flash"):
        assert book.resolve("x", model) is not None, model
    assert len(load_tables()) > 50


# ---- the feed
def catalogue_files(tmp_path, price=1e-6):
    d = tmp_path / "feed"
    d.mkdir(exist_ok=True)
    (d / "openrouter.json").write_text(json.dumps({"data": [{"id": "acme/fresh-model", "name": "Acme: Fresh", "pricing": {"prompt": str(price), "completion": str(price * 2)}}]}))
    (d / "litellm.json").write_text(json.dumps({"fresh-model-x": {"input_cost_per_token": price, "output_cost_per_token": price * 2}}))
    (d / "modelsdev.json").write_text(json.dumps({"acme": {"models": {"fresh-model": {"cost": {"input": 1, "output": 2}}}}}))
    return str(d)


class Counting:
    def __init__(self, inner):
        self.inner, self.calls = inner, []

    def __call__(self, source, etag):
        self.calls.append((source, etag))
        return self.inner(source, etag)


def test_refresh_writes_a_cache_and_the_book_uses_it(tmp_path):
    cache = str(tmp_path / "cache")
    feed = PriceFeed(cache, fetcher=file_fetcher(catalogue_files(tmp_path)))
    report = feed.refresh()
    assert sorted(report.updated) == ["litellm", "modelsdev", "openrouter"] and report.changed
    cats, origins = feed.load_local()
    assert [c.source for c in cats] == ["openrouter", "litellm", "modelsdev"] and origins["openrouter"].startswith("cache")
    assert Pricer(cats).resolve("acme", "fresh-model")["catalog"] == "OpenRouter"


def test_a_fresh_cache_is_not_asked_again_and_a_stale_one_is(tmp_path):
    cache = str(tmp_path / "cache")
    fetch = Counting(file_fetcher(catalogue_files(tmp_path)))
    clock = [1_800_000_000.0]
    feed = PriceFeed(cache, fetcher=fetch, now=lambda: clock[0])
    feed.refresh()
    assert len(fetch.calls) == 3
    again = feed.refresh()
    assert len(fetch.calls) == 3 and sorted(again.fresh) == ["litellm", "modelsdev", "openrouter"]
    clock[0] += 25 * 3600
    feed.refresh()
    assert len(fetch.calls) == 6


def test_304_keeps_the_cache_and_sends_the_etag(tmp_path):
    cache = str(tmp_path / "cache")
    seen = []

    def fetch(source, etag):
        seen.append(etag)
        return ("notmodified",) if etag else ("ok", json.dumps({"data": [{"id": "a/b", "pricing": {"prompt": "0.000001", "completion": "0.000002"}}]}).encode() if source == "openrouter"
                                              else json.dumps({"x": {"input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6}}).encode() if source == "litellm"
                                              else json.dumps({"p": {"models": {"m": {"cost": {"input": 1, "output": 2}}}}}).encode(), "etag-1")
    clock = [1_800_000_000.0]
    feed = PriceFeed(cache, fetcher=fetch, now=lambda: clock[0])
    feed.refresh()
    clock[0] += 30 * 3600
    report = feed.refresh()
    assert sorted(report.not_modified) == ["litellm", "modelsdev", "openrouter"] and "etag-1" in seen


def test_an_answer_that_is_not_the_catalogue_never_replaces_the_cache(tmp_path):
    cache = str(tmp_path / "cache")
    good = PriceFeed(cache, fetcher=file_fetcher(catalogue_files(tmp_path)), now=lambda: 1_800_000_000.0)
    good.refresh()
    before = open(os.path.join(cache, "prices-litellm.json")).read()
    bad = PriceFeed(cache, fetcher=lambda s, e: ("ok", b"<html>captive portal</html>", None), now=lambda: 1_800_000_000.0 + 48 * 3600)
    report = bad.refresh()
    assert set(report.failed) == {"openrouter", "litellm", "modelsdev"}
    assert open(os.path.join(cache, "prices-litellm.json")).read() == before


def test_after_a_failure_the_next_try_waits(tmp_path):
    fetch = Counting(lambda s, e: (_ for _ in ()).throw(FetchError("down")))
    clock = [1_800_000_000.0]
    feed = PriceFeed(str(tmp_path / "c"), fetcher=fetch, now=lambda: clock[0])
    feed.refresh()
    feed.refresh()
    assert len(fetch.calls) == 3          # the second pass skipped all three
    clock[0] += 3700
    feed.refresh()
    assert len(fetch.calls) == 6


def test_offline_makes_no_request_at_all(tmp_path):
    fetch = Counting(file_fetcher(catalogue_files(tmp_path)))
    feed = PriceFeed(str(tmp_path / "c"), offline=True, fetcher=fetch)
    report = feed.refresh()
    assert fetch.calls == [] and len(report.skipped) == 3 and not report.changed


def test_going_offline_during_a_pass_stops_the_rest(tmp_path):
    state = {"stop": False}

    def fetch(source, etag):
        state["stop"] = True
        return file_fetcher(catalogue_files(tmp_path))(source, etag)
    feed = PriceFeed(str(tmp_path / "c"), fetcher=fetch, should_stop=lambda: state["stop"])
    report = feed.refresh()
    assert len(report.updated) == 1 and len(report.skipped) == 2


def test_a_cache_stamped_in_the_future_is_stale(tmp_path):
    cache = str(tmp_path / "cache")
    PriceFeed(cache, fetcher=file_fetcher(catalogue_files(tmp_path)), now=lambda: 2_000_000_000.0).refresh()
    fetch = Counting(file_fetcher(catalogue_files(tmp_path)))
    PriceFeed(cache, fetcher=fetch, now=lambda: 1_800_000_000.0).refresh()
    assert len(fetch.calls) == 3


def test_a_cache_file_with_a_corrupt_row_loses_the_row_not_the_app(tmp_path):
    cache = tmp_path / "cache"
    cache.mkdir()
    (cache / "prices-litellm.json").write_text(json.dumps({"schema": 1, "source": "litellm", "fetched": 1.0, "rows": {
        "bad": [1e308, 2, 0, 0, 0, []], "good": [1, 2, 0, 0, 0, []], "tier": [1, 2, 0, 0, 0, [[10 ** 40, 1, 1, 0, 0, 0]]]}}))
    feed = PriceFeed(str(cache))
    c = feed.read_cache("litellm")
    assert set(c.rows) == {"good"}
    (cache / "prices-litellm.json").write_text("{not json")
    assert feed.read_cache("litellm") is None
    cats, origins = feed.load_local()
    assert origins["litellm"].startswith("snapshot")


def test_no_infinity_is_ever_written_to_a_cache(tmp_path):
    from tokenbar.prices.feed import _write_json
    p = tmp_path / "x.json"
    _write_json(str(p), {"a": float("inf")})
    assert not p.exists()


def test_the_book_follows_the_offline_switch_and_the_environment(tmp_path, monkeypatch):
    from tokenbar.paths import Env
    env = Env.from_os({"USERPROFILE": str(tmp_path), "APPDATA": str(tmp_path / "r"), "LOCALAPPDATA": str(tmp_path / "l")})
    book = PriceBook(env, pinned=False, offline=False)
    assert not book.is_offline
    book.set_offline(True)
    assert book.is_offline and book.refresh() is None
    env2 = Env.from_os({"USERPROFILE": str(tmp_path), "APPDATA": str(tmp_path / "r"), "LOCALAPPDATA": str(tmp_path / "l"), "TOKENBAR_OFFLINE": "yes"})
    assert PriceBook(env2, pinned=False).is_offline


def test_alias_file_is_read_unless_pinned(tmp_path):
    from tokenbar.paths import Env
    env = Env.for_home(str(tmp_path / "h"))
    os.makedirs(env.config_dir())
    open(env.aliases_path(), "w").write('{"my-model": {"input": 1, "output": 2}}')      # the aliases alone, no "aliases" key
    assert PriceBook(env, pinned=False, offline=True).resolve("x", "my-model")["output"] == 2.0
    assert PriceBook(env, pinned=True, offline=True).resolve("x", "my-model") is None
    open(env.aliases_path(), "w").write("{broken")
    assert PriceBook(env, pinned=False, offline=True).resolve("x", "my-model") is None   # an unreadable file is no aliases
