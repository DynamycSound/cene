"""Mali HTTP helper nad urllib (bez spoljnih zavisnosti)."""
from __future__ import annotations

import gzip
import json
import time
import urllib.error
import urllib.parse
import urllib.request

UA = "CeneApp/0.1 (+https://github.com/; licni uporedjivac cena)"
BROWSER_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36"


class HttpError(Exception):
    pass


def _open(url: str, headers: dict | None = None, timeout: float = 60):
    h = {"User-Agent": UA, "Accept-Encoding": "gzip"}
    if headers:
        h.update(headers)
    # neki resursi na portalu imaju razmake/dijakritike u URL-u
    url = urllib.parse.quote(url.strip(), safe=":/?&=%#+@;,~!$*'()[]")
    req = urllib.request.Request(url, headers=h)
    return urllib.request.urlopen(req, timeout=timeout)


def _read(resp, limit: int | None = None) -> bytes:
    raw = resp.read(limit) if limit else resp.read()
    if resp.headers.get("Content-Encoding") == "gzip":
        try:
            raw = gzip.decompress(raw)
        except (OSError, EOFError):
            # skraćen gzip (range/limit) – raspakuj koliko može
            d = gzip.GzipFile(fileobj=__import__("io").BytesIO(raw))
            out = b""
            try:
                while chunk := d.read(4096):
                    out += chunk
            except (OSError, EOFError):
                pass
            raw = out
    return raw


def get_bytes(url: str, headers: dict | None = None, timeout: float = 120, retries: int = 3,
              limit: int | None = None) -> bytes:
    last: Exception | None = None
    for attempt in range(retries):
        try:
            with _open(url, headers, timeout) as r:
                return _read(r, limit)
        except urllib.error.HTTPError as e:
            if e.code in (400, 401, 403, 404, 410):
                raise HttpError(f"{e.code} {url}") from e
            last = e
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as e:
            last = e
        time.sleep(2 * (attempt + 1))
    raise HttpError(f"neuspelo posle {retries} pokušaja: {url}: {last}")


def get_head_bytes(url: str, n: int = 4096, timeout: float = 30) -> bytes:
    """Prvih n bajtova (Range; ako server ignoriše Range, čita samo n bajtova)."""
    return get_bytes(url, {"Range": f"bytes=0-{n - 1}"}, timeout=timeout, retries=2, limit=n)


def get_json(url: str, **kw):
    return json.loads(get_bytes(url, **kw))
