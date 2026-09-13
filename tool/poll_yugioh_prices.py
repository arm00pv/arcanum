#!/usr/bin/env python3
"""Poll live Yu-Gi-Oh! prices from YGOPRODeck into a local history database.

Why this exists: YGOPRODeck publishes live *current* prices and keeps no
history. Yu-Gi-Oh! has no archive to backfill from and no paid key to buy - the
Magic series comes from MTGJSON's weekly rebuild, Pokemon's from a daily TCGdex
sample, and this game has neither - so a day that is not sampled here is a day
the charts will never have. This script samples once a day and accumulates the
series locally, the same way poll_pokemon_prices.py does for Pokemon.

**One request is the whole game.** cardinfo.php answers every card - about
14,500 of them, each with all of its printings and both price blocks - in a
single 21 MB response that takes roughly two seconds. The paged form
(num/offset) moves the same bytes over about fifteen requests, so the single
call is both the cheapest and the simplest and is what a normal run uses.
--page-size switches to paging for a host that cannot hold one response that
large, and the single call falls back to paging by itself when it fails.

**Printings are keyed the way the app keys them.** A passcode names a card, not
a printing: the same passcode is printed in every set it appears in, and one set
can hold it at two rarities under one collector code. The app therefore builds
each printing's id as

    <passcode>:<app set code>:<collector code slug>:<rarity slug>

from _printingId in lib/data/catalog/ygo_catalog.dart, and only that shape
resolves - a series stored under any other key would be a series the app never
asks for. This script rebuilds the same four fields from the same two endpoints,
including the app's set-code assignment (cardsets.php publishes 1,035 sets under
646 distinct codes, and the app suffixes the ones that collide). A card the
provider gives no printing rows at all is stored under its bare passcode, which
is the id the app gives it.

**Prices are per printing where the provider has one.** card_sets[].set_price is
the figure for that single row and is used whenever it is above zero. Where it
is zero - which the provider means as "no market data", not as "free" - the
card-level card_prices figure stands in, exactly as ygo_catalog.dart does when
it renders the card, so the line the chart draws matches the number the card
screen shows. That fallback is one number for the card ("the lowest price found
across multiple versions"), so a cheap reprint pulls it down; it is the honest
figure available and it is labelled as such here rather than hidden.

No foil series is written. The provider publishes no foil price at all, and the
app folds every foil treatment onto a single "foil" key - there is no one
honest number to put there, so storing the non-foil figure twice would claim
knowledge the source does not have.

It is free, keyless, resumable and safe to run from a scheduled task.

Usage:
    python poll_yugioh_prices.py                    # poll every card
    python poll_yugioh_prices.py --limit 500        # stop after 500 printings
    python poll_yugioh_prices.py --sets lob,ct13    # only these sets
    python poll_yugioh_prices.py --page-size 1000   # page instead of one request
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

API = "https://db.ygoprodeck.com/api/v7"
UA = "Arcanum/1.0 (+https://github.com/arcanum)"

# The finish every point is written under. See the module docstring: the source
# cannot support a second one.
FINISH = "nonfoil"

# Cards per request when paging. 1,000 keeps one response near 1.5 MB.
PAGE_SIZE = 1000

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


def get_json(url, timeout=120, retries=3):
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
        time.sleep(0.5 * (attempt + 1))
    return None


def money(raw):
    """Parses a price the provider sends as a string, treating zero as no data.

    YGOPRODeck signals "no market data" with "0.00" rather than by leaving the
    field out, so a zero is an absence and never a free card.
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


def best_usd(card_prices):
    """The one USD figure a card row should carry, mirroring ygo_catalog.dart.

    TCGplayer wins outright when it quotes a price, because it is the reference
    market for the game; only when it holds no data does the cheapest of the
    other USD vendors stand in. The EUR figure is never used.
    """
    if not isinstance(card_prices, dict):
        return None
    preferred = money(card_prices.get("tcgplayer_price"))
    if preferred is not None:
        return preferred
    alternatives = [
        value for value in (
            money(card_prices.get("ebay_price")),
            money(card_prices.get("amazon_price")),
            money(card_prices.get("coolstuffinc_price")),
        ) if value is not None
    ]
    return min(alternatives) if alternatives else None


def slug(value):
    """Mirrors _slug in ygo_catalog.dart: lower-cased, punctuation to hyphens."""
    text = re.sub(r"[^a-z0-9]+", "-", str(value or "").strip().lower())
    return text.strip("-")


def provider_code(code):
    """The set a Konami collector code belongs to: "LOB-EN001" -> "LOB"."""
    trimmed = str(code or "").strip().upper()
    dash = trimmed.find("-")
    return trimmed[:dash] if dash > 0 else trimmed


def _release_then_name(entry):
    """Orders a group of same-coded sets oldest first, then by name.

    A missing release date sorts last rather than first: a set the provider
    forgot to date is far more likely to be a recent reprint than the original.
    """
    released = entry["released"]
    if released:
        return (0, released, entry["name"])
    return (1, "", entry["name"])


