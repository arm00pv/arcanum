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
of a row its importer actually derives, because two of the three games have no
catalogue importer yet and this file must not claim more than the code it runs:

  * lorcana - poll_lorcana_prices.card_document() and set_document(): every
    column of the row, because that importer exists and writes it. The ids here
    are forwarded from the provider.
  * pokemon - the id is the provider's own and both sides forward it; the
    derived columns beside it (oracle_id, collector_sort) are the shared Dart
    rules the importer already owns a mirror for, and are compared. Nothing else
    is claimed, because no Pokemon catalogue importer has been written yet.
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
    """The card ids one TCGdex set response lists, read the way the poller reads them.

    poll_pokemon_prices.card_ids_for_set() fetches the set and extracts the ids
    in one function, so the extraction - and only the extraction - is written out
    here. It is the importer's entire relationship with a Pokemon card id: the
    id the set response lists is the card_id every price is sampled under, and
    the card detail is fetched by that same id. There is no derivation to
    mirror, which is what the check below this states as a test.
    """
    if not isinstance(body, dict):
        return []
    return [c.get("id") for c in (body.get("cards") or [])
            if isinstance(c, dict) and c.get("id")]


def pokemon_cards(sample):
    """Every catalog_cards row the Pokemon importer would derive, keyed by its id.

    The id is the provider's own and is forwarded by both sides. The two columns
    beside it are derived, and both are shared Dart rules the importer already
    owns a mirror for: TcgCard.normaliseName fills oracle_id for Pokemon exactly
    as it does for Lorcana, and TcgCard.collectorNumberSortKey orders a shelf
    whose numbers are "4", "TG01", "SV001" and "H1" in one set. Those mirrors
    live in poll_lorcana_prices.py because Lorcana was the first game to need
    them; they are imported from there rather than transcribed a second time
    here, because a second transcription of one rule is the failure this file
    exists to catch.

    The set code is the third derived column: PokemonCatalog resolves it from
    the set the card belongs to rather than from the card's own id, and TCGdex
    publishes that set id on the card response.
    """
    mine = {}
    for card in sample["cards"]:
        if not isinstance(card, dict):
            continue
        card_id = card.get("id")
        if not isinstance(card_id, str) or not card_id:
            continue
        set_map = card.get("set") if isinstance(card.get("set"), dict) else {}
        number = "" if card.get("localId") is None else str(card.get("localId"))
        mine[card_id] = {
            "id": card_id,
            "oracle_id": lorcast.normalise_name(str(card.get("name") or "")),
            "collector_sort": lorcast.collector_sort_key(number),
            "set_code": str(set_map.get("id") or ""),
        }
    return mine


def pokemon_sets(sample):
    """Every catalog_sets row the client stores, keyed by its code.

    The code is the provider's own set id: PokemonCatalog builds the set's id
    and its code from the id TCGdex published, so nothing here is derived and
    the only column to hold the importer to is that one.
    """
    mine = {}
    for item in sample["sets"]:
        if not isinstance(item, dict):
            continue
        code = item.get("id")
        if not isinstance(code, str) or not code:
            continue
        mine[code] = {"code": code, "id": code}
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
    Game("pokemon", pokemon_cards, pokemon_sets,
         card_columns=("id", "oracle_id", "collector_sort", "set_code"),
         set_columns=("code", "id"),
         checks=(every_id_is_the_providers_own, no_card_was_dropped,
                 the_set_responses_list_the_same_ids)),
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

