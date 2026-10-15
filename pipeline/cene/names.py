"""Čitljiv naziv proizvoda od naziva koje za isti barkod pišu različiti lanci.

Svaki lanac ima svoje skraćenice i interne šifre („Mleko ster.2.8%mm Moja kravica BPslim 1L“,
„HLEB T-500 URD 500G“). Reč koju koristi više lanaca je deo naziva, reč koju piše samo jedan lanac je
najčešće šifra. Brend se izdvaja iz naziva (aplikacija ga prikazuje posebno).
"""
from __future__ import annotations

import re
from collections import Counter

from .text import fold

BAD_BRANDS = {"", "rm nije definisana", "nije definisano", "bez brenda", "nema", "-", "/", "n/a", "brend",
              "ostalo", "razno", "nepoznat"}

# oznake pakovanja, logistike i uredbe i nazivi distributera – kupcu ne znače ništa
_JUNK = {"tb", "tt", "pet", "bp", "bpslim", "slim", "br", "pd", "pvc", "stand", "var", "des", "ur", "urd",
         "uredba", "bezk", "pdm", "rm", "mk", "ad", "doo", "kd", "cep", "cepom", "nelt", "mondelez", "way",
         "craft", "pak", "kom"}
_JUNK_CODE = re.compile(r"(k|mk|f|pd|sk)\d+[a-z]?|\d+/\d+")  # K12, MK20, F21X, SK4 (Lidl), 24/1 (broj u kutiji)
_UNIT = r"%|kg|gr|g|ml|lit|l|cl|dl|mm|cm|m|kom|w|v"
_UNITS = {"gr": "g", "lit": "l"}
_ABBR = {"ster": "sterilizovano", "dugot": "dugotrajno", "dugotr": "dugotrajno", "dug": "dugotrajno",
         "kis": "kiselo", "pavl": "pavlaka", "ng": "negazirana", "negaz": "negazirana", "gaz": "gazirana",
         "min": "mineralna", "krav": "kravica", "pas": "pasterizovano", "smrz": "smrznuto",
         "sv": "svinjski", "jun": "juneći", "pil": "pileći"}
_ACRONYMS = {"uht", "bio", "xxl", "xl", "xs", "dm", "eko", "cbd", "led", "usb", "edp", "edt"}
_L = "a-zžćčšđ"
_N = r"\d+(?:[.,]\d+)?"

_TOK = re.compile(
    # 20x10cm, 7-14kg, 48/1
    rf"(?P<dim>(?<![\w.,]){_N}(?:\s?[x×*/-]\s?{_N})+)\s?(?P<dunit>{_UNIT})?(?![{_L}\d])"
    # 112g, 0,5 l, 2,8%
    # „2,8%MM“: posle % sme da dođe slovo, posle jedinice ne („5 YR“ nije 5 + jedinica)
    rf"|(?P<num>(?<![\w,]){_N})(?:\s?(?P<pct>%)|\s?(?P<unit>{_UNIT})(?![{_L}\d])|(?![{_L}\d]))"
    # šifre i oznake: K12, T-500, 5YR, 3in1
    rf"|(?P<code>[{_L}]*\d+[{_L}\d]*|[{_L}]+-\d+)"
    rf"|(?P<word>[{_L}]+(?:-[{_L}]+)*\.?)",
    re.IGNORECASE,
)


class Tok:
    __slots__ = ("key", "text", "kind")

    def __init__(self, key: str, text: str, kind: str):
        self.key, self.text, self.kind = key, text, kind

    def __repr__(self):
        return f"{self.kind}:{self.text}"


def _num(s: str) -> str:
    n = s.replace(",", ".")
    if "." in n:
        return n.rstrip("0").rstrip(".") or "0"
    return n.lstrip("0") or "0"


def tokens(name: str) -> list[Tok]:
    out = []
    for m in _TOK.finditer(name):
        if m.group("dim") is not None:
            unit = _UNITS.get((m.group("dunit") or "").lower(), (m.group("dunit") or "").lower())
            parts = re.split(r"\s?([x×*/-])\s?", m.group("dim"), flags=re.I)
            key = "".join(p.lower() if i % 2 else _num(p) for i, p in enumerate(parts))
            text = key.replace(".", ",").replace("*", "x").replace("×", "x") + (f" {unit}" if unit else "")
            out.append(Tok(key + unit, text, "dim"))
        elif m.group("num") is not None:
            n = _num(m.group("num"))
            unit = (m.group("pct") or m.group("unit") or "").lower()
            unit = _UNITS.get(unit, unit)
            text = n.replace(".", ",") + ("%" if unit == "%" else f" {unit}" if unit else "")
            out.append(Tok(n + unit, text, "qty" if unit else "num"))
        elif m.group("code") is not None:
            c = m.group("code")
            out.append(Tok(fold(c), c.lower(), "code"))
        else:
            w = m.group("word")
            out.append(Tok(fold(w.rstrip(".")), w, "word"))
    return out


