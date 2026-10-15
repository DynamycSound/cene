"""Slike proizvoda sa maxi.rs (fotografije pakovanja na belom), vezane za naziv iz Maxi cenovnika.

Maxi online i zvanični Maxi cenovnik koriste iste nazive proizvoda, a sajt ne prikazuje barkod – zato se
spaja po nazivu. Čitaju se stranice kategorija preko istog API-ja koji koristi njihov sajt (robots.txt
zabranjuje samo pretragu, nalog i korpu), polako: jedan zahtev u sekundi, ~150 zahteva ukupno.

    python -m cene.maxi_images -o data/images_maxi.json
"""
from __future__ import annotations

import argparse
import gzip
import json
import re
import sys
import time
import urllib.parse
from pathlib import Path

from .http import BROWSER_UA, get_bytes
from .text import fold

SITE = "https://www.maxi.rs"
STATIC = "https://static.maxi.rs"
# „persisted query“ njihovog sajta; kad ga promene, API vrati grešku i ostaje prošli images_maxi.json
QUERY_HASH = "d8bff3916275ffeb6f51604d36d7a3aa2f9cd92847487a7f2e3bdf6bb2115cdd"
PAGE_SIZE = 50  # više od 50 API odbija


def name_key(name: str) -> str:
    return " ".join(re.findall(r"[a-z0-9]+", fold(name)))


def top_categories() -> list[str]:
    idx = get_bytes(f"{SITE}/sitemap/delhaizesitemapindex.xml", {"User-Agent": BROWSER_UA}).decode()
    codes: set[str] = set()
    for loc in re.findall(r"<loc>([^<]+)</loc>", idx):
        raw = get_bytes(loc, {"User-Agent": BROWSER_UA})
        xml = (gzip.decompress(raw) if raw[:2] == b"\x1f\x8b" else raw).decode()
        codes.update(re.findall(r"/c/(\d{2})</loc>", xml))
    return sorted(codes)


def category_page(code: str, page: int) -> dict:
    variables = {"lang": "sr", "searchQuery": "", "category": code, "pageNumber": page, "pageSize": PAGE_SIZE,
                 "filterFlag": True, "fields": "PRODUCT_TILE", "plainChildCategories": True}
    qs = urllib.parse.urlencode({
        "operationName": "GetCategoryProductSearch",
        "variables": json.dumps(variables, separators=(",", ":")),
        "extensions": json.dumps({"persistedQuery": {"version": 1, "sha256Hash": QUERY_HASH}}, separators=(",", ":")),
    })
    raw = get_bytes(f"{SITE}/api/v1/?{qs}", {
        "User-Agent": BROWSER_UA, "content-type": "application/json",
        "x-apollo-operation-name": "GetCategoryProductSearch",
    })
    j = json.loads(raw)
    if j.get("errors") or not j.get("data", {}).get("categoryProductSearch"):
        raise RuntimeError(f"Maxi API greška za kategoriju {code}: {str(j.get('errors'))[:300]}")
    return j["data"]["categoryProductSearch"]


def images_of(product: dict) -> tuple[str | None, str | None]:
    by_fmt = {i.get("format"): i.get("url") for i in product.get("images") or [] if i.get("imageType") == "PRIMARY"}
    small = by_fmt.get("respListGrid") or by_fmt.get("small")
    big = by_fmt.get("zoom") or by_fmt.get("xlarge") or small
    full = lambda u: (STATIC + u) if u and u.startswith("/") else u
    return full(small), full(big)


def fetch(delay: float = 1.0, log=print) -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    for code in top_categories():
        page, pages = 0, 1
        while page < pages:
            s = category_page(code, page)
            pages = s["pagination"]["totalPages"]
            for p in s["products"]:
                small, big = images_of(p)
                if small and p.get("name"):
                    out[name_key(p["name"])] = [small, big]
            page += 1
            time.sleep(delay)
        log(f"kategorija {code}: {pages} strana, ukupno {len(out)} proizvoda sa slikom")
    return out


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", default="data/images_maxi.json")
    ap.add_argument("--delay", type=float, default=1.0)
    a = ap.parse_args(argv)
    imgs = fetch(a.delay, log=lambda m: print(m, file=sys.stderr))
    if len(imgs) < 1000:
        sys.exit(f"premalo slika ({len(imgs)}), ne menjam {a.out}")
    Path(a.out).write_text(json.dumps(imgs, ensure_ascii=False, sort_keys=True, indent=0), "utf-8")
    print(f"{len(imgs)} slika -> {a.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
