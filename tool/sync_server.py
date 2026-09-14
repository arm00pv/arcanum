#!/usr/bin/env python3
"""Arcanum Sync - a tiny price-history and backup service for the Arcanum app.

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
  GET /v1/sealed?game=mtg&set=BLB
      {"set": "BLB", "setName": "Bloomburrow", "updated": ...,
       "products": [{"productId":..., "name":..., "market":..., "low":..., "mid":...}]}
      Sealed product and what it sells for, read from TCGplayer's own product
      dumps through tcgcsv.com and cached here for half a day. Cards are filtered
      out structurally - a single carries a rarity and a collector number, a box
      carries neither - so nothing has to guess from a name alone. A set this
      server cannot resolve answers 404 and the app falls back to typing it in.

The four games address a printing differently - Scryfall UUIDs, TCGdex ids,
Lorcast's crd_ ids and Yu-Gi-Oh!'s compound ids - and those id spaces do not
overlap, so the id alone decides which database answers.

Backups, for the collector whose collection exists only on the phone:

  POST /v1/backup      body: the archive bytes (the app sends gzip)
      {"ok": true, "saved": "arcanum-backup-...json.gz", "bytes": N, "kept": K}
  GET  /v1/backup/latest
      the newest archive as application/gzip, or 404 when there is none
  GET  /v1/backup/status
      {"ok": true, "enabled": true, "backups": N, "latest": "<ISO8601 or null>", "bytes": N}

Every backup route demands an X-Arcanum-Token header matching the token in
--backup-token (~/arcanum/backup.token by default), which is read on each
request so it can be rotated without a restart. The routes above answer to
anyone, as they always have; these three must not, because a stranger who found
the URL could otherwise read a collection - what the collector owns and what
they paid for it - or overwrite the only backup of it. With no token installed
there is no write path at all: every backup route answers 503 and stores
nothing. The newest 14 archives are kept, so an upload adds history rather than
replacing it.

Run:
    python sync_server.py --port 8787 --db tool/prices/prices.db
"""

from __future__ import annotations

import argparse
import gzip
import hmac
import json
import os
import shutil
import socket
import sqlite3
import sys
import threading
import time
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

DB_PATH = ""
POKEMON_DB_PATH = ""
LORCANA_DB_PATH = ""
YUGIOH_DB_PATH = ""
BACKUP_TOKEN_PATH = ""
BACKUPS_DIR = ""
_LOCK = threading.Lock()
_CONNS = {}

# Backups. The archive is the collector's whole collection, so the write path
# is deliberately narrow: one token, one directory, one shape of filename.
BACKUP_PREFIX = "arcanum-backup-"
BACKUP_SUFFIX = ".json.gz"
BACKUP_STAMP = "%Y-%m-%dT%H%M%SZ"
BACKUP_STAMP_WIDTH = len("YYYY-MM-DDTHHMMSSZ")
INCOMING_PREFIX = ".incoming-"
KEEP_BACKUPS = 14
MAX_BACKUP_BYTES = 64 * 1024 * 1024
DRAIN_LIMIT = 64 * 1024
DRAIN_TIMEOUT = 0.5


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


# ---------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------
#
# The app's collection lives in SQLite on the phone and is the only copy of it
# that exists, so the server keeps a short history of the archives the app
# uploads. Everything below is written for a URL strangers can find: a token
# file decides whether there is a write path at all, the token is read on every
# request so it can be rotated, and nothing an unauthenticated caller can send
# changes what is stored.


def installed_token():
    """The token a backup request must carry, or None when there is none.

    Read on every request rather than once at startup: a token can then be
    rotated - or deleted, which closes the write path again - without a
    restart. A file that is missing, unreadable or empty means no write path
    at all, which is the safe way round for a service that is otherwise
    read-only.
    """
    try:
        with open(BACKUP_TOKEN_PATH, "r", encoding="utf-8") as fh:
            token = fh.read().strip()
    except OSError:
        return None
    return token or None


def token_matches(supplied, expected):
    """Compares two tokens in constant time, so a guess cannot be timed.

    hmac.compare_digest is the only comparison a token is ever put through:
    == stops at the first byte that differs, and over enough requests that
    difference in timing is a way to learn a token without ever seeing it.
    """
    return hmac.compare_digest(supplied.encode("utf-8"), expected.encode("utf-8"))


