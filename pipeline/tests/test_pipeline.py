import io
import sqlite3

from cene.build_db import build, search_text
from cene.columns import is_price_list, map_columns
from cene.ingest_gov import Chain, current, latest, parse_csv
from cene.parse import parse_date, parse_price, product_key
from cene.text import fold

# isečci pravih fajlova (zaglavlja doslovno kako ih lanci objavljuju)
MAXI = """﻿KATEGORIJA;NAZIV KATEGORIJE;Naziv proizvoda;Robna marka;Barkod proizvoda;Jedinica mere;Naziv trgovca - formata;Datum cenovnika;Redovna cena;Cena po jedinici mere;Snižena cena;Datum početka sniženja;Datum kraja sniženja;Stopa PDV;VRSTA_CENOVNIKA
2;Bezalkoholna pića, kafa, čaj;Prolom voda NG Planinka 0,5l;Prolom;8600169600046;lit;Maxi;01-09-2026;57.99;57.99;;;;20;MESECNI_PRESEK
2;Bezalkoholna pića, kafa, čaj;Prolom voda NG Planinka 0,5l;Prolom;8600169600046;lit;Mega Maxi;01-09-2026;57.99;57.99;49.99;10-10-2026;20-10-2026;20;MESECNI_PRESEK
"""

LIDL = """KATEGORIJA;NAZIV KATEGORIJE;Naziv proizvoda;Robna marka;Barkod proizvoda;Jedinica mere;Naziv trgovca – formata;Datum cenovnika;Redovna cena;Cena po jedinici mere;Snižena cena;Datum početka sniženja;Datum kraja sniženja;Stopa PDV;VRSTA_CENOVNIKA
1;Mleko, mlečni i mešoviti proizvodi, jaja;Ml. dezert na bazi sira sa jog. SK1 500g;Milbona;4056489515999;kg;Lidl Srbija KD;15-10-2026;269.99;539.98;;;;20;VAZECI_CENOVNIK
"""

# Proleter: dva mesečna preseka; kefir 500 g postoji samo u starom preseku (povučen)
PROLETER = """﻿KATEGORIJA;NAZIV KATEGORIJE;Naziv proizvoda;Robna marka;Barkod proizvoda;Jedinica mere;Naziv trgovca – formata;Datum cenovnika;Redovna cena;Cena po jedinici mere;Snižena cena;Datum početka sniženja;Datum kraja sniženja;Stopa PDV;VRSTA_CENOVNIKA
1;Mleko, mlečni i mešoviti proizvodi, jaja;Balans + Kefir 2,8% IMLEK PET 500 g;RM NIJE DEFINISANA;8601500134435;KOM;Metalac Proleter d.o.o.;01-09-2026;99.99;199.98;;;;10;MESECNI_PRESEK
2;Bezalkoholna pića, kafa, čaj;Voda Prolom PET 500 ml;RM NIJE DEFINISANA;8600169600046;KOM;Metalac Proleter d.o.o.;01-09-2026;62.00;124.00;;;;20;MESECNI_PRESEK
2;Bezalkoholna pića, kafa, čaj;Voda Prolom PET 500 ml;RM NIJE DEFINISANA;8600169600046;KOM;Metalac Proleter d.o.o.;01-10-2026;65.00;130.00;;;;20;MESECNI_PRESEK
"""

LILLY_HEADER = ("KATEGORIJA;NAZIV_KATEGORIJE;NAZIV_PROIZVODA;ROBNA_MARKA;BARKOD;JEDINICA_MERE;NAZIV_TRGOVCA;"
                "DATUM_CENOVNIKA;REDOVNA_CENA;CENA_PO_JM;SNIZENA_CENA;DATUM_POCETKA_SNIZENJA;"
                "DATUM_KRAJA_SNIZENJA;STOPA_PDV;VRSTA_CENOVNIKA")

MAXI_C = Chain("maxi", "Maxi", "#E30613")
LIDL_C = Chain("lidl", "Lidl", "#0050AA")
PROL_C = Chain("proleter", "Proleter", "#2E7D32")


