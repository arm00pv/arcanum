#!/usr/bin/env python3
"""Serves tcgcsv and card art to a browser, which is not allowed to ask either.

tcgcsv sends no CORS headers and wants a named User-Agent. A browser can set
neither, so Digimon, One Piece, Gundam, Star Wars: Unlimited and Dragon Ball
came back empty on the web build while Magic worked.

Card art is the same request against a different host. The app reads a card's
picture by fetching its bytes and decoding them itself, so a browser judges an
image by exactly the rule it judges JSON by, and two of the three hosts the
catalogues draw art from have nothing to say to it: YGOPRODeck's image host and
Lorcast's card store send no Access-Control-Allow-Origin at all, and the
shop's CDN sends a wildcard the shop is free to withdraw. A relay is therefore
what a browser asks for art as well - same fetch, same header, one process.

Art is immutable per product, so it is handed over with a year of Cache-Control
and the browser is not expected back for the same picture.

Bound to the docker bridge, like the file server, so only Caddy reaches it.
"""
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = "https://tcgcsv.com/tcgplayer"
USER_AGENT = "Arcanum/1.0 (+https://marquezhv.com)"
PORT = 8098

# Where art comes from, keyed by the segment the app puts in the URL. A table
# rather than a host read out of the path: a relay that fetches whatever it is
# pointed at is a relay any page on the internet can spend against any host it
# likes, under this machine's name.
ART_ORIGINS = {
    "tcgplayer": "https://tcgplayer-cdn.tcgplayer.com",
    "ygoprodeck": "https://images.ygoprodeck.com",
    "lorcast": "https://cards.lorcast.io",
    # TCGdex's card art answers with "Access-Control-Allow-Origin: *, *" - the
    # value twice - and a browser refuses a multi-valued header outright. Its set
    # logos send a single "*" and are fine, which is what hid this. Measured
    # 2026-09-21: of 216 Pokemon sets, 186 had a refused low.webp, 208 a refused
    # high.webp and 165 a refused high.png.
    "tcgdex": "https://assets.tcgdex.net",
    # Bandai's own card database, which is what gcgapi's art URLs point at. The
    # API itself names the asking origin, so only the pictures come through here:
    # measured 2026-09-21, none of the 1,912 Gundam product images carried an
    # Access-Control-Allow-Origin, so a browser refused every one of them.
    "gundam": "https://www.gundam-gcg.com",
}

# A year, and immutable: the shop names a picture after the product it shows
# and never rewrites it under the same name, so the only thing a shorter life
# buys is the same bytes over the same wire a second time.
ART_CACHE = "public, max-age=31536000, immutable"

# The deployed app is same-origin with this relay and needs no header at all,
# but a locally served web build is a different origin and would be blocked
# without one - and being unable to run the app locally is how a bug like this
# gets shipped. Only localhost is added: a wildcard would let any page on the
# internet spend this host's requests against the mirror.
ORIGINS = (
    "https://marquezhv.com",
    "https://zapp.sytes.net",
    "http://localhost:8080",
    "http://127.0.0.1:8080",
)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _cors(self):
        origin = self.headers.get("Origin")
        if origin in ORIGINS:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")

    def _send(self, status, body, content_type, cache, head_only=False):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        if cache is not None:
            self.send_header("Cache-Control", cache)
        self._cors()
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def _fetch(self, url, accept):
        request = urllib.request.Request(
            url, headers={"User-Agent": USER_AGENT, "Accept": accept}
        )
        with urllib.request.urlopen(request, timeout=30) as answer:
            return answer.status, answer.headers.get_content_type(), answer.read()

    def do_HEAD(self):
        # Answered rather than refused. A 501 here reads, from the outside, as
        # a missing CORS header - which is how this very proxy was first
        # misjudged.
        self._send(200, b"", "application/json", None, head_only=True)

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.send_header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
        self.send_header("Access-Control-Max-Age", "86400")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path.startswith("/art/"):
            self._art(path, query)
        else:
            self._catalogue(path)

    def _catalogue(self, path):
        try:
            status, _, body = self._fetch(UPSTREAM + path, "application/json")
        except Exception as problem:  # noqa: BLE001 - reported, not raised
            print("upstream failed for %s: %s" % (path, problem), flush=True)
            self._send(502, b"", "application/json", None)
            return

        # The Content-Type is this relay's own rather than the mirror's: a
        # refusal from the mirror arrives as HTML, and the app is better served
        # by a body it cannot decode under a type that says so.
        self._send(status, body, "application/json", "public, max-age=3600")

    def _art(self, path, query):
        key, _, tail = path[len("/art/") :].partition("/")
        origin = ART_ORIGINS.get(key)
        # '..' would climb out of the origin the key chose and turn the table
        # above back into an open proxy.
        if origin is None or not tail or ".." in tail.split("/"):
            self._send(404, b"", "text/plain", None)
            return

        url = "%s/%s" % (origin, tail)
        if query:
            url += "?" + query
        try:
            status, content_type, body = self._fetch(url, "image/*,*/*;q=0.8")
        except Exception as problem:  # noqa: BLE001 - reported, not raised
            print("upstream failed for %s: %s" % (url, problem), flush=True)
            # Nothing is kept of a failure, and that is what keeps the year of
            # cache above honest: urllib raises on a refusal rather than
            # answering with one, so a CDN having a bad minute or turning down
            # a product that is not there lands here and is not remembered.
            self._send(502, b"", "text/plain", "no-store")
            return

        self._send(status, body, content_type, ART_CACHE)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("172.19.0.1", PORT), Handler).serve_forever()
