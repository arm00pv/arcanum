#!/usr/bin/env python3
"""The importer half of the id-parity test.

Design: docs/catalogue-server-side.md, sections 3, 7 and 8. The Dart half lives
in test/catalog/catalog_id_parity_test.dart and runs the real provider clients
over a committed sample of real responses per game. This runs each importer
owner's own functions - the same ones the nightly import uses, imported rather
than copied - over the same samples, and asserts both against the same committed
file:

    tool/catalog/catalog_id_vectors.json.gz

Neither language is the authority. Both are asserted against that file, which
was generated from the Dart and is reviewed as a diff, so a change on either
side fails a test rather than quietly moving the goalposts.

One case per game in the GAMES table below, with the same assertions applied to
every case: the ids the importer derives are the ids the client derived, for
every card, and nothing is dropped or repeated. Each case also names the columns
of a row its importer actually derives, so this file never claims more than the
code it runs - Lorcana and Pokemon have an importer and are compared over every
column of a card row and of a set row, while Yu-Gi-Oh! has none yet and is
compared over the fields its id derivation produces:

  * lorcana - poll_lorcana_prices.card_document() and set_document(): every
    column of the row, because that importer exists and writes it. The ids here
    are forwarded from the provider.
  * pokemon - poll_pokemon_prices.card_document() and set_document(): every
    column of the row, because that importer exists and writes it. The ids are
    forwarded from the provider, and everything beside them is derived: the
    oracle id, the collector sort key, the composed type line, the rules text,
    the art URLs and the JSON in extras.
  * yugioh - poll_yugioh_prices.printing_id(), slug() and set_index(): the
    synthesised id and the set code inside it. The id derivation is mirrored in
    full and is where the two languages are likeliest to disagree.
  * gundam - import_gundam_catalogue.card_document() and set_document(): every
    column of the row, because that importer exists and writes it. The ids here
    are forwarded from the provider verbatim, and the printed number is not an
    id: five products are printed with GD01-005 on them.
  * digimon - import_digimon_catalogue.card_document() and set_document(): every
    column of the row, because that importer exists and writes it. The ids here
    are the source's own verbatim - BT8-022, or BT5-007_P3 for a printing of it -
    and the release a card is filed under is not always the set that printed it:
    bt-08 lists BT5-007_P3.

Why this is worth an offline test of its own rather than a line in the proof
script: the failure it catches is silent. A card id that the importer derives a
character differently does not raise. The row is written, the collection row
still names the old id, and that collector's holding renders as "--" for ever.
It is the one failure in this design that no log would show.

Nothing above needs a database. The last check does: with a database URL in the
environment it also asserts that the ids both languages derive are ids the
catalogue actually holds. Without one it is skipped with the reason, and a skip
is reported as a skip rather than as a pass; --require-db turns a skip into a
failure, which is what a run that was meant to check the database should do.

Exits 0 only if nothing failed.

    python3 tool/catalog/test_id_parity.py
    python3 tool/catalog/test_id_parity.py --verbose
    python3 tool/catalog/test_id_parity.py --require-db
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
import re
import sys
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.dirname(HERE)
REPO = os.path.dirname(TOOL)
VECTORS = os.path.join(HERE, "catalog_id_vectors.json.gz")

# The importers live one directory up, beside the pollers they are shared with,
# so they are imported rather than reimplemented. Importing catalog_store too is
# part of the point: this asserts the code that actually runs, and the database
# half below speaks to Postgres through the importer's own psql plumbing.
sys.path.insert(0, TOOL)
import catalog_store  # noqa: E402
import import_digimon_catalogue as digimon  # noqa: E402
import import_gundam_catalogue as gcgapi  # noqa: E402
import import_swu_catalogue as swu  # noqa: E402
import poll_lorcana_prices as lorcast  # noqa: E402
import poll_pokemon_prices as tcgdex  # noqa: E402
import poll_yugioh_prices as ygoprodeck  # noqa: E402

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


def skip(name, detail):
    record("SKIP", name, detail)


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


def project(rows, columns):
    """One game's rows, over the columns its importer actually derives.

    A game whose catalogue importer does not exist yet is compared on what the
    importer does derive rather than on a whole row Python has no rule for. The
    columns are named in the GAMES table below and printed with the result, so
    what was and was not compared is on the screen rather than implied.
    """
    if columns is None:
        return rows
    return {key: {name: row.get(name) for name in columns}
            for key, row in rows.items()}


def compare(label, mine, theirs, columns, verbose):
    """Compares one map of rows against the committed vectors, keyed alike."""
    compared = ("every column" if columns is None
                else f"{len(columns)} columns: {', '.join(columns)}")
    mine, theirs = project(mine, columns), project(theirs, columns)
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
    detail = (f"{len(mine)} rows compared against the committed vectors over "
              f"{compared}")
    if problems:
        if differing > 5:
            problems.append(f"... and {differing - 5} more rows differ")
        bad(label, detail + "\n" + "\n".join(problems))
        return False
    ok(label, detail + (f"; all {len(mine)} matched the client's row for row"
                        if verbose else f"; all {len(mine)} matched"))
    return True


# --------------------------------------------------------------------- lorcana

def lorcana_cards(sample):
    """Every catalog_cards row the Lorcana importer derives, keyed by its id."""
    mine = {}
    for card in sample["cards"]:
        if not isinstance(card, dict):
            continue
        set_map = card.get("set") if isinstance(card.get("set"), dict) else {}
        fallback = (lorcast.dart_string(set_map.get("code")) or "").lower()
        row = lorcast.card_document(card, fallback)
        if row is not None:
            mine[row["id"]] = row
    return mine


def lorcana_sets(sample):
    """Every catalog_sets row the Lorcana importer derives, keyed by its code."""
    mine = {}
    for item in sample["sets"]:
        if not isinstance(item, dict):
            continue
        row = lorcast.set_document(item)
        if row is not None:
            mine[row["code"]] = row
    return mine


# --------------------------------------------------------------------- pokemon

def tcgdex_ids(body):
    """The card ids one TCGdex set response lists, by the importer's own extraction.

    poll_pokemon_prices.stubs_of() is where the sweep, the catalogue importer
    and this test all read a set's brief card entries from, and card_ids_for_set()
    is its id-only form. It is the importer's entire relationship with a Pokemon
    card id: the id a set response lists is the id a card is fetched by and the
    id every price is sampled under, so there is no derivation to mirror and
    nothing to get a character wrong - which is what the check below this states
    as a test.
    """
    return [c["id"] for c in tcgdex.stubs_of(body)]


def client_addressable_id(card_id):
    """The key the client's own card lookup uses for a card id.

    The client drops the id into its request path unescaped, and the adapter
    that serves this sample reads the id back out with Uri.pathSegments, which
    decodes percent-escapes. An id carrying an escape is therefore looked up
    under its decoded spelling and is not found: "exu-%3F" is asked for as
    "exu-?" and answers 404. That is the same card the live provider answers 404
    for the importer, which is why the two halves of this test agree about which
    cards the client cannot read.

    Public because tool/catalog/prove_pokemon_import.py asks the same question
    of the same sample: one rule, one implementation, two callers.
    """
    return urllib.parse.unquote(card_id)


def pokemon_set_downloads(sample):
    """Each set the sample holds a response for, as (list entry, body), in order.

    The client lists every set and then downloads the ones it is asked for, so
    this is the same selection fetchCardsInSet makes: the entry the list carries,
    which is where a set row's published count comes from, and the set's own
    response, which is where its cards, its name, its release date and its
    series come from. A set the sample lists without a response is one the
    client's download of it 404s, and it contributes no cards.

    The proof script imports this rather than walking the sample a second time,
    because the two would otherwise be able to disagree about which cards the
    sample can place in a set.
    """
    details = sample.get("details") or {}
    out = []
    for item in sample.get("sets") or []:
        if not isinstance(item, dict):
            continue
        body = details.get(item.get("id"))
        if isinstance(body, dict):
            out.append((item, body))
    return out


def pokemon_cards(sample):
    """Every catalog_cards row the Pokemon importer derives, keyed by its id.

    The id is the provider's own and is forwarded by both sides. Everything
    beside it is derived, and is compared column by column: the oracle id, the
    collector sort key, the composed type line, the rules text, the rarity, the
    art URLs and the JSON in extras.

    The driver mirrors the client's two paths, because the client has two and
    they derive two different rows for one card - which is a fact about
    PokemonCatalog rather than about this test.

    A set the sample holds a response for is downloaded whole, the way
    PokemonCatalog.fetchCardsInSet downloads it: one row per brief entry in the
    set response, built from the full card object where the sample holds one.

    Every other sampled card is reached the way the app reaches a card it
    already holds an id for, by the id alone: fetchCardById has no set object,
    so its row carries no release date, takes its set name from the payload's
    embedded set and its set code from the id's own last dash. Those rows are
    why this driver is not simply "the importer's mapping over every card": the
    importer walks sets, so in a real run it has the set in hand, while the
    committed sample holds no set response at all for the sets those cards come
    from - the cut reaches them by id - and the row both languages derive from
    the responses that do exist is that by-id row.
    """
    full = {}
    for card in sample["cards"]:
        if isinstance(card, dict) and isinstance(card.get("id"), str):
            full[card["id"]] = card

    mine = {}
    for item, body in pokemon_set_downloads(sample):
        serie = tcgdex.serie_id(body)
        set_doc = tcgdex.set_document(item, body)
        for stub in tcgdex.stubs_of(body):
            # A body the client cannot address yields no card object, exactly as
            # it yields none for the client, and the row is the stub row built
            # from the set response instead.
            card = full.get(client_addressable_id(stub["id"]))
            row = tcgdex.card_document(card, set_doc=set_doc, stub=stub, serie=serie)
            if row is not None:
                mine[row["id"]] = row

    for card_id, card in full.items():
        if card_id in mine:
            continue
        row = tcgdex.card_document(card, requested_id=card_id)
        if row is not None:
            mine[row["id"]] = row
    return mine


def pokemon_sets(sample):
    """Every catalog_sets row the Pokemon importer derives, keyed by its code.

    PokemonCatalog lists every set once and then enriches each one with that
    set's own response, so its row is built from two payloads and both are
    committed here: the entry the list carries - the id, the name and the card
    count TCGdex publishes there - and the detail, which carries the release
    date, the logo and the series. A set whose detail response failed keeps the
    row the list entry alone describes, which is what fetchAllSets falls back
    to. All five of the sample's sets have a detail, so the enrich branch and
    every column it writes are compared.
    """
    mine = {}
    for item, body in pokemon_set_downloads(sample):
        row = tcgdex.set_document(item, body)
        if row is not None:
            mine[row["code"]] = row
    # A set the list holds without a response still has a row: the client's
    # download of it 404s and it keeps what the list alone describes.
    listed = {item.get("id") for item, _ in pokemon_set_downloads(sample)}
    for item in sample.get("sets") or []:
        if not isinstance(item, dict) or item.get("id") in listed:
            continue
        row = tcgdex.set_document(item, None)
        if row is not None:
            mine[row["code"]] = row
    return mine


# --------------------------------------------------------------------- yugioh

def yugioh_cards(sample):
    """Every catalog_cards row the Yu-Gi-Oh! importer derives, keyed by its id.

    The id is poll_yugioh_prices.printing_id() - the importer's own mirror of
    _printingId in lib/data/catalog/ygo_catalog.dart - over four fields, and the
    set code that becomes its second field is resolved the way card_points()
    resolves it: by the printing's own set name in the index set_index() builds,
    and otherwise from the Konami code printed on the card.

    card_points() itself cannot be called: it folds in a price gate (a printing
    the provider holds no price for contributes nothing) and a --sets filter,
    and neither is part of an id. What is written out here is therefore the
    *selection* - which rows of a card become printings, and which set each one
    belongs to - because a row the client does not derive is a row the importer
    must not derive either. Every derivation inside that selection is the
    importer's own function.
    """
    index = ygoprodeck.set_index(sample["sets"])
    mine = {}
    for card in sample["cards"]:
        if not isinstance(card, dict):
            continue
        passcode = ygoprodeck.passcode_of(card)
        if passcode is None:
            continue
        raw = card.get("card_sets")
        rows = [r for r in raw if isinstance(r, dict)] if isinstance(raw, list) else []
        if not rows:
            # A card the provider gives no printing rows at all keeps its bare
            # passcode, which is the id the app gives such a card.
            card_id = ygoprodeck.printing_id(passcode, "", "", "")
            mine[card_id] = {"id": card_id, "set_code": ""}
            continue
        for row in rows:
            printing_code = row.get("set_code") or ""
            set_code = index.get(str(row.get("set_name") or "").strip().lower())
            if not set_code:
                set_code = ygoprodeck.provider_code(printing_code).lower()
            card_id = ygoprodeck.printing_id(
                passcode, set_code, printing_code, row.get("set_rarity") or "")
            mine[card_id] = {"id": card_id, "set_code": set_code}
    return mine


def yugioh_sets(sample):
    """Every catalog_sets row the client stores, keyed by its code.

    The client's set row is mostly the provider's own entry, but its code is
    not: the app assigns one per set and suffixes the repeats, and that
    assignment is a rule over the whole published list - 1,035 sets under 646
    codes. poll_yugioh_prices re-implements it as set_index() and it has to stay
    one, because the code is the second field of every printing id.
    """
    return {code: {"code": code}
            for code in ygoprodeck.set_index(sample["sets"]).values()}


# ------------------------------------------------------------------------- swu

def swu_records_by_code(sample):
    """The sampled records of each set, keyed by the publisher's own code."""
    out = {}
    for row in sample.get("cards") or []:
        attributes = swu.attributes_of(row)
        if attributes is None:
            continue
        expansion = swu.relation_of(attributes, "expansion") or {}
        code = swu.dart_string(expansion.get("code"))
        if code:
            out.setdefault(code, []).append(row)
    return out