def set_index(raw_sets):
    """Lower-cased set name -> the set code the app stores, as ygo_catalog.dart.

    This re-implements _YgoSet.fromJson and the assignment in _ensureSets, and
    it has to stay one: the set code is the second field of every printing id,
    so a different rule here would file today's points under ids the app never
    asks for. Konami reuses codes - 1,035 published sets share 646 codes - and
    the app disambiguates the repeats by ordering each group oldest first and
    appending a counter ("ys15", "ys152", "ys153"). The counter is appended
    with no separator, which is what the Dart code does; the comment above it
    spells the result "ys15-2" and the code does not.
    """
    parsed = []
    for item in raw_sets or []:
        if not isinstance(item, dict):
            continue
        # The name is the only handle cardinfo.php accepts - a code and an
        # unknown name are both rejected - so a nameless row is dropped.
        name = str(item.get("set_name") or "").strip()
        if not name:
            continue
        code = str(item.get("set_code") or "").strip()
        parsed.append({
            "name": name,
            "provider": (code or name).upper(),
            "released": str(item.get("tcg_date") or "").strip(),
        })

    groups = {}
    for entry in parsed:
        groups.setdefault(entry["provider"], []).append(entry)
    reserved = {entry["provider"].lower() for entry in parsed}

    assigned = {}
    for group in groups.values():
        group.sort(key=_release_then_name)
        for i, entry in enumerate(group):
            base = entry["provider"].lower()
            code = base
            n = i
            while code in assigned.values() or (n > 0 and code in reserved):
                n += 1
                code = base + str(n)
            assigned[entry["name"].lower()] = code
    return assigned


def printing_id(passcode, set_code, printing_code, rarity):
    """The catalogue id for one printing, in the app's own shape.

    Mirrors _printingId in ygo_catalog.dart field for field: the passcode stays
    first so the app can read it back with a split, the collector code and the
    rarity are slugged, an absent collector code becomes "unplaced" and an
    absent rarity "unknown". A card with neither a set nor a collector code is
    its bare passcode, which is the id the app gives such a card.
    """
    code = slug(printing_code)
    rarity_slug = slug(rarity)
    if not set_code and not code:
        return str(passcode)
    return ":".join([
        str(passcode),
        set_code,
        code or "unplaced",
        rarity_slug or "unknown",
    ])


def passcode_of(card):
    """The provider's numeric id for a card, or None when it is unusable."""
    raw = card.get("id")
    if isinstance(raw, bool) or raw is None:
        return None
    try:
        return int(str(raw).strip())
    except (TypeError, ValueError):
        return None


def card_points(card, index, wanted=()):
    """Every (card_id, price) one card contributes, in the app's id shape.

    A printing the provider gives no price for, and a card whose card-level
    block is empty too, contributes nothing: an absent point says "unknown"
    where a zero would say "worthless".
    """
    if not isinstance(card, dict):
        return []
    passcode = passcode_of(card)
    if passcode is None:
        return []

    blocks = card.get("card_prices")
    card_usd = best_usd(blocks[0]) if isinstance(blocks, list) and blocks else None

    rows = card.get("card_sets")
    rows = [r for r in rows if isinstance(r, dict)] if isinstance(rows, list) else []

    if not rows:
        # The provider does publish cards with no printing rows at all. The app
        # keeps them, unplaced, under their bare passcode.
        if card_usd is None or wanted:
            return []
        return [(printing_id(passcode, "", "", ""), card_usd)]

    out = []
    for row in rows:
        printing_code = row.get("set_code") or ""
        set_code = index.get(str(row.get("set_name") or "").strip().lower())
        if not set_code:
            set_code = provider_code(printing_code).lower()
        if wanted and set_code not in wanted and provider_code(printing_code).lower() not in wanted:
            continue
        # set_price is the printing's own figure; the card-level price is the
        # fallback the app also uses when the row quotes "0".
        price = money(row.get("set_price"))
        if price is None:
            price = card_usd
        if price is None:
            continue
        out.append((
            printing_id(passcode, set_code, printing_code, row.get("set_rarity") or ""),
            price,
        ))
    return out


def fetch_cards(page_size=0, timeout=120, retries=3):
    """Every card object, printings and prices included.

    One unpaged request is the cheap path; see the module docstring. Any
    failure there - a truncated 21 MB body, a timeout, a proxy that will not
    hold it - falls back to paging rather than losing the day.
    """
    if page_size and page_size > 0:
        return fetch_cards_paged(page_size, timeout=timeout, retries=retries)
    try:
        data = get_json(f"{API}/cardinfo.php", timeout=timeout, retries=retries)
        cards = data.get("data") if isinstance(data, dict) else None
        if cards:
            return [c for c in cards if isinstance(c, dict)]
        raise ValueError("cardinfo.php returned no card array")
    except Exception as exc:
        print(f"  full cardinfo.php failed ({exc}) — falling back to paging", file=sys.stderr, flush=True)
        return fetch_cards_paged(PAGE_SIZE, timeout=timeout, retries=retries)


