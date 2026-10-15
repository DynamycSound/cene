"""Parsiranje vrednosti iz cenovnika (cene, datumi, barkodovi)."""
from __future__ import annotations

import re
from datetime import date

from .text import norm_ean

_DATE_RX = [
    (re.compile(r"^(\d{1,2})[-./](\d{1,2})[-./](\d{4})"), ("d", "m", "y")),
    (re.compile(r"^(\d{4})[-./](\d{1,2})[-./](\d{1,2})"), ("y", "m", "d")),
]


def parse_date(s: str | None) -> str | None:
    """'01-09-2026' / '1.9.2026.' / '2026-09-01' -> '2026-09-01'. Nevažeće -> None."""
    s = (s or "").strip()
    if not s:
        return None
    for rx, order in _DATE_RX:
        m = rx.match(s)
        if m:
            parts = dict(zip(order, map(int, m.groups())))
            try:
                return date(parts["y"], parts["m"], parts["d"]).isoformat()
            except ValueError:
                return None
    return None


def parse_price(s: str | None) -> float | None:
    """'1.299,99' / '1299.99' / '1 299,99 din' -> 1299.99. Prazno ili <= 0 -> None."""
    s = (s or "").strip().replace("\xa0", "").replace(" ", "")
    s = re.sub(r"[^\d.,\-]", "", s)
    if not s:
        return None
    if "," in s and "." in s:
        # poslednji separator je decimalni
        if s.rfind(",") > s.rfind("."):
            s = s.replace(".", "").replace(",", ".")
        else:
            s = s.replace(",", "")
    elif "," in s:
        s = s.replace(",", ".")
    elif s.count(".") > 1:
        s = s.replace(".", "")
    try:
        v = float(s)
    except ValueError:
        return None
    return round(v, 2) if v > 0 else None


def product_key(ean_raw: str, chain_slug: str) -> str | None:
    """Ključ za spajanje proizvoda između lanaca.

    GTIN-8/12/13/14 se poredi globalno. Interne šifre (prefiks 2 = vaga/interno kod GS1,
    ili prekratke) važe samo unutar jednog lanca.
    """
    digits = re.sub(r"\D", "", ean_raw or "")
    e = norm_ean(digits)
    if not e:
        return None
    full = digits.zfill(13) if len(digits) <= 13 else digits
    if len(e) < 8 or full.startswith("2"):
        return f"{chain_slug}:{e}"
    return e
