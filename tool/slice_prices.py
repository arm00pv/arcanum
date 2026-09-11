#!/usr/bin/env python3
"""Build a compact per-printing price-history database from MTGJSON.

Scryfall publishes only *current* prices, and MTGJSON's smallest price-history
artifact is a 1.2 GB JSON document keyed by MTGJSON's own UUIDs. This tool
streams that document once, joins it to Scryfall printing ids via
AllIdentifiers, and emits a small SQLite database that the Arcanum Sync
companion service can serve per card.

Usage:
    python slice_prices.py --dir tool/prices [--limit 5000]
"""

from __future__ import annotations

import argparse
import gzip
import io
import json
import os
import re
import sqlite3
import sys
import time

# --------------------------------------------------------------------------
# Streaming JSON reader
# --------------------------------------------------------------------------


class JsonStream:
    """A minimal chunked JSON scanner that never holds the whole document."""

    def __init__(self, fh: io.TextIOBase, chunk: int = 1 << 20) -> None:
        self.fh = fh
        self.chunk = chunk
        self.buf = ""
        self.pos = 0
        self.eof = False

    def _fill(self) -> bool:
        if self.eof:
            return False
        if self.pos:
            self.buf = self.buf[self.pos :]
            self.pos = 0
        data = self.fh.read(self.chunk)
        if not data:
            self.eof = True
            return False
        self.buf += data
        return True

    def peek(self) -> str:
        while self.pos >= len(self.buf):
            if not self._fill():
                return ""
        return self.buf[self.pos]

    def take(self) -> str:
        c = self.peek()
        if c:
            self.pos += 1
        return c

    def skip_ws(self) -> str:
        while True:
            c = self.peek()
            if c and c in " \t\r\n":
                self.pos += 1
            else:
                return c

    def expect(self, ch: str) -> None:
        got = self.skip_ws()
        if got != ch:
            raise ValueError(f"expected {ch!r} but found {got!r}")
        self.pos += 1

    def read_string(self) -> str:
        self.expect('"')
        out: list[str] = []
        while True:
            c = self.take()
            if c == "":
                raise EOFError("unterminated string")
            if c == "\\":
                out.append(self.take())
            elif c == '"':
                return "".join(out)
            else:
                out.append(c)

    def read_raw_value(self) -> str:
        """Consumes one JSON value and returns its raw text."""
        c = self.skip_ws()
        if c in "{[":
            depth = 0
            chars: list[str] = []
            in_str = False
            esc = False
            while True:
                ch = self.take()
                if ch == "":
                    raise EOFError("unexpected end of document")
                chars.append(ch)
                if in_str:
                    if esc:
                        esc = False
                    elif ch == "\\":
                        esc = True
                    elif ch == '"':
                        in_str = False
                else:
                    if ch == '"':
                        in_str = True
                    elif ch in "{[":
                        depth += 1
                    elif ch in "}]":
                        depth -= 1
                        if depth == 0:
                            return "".join(chars)
        chars = []
        while True:
            ch = self.peek()
            if ch == "" or ch in ",}] \t\r\n":
                return "".join(chars)
            chars.append(self.take())


def iter_root_entries(fh: io.TextIOBase, want: str = "data"):
    """Yields (key, raw_json) for each entry of the root object's *want* member."""
    js = JsonStream(fh)
    js.expect("{")
    while True:
        c = js.skip_ws()
        if c == "}":
            js.pos += 1
            return
        if c == ",":
            js.pos += 1
            continue
        key = js.read_string()
        js.expect(":")
        if key != want:
            js.read_raw_value()
            continue
        js.expect("{")
        while True:
            c = js.skip_ws()
            if c == "}":
                js.pos += 1
                break
            if c == ",":
                js.pos += 1
                continue
            k = js.read_string()
            js.expect(":")
            yield k, js.read_raw_value()


def open_maybe_gz(path: str) -> io.TextIOBase:
    if path.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8")
    return open(path, "r", encoding="utf-8")


# --------------------------------------------------------------------------
# Build steps
# --------------------------------------------------------------------------


_SCRYFALL_ID_RE = re.compile(r'"scryfallId"\s*:\s*"([0-9a-fA-F-]{36})"')