def device_slug(raw):
    """The uploader's own name for the phone, reduced to a safe filename tail.

    X-Arcanum-Device is client-supplied, so it is allowed to decide nothing but
    the text before the extension: everything outside [A-Za-z0-9._-] is
    dropped, which is also what keeps a path separator, or the quote that would
    end the Content-Disposition filename, out of a stored name.
    """
    kept = [c for c in (raw or "") if c.isascii() and (c.isalnum() or c in "._-")]
    return "".join(kept)[:32].strip(".")


def backup_name(stamp, device="", attempt=1):
    """The name one archive is stored under.

    arcanum-backup-YYYY-MM-DDTHHMMSSZ[-device].json.gz, with ".2", ".3" ...
    in front of the extension when two uploads land in the same second, so the
    second one is kept beside the first rather than replacing it.
    """
    tail = "-" + device if device else ""
    again = "" if attempt == 1 else ".%d" % attempt
    return "%s%s%s%s%s" % (BACKUP_PREFIX, stamp, tail, again, BACKUP_SUFFIX)


def archive_time(name):
    """The moment an archive records in its name, or None when it is not ours."""
    stamp = name[len(BACKUP_PREFIX):len(BACKUP_PREFIX) + BACKUP_STAMP_WIDTH]
    try:
        return datetime.strptime(stamp, BACKUP_STAMP).replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def backup_files():
    """Every stored archive, newest last.

    Names sort chronologically because the timestamp in them is fixed width,
    which is what lets retention work on names alone. Two archives uploaded
    inside the same second carry names that cannot say which came first, so
    those - and only those - are ordered by the time they were written.
    """
    try:
        names = os.listdir(BACKUPS_DIR)
    except OSError:
        return []
    names = [n for n in names
             if n.startswith(BACKUP_PREFIX) and n.endswith(BACKUP_SUFFIX)]

    def order(name):
        try:
            written = os.path.getmtime(os.path.join(BACKUPS_DIR, name))
        except OSError:
            written = 0.0
        return (name[:len(BACKUP_PREFIX) + BACKUP_STAMP_WIDTH], written, name)

    return sorted(names, key=order)


def prune_backups(keep=KEEP_BACKUPS):
    """Deletes all but the newest `keep` archives and returns how many remain.

    Run after a successful upload, so uploading grows a short history of the
    collection instead of replacing the one copy of it. An archive that cannot
    be deleted is left where it is: it is a backup, and a stubborn one is not a
    reason to report the upload that just succeeded as a failure.
    """
    names = backup_files()
    for name in names[:max(0, len(names) - keep)]:
        try:
            os.remove(os.path.join(BACKUPS_DIR, name))
        except OSError:
            pass
    return len(backup_files())


def discard(path):
    """Removes an upload that never became an archive; failure is not news."""
    try:
        os.remove(path)
    except OSError:
        pass


def backup_status():
    """What the app shows about the backups it has made.

    "bytes" is the size of the newest archive - the same figure an upload
    reports for what it just stored - and "latest" is when it was uploaded,
    read back out of its name.
    """
    names = backup_files()
    if not names:
        return {"ok": True, "enabled": True, "backups": 0, "latest": None, "bytes": 0}
    newest = names[-1]
    try:
        size = os.path.getsize(os.path.join(BACKUPS_DIR, newest))
    except OSError:
        size = 0
    when = archive_time(newest)
    return {
        "ok": True,
        "enabled": True,
        "backups": len(names),
        "latest": when.isoformat() if when else None,
        "bytes": size,
    }


def drain_body(sock, rfile, length):
    """Reads and discards a refused request's body, up to DRAIN_LIMIT bytes.

    A refusal that leaves the body unread in the socket can be answered with a
    reset instead of the 401 just written, so the client sees a broken pipe
    rather than being told why it was refused. What has already arrived is read
    off the wire, which leaves the connection usable for the next request;
    anything past DRAIN_LIMIT is left alone, which is the body the cap exists to
    avoid reading. The wait for more is short and never a wait for the whole
    declared body: a client that is being refused has usually stopped sending,
    and a client that has not must not be able to hold a thread by going quiet.
    True means every declared byte was read and the next request will line up.
    """
    if length <= 0:
        return length == 0
    was = sock.gettimeout()
    read = 0
    try:
        sock.settimeout(DRAIN_TIMEOUT)
        while read < length and read < DRAIN_LIMIT:
            try:
                chunk = rfile.read(min(length - read, 8192))
            except OSError:
                break
            if not chunk:
                return False
            read += len(chunk)
    finally:
        sock.settimeout(was)
    return read == length



# --------------------------------------------------------------- sealed product

