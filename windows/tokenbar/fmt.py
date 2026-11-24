"""Numbers as people read them."""
from __future__ import annotations

from .i18n import lang, t
from .report import PERIOD_ORDER


def tokens(n: int) -> str:
    """1.2M, 113.6K ... The unit is chosen after the rounding (the Mac's `UsageText.tokens`): 999 950 is "1M" (999.95K
    rounds to 1000.0), never "1000K"; the band below it keeps its tenth ("999.9K") where whole thousands would say 1000."""
    n = int(n)
    for unit, size, first in (("B", 10 ** 9, 999_950_000), ("M", 10 ** 6, 999_950), ("K", 10 ** 3, 1000)):
        if n >= first:
            v = n / size
            if 100 <= v < 999.5 or v >= 1000:
                text = f"{v:.0f}"
            elif v >= 10:
                text = f"{v:.1f}"
            else:
                text = f"{v:.2f}"
            if "." in text:
                text = text.rstrip("0").rstrip(".")
            return text + unit
    return str(n)


def money(v: float) -> str:
    if v >= 1000:
        return f"${v:,.0f}"
    if v >= 100:
        return f"${v:.0f}"
    if v >= 1:
        return f"${v:.2f}"
    if v >= 0.01:
        return f"${v:.2f}"
    if v > 0:
        return "<$0.01"
    return "$0"


def rate(v: float) -> str:
    """USD per 1M tokens."""
    if v >= 100:
        return f"{v:.0f}"
    if v >= 10:
        return f"{v:.1f}".rstrip("0").rstrip(".")
    if 0 < v < 0.1:
        # Three decimals once two would round a small paid price to 0 (the Mac app's rate(): $0.001 is not $0). A price
        # that three decimals still round to 0 stays "0.000", visibly a rounded number and not "free".
        three = f"{v:.3f}"
        return three.rstrip("0").rstrip(".") if float(three) > 0 else three
    return f"{v:.2f}".rstrip("0").rstrip(".") if v else "0"


def calls(n: int) -> str:
    return f"{n:,} " + t("çağrı", "calls" if n != 1 else "call")


def period_label(p: str) -> str:
    return {
        "1h": t("1 saat", "1 hour"), "5h": t("5 saat", "5 hours"), "24h": t("24 saat", "24 hours"),
        "7d": t("7 gün", "7 days"), "30d": t("30 gün", "30 days"), "all": t("Tümü", "All time"),
    }[p]


def period_short(p: str) -> str:
    return {"1h": t("1sa", "1h"), "5h": t("5sa", "5h"), "24h": t("24sa", "24h"), "7d": t("7g", "7d"),
            "30d": t("30g", "30d"), "all": t("Tümü", "All")}[p]
