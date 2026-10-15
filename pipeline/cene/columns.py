"""Mapiranje kolona cenovnika (Pravilnik, prilog) na kanonske ključeve.

Trgovci pišu zaglavlja različito: "Naziv trgovca – formata" (en-crtica), "NAZIV_TRGOVCA",
"BARKOD", "CENA_PO_JM"... Zato poklapamo po ključnim rečima, ne po tačnom tekstu.
"""
from __future__ import annotations

import re

from .text import fold

# redosled je bitan: specifičnije provere pre opštijih
_RULES: list[tuple[str, re.Pattern]] = [
    ("sale_from", re.compile(r"pocet\w* snizenja")),
    ("sale_to", re.compile(r"kraj\w* snizenja")),
    ("sale_price", re.compile(r"snizen\w* cena")),
    ("unit_price", re.compile(r"cena po (jedinici|jm|j m)")),
    ("price", re.compile(r"redovn\w* cena")),
    ("date", re.compile(r"datum cenovnika")),
    ("category", re.compile(r"naziv kategorije")),
    ("name", re.compile(r"naziv proizvoda")),
    ("format", re.compile(r"naziv trgovca")),
    ("brand", re.compile(r"robna marka|^brend")),
    ("ean", re.compile(r"barkod|^ean|gtin")),
    ("unit", re.compile(r"jedinica mere|^jm$")),
    ("vat", re.compile(r"pdv")),
    ("kind", re.compile(r"vrsta cenovnika")),
    ("sku", re.compile(r"sifra proizvoda")),
    ("category_code", re.compile(r"^kategorija$")),
]

REQUIRED = {"ean", "format", "price", "name"}


def normalize_header(h: str) -> str:
    h = fold(h.strip().strip('"').lstrip("﻿"))
    h = re.sub(r"[_–—\-]+", " ", h)
    return re.sub(r"\s+", " ", h).strip()


def map_columns(headers: list[str]) -> dict[str, int]:
    """Vrati {kanonski_ključ: indeks kolone}."""
    out: dict[str, int] = {}
    for i, raw in enumerate(headers):
        h = normalize_header(raw)
        for key, rx in _RULES:
            if key not in out and rx.search(h):
                out[key] = i
                break
    return out


def is_price_list(headers: list[str]) -> bool:
    return REQUIRED <= map_columns(headers).keys()


def sniff_delimiter(first_line: str) -> str:
    return max(";,\t|", key=first_line.count)