# TCGplayer's own product lists, mirrored as plain JSON and CSV by tcgcsv.com.
# Arcanum reads them through this server rather than from the phone: one cache,
# one rate limit, one place to change when the shape moves.
TCGCSV_ROOT = "https://tcgcsv.com/tcgplayer"
SEALED_DIR = ""
SEALED_TTL = 12 * 3600
GROUPS_TTL = 7 * 24 * 3600
SEALED_TIMEOUT = 25

# The app's game ids to TCGplayer's category ids. A game missing here has no
# sealed product this server can price, and says so rather than guessing.
TCGCSV_CATEGORIES = {
    "mtg": 1,
    "yugioh": 2,
    "pokemon": 3,
    "lorcana": 71,
}

# Product names that are sealed product even when the list is vague about it.
SEALED_WORDS = (
    "booster box", "booster pack", "booster bundle", "display", "bundle",
    "elite trainer box", "trainer box", "tin", "commander deck", "starter deck",
    "structure deck", "theme deck", "precon", "deck box", "gift box",
    "collector box", "illumineer", "trove", "case", "pack", "box", "deck",
)


def _sealed_cache_path(kind, key):
    return os.path.join(SEALED_DIR, "%s-%s.json" % (kind, key))


def _read_cache(path, ttl):
    """A cached JSON document, when it is younger than ttl seconds."""
    try:
        age = time.time() - os.path.getmtime(path)
        if age > ttl:
            return None
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def _write_cache(path, payload):
    """Stores a document for next time; a cache that cannot be written is fine."""
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(payload, handle)
        os.replace(tmp, path)
    except OSError:
        pass


def _fetch_json(url):
    """One small JSON document, or None when the price list cannot be reached."""
    request = urllib.request.Request(
        url, headers={"User-Agent": "ArcanumSync/1.0 (+personal collection app)"}
    )
    try:
        with urllib.request.urlopen(request, timeout=SEALED_TIMEOUT) as response:
            return json.loads(response.read().decode("utf-8"))
    except Exception:
        return None


def _tcgsv_groups(category):
    """Every group (set) in a category, cached for a week."""
    path = _sealed_cache_path("groups", category)
    cached = _read_cache(path, GROUPS_TTL)
    if cached is not None:
        return cached
    payload = _fetch_json("%s/%d/groups" % (TCGCSV_ROOT, category))
    if not payload:
        return []
    groups = payload.get("results") or []
    _write_cache(path, groups)
    return groups


def _group_for(category, set_code):
    """The TCGplayer group id for a set code, or None."""
    wanted = (set_code or "").strip().lower()
    if not wanted:
        return None
    for group in _tcgsv_groups(category):
        if str(group.get("abbreviation") or "").strip().lower() == wanted:
            return group
    # Some sets are only named, not abbreviated; a name that matches exactly is
    # still an answer, and anything looser would attach a box to the wrong set.
    for group in _tcgsv_groups(category):
        if str(group.get("name") or "").strip().lower() == wanted:
            return group
    return None


def _is_sealed(product):
    """Whether a listed product is sealed product rather than a single card.

    Decided structurally first: a single card carries a rarity and a collector
    number, and a box carries neither. The name is used only to confirm, because
    no keyword list survives contact with a game that prints "Illumineer's Trove".
    """
    fields = {}
    for entry in product.get("extendedData") or []:
        name = str(entry.get("name") or "").lower()
        fields[name] = entry.get("value")
    if fields.get("rarity") or fields.get("number") or fields.get("cardnumber"):
        return False
    name = str(product.get("name") or "").lower()
    return any(word in name for word in SEALED_WORDS)


def sealed_for(game, set_code):
    """Sealed product and its prices for one set, or None when unknown.

    Returns {"set": ..., "group": ..., "updated": ..., "products": [...]}, where
    each product carries market, low and mid. Prices come from the same dump
    TCGplayer publishes for its own site, so a box is priced on the same basis as
    the cards inside it.
    """
    category = TCGCSV_CATEGORIES.get((game or "").strip().lower())
    if category is None:
        return None
    group = _group_for(category, set_code)
    if group is None:
        return None
    group_id = group.get("groupId")
    products_path = _sealed_cache_path("products", "%d-%s" % (category, group_id))
    prices_path = _sealed_cache_path("prices", "%d-%s" % (category, group_id))
    products = _read_cache(products_path, SEALED_TTL)
    prices = _read_cache(prices_path, SEALED_TTL)
    if not products or not prices:
        fetched_products = _fetch_json(
            "%s/%d/%s/products" % (TCGCSV_ROOT, category, group_id)
        )
        fetched_prices = _fetch_json(
            "%s/%d/%s/prices" % (TCGCSV_ROOT, category, group_id)
        )
        if not fetched_products or not fetched_prices:
            return None
        products = fetched_products.get("results") or []
        prices = fetched_prices.get("results") or []
        _write_cache(products_path, products)
        _write_cache(prices_path, prices)

    by_id = {}
    for price in prices:
        by_id[str(price.get("productId"))] = price

    out = []
    for product in products:
        if not _is_sealed(product):
            continue
        price = by_id.get(str(product.get("productId"))) or {}
        out.append({
            "productId": product.get("productId"),
            "name": product.get("cleanName") or product.get("name"),
            "market": price.get("marketPrice"),
            "low": price.get("lowPrice"),
            "mid": price.get("midPrice"),
            "url": product.get("url"),
        })
    out.sort(key=lambda p: p.get("market") or 0, reverse=True)
    return {
        "set": group.get("abbreviation") or set_code,
        "setName": group.get("name"),
        "group": group_id,
        "updated": int(time.time()),
        "products": out,
    }



