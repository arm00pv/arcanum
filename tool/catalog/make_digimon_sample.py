#!/usr/bin/env python3
'''Cut the committed Digimon sample: real Heroicc answers, kept verbatim.

Why a sample at all. The server importer and the Dart client must derive the same
catalogue rows from the same provider response, and the only way to prove that is
to run both over one frozen set of answers. The importer reads this file, the
client is driven over it through a fake transport in
test/catalog/catalog_id_parity_test.dart, and both are asserted against the
vectors that file writes. See docs/catalogue-server-side.md.

What is kept is what the source said: whole envelopes, not projected records. A
card envelope carries its own relationships and its own included list - the
release it is filed under and the printings it is one of - and those are exactly
what the client reads to decide a row's set code, so a sample that kept only the
attributes would be a sample that cannot answer the question it is here to answer.

    python3 tool/catalog/make_digimon_sample.py

The sets are whole because a set download is one request plus one per card, and
they are chosen for the shapes a row can take: an expansion with alternate arts
(bt-05), a second expansion that files a card printed by the first (bt-08, which
holds BT5-007_P3), a starter deck (st-01), and two undated promotional runs - one
whose cards are parallel prints filed under the promotion (other-promos), and the
game's biggest one (p), which carries the promotion's own numbered run (P-005,
P-191, P-244) and one card, P-058, that another release lists as well.

One shape is deliberately *not* here, and the proof says so instead: the 77 cards
the source files under no release at all are not in any release, so no set
walk - and therefore no import - can reach them. The fallback that files such a
card under the prefix of its printed number is asserted against a search answer,
in tool/catalog/prove_digimon_import.py.

The fixture is written with mtime 0 and sorted keys, so re-running it over
unchanged data leaves the committed bytes alone and a diff means a real change.
'''

from __future__ import annotations

import concurrent.futures
import gzip
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.heroi.cc"
UA = "Arcanum/1.0 (+https://github.com/arm00pv/arcanum)"
ACCEPT = "application/vnd.api+json, application/json"

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "digimon_sample.json.gz")

# Whole releases. bt-05 and bt-08 file each other's cards, st-01 is a starter,
# other-promos is the undated run - see the module docstring.
WHOLE_SETS = ("bt-05", "bt-08", "st-01", "other-promos", "p")

# Two searches: a collector number, which is how a row is found from a paste, and
# a name, which answers a full page the way the source pages it.
SEARCHES = ("BT5-007", "agumon")

WORKERS = 4
TIMEOUT = 90
RETRIES = 3
# The source is one hobbyist's server: it asks to be identified, asks that
# responses be cached, and publishes no rate limit. Four requests in flight with
# a pause behind each is a walk rather than a flood.
GAP = 0.05

_lock = threading.Lock()


