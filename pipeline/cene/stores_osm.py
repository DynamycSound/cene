"""Radnje sa koordinatama iz OpenStreetMap-a (Overpass) -> data/stores.json.

Radnja se pripisuje lancu po tagovima brand / name / operator (imena iz chains.json "osm"),
a formatu (npr. Mega Maxi, Shop and Go, Mercator) po nazivu radnje.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

from .http import UA
from .ingest_gov import load_chains
from .text import fold

# javni Overpass serveri često vrate 502/504 pod opterećenjem – probaj redom
OVERPASS = ["https://overpass-api.de/api/interpreter",
            "https://overpass.private.coffee/api/interpreter",
            "https://maps.mail.ru/osm/tools/overpass/api/interpreter"]

SHOPS = ("supermarket|convenience|electronics|computer|mobile_phone|chemist|doityourself|hardware|"
         "wholesale|department_store|books|sports|butcher|general|variety_store|appliance")

QUERY = f"""[out:json][timeout:300];
area["ISO3166-1"="RS"][admin_level=2]->.rs;
nwr["shop"~"^({SHOPS})$"](area.rs);
out center tags;"""

# format se prepoznaje po nazivu radnje; redosled: specifičnije pre opštijeg
FORMAT_RULES = {
    "maxi": [(r"mega ?maxi|tempo", "Mega Maxi"), (r"shop ?(&|and|i)? ?go", "Shop and Go"), (r"maxi", "Maxi")],
    "idea": [(r"mercator", "MERCATOR"), (r"roda", "RODA"), (r"idea", "IDEA")],
}


def fetch(query: str = QUERY, timeout: float = 400) -> list[dict]:
    data = urllib.parse.urlencode({"data": query}).encode()
    errors = []
    for url in OVERPASS:
        req = urllib.request.Request(url, data=data, headers={"User-Agent": UA})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.load(r)["elements"]
        except (OSError, ValueError) as e:
            errors.append(f"{url}: {e}")
            print(f"  Overpass greška {url}: {e}", file=sys.stderr)
    raise RuntimeError("svi Overpass serveri nedostupni: " + " | ".join(errors))


def _matcher(chains):
    """Lista (regex, slug); duža imena prva da 'Super Idea' ne pobedi 'Idea' pogrešno itd."""
    pats = []
    for c in chains:
        for n in c.osm:
            n = fold(n)
            # naziv mora da POČINJE imenom lanca ("Novi okov", "Metal plast - DM" nisu Okov/dm);
            # kratka imena (dm, ZAM) moraju biti ceo naziv
            tail = r"$" if len(n) <= 3 else r"($|\W)"
            pats.append((len(n), re.compile("^" + re.escape(n) + tail), c.slug))
    pats.sort(key=lambda p: -p[0])
    return [(rx, slug) for _, rx, slug in pats]


def match_chain(tags: dict, matcher) -> str | None:
    # brand je najpouzdaniji, pa name, pa operator
    for key in ("brand", "name", "name:sr-Latn", "operator"):
        v = tags.get(key)
        if not v:
            continue
        v = fold(v)
        for rx, slug in matcher:
            if rx.search(v):
                return slug
    return None


def match_format(slug: str, tags: dict) -> str | None:
    name = fold(" ".join(tags.get(k, "") for k in ("name", "brand")))
    for rx, fmt in FORMAT_RULES.get(slug, []):
        if re.search(rx, name):
            return fmt
    return None


def address(tags: dict) -> str:
    street = tags.get("addr:street", "")
    num = tags.get("addr:housenumber", "")
    return f"{street} {num}".strip()


def to_stores(elements: list[dict], chains) -> list[dict]:
    matcher = _matcher(chains)
    out = []
    for e in elements:
        tags = e.get("tags", {})
        lat = e.get("lat") or e.get("center", {}).get("lat")
        lon = e.get("lon") or e.get("center", {}).get("lon")
        if lat is None or lon is None:
            continue
        slug = match_chain(tags, matcher)
        if not slug:
            continue
        out.append({
            "chain": slug, "format": match_format(slug, tags),
            "name": tags.get("name") or tags.get("brand") or "",
            "address": address(tags),
            "city": tags.get("addr:city", ""),
            "lat": round(lat, 6), "lon": round(lon, 6),
            "osm_id": f"{e['type'][0]}{e['id']}",
        })
    out.sort(key=lambda s: (s["chain"], s["city"], s["name"]))
    return out


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--chains", default="data/chains.json")
    ap.add_argument("-o", "--out", default="data/stores.json")
    ap.add_argument("--raw", help="sačuvan Overpass JSON umesto upita (za testiranje)")
    a = ap.parse_args(argv)
    chains = load_chains(Path(a.chains))
    elements = json.loads(Path(a.raw).read_text("utf-8"))["elements"] if a.raw else fetch()
    stores = to_stores(elements, chains)
    Path(a.out).write_text(json.dumps(stores, ensure_ascii=False, indent=0), "utf-8")
    from collections import Counter
    c = Counter(s["chain"] for s in stores)
    print(f"OSM objekata: {len(elements)}, radnji lanaca: {len(stores)}", file=sys.stderr)
    for k, v in c.most_common():
        print(f"  {k:<16}{v:>5}", file=sys.stderr)
    if not stores:
        sys.exit("nijedna radnja nije prepoznata")


if __name__ == "__main__":
    main()
