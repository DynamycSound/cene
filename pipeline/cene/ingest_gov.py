"""Skida cenovnike sa liste iz discover.py i vraća trenutne cene po (lanac, format, proizvod)."""
from __future__ import annotations

import csv
import io
import json
import re
import sys
import urllib.parse
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

from .columns import map_columns, sniff_delimiter
from .http import UA, get_json
from .parse import parse_date, parse_price, product_key
from .text import fold

csv.field_size_limit(10_000_000)


@dataclass
class Row:
    key: str            # ključ proizvoda (EAN ili "lanac:šifra")
    ean: str
    chain: str          # slug lanca
    format: str         # "Mega Maxi", "Lidl Srbija KD", "MIRIJEVO PRODAVNICA 39"...
    name: str
    brand: str
    unit: str
    category: str
    price: float
    unit_price: float | None
    sale_price: float | None
    sale_from: str | None
    sale_to: str | None
    date: str | None
    snapshot: bool = False   # red iz mesečnog preseka (VRSTA_CENOVNIKA = MESECNI...)
    url: str | None = None
    image: str | None = None


@dataclass
class Chain:
    slug: str
    name: str
    color: str
    kind: str = "gov"
    match: str | None = None
    osm: list[str] = field(default_factory=list)
    url: str | None = None
    search_url: str | None = None


def load_chains(path: Path) -> list[Chain]:
    return [Chain(**{k: v for k, v in c.items()}) for c in json.loads(path.read_text("utf-8"))]


def slugify(s: str) -> str:
    s = fold(s)
    s = re.sub(r"\b(d ?o ?o|doo|d\.o\.o|ad|pr|preduzece|drustvo|za|i|trgovinu|usluge|proizvodnju|promet)\b", " ", s)
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    return s[:40] or "nepoznat"


def chain_for_org(org: str, chains: list[Chain]) -> Chain:
    for c in chains:
        if c.match and re.search(c.match, org, re.I):
            return c
    # nepoznat trgovac: automatski unos, da novi lanci na portalu odmah rade
    name = re.sub(r"\s+(d\.?o\.?o\.?|doo|DOO)\b.*$", "", org, flags=re.I).strip() or org
    return Chain(slug=slugify(org), name=name[:40], color="#607D8B")


def _stream_lines(url: str, timeout: float = 300):
    url = urllib.parse.quote(url.strip(), safe=":/?&=%#+@;,~!$*'()[]")
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    resp = urllib.request.urlopen(req, timeout=timeout)
    raw = resp.read()  # fajlovi su do ~15 MB; dekodiranje celog fajla je pouzdanije od streaming-a
    resp.close()
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        text = raw.decode("cp1250", errors="replace")
    # neki izvozi imaju NUL bajtove (popuna polja) koje csv modul odbija
    return io.StringIO(text.replace("\x00", ""), newline="")


def fresh_url(src: dict) -> str:
    """Fajlovi postavljeni na data.gov.rs dobijaju nov URL pri svakoj izmeni – uzmi trenutni."""
    if not src.get("dataset_id") or not src.get("resource_id"):
        return src["url"]
    ds = get_json(f"https://data.gov.rs/api/1/datasets/{src['dataset_id']}/")
    for r in ds.get("resources", []):
        if r.get("id") == src["resource_id"]:
            return r["url"]
    raise LookupError(f"resurs {src['resource_id']} više ne postoji u datasetu {src['dataset_id']}")


