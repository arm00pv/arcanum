#!/usr/bin/env python3
"""Cut the committed Yu-Gi-Oh! id-parity sample out of live YGOPRODeck responses.

Design: docs/catalogue-server-side.md, sections 3 and 7. Yu-Gi-Oh! is the game
whose card ids are least like the provider's own: a passcode names a card, not a
printing, so the app synthesises each printing's id as

    <passcode>:<app set code>:<collector code slug>:<rarity slug>

from _printingId in lib/data/catalog/ygo_catalog.dart. Two of those four fields
are derived rather than forwarded - the collector code is slugged, and the set
code is the app's own because Konami publishes 1,035 sets under 646 distinct
codes and the app suffixes the repeats ("25lp2"). If the Python importer derives
any of them a character differently, every collection row naming such a printing
stops resolving and renders as "--".

So the sample has to hold real responses that exercise exactly those branches,
and the selection rule is written out rather than being a random slice, because
a sample that drifted with the provider would make the test fail for a reason
that has nothing to do with the code. It takes:

  * every entry of cardsets.php - all 1,035 sets - because the set-code
    assignment is a rule over the whole list: which of two sets sharing a code
    keeps the plain code depends on the dates and names of every member of its
    group. A cut set list would assign different codes and the sample would
    stop describing the catalogue that exists;

  * every card of Legend of Blue Eyes White Dragon, an ordinary retail set,
    whose printings come in region variants ("LOB-027", "LOB-E021",
    "LOB-EN027") that are one collector number and three different ids;

  * every card of the two colliding set-code groups with the fewest published
    sets, ties broken by code - the place the numeric suffix rule bites;

  * every card carrying a printing whose rarity is not plain words, capped at
    60 cards in passcode order: "Collector's Rare", "Ultra Rare (Pharaoh's
    Rare)", "Ghost/Gold Rare" are the slugs a naive lower-case gets wrong;

  * every card carrying a printing whose Konami code has no digits at the end
    ("SR03-ENTKN", "CRAR-EN10K", "MF03-EN0??"), which is where the collector
    number stops being the trailing digits of the code;

  * every card the provider gives no printing rows at all, capped at 20 cards
    in passcode order. Those are stored under their bare passcode, which is a
    branch of _printingId that no set download can reach.

Run it only when the sample genuinely needs re-cutting, and read the diff:
every change in it is a change in what the parity test asserts.

    python3 tool/catalog/make_yugioh_sample.py
"""

from __future__ import annotations

import gzip
import json
import os
import re
import sys
import time
import urllib.request

API = "https://db.ygoprodeck.com/api/v7"
UA = "Arcanum/1.0 (+https://github.com/arcanum)"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "yugioh_sample.json.gz")

# The ordinary retail set the sample takes whole, by the provider's own name.
ORDINARY_SET = "Legend of Blue Eyes White Dragon"

# Caps on the rule-driven subsets. A cap is written out rather than left to
# whatever the provider happens to publish, so re-running this script against
# the same data cuts the same sample.
MAX_PUNCTUATED_RARITY = 60
MAX_UNPLACED = 20
COLLIDING_GROUPS = 2


def get(url, timeout=180, retries=3):
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
            time.sleep(1.0 * (attempt + 1))
    raise RuntimeError(f"could not read {url}: {last}")


def provider_code(code):
    """The set a Konami code belongs to: "LOB-EN001" -> "LOB"."""
    trimmed = str(code or "").strip().upper()
    dash = trimmed.find("-")
    return trimmed[:dash] if dash > 0 else trimmed


def rows_of(card):
    rows = card.get("card_sets")
    return [r for r in rows if isinstance(r, dict)] if isinstance(rows, list) else []


def punctuated(card):
    """Whether a printing's rarity is not plain words, which the slug mangles."""
    return any(re.search(r"[^A-Za-z0-9 ]", str(r.get("set_rarity") or "").strip())
               for r in rows_of(card))


def code_without_digits(card):
    """Whether a Konami code does not end in digits."""
    for row in rows_of(card):
        code = str(row.get("set_code") or "").strip()
        if code and not re.search(r"\d+$", code):
            return True
    return False


