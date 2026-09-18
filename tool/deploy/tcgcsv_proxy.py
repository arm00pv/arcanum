#!/usr/bin/env python3
"""Serves tcgcsv to a browser, which is not allowed to ask it itself.

tcgcsv sends no CORS headers and wants a named User-Agent. A browser can set
neither, so Digimon, One Piece, Gundam, Star Wars: Unlimited and Dragon Ball
came back empty on the web build while Magic worked. This is the whole of what
the browser needs from the server: fetch the path with a real User-Agent and
hand the answer back with the header the browser is waiting for.

Bound to the docker bridge, like the file server, so only Caddy reaches it.
"""
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = "https://tcgcsv.com/tcgplayer"
USER_AGENT = "Arcanum/1.0 (+https://marquezhv.com)"
PORT = 8098

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

    def _answer(self, status, body, head_only):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self._cors()
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def do_HEAD(self):
        # Answered rather than refused. A 501 here reads, from the outside, as
        # a missing CORS header - which is how this very proxy was first
        # misjudged.
        self._answer(200, b"", head_only=True)

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.send_header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
        self.send_header("Access-Control-Max-Age", "86400")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?")[0]
        request = urllib.request.Request(
            UPSTREAM + path,
            headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as answer:
                body = answer.read()
                status = answer.status
        except Exception as problem:  # noqa: BLE001 - reported, not raised
            print("upstream failed for %s: %s" % (path, problem), flush=True)
            self._answer(502, b"", head_only=False)
            return

        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "public, max-age=3600")
        self._cors()
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("172.19.0.1", PORT), Handler).serve_forever()
