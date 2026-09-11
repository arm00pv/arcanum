#!/usr/bin/env python3
"""Arcanum Sync - a tiny read-only price-history service for the Arcanum app.

Scryfall exposes only *current* card prices, so real trend analysis needs a
history provider. This service reads the compact SQLite database produced by
slice_prices.py and answers one small JSON document per printing.

Endpoints:

  GET /v1/health
      {"ok": true, "printings": N, "points": M, "days": D}
  GET /v1/history/<scryfallId>.json
      {"id": ..., "updated": ..., "series": {"nonfoil": [[ts, price], ...], ...}}
      Dates are unix seconds. Missing printings return 404 with a JSON body.

Run:
    python sync_server.py --port 8787 --db tool/prices/prices.db
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

DB_PATH = ""
POKEMON_DB_PATH = ""
_LOCK = threading.Lock()
_CONNS = {}


def conn(path=None):
    """Returns a shared connection for a database path."""
    key = path or DB_PATH
    if key not in _CONNS:
        c = sqlite3.connect(key, check_same_thread=False)
        c.row_factory = sqlite3.Row
        _CONNS[key] = c
    return _CONNS[key]


def databases():
    """Every database this server can answer from, Arcanum first."""
    out = [DB_PATH]
    if POKEMON_DB_PATH and os.path.exists(POKEMON_DB_PATH):
        out.append(POKEMON_DB_PATH)
    return out


def to_unix(date_str):
    try:
        d = datetime.strptime(date_str, "%Y-%m-%d").replace(tzinfo=timezone.utc)
        return int(d.timestamp())
    except ValueError:
        return None


def _series_from(path, column, card_id):
    """Reads one card's series out of a database, or None when absent."""
    with _LOCK:
        try:
            rows = conn(path).execute(
                f"SELECT finish, date, price FROM history WHERE {column} = ? ORDER BY date ASC",
                (card_id,),
            ).fetchall()
        except sqlite3.Error:
            return None
    if not rows:
        return None
    series = {}
    for r in rows:
        ts = to_unix(r["date"])
        if ts is None:
            continue
        series.setdefault(r["finish"], []).append([ts, round(float(r["price"]), 4)])
    return series or None


def history_for(card_id):
    """Looks a card up in every configured database.

    Magic printings are keyed by Scryfall id and Pokemon printings by TCGdex id.
    Rather than make the client say which game it is asking about, the server
    tries each database in turn — the id spaces do not overlap in practice.
    """
    for path, column in ((DB_PATH, "scryfall_id"), (POKEMON_DB_PATH, "card_id")):
        if not path:
            continue
        series = _series_from(path, column, card_id)
        if series:
            return {
                "id": card_id,
                "updated": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
                "series": series,
            }
    return None


# Counting 13M rows takes tens of seconds, so the health figures are computed
# once per process and then served from memory.
_STATS = None


def _counts(path, column):
    if not path or not os.path.exists(path):
        return (0, 0, 0)
    with _LOCK:
        try:
            c = conn(path)
            printings = c.execute(
                f"SELECT COUNT(DISTINCT {column}) FROM history"
            ).fetchone()[0]
            points = c.execute("SELECT COUNT(*) FROM history").fetchone()[0]
            days = c.execute("SELECT COUNT(DISTINCT date) FROM history").fetchone()[0]
        except sqlite3.Error:
            return (0, 0, 0)
    return (printings, points, days)


def stats():
    global _STATS
    if _STATS is None:
        mtg = _counts(DB_PATH, "scryfall_id")
        pkm = _counts(POKEMON_DB_PATH, "card_id")
        _STATS = {
            "ok": True,
            "printings": mtg[0],
            "points": mtg[1],
            "days": mtg[2],
            "games": {
                "mtg": {"printings": mtg[0], "points": mtg[1], "days": mtg[2]},
                "pokemon": {"printings": pkm[0], "points": pkm[1], "days": pkm[2]},
            },
        }
    return _STATS


class Handler(BaseHTTPRequestHandler):
    server_version = "ArcanumSync/1.0"
    protocol_version = "HTTP/1.1"

    def _send(self, code, payload):
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "public, max-age=3600")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = unquote(urlparse(self.path).path)
        try:
            if path in ("/v1/health", "/health", "/"):
                self._send(200, stats())
                return
            if path.startswith("/v1/history/"):
                sid = path[len("/v1/history/"):]
                if sid.endswith(".json"):
                    sid = sid[:-5]
                if not sid or "/" in sid:
                    self._send(400, {"error": "bad id"})
                    return
                data = history_for(sid)
                if data is None:
                    self._send(404, {"error": "no history", "id": sid})
                    return
                self._send(200, data)
                return
            self._send(404, {"error": "not found", "path": path})
        except BrokenPipeError:
            pass
        except Exception as exc:
            try:
                self._send(500, {"error": str(exc)})
            except Exception:
                pass

    def log_message(self, fmt, *args):
        sys.stderr.write("  " + (fmt % args) + "\n")


def main():
    global DB_PATH, POKEMON_DB_PATH, _STATS
    ap = argparse.ArgumentParser()
    default_db = os.path.join(os.path.dirname(os.path.abspath(__file__)), "prices", "prices.db")
    ap.add_argument("--db", default=default_db)
    ap.add_argument(
        "--pokemon-db",
        default=os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "prices", "pokemon_prices.db"
        ),
        help="optional Pokemon price database written by poll_pokemon_prices.py",
    )
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8787)
    args = ap.parse_args()

    if not os.path.exists(args.db):
        print("database not found: " + args.db, file=sys.stderr)
        print("run slice_prices.py first", file=sys.stderr)
        return 1
    DB_PATH = args.db
    POKEMON_DB_PATH = args.pokemon_db if os.path.exists(args.pokemon_db) else ""
    _STATS = None
    s = stats()
    print("Arcanum Sync serving {:,} printings / {:,} points ({} days) on http://{}:{}".format(
        s["printings"], s["points"], s["days"], args.host, args.port))
    pkm = s["games"]["pokemon"]
    if pkm["points"]:
        print("  + Pokemon: {:,} printings / {:,} points ({} days)".format(
            pkm["printings"], pkm["points"], pkm["days"]))
    else:
        print("  (no Pokemon database yet - run poll_pokemon_prices.py to build one)")
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
