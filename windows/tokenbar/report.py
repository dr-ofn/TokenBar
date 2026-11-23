"""Turns the index into one period's report: tool -> model -> tokens and dollars."""
from __future__ import annotations

import math
import time
from dataclasses import dataclass, field

from .catalog import harness_name, harness_of_key
from .prices.engine import normalize
from .util import clamp

PERIODS = {"1h": 3600, "5h": 5 * 3600, "24h": 24 * 3600, "7d": 7 * 24 * 3600, "30d": 30 * 24 * 3600, "all": None}
PERIOD_ORDER = ["1h", "5h", "24h", "7d", "30d", "all"]


@dataclass
class ModelStat:
    harness: str
    provider: str
    model: str
    inp: int = 0
    cr: int = 0
    cw: int = 0
    out: int = 0
    rz: int = 0
    calls: int = 0
    cost: float = 0.0
    entry: dict | None = None

    @property
    def id(self) -> str:
        return self.provider + "/" + self.model

    @property
    def tokens(self) -> int:
        return self.inp + self.cr + self.cw + self.out

    @property
    def name(self) -> str:
        return (self.entry or {}).get("name") or self.model

    @property
    def priced(self) -> bool:
        return self.entry is not None


@dataclass
class HarnessStat:
    harness: str
    models: list = field(default_factory=list)
    tokens: int = 0
    calls: int = 0
    cost: float = 0.0

    @property
    def name(self) -> str:
        return harness_name(self.harness)


@dataclass
class Report:
    period: str
    harnesses: list = field(default_factory=list)
    tokens: int = 0
    calls: int = 0
    cost: float = 0.0
    unpriced: list = field(default_factory=list)    # model ids with no price


def build_report(store, book, period: str = "24h", now: float | None = None) -> Report:
    """One period of the index, priced by `book`. Adjustment rows (tokens a tool recorded without a call of its own)
    count in tokens and cost but not as calls, and carry no price tier: their prompt total says nothing about one."""
    if period not in PERIODS:
        raise ValueError(f"unknown window: {period}")
    span = PERIODS[period]
    cutoff = (now if now is not None else time.time()) - span if span else None
    stats: dict[tuple, ModelStat] = {}
    for key, provider, model, ts, inp, cr, cw, out, rz, cw1h in store.events_since(cutoff):
        adjustment = key.split(":", 2)[1:2] == ["adj"]
        harness = harness_of_key(key)
        s = stats.get((harness, provider, model))
        if s is None:
            s = stats[(harness, provider, model)] = ModelStat(harness, provider, model, entry=book.resolve(provider, model))
        cost, _ = book.cost(provider, model, inp, cr, cw, out, cw1h, tiered=not adjustment)
        if not math.isfinite(cost) or cost < 0:
            cost = 0.0
        s.inp = clamp(s.inp + inp)
        s.cr = clamp(s.cr + cr)
        s.cw = clamp(s.cw + cw)
        s.out = clamp(s.out + out)
        s.rz = clamp(s.rz + rz)
        s.calls += 0 if adjustment else 1
        s.cost += cost
    report = Report(period)
    by_harness: dict[str, HarnessStat] = {}
    for (harness, _, _), s in stats.items():
        h = by_harness.setdefault(harness, HarnessStat(harness))
        h.models.append(s)
        h.tokens += s.tokens
        h.calls += s.calls
        h.cost += s.cost
    for h in by_harness.values():
        h.models.sort(key=lambda m: (-m.tokens, m.id))
    # Models that ran with nothing to price them by. Two names that normalise alike are one model, listed once:
    # the first met, harnesses in name order (as the Mac app does).
    groups: set[str] = set()
    for harness in sorted(by_harness):
        for m in by_harness[harness].models:
            if not m.priced and normalize(m.model) not in groups:
                groups.add(normalize(m.model))
                report.unpriced.append(m.id)
    report.harnesses = sorted(by_harness.values(), key=lambda h: (-h.tokens, h.harness))
    report.tokens = sum(h.tokens for h in report.harnesses)
    report.calls = sum(h.calls for h in report.harnesses)
    report.cost = sum(h.cost for h in report.harnesses)
    report.unpriced.sort()
    return report


def price_per_million(s: ModelStat):
    """(input, output) USD per 1M tokens of a model's base rate, or None when it has no price."""
    return (s.entry["input"], s.entry["output"]) if s.entry else None


def to_json(report: Report, detected: list[str]) -> dict:
    """The Mac CLI's `--json` shape: total, calls, cost, harnesses, unpriced, detected."""
    harnesses = {}
    for h in report.harnesses:
        harnesses[h.harness] = {
            "total": h.tokens, "calls": h.calls, "cost": h.cost,
            "models": {m.id: [m.tokens, m.calls, m.inp, m.cr, m.cw, m.out, m.rz] for m in h.models}}
    def finite(v):
        return v if math.isfinite(v) else 0.0
    for h in harnesses.values():
        h["cost"] = finite(h["cost"])
    return {"window": report.period, "total": report.tokens, "calls": report.calls, "cost": finite(report.cost),
            "unpriced": report.unpriced, "harnesses": harnesses, "detected": detected}