def pick_brand(brands: list[str]) -> str:
    """Najčešći brend (bez obzira na velika slova); prikaz u obliku koji nije sav velikim slovima."""
    # bez pravne forme: „Slatki dar d.o.o“ -> „Slatki dar“
    good = [re.sub(r"[\s,]+(d\.?o\.?o\.?|a\.?d\.?|doo|ad)\s*$", "", b.strip(), flags=re.I) for b in brands]
    good = [b for b in good if b and fold(b).strip() not in BAD_BRANDS]
    if not good:
        return ""
    c = Counter(fold(b) for b in good)
    top = c.most_common(1)[0][0]
    forms = [b for b in good if fold(b) == top]
    mixed = [b for b in forms if b != b.upper()]
    if mixed:
        return Counter(mixed).most_common(1)[0][0]
    return " ".join(w if len(w) <= 2 else w.capitalize() for w in forms[0].lower().split())


def _junk(t: Tok) -> bool:
    if t.key in _JUNK or _JUNK_CODE.fullmatch(t.key):
        return True
    if t.kind == "word" and len(t.key) < 2 and t.key not in ("i", "u"):
        return True
    return t.kind == "num" and len(t.key) >= 4  # interne šifre (00391, 10277)


def clean_name(names: list[str], brand: str = "", brand_words: set[str] = frozenset(),
               generic: set[str] = frozenset()) -> str:
    """[names] – po jedan naziv po lancu, [brand] – izabrani brend (njegove reči se uvek vade iz naziva).
    [brand_words] – reči iz polja „robna marka“ ostalih lanaca (distributeri, proizvođači): vade se ako ih
    ne piše većina lanaca u nazivu. [generic] – reči koje se nikad ne vade („voda“ iz brenda „Prolom voda“)."""
    names = [n for n in dict.fromkeys(n.strip() for n in names) if n]
    if not names:
        return ""
    toks = [tokens(n) for n in names]
    df = Counter()
    for ts in toks:
        df.update({t.key for t in ts})
    many = len(names) >= 3
    own = {t.key for t in tokens(brand) if t.kind == "word"} - generic

    def keep(t: Tok) -> bool:
        if _junk(t) or t.key in own:
            return False
        if t.kind == "word" and t.key in brand_words and t.key not in generic and df[t.key] * 2 <= len(names):
            return False
        return not many or df[t.key] >= 2

    # prva reč naziva kod većine lanaca („Čokolada noisette“, ne „Noisette čokolada“)
    firsts = Counter(next((t.key for t in ts if t.kind == "word" and keep(t)), "") for ts in toks)

    def score(ts: list[Tok]) -> float:
        kept = {t.key: t for t in ts if keep(t)}
        first = next((t.key for t in ts if t.kind == "word" and keep(t)), "")
        # naziv čije reči potvrđuje najviše drugih lanaca; svaka reč malo košta (protiv „lila stix“ umesto
        # „lilastix“), skraćenice i izbačene šifre koštaju više
        return (sum(df[k] / len(names) for k in kept) - 0.15 * len(kept)
                - 0.2 * sum(t.text.endswith(".") for t in kept.values())
                - 0.1 * sum(1 for t in ts if not keep(t))
                + 0.1 * firsts[first] / len(names))

    best = max(toks, key=score)
    kept = [t for t in best if keep(t)]
    if not any(t.kind == "word" for t in kept):
        # sve je ispalo (npr. naziv je samo brend i gramaža) – zadrži sve osim šifara
        kept = [t for t in best if not _junk(t)]

    # oblik reči: kako je piše lanac koji naziv piše kao rečenicu (bar jedna reč cela malim slovima),
    # ne SVE VELIKIM ni „Svaka Reč Velikim“
    forms: dict[str, Counter] = {}
    for n, ts in zip(names, toks):
        if re.search(rf"(?<!\S)[{_L}]{{3,}}", n):
            for t in ts:
                if t.kind == "word" and not t.text.endswith(".") and t.text != t.text.upper():
                    forms.setdefault(t.key, Counter())[t.text] += 1

    # kvačice iz bilo kog lanca, i iz naziva pisanih velikim slovima („ČOKOLADA“)
    diac: dict[str, str] = {}
    for ts in toks:
        for t in ts:
            low = t.text.rstrip(".").lower()
            if t.kind == "word" and low != fold(low) and re.fullmatch(r"[a-zžćčšđ-]+", low):
                diac.setdefault(t.key, low)

    def with_diac(key: str, w: str) -> str:
        if key not in diac or w.lower() != fold(w):
            return w
        d = diac[key]
        return d.capitalize() if w[:1].isupper() else d

    out, seen = [], set()
    prev = None
    for t in kept:
        if t.key in seen:
            continue
        seen.add(t.key)
        if t.kind != "word":
            out.append(t.text)
        elif t.key == "mm" and prev is not None and prev.text.endswith("%"):
            out.append("m.m.")  # mlečne masti
        elif t.key in _ABBR and t.text.endswith("."):
            out.append(_ABBR[t.key])
        elif t.key in _ACRONYMS:
            out.append(t.key.upper())
        elif t.key in forms:
            # većina lanaca piše bez kvačica; ako ijedan piše „sveže“, to je pravi oblik
            out.append(with_diac(t.key, max(forms[t.key].items(),
                                            key=lambda kv: (kv[0].lower() != fold(kv[0]), kv[1]))[0]))
        else:
            out.append(with_diac(t.key, t.text.rstrip(".").lower()))
        prev = t
    while len(out) > 1 and out[-1].lower() in ("i", "u", "sa", "za", "od"):  # ostatak izbačenog dela
        out.pop()
    s = " ".join(out)
    return s[:1].upper() + s[1:]
