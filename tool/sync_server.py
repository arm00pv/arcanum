#!/usr/bin/env python3
"""Arcanum Sync - a tiny read-only price-history service for the Arcanum app.

Scryfall exposes only *current* card prices, so real trend analysis needs a
history provider. This service reads the compact SQLite databases the tools in
this directory produce - one per game: Magic from slice_prices.py, and Pokemon,
Lorcana and Yu-Gi-Oh! from the daily pollers - and answers one small JSON
document per printing.

Endpoints:

  GET /v1/health
      {"ok": true, "printings": N, "points": M, "days": D,
       "games": {"mtg": {..}, "pokemon": {..}, "lorcana": {..}, "yugioh": {..}}}
  GET /v1/history/<cardId>.json
      {"id": ..., "updated": ..., "series": {"nonfoil": [[ts, price], ...]}, "game": ...}
      Dates are unix seconds. Missing printings return 404 with a JSON body.

The four games address a printing differently - Scryfall UUIDs, TCGdex ids,
Lorcast's crd_ ids and Yu-Gi-Oh!'s compound ids - and those id spaces do not
overlap, so the id alone decides which database answers.

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
LORCANA_DB_PATH = ""
YUGIOH_DB_PATH = ""
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


def sources():
    """(path, id column, game) for every database, Magic first.

    The game name is the app's own CardGame id, so it is the same word in a
    history payload and in the health counters. A path is empty when that game's
    database is not configured or does not exist yet.
    """
    return (
        (DB_PATH, "scryfall_id", "mtg"),
        (POKEMON_DB_PATH, "card_id", "pokemon"),
        (LORCANA_DB_PATH, "card_id", "lorcana"),
        (YUGIOH_DB_PATH, "card_id", "yugioh"),
    )


def databases():
    """Every database this server can answer from, Arcanum first."""
    return [path for path, _column, _game in sources() if path]


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

    The games key a printing differently - Magic by Scryfall id, Pokemon by
    TCGdex id, Lorcana by Lorcast's crd_ id, Yu-Gi-Oh! by its compound
    passcode:set:code:rarity id - so rather than make the client say which game
    it is asking about, the server tries each database in turn; the id spaces do
    not overlap in practice. The reply names the database that answered.
    """
    for path, column, game in sources():
        if not path:
            continue
        series = _series_from(path, column, card_id)
        if series:
            return {
                "id": card_id,
                "updated": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
                "series": series,
                "game": game,
            }
    return None


# Counting 13M rows takes tens of seconds, so the health figures are computed
# once per process and then served from memory.
#
# A count that fails is never cached. The database is rewritten in place by the
# weekly slice, and reading it mid-swap used to raise "database is locked" -
# which the old code reported as a confident "0 printings" for the life of the
# process. Zeros now mean the cache is cold, not that the archive is empty.
#
# A database that is simply not there yet is the other case, and it is not a
# failure: it holds nothing, and (0, 0, 0) says exactly that. Those figures are
# cached like any other, so a game whose poller has not run yet cannot make
# /v1/health re-count the 13M Magic rows on every request.
_STATS = None


def _counts(path, column):
    """(printings, points, days) for one database, or None when the read failed."""
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
            return None
    return (printings, points, days)


def _empty():
    return {"printings": 0, "points": 0, "days": 0}


def _game(counts):
    """One game's counters, zeros when its database is missing or unreadable."""
    if not counts:
        return _empty()
    return {"printings": counts[0], "points": counts[1], "days": counts[2]}


def stats():
    global _STATS
    if _STATS is not None:
        return _STATS
    counts = {}
    for path, column, game in sources():
        counts[game] = _counts(path, column)
    mtg = counts["mtg"] or (0, 0, 0)
    payload = {
        "ok": True,
        # The top-level figures have always meant Magic, and still do.
        "printings": mtg[0],
        "points": mtg[1],
        "days": mtg[2],
        "games": {game: _game(value) for game, value in counts.items()},
    }
    if all(counts.values()):
        _STATS = payload
    return payload


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
    global DB_PATH, POKEMON_DB_PATH, LORCANA_DB_PATH, YUGIOH_DB_PATH, _STATS
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    default_db = os.path.join(here, "prices", "prices.db")
    ap.add_argument("--db", default=default_db)
    ap.add_argument(
        "--pokemon-db",
        default=os.path.join(here, "prices", "pokemon_prices.db"),
        help="optional Pokemon price database written by poll_pokemon_prices.py",
    )
    ap.add_argument(
        "--lorcana-db",
        default=os.path.join(here, "data", "lorcana_prices.db"),
        help="optional Lorcana price database written by poll_lorcana_prices.py",
    )
    ap.add_argument(
        "--yugioh-db",
        default=os.path.join(here, "data", "yugioh_prices.db"),
        help="optional Yu-Gi-Oh! price database written by poll_yugioh_prices.py",
    )
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8787)
    args = ap.parse_args()

    if not os.path.exists(args.db):
        print("database not found: " + args.db, file=sys.stderr)
        print("run slice_prices.py first", file=sys.stderr)
        return 1
    DB_PATH = args.db
    # A game database that is not there yet is simply not served: each poller
    # creates its own on its first run.
    POKEMON_DB_PATH = args.pokemon_db if os.path.exists(args.pokemon_db) else ""
    LORCANA_DB_PATH = args.lorcana_db if os.path.exists(args.lorcana_db) else ""
    YUGIOH_DB_PATH = args.yugioh_db if os.path.exists(args.yugioh_db) else ""
    _STATS = None
    s = stats()
    print("Arcanum Sync serving {:,} printings / {:,} points ({} days) on http://{}:{}".format(
        s["printings"], s["points"], s["days"], args.host, args.port))
    pollers = (("pokemon", "poll_pokemon_prices.py"),
               ("lorcana", "poll_lorcana_prices.py"),
               ("yugioh", "poll_yugioh_prices.py"))
    for game, poller in pollers:
        counts = s["games"].get(game, _empty())
        if counts["points"]:
            print("  + {}: {:,} printings / {:,} points ({} days)".format(
                game, counts["printings"], counts["points"], counts["days"]))
        else:
            print("  (no {} database yet - run {} to build one)".format(game, poller))
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
