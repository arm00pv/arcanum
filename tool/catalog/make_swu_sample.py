#!/usr/bin/env python3
"""Cut the committed Star Wars: Unlimited id-parity sample out of live FFG responses.

Design: docs/catalogue-server-side.md, sections 3 and 7, and
docs/catalogue-import-swu.md, which is the file that measured this source. Star
Wars: Unlimited is the game whose answers are Strapi envelopes: every relation -
the expansion, the type, the rarity, the three art objects, and the base card a
treatment points at with `variantOf` - arrives as `{data: {id, attributes}}` or
`{data: [...]}`, and nothing about a record is flat. Both readers have to unwrap
that envelope the same way, and the sample is where the shape is pinned, so the
records are stored exactly as the source returns them: not flattened, not trimmed,
not re-spelled, relations and localizations and all.

What the envelope hides are the two derived values the test exists for. The id is
the publisher's `cardUid`, forwarded verbatim - `cardId` is null on most records
and names a related card where it is set, and `validationId` repeats, so neither of
those is an id at all. The collector number is the *base* card's: a treatment
carries a `cardNumber` of its own that counts something other than the card
(hyperspace Luke is 1 where Luke is 5), so a record that points at a base takes the
base's number out of the embed, which is the number printed on the card and the
number a binder slot is made of.

A treatment's own name is not the marker of a treatment either. `variantTypes` is
stated on base printings too - all 254 of Spark of Rebellion's bases carry
`Standard`, and C24's six promos carry `Convention Exclusive` - and not one of
those rows points at a base, so what makes a record a treatment is `variantOf` and
nothing else, while the foil and promo flags are read from the names.

So the sample has to hold real responses that exercise exactly those branches, and
the selection rule is written out rather than being a random slice, because a
sample that drifted with the publisher would make the test fail for a reason that
has nothing to do with the code. It takes every entry of /card-expansions - the
whole set list, 27 sets, so that every branch of the set-type rule that the client
and the importer both read off a set's code and name is asserted: the convention,
judge, promo, Gamegenic and exclusive runs, the three Weekly Play runs named for
the set they belong to, Intro Battle: Hoth, and JTLP, whose code begins J and so is
answered by the code-prefix branch before the Weekly Play in its name is even
asked - and every record of these sets:

  * SOR, "Spark of Rebellion", 991 records over 4 pages. It is the only set here
    bigger than the source's 250-row page cap, so it is the one that proves the
    client and the importer page a set the same way and stop at the same row; and
    it holds every awkward card shape at once: 252 base printings of cards, 737
    treatments
    (Hyperspace, Standard Foil, Hyperspace Foil, Showcase, Weekly Play, Prerelease
    Promo and Judge, and the Store Showdown prizes), 4 token records, and the 88
    records whose front art is landscape - 56 leaders and 32 bases. The bases are
    the trap in that flag: a base is printed landscape and has no second face at
    all, so `artFrontHorizontal` is not a leader test, and a reader that takes it for
    one draws a base from an `artBack` that is not there, where a leader really does
    carry the deployed unit on its other side;

  * C24, "2024 Convention Exclusive", 6 records: the smallest thing a client can be
    asked to download, and a set whose every row is a promo - each of the six states
    the treatment "Convention Exclusive" and carries neither "Promo" nor "Judge" nor
    "Prize" in it, so the printing's promo flag is decided by the set's own type and
    by nothing on the record;

  * G25, "2025 Gift Box", 2 records: the smallest set the publisher lists.

Run it only when the sample genuinely needs re-cutting, and read the diff: every
change in it is a change in what the parity test asserts.

    python3 tool/catalog/make_swu_sample.py
"""

from __future__ import annotations

import concurrent.futures
import gzip
import json
import os
import time
import urllib.error
import urllib.request

API = "https://admin.starwarsunlimited.com/api"
UA = "Arcanum/1.0 (+https://github.com/arm00pv/arcanum)"

