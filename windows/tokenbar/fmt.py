"""Numbers as people read them."""
from __future__ import annotations

from .i18n import lang, t
from .report import PERIOD_ORDER


def tokens(n: int) -> str:
    n = int(n)
    for unit, size in (("B", 10 ** 9), ("M", 10 ** 6), ("K", 10 ** 3)):
        if n >= size:
            v = n / size
            text = f"{v:.0f}" if v >= 100 else f"{v:.1f}" if v >= 10 else f"{v:.2f}"
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
