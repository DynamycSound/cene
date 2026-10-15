"""Pravi cene.sqlite (+ .gz) za aplikaciju: lanci, formati, proizvodi, cene, radnje."""
from __future__ import annotations

import argparse
import gzip
import json
import re
import shutil
import sqlite3
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

from .ingest_gov import Chain, Row, ingest, load_chains
from .maxi_images import name_key
from .names import BAD_BRANDS, clean_name, pick_brand, tokens
from .text import fold

SCHEMA_VERSION = 2

SCHEMA = """
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE chains(id INTEGER PRIMARY KEY, slug TEXT UNIQUE, name TEXT, color TEXT, kind TEXT,
                    url TEXT, search_url TEXT);
CREATE TABLE formats(id INTEGER PRIMARY KEY, chain_id INTEGER, name TEXT);
CREATE TABLE categories(id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE products(id INTEGER PRIMARY KEY, ean TEXT, name TEXT, brand TEXT, unit TEXT,
                      category_id INTEGER, image TEXT, search TEXT, n_chains INTEGER, image_big TEXT);
-- datumi kao INTEGER yyyymmdd (manja baza)
CREATE TABLE prices(product_id INTEGER, format_id INTEGER, price REAL, unit_price REAL,
                    sale_price REAL, sale_from INTEGER, sale_to INTEGER, date INTEGER, url TEXT,
                    PRIMARY KEY(product_id, format_id)) WITHOUT ROWID;
CREATE TABLE stores(id INTEGER PRIMARY KEY, chain_id INTEGER, format_id INTEGER, name TEXT,
                    address TEXT, city TEXT, lat REAL, lon REAL, osm_id TEXT);
CREATE INDEX prices_format ON prices(format_id);
CREATE INDEX products_ean ON products(ean);
CREATE INDEX stores_chain ON stores(chain_id);
"""



def _pick(values: list[str], bad: set[str] = frozenset()) -> str:
    vals = [v for v in values if fold(v).strip() not in bad]
    if not vals:
        return ""
    c = Counter(vals)
    top = max(c.values())
    # najčešći naziv; kod nerešenog najduži (obično najopisniji)
    return max((v for v in c if c[v] == top), key=len)


def generic_words(by_key: dict[str, list[Row]], brand_of: dict[str, str], min_brands: int = 60) -> set[str]:
    """Reči iz naziva proizvoda mnogo različitih brendova („voda“, „mleko“) – nikad se ne vade kao deo brenda."""
    brands_of_word: dict[str, set[str]] = defaultdict(set)
    for key, rs in by_key.items():
        b = fold(brand_of[key])
        for name in {r.name for r in rs}:
            for t in tokens(name):
                if t.kind == "word":
                    brands_of_word[t.key].add(b)
    return {w for w, bs in brands_of_word.items() if len(bs) >= min_brands}


def _d(iso: str | None) -> int | None:
    return int(iso.replace("-", "")) if iso else None


def search_text(names: list[str]) -> str:
    """Jedinstvene reči iz svih naziva (svaki lanac piše naziv drugačije), bez dijakritika."""
    words = re.findall(r"[a-z0-9]+(?:[.,][0-9]+)?", fold(" ".join(n for n in names if n)))
    return " ".join(dict.fromkeys(words))