def swu_base_printings(records):
    """How many of [records] are the base printing of a card.

    The set's own card count, and the number printed on the cards: the records
    that are not a version of another card and not a token. Spark of Rebellion is
    991 records and 252 of these.
    """
    count = 0
    for row in records:
        attributes = swu.attributes_of(row)
        if attributes is None:
            continue
        kind = swu.dart_string((swu.relation_of(attributes, "type") or {})
                               .get("name")) or ""
        if kind in swu.TOKENS:
            continue
        if swu.relation_of(attributes, "variantOf") is not None:
            continue
        count += 1
    return count


def swu_set_downloads(sample):
    """Each set the sample cuts whole, as (list entry, records), in order.

    The client lists every set - one request for the list and one count request
    per set, both answered from the sample - and then downloads the sets it is
    asked for, so this is the same selection fetchCardsInSet makes. Public because
    tool/catalog/prove_swu_import.py walks the sample through the same selection:
    one rule, one implementation, two callers.
    """
    by_code = {}
    for item in sample.get("sets") or []:
        attributes = swu.attributes_of(item)
        if attributes is None:
            continue
        code = swu.dart_string(attributes.get("code"))
        if code:
            by_code[code] = item
    records = swu_records_by_code(sample)
    out = []
    for code in sample.get("sampled_sets") or []:
        provider = str(code).strip().upper()
        out.append((by_code.get(provider), records.get(provider, [])))
    return out


def swu_cards(sample):
    """Every catalog_cards row the Star Wars: Unlimited importer derives.

    The id is the publisher's cardUid, forwarded verbatim; everything beside it
    is derived and is compared column by column - the oracle id, the collector
    number (which a treatment takes from the base card it points at, not from its
    own), the collector sort key, the folded set code, the type line, the rarity,
    the portrait art and the JSON in extras.

    The driver mirrors the client's set-download path, because that is the path
    the committed Dart vectors hold: the sample cuts whole sets, and a record of
    one carries the set it was downloaded as part of.
    """
    mine = {}
    for _item, records in swu_set_downloads(sample):
        for row in records:
            document = swu.card_document(row)
            if document is not None:
                mine[document["id"]] = document
    return mine


def swu_sets(sample):
    """Every catalog_sets row the Star Wars: Unlimited importer derives.

    The set list carries the code and the name and no card count at all, which is
    why a count is a second request per set in both languages: a one-record read
    whose envelope carries the total, over the base printings that are not tokens.
    Here that request is answered from the sample, so a set the sample does not
    cut whole counts its own sampled records - which is zero - and the row is the
    row the Dart side derives from the same envelope.
    """
    counts = {code: swu_base_printings(records)
              for code, records in swu_records_by_code(sample).items()}
    mine = {}
    for item in sample.get("sets") or []:
        attributes = swu.attributes_of(item)
        if attributes is None:
            continue
        provider = swu.dart_string(attributes.get("code"))
        if not provider:
            continue
        row = swu.set_document(item, counts.get(provider, 0))
        if row is not None:
            mine[row["code"]] = row
    return mine


