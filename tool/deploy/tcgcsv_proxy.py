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
ORIGIN = "https://marquezhv.com"
PORT = 8098


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

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
            self.send_response(502)
            self.send_header("Access-Control-Allow-Origin", ORIGIN)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", "0")
            self.end_headers()
            print("upstream failed for %s: %s" % (path, problem), flush=True)
            return

        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", ORIGIN)
        self.send_header("Cache-Control", "public, max-age=3600")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("172.19.0.1", PORT), Handler).serve_forever()