def main():
    sets = get(f"{API}/cardsets.php")
    if not isinstance(sets, list) or not sets:
        raise SystemExit("YGOPRODeck listed no sets; refusing to write an empty sample")

    groups = {}
    for item in sets:
        if not isinstance(item, dict):
            continue
        name = str(item.get("set_name") or "").strip()
        if not name:
            continue
        code = str(item.get("set_code") or "").strip()
        groups.setdefault((code or name).upper(), []).append(name)

    # The colliding codes with the fewest members: the shortest of them is where
    # the suffix rule is cheapest to sample and where it is guaranteed to fire.
    colliding = sorted((len(names), code) for code, names in groups.items()
                       if len(names) > 1)
    chosen_codes = [code for _, code in colliding[:COLLIDING_GROUPS]]
    colliding_names = sorted({name for code in chosen_codes for name in groups[code]})
    print(f"  {len(sets)} sets, {len(groups)} distinct codes, "
          f"{sum(1 for names in groups.values() if len(names) > 1)} codes reused")
    print(f"  colliding groups sampled: "
          f"{', '.join(f'{code} x{len(groups[code])}' for code in chosen_codes)}")

    payload = get(f"{API}/cardinfo.php")
    cards = payload.get("data") if isinstance(payload, dict) else payload
    if not isinstance(cards, list) or not cards:
        raise SystemExit("cardinfo.php returned no card array")
    cards = [c for c in cards if isinstance(c, dict) and c.get("id") is not None]
    print(f"  {len(cards)} cards live")

    wanted = set()

    def take(selected, why):
        before = len(wanted)
        for card in selected:
            wanted.add(card["id"])
        print(f"  {len(wanted) - before:5} new, {len(wanted):5} cards chosen: {why}",
              flush=True)

    by_passcode = sorted(cards, key=lambda c: int(c["id"]))
    take([c for c in by_passcode
          if any(str(r.get("set_name") or "") == ORDINARY_SET for r in rows_of(c))],
         f"every card of {ORDINARY_SET}")
    take([c for c in by_passcode
          if any(str(r.get("set_name") or "") in colliding_names for r in rows_of(c))],
         "every card of the colliding set-code groups")
    take([c for c in by_passcode if punctuated(c)][:MAX_PUNCTUATED_RARITY],
         "cards with a punctuated rarity")
    take([c for c in by_passcode if code_without_digits(c)],
         "cards with a Konami code that does not end in digits")
    take([c for c in by_passcode if not rows_of(c)][:MAX_UNPLACED],
         "cards the provider gives no printing rows at all")

    chosen = [c for c in by_passcode if c["id"] in wanted]

    # The sets the sample can answer a cardinfo.php?cardset= query for: the ones
    # whose download the parity test actually drives. That is the ordinary set
    # and the colliding groups - everywhere else the test reaches the printings
    # through the card, which is the path the importer's own card_points mirrors.
    sampled_sets = [ORDINARY_SET] + colliding_names

    unplaced = sum(1 for c in chosen if not rows_of(c))
    punctuated_rows = sum(1 for c in chosen for r in rows_of(c)
                          if re.search(r"[^A-Za-z0-9 ]",
                                       str(r.get("set_rarity") or "").strip()))
    rows = sum(len(rows_of(c)) for c in chosen)

    payload = {
        "source": API,
        "cut_by": "tool/catalog/make_yugioh_sample.py",
        "why": "the Yu-Gi-Oh! id-parity sample; see the module docstring",
        "sets": sets,
        "sampled_sets": sampled_sets,
        "cards": chosen,
    }
    blob = json.dumps(payload, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":")).encode("utf-8")
    # mtime=0 so the committed file is byte-identical for the same input: a
    # fixture whose bytes move for no reason makes every diff a lie.
    with gzip.GzipFile(OUT, "wb", mtime=0) as fh:
        fh.write(blob)

    print()
    print(f"{len(chosen)} cards, {rows} printing rows, {len(sets)} sets, "
          f"{len(sampled_sets)} set downloads sampled")
    print(f"  {punctuated_rows} rows carry a punctuated rarity, "
          f"{unplaced} cards carry no printing rows at all")
    print(f"raw {len(blob) / 1024:.0f} KiB, gzipped {os.path.getsize(OUT) / 1024:.0f} KiB")
    print(f"  {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