def swu_tokens(sample):
    """The cardUid of every sampled record that is a token."""
    out = set()
    for row in sample.get("cards") or []:
        attributes = swu.attributes_of(row)
        if attributes is None:
            continue
        kind = swu.dart_string((swu.relation_of(attributes, "type") or {})
                               .get("name")) or ""
        if kind in swu.TOKENS:
            uid = swu.dart_string(attributes.get("cardUid"))
            if uid:
                out.add(uid)
    return out


def every_id_is_the_card_uid_the_publisher_publishes(case):
    """The ids the importer derives are the publisher's cardUids, verbatim.

    The publisher names a card three ways and only one of them is an id: cardUid
    is unique over the whole game, cardId is null on most records and names a
    related card where it is set, and validationId repeats. Both languages can
    forward an id and still disagree about it - a trim, a lower-case, a dropped
    separator - so the id set is asserted rather than assumed, over every sampled
    record that is a card at all.
    """
    provider = set()
    for row in case.sample.get("cards") or []:
        attributes = swu.attributes_of(row)
        if attributes is None:
            continue
        uid = swu.dart_string(attributes.get("cardUid"))
        if uid:
            provider.add(uid)
    cards = provider - swu_tokens(case.sample)
    if set(case.cards) == cards:
        return True, ("%d cardUids forwarded verbatim, %d tokens dropped and "
                      "nothing else" % (len(cards), len(provider) - len(cards)))
    invented = sorted(set(case.cards) - cards)[:3]
    dropped = sorted(cards - set(case.cards))[:3]
    return False, ("the id set is not the publisher's: %d invented (%s), %d "
                   "dropped (%s)" % (len(set(case.cards) - cards), invented,
                                      len(cards - set(case.cards)), dropped))


def a_treatment_takes_its_base_cards_number(case):
    """A treatment is numbered as the card it is a version of, and stays its own.

    A hyperspace Luke carries cardNumber 1 where Luke carries 5, because a
    treatment's own number counts its run rather than the card. Both languages
    take the number from the base record the treatment points at - which is the
    number printed on the card and the number the app's binder slots group by -
    while the id stays the treatment's own, so two holdings of one card do not
    collapse into one row.
    """
    seen = 0
    for row in case.sample.get("cards") or []:
        attributes = swu.attributes_of(row)
        if attributes is None:
            continue
        base = swu.relation_of(attributes, "variantOf")
        if base is None:
            continue
        uid = swu.dart_string(attributes.get("cardUid"))
        stored = case.cards.get(uid)
        if stored is None:
            continue
        seen += 1
        printed = base.get("cardNumber")
        if not isinstance(printed, int):
            return False, "a base record carries no cardNumber: %r" % (base,)
        if stored["collector_number"] != "%03d" % printed:
            return False, ("%s is stored as #%s and its base card is #%03d"
                           % (uid, stored["collector_number"], printed))
        if stored["oracle_id"] != str(base.get("cardUid")):
            return False, ("%s does not group with the base card it is a version "
                           "of" % uid)
        if stored["id"] == str(base.get("cardUid")):
            return False, "%s was stored under its base card's id" % uid
    if seen < 50:
        return False, ("the sample holds %d treatments, too few to prove the rule"
                       % seen)
    return True, ("%d treatments take their base card's printed number, keep "
                  "their own id and group with the card" % seen)


def the_landscape_art_is_drawn_from_the_other_face(case):
    """A landscape card with a portrait face is stored as that face.

    A leader's own art is 418x300 and every card in the app is drawn at the game's
    portrait ratio, so its row carries the deployed unit from the other face of
    the same card. The flag is not a leader flag - 32 Base records of the sample
    are landscape too, and have no second face - so the rule is "the other face
    when there is one" and both languages have to read it that way.
    """
    leaders = 0
    bases = 0
    for row in case.sample.get("cards") or []:
        attributes = swu.attributes_of(row)
        if attributes is None:
            continue
        if attributes.get("artFrontHorizontal") is not True:
            continue
        uid = swu.dart_string(attributes.get("cardUid"))
        stored = case.cards.get(uid)
        if stored is None:
            continue
        back = swu.image_of(attributes.get("artBack"))
        if back is None:
            bases += 1
            continue
        leaders += 1
        if stored["image_normal"] != back:
            return False, ("%s is stored with the landscape art rather than the "
                           "other face" % uid)
    if leaders < 5 or bases < 5:
        return False, ("the sample holds %d landscape cards with a second face "
                       "and %d without, too few to prove the rule"
                       % (leaders, bases))
    return True, ("%d landscape cards are stored as their portrait face and %d "
                  "with no second face keep the art they have" % (leaders, bases))


def the_set_counts_are_base_printings(case):
    """A set's card count is its base printings, which is what the cards print.

    The set list carries no count at all, so both languages read one with a
    one-record request per set whose envelope carries the total, over the base
    printings that are not tokens: 252 for Spark of Rebellion, where the same
    filter answers 991 for every record in the set."""
    bases = {code: swu_base_printings(records)
             for code, records in swu_records_by_code(case.sample).items()}
    for code, row in case.sets.items():
        provider = str(row.get("id") or "")
        if row.get("card_count") != bases.get(provider, 0):
            return False, ("set %s is counted as %r and holds %d base printings"
                           % (code, row.get("card_count"),
                              bases.get(provider, 0)))
    return True, ("every set is counted over its base printings: %s"
                  % sorted(bases.items())[:3])


# ---------------------------------------------------------------------- gundam

def gundam_set_downloads(sample):
    """Each set the sample cuts whole, as (list entry, products), in order.

    The client lists every set and then downloads the ones it is asked for, so
    this is the same selection fetchCardsInSet makes: the entry the list carries,
    which is where a set row's name and published card count come from, and the
    products the provider files under that set, which is where its cards come
    from. A set is cut whole or not at all, so every product in the sample is in
    the set the payload names - and the payload names the set a product is filed
    under, which is not always the set its printed number names.

    Public because tool/catalog/prove_gundam_import.py walks the sample through
    the same selection: one rule, one implementation, two callers.
    """
    by_code = {}
    for item in sample.get("sets") or []:
        if isinstance(item, dict):
            code = gcgapi.slug(item.get("set_code"))
            if code:
                by_code[code] = item
    products = {}
    for card in sample.get("cards") or []:
        if not isinstance(card, dict):
            continue
        products.setdefault(gcgapi.slug(card.get("set_code")), []).append(card)
    out = []
    for code in sample.get("sampled_sets") or []:
        folded = gcgapi.slug(code)
        out.append((by_code.get(folded), products.get(folded, [])))
    return out


def gundam_cards(sample):
    """Every catalog_cards row the Gundam importer derives, keyed by its id.

    The id is the provider's own product id and is forwarded by both sides:
    nothing here is synthesised, and the id a row is stored under is the id the
    provider's own response carries. Everything beside it is derived and is
    compared column by column: the oracle id, the collector sort key, the folded
    set code, the type line, the rarity, the art URL and the JSON in extras.

    The driver mirrors the client's set-download path, because that is the path
    the committed Dart vectors hold: the sample cuts whole sets, and a row of one
    carries the set it was downloaded as part of.
    """
    mine = {}
    for item, products in gundam_set_downloads(sample):
        set_doc = gcgapi.set_document(item) if isinstance(item, dict) else None
        code = set_doc["code"] if set_doc is not None else None
        for card in products:
            row = gcgapi.card_document(card, set_doc=set_doc, set_code=code)
            if row is not None:
                mine[row["id"]] = row
    return mine


def gundam_sets(sample):
    """Every catalog_sets row the Gundam importer derives, keyed by its code.

    The set list carries everything a set row needs: the provider's own code, the
    name and a real card count - 28 sets, none of them short. The row's code is
    that code folded, and the provider's spelling is kept beside it in 'id',
    which is the one place in this document where the two genuinely differ for
    every set of a game.
    """
    mine = {}
    for item in sample.get("sets") or []:
        row = gcgapi.set_document(item)
        if row is not None:
            mine[row["code"]] = row
    return mine