# ------------------------------------------------------------------ vault page

GAME_LABELS = {
    "mtg": "Magic: The Gathering",
    "pokemon": "Pokemon",
    "lorcana": "Disney Lorcana",
    "yugioh": "Yu-Gi-Oh!",
}


def _escape(text):
    """Minimal HTML escaping: everything in this page came from a card name."""
    return (
        str(text if text is not None else "")
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def _money(value):
    try:
        return ("$" "{:,.2f}").format(float(value))
    except (TypeError, ValueError):
        return "--"


def _latest_archive():
    """The newest stored archive, decoded, or None."""
    names = backup_files()
    if not names:
        return None
    path = os.path.join(BACKUPS_DIR, names[-1])
    try:
        with gzip.open(path, "rb") as handle:
            return json.loads(handle.read().decode("utf-8")), names[-1]
    except (OSError, ValueError):
        return None


def _index_of(archive):
    """card id to (name, set code, number), however the archive stored it."""
    raw = archive.get("cards_index") or {}
    out = {}
    if isinstance(raw, dict):
        for card_id, value in raw.items():
            if isinstance(value, list) and value:
                out[str(card_id)] = tuple(value)
    return out


def _last_prices(rows):
    """(game, card id) to the newest price the app itself recorded."""
    out = {}
    for row in rows:
        key = (str(row.get("game") or "mtg"), str(row.get("card_id") or ""))
        date = str(row.get("date") or "")
        price = row.get("price")
        if not isinstance(price, (int, float)):
            continue
        if key not in out or date > out[key][0]:
            out[key] = (date, float(price))
    return out


def _sparkline(points, width=260, height=48):
    """A tiny inline SVG of the portfolio curve. No script, no library."""
    if len(points) < 2:
        return ""
    values = [value for _, value in points]
    low, high = min(values), max(values)
    span = (high - low) or 1.0
    step = width / (len(points) - 1)
    coords = []
    for i, value in enumerate(values):
        y = height - 4 - (value - low) / span * (height - 8)
        coords.append("%.1f,%.1f" % (i * step, y))
    return (
        '<svg class="spark" viewBox="0 0 %d %d" preserveAspectRatio="none">'
        '<polyline points="%s" fill="none" stroke="#8b7bf7" stroke-width="2"/>'
        "</svg>" % (width, height, " ".join(coords))
    )


def _rows_of(tables, name):
    rows = tables.get(name) or []
    return rows if isinstance(rows, list) else []


def vault_html(archive, name):
    """The whole page: one string, no template engine, no dependencies."""
    tables = archive.get("tables") or {}
    if not isinstance(tables, dict):
        tables = {}
    entries = _rows_of(tables, "collection_entries")
    sealed = _rows_of(tables, "sealed_products")
    snapshots = _rows_of(tables, "portfolio_snapshots")
    history = _rows_of(tables, "price_history")
    index = _index_of(archive)
    prices = _last_prices(history)

    games = {}
    for key, rows in (("entries", entries), ("sealed", sealed),
                      ("snapshots", snapshots)):
        for row in rows:
            if not isinstance(row, dict):
                continue
            game = str(row.get("game") or "mtg")
            bucket = games.setdefault(
                game, {"entries": [], "sealed": [], "snapshots": []})
            bucket[key].append(row)

    parts = []
    parts.append(
        '<!doctype html><html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        "<title>Arcanum vault</title><style>"
        ":root{color-scheme:dark}"
        "body{margin:0;padding:28px 20px 60px;background:#0b0b12;color:#e8e8f0;"
        "font:15px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif}"
        ".wrap{max-width:900px;margin:0 auto}"
        "h1{font-size:26px;margin:0 0 2px}h2{font-size:18px;margin:34px 0 10px}"
        ".quiet{color:#8f8fa3;font-size:13px}"
        ".card{background:#16161f;border:1px solid #26263a;border-radius:16px;"
        "padding:16px 18px;margin:14px 0}"
        ".row{display:flex;justify-content:space-between;gap:16px;padding:4px 0;"
        "border-bottom:1px solid #1e1e2c}.row:last-child{border-bottom:none}"
        ".big{font-size:24px;font-weight:600}"
        "table{width:100%;border-collapse:collapse;font-size:14px}"
        "th,td{text-align:left;padding:6px 4px;border-bottom:1px solid #1e1e2c}"
        "th{color:#8f8fa3;font-weight:500}td.n,th.n{text-align:right}"
        ".spark{width:100%;height:48px;display:block;margin-top:8px}"
        "</style></head><body><div class=\"wrap\">"
    )
    parts.append("<h1>Arcanum vault</h1>")
    parts.append(
        '<p class="quiet">A read-only view of the newest backup this server '
        "holds: <strong>%s</strong>, uploaded by Arcanum %s on %s. Nothing here "
        "is live - it is what the phone last sent.</p>"
        % (_escape(name), _escape(archive.get("app")),
           _escape(archive.get("created")))
    )

    if not games:
        parts.append('<div class="card">This backup holds no collection.</div>')

    for game in sorted(games):
        data = games[game]
        label = GAME_LABELS.get(game, game)
        parts.append("<h2>%s</h2>" % _escape(label))

        total_cards = sum(int(row.get("quantity") or 0) for row in data["entries"])
        unique = len({str(row.get("card_id")) for row in data["entries"]})
        value = 0.0
        priced = 0
        for row in data["entries"]:
            found = prices.get((game, str(row.get("card_id") or "")))
            if not found:
                continue
            value += found[1] * int(row.get("quantity") or 0)
            priced += 1

        sealed_items = sum(int(row.get("quantity") or 0) for row in data["sealed"])
        sealed_value = 0.0
        sealed_cost = 0.0
        for row in data["sealed"]:
            quantity = int(row.get("quantity") or 0)
            if isinstance(row.get("unit_value"), (int, float)):
                sealed_value += float(row["unit_value"]) * quantity
            if isinstance(row.get("unit_cost"), (int, float)):
                sealed_cost += float(row["unit_cost"]) * quantity

        points = []
        for row in sorted(data["snapshots"], key=lambda r: str(r.get("date") or "")):
            if isinstance(row.get("total_value"), (int, float)):
                points.append((str(row.get("date")), float(row["total_value"])))

        parts.append('<div class="card">')
        parts.append(
            '<div class="row"><span>Cards held</span><span class="big">%s</span>'
            "</div>" % "{:,}".format(total_cards)
        )
        parts.append(
            '<div class="row"><span>Distinct printings</span>'
            '<span class="big">%s</span></div>' % "{:,}".format(unique)
        )
        parts.append(
            '<div class="row"><span>Value at the last prices the app recorded'
            '</span><span class="big">%s</span></div>' % _money(value)
        )
        if priced < len(data["entries"]):
            parts.append(
                '<div class="row"><span class="quiet">Priced from %s of %s '
                "holdings</span><span></span></div>"
                % ("{:,}".format(priced), "{:,}".format(len(data["entries"])))
            )
        if data["sealed"]:
            parts.append(
                '<div class="row"><span>Sealed product</span>'
                '<span class="big">%s (%s items)</span></div>'
                % (_money(sealed_value), "{:,}".format(sealed_items))
            )
            if sealed_cost:
                parts.append(
                    '<div class="row"><span class="quiet">Sealed, what it cost'
                    '</span><span class="quiet">%s</span></div>'
                    % _money(sealed_cost)
                )
            parts.append(
                '<div class="row"><span>Cards and sealed together</span>'
                '<span class="big">%s</span></div>' % _money(value + sealed_value)
            )
        if points:
            parts.append(
                '<div class="row"><span class="quiet">Portfolio snapshots, %s to '
                '%s</span><span class="quiet">%s</span></div>'
                % (_escape(points[0][0]), _escape(points[-1][0]),
                   _money(points[-1][1]))
            )
            parts.append(_sparkline(points))
        parts.append("</div>")

        rows = []
        by_set = {}
        for row in data["entries"]:
            card = index.get(str(row.get("card_id") or ""))
            code = (card[1] if card and len(card) > 1 else "") or ""
            found = prices.get((game, str(row.get("card_id") or "")))
            unit = found[1] if found else None
            quantity = int(row.get("quantity") or 0)
            bucket = by_set.setdefault(
                code or "(unknown set)", {"cards": 0, "unique": set(), "value": 0.0})
            bucket["cards"] += quantity
            bucket["unique"].add(str(row.get("card_id")))
            if unit:
                bucket["value"] += unit * quantity
            rows.append({
                "name": (card[0] if card else str(row.get("card_id"))),
                "set": (card[1] if card and len(card) > 1 else ""),
                "number": (card[2] if card and len(card) > 2 else ""),
                "quantity": quantity,
                "finish": row.get("finish"),
                "condition": row.get("condition"),
                "binder": row.get("binder"),
                "unit": unit,
                "value": (unit * quantity) if unit else 0.0,
            })

        if data["entries"]:
            parts.append('<h2>By set</h2><div class="card"><table>')
            parts.append(
                "<tr><th>Set</th><th class=n>Cards</th><th class=n>Printings</th>"
                "<th class=n>Value</th></tr>"
            )
            for code, bucket in sorted(
                by_set.items(), key=lambda kv: kv[1]["value"], reverse=True
            ):
                shown = code if code == "(unknown set)" else code.upper()
                parts.append(
                    "<tr><td>%s</td><td class=n>%s</td><td class=n>%s</td>"
                    "<td class=n>%s</td></tr>"
                    % (_escape(shown), "{:,}".format(bucket["cards"]),
                       "{:,}".format(len(bucket["unique"])),
                       _money(bucket["value"]))
                )
            parts.append("</table></div>")

        rows.sort(key=lambda r: r["value"], reverse=True)
        if rows:
            parts.append('<h2>The dearest stacks</h2><div class="card"><table>')
            parts.append(
                "<tr><th>Card</th><th>Where</th><th class=n>Qty</th>"
                "<th class=n>Each</th><th class=n>Value</th></tr>"
            )
            for row in rows[:50]:
                where = " ".join(
                    part for part in
                    (row["set"], row["number"], row["binder"] or "") if part
                )
                detail = " ".join(
                    part for part in (row["finish"], row["condition"]) if part
                )
                parts.append(
                    "<tr><td>%s<div class=\"quiet\">%s</div></td><td>%s</td>"
                    "<td class=n>%s</td><td class=n>%s</td><td class=n>%s</td></tr>"
                    % (_escape(row["name"]), _escape(detail), _escape(where),
                       "{:,}".format(row["quantity"]),
                       _money(row["unit"]) if row["unit"] else "--",
                       _money(row["value"]) if row["unit"] else "--")
                )
            parts.append("</table>")
            if len(rows) > 50:
                parts.append(
                    '<p class="quiet">and %s more holdings.</p>'
                    % "{:,}".format(len(rows) - 50)
                )
            parts.append("</div>")

        if data["sealed"]:
            parts.append('<h2>Sealed product</h2><div class="card"><table>')
            parts.append(
                "<tr><th>Product</th><th>Where</th><th class=n>Qty</th>"
                "<th class=n>Each</th><th class=n>Value</th></tr>"
            )
            for row in sorted(
                data["sealed"],
                key=lambda r: (r.get("unit_value") or 0) * int(r.get("quantity") or 0),
                reverse=True,
            ):
                quantity = int(row.get("quantity") or 0)
                unit = row.get("unit_value")
                detail = " ".join(
                    part for part in
                    (row.get("set_name"), row.get("category")) if part
                )
                parts.append(
                    "<tr><td>%s<div class=\"quiet\">%s</div></td><td>%s</td>"
                    "<td class=n>%s</td><td class=n>%s</td><td class=n>%s</td></tr>"
                    % (_escape(row.get("name")), _escape(detail),
                       _escape(row.get("location") or ""),
                       "{:,}".format(quantity),
                       _money(unit) if unit else "--",
                       _money(unit * quantity) if unit else "--")
                )
            parts.append("</table></div>")

    parts.append(
        '<p class="quiet">Arcanum holds this collection on one phone and sends '
        "it nowhere except here. This page reads the copy on this server, needs "
        "no account, and cannot change anything.</p>"
    )
    parts.append("</div></body></html>")
    return "".join(parts)


class Handler(BaseHTTPRequestHandler):
    server_version = "ArcanumSync/1.0"
    protocol_version = "HTTP/1.1"

    def _send(self, code, payload, cache="public, max-age=3600", close=False):
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", cache)
        if close:
            # A body that was not read leaves the socket in the middle of a
            # request, so this connection cannot carry another one.
            self.close_connection = True
            self.send_header("Connection", "close")
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
            if path in ("/vault", "/v1/vault"):
                # Read from the query string as well as the header: a browser
                # navigating to a URL cannot send a header, and the token is the
                # only lock this server has.
                if not self._vault_gate():
                    return
                found = _latest_archive()
                if found is None:
                    self._send(404, {"error": "no backup"}, cache="no-store")
                    return
                archive, name = found
                body = vault_html(archive, name).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)
                return
            if path == "/v1/sealed":
                query = parse_qs(urlparse(self.path).query)
                game = (query.get("game") or ["mtg"])[0]
                set_code = (query.get("set") or [""])[0]
                if not set_code:
                    self._send(400, {"error": "no set", "game": game})
                    return
                data = sealed_for(game, set_code)
                if data is None:
                    self._send(404, {"error": "no sealed product",
                                     "game": game, "set": set_code})
                    return
                self._send(200, data)
                return
            if path == "/v1/backup/status":
                if not self._backup_gate():
                    return
                self._send(200, backup_status(), cache="no-store")
                return
            if path == "/v1/backup/latest":
                if not self._backup_gate():
                    return
                names = backup_files()
                if not names or not self._send_archive(names[-1]):
                    self._send(404, {"error": "no backup"}, cache="no-store")
                return
            self._send(404, {"error": "not found", "path": path})
        except BrokenPipeError:
            pass
        except Exception as exc:
            try:
                self._send(500, {"error": str(exc)})
            except Exception:
                pass

    def _send_archive(self, name):
        """Streams one stored archive back exactly as it was uploaded."""
        path = os.path.join(BACKUPS_DIR, name)
        try:
            size = os.path.getsize(path)
            handle = open(path, "rb")
        except OSError:
            return False
        self.send_response(200)
        self.send_header("Content-Type", "application/gzip")
        self.send_header("Content-Length", str(size))
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % name)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        with handle:
            shutil.copyfileobj(handle, self.wfile, 1 << 20)
        return True

    def _refuse(self, code, payload, length=0):
        """Answers a request whose body this server is not going to store."""
        self._send(code, payload, cache="no-store",
                   close=not drain_body(self.connection, self.rfile, length))

    def _vault_gate(self):
        """Refuses the vault page unless the request carries the token.

        The page shows the whole collection - what is owned, what it cost, where
        it is kept - so it is behind the same token as the backups themselves.
        The token may arrive as a query parameter because that is the only way a
        browser can carry it into a page; the trade is that it lands in the
        browser's history, which is why the page itself never prints it.
        """
        token = installed_token()
        if token is None:
            self._send(503, {"ok": False, "enabled": False,
                             "error": "no token installed"}, cache="no-store")
            return False
        query = parse_qs(urlparse(self.path).query)
        supplied = (
            self.headers.get("X-Arcanum-Token")
            or (query.get("token") or [""])[0]
        )
        if not token_matches(supplied, token):
            self._send(401, {"ok": False, "error": "unauthorized"},
                       cache="no-store")
            return False
        return True

    def _backup_gate(self, length=0):
        """Refuses the request unless it carries the token that is installed.

        Returns True when the request may go on. The two refusals say the least
        they can: with no token file there is no write path to protect and the
        answer is 503, and with one installed a request that does not carry it
        is told only that - never whether the file is there, what it holds, or
        how close a guess came.
        """
        token = installed_token()
        if token is None:
            self._refuse(503, {"ok": False, "enabled": False,
                               "error": "backups disabled"}, length)
            return False
        supplied = self.headers.get("X-Arcanum-Token") or ""
        if not token_matches(supplied, token):
            self._refuse(401, {"ok": False, "error": "unauthorized"}, length)
            return False
        return True

    def do_POST(self):
        path = unquote(urlparse(self.path).path)
        try:
            try:
                length = int(self.headers.get("Content-Length") or "")
            except ValueError:
                length = -1
            if path != "/v1/backup":
                self._refuse(404, {"error": "not found", "path": path}, length)
                return
            if not self._backup_gate(length):
                return
            if length < 0:
                self._refuse(411, {"ok": False, "error": "length required"}, length)
                return
            if length == 0:
                self._refuse(400, {"ok": False, "error": "empty body"}, length)
                return
            if length > MAX_BACKUP_BYTES:
                # Refused on the declared length, before a byte of the body is
                # read: an archive that size is not a collection, and reading
                # it to find out is the denial of service the cap exists to
                # stop.
                self._refuse(413, {"ok": False, "error": "too large",
                                   "limit": MAX_BACKUP_BYTES}, length)
                return
            self._store_backup(length)
        except BrokenPipeError:
            pass
        except Exception as exc:
            try:
                self._send(500, {"error": str(exc)}, cache="no-store")
            except Exception:
                pass

    def _store_backup(self, length):
        """Stores one uploaded archive, or leaves what is stored untouched.

        The body is streamed to a temporary file beside the archives and moved
        into place only once every declared byte has arrived and been flushed,
        so an upload that stops halfway - the phone losing signal, the socket
        dying - can leave neither a half-written archive where the app expects
        a whole one, nor a mark on the backup that was already there.
        """
        try:
            os.makedirs(BACKUPS_DIR, exist_ok=True)
        except OSError as exc:
            self._refuse(500, {"ok": False, "error": str(exc)}, length)
            return
        stamp = datetime.now(timezone.utc).strftime(BACKUP_STAMP)
        device = device_slug(self.headers.get("X-Arcanum-Device"))
        name, tmp, handle = "", "", None
        for attempt in range(1, 1000):
            candidate = backup_name(stamp, device, attempt)
            if os.path.exists(os.path.join(BACKUPS_DIR, candidate)):
                continue
            tmp = os.path.join(BACKUPS_DIR, INCOMING_PREFIX + candidate)
            try:
                # O_EXCL, so two uploads landing in the same second cannot both
                # decide on one name and then lose an archive to each other.
                fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY
                             | getattr(os, "O_BINARY", 0))
            except FileExistsError:
                continue
            except OSError as exc:
                self._refuse(500, {"ok": False, "error": str(exc)}, length)
                return
            name, handle = candidate, os.fdopen(fd, "wb")
            break
        if handle is None:
            self._refuse(500, {"ok": False, "error": "no name for the archive"}, length)
            return
        written = 0
        try:
            with handle:
                while written < length:
                    chunk = self.rfile.read(min(length - written, 1 << 20))
                    if not chunk:
                        break
                    handle.write(chunk)
                    written += len(chunk)
                # Flushed onto the disk before the name is moved into place:
                # this file is a backup, and a rename that outruns the data it
                # names would report a backup that is not there.
                handle.flush()
                os.fsync(handle.fileno())
        except OSError as exc:
            discard(tmp)
            self._refuse(500, {"ok": False, "error": str(exc)}, length - written)
            return
        if written != length:
            discard(tmp)
            self._refuse(400, {"ok": False, "error": "incomplete body",
                               "got": written}, length - written)
            return
        try:
            os.replace(tmp, os.path.join(BACKUPS_DIR, name))
        except OSError as exc:
            discard(tmp)
            self._refuse(500, {"ok": False, "error": str(exc)}, length)
            return
        self._send(200, {"ok": True, "saved": name, "bytes": written,
                         "kept": prune_backups()}, cache="no-store")

    def log_message(self, fmt, *args):
        sys.stderr.write("  " + (fmt % args) + "\n")