def rows(text, chain):
    f = io.StringIO(text.lstrip("﻿"), newline="")
    return current(parse_csv(f, chain))


def test_header_variants():
    for h in (MAXI.splitlines()[0], LIDL.splitlines()[0], LILLY_HEADER):
        cols = map_columns(h.lstrip("﻿").split(";"))
        assert {"name", "ean", "format", "price", "unit_price", "sale_price", "sale_from", "sale_to",
                "date", "kind"} <= cols.keys(), h
        assert cols["price"] == 8 and cols["sale_price"] == 10 and cols["sale_from"] == 11
    assert not is_price_list(["Naziv", "Adresa", "Grad"])


def test_values():
    assert parse_price("1.299,99") == 1299.99
    assert parse_price("1299.99") == 1299.99
    assert parse_price("57,99 din") == 57.99
    assert parse_price("") is None and parse_price("0") is None
    assert parse_date("01-09-2026") == "2026-09-01"
    assert parse_date("1.9.2026.") == "2026-09-01"
    assert parse_date("31-02-2026") is None
    assert product_key("08600169600046", "maxi") == "8600169600046"
    assert product_key("2000123", "maxi") == "maxi:2000123"          # prekratko -> interna šifra
    assert product_key("2100000012345", "lidl") == "lidl:2100000012345"  # GS1 prefiks 2 -> interno
    assert fold("Mleko ČOKOLADNO đak Млеко") == "mleko cokoladno djak mleko"


def test_sale_and_formats():
    r = rows(MAXI, MAXI_C)
    assert len(r) == 2
    mega = r[("maxi", "Mega Maxi", "8600169600046")]
    assert mega.price == 57.99 and mega.sale_price == 49.99
    assert (mega.sale_from, mega.sale_to) == ("2026-10-10", "2026-10-20")


def test_latest_snapshot_wins_and_delisted_dropped():
    r = rows(PROLETER, PROL_C)
    keys = {k[2] for k in r}
    assert keys == {"8600169600046"}  # kefir nije u poslednjem preseku -> povučen
    assert r[("proleter", "Metalac Proleter d.o.o.", "8600169600046")].price == 65.00


def test_build_merges_by_ean(tmp_path):
    merged = {}
    for text, ch in ((MAXI, MAXI_C), (LIDL, LIDL_C), (PROLETER, PROL_C)):
        latest(rows(text, ch).values(), merged)
    out = tmp_path / "t.sqlite"
    stats = build(merged, [MAXI_C, LIDL_C, PROL_C], out)
    assert stats["products"] == 2 and stats["prices"] == 4 and stats["multi_chain_products"] == 1

    db = sqlite3.connect(out)
    got = db.execute("""SELECT c.slug, f.name, pr.price, pr.sale_price, pr.sale_from FROM products p
                        JOIN prices pr ON pr.product_id = p.id JOIN formats f ON f.id = pr.format_id
                        JOIN chains c ON c.id = f.chain_id WHERE p.ean = '8600169600046'
                        ORDER BY pr.price, f.name""").fetchall()
    assert got == [("maxi", "Maxi", 57.99, None, None),
                   ("maxi", "Mega Maxi", 57.99, 49.99, 20261010),
                   ("proleter", "Metalac Proleter d.o.o.", 65.0, None, None)]
    name, brand, n, search = db.execute(
        "SELECT name, brand, n_chains, search FROM products WHERE ean = '8600169600046'").fetchone()
    assert n == 2 and brand == "Prolom"  # "RM NIJE DEFINISANA" se ne bira kao brend
    # pretraga nalazi proizvod po rečima iz naziva bilo kog lanca, bez dijakritika
    assert {"prolom", "planinka", "voda", "pet", "0,5", "500"} <= set(search.split())
    assert db.execute("SELECT count(*) FROM products WHERE search LIKE '%mlecni%' OR search LIKE '%dezert%'"
                      ).fetchone()[0] == 1


def test_search_text_dedup():
    assert search_text(["Čokolada MILKA 100g", "cokolada milka 100g"]) == "cokolada milka 100g"


