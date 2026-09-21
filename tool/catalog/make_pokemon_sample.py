#!/usr/bin/env python3
"""Cut the committed Pokemon id-parity sample out of live TCGdex responses.

Design: docs/catalogue-server-side.md, sections 3 and 7. Pokemon is the game
whose *derived* values are the ones worth pinning, even though its card ids are
forwarded: TcgCard.normaliseName fills oracle_id, TcgCard.collectorNumberSortKey
orders a shelf whose numbers are "TG01", "SV001", "H01" and "50a" in one set, and
the rarity falls back to "unknown" when the provider publishes none. Those are
the rules docs/catalogue-server-side.md names as existing in two languages, and
the Python importer has to reproduce them character for character.

So the sample has to hold real responses that exercise exactly those branches,
and the selection rule is written out rather than being a random slice, because
a sample that drifted with the provider would make the test fail for a reason
that has nothing to do with the code. It takes:

  * every entry of /sets for the sets below, so a set-level rule is covered too;
  * every card of Base Set - an ordinary retail set whose collector numbers are
    the plain integers every other shape is a deviation from;
  * every card of Brilliant Stars Trainer Gallery, where the collector numbers
    are "TG01".."TG30", and of Shining Fates Shiny Vault, where they are
    "SV001".."SV122". Both are the prefix branch of the sort key, with one and
    with three digits;
  * every card of Unseen Forces Unown Collection, whose collector numbers are
    not numbers at all - "!", "%3F", "A";
  * every card of Miscellaneous Promos, the one-card promo set, which is the
    smallest thing the client can be asked to download;
  * every card of any other set whose collector number is not a plain integer,
    capped at 40 cards in (set id, collector number) order: "H01", "50a", "ONE"
    are the shapes a real set mixes in among its integers.

The sample stores the provider's own /sets/{id} responses as well as the card
details, because the client asks for both and the set response is where the
collector number of a card that has no detail yet comes from.

Run it only when the sample genuinely needs re-cutting, and read the diff:
every change in it is a change in what the parity test asserts.

    python3 tool/catalog/make_pokemon_sample.py
"""

from __future__ import annotations

import concurrent.futures
import gzip
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

API = "https://api.tcgdex.net/v2/en"
UA = "Arcanum/1.0 (+https://github.com/arcanum)"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "pokemon_sample.json.gz")

# The sets taken whole, by the provider's own set id. Each one is here for the
# reason the module docstring gives, and no other set is taken whole.
WHOLE_SETS = ("base1", "swsh9tg", "swsh4.5sv", "exu", "miscp")

# Caps on the rule-driven subsets, written out so re-running this script against
# the same data cuts the same sample.
MAX_ODD_NUMBERS = 40
CONCURRENCY = 8


def get(url, timeout=60, retries=3):
    """GETs a URL and decodes JSON, retrying transient failures."""
    last = None
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": UA, "Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except Exception as exc:  # noqa: BLE001 - retried, then raised
            last = exc
            time.sleep(0.5 * (attempt + 1))
    raise RuntimeError(f"could not read {url}: {last}")


def card_url(card_id):
    """The card endpoint for an id, escaped the way the provider's own ids need.

    TCGdex publishes a collector number of "%3F" as the id "exu-%3F", which only
    addresses as a path segment when the percent sign is escaped again.
    """
    return f"{API}/cards/{urllib.parse.quote(card_id, safe='')}"


def plain_number(value):
    """Whether a collector number is the plain integer every other shape deviates from."""
    return re.fullmatch(r"[0-9]+", str(value or "")) is not None


def main():
    listed = get(f"{API}/sets")
    if not isinstance(listed, list) or not listed:
        raise SystemExit("TCGdex listed no sets; refusing to write an empty sample")
    by_id = {s["id"]: s for s in listed if isinstance(s, dict) and s.get("id")}
    missing = [s for s in WHOLE_SETS if s not in by_id]
    if missing:
        raise SystemExit(f"TCGdex no longer publishes {missing}")

    def detail(set_id):
        return get(f"{API}/sets/{set_id}")

    chosen_sets = list(WHOLE_SETS)
    with concurrent.futures.ThreadPoolExecutor(CONCURRENCY) as pool:
        details = dict(zip(chosen_sets, pool.map(detail, chosen_sets)))
    print(f"  {len(listed)} sets live; taking {len(chosen_sets)} whole: "
          f"{', '.join(chosen_sets)}", flush=True)

    # Every card of the whole sets, plus the odd collector numbers elsewhere.
    wanted = {}
    for set_id in chosen_sets:
        for stub in details[set_id].get("cards") or []:
            if isinstance(stub, dict) and stub.get("id"):
                wanted[stub["id"]] = set_id

    others = [s["id"] for s in listed
              if isinstance(s, dict) and s.get("id") and s["id"] not in WHOLE_SETS]
    with concurrent.futures.ThreadPoolExecutor(CONCURRENCY) as pool:
        other_details = list(pool.map(detail, others))
    odd = []
    for set_id, body in zip(others, other_details):
        for stub in body.get("cards") or []:
            if not isinstance(stub, dict) or not stub.get("id"):
                continue
            if plain_number(stub.get("localId")):
                continue
            odd.append((set_id, str(stub.get("localId")), stub["id"]))
    odd.sort()
    for _, _, card_id in odd[:MAX_ODD_NUMBERS]:
        wanted.setdefault(card_id, "odd")
    print(f"  {len(wanted)} cards chosen ({len(odd)} odd collector numbers live, "
          f"{min(len(odd), MAX_ODD_NUMBERS)} of them taken)", flush=True)

    ids = sorted(wanted)
    with concurrent.futures.ThreadPoolExecutor(CONCURRENCY) as pool:
        cards = list(pool.map(lambda i: get(card_url(i)), ids))

    # The /sets/{id} responses the client asks for: the whole sets, and whichever
    # other set an odd-numbered card came from, because a set download enriches
    # every set it lists.
    sampled = list(dict.fromkeys(chosen_sets + [wanted[i] for i in ids
                                                if wanted[i] != "odd"]))
    extra = [s for s in sampled if s not in details]
    if extra:
        with concurrent.futures.ThreadPoolExecutor(CONCURRENCY) as pool:
            details.update(dict(zip(extra, pool.map(detail, extra))))

    priced = sum(1 for c in cards if isinstance(c.get("pricing"), dict))
    categories = sorted({str(c.get("category") or "") for c in cards})
    odd_numbers = sorted({str(c.get("localId")) for c in cards
                          if not plain_number(c.get("localId"))})

    payload = {
        "source": API,
        "cut_by": "tool/catalog/make_pokemon_sample.py",
        "why": "the Pokemon id-parity sample; see the module docstring",
        "sets": [by_id[s] for s in sampled],
        "details": {s: details[s] for s in sampled},
        "cards": sorted(cards, key=lambda c: str(c.get("id") or "")),
    }
    blob = json.dumps(payload, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":")).encode("utf-8")
    # mtime=0 so the committed file is byte-identical for the same input: a
    # fixture whose bytes move for no reason makes every diff a lie.
    with gzip.GzipFile(OUT, "wb", mtime=0) as fh:
        fh.write(blob)

    print()
    print(f"{len(cards)} cards, {len(sampled)} sets, {len(odd_numbers)} distinct "
          f"non-integer collector numbers")
    print(f"  {priced} cards carry a pricing block; categories: {categories}")
    print(f"  e.g. {odd_numbers[:8]}")
    print(f"raw {len(blob) / 1024:.0f} KiB, gzipped {os.path.getsize(OUT) / 1024:.0f} KiB")
    print(f"  {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