# -------------------------------------------------------------------- digimon

def digimon_set_downloads(sample):
    """Each release the sample cuts whole, as its own slug -> the ids it lists.

    The client lists every release and then downloads the ones it is asked for, so
    this is the same selection fetchCardsInSet makes: one request for the release
    itself, which names its cards one id at a time in 'included' and carries its
    own name, and then one request per id - there is no batch route. The mapping is
    ordered by the sample's own 'sampled_sets', which is the source's listing order
    and is load bearing: P-058 is listed by both 'p' and 'bt-08', so that order is
    what decides which of its two rows the catalogue keeps.

    Public because the checks below walk the sample through the same selection:
    one rule, one implementation, four callers.
    """
    releases = sample.get("releases") or {}
    out = {}
    for slug in sample.get("sampled_sets") or []:
        envelope = releases.get(slug)
        if isinstance(envelope, dict):
            out[slug] = digimon.card_ids_of(envelope)
    return out


def digimon_number_of(envelope):
    """The number a card prints, as the source's own envelope states it.

    The one raw field of a card this file reads for itself: that number is what
    names the set a card was printed in, and it is the fallback a card the source
    files under no release at all is filed under, so a check about either needs it.
    """
    data = envelope.get("data") if isinstance(envelope, dict) else None
    attributes = data.get("attributes") if isinstance(data, dict) else None
    return attributes.get("number") if isinstance(attributes, dict) else None


def digimon_walk(sample):
    """Every row the sample's set downloads derive, as id -> {folded code: row}.

    Keyed by the release as well as the card, because the two are not one fact
    here: a card one release lists has one row and P-058 has two. The client walks
    a release with one request for its ids and one per card, and hands each card
    the release it was reading rather than the set the card prints, because a card
    printed by one set is often filed under another. digimon_cards keeps the last
    row written for a card, which is the row the catalogue holds; the checks that
    need the row of the release a card's own record names keep them apart this way.
    """
    releases = sample.get("releases") or {}
    envelopes = sample.get("cards") or {}
    walk = {}
    for slug, card_ids in digimon_set_downloads(sample).items():
        envelope = releases.get(slug)
        code = digimon.slug(slug)
        name = digimon.release_name_of(envelope)
        for card_id in card_ids:
            row = digimon.card_document(envelopes.get(card_id), set_code=code,
                                        set_name=name)
            if row is None:
                continue
            walk.setdefault(card_id, {})[code] = row
    return walk


def digimon_cards(sample):
    """Every catalog_cards row the Digimon importer derives, keyed by its id.

    The id is the source's own and is forwarded verbatim - BT8-022, or BT5-007_P3
    for a printing of it - and everything beside it is derived and is compared
    column by column: the oracle id, the collector number and its sort key, the
    folded set code, the rarity word behind the source's code, the type line, the
    rules text, the art and the JSON in extras.

    The driver mirrors the client's set-download path, and it walks the sample's
    'sampled_sets' in the order the source lists them rather than set by set: that
    order is what decides the row of a card two releases list, because the row that
    survives is the last one written and the importer walks them in the same order.
    The set code and the set name each card is handed are the release the walk was
    reading, which is not always the set that printed the card.

    A card that derives no row is reported as a failure rather than skipped: the
    importer refuses a whole set whose walk answered nothing card-like, and a card
    this file dropped quietly would be a card the two languages were never compared
    about at all.
    """
    downloads = digimon_set_downloads(sample)
    walk = digimon_walk(sample)
    mine = {}
    for card_id, rows in walk.items():
        # The release the walk wrote this card under last, which is the row the
        # catalogue keeps for it.
        mine[card_id] = rows[list(rows)[-1]]
    listed = {card_id for card_ids in downloads.values() for card_id in card_ids}
    underived = sorted(listed - set(walk))
    unfetched = [slug for slug in sample.get("sampled_sets") or []
                 if slug not in downloads]
    if underived or unfetched:
        bad("digimon: the_source_answered_nothing_card_like",
            f"{len(underived)} of the {len(listed)} ids the sampled releases list "
            f"derived no row, e.g. {underived[:3]}"
            + (f"; the sample holds no release envelope for {unfetched}"
               if unfetched else ""))
    return mine


def digimon_sets(sample):
    """Every catalog_sets row the Digimon importer derives, keyed by its code.

    The set list is one request and carries everything a set row needs: the
    source's own spelling of the release, what it calls it, the number of card
    entries it lists - the source's own count rather than the distinct cards it
    holds - and, for 87 of the 93, the date it went on sale. There is no count
    request here, which is the difference between this source and the one Star
    Wars: Unlimited came from.

    The row's code is that spelling folded and its 'id' is the spelling itself, and
    they are not recoverable from each other: folding throws away the dash and the
    version numbering of 'bt01-03-v1-0', which folds to 'bt0103v10'.
    """
    envelope = sample.get("sets")
    included = envelope.get("included") if isinstance(envelope, dict) else None
    mine = {}
    for item in included or []:
        provider_code = digimon.slug_of(item, digimon.RELEASES)
        if not provider_code:
            continue
        row = digimon.set_document(item, provider_code)
        if row is not None:
            mine[row["code"]] = row
    return mine


# ------------------------------------------------------------ the assertions
#
# One function per property, each applied to the games that can state it. They
# take the case rather than a couple of maps so that a check can reach the
# sample, the rows the importer derived and the rows the client committed.

class Case:
    """One game: its sample, the rows its importer derived, and the client's."""

    def __init__(self, game, sample, cards, sets, client_cards, client_sets):
        self.game = game
        self.sample = sample
        self.cards = cards
        self.sets = sets
        self.client_cards = client_cards
        self.client_sets = client_sets


def every_id_is_the_providers_own(case):
    """The ids the importer derives are the provider's own, verbatim.

    Both languages can forward an id and still disagree about it - a trim, a
    lower-case, a dropped separator - so the id set is asserted rather than
    assumed. It is also the claim that quietly stops being true: a game whose
    ids were forwarded when this was written and are synthesised a year later
    fails here rather than in a collection row.
    """
    provider = {c["id"] for c in case.sample["cards"]
                if isinstance(c, dict) and isinstance(c.get("id"), str)}
    if set(case.cards) == provider:
        return True, (f"{len(provider)} ids forwarded verbatim, none synthesised "
                      f"and none dropped")
    invented = sorted(set(case.cards) - provider)[:3]
    dropped = sorted(provider - set(case.cards))[:3]
    return False, (f"the id set is not the provider's: "
                   f"{len(set(case.cards) - provider)} not published by the "
                   f"provider ({invented}), {len(provider - set(case.cards))} "
                   f"dropped ({dropped})")


def no_card_was_dropped(case):
    """Every card object the sample holds produced a row."""
    total = sum(1 for c in case.sample["cards"] if isinstance(c, dict))
    if len(case.cards) == total:
        return True, f"all {total} sampled cards produced a row"
    return False, (f"{total - len(case.cards)} of {total} sampled cards produced "
                   f"no row")


def layout_is_the_clients_empty_string(case):
    """The one field a transcription is likeliest to get wrong.

    It is the one field the provider publishes and the client deliberately does
    not use: Lorcast carries a layout, LorcanaCatalog never reads it, and a
    server row carrying "normal" would not be the row the client writes.
    """
    layouts = {row["layout"] for row in case.cards.values()}
    if layouts == {""}:
        return True, ("the payload carries a layout and the client stores an "
                      "empty one; the importer follows the client")
    return False, f"layouts stored: {sorted(layouts)}"


