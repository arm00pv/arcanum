#!/usr/bin/env python3
"""Poll live Disney Lorcana prices from Lorcast into a local history database.

Why this exists: Lorcast publishes live *current* prices and keeps no history,
and no free Lorcana price-history API exists anywhere - there is no archive to
backfill from and no paid key to buy. A day that is not sampled here is a day
the Lorcana charts will never have, so this script samples Lorcast once a day
and accumulates the series locally, the same way poll_pokemon_prices.py does for
Pokemon.

Lorcast is asked for one set at a time: /sets lists the 23 sets and
/sets/{code}/cards answers a whole set - about 3,200 cards in total - as a bare
JSON array of full card objects, so one request per set covers the game. The
prices ride on each card as decimal *strings* under prices.usd (non-foil) and
prices.usd_foil (foil), which is exactly the pair of finishes Lorcana physically
prints. A card Lorcast quotes no price for is written as nothing at all rather
than as a zero: an absent point says "unknown", and a zero would say "worthless".

Card ids are Lorcast's own ids (crd_...) stored verbatim, because that is the id
the app catalogues and asks the companion for.

It is free, keyless, resumable and safe to run from a scheduled task.

Usage:
    python poll_lorcana_prices.py                    # poll every set
    python poll_lorcana_prices.py --sets 1,2,P1      # poll only these sets
    python poll_lorcana_prices.py --limit 500        # stop after 500 cards
    python poll_lorcana_prices.py --skip-polled-today
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from urllib.parse import quote

API = "https://api.lorcast.com/v0"
UA = "Arcanum/1.0 (+https://github.com/arcanum)"

# Lorcast's two price fields are the two finishes the game is printed in, so the
# mapping onto the app's finish codes is direct.
FINISH_MAP = {
    "usd": "nonfoil",
    "usd_foil": "foil",
}

# The history table matches the Magic and Pokemon databases exactly, so the
# companion service reads all three without knowing which game it is looking at.
SCHEMA = [
    """
    CREATE TABLE IF NOT EXISTS history (
        card_id TEXT NOT NULL,
        finish  TEXT NOT NULL,
        date    TEXT NOT NULL,
        price   REAL NOT NULL,
        PRIMARY KEY (card_id, finish, date)
    ) WITHOUT ROWID
    """,
    "CREATE INDEX IF NOT EXISTS idx_hist ON history(card_id, finish, date DESC)",
    """
    CREATE TABLE IF NOT EXISTS poll_state (
        card_id     TEXT PRIMARY KEY,
        last_polled TEXT NOT NULL
    )
    """,
]


def get_json(url, timeout=60, retries=3):
    """GETs a URL and decodes JSON, retrying transient failures."""
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            if attempt >= retries:
                raise
        except Exception:
            if attempt >= retries:
                raise
        time.sleep(0.4 * (attempt + 1))
    return None


def money(raw):
    """Parses one of Lorcast's decimal-string prices, or None when unusable.

    The provider sends prices as strings, leaves the field out entirely for a
    card it has no market data for, and is not above sending an empty string.
    Anything that is not a finite, strictly positive number is therefore an
    absence, never a zero.
    """
    if raw is None or isinstance(raw, bool):
        return None
    try:
        value = float(str(raw).strip())
    except (TypeError, ValueError):
        return None
    if not math.isfinite(value) or value <= 0:
        return None
    return value


def prices_of(card):
    """Extracts {finish_code: usd_price} from one Lorcast card object."""
    prices = card.get("prices")
    out = {}
    if isinstance(prices, dict):
        for field, finish in FINISH_MAP.items():
            value = money(prices.get(field))
            if value is not None:
                out[finish] = value
    return out


def set_codes(timeout=60, retries=3):
    """Every set code, spelled exactly as Lorcast spells it.

    The casing is not decoration: the provider answers /sets/P1/cards and 404s
    /sets/p1/cards, so the code from this list is the only safe thing to request.
    """
    data = get_json(f"{API}/sets", timeout=timeout, retries=retries)
    results = data.get("results") if isinstance(data, dict) else data
    out = []
    for item in results or []:
        if not isinstance(item, dict):
            continue
        code = item.get("code")
        if isinstance(code, str) and code.strip():
            out.append(code.strip())
    return out


def cards_for_set(code, timeout=60, retries=3):
    """Every card object in one set, as a bare JSON array.

    A set Lorcast does not answer for is an error rather than an empty set. The
    codes are case-sensitive - "P1" answers and "p1" is a 404 - so a silent zero
    here would be indistinguishable from a set that genuinely holds no cards,
    and a whole set would go unsampled without a word in the log.
    """
    data = get_json(f"{API}/sets/{quote(code, safe='')}/cards", timeout=timeout, retries=retries)
    if data is None:
        raise ValueError(f"Lorcast has no set {code!r} (its codes are case-sensitive)")
    if not isinstance(data, list):
        raise ValueError(f"expected a bare card array, got {type(data).__name__}")
    return [c for c in data if isinstance(c, dict)]


def connect(db_path):
    """Opens the history database, creating it and its schema when absent."""
    parent = os.path.dirname(os.path.abspath(db_path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    con = sqlite3.connect(db_path)
    for stmt in SCHEMA:
        con.execute(stmt)
    con.commit()
    return con


def write_points(con, rows, state=()):
    """Writes one batch of (card_id, finish, date, price) points.

    This is the only insert path this script has, so a run is idempotent: the
    primary key is (card_id, finish, date) and every write replaces, which means
    sampling twice on one day leaves exactly one row per card and finish.

    A batch is one transaction. A run that dies part way through therefore keeps
    every batch already committed and loses at most the batch in flight, rather
    than leaving a half-written day behind.
    """
    with con:
        if rows:
            con.executemany("INSERT OR REPLACE INTO history VALUES (?,?,?,?)", rows)
        if state:
            con.executemany("INSERT OR REPLACE INTO poll_state VALUES (?,?)", state)
    return len(rows)


def main():
    ap = argparse.ArgumentParser()
    default_db = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "lorcana_prices.db")
    ap.add_argument("--db", default=default_db, help="history database to write")
    ap.add_argument("--out", default=None, help="alias for --db, for callers that name the output")
    ap.add_argument("--sets", default="", help="comma-separated set codes; default is all")
    ap.add_argument("--limit", type=int, default=0, help="stop after N cards (0 = no limit)")
    ap.add_argument("--delay", type=float, default=0.4,
                    help="seconds to wait between set requests (politeness)")
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--retries", type=int, default=3)
    ap.add_argument("--skip-polled-today", action="store_true",
                    help="do not rewrite cards already sampled today (use for a re-run)")
    args = ap.parse_args()

    db = args.out or args.db
    con = connect(db)
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    # ---- work out which sets to read
    if args.sets:
        codes = [s.strip() for s in args.sets.split(",") if s.strip()]
    else:
        codes = set_codes(timeout=args.timeout, retries=args.retries)
    print(f"{len(codes)} sets to scan", flush=True)
    if not codes:
        print("nothing to do", flush=True)
        con.close()
        return 0

    already = set()
    if args.skip_polled_today:
        already = {
            row[0] for row in con.execute(
                "SELECT card_id FROM poll_state WHERE last_polled = ?", (today,)
            )
        }
        print(f"{len(already)} cards already sampled today", flush=True)

    # ---- sample
    t0 = time.time()
    seen = 0
    written = 0
    unpriced = 0
    failed_sets = 0

    for i, code in enumerate(codes, 1):
        if args.limit and seen >= args.limit:
            break
        try:
            cards = cards_for_set(code, timeout=args.timeout, retries=args.retries)
        except Exception as exc:
            failed_sets += 1
            print(f"  set {code} failed: {exc}", file=sys.stderr, flush=True)
            time.sleep(args.delay)
            continue

        rows = []
        state = []
        for card in cards:
            if args.limit and seen >= args.limit:
                break
            card_id = card.get("id")
            if not isinstance(card_id, str) or not card_id.strip():
                continue
            card_id = card_id.strip()
            seen += 1
            if card_id in already:
                continue
            prices = prices_of(card)
            if not prices:
                unpriced += 1
            for finish, price in prices.items():
                rows.append((card_id, finish, today, price))
            state.append((card_id, today))

        written += write_points(con, rows, state)
        print(f"  set {i}/{len(codes)} {code}: {len(cards)} cards, {len(rows)} points", flush=True)
        if i < len(codes):
            time.sleep(args.delay)

    total = con.execute("SELECT COUNT(*) FROM history").fetchone()[0]
    cards_held = con.execute("SELECT COUNT(DISTINCT card_id) FROM history").fetchone()[0]
    days = con.execute("SELECT COUNT(DISTINCT date) FROM history").fetchone()[0]
    con.close()
    try:
        size = os.path.getsize(db) / (1024 * 1024)
    except OSError:
        size = 0.0

    print("", flush=True)
    print(f"done in {int(time.time() - t0)}s — {written} points written, {failed_sets} set(s) failed", flush=True)
    print(f"{len(codes)} sets read, {seen:,} cards seen, {unpriced:,} with no price at all", flush=True)
    print(f"database now holds {total:,} points across {cards_held:,} cards and {days} day(s), {size:.2f} MB", flush=True)
    print(f"  {db}", flush=True)
    return 1 if failed_sets and failed_sets == len(codes) else 0


if __name__ == "__main__":
    raise SystemExit(main())