def fetch_cards_paged(page_size, timeout=120, retries=3, max_pages=200):
    """The same card list, one page at a time, following the response's own meta.

    The provider answers with meta.rows_remaining, so the walk stops when it
    says there is nothing left and --max-pages is only a guard against a
    provider that never does.
    """
    cards = []
    offset = 0
    for _ in range(max_pages):
        page = get_json(
            f"{API}/cardinfo.php?num={int(page_size)}&offset={offset}",
            timeout=timeout,
            retries=retries,
        )
        if not isinstance(page, dict):
            break
        chunk = [c for c in (page.get("data") or []) if isinstance(c, dict)]
        cards.extend(chunk)
        meta = page.get("meta") if isinstance(page.get("meta"), dict) else {}
        remaining = meta.get("rows_remaining")
        print(f"  paged {len(cards):,} cards ({offset}+{len(chunk)}, remaining={remaining})", flush=True)
        if not chunk or not remaining:
            break
        offset += len(chunk)
        # Ten request starts a second, well inside the provider's documented
        # ceiling of twenty.
        time.sleep(0.1)
    return cards


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
    sampling twice on one day leaves exactly one row per printing.

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
    default_db = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "yugioh_prices.db")
    ap.add_argument("--db", default=default_db, help="history database to write")
    ap.add_argument("--out", default=None, help="alias for --db, for callers that name the output")
    ap.add_argument("--sets", default="", help="comma-separated set codes; default is all")
    ap.add_argument("--limit", type=int, default=0, help="stop after N printings (0 = no limit)")
    ap.add_argument("--page-size", type=int, default=0,
                    help="page cardinfo.php in batches of N instead of one request")
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--retries", type=int, default=3)
    ap.add_argument("--skip-polled-today", action="store_true",
                    help="do not rewrite cards already sampled today (use for a re-run)")
    args = ap.parse_args()

    if args.page_size and args.page_size < 1:
        print("--page-size must be positive", file=sys.stderr)
        return 2

    db = args.out or args.db
    con = connect(db)
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    wanted = {s.strip().lower() for s in args.sets.split(",") if s.strip()}

    # ---- the set list, which every printing id needs
    print("reading the set list", flush=True)
    raw_sets = get_json(f"{API}/cardsets.php", timeout=args.timeout, retries=args.retries)
    if not isinstance(raw_sets, list):
        print("cardsets.php returned no set list", file=sys.stderr, flush=True)
        return 1
    index = set_index(raw_sets)
    print(f"{len(index)} sets indexed", flush=True)

    # ---- every card, and every printing of it
    print("reading every card", flush=True)
    cards = fetch_cards(page_size=args.page_size, timeout=args.timeout, retries=args.retries)
    print(f"{len(cards):,} cards read", flush=True)
    if not cards:
        print("nothing to do", flush=True)
        con.close()
        return 1

    already = set()
    if args.skip_polled_today:
        already = {
            row[0] for row in con.execute(
                "SELECT card_id FROM poll_state WHERE last_polled = ?", (today,)
            )
        }
        print(f"{len(already):,} printings already sampled today", flush=True)

    # ---- sample
    t0 = time.time()
    seen = 0
    written = 0
    unpriced = 0
    pending_rows = []
    pending_state = []

    def flush():
        nonlocal written
        written += write_points(con, pending_rows, pending_state)
        pending_rows.clear()
        pending_state.clear()

    stop = False
    for card in cards:
        if stop:
            break
        passcode = passcode_of(card)
        if passcode is None:
            continue
        points = card_points(card, index, wanted)
        seen += 1
        if not points:
            unpriced += 1
        for card_id, price in points:
            if card_id in already:
                continue
            pending_rows.append((card_id, FINISH, today, price))
            if args.limit and len(pending_rows) >= args.limit:
                stop = True
                break
        if str(passcode) not in already:
            pending_state.append((str(passcode), today))
        if len(pending_rows) >= 2000:
            flush()
            rate = seen / max(time.time() - t0, 0.001)
            print(f"  {seen:,}/{len(cards):,} cards read  ({rate:.0f}/s, {written:,} points)", flush=True)

    flush()

    total = con.execute("SELECT COUNT(*) FROM history").fetchone()[0]
    printings = con.execute("SELECT COUNT(DISTINCT card_id) FROM history").fetchone()[0]
    days = con.execute("SELECT COUNT(DISTINCT date) FROM history").fetchone()[0]
    today_ids = con.execute(
        "SELECT COUNT(DISTINCT card_id) FROM history WHERE date = ?", (today,)
    ).fetchone()[0]
    con.close()
    try:
        size = os.path.getsize(db) / (1024 * 1024)
    except OSError:
        size = 0.0

    print("", flush=True)
    print(f"done in {int(time.time() - t0)}s — {written:,} points written, {unpriced:,} cards with no price at all", flush=True)
    print(f"{len(index):,} sets read, {seen:,} cards seen, {today_ids:,} printings carry a point for {today}", flush=True)
    print(f"database now holds {total:,} points across {printings:,} printings and {days} day(s), {size:.2f} MB", flush=True)
    print(f"  {db}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