def the_unaddressable_card_round_trips(case):
    """The one card the client cannot address is stored as the row the client stores.

    TCGdex publishes a collector number of "%3F" as the card id "exu-%3F", and
    that id only addresses as a path segment when the percent sign is escaped
    again. The Dart client does not escape it, so its request reaches the router
    as "exu-?" and answers 404, and PokemonCatalog then stores a card built from
    the set response's brief entry: no rarity, no rules text, no artist, no
    extras and no release date. A sample that did not hold such a card would let
    an importer store the fuller row it *can* read and still pass - and the
    catalogue would then serve a card the phone's own provider path cannot show,
    which is the two-ways-to-fill-one-table problem the design warns about. So
    the trap is asserted rather than assumed.
    """
    unaddressable = sorted(
        str(card["id"]) for card in case.sample["cards"]
        if isinstance(card, dict) and isinstance(card.get("id"), str)
        and client_addressable_id(card["id"]) != card["id"])
    if not unaddressable:
        return False, ("the sample holds no card the client cannot address, so "
                       "the fallback row this importer has a branch for is "
                       "untested")
    problems = []
    for card_id in unaddressable:
        row = case.cards.get(card_id)
        if row is None:
            problems.append(f"{card_id} produced no row at all")
            continue
        if row.get("rarity") != "unknown":
            problems.append(f"{card_id} carries rarity {row.get('rarity')!r}")
        if row.get("extras") is not None:
            problems.append(f"{card_id} carries extras {row.get('extras')!r}")
        if row.get("oracle_text") is not None or row.get("cmc") is not None:
            problems.append(f"{card_id} carries rules text or an hp")
        if row.get("released_at") is not None:
            problems.append(f"{card_id} carries a release date")
    if problems:
        return False, "\n".join(problems)
    return True, (f"{len(unaddressable)} card(s) the client cannot address "
                  f"({', '.join(unaddressable)}) are stored as the fallback row "
                  f"the client itself stores, under their own ids")


def the_set_codes_are_the_folded_form_the_catalogue_stores(case):
    """Every set id in the sample is already the folded code the catalogue stores.

    The catalogue stores a Pokemon set code folded to lower case - see
    poll_pokemon_prices.set_document, which argues it in full - while
    PokemonCatalog puts the provider's own id in TcgSet.code. TCGdex publishes
    fifteen set ids that are not lower case (A1, A1a, A2 ... B2a and P-A), so
    for those sets the two really do differ; the committed sample holds none of
    them, because the five sets it cuts whole are base1, swsh9tg, swsh4.5sv, exu
    and miscp. That makes the whole-row comparison in this case silent about the
    folding rule, and this check is here so that silence is stated rather than
    assumed. It fails if the sample is ever re-cut to hold a set whose id is not
    lower case, so that the row comparison does not report a mismatch whose
    cause is a decision somebody has to make.
    """
    unusual = sorted(
        str(item["id"]) for item in case.sample["sets"]
        if isinstance(item, dict) and isinstance(item.get("id"), str)
        and item["id"] != item["id"].lower())
    if unusual:
        return False, (
            f"the sample now holds set id(s) that are not lower case: {unusual}. "
            "The importer stores the folded code and the client stores the "
            "provider's own, so those rows differ by construction and the "
            "vectors need a decision before they can be compared")
    return True, ("every set id in the sample is already lower case, so the "
                  "folded code the catalogue stores is the id the client stores: "
                  "the folding is a no-op over these vectors, and the fifteen "
                  "live set ids it does change are argued in "
                  "poll_pokemon_prices.set_document")


def every_art_url_carries_its_series(case):
    """No Pokemon row carries an address of the form the CDN answers 404 for.

    TCGdex files art at <host>/en/<serie>/<set>/<number>/<size>, and the series
    segment is load bearing: measured over ten sets from ten different series,
    the form with it answered 200 ten times out of ten and the form without it
    404 ten times out of ten. The client used to build the series-less form on
    one path - a card fetched by its id alone whose payload carried no image of
    its own - and now stores no art at all there rather than a URL that cannot
    load, so the app draws its card back instead of requesting a broken address.

    The whole-row comparison above cannot catch a disagreement about this rule
    if both languages make the same mistake: they would still match, row for
    row, on a URL that 404s. This asserts the rule itself, over the committed
    rows, so a series-less URL is a failure rather than an agreement.
    """
    host = "https://assets.tcgdex.net/en/"
    wrong = []
    for card_id in sorted(case.cards):
        row = case.cards[card_id]
        for column in ("image_small", "image_normal", "image_large"):
            url = row.get(column)
            if url is None:
                continue
            if not isinstance(url, str) or url != url.strip():
                wrong.append(f"{card_id}: {column} is not a clean URL: {url!r}")
                continue
            if not url.startswith(host):
                continue
            # <serie>/<set>/<number>/<size> is four segments under /en/; the
            # series-less form the CDN 404s on is three.
            if len(url[len(host):].split("/")) != 4:
                wrong.append(f"{card_id}: {column} has no series segment: {url}")
    if wrong:
        return False, (f"{len(wrong)} art URL(s) of the form the CDN answers 404 "
                       f"for:\n" + "\n".join(wrong[:5]))
    arts = sum(1 for row in case.cards.values()
               for column in ("image_small", "image_normal", "image_large")
               if isinstance(row.get(column), str))
    return True, (f"all {arts} art URLs carry their series segment; the cards "
                  f"with no image of their own and no series to place them under "
                  f"carry no art at all")


def the_set_responses_list_the_same_ids(case):
    """The ids the provider's own set responses list are the ids the rows carry.

    The poller learns a Pokemon card's id from a set response - that is the id
    it fetches the card by and the card_id it samples every price under - while
    the client learns it from the card response. The sample cuts five sets whole
    and reaches the rest of its cards by id, so this compares the ids of the
    sets it does hold, which is where both sides read the same payload.
    """
    listed = set()
    for body in (case.sample.get("details") or {}).values():
        listed.update(i for i in tcgdex_ids(body) if i)
    if not listed:
        return False, "the sample holds no set responses to read ids out of"
    orphans = sorted(listed - set(case.cards))
    if orphans:
        return False, (f"{len(orphans)} ids listed by the provider's set "
                       f"responses produced no row, e.g. {orphans[:3]}")
    return True, (f"all {len(listed)} ids the provider's set responses list are "
                  f"ids a row was stored under")


def every_id_begins_with_its_passcode(case):
    """Every synthesised id is four fields and begins with the passcode.

    _printingId puts the passcode first so refreshPrices and fetchCardById can
    read it back with a split rather than a lookup, and the three fields after
    it are slugs, which cannot contain a colon. A bare passcode is the branch
    for a card the provider gives no printing rows at all - the id the app gives
    such a card.
    """
    passcodes = {str(c.get("id")) for c in case.sample["cards"]
                 if isinstance(c, dict)}
    bare = 0
    for card_id in case.cards:
        parts = card_id.split(":")
        if not parts[0].strip().isdigit():
            return False, f"{card_id} does not begin with a passcode"
        if len(parts) == 1:
            bare += 1
            if parts[0] not in passcodes:
                return False, f"{card_id} is not a passcode the provider publishes"
        elif len(parts) != 4 or not parts[3].strip():
            return False, f"{card_id} is not four fields ending in a rarity"
    return True, (f"{len(case.cards)} ids, {len(case.cards) - bare} synthesised "
                  f"from four fields and {bare} bare passcodes for cards the "
                  f"provider gives no printing rows at all")


def the_collision_rule_is_exercised(case):
    """A committed set code is not the code Konami published.

    The app suffixes the repeats of a code, and the suffix is part of every
    printing id in that set - "25lp2" is a real set code and 21 real printings
    are stored under it. A sample in which no code was suffixed would leave the
    likeliest disagreement between the two languages untested.
    """
    published = {str(s.get("set_name") or ""): str(s.get("set_code") or "")
                 for s in case.sample["sets"] if isinstance(s, dict)}
    suffixed = sorted(
        code for code, row in case.client_sets.items()
        if published.get(str(row.get("name") or "")) and
        published[str(row.get("name") or "")].lower() != code)
    if suffixed:
        return True, (f"{len(suffixed)} set code(s) were suffixed by the "
                      f"assignment, e.g. {suffixed[:3]}")
    return False, "no set code was suffixed, so the collision rule is untested"


def the_punctuated_rarities_are_slugged(case):
    """The rarities that carry punctuation appear in the ids as slugs.

    The rarity is the fourth field of every printing id and the only field that
    has to guess: "Collector's Rare" and "Ultra Rare (Pharaoh's Rare)" are what
    a naive lower-case gets wrong. A sample holding none of them would pass
    while proving nothing about it.
    """
    punctuated = set()
    for card in case.sample["cards"]:
        if not isinstance(card, dict):
            continue
        for row in card.get("card_sets") or []:
            if not isinstance(row, dict):
                continue
            rarity = str(row.get("set_rarity") or "").strip()
            if rarity and re.search(r"[^A-Za-z0-9 ]", rarity):
                punctuated.add(rarity)
    fields = {card_id.split(":")[3] for card_id in case.cards
              if card_id.count(":") == 3}
    matched = sorted(r for r in punctuated if ygoprodeck.slug(r) in fields)
    if matched:
        return True, (f"{len(matched)} punctuated rarities are in the ids as "
                      f"slugs, e.g. {matched[:3]}")
    return False, (f"none of the {len(punctuated)} punctuated rarities the sample "
                   f"holds appears in any id, e.g. {sorted(punctuated)[:3]}")