# The source answers a browser directly and echoes the Origin it was sent, so the
# sample is cut the way the app asks for it and not the way a bare curl does.
ORIGIN = "https://arcanum.example"

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "swu_sample.json.gz")

# The sets taken whole, by the publisher's own code. Each one is here for the
# reason the module docstring gives, and no other set is taken whole.
WHOLE_SETS = ("SOR", "C24", "G25")

# The publisher's own page cap, which is why SOR is read in four requests: 250 is
# the largest page it will answer, and asking for 1000 answers 250.
PAGE_SIZE = 250
CONCURRENCY = 3

# The card types that are not cards. They are listed beside the cards and dropped
# by both readers, so the sample has to hold them for the drop to be asserted
# rather than assumed.
TOKEN_TYPES = ("Token Upgrade", "Token Unit", "Credit Token", "Force Token")


def get(url, timeout=90, retries=3):
    """GETs a URL and decodes JSON, retrying transient failures."""
    last = None
    for attempt in range(retries + 1):
        try:
            request = urllib.request.Request(
                url, headers={"User-Agent": UA, "Accept": "application/json",
                              "Origin": ORIGIN})
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return json.loads(response.read().decode("utf-8") or "null")
        except Exception as exc:  # noqa: BLE001 - retried, then raised
            last = exc
            time.sleep(0.5 * (attempt + 1))
    raise RuntimeError("could not read %s: %s" % (url, last))


def rows_of(body):
    """The 'data' array a Strapi route answers with."""
    if isinstance(body, dict) and isinstance(body.get("data"), list):
        return body["data"]
    if isinstance(body, list):
        return body
    return []


def attributes_of(row):
    """The attributes of one Strapi record, or None where the row is not one."""
    if isinstance(row, dict) and isinstance(row.get("attributes"), dict):
        return row["attributes"]
    return None


def relation_of(attributes, key):
    """The attributes of the record a relation field points at, or None.

    Every relation in these answers is an envelope of its own - `{data: {id,
    attributes}}` - and an unset one is `{data: null}`, so a missing relation and
    an empty one both come back as None.
    """
    if not isinstance(attributes, dict):
        return None
    value = attributes.get(key)
    if not isinstance(value, dict):
        return None
    data = value.get("data")
    return data.get("attributes") if isinstance(data, dict) else None


def name_of(attributes):
    """The 'name' a record states, which is how a type, a rarity or a variant is spelled."""
    return (attributes or {}).get("name")


def set_code_of(row):
    """The expansion code one card record is filed under."""
    return (relation_of(attributes_of(row), "expansion") or {}).get("code")


def set_records(set_code):
    """Every record of one set, paged the way the client and the importer page it.

    Returns the records and the number the source's own pagination envelope counts
    for the set, which the caller checks them against: a page that came back short,
    or a 502 that outlived the retries, would otherwise write a smaller sample
    quietly.
    """
    out = []
    page = 1
    total = 0
    while True:
        body = get("%s/card-list?locale=en&pagination[pageSize]=%d&pagination[page]=%d"
                   "&filters[expansion][code][$eq]=%s"
                   % (API, PAGE_SIZE, page, set_code))
        rows = rows_of(body)
        if isinstance(body, dict) and isinstance(body.get("meta"), dict):
            pagination = body["meta"].get("pagination")
            if isinstance(pagination, dict):
                total = pagination.get("total") or total
        out.extend(row for row in rows if isinstance(row, dict))
        if len(rows) < PAGE_SIZE:
            break
        if total and len(out) >= total:
            break
        page += 1
    return out, total


