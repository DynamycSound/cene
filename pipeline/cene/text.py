"""Normalizacija teksta: dekodiranje, latinica/ćirilica, dijakritici."""
from __future__ import annotations

import re
import unicodedata

_CYR = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "ђ": "dj", "е": "e", "ж": "z", "з": "z",
    "и": "i", "ј": "j", "к": "k", "л": "l", "љ": "lj", "м": "m", "н": "n", "њ": "nj", "о": "o",
    "п": "p", "р": "r", "с": "s", "т": "t", "ћ": "c", "у": "u", "ф": "f", "х": "h", "ц": "c",
    "ч": "c", "џ": "dz", "ш": "s",
}
_LAT = {"đ": "dj", "ð": "dj"}


def decode_bytes(b: bytes) -> str:
    if b.startswith(b"\xef\xbb\xbf"):
        b = b[3:]
    try:
        return b.decode("utf-8")
    except UnicodeDecodeError as e:
        # skraćen fajl može da preseče višebajtni znak na kraju
        if e.start >= len(b) - 3:
            return b[: e.start].decode("utf-8")
        # stari Windows izvozi su cp1250; nedefinisani bajtovi (npr. binarni fajl označen kao CSV) -> U+FFFD
        return b.decode("cp1250", errors="replace")


def fold(s: str) -> str:
    """Mala slova, ćirilica -> latinica, bez dijakritika (č,ć->c, š->s, ž->z, đ->dj)."""
    s = s.lower()
    s = "".join(_CYR.get(ch, _LAT.get(ch, ch)) for ch in s)
    s = unicodedata.normalize("NFKD", s)
    return "".join(ch for ch in s if not unicodedata.combining(ch))


def norm_ean(s: str) -> str:
    """Barkod: samo cifre, bez vodećih nula (0000080042556 == 80042556)."""
    d = re.sub(r"\D", "", s or "")
    return d.lstrip("0")