def every_id_is_the_product_id_the_provider_publishes(case):
    """The ids the importer derives are the provider's own product ids, verbatim.

    This is the whole of the id claim for this game, and it is the claim that
    makes the catalogue usable: a collection row names a card id, so an id that
    moved would leave a holding rendering as "--" for ever. Both languages can
    forward an id and still disagree about it - a trim, a lower-case, a dropped
    separator - so the id set is asserted rather than assumed.
    """
    provider = {str(c["product_id"]) for c in case.sample["cards"]
                if isinstance(c, dict) and c.get("product_id")}
    if set(case.cards) == provider:
        return True, (f"{len(provider)} product ids forwarded verbatim, none "
                      f"synthesised and none dropped")
    invented = sorted(set(case.cards) - provider)[:3]
    dropped = sorted(provider - set(case.cards))[:3]
    return False, (f"the id set is not the provider's: "
                   f"{len(set(case.cards) - provider)} not published by the "
                   f"provider ({invented}), {len(provider - set(case.cards))} "
                   f"dropped ({dropped})")


def the_art_variants_of_one_card_stay_apart(case):
    """The products printed with one number are separate rows, not one.

    Gundam's printed number is not an id and this is the game where saying so
    costs something: 1,912 products carry 1,148 card numbers, because an
    alternate art is a product of its own with the same number printed on it -
    GD01-005 has four parallels, two of them sharing a rarity. An id derived
    from the number would be unique-looking, would store, and would silently
    collapse a collector's two holdings into one row. A sample holding no such
    cluster would let that pass, so the cluster is asserted rather than assumed.
    """
    by_number = {}
    for card in case.sample["cards"]:
        if not isinstance(card, dict):
            continue
        by_number.setdefault(str(card.get("card_number") or ""),
                             []).append(str(card.get("product_id") or ""))
    clusters = {n: ids for n, ids in by_number.items() if len(ids) > 1}
    if not clusters:
        return False, ("the sample holds no printed number shared by two "
                       "products, so an id derived from the number would pass "
                       "this file")
    shared = sum(len(ids) for ids in clusters.values())
    stored = sum(1 for ids in clusters.values() for card_id in ids
                 if card_id in case.cards)
    if stored != shared:
        return False, (f"{shared - stored} of the {shared} products sharing a "
                       f"printed number produced no row of their own")
    numbers = {row["collector_number"] for row in case.cards.values()}
    if len(numbers) >= len(case.cards):
        return False, ("every row carries a distinct collector number, so this "
                       "sample cannot show what an id built from the number "
                       "would do")
    return True, (f"{shared} products across {len(clusters)} printed number(s) "
                  f"each kept a row of their own, e.g. "
                  f"{sorted(clusters)[:3]}; the {len(case.cards)} rows carry "
                  f"{len(numbers)} distinct collector numbers, so the number is "
                  f"demonstrably not the id")


def the_page_cap_is_exercised(case):
    """A set larger than the provider's page is stored whole.

    gcgapi caps a page at 250 rows and answers 250 for any larger limit rather
    than refusing, so a set bigger than that is only complete if both languages
    page it the same way: a loop that stopped after the first page would store a
    set that looks catalogued and is 246 cards short. GD01 is the set that says
    so, and the sample holds it.
    """
    paging = [str(item.get("set_code"))
              for item in case.sample.get("sets") or []
              if isinstance(item, dict) and (item.get("card_count") or 0) > 250]
    if not paging:
        return False, ("no set in the sample is larger than the provider's page "
                       "cap, so the paging of a set is untested here")
    problems = []
    for code in paging:
        folded = gcgapi.slug(code)
        expected = sum(1 for card in case.sample["cards"]
                       if isinstance(card, dict)
                       and gcgapi.slug(card.get("set_code")) == folded)
        stored = sum(1 for row in case.cards.values()
                     if row.get("set_code") == folded)
        if stored != expected:
            problems.append(f"set {code!r} publishes {expected} products and "
                            f"{stored} of them are rows")
    if problems:
        return False, "\n".join(problems)
    return True, (f"{len(paging)} set(s) are larger than the provider's "
                  f"250-row page ({', '.join(paging)}) and every one of their "
                  f"products is a row")


def the_two_paths_derive_one_row(case):
    """A card downloaded with its set and the same card reached by its id are one row.

    The client has two paths that build a row for a card - a set download and a
    card fetched by its own id - and they are the place the Pokemon catalogue
    genuinely derives two different rows for one card. Gundam does not: the
    payload names the set a product is filed under, so a by-id row carries the
    same set code as a set download's. That is a claim about this provider rather
    than a fact about the world, so it is asserted over the sample: a change that
    made the two disagree would otherwise move which row the committed vectors
    hold without failing anything.
    """
    problems = []
    compared = 0
    for _item, products in gundam_set_downloads(case.sample):
        for card in products:
            folded = gcgapi.slug(card.get("set_code"))
            downloaded = gcgapi.card_document(card, set_code=folded)
            by_id = gcgapi.card_document(card, set_code=None)
            compared += 1
            if not same(downloaded, by_id):
                problems.append(
                    f"{card.get('product_id')}: " + "; ".join(
                        field_diffs(downloaded, by_id, limit=2)))
                if len(problems) >= 3:
                    break
    if problems:
        return False, "\n".join(problems)
    if not compared:
        return False, "the sample holds no card to compare the two paths over"
    return True, (f"all {compared} sampled products derive one row whichever "
                  f"path reaches them, because the payload names the set the "
                  f"product is filed under")


# -------------------------------------------------------------------- digimon

def every_id_is_the_sources_own_and_a_parallel_keeps_its_suffix(case):
    """The ids are the source's own, and a parallel stays a card of its own.

    The source names a printing once and both languages forward that name verbatim:
    BT8-022 is a card and BT5-007_P3 is a printing of BT5-007, and neither is
    synthesised from the other. The suffix is what keeps a parallel a separate row
    - a collector holds it, and it is a printing the base card does not have -
    while the oracle id, the same id with the suffix taken off, is what groups it
    with the card it is a version of. An id that dropped the suffix would store,
    would look unique, and would quietly merge two holdings into one; a game whose
    sample held no parallel would let that pass, so the parallels are counted
    rather than assumed - 106 of the sample's 553 cards are one.
    """
    provider = set()
    for envelope in (case.sample.get("cards") or {}).values():
        data = envelope.get("data") if isinstance(envelope, dict) else None
        card_id = digimon.slug_of(data, digimon.CARDS)
        if card_id:
            provider.add(card_id)
    if set(case.cards) != provider:
        invented = sorted(set(case.cards) - provider)[:3]
        dropped = sorted(provider - set(case.cards))[:3]
        return False, (f"the id set is not the source's: "
                       f"{len(set(case.cards) - provider)} ids the source does not "
                       f"publish ({invented}), {len(provider - set(case.cards))} of "
                       f"its own dropped ({dropped})")
    parallels = sorted(card_id for card_id in provider
                       if digimon.base_id_of(card_id) != card_id)
    if len(parallels) <= 100:
        return False, (f"the sample holds {len(parallels)} parallel(s), too few for "
                       f"a suffix that survives into the id to be a claim this "
                       f"sample can make")
    problems = []
    for card_id in parallels:
        row = case.cards[card_id]
        base = digimon.base_id_of(card_id)
        if row["oracle_id"] != base:
            problems.append(f"{card_id} groups under {row['oracle_id']!r} rather "
                            f"than the base card it is a version of, {base}")
        if row["id"] == row["oracle_id"]:
            problems.append(f"{card_id} was stored under its base card's id")
    if problems:
        return False, "\n".join(problems[:5])
    beside = [card_id for card_id in parallels
              if digimon.base_id_of(card_id) in case.cards]
    return True, (f"all {len(provider)} ids are the source's own, none synthesised "
                  f"and none dropped; {len(parallels)} of them are parallels that "
                  f"keep the suffix and group with their base card, {len(beside)} of "
                  f"them beside the base printing itself, e.g. {parallels[0]} beside "
                  f"{digimon.base_id_of(parallels[0])}")


