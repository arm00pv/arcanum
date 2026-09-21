#!/usr/bin/env python3
"""Cut the committed Gundam id-parity sample out of live gcgapi responses.

Design: docs/catalogue-server-side.md, sections 3 and 7. Gundam is the game whose
ids are forwarded *and* whose printed numbers repeat, which is the shape the
parity test has not seen before: Lorcana and Pokemon forward an id that is unique
by construction, and Yu-Gi-Oh! synthesises one. Here five products - GD01-005 and
its four alternate arts - share one printed number, so an id derived from the
number would silently collapse five holdings into one, and the sample has to hold
such a cluster or the test proves nothing about it.

So the sample has to hold real responses that exercise exactly those branches, and
the selection rule is written out rather than being a random slice, because a
sample that drifted with the provider would make the test fail for a reason that
has nothing to do with the code. It takes every entry of /sets - the whole set
list, so a set-level rule is covered too - and every product of these sets:

  * GD01, "Newtype Rising", the largest set at 254 products. It is the only set
    bigger than the provider's 250-row page cap, so it is the one that proves the
    client and the importer page a set the same way and in the same order;
  * EB01, "Eternal Nexus", an extra booster whose cards are printed in many
    alternate arts - the cluster above is in GD01, but EB01 is where the density
    of them is;
  * SC01, "Deck Build Box Freedom Ascension", which files 51 products and not one
    of them has a number beginning SC01: the deck box reprints cards whose numbers
    belong to other sets. A card's set is the set it is filed under and not the
    set its number names, and this is the set that says so;
  * ST01, a starter deck, and RP, a promotional run, which are the two set types
    the importer derives from the code and the name rather than reading off a
    flag;
  * T, the 15-product trial run, and EXB, "Basic Cards", which holds two products
    and is the smallest thing a client can be asked to download.

Run it only when the sample genuinely needs re-cutting, and read the diff: every
change in it is a change in what the parity test asserts.

    python3 tool/catalog/make_gundam_sample.py
"""

from __future__ import annotations

import concurrent.futures
import gzip
import json
import os
import sys
import time
import urllib.error
import urllib.request

API = "https://api.gcgapi.com/v1"
UA = "Arcanum/1.0 (+https://github.com/arm00pv/arcanum)"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "gundam_sample.json.gz")

# The sets taken whole, by the provider's own code. Each one is here for the
# reason the module docstring gives, and no other set is taken whole.
WHOLE_SETS = ("GD01", "EB01", "SC01", "ST01", "RP", "T", "EXB")

# The provider's own page cap, which is why GD01 is read in two requests.
PAGE_SIZE = 250
CONCURRENCY = 7


def get(url, timeout=60, retries=3):
    """GETs a URL and decodes JSON, retrying transient failures."""
    last = None
    for attempt in range(retries + 1):
        try:
            request = urllib.request.Request(
                url, headers={"User-Agent": UA, "Accept": "application/json"})
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return json.loads(response.read().decode("utf-8") or "null")
        except Exception as exc:  # noqa: BLE001 - retried, then raised
            last = exc
            time.sleep(0.5 * (attempt + 1))
    raise RuntimeError("could not read %s: %s" % (url, last))


def rows_of(body):
    """The 'data' array a gcgapi route answers with."""
    if isinstance(body, dict) and isinstance(body.get("data"), list):
        return body["data"]
    if isinstance(body, list):
        return body
    return []


def set_cards(set_code):
    """Every product of one set, paged the way the client and the importer page it."""
    out = []
    offset = 0
    total = 0
    while True:
        body = get("%s/cards?set_code=%s&limit=%d&offset=%d"
                   % (API, set_code, PAGE_SIZE, offset))
        rows = rows_of(body)
        if isinstance(body, dict) and isinstance(body.get("_meta"), dict):
            total = body["_meta"].get("total") or total
        out.extend(row for row in rows if isinstance(row, dict))
        offset += PAGE_SIZE
        if len(rows) < PAGE_SIZE:
            break
        if total and offset >= total:
            break
    return out


def main():
    listed = get(API + "/sets")
    sets = rows_of(listed)
    if not sets:
        raise SystemExit("gcgapi listed no sets; refusing to write an empty sample")
    by_code = {s["set_code"]: s for s in sets if isinstance(s.get("set_code"), str)}
    missing = [code for code in WHOLE_SETS if code not in by_code]
    if missing:
        raise SystemExit("gcgapi no longer publishes %s" % missing)

    print("  %d sets live; taking %d whole: %s"
          % (len(sets), len(WHOLE_SETS), ", ".join(WHOLE_SETS)), flush=True)
    with concurrent.futures.ThreadPoolExecutor(CONCURRENCY) as pool:
        fetched = dict(zip(WHOLE_SETS, pool.map(set_cards, WHOLE_SETS)))

    cards = []
    for code in WHOLE_SETS:
        cards.extend(fetched[code])
    cards.sort(key=lambda c: str(c.get("product_id") or ""))

    # A summary of what the sample can prove, printed rather than assumed: the
    # numbers below are the branches the test is relying on this sample to hold.
    numbers = {}
    for card in cards:
        numbers.setdefault(card.get("card_number"), []).append(card["product_id"])
    clusters = {n: ids for n, ids in numbers.items() if len(ids) > 1}
    elsewhere = [c for c in cards
                 if not str(c.get("card_number") or "").startswith(
                     str(c.get("set_code") or "") + "-")]
    pages = [code for code in WHOLE_SETS if len(fetched[code]) > PAGE_SIZE]

    payload = {
        "source": API,
        "cut_by": "tool/catalog/make_gundam_sample.py",
        "why": "the Gundam id-parity sample; see the module docstring",
        "sets": sets,
        "sampled_sets": list(WHOLE_SETS),
        "cards": cards,
    }
    blob = json.dumps(payload, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":")).encode("utf-8")
    # mtime=0 so the committed file is byte-identical for the same input: a
    # fixture whose bytes move for no reason makes every diff a lie.
    with gzip.GzipFile(OUT, "wb", mtime=0) as fh:
        fh.write(blob)

    print()
    print("%d cards, %d sets, %d products sharing a printed number"
          % (len(cards), len(sets), sum(len(v) - 1 for v in clusters.values())))
    print("  %d card(s) are filed in a set their number does not name, e.g. %s"
          % (len(elsewhere),
             ", ".join("%s in %s" % (c["product_id"], c["set_code"])
                       for c in elsewhere[:3])))
    print("  sets read in more than one page: %s" % (", ".join(pages) or "none"))
    print("  largest clusters: %s"
          % ", ".join("%s x%d" % (n, len(ids))
                      for n, ids in sorted(clusters.items(),
                                           key=lambda kv: -len(kv[1]))[:4]))
    print("raw %.0f KiB, gzipped %.0f KiB" % (len(blob) / 1024,
                                              os.path.getsize(OUT) / 1024))
    print("  %s" % OUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
