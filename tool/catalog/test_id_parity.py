#!/usr/bin/env python3
"""The importer half of the id-parity test.

Design: docs/catalogue-server-side.md, sections 7 and 8. The Dart half lives in
test/catalog/catalog_id_parity_test.dart and runs the real LorcanaCatalog over a
committed sample of 440 real Lorcast responses. This runs the importer owner's own
functions - the same card_document() and set_document() the nightly import uses,
imported rather than copied - over the same sample, and compares both against the
same committed file:

    tool/catalog/catalog_id_vectors.json.gz

Neither language is the authority. Both are asserted against that file, which was
generated from the Dart and is reviewed as a diff, so a change on either side
fails a test rather than quietly moving the goalposts.

Why this is worth an offline test of its own rather than a line in the proof
script: the failure it catches is silent. A card id that the importer derives a
character differently does not raise. The row is written, the collection row
still names the old id, and that collector's holding renders as "--" for ever. It
is the one failure in this design that no log would show.

Exits 0 only if nothing failed.

    python3 tool/catalog/test_id_parity.py
    python3 tool/catalog/test_id_parity.py --verbose
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.dirname(HERE)
SAMPLE = os.path.join(HERE, "lorcana_sample.json.gz")
VECTORS = os.path.join(HERE, "catalog_id_vectors.json.gz")

# The importer lives one directory up, beside the pollers it is shared with, so
# it is imported rather than reimplemented. Importing the module also imports
# catalog_store, which is the point: this asserts the code that actually runs.
sys.path.insert(0, TOOL)
import poll_lorcana_prices as lorcast  # noqa: E402

RESULTS = []


def record(status, name, detail):
    RESULTS.append((status, name, detail))
    print(f"{status:<4}  {name}")
    for line in detail.splitlines():
        print(f"        {line}")


def ok(name, detail):
    record("PASS", name, detail)


def bad(name, detail):
    record("FAIL", name, detail)


def read_gzip(path):
    with gzip.open(path, "rb") as fh:
        return json.loads(fh.read().decode("utf-8"))


def same(a, b):
    """Structural equality over decoded JSON.

    Numbers compare numerically: JSON has one number type and the two languages
    may hold 3 as an int or as a double, which is not a disagreement about the
    card.
    """
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return a == b
    if isinstance(a, dict) and isinstance(b, dict):
        if set(a) != set(b):
            return False
        return all(same(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    return a == b


def field_diffs(mine, theirs, limit=4):
    """The fields on which two rows disagree, named rather than described."""
    out = []
    for key in sorted(set(mine) | set(theirs)):
        if not same(mine.get(key), theirs.get(key)):
            out.append(f"{key}: importer {mine.get(key)!r} != client {theirs.get(key)!r}")
        if len(out) >= limit:
            break
    return out


def compare(label, mine, theirs, verbose):
    """Compares one map of rows against the committed vectors, keyed alike."""
    problems = []
    missing = sorted(set(mine) - set(theirs))
    extra = sorted(set(theirs) - set(mine))
    if missing:
        problems.append(f"{len(missing)} rows the importer derives are not in the "
                        f"committed file, e.g. {missing[:3]}")
    if extra:
        problems.append(f"{len(extra)} rows in the committed file the importer no "
                        f"longer derives, e.g. {extra[:3]}")
    differing = 0
    for key in sorted(set(mine) & set(theirs)):
        if not same(mine[key], theirs[key]):
            differing += 1
            if differing <= 5:
                problems.append(f"{key}: " + "; ".join(
                    field_diffs(mine[key], theirs[key])))
    detail = (f"{len(mine)} rows compared against the committed vectors")
    if problems:
        if differing > 5:
            problems.append(f"... and {differing - 5} more rows differ")
        bad(label, detail + "\n" + "\n".join(problems))
        return False
    ok(label, detail + (f"; all {len(mine)} identical" if verbose else ""))
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    for path in (SAMPLE, VECTORS):
        if not os.path.exists(path):
            print(f"missing {path}", file=sys.stderr)
            return 2

    sample = read_gzip(SAMPLE)
    committed = read_gzip(VECTORS)
    cards = [c for c in sample["cards"] if isinstance(c, dict)]
    sets = [s for s in sample["sets"] if isinstance(s, dict)]

    print(f"--- {len(cards)} sampled cards, {len(sets)} sets ---")
    print()

    # ---- cards
    mine_cards = {}
    skipped = 0
    for card in cards:
        set_map = card.get("set") if isinstance(card.get("set"), dict) else {}
        fallback = (lorcast.dart_string(set_map.get("code")) or "").lower()
        row = lorcast.card_document(card, fallback)
        if row is None:
            skipped += 1
            continue
        mine_cards[row["id"]] = row
    theirs_cards = {row["id"]: row for row in committed["cards"]}
    compare("importer_derives_the_clients_card_rows", mine_cards, theirs_cards,
            args.verbose)

    # ---- sets
    mine_sets = {}
    for item in sets:
        row = lorcast.set_document(item)
        if row is not None:
            mine_sets[row["code"]] = row
    theirs_sets = {row["code"]: row for row in committed["sets"]}
    compare("importer_derives_the_clients_set_rows", mine_sets, theirs_sets,
            args.verbose)

    # ---- the properties a row-by-row comparison cannot state
    ids = [row["id"] for row in cards]
    provider_ids = {c["id"] for c in cards if isinstance(c.get("id"), str)}
    if {row["id"] for row in mine_cards.values()} == provider_ids:
        ok("every_id_is_the_providers_own",
           f"{len(provider_ids)} ids forwarded verbatim, none synthesised")
    else:
        bad("every_id_is_the_providers_own",
            "the importer invented or dropped an id")

    if skipped == 0 and len(ids) == len(provider_ids):
        ok("no_card_was_dropped", f"all {len(ids)} sampled cards produced a row")
    else:
        bad("no_card_was_dropped",
            f"{skipped} card(s) produced no row, {len(ids)} cards for "
            f"{len(provider_ids)} distinct ids")

    # The one field a transcription is likeliest to get wrong, because it is the
    # one field the provider publishes and the client deliberately does not use.
    layouts = {row["layout"] for row in mine_cards.values()}
    if layouts == {""}:
        ok("layout_is_the_clients_empty_string",
           "the payload carries a layout and the client stores an empty one; the "
           "importer follows the client")
    else:
        bad("layout_is_the_clients_empty_string",
            f"layouts stored: {sorted(layouts)}")

    failed = sum(1 for status, _, _ in RESULTS if status == "FAIL")
    passed = sum(1 for status, _, _ in RESULTS if status == "PASS")
    print()
    print(f"{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