def a_card_is_filed_under_the_release_it_names_first(case):
    """A card's set code is the first release its own record names.

    The source lists a card under every release that carries it and prints on the
    card the set it came from, and all three can differ: bt-08 lists BT5-007_P3
    whose number belongs to bt-05, bt-05 lists BT2-028_P1 whose number belongs to
    bt-02, and 142 of the game's cards are listed by two releases each - a premium
    parallel by its own promotion and by the binder set it was reprinted in.
    A row cannot follow the number ('BT1-010' names 'bt1', where the release that
    carries that family folds to 'bt0103v10'), and it cannot follow whichever walk
    found it either: a card is one row, so the release walked last would own it,
    the same card would move set when the source reordered its list, and a
    promotion listing 29 entries would hold no cards at all. So the card's own
    record decides, and this is the check that says so for every sampled card.
    """
    cards = case.sample.get("cards") or {}
    walk = digimon_walk(case.sample)

    # The two directions the sample holds, where the release is not the number.
    for card_id, release in (("BT5-007_P3", "bt08"), ("BT2-028_P1", "bt05")):
        rows = walk.get(card_id)
        if not rows or release not in rows:
            return False, (f"the sample no longer lists {card_id} under {release}, "
                           f"which is one of the two directions this check is about")
        row = rows[release]
        base = digimon.base_id_of(card_id)
        if row["set_code"] != release:
            return False, (f"{card_id} is stored under {row['set_code']!r} where its "
                           f"own record names {release} first")
        if base == card_id or row["oracle_id"] != base:
            return False, (f"{card_id} does not group with the base card it is a "
                           f"version of ({base})")

    # The card two sampled releases list: walked second, filed by its own record.
    shared = walk.get("P-058") or {}
    if set(shared) != {"p", "bt08"}:
        return False, ("the sample no longer lists P-058 under both p and bt-08, so "
                       "nothing here shows which release a card two walks disagree "
                       "about is filed under")
    if any(row["set_code"] != "p" for row in shared.values()):
        return False, ("P-058 is stored under "
                       f"{sorted({row['set_code'] for row in shared.values()})} where "
                       "its own record names p first")

    problems = []
    displaced = 0
    for card_id, rows in walk.items():
        envelope = cards.get(card_id) or {}
        named = digimon.releases_of(envelope.get("data") or {})
        owner = digimon.slug(named[0]) if named else None
        if owner is None:
            return False, (f"{card_id} names no release at all, and no set walk can "
                           f"reach such a card")
        printed = digimon_number_of(envelope)
        if digimon.code_of_number(printed) != owner:
            displaced += 1
        for code, row in rows.items():
            if row["set_code"] != owner:
                problems.append(f"{card_id} was walked as {code!r} and is stored "
                                f"under {row['set_code']!r} where its own record "
                                f"names {owner!r} first")
    if problems:
        return False, "\n".join(problems[:5])
    if displaced < 100:
        return False, (f"only {displaced} of the sampled cards print the number of a "
                       f"set other than the release they are filed under, too few to "
                       f"show the rule")
    return True, (f"all {len(walk)} sampled cards are filed under the first release "
                  f"their own record names, whichever walk found them - {displaced} "
                  f"of them under a release their printed number does not name, "
                  f"e.g. BT5-007_P3 under bt-08 and BT2-028_P1 under bt-05 - and "
                  f"P-058, which two sampled releases list, is filed under p")


def the_set_codes_are_folded_and_the_ids_keep_the_sources_spelling(case):
    """The code the catalogue stores is the spelling folded, and the spelling is kept.

    Codes.fold is what a card's set code is and what every read path of the app
    compares, so 'bt-05' is stored as 'bt05' - which is also what a card prints.
    The row keeps the source's own spelling in 'id' beside it, because that is what
    a request names and the two are not recoverable from each other: folding throws
    away the dash and the version numbering of 'bt01-03-v1-0', which folds to
    'bt0103v10'. 82 of the sample's 93 releases differ between the two, so a row
    that stored the spelling as the code, or the code as the spelling, is a
    disagreement this file reports rather than a request that 404s in a year.
    """
    envelope = case.sample.get("sets")
    published = set()
    for item in (envelope.get("included") if isinstance(envelope, dict) else None) or []:
        provider_code = digimon.slug_of(item, digimon.RELEASES)
        if provider_code:
            published.add(provider_code)
    problems = []
    spelled = 0
    for code, row in sorted(case.sets.items()):
        if row.get("id") not in published:
            problems.append(f"{code} keeps {row.get('id')!r}, which is not a release "
                            f"the source's set list carries")
        if digimon.slug(row.get("id")) != code:
            problems.append(f"{code} is stored as {row.get('id')!r}, which folds to "
                            f"{digimon.slug(row.get('id'))!r}")
        if code != row.get("id"):
            spelled += 1
    for slug in case.sample.get("sampled_sets") or []:
        if digimon.slug(slug) not in case.sets:
            problems.append(f"the sampled release {slug} folds to "
                            f"{digimon.slug(slug)}, which is not a code a set row "
                            f"was stored under")
    if problems:
        return False, "\n".join(problems[:5])
    if spelled < 50:
        return False, (f"only {spelled} of {len(case.sets)} set codes differ from the "
                       f"source's own spelling, so folding is nearly a no-op over "
                       f"this sample and the two spellings are barely told apart")
    return True, (f"all {len(case.sets)} sets store the folded code and keep the "
                  f"source's own spelling beside it; {spelled} of them differ between "
                  f"the two, e.g. 'bt-05' stored as bt05")


def the_art_is_the_sources_own_and_never_the_relays(case):
    """Every row's art is the source's own address, and never the relay's.

    Heroicc serves its images from https://images.heroi.cc, and that host sends no
    Access-Control-Allow-Origin - which is the property tcgcsv lacks and the whole
    reason Arcanum's relay exists. CardArt.host rewrites the address through the
    relay on a web build only, leaving the address a phone reads as the source's
    own, and the row the catalogue stores is that address: a row that already named
    the relay would be a row a phone could not load. The whole-row comparison above
    cannot catch it if both languages make the same mistake, so the rule is asserted
    over the committed rows rather than left to an agreement.
    """
    host = "https://images.heroi.cc/"
    relay = "/arcanumweb-api/"
    columns = ("image_small", "image_normal", "image_large", "image_art_crop",
               "image_png", "back_image_small", "back_image_normal")
    wrong = []
    arts = 0
    for card_id in sorted(case.cards):
        row = case.cards[card_id]
        for column in columns:
            url = row.get(column)
            if url is None:
                continue
            arts += 1
            if not isinstance(url, str) or url != url.strip():
                wrong.append(f"{card_id}: {column} is not a clean URL: {url!r}")
            elif relay in url or not url.startswith(host):
                wrong.append(f"{card_id}: {column} is not the source's own "
                             f"address: {url}")
    if wrong:
        return False, (f"{len(wrong)} art URL(s) the source does not serve:\n"
                       + "\n".join(wrong[:5]))
    if not arts:
        return False, ("no row carries art at all, so the address art is stored at "
                       "is untested here")
    return True, (f"all {arts} art URLs are the source's own, under {host}, and none "
                  f"names the relay ({relay})")