def main():
    global DB_PATH, POKEMON_DB_PATH, LORCANA_DB_PATH, YUGIOH_DB_PATH
    global BACKUP_TOKEN_PATH, BACKUPS_DIR, SEALED_DIR, _STATS
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
    ap.add_argument(
        "--backups-dir",
        default=os.path.join(os.path.expanduser("~"), "arcanum", "backups"),
        help="where the archives uploaded by the app are kept",
    )
    ap.add_argument(
        "--backup-token",
        default=os.path.join(os.path.expanduser("~"), "arcanum", "backup.token"),
        help="file holding the token a backup request must send; while it is "
             "missing or empty the backup routes answer 503 and store nothing",
    )
    ap.add_argument(
        "--sealed-dir",
        default=os.path.join(os.path.expanduser("~"), "arcanum", "data", "sealed"),
        help="where set product lists and their prices are cached",
    )
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
    BACKUPS_DIR = args.backups_dir
    BACKUP_TOKEN_PATH = args.backup_token
    SEALED_DIR = args.sealed_dir
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
    print("  sealed product: cached in {} ({} categories)".format(
        args.sealed_dir, len(TCGCSV_CATEGORIES)))
    if installed_token() is None:
        print("  backups disabled: no token in {} (backup routes answer 503)".format(
            args.backup_token))
    else:
        print("  backups enabled: keeping the newest {} archives in {}".format(
            KEEP_BACKUPS, args.backups_dir))
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
