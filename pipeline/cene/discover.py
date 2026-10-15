"""Pronalazi cenovnike po Pravilniku (Sl. glasnik 76/2026) na data.gov.rs.

Pretraga portala je nepouzdana, pa prolazimo kroz ceo katalog i za svaki CSV resurs
proveravamo zaglavlje. Rezultat: sources.json (lista resursa koje ingest skida).
"""
from __future__ import annotations

import argparse
import json
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from .columns import is_price_list, sniff_delimiter
from .http import HttpError, get_head_bytes, get_json
from .text import decode_bytes

API = "https://data.gov.rs/api/1/datasets/"


def iter_datasets(page_size: int = 100):
    page = 1
    while True:
        data = get_json(f"{API}?page_size={page_size}&page={page}")
        yield from data["data"]
        if not data.get("next_page"):
            break
        page += 1


def csv_resources(ds: dict):
    for r in ds.get("resources", []):
        fmt = (r.get("format") or "").lower()
        url = r.get("url") or ""
        if fmt == "csv" or url.lower().split("?")[0].endswith(".csv"):
            yield r


def check_header(url: str) -> tuple[list[str], str] | None:
    try:
        head = get_head_bytes(url, 8192)
    except HttpError:
        return None
    text = decode_bytes(head)
    first = text.splitlines()[0] if text else ""
    delim = sniff_delimiter(first)
    cols = first.split(delim)
    if is_price_list(cols):
        return [c.strip().lstrip("﻿") for c in cols], delim
    return None


def discover(workers: int = 16, log=print) -> list[dict]:
    cands = []
    n = 0
    for ds in iter_datasets():
        n += 1
        org = (ds.get("organization") or {})
        for r in csv_resources(ds):
            cands.append({
                "dataset_id": ds["id"],
                "dataset": ds.get("title"),
                "org_id": org.get("id"),
                "org": (org.get("name") or "").strip(),
                "resource_id": r.get("id"),
                "url": r["url"],
                "last_modified": r.get("last_modified") or ds.get("last_modified"),
            })
    log(f"dataseta: {n}, CSV resursa: {len(cands)}")

    with ThreadPoolExecutor(workers) as ex:
        results = list(ex.map(lambda c: check_header(c["url"]), cands))

    out = []
    for c, res in zip(cands, results):
        if res:
            c["columns"], c["delimiter"] = res
            out.append(c)
    log(f"cenovnika po Pravilniku: {len(out)} od {len({c['org'] for c in out})} trgovaca")
    return out


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", default="data/sources.json")
    ap.add_argument("--workers", type=int, default=16)
    a = ap.parse_args(argv)
    src = discover(a.workers, log=lambda m: print(m, file=sys.stderr))
    p = Path(a.out)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(src, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"upisano {len(src)} -> {p}", file=sys.stderr)


if __name__ == "__main__":
    main()
