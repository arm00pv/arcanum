#!/usr/bin/env python3
"""Cut the committed id-parity sample out of live Lorcast responses.

Design: docs/catalogue-server-side.md, sections 7 and 8. The importer and the
Dart client both turn a Lorcast card object into a stored row, and if they
disagree about any derived value - the id, the composed name, the oracle id,
the rarity spelling, the collector sort key - a collection row stops resolving
and renders as "--". The test that catches that has to run offline, against
real data, so this cuts a sample of real responses into
tool/catalog/lorcana_sample.json.gz and commits it.

The selection rule is written out rather than being a random slice, because a
sample that drifted with the provider would make the test fail for a reason
that has nothing to do with the code. It takes:

  * every set object, so a set-level rule is covered too;
  * every card of every set whose code is not a plain integer - the promo runs
    and the one-off sets, which are where the awkward shapes live;
  * every card of The First Chapter, an ordinary retail set, so the common
    case is represented and not only the oddities;
  * every card anywhere that carries a shape the derivation has to get right:
    a quoted subtitle, a collector number that is not a plain integer, or no
    tcgplayer_id at all (which is what decides between JPEG and AVIF art).

Run it only when the sample genuinely needs re-cutting, and read the diff:
every change in it is a change in what the parity test asserts.

    python3 tool/catalog/make_lorcana_sample.py
"""

from __future__ import annotations

import gzip
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

API = "https://api.lorcast.com/v0"
UA = "Arcanum/1.0 (+https://github.com/arcanum)"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "lorcana_sample.json.gz")


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


def awkward(card):
    """Whether a card carries a shape the row derivation has to get right."""
    if str(card.get("version", "")).startswith(chr(34)):
        return True
    number = str(card.get("collector_number", ""))
    if not re.fullmatch(r"[0-9]+", number):
        return True
    return not card.get("tcgplayer_id")


def main():
    sets = get(f"{API}/sets")
    results = sets.get("results") if isinstance(sets, dict) else sets
    if not results:
        raise SystemExit("Lorcast listed no sets; refusing to write an empty sample")

    chosen, total = [], 0
    for item in results:
        code = item.get("code")
        if not isinstance(code, str) or not code.strip():
            continue
        cards = get(f"{API}/sets/{urllib.parse.quote(code, safe=chr(39))}/cards")
        if not isinstance(cards, list):
            raise SystemExit(f"expected a card array for {code!r}")
        cards = [c for c in cards if isinstance(c, dict)]
        total += len(cards)
        take_all = not re.fullmatch(r"[0-9]+", code) or code == "1"
        for card in cards:
            if take_all or awkward(card):
                chosen.append(card)
        print(f"  {code!r:10} {len(cards):4} cards, {len(chosen):5} chosen so far",
              flush=True)
        time.sleep(0.3)

    seen, unique = set(), []
    for card in chosen:
        cid = card.get("id")
        if not isinstance(cid, str) or cid in seen:
            continue
        seen.add(cid)
        unique.append(card)
    unique.sort(key=lambda c: (str(c.get("set", {}).get("code", "")), c["id"]))

    payload = {
        "source": API,
        "cut_by": "tool/catalog/make_lorcana_sample.py",
        "why": "the id-parity and fold samples; see the module docstring",
        "sets": results,
        "cards": unique,
    }
    blob = json.dumps(payload, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":")).encode("utf-8")
    # mtime=0 so the committed file is byte-identical for the same input: a
    # fixture whose bytes move for no reason makes every diff a lie.
    with gzip.GzipFile(OUT, "wb", mtime=0) as fh:
        fh.write(blob)

    print()
    print(f"{len(results)} sets, {total} cards live, {len(unique)} sampled")
    print(f"raw {len(blob) / 1024:.0f} KiB, gzipped {os.path.getsize(OUT) / 1024:.0f} KiB")
    print(f"  {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())