def build_uuid_map(path: str, limit: int | None = None) -> dict[str, str]:
    """MTGJSON uuid -> Scryfall printing id.

    The identifier lives at `identifiers.scryfallId`. Entries also carry large
    unrelated payloads (legalities, foreign data), so the id is pulled out with
    a regex instead of a full parse — roughly an order of magnitude faster over
    ~110k entries.
    """
    out: dict[str, str] = {}
    t0 = time.time()
    with open_maybe_gz(path) as fh:
        for uuid, raw in iter_root_entries(fh):
            m = _SCRYFALL_ID_RE.search(raw)
            if m:
                out[uuid] = m.group(1)
            if limit and len(out) >= limit:
                break
    print(f"  identifiers: {len(out):,} uuid->scryfallId in {time.time()-t0:.1f}s", flush=True)
    return out


FINISHES = (("normal", "nonfoil"), ("foil", "foil"), ("etched", "etched"))


def build_database(
    prices_path: str,
    uuid_map: dict[str, str],
    out_path: str,
    limit: int | None = None,
) -> None:
    if os.path.exists(out_path):
        os.remove(out_path)
    con = sqlite3.connect(out_path)
    con.execute("PRAGMA journal_mode=OFF")
    con.execute("PRAGMA synchronous=OFF")
    con.execute("PRAGMA temp_store=MEMORY")
    con.execute(
        """
        CREATE TABLE history (
            scryfall_id TEXT NOT NULL,
            finish      TEXT NOT NULL,
            date        TEXT NOT NULL,
            price       REAL NOT NULL,
            PRIMARY KEY (scryfall_id, finish, date)
        ) WITHOUT ROWID
        """
    )

    t0 = time.time()
    matched = 0
    rows = 0
    batch: list[tuple[str, str, str, float]] = []
    pending = 0

    with open_maybe_gz(prices_path) as fh:
        for uuid, raw in iter_root_entries(fh):
            pending += 1
            if pending % 20000 == 0:
                print(
                    f"  ...{pending:,} price records scanned, {matched:,} matched, "
                    f"{rows:,} points, {time.time()-t0:.0f}s",
                    flush=True,
                )
            sid = uuid_map.get(uuid)
            if sid is None:
                continue
            matched += 1
            try:
                obj = json.loads(raw)
            except json.JSONDecodeError:
                continue
            retail = (
                obj.get("paper", {})
                .get("tcgplayer", {})
                .get("retail", {})
            )
            if not retail:
                continue
            for json_key, finish in FINISHES:
                series = retail.get(json_key)
                if not isinstance(series, dict):
                    continue
                for date, price in series.items():
                    if not isinstance(price, (int, float)) or price <= 0:
                        continue
                    batch.append((sid, finish, date, float(price)))
                    rows += 1
            if len(batch) >= 50000:
                con.executemany(
                    "INSERT OR REPLACE INTO history VALUES (?,?,?,?)", batch
                )
                batch.clear()
            if limit and matched >= limit:
                break

    if batch:
        con.executemany("INSERT OR REPLACE INTO history VALUES (?,?,?,?)", batch)
    con.commit()
    print("  building index...", flush=True)
    con.execute("CREATE INDEX idx_history_card ON history(scryfall_id, finish, date)")
    con.execute("ANALYZE")
    con.commit()
    con.close()
    size = os.path.getsize(out_path) / (1024 * 1024)
    print(
        f"  prices: {matched:,} printings matched, {rows:,} points, "
        f"{size:.1f} MB, {time.time()-t0:.0f}s",
        flush=True,
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=os.path.dirname(os.path.abspath(__file__)) + "/prices")
    ap.add_argument("--out", default=None)
    ap.add_argument("--limit", type=int, default=None, help="stop after N matched printings")
    args = ap.parse_args()

    ident = os.path.join(args.dir, "AllIdentifiers.json.gz")
    prices = os.path.join(args.dir, "AllPrices.json.gz")
    out = args.out or os.path.join(args.dir, "prices.db")

    for p in (ident, prices):
        if not os.path.exists(p):
            print(f"missing input: {p}", file=sys.stderr)
            return 1

    print("building uuid -> scryfallId map", flush=True)
    uuid_map = build_uuid_map(ident, limit=None if args.limit is None else args.limit * 4)
    print("slicing price history", flush=True)
    build_database(prices, uuid_map, out, limit=args.limit)
    print(f"wrote {out}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