def main():
    listed = get(API + "/card-expansions?locale=en&pagination[pageSize]=100")
    sets = rows_of(listed)
    if not sets:
        raise SystemExit("the card database listed no sets; refusing to write an empty sample")
    by_code = {attributes_of(s).get("code"): s for s in sets if attributes_of(s)}
    missing = [code for code in WHOLE_SETS if code not in by_code]
    if missing:
        raise SystemExit("the card database no longer lists %s; the sample is not "
                         "written smaller silently" % ", ".join(missing))

    print("  %d sets live; taking %d whole: %s"
          % (len(sets), len(WHOLE_SETS), ", ".join(WHOLE_SETS)), flush=True)
    with concurrent.futures.ThreadPoolExecutor(CONCURRENCY) as pool:
        fetched = dict(zip(WHOLE_SETS, pool.map(set_records, WHOLE_SETS)))

    cards = []
    for code in WHOLE_SETS:
        records, total = fetched[code]
        if total and len(records) != total:
            raise SystemExit("set %s answered %d records where its own envelope counts "
                             "%d, so the walk did not finish; refusing to write a short "
                             "sample" % (code, len(records), total))
        cards.extend(records)
    if not cards:
        raise SystemExit("the sets above answered no records; refusing to write an empty sample")

    # The source pages a set without stating an order, so the order the pages come
    # back in is not a contract: sorting by (set code, row id) makes the same rows
    # write the same bytes however the walk was laid out.
    cards.sort(key=lambda row: (str(set_code_of(row) or ""), row.get("id") or 0))

    # A summary of what the sample can prove, printed rather than assumed: the
    # numbers below are the branches the test is relying on this sample to hold.
    treatments = []
    bases = []
    tokens = []
    token_bases = 0
    landscape = 0
    leaders = 0
    bases_landscape = 0
    recounted = []
    expansions = {}
    for row in cards:
        attributes = attributes_of(row) or {}
        type_name = name_of(relation_of(attributes, "type"))
        base = relation_of(attributes, "variantOf")
        token = type_name in TOKEN_TYPES
        if base:
            treatments.append(row)
            if base.get("cardNumber") != attributes.get("cardNumber"):
                recounted.append("%s #%s for #%s" % (attributes.get("title"),
                                                    base.get("cardNumber"),
                                                    attributes.get("cardNumber")))
        else:
            bases.append(row)
            if token:
                token_bases += 1
        if token:
            tokens.append(row)
        if attributes.get("artFrontHorizontal") is True:
            landscape += 1
            if type_name == "Leader":
                leaders += 1
            elif type_name == "Base":
                bases_landscape += 1
        code = set_code_of(row)
        expansions[code] = expansions.get(code, 0) + 1
    pages = [code for code in WHOLE_SETS if len(fetched[code][0]) > PAGE_SIZE]

    payload = {
        "source": API,
        "cut_by": "tool/catalog/make_swu_sample.py",
        "why": "the Star Wars: Unlimited id-parity sample; see the module docstring",
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
    print("%d records, %d sets, %d treatment(s), %d base printing(s)"
          % (len(cards), len(sets), len(treatments), len(bases)))
    print("  %d token record(s), types %s: %d of them base printings, so the sample "
          "holds %d base printings once tokens are dropped"
          % (len(tokens),
             ", ".join(sorted({name_of(relation_of(attributes_of(r), "type"))
                               for r in tokens} & set(TOKEN_TYPES))),
             token_bases, len(bases) - token_bases))
    print("  %d record(s) printed landscape (artFrontHorizontal true): %d Leader, "
          "%d Base, %d other"
          % (landscape, leaders, bases_landscape,
             landscape - leaders - bases_landscape))
    print("  %d treatment(s) carry a cardNumber their base does not, e.g. %s"
          % (len(recounted), "; ".join(recounted[:3])))
    print("  records fall in %d expansion(s): %s"
          % (len(expansions),
             ", ".join("%s x%d" % (code, count)
                       for code, count in sorted(expansions.items()))))
    print("  sets read in more than one page: %s" % (", ".join(pages) or "none"))
    print("raw %.0f KiB, gzipped %.0f KiB" % (len(blob) / 1024,
                                              os.path.getsize(OUT) / 1024))
    print("  %s" % OUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
