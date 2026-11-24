"""9.0.6: scripts/pricelib.py takes the catalogue hardening the apps have, and scripts/oracle.py the `adj` rule."""
import importlib.util
import json
import math
import os
import shutil
import subprocess
import sys

import pytest

from conftest import claude_line

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPTS = os.path.join(ROOT, "scripts")
pytestmark = pytest.mark.skipif(not os.path.isfile(os.path.join(SCRIPTS, "pricelib.py")), reason="the scripts folder is not beside windows/")


@pytest.fixture(scope="module")
def pricelib():
    sys.path.insert(0, SCRIPTS)
    try:
        import pricelib as module
        yield module
    finally:
        sys.path.remove(SCRIPTS)


# ---------------------------------------------------------------- pricelib: JSON true/false and non-finite numbers are no prices
def test_litellm_bool_prices_are_not_prices(pricelib):
    rows = pricelib.litellm_rows({
        "t-ok": {"input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6},
        "t-bool-in": {"input_cost_per_token": True, "output_cost_per_token": 2e-6},
        "t-bool-out": {"input_cost_per_token": 1e-6, "output_cost_per_token": True},
        "t-bool-cache": {"input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6, "cache_read_input_token_cost": True},
        "t-bool-tier": {"input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6, "input_cost_per_token_above_200k_tokens": True},
    })
    assert set(rows) == {"t-ok", "t-bool-cache", "t-bool-tier"}                 # a bool price leaves the row without a price: dropped
    assert rows["t-bool-cache"][2] == 0.0                                        # a bool cache price is 0 ("not said"), never $1M/M
    assert rows["t-bool-tier"][5] == []                                          # a bool tier price is no tier


@pytest.mark.parametrize("bad", [float("inf"), float("nan"), 1e999, "1e999", "inf", "nan", 5.0, 1e10])
def test_litellm_rates_that_are_not_finite_or_far_too_big_are_dropped(pricelib, bad):
    rows = pricelib.litellm_rows({"t": {"input_cost_per_token": bad, "output_cost_per_token": 2e-6},
                                  "ok": {"input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6}})
    assert set(rows) == {"ok"}                                                    # 5 USD per token is 5,000,000 per million: over the bound
    for row in rows.values():
        assert all(math.isfinite(x) for x in row[:5])


def test_litellm_tier_thresholds_that_cannot_exist_drop_the_row(pricelib):
    base = {"input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6}
    rows = pricelib.litellm_rows({"huge": {**base, "input_cost_per_token_above_99999999999999k_tokens": 2e-6},
                                  "zero": {**base, "input_cost_per_token_above_0k_tokens": 2e-6},
                                  "ok": {**base, "input_cost_per_token_above_200k_tokens": 2e-6}})
    assert set(rows) == {"ok"} and rows["ok"][5][0][0] == 200_001


def test_modelsdev_bool_and_non_finite_prices_are_dropped(pricelib):
    raw = {"p": {"models": {
        "ok": {"cost": {"input": 1, "output": 2}, "name": "Nice"},
        "bool": {"cost": {"input": True, "output": 2}},
        "overbool": {"cost": {"input": 1, "output": 2, "context_over_200k": {"input": True, "output": 3}}},
        "tierbool": {"cost": {"input": 1, "output": 2, "tiers": [{"tier": {"type": "context", "size": True}, "input": 5}]}},
        "inf": {"cost": {"input": 1e999, "output": 2}},
        "big": {"cost": {"input": 2_000_000, "output": 2}},
        "badname": {"cost": {"input": 1, "output": 2}, "name": 42}}}}
    rows = pricelib.modelsdev_rows(raw)
    # a bool price is 0, so a row (or tier) that needs it is dropped; a tier size that is a bool is a corrupt row
    assert set(rows) == {"p/ok", "p/badname"}, rows
    assert rows["p/ok"][6] == "Nice" and rows["p/badname"][6] == ""              # a name that is no string is no name


def test_openrouter_bool_and_non_finite_prices_are_dropped(pricelib):
    rows = pricelib.openrouter_rows({"data": [
        {"id": "a/ok", "name": "Vendor: Nice", "pricing": {"prompt": "0.000001", "completion": "0.000002"}},
        {"id": "a/bool", "pricing": {"prompt": True, "completion": "0.000002"}},
        {"id": "a/inf", "pricing": {"prompt": 1e999, "completion": "0.000002"}},
        {"id": "a/neg", "pricing": {"prompt": "-1", "completion": "-1"}},
        {"id": 7, "pricing": {"prompt": "1", "completion": "1"}},
        {"id": "a/name", "name": 12, "pricing": {"prompt": "0.000001", "completion": "0.000002"}}]})
    assert set(rows) == {"a/ok", "a/name"}
    assert rows["a/ok"][6] == "Nice" and rows["a/name"][6] == ""


def test_parsers_survive_a_catalogue_of_the_wrong_shape(pricelib):
    for junk in (None, [], "x", 5):
        assert pricelib.litellm_rows(junk) == {} and pricelib.modelsdev_rows(junk) == {} and pricelib.openrouter_rows(junk) == {}


def test_per_million_of_a_bool_or_infinity_is_zero(pricelib):
    assert [pricelib.per_million(v) for v in (True, False, None, float("inf"), 1e999, "x", "0.000001")] == [0, 0, 0, 0, 0, 0, 1.0]


# ---------------------------------------------------------------- update-prices.py: nothing but finite, sane rows reach the embedded snapshot
def _update_prices(tmp_path, litellm, modelsdev):
    """Runs update-prices.py from a copy of scripts/ so its output lands in tmp_path, never in the repo."""
    work = tmp_path / "repo"
    shutil.copytree(SCRIPTS, work / "scripts", ignore=shutil.ignore_patterns("__pycache__"))
    (work / "Sources" / "LocalCore").mkdir(parents=True)
    (work / "windows" / "tokenbar" / "data").mkdir(parents=True)
    (tmp_path / "ll.json").write_text(json.dumps(litellm))
    (tmp_path / "md.json").write_text(json.dumps(modelsdev))
    proc = subprocess.run([sys.executable, "-I", str(work / "scripts" / "update-prices.py"), "--only", "snapshot",
                           "--litellm", str(tmp_path / "ll.json"), "--modelsdev", str(tmp_path / "md.json")],
                          capture_output=True, text=True, cwd=str(work))
    return proc, work / "windows" / "tokenbar" / "data" / "prices-snapshot.json"


def test_snapshot_never_holds_infinity_or_a_bool_made_price(tmp_path):
    ll = {"t-ok": {"input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6},
          "t-bool-in": {"input_cost_per_token": True, "output_cost_per_token": 2e-6},
          "t-inf": {"input_cost_per_token": 1e999, "output_cost_per_token": 2e-6},
          "t-big": {"input_cost_per_token": 5, "output_cost_per_token": 5}}
    md = {"prov": {"models": {"ok": {"cost": {"input": 1, "output": 2}}, "bool": {"cost": {"input": True, "output": 2}}}}}
    proc, snapshot = _update_prices(tmp_path, ll, md)
    assert proc.returncode == 0, proc.stderr
    text = snapshot.read_text()
    assert "Infinity" not in text and "NaN" not in text
    data = json.loads(text)                                                       # strict JSON, as Swift's JSONSerialization reads it
    assert set(data["litellm"]) == {"t-ok"} and set(data["modelsdev"]) == {"prov/ok"}


def test_snapshot_builder_refuses_a_row_that_fails_the_sanity_rule(tmp_path, monkeypatch, pricelib):
    spec = importlib.util.spec_from_file_location("update_prices", os.path.join(SCRIPTS, "update-prices.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    monkeypatch.setattr(module, "ROOT", str(tmp_path))
    monkeypatch.setattr(module.pricelib, "litellm_rows", lambda raw: {"t-inf": [float("inf"), 2.0, 0.0, 0.0, 0.0, []]})
    monkeypatch.setattr(module.pricelib, "modelsdev_rows", lambda raw: {})
    (tmp_path / "ll.json").write_text("{}")
    with pytest.raises(SystemExit) as stop:
        module.build_snapshot(str(tmp_path / "ll.json"), str(tmp_path / "ll.json"))
    assert "t-inf" in str(stop.value) or "JSON cannot write" in str(stop.value) or "sanity" in str(stop.value)
    assert not (tmp_path / "Sources" / "LocalCore" / "Resources" / "prices-snapshot.json").exists()      # nothing was written


# ---------------------------------------------------------------- oracle.py counts a call whose id is `adj` as the apps do
@pytest.mark.skipif(sys.platform == "win32", reason="scripts/oracle.py is the macOS twin (it reads the macOS tool folders and imports pwd)")
def test_oracle_counts_calls_whose_id_is_adj_like_the_app(home):
    cost = '{"type":"cost-state",' + json.dumps({"sessionId": "s1", "startTime": "2026-11-06T10:00:00.000Z",
        "modelUsage": {"claude-haiku-5-5": {"inputTokens": 620}}}, separators=(",", ":"))[1:] + "\n"
    home.write(".claude/projects/p/a.jsonl", json.dumps(claude_line("adj", "r1", 600, 0, model="claude-haiku-5-5")) + "\n" + cost)
    row = {"type": "say", "say": "api_req_started", "ts": 1793968800000,
           "text": json.dumps({"tokensIn": 250_000, "tokensOut": 100, "cacheReads": 0, "cacheWrites": 0}),
           "modelInfo": {"modelId": "claude-sonnet-4-20250514", "providerId": "anthropic"}}
    home.write(".cline/data/tasks/adj/ui_messages.json", json.dumps([row]))
    home.scan()
    mine = home.report()
    env = {"HOME": home.root, "PATH": os.environ.get("PATH", ""), "TOKENBAR_PRICES_PINNED": "1"}
    proc = subprocess.run([sys.executable, os.path.join(SCRIPTS, "oracle.py"), "all"], capture_output=True, text=True, env=env, cwd=home.root)
    assert proc.returncode == 0, proc.stderr
    oracle = json.loads(proc.stdout)
    assert (oracle["total"], oracle["calls"]) == (mine.tokens, mine.calls) == (620 + 250_100, 2)
    assert oracle["cost"] == pytest.approx(mine.cost, rel=1e-6)
