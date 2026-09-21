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