def get(url, timeout=TIMEOUT, retries=RETRIES):
    '''One read of the source, retried, as the bytes it answered.'''
    last = None
    for attempt in range(retries + 1):
        request = urllib.request.Request(
            url, headers={"Accept": ACCEPT, "User-Agent": UA}
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as answer:
                return answer.read()
        except Exception as problem:  # noqa: BLE001 - retried, then reported
            last = problem
        time.sleep(0.5 * (attempt + 1))
    raise RuntimeError("could not read %s: %s" % (url, last))


def get_json(url):
    return json.loads(get(url).decode("utf-8", "replace"))


def set_list():
    return get_json(API + "/releases/en")


def entries_of(envelope):
    included = envelope.get("included")
    return included if isinstance(included, list) else []


def slug_of(item):
    value = item.get("id") if isinstance(item, dict) else None
    if not isinstance(value, str) or not value.startswith("/releases/en/"):
        return None
    slug = value[len("/releases/en/") :]
    return slug or None


def card_ids_of(release):
    ids = []
    for item in entries_of(release):
        value = item.get("id") if isinstance(item, dict) else None
        if isinstance(value, str) and value.startswith("/cards/en/"):
            ids.append(value[len("/cards/en/") :])
    return ids


def card(id_):
    '''One card envelope, fetched and then reported, so a failure names the id.'''
    try:
        return id_, get_json(API + "/cards/en/" + id_)
    except Exception as problem:  # noqa: BLE001 - reported by the caller
        raise RuntimeError("card %s could not be read: %s" % (id_, problem))
    finally:
        time.sleep(GAP)


def fetch_cards(ids):
    found = {}
    with concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
        for id_, envelope in pool.map(card, ids):
            found[id_] = envelope
            with _lock:
                print("    %-16s %d" % (id_, len(found)), end="\r", flush=True)
    print(" " * 40, end="\r")
    return found


def fold(value):
    '''The app's own code form: lower case, with everything that is not a letter
    or a digit gone - so 'bt-05' and a card printed 'BT5-001' compare equal.'''
    return "".join(character for character in str(value).lower() if character.isalnum())


def releases_of(envelope):
    data = envelope.get("data") if isinstance(envelope, dict) else None
    attributes = data.get("attributes") if isinstance(data, dict) else None
    release = None
    for item in entries_of(envelope):
        if isinstance(item, dict) and item.get("type") == "release":
            release = slug_of(item)
    number = None
    if isinstance(attributes, dict):
        value = attributes.get("number")
        number = value if isinstance(value, str) else None
    return release, attributes, number


def main():
    listing = set_list()
    listed = {}
    for item in entries_of(listing):
        slug = slug_of(item)
        if slug is not None:
            listed[slug] = item
    if not listed:
        raise SystemExit("the source listed no releases; refusing to write an empty sample")
    print("  %d release(s) live; taking %d whole: %s"
          % (len(listed), len(WHOLE_SETS), ", ".join(WHOLE_SETS)))

    for slug in WHOLE_SETS:
        if slug not in listed:
            raise SystemExit(
                "the source no longer lists %s; the sample is not written smaller silently"
                % slug
            )

    source_order = [slug for slug in (slug_of(item) for item in entries_of(listing))
                    if slug is not None]
    sampled = set(WHOLE_SETS)
    releases = {}
    cards = {}
    report = []
    for slug in WHOLE_SETS:
        envelope = get_json(API + "/releases/en/" + slug)
        ids = card_ids_of(envelope)
        expected = (listed[slug].get("meta") or {}).get("cards")
        if not ids:
            raise SystemExit("release %s answered no cards; refusing to write a short sample" % slug)
        if expected is not None and len(ids) != expected:
            raise SystemExit(
                "release %s answered %d cards where its own set list counts %s, so the "
                "walk did not finish; refusing to write a short sample" % (slug, len(ids), expected)
            )
        print("  %-14s %4d card(s)" % (slug, len(ids)))
        releases[slug] = envelope
        found = fetch_cards(ids)
        cards.update(found)
        report.append((slug, ids))

    searches = {}
    for term in SEARCHES:
        envelope = get_json(API + "/search?q=" + urllib.parse.quote(term))
        rows = envelope.get("data")
        searches[term] = envelope
        print("  search %-10s %4d row(s)" % (term, len(rows) if isinstance(rows, list) else 0))

    if not cards:
        raise SystemExit("the sets above answered no cards; refusing to write an empty sample")

    payload = {
        "source": API,
        "cut_by": "tool/catalog/make_digimon_sample.py",
        "why": "the Digimon id-parity sample; see the module docstring",
        "sets": listing,
        # In the source's own listing order, which is not the order they are fetched
        # in and matters: a card listed by two sampled releases is written twice by
        # the importer and by both drivers, and the row that survives is the last
        # one written. Ordering all three the way the source lists them is what
        # makes that the same row everywhere.
        "sampled_sets": [slug for slug in source_order if slug in sampled],
        "releases": releases,
        "cards": cards,
        "searches": searches,
    }
    blob = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    with gzip.GzipFile(OUT, "wb", mtime=0) as handle:
        handle.write(blob)

    parallels = [id_ for id_ in cards if "_" in id_]
    released = 0
    unreleased = 0
    listed_twice = 0
    cross = 0
    for id_ in cards:
        release, _, number = releases_of(cards[id_])
        if release is None:
            unreleased += 1
            continue
        released += 1
        # The release a card is filed under against the set that printed it, which
        # are different facts: bt-08 lists BT5-007_P3 and bt-05 lists BT2-028_P1.
        prefix = fold((number or "").split("-")[0])
        if prefix and not fold(release).startswith(prefix):
            cross += 1
    seen = {}
    for slug, ids in report:
        for id_ in ids:
            seen[id_] = seen.get(id_, 0) + 1
    listed_twice = sum(1 for count in seen.values() if count > 1)
    print("")
    print("%d card(s) across %d release(s): %d parallel(s), %d filed under a release, "
          "%d filed under none" % (len(cards), len(report), len(parallels), released, unreleased))
    print("  %d card(s) printed by the release that filed them, %d printed elsewhere"
          % (released - cross, cross))
    print("  %d card(s) are listed by two of the sampled releases, so the row that "
          "survives is the last written" % listed_twice)
    print("  %d distinct base id(s) behind those %d card(s)"
          % (len({id_.split("_")[0] for id_ in cards}), len(cards)))
    print("raw %.0f KiB, gzipped %.0f KiB" % (len(blob) / 1024.0, os.path.getsize(OUT) / 1024.0))
    print("  %s" % OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