def the_by_id_path_derives_the_walks_row(case):
    """A card reached by its own envelope alone derives the row the walk derived.

    The client has two paths to a row - a set download, which hands a card the
    release it was reading, and a card fetched by its own id, which has only the
    card's own answer - and this is the branch where the release comes from that
    answer: the first release the card's own record names, with the set name read
    out of the release object embedded in the envelope's own 'included' array. The
    walk reaches every card of the sample and so does this pass, so every card is
    compared twice and the two rows have to be one.

    One card is the exception, and it is a fact about the sample rather than about
    either language: P-058 is listed by both 'p' and 'bt-08', so the walk derives
    two rows for it and the catalogue keeps the last one written, while a read by
    id can only name the first release the card's own record carries. That card is
    held to the walk's row for the release it does name, and every other card is
    held to the walk's row without qualification; the count of such cards is
    reported so that a re-cut sample cannot quietly make this check easier.
    """
    walk = digimon_walk(case.sample)
    problems = []
    compared = 0
    twice = 0
    for card_id, envelope in (case.sample.get("cards") or {}).items():
        by_id = digimon.card_document(envelope)
        if by_id is None:
            problems.append(f"{card_id} derives no row from its own envelope")
            continue
        rows = walk.get(card_id) or {}
        if not rows:
            problems.append(f"{card_id} is not listed by any sampled release")
            continue
        if len(rows) > 1:
            twice += 1
        expected = rows.get(by_id["set_code"])
        if expected is None:
            problems.append(f"{card_id} is reached by its own record as "
                            f"{by_id['set_code']!r}, which is not a release the "
                            f"sample lists it under ({sorted(rows)})")
            continue
        compared += 1
        if not same(expected, by_id):
            problems.append(f"{card_id}: " + "; ".join(field_diffs(expected, by_id)))
        if len(problems) >= 3:
            break
    if problems:
        return False, "\n".join(problems)
    return True, (f"all {compared} sampled cards derive the row the walk derived for "
                  f"them when reached by their own envelope alone; {twice} of them is "
                  f"listed by two sampled releases and is held to the row of the "
                  f"release its own record names")


# ------------------------------------------------------------------- the table
#
# One row per game. card_columns and set_columns name the columns of a row that
# game's importer actually derives: None means every column, which is only true
# where the catalogue importer exists and writes the whole row.

class Game:
    """One row of the table: the game, its sample, and what its importer derives."""

    def __init__(self, name, cards, sets, card_columns=None, set_columns=None,
                 checks=()):
        self.name = name
        self.cards = cards
        self.sets = sets
        self.card_columns = card_columns
        self.set_columns = set_columns
        self.checks = checks


GAMES = (
    Game("lorcana", lorcana_cards, lorcana_sets,
         checks=(every_id_is_the_providers_own, no_card_was_dropped,
                 layout_is_the_clients_empty_string)),
    # card_columns and set_columns are None, which means every column: the
    # Pokemon catalogue importer exists, so there is nothing left to excuse.
    Game("pokemon", pokemon_cards, pokemon_sets,
         checks=(every_id_is_the_providers_own, no_card_was_dropped,
                 the_set_responses_list_the_same_ids,
                 the_unaddressable_card_round_trips,
                 the_set_codes_are_the_folded_form_the_catalogue_stores,
                 every_art_url_carries_its_series)),
    Game("gundam", gundam_cards, gundam_sets,
         checks=(every_id_is_the_product_id_the_provider_publishes,
                 no_card_was_dropped,
                 the_art_variants_of_one_card_stay_apart,
                 the_two_paths_derive_one_row,
                 the_page_cap_is_exercised)),
    Game("swu", swu_cards, swu_sets,
         checks=(every_id_is_the_card_uid_the_publisher_publishes,
                 a_treatment_takes_its_base_cards_number,
                 the_landscape_art_is_drawn_from_the_other_face,
                 the_set_counts_are_base_printings)),
    # card_columns and set_columns are None here too, which means every column: the
    # Digimon importer exists and writes the whole row, like the Star Wars:
    # Unlimited one it is modelled on.
    Game("digimon", digimon_cards, digimon_sets,
         checks=(every_id_is_the_sources_own_and_a_parallel_keeps_its_suffix,
                 a_card_is_filed_under_the_release_it_names_first,
                 the_set_codes_are_folded_and_the_ids_keep_the_sources_spelling,
                 the_art_is_the_sources_own_and_never_the_relays,
                 the_by_id_path_derives_the_walks_row)),
    Game("yugioh", yugioh_cards, yugioh_sets,
         card_columns=("id", "set_code"), set_columns=("code",),
         checks=(every_id_begins_with_its_passcode, the_collision_rule_is_exercised,
                 the_punctuated_rarities_are_slugged)),
)


# --------------------------------------------------------------- the database

def check_the_committed_ids_are_in_the_database(args, cases):
    """The ids both languages derive, against the ids the catalogue holds.

    The checks above prove the two languages agree on a laptop; this proves the
    rows the database actually serves are the rows they agreed on, which is a
    different statement - an import that predates a rule change satisfies the
    first and fails this.

    It is the only part of this file that needs a database, so it is skipped,
    with the reason, when there is none: a skip is reported as a skip and never
    as a pass, and --require-db turns one into a failure for a run that was
    meant to check the database.
    """
    db_url = (os.environ.get("SUPABASE_DB_URL")
              or os.environ.get("SUPABASE_DB_URL_POOLED"))
    if not db_url:
        skip("the_committed_ids_are_in_the_catalogue",
             "no database URL in the environment (SUPABASE_DB_URL or "
             "SUPABASE_DB_URL_POOLED); everything above needs none")
        return
    try:
        store = catalog_store.CatalogStore(
            db_url, psql=args.psql or catalog_store.find_psql())
        held = store.query_json("select game, count(*) as rows from "
                                "public.catalog_cards group by game")
    except Exception as exc:  # noqa: BLE001 - a skip, with the reason printed
        skip("the_committed_ids_are_in_the_catalogue",
             f"the database could not be read: {exc}")
        return

    counts = {row["game"]: int(row["rows"]) for row in held}
    for case in cases:
        name = f"the_committed_ids_are_in_the_catalogue ({case.game})"
        if not counts.get(case.game):
            skip(name, f"the catalogue holds no {case.game} rows yet")
            continue
        try:
            rows = store.query_json(
                "select id from public.catalog_cards where game = "
                + catalog_store.sql_literal(case.game))
        except Exception as exc:  # noqa: BLE001 - a skip, with the reason printed
            skip(name, f"{case.game} could not be read: {exc}")
            continue
        ids = {row["id"] for row in rows}
        committed = set(case.client_cards)
        missing = sorted(committed - ids)
        if missing:
            bad(name, f"{len(missing)} of {len(committed)} committed ids are not "
                      f"rows the catalogue holds, e.g. {missing[:3]}")
        else:
            ok(name, f"all {len(committed)} committed ids are rows the catalogue "
                     f"holds, of {counts[case.game]} {case.game} rows")


def main():
    ap = argparse.ArgumentParser(
        description="the importer half of the catalogue id-parity test")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--require-db", action="store_true",
                    help="treat a skipped database check as a failure")
    ap.add_argument("--psql", default="", help="the psql to run, if not on PATH")
    args = ap.parse_args()

    if not os.path.exists(VECTORS):
        print(f"missing {VECTORS}", file=sys.stderr)
        return 2
    committed = read_gzip(VECTORS)
    blocks = {block.get("game"): block for block in committed.get("games", [])}

    cases = []
    for game in GAMES:
        block = blocks.get(game.name)
        if block is None:
            print(f"the committed vectors hold no block for {game.name}",
                  file=sys.stderr)
            return 2
        # The sample each game is asserted over is the one the vectors name, so
        # the two halves of this test cannot drift apart about which responses
        # they are comparing over.
        sample_path = os.path.join(REPO, str(block.get("sample") or ""))
        if not os.path.exists(sample_path):
            print(f"missing {sample_path}, which is the sample the committed "
                  f"vectors name for {game.name}", file=sys.stderr)
            return 2
        sample = read_gzip(sample_path)

        print(f"--- {game.name}: {len(block['cards'])} committed card rows, "
              f"{len(block['sets'])} set rows ---")
        print()
        case = Case(game.name, sample, game.cards(sample), game.sets(sample),
                    {row["id"]: row for row in block["cards"]},
                    {row["code"]: row for row in block["sets"]})
        cases.append(case)
        compare(f"{game.name}: importer_derives_the_clients_card_rows",
                case.cards, case.client_cards, game.card_columns, args.verbose)
        compare(f"{game.name}: importer_derives_the_clients_set_rows",
                case.sets, case.client_sets, game.set_columns, args.verbose)
        for check in game.checks:
            good, detail = check(case)
            (ok if good else bad)(f"{game.name}: {check.__name__}", detail)
        print()

    check_the_committed_ids_are_in_the_database(args, cases)

    failed = sum(1 for status, _, _ in RESULTS if status == "FAIL")
    passed = sum(1 for status, _, _ in RESULTS if status == "PASS")
    skipped = sum(1 for status, _, _ in RESULTS if status == "SKIP")
    print()
    print(f"{passed} passed, {failed} failed, {skipped} skipped")
    if skipped and args.require_db:
        print("a skip was treated as a failure because --require-db was given")
        failed += skipped
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())