def build(rows: dict, chains: list[Chain], out: Path, stores: list[dict] | None = None,
          report: list[dict] | None = None, maxi_images: dict[str, list[str]] | None = None) -> dict:
    if out.exists():
        out.unlink()
    db = sqlite3.connect(out)
    db.executescript(SCHEMA)

    chain_id = {}
    for i, c in enumerate(sorted(chains, key=lambda c: c.name.lower()), 1):
        chain_id[c.slug] = i
        db.execute("INSERT INTO chains VALUES(?,?,?,?,?,?,?)",
                   (i, c.slug, c.name, c.color, c.kind, c.url, c.search_url))

    fmt_id: dict[tuple, int] = {}
    by_key: dict[str, list[Row]] = defaultdict(list)
    for r in rows.values():
        by_key[r.key].append(r)
        fk = (r.chain, r.format)
        if fk not in fmt_id:
            fmt_id[fk] = len(fmt_id) + 1
    db.executemany("INSERT INTO formats VALUES(?,?,?)",
                   [(i, chain_id[c], f) for (c, f), i in fmt_id.items()])

    brand_of = {key: pick_brand([r.brand for r in rs]) for key, rs in by_key.items()}
    generic = generic_words(by_key, brand_of)

    cat_id: dict[str, int] = {}
    prod_rows, price_rows = [], []
    for pid, (key, rs) in enumerate(sorted(by_key.items()), 1):
        brand = brand_of[key]
        per_chain = list({r.chain: r.name for r in rs}.values())
        other_brands = {t.key for r in rs if fold(r.brand or "").strip() not in BAD_BRANDS
                        for t in tokens(r.brand) if t.kind == "word"}
        name = clean_name(per_chain, brand, other_brands, generic) or _pick([r.name for r in rs])
        image = next((r.image for r in rs if r.image), None)
        image_big = image
        if not image and maxi_images:
            # Maxi online ima iste nazive kao Maxi cenovnik
            hit = next((maxi_images[k] for r in rs if r.chain == "maxi"
                        and (k := name_key(r.name)) in maxi_images), None)
            if hit:
                image, image_big = hit
        cat = _pick([r.category for r in rs])
        cid = cat_id.setdefault(cat, len(cat_id) + 1) if cat else None
        prod_rows.append((pid, rs[0].ean, name, brand, _pick([r.unit for r in rs]), cid, image,
                          search_text([name, brand, *(r.name for r in rs)]),
                          len({r.chain for r in rs}), image_big))
        for r in rs:
            price_rows.append((pid, fmt_id[(r.chain, r.format)], r.price, r.unit_price,
                               r.sale_price, _d(r.sale_from), _d(r.sale_to), _d(r.date), r.url))
    db.executemany("INSERT INTO categories VALUES(?,?)", [(i, n) for n, i in cat_id.items()])
    db.executemany("INSERT INTO products VALUES(?,?,?,?,?,?,?,?,?,?)", prod_rows)
    db.executemany("INSERT INTO prices VALUES(?,?,?,?,?,?,?,?,?)", price_rows)

    formats_of: dict[str, list[int]] = defaultdict(list)
    for (c, _), i in fmt_id.items():
        formats_of[c].append(i)
    for s in stores or []:
        cid = chain_id.get(s["chain"])
        if cid is None:
            continue
        fid = fmt_id.get((s["chain"], s.get("format"))) if s.get("format") else None
        if fid is None and len(formats_of[s["chain"]]) == 1:
            fid = formats_of[s["chain"]][0]  # lanac sa jednim cenovnikom važi za sve radnje
        db.execute("INSERT INTO stores(chain_id,format_id,name,address,city,lat,lon,osm_id) "
                   "VALUES(?,?,?,?,?,?,?,?)",
                   (cid, fid, s.get("name"), s.get("address"), s.get("city"), s["lat"], s["lon"],
                    s.get("osm_id")))

    stats = {
        "built_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "schema": SCHEMA_VERSION,
        "chains": len(chains), "formats": len(fmt_id), "products": len(prod_rows),
        "prices": len(price_rows), "stores": len(stores or []),
        "multi_chain_products": sum(1 for p in prod_rows if p[8] > 1),
        "products_with_image": sum(1 for p in prod_rows if p[6]),
    }
    for k, v in stats.items():
        db.execute("INSERT INTO meta VALUES(?,?)", (k, str(v)))
    db.execute("INSERT INTO meta VALUES('sources', ?)", (json.dumps(report or [], ensure_ascii=False),))
    db.commit()
    db.execute("VACUUM")
    db.close()
    return stats


def gzip_file(src: Path) -> Path:
    dst = src.with_suffix(src.suffix + ".gz")
    with open(src, "rb") as f, gzip.open(dst, "wb", compresslevel=9) as g:
        shutil.copyfileobj(f, g)
    return dst


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--sources", default="data/sources.json")
    ap.add_argument("--chains", default="data/chains.json")
    ap.add_argument("--stores", default="data/stores.json")
    ap.add_argument("--images", default="data/images_maxi.json")
    ap.add_argument("--out", default="dist/cene.sqlite")
    ap.add_argument("--max-error-ratio", type=float, default=0.3)
    a = ap.parse_args(argv)
    log = lambda m: print(m, file=sys.stderr)

    chains = load_chains(Path(a.chains))
    sources = json.loads(Path(a.sources).read_text("utf-8"))
    rows, used, report = ingest(sources, chains, log=log)

    # tehnika (Gigatron, Uspon – pretraga uživo sa telefona; Tehnomanija – samo link) ide u bazu bez cena
    used += [c for c in chains if c.kind in ("web", "link") and c not in used]

    stores_p = Path(a.stores)
    stores = json.loads(stores_p.read_text("utf-8")) if stores_p.exists() else []

    images_p = Path(a.images)
    maxi_images = json.loads(images_p.read_text("utf-8")) if images_p.exists() else {}

    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    stats = build(rows, used, out, stores, report, maxi_images)
    gz = gzip_file(out)
    stats["sqlite_mb"] = round(out.stat().st_size / 1e6, 1)
    stats["gz_mb"] = round(gz.stat().st_size / 1e6, 1)
    errors = [r for r in report if r["error"]]
    stats["source_errors"] = len(errors)
    (out.parent / "manifest.json").write_text(json.dumps(stats, indent=1), "utf-8")
    print(json.dumps(stats, indent=1))
    if not sources or len(errors) / len(sources) > a.max_error_ratio:
        log(f"previše neuspelih izvora: {len(errors)}/{len(sources)}")
        sys.exit(1)


if __name__ == "__main__":
    main()