def parse_csv(f, chain: Chain, delimiter: str | None = None):
    """Generator Row-ova iz CSV fajla (file-like, tekst)."""
    first = f.readline()
    delim = delimiter or sniff_delimiter(first)
    headers = next(csv.reader([first], delimiter=delim))
    cols = map_columns(headers)
    if not {"ean", "format", "price", "name"} <= cols.keys():
        raise ValueError(f"nepoznat format zaglavlja: {headers}")

    def g(r, k):
        i = cols.get(k)
        return r[i].strip() if i is not None and i < len(r) else ""

    for r in csv.reader(f, delimiter=delim):
        if not r or len(r) < 4:
            continue
        price = parse_price(g(r, "price"))
        key = product_key(g(r, "ean"), chain.slug)
        name = g(r, "name")
        if price is None or not key or not name:
            continue
        yield Row(
            key=key, ean=re.sub(r"\D", "", g(r, "ean")).lstrip("0"), chain=chain.slug,
            format=re.sub(r"\s+", " ", g(r, "format")) or chain.name,
            name=re.sub(r"\s+", " ", name), brand=g(r, "brand"), unit=g(r, "unit"),
            category=g(r, "category"), price=price, unit_price=parse_price(g(r, "unit_price")),
            sale_price=parse_price(g(r, "sale_price")), sale_from=parse_date(g(r, "sale_from")),
            sale_to=parse_date(g(r, "sale_to")), date=parse_date(g(r, "date")),
            snapshot=fold(g(r, "kind")).startswith("mesecn"),
        )


def latest(rows, into: dict | None = None) -> dict:
    """Zadrži samo najnoviji red po (lanac, format, proizvod).

    Fajl sadrži mesečne preseke + važeći cenovnik; trgovac ne mora ponovo objaviti
    nepromenjene cene, pa je "trenutna" cena red sa najnovijim datumom.
    """
    out = {} if into is None else into
    for r in rows:
        k = (r.chain, r.format, r.key)
        old = out.get(k)
        if old is None or (r.date or "") >= (old.date or ""):
            out[k] = r
    return out


def current(rows) -> dict:
    """Trenutne cene iz jednog fajla.

    Proizvod koji nije ni u poslednjem mesečnom preseku ni posle njega je povučen iz
    prodaje (npr. bio je samo u preseku od 1. prošlog meseca) – izbacuje se.
    """
    rows = list(rows)
    last_snap: dict[tuple, str] = {}
    for r in rows:
        if r.snapshot and r.date:
            k = (r.chain, r.format)
            if r.date > last_snap.get(k, ""):
                last_snap[k] = r.date
    out = latest(rows)
    return {k: r for k, r in out.items()
            if (r.date or "") >= last_snap.get((r.chain, r.format), "")}


def ingest(sources: list[dict], chains: list[Chain], workers: int = 6, log=print):
    """Vrati (dict trenutnih Row-ova, lista korišćenih lanaca, izveštaj po izvoru)."""
    used: dict[str, Chain] = {}
    report = []

    def one(src):
        ch = chain_for_org(src["org"], chains)
        try:
            src["url"] = fresh_url(src)
            f = _stream_lines(src["url"])
            part = current(parse_csv(f, ch, src.get("delimiter")))
            return src, ch, part, None
        except Exception as e:  # jedan pokvaren izvor ne sme da obori ceo build – beleži se u izveštaj
            return src, ch, {}, f"{type(e).__name__}: {e}"

    merged: dict = {}
    with ThreadPoolExecutor(workers) as ex:
        for src, ch, part, err in ex.map(one, sources):
            report.append({"org": src["org"], "chain": ch.slug, "url": src["url"],
                           "rows": len(part), "error": err})
            if err:
                log(f"  GREŠKA {src['org']}: {err}")
                continue
            used[ch.slug] = ch
            latest(part.values(), merged)
            log(f"  {ch.slug:<14} {len(part):>7} cena  ({src['org'][:50]})")
    return merged, list(used.values()), report


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--sources", default="data/sources.json")
    ap.add_argument("--chains", default="data/chains.json")
    a = ap.parse_args(argv)
    srcs = json.loads(Path(a.sources).read_text("utf-8"))
    rows, used, _ = ingest(srcs, load_chains(Path(a.chains)), log=lambda m: print(m, file=sys.stderr))
    c = Counter(r.chain for r in rows.values())
    for k, v in c.most_common():
        print(f"{k:<16}{v:>8}")
    print("ukupno", len(rows), "proizvoda:", len({r.key for r in rows.values()}))


if __name__ == "__main__":
    main()
