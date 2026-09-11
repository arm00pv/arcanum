#!/usr/bin/env python3
"""Poll live Pokemon TCG prices from TCGdex into a local history database.

Why this exists: no free, live, per-card Pokemon price-history API exists.
TCGdex publishes live *current* prices but keeps no history, and the community
price archive on GitHub stopped updating in September 2024. This script closes
that gap by sampling TCGdex once a day and accumulating the series locally, so
Arcanum can chart real Pokemon trends without a paid key.

It is free, keyless, resumable and safe to run from a scheduled task.

Usage:
    python poll_pokemon_prices.py                 # poll every card
    python poll_pokemon_prices.py --limit 500     # poll only 500 cards
    python poll_pokemon_prices.py --sets base1,sv01
    python poll_pokemon_prices.py --stale-days 1  # only cards not polled today
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

API = "https://api.tcgdex.net/v2/en"
UA = "Arcanum/1.0 (+https://github.com/arcanum)"

# TCGdex/TCGplayer variant key -> Arcanum finish code.
FINISH_MAP = {
    "normal": "nonfoil",
    "holofoil": "holofoil",
    "unlimitedholofoil": "holofoil",
    "reverseholofoil": "reverse_holofoil",
    "1stedition": "first_edition",
    "1steditionholofoil": "first_edition_holofoil",
}

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


def get_json(url, timeout=30, retries=3):
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


def finish_prices(card):
    """Extracts {finish_code: usd_price} from a TCGdex card response."""
    pricing = card.get("pricing") or {}
    tcg = pricing.get("tcgplayer")
    out = {}
    if isinstance(tcg, dict):
        for key, value in tcg.items():
            if not isinstance(value, dict):
                continue
            price = value.get("marketPrice") or value.get("midPrice")
            finish = FINISH_MAP.get(str(key).lower())
            if finish and isinstance(price, (int, float)) and price > 0:
                out.setdefault(finish, float(price))
    # Fall back to the variants list when the flat pricing block is absent.
    if not out:
        for variant in card.get("variants_detailed") or []:
            if not isinstance(variant, dict):
                continue
            vpricing = (variant.get("pricing") or {}).get("tcgplayer")
            if not isinstance(vpricing, dict):
                continue
            for key, value in vpricing.items():
                if not isinstance(value, dict):
                    continue
                price = value.get("marketPrice") or value.get("midPrice")
                finish = FINISH_MAP.get(str(key).lower()) or FINISH_MAP.get(
                    str(variant.get("type", "")).lower())
                if finish and isinstance(price, (int, float)) and price > 0:
                    out.setdefault(finish, float(price))
    return out


def card_ids_for_set(set_id):
    data = get_json(f"{API}/sets/{set_id}")
    if not isinstance(data, dict):
        return []
    return [c.get("id") for c in (data.get("cards") or []) if isinstance(c, dict) and c.get("id")]


def main():
    ap = argparse.ArgumentParser()
    default_db = os.path.join(os.path.dirname(os.path.abspath(__file__)), "prices", "pokemon_prices.db")
    ap.add_argument("--db", default=default_db)
    ap.add_argument("--sets", default="", help="comma-separated set ids; default is all")
    ap.add_argument("--limit", type=int, default=0, help="stop after N cards (0 = no limit)")
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--skip-polled-today", action="store_true",
                    help="skip cards already sampled today (use for a daily run)")
    args = ap.parse_args()

    os.makedirs(os.path.dirname(args.db), exist_ok=True)
    con = sqlite3.connect(args.db)
    for stmt in SCHEMA:
        con.execute(stmt)
    con.commit()

    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    # ---- work out which cards to sample
    if args.sets:
        set_ids = [s.strip() for s in args.sets.split(",") if s.strip()]
    else:
        sets = get_json(f"{API}/sets") or []
        set_ids = [s.get("id") for s in sets if isinstance(s, dict) and s.get("id")]
    print(f"{len(set_ids)} sets to scan", flush=True)

    already = set()
    if args.skip_polled_today:
        already = {
            row[0] for row in con.execute(
                "SELECT card_id FROM poll_state WHERE last_polled = ?", (today,)
            )
        }
        print(f"{len(already)} cards already sampled today", flush=True)

    card_ids = []
    for i, set_id in enumerate(set_ids, 1):
        try:
            ids = card_ids_for_set(set_id)
        except Exception as exc:
            print(f"  set {set_id} failed: {exc}", file=sys.stderr, flush=True)
            continue
        for cid in ids:
            if cid not in already:
                card_ids.append(cid)
        if i % 25 == 0:
            print(f"  scanned {i}/{len(set_ids)} sets, {len(card_ids)} cards queued", flush=True)
        if args.limit and len(card_ids) >= args.limit:
            card_ids = card_ids[: args.limit]
            break

    if not card_ids:
        print("nothing to do", flush=True)
        return 0

    print(f"sampling {len(card_ids)} cards", flush=True)

    # ---- sample
    written = 0
    failed = 0
    pending_rows = []
    pending_state = []
    t0 = time.time()

    def flush():
        nonlocal written
        if pending_rows:
            con.executemany("INSERT OR REPLACE INTO history VALUES (?,?,?,?)", pending_rows)
            written += len(pending_rows)
            pending_rows.clear()
        if pending_state:
            con.executemany("INSERT OR REPLACE INTO poll_state VALUES (?,?)", pending_state)
            pending_state.clear()
        con.commit()

    def sample(card_id):
        try:
            card = get_json(f"{API}/cards/{card_id}")
        except Exception:
            return card_id, None
        if not isinstance(card, dict):
            return card_id, None
        return card_id, finish_prices(card)

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        for n, (card_id, prices) in enumerate(pool.map(sample, card_ids), 1):
            if prices is None:
                failed += 1
            else:
                for finish, price in prices.items():
                    pending_rows.append((card_id, finish, today, price))
                pending_state.append((card_id, today))
            if len(pending_rows) >= 2000:
                flush()
            if n % 2000 == 0:
                rate = n / max(time.time() - t0, 0.001)
                print(f"  {n}/{len(card_ids)} sampled  ({rate:.1f}/s, {written} points)", flush=True)

    flush()
    total = con.execute("SELECT COUNT(*) FROM history").fetchone()[0]
    cards = con.execute("SELECT COUNT(DISTINCT card_id) FROM history").fetchone()[0]
    days = con.execute("SELECT COUNT(DISTINCT date) FROM history").fetchone()[0]
    con.close()

    print("", flush=True)
    print(f"done in {int(time.time() - t0)}s — {written} points written, {failed} cards failed", flush=True)
    print(f"database now holds {total:,} points across {cards:,} cards and {days} day(s)", flush=True)
    print(f"  {args.db}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