def test_osm_store_matching():
    from cene.stores_osm import to_stores
    chains = [Chain("maxi", "Maxi", "#E30613", osm=["Maxi", "Mega Maxi", "Shop&Go"]),
              Chain("dm", "dm", "#002F6C", osm=["dm"]),
              Chain("okov", "Okov", "#F9A825", osm=["Okov"])]
    el = [
        {"type": "node", "id": 1, "lat": 44.8, "lon": 20.4, "tags": {"name": "Mega Maxi", "brand": "Maxi"}},
        {"type": "way", "id": 2, "center": {"lat": 44.7, "lon": 20.5}, "tags": {"name": "Shop&Go"}},
        {"type": "node", "id": 3, "lat": 44.0, "lon": 21.0, "tags": {"name": "Metal plast - DM"}},
        {"type": "node", "id": 4, "lat": 44.0, "lon": 21.0, "tags": {"name": "Novi okov"}},
        {"type": "node", "id": 5, "lat": 43.3, "lon": 21.9, "tags": {"name": "Оков", "addr:city": "Ниш"}},
    ]
    got = {(s["osm_id"], s["chain"], s["format"]) for s in to_stores(el, chains)}
    assert got == {("n1", "maxi", "Mega Maxi"), ("w2", "maxi", "Shop and Go"), ("n5", "okov", None)}


def test_clean_names():
    from cene.names import clean_name, pick_brand, tokens
    milk = ["MLEKO UHT MOJA KRAVICA 2,8%MM 1L TB", "Mleko ster.2.8%mm Moja kravica BPslim 1L",
            "MLEKO UHT 2,8%MM 1L TB KRAVICA", "MLEKO TRAJNO 2.8% TB MOJA KRAVICA 1L IMLEK AD --"]
    brand = pick_brand(["MOJA KRAVICA", "Moja kravica", "RM NIJE DEFINISANA", "Brend"])
    assert brand == "Moja kravica"
    n = clean_name(milk, brand, {"imlek"})
    assert n.startswith("Mleko UHT 2,8%") and n.endswith("1 l"), n
    assert "kravica" not in n.lower() and "BPslim" not in n and " TB" not in n
    # brend se vadi iz naziva, šifra koju piše samo jedan lanac ispada, oblik reči iz „rečeničnog“ naziva
    milka = ["MILKA LILASTIX 112G", "KEKS MILKA LILASTIX 112G MONDELEZ", "Milka Lilastix 112g #20",
             "KEKS CHOCO LILASTIX MILKA 112G"]
    assert clean_name(milka, "Milka", {"mondelez"}) == "Keks lilastix 112 g"
    # reč iz naziva mnogo brendova („voda“) ostaje i kad je deo brenda
    assert clean_name(["PROLOM VODA 0.5L", "VODA PROLOM 0,5L"], "Prolom voda", generic={"voda"}) == "Voda 0,5 l"
    assert clean_name(["Letva za rampu 69x92x4150mm alumin. Nice"], "Nice") == "Letva za rampu 69x92x4150 mm alumin"
    assert clean_name(["HLEB BELI 500G K12 DON DON U"], "Don Don") == "Hleb beli 500 g"
    assert clean_name(["Mesni hleb SK4 500g"], "Pikok") == "Mesni hleb 500 g"
    assert [t.text for t in tokens("BURGIJA SDS 10X160MM 2,8%1L")][-3:] == ["10x160 mm", "2,8%", "1 l"]
    assert pick_brand(["Slatki dar d.o.o"]) == "Slatki dar"
    # kvačice iz naziva pisanog velikim slovima, redosled reči kao kod većine lanaca
    choco = ["MILKA NOISSET 80G27#", "ČOKOLADA MLEČNA NOISETTE MILKA 80G", "Cokolada noisette Milka 80g",
             "ČOKOLADA MILKA NOISETTE 80G", "Milka noisette cokolada 80g"]
    assert clean_name(choco, "Milka") == "Čokolada noisette 80 g"
