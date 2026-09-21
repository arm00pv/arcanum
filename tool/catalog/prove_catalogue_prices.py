#!/usr/bin/env python3
"""Prove the price import against the live database.

Design: docs/catalogue-server-side.md, section 8 step 6, whose specification is
section 5. Step 1 proved a Lorcana catalogue and step 5 a Pokemon one; this
proves that both games now carry *current prices* in public.catalog_prices - the
rows the importers derive, keyed by the card ids the catalogue stores, dated by
the day the sweep sampled rather than by the moment the row was written, with no
zero among them and no row a client cannot resolve.

Written the way tool/catalog/prove_lorcana_import.py and
prove_pokemon_import.py are written, and for the same reason: the interesting
failures are invisible in the SQL that was supposed to produce them and obvious
in the database. A derivation that agrees with a committed sample on a laptop and
disagrees with the deployed table is a real failure mode, and only a check
against the deployed table finds it.

Two kinds of check, and no one check implies another:

| Check | Why it is not implied by the others |
| --- | --- |
| Both games hold prices and the other seven hold none | the write path is game-scoped, and a wrong game name writes nowhere |
| No stored price is zero or negative | section 5's oldest rule, and the one a provider's 0.00 breaks |
| Every price row resolves to a card of the same game | the import would report success for rows nothing can read |
| prices_revision moved and prices_observed_on is set | a run that wrote rows and moved nothing leaves every client stale |
| The rows equal the importer's derivation from the committed sample | a stale import satisfies every count above |
| No stored finish is a known finish spelled another way | the decision this step made about TCGdex's renamed variant |
| Each game stores the finishes and secondary figures section 5 names | a mapping that is merely plausible looks correct in the table |
| The replacement deletes one game and nothing else | the scoping is the only thing between an import and the other game's prices |
| The write path refuses to empty a game's prices | an empty provider sweep would otherwise delete the table it could not read |
| Re-offering the same night's rows writes nothing | idempotency is a claim about the second call, not the first |
| A second sweep on the same day duplicates and empties nothing | the same claim, driven end to end through the importer |
| The publishable key can read the prices | a browser reaches this through PostgREST, and a grant can be present while a policy is not |
| The account tables are unchanged | the thing every step of this design promises not to disturb |
| No probe rows are left behind | the test must not be the thing that damages the database |

One thing this file is careful about, because it is the difference between an
honest check and a decorative one: **a committed sample of provider responses
cannot be the expectation for a price.** lorcana_sample.json.gz and
pokemon_sample.json.gz hold the *provider's own* answers, cut on 2026-09-18, and
a price is volatile by definition - the table holds what was read last night.
So the committed sample supplies what it can still supply: the card ids, and the
raw shapes the derivation is driven from. The expectation itself is re-read from
the provider at proof time, with the importer's own functions, and compared with
the rows the database holds. Deriving instead from the three-day-old sample
would fail every run for a reason that has nothing to do with the code, which is
exactly what make_lorcana_sample.py warns about for the id vectors.

Credentials come from the environment, or from a file named with --env-file.
Nothing in this file holds a secret and the database URL is never printed.

    set -a; . /home/zixen/arcanum/supabase.env; set +a
    python3 tool/catalog/prove_catalogue_prices.py

--no-auth runs without the HTTP half. --skip-rerun does not re-run the Lorcana
importer, which is the slowest check and the one that proves idempotency end to
end. Exit status is 0 only if nothing failed.
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

TIMEOUT = 60

# The two games whose catalogues are on the server, and the source each one's
# prices come from - the value catalog_prices.source holds, which is also the
# value catalog_meta.source holds for these two games since the same sweep does
# both jobs.
GAMES = {
    "lorcana": "lorcast",
    "pokemon": "tcgdex",
}

# Section 5's table, per game: the finishes and the secondary figures the design
# says each game has. Nothing outside these sets may be stored except a finish
# this file reports as unrecognised - see check_finish_codes.
#
# Lorcana has no secondary figure at all, and that is a claim worth asserting
# rather than assuming: Lorcast quotes two decimal strings and nothing else.
DESIGN_CODES = {
    "lorcana": ({"nonfoil", "foil"}, set()),
    "pokemon": ({"nonfoil", "holofoil", "reverse_holofoil", "first_edition",
                 "first_edition_holofoil"}, {"eur", "eurLow"}),
}

# Every finish code the app can name, transcribed from the CardFinish enum in
# lib/core/theme/mana.dart. It is written out rather than taken from
# poll_pokemon_prices.FINISH_MAP because that map is one game's vocabulary and
# not the app's: Pokemon has no plain foil code, so a check built on it would
# call Lorcana's perfectly ordinary 'foil' an unrecognised finish - which is what
# its first run did. A CardFinish added to the Dart would have to be added here
# too, and until it is, a game quoting it is reported as unrecognised rather than
# passing silently, which is the failure direction that gets noticed.
APP_FINISH_CODES = frozenset({
    "nonfoil", "foil", "etched", "holofoil", "reverse_holofoil",
    "first_edition", "first_edition_holofoil",
})

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.dirname(HERE)
SAMPLES = {
    "lorcana": os.path.join(HERE, "lorcana_sample.json.gz"),
    "pokemon": os.path.join(HERE, "pokemon_sample.json.gz"),
}

# psql is told its connection through the environment rather than through its
# argv, so the password is not in a process listing. catalog_store owns that
# split and is the module the importer itself runs, so this proof uses it rather
# than keeping a second copy of a rule about credentials.
sys.path.insert(0, TOOL)
import catalog_store  # noqa: E402
import poll_lorcana_prices as lorcana  # noqa: E402
import poll_pokemon_prices as tcgdex  # noqa: E402

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


# ---------------------------------------------------------------------------
# SQL and HTTP, as the owner and as the publishable key
# ---------------------------------------------------------------------------


def session_url(db_url):
    """The session pooler, which is what the design names for admin work.

    The credentials file also carries the runtime transaction pooler on 6543,
    which the web service uses. Either answers these queries; the importer and
    this proof both use the session pooler so that what is being proved is the
    connection the nightly job actually makes.
    """
    return db_url.replace(":6543/", ":5432/"), ":6543/" in db_url


def psql(db_url, sql, want_json=False):
    """One script through psql, with ON_ERROR_STOP, reading JSON when asked."""

    # Adjacent string literals concatenate in Python; a line ending in a comma
    # instead turns the whole call into a tuple of fragments. psql cannot read
    # that and the error it raises points at subprocess rather than at the
    # missing quote, so a non-string is refused here, by name.
    if not isinstance(sql, str):
        raise TypeError(f"psql was handed {type(sql).__name__}, not one "
                        f"statement: {str(sql)[:200]}")
    if want_json:
        sql = f"select coalesce(json_agg(x), '[]'::json) from (\n{sql}\n) x;"
    proc = subprocess.run(
        ["psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c", sql],
        capture_output=True, text=True, timeout=TIMEOUT,
        env=catalog_store.psql_environment(db_url),
    )
    if proc.returncode != 0:
        raise RuntimeError(f"psql: {proc.stderr.strip()[:500]}")
    if want_json:
        return json.loads(proc.stdout.strip() or "[]")
    return [line.split("|") for line in proc.stdout.splitlines() if line != ""]


def store_for(db_url):
    """The importer's own write path, against the live database."""
    return catalog_store.CatalogStore(db_url, psql=catalog_store.find_psql())


def sql_text(value):
    """A Python string as a SQL literal. The same rule the importer uses."""
    return "'" + str(value).replace("'", "''") + "'"


def http_get(base, path, key):
    url = f"{base.rstrip('/')}/rest/v1/{path}"
    req = urllib.request.Request(url, headers={"apikey": key,
                                               "Accept": "application/json",
                                               "Prefer": "count=exact"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            body = resp.read().decode("utf-8", "replace")
            return resp.status, json.loads(body or "[]"), dict(resp.headers)
    except urllib.error.HTTPError as exc:
        return exc.code, None, dict(exc.headers or {})
    except urllib.error.URLError as exc:
        raise SystemExit(f"cannot reach {base}: {exc}")


# ---------------------------------------------------------------------------
# Reading the committed samples
# ---------------------------------------------------------------------------


def read_json_gz(path):
    with gzip.open(path, "rb") as fh:
        return json.loads(fh.read().decode("utf-8"))


def sample(game):
    """One game's committed sample of real provider responses."""
    path = SAMPLES[game]
    if not os.path.exists(path):
        raise SystemExit(f"missing {path}")
    return read_json_gz(path)


# ---------------------------------------------------------------------------
# The checks
# ---------------------------------------------------------------------------


def check_prices_are_stored(db_url):
    """Both catalogued games hold prices, and no other game holds anything.

    The seven games with no catalogue must hold no price rows: the foreign key
    would refuse a row for a card that is not stored, so a row there could only
    mean somebody had widened the table's key. The row counts are read rather
    than remembered, because prices are recomputed nightly and a number written
    down here would be wrong by morning.
    """
    rows = psql(db_url, (
        "select game, count(*), count(distinct card_id),"
        "       count(distinct observed_on),"
        "       count(distinct source), min(observed_on)::text, max(observed_on)::text"
        "  from public.catalog_prices group by game order by game"))
    by_game = {}
    for game, rows_n, cards, days, sources, first, last in rows:
        by_game[game] = {"rows": int(rows_n), "cards": int(cards),
                         "days": int(days), "sources": int(sources),
                         "first": first, "last": last}
    problems = []
    for game, source in GAMES.items():
        found = by_game.get(game)
        if not found:
            problems.append(f"{game} holds no price rows at all")
            continue
        if found["sources"] != 1:
            problems.append(f"{game} holds rows from {found['sources']} sources")
    stored = psql(db_url, (
        "select source, count(*) from public.catalog_prices"
        " group by source order by source"))
    for source, n in stored:
        if source not in GAMES.values():
            problems.append(f"{n} row(s) name source {source!r}, which is not one "
                            "of the two games this step writes")
    uncatalogued = psql(db_url, (
        "select count(*) from public.catalog_prices p"
        "  left join public.catalog_cards c on c.game = p.game and c.id = p.card_id"
        " where c.id is null"))
    if int(uncatalogued[0][0]):
        problems.append(f"{uncatalogued[0][0]} row(s) name a card the catalogue does "
                        "not hold")
    if problems:
        bad("both_catalogued_games_hold_prices_and_no_other_game_does",
            "\n".join(problems))
    else:
        detail = []
        for game in sorted(by_game):
            found = by_game[game]
            detail.append(
                f"{game}: {found['rows']:,} rows over {found['cards']:,} cards, "
                f"{found['days']} day(s), {found['first']}..{found['last']}")
        ok("both_catalogued_games_hold_prices_and_no_other_game_does",
           "\n".join(detail) + "\nand the seven games without a catalogue hold none")
    return by_game


def check_no_zero_prices(db_url):
    """A zero is not a price, and there is no such row anywhere.

    Section 5's rule, asserted on the table rather than trusted to the two
    readers: TCGdex quotes 0.00 for a printing with no market and Lorcast can
    send an empty string, and a stored zero would read as a real quote of
    nothing while an absent row already says unknown.
    """
    rows = psql(db_url, (
        "select game, count(*) filter (where price <= 0) as zero,"
        "       count(*) filter (where price is null) as nulls,"
        "       min(price) as cheapest, max(price) as dearest"
        "  from public.catalog_prices group by game order by game"))
    problems = []
    for game, zero, nulls, cheapest, dearest in rows:
        if int(zero) or int(nulls):
            problems.append(f"{game}: {zero} row(s) at or below zero, {nulls} null")
    if problems:
        bad("no_stored_price_is_zero", "\n".join(problems))
    else:
        summary = "; ".join(f"{g} {c}..{d}" for g, _, _, c, d in rows)
        ok("no_stored_price_is_zero",
           f"every price is strictly positive ({summary}), so a finish with no "
           "quote is an absent row rather than a zero")


def check_every_row_resolves(db_url):
    """Every price row names a card of the same game that the catalogue holds.

    The foreign key is supposed to make this impossible, and this checks the
    deployed constraint rather than the file that declared it. A price row whose
    card id belongs to the other game is the shape a game-scoped write bug takes,
    and a client asking for that id would be answered with a price for a card it
    cannot open.
    """
    rows = psql(db_url, (
        "select count(*) from public.catalog_prices p"
        "  left join public.catalog_cards c on c.game = p.game and c.id = p.card_id"
        " where c.id is null"))
    orphans = int(rows[0][0])
    crossed = psql(db_url, (
        "select count(*) from public.catalog_prices p"
        "  join public.catalog_cards c on c.id = p.card_id and c.game <> p.game"))
    crossed_n = int(crossed[0][0])
    if orphans or crossed_n:
        bad("every_price_row_resolves_to_a_card_of_the_same_game",
            f"{orphans} price row(s) name no stored card, {crossed_n} name a card "
            "stored under another game")
    else:
        rows = psql(db_url, "select count(*) from public.catalog_prices")
        ok("every_price_row_resolves_to_a_card_of_the_same_game",
           f"all {int(rows[0][0]):,} price rows join a catalog_cards row of the "
           "same game, so every price a client asks for resolves")


def check_revision_and_day(db_url):
    """prices_revision moved and prices_observed_on is the day on the rows.

    Two separate facts. A revision that never moved means no client is told to
    refetch, whatever the table holds; a day that is null, or older than the rows
    it describes, means the app would show a date that is not when the price was
    read - and observed_on being the *sampler's* day rather than the moment of the
    write is the whole point of the column.

    Rows *older* than the recorded day are reported rather than failed, and that
    line is deliberate. The replacement keeps a card's previous rows when the
    sweep could not read its set, so their older day is correct: they really were
    observed then. Calling that a failure would make this check fail on a night a
    provider hiccuped, which is the night it is most useful.
    """
    problems = []
    detail = []
    for game in GAMES:
        rows = psql(db_url, (
            "select prices_revision, to_char(prices_observed_on, 'YYYY-MM-DD'),"
            "       (select count(*) from public.catalog_prices where game = m.game),"
            "       (select max(observed_on)::text from public.catalog_prices"
            "         where game = m.game),"
            "       (select min(observed_on)::text from public.catalog_prices"
            "         where game = m.game),"
            "       (select count(*) from public.catalog_prices"
            "         where game = m.game and observed_on <> m.prices_observed_on)"
            "  from public.catalog_meta m"
            f" where game = {sql_text(game)}"))
        revision, observed, rows_n, newest, oldest, stale = rows[0]
        if int(revision) < 1:
            problems.append(f"{game}: prices_revision is {revision}")
        if not observed:
            problems.append(f"{game}: prices_observed_on is null")
        if not int(rows_n):
            problems.append(f"{game}: no rows to date")
        elif newest != observed:
            problems.append(f"{game}: the newest row is dated {newest} while "
                            f"catalog_meta says {observed}")
        line = (f"{game}: prices_revision {revision}, observed_on {observed}, "
                f"{rows_n} rows")
        if int(stale):
            line += (f", {stale} of them dated earlier (oldest {oldest}) - rows "
                     "kept from a set a later sweep could not read")
        else:
            line += ", every one of them dated that day"
        detail.append(line)
    if problems:
        bad("prices_revision_moved_and_the_day_is_recorded", "\n".join(problems))
    else:
        ok("prices_revision_moved_and_the_day_is_recorded", "\n".join(detail))


def lorcana_live_cards(sample_block):
    """The sampled Lorcana cards, re-read from Lorcast, keyed by id.

    Only the sets the sample actually holds cards from are requested: the sample
    reaches cards in most of the twenty-four, and a set the sample does not
    mention cannot contribute a card to the comparison.
    """
    wanted = {c["id"] for c in sample_block["cards"]
              if isinstance(c, dict) and isinstance(c.get("id"), str)}
    codes = sorted({c["set"]["code"] for c in sample_block["cards"]
                    if isinstance(c, dict) and isinstance(c.get("set"), dict)
                    and isinstance(c["set"].get("code"), str)})
    out = {}
    for code in codes:
        for card in lorcana.cards_for_set(code):
            card_id = card.get("id")
            if card_id in wanted:
                out[card_id] = card
    return out, len(codes)


def lorcana_derived(sample_block):
    """The price rows the importer derives for the sample's cards, live.

    Driven through the importer's own functions - card_documents and
    catalogue_price_rows - so that what is compared with the database is the
    importer's answer rather than a second implementation of it that agrees with
    the proof and not with the nightly job.
    """
    cards, sets_read = lorcana_live_cards(sample_block)
    sample_codes = sorted({c["set"]["code"].lower() for c in sample_block["cards"]
                           if isinstance(c, dict) and isinstance(c.get("set"), dict)
                           and isinstance(c["set"].get("code"), str)})
    by_set = {}
    for card in cards.values():
        embedded = card.get("set")
        code = embedded.get("code") if isinstance(embedded, dict) else None
        if isinstance(code, str):
            by_set.setdefault(code.lower(), []).append(card)
    rows = []
    for code in sorted(by_set):
        documents = lorcana.card_documents(by_set[code], code)
        rows.extend(lorcana.catalogue_price_rows(by_set[code], documents))
    return rows, {"cards": len(cards), "sets": sets_read,
                  "sample_sets": len(sample_codes)}


def pokemon_derived(sample_block):
    """The price rows the importer derives for the sample's cards, live.

    The sample holds a full TCGdex card object per sampled card, so the card is
    fetched by its own id exactly as the importer's sweep does, its row is built
    with card_document, and the price rows come off that row's id - which is what
    keeps a price under the id the catalogue stored.
    """
    ids = [c["id"] for c in sample_block["cards"]
           if isinstance(c, dict) and isinstance(c.get("id"), str)]
    results = tcgdex.fetch_cards(ids, 8)
    documents = {}
    for card_id, card, _error in results:
        if isinstance(card, dict):
            row = tcgdex.card_document(card, requested_id=card_id)
            if row is not None:
                documents[card_id] = row
    rows = tcgdex.catalogue_price_rows(results, documents)
    variant_keys = {}
    for _cid, card, _error in results:
        if not isinstance(card, dict):
            continue
        for key, value in ((card.get("pricing") or {}).get("tcgplayer") or {}).items():
            if isinstance(value, dict):
                variant_keys.setdefault(str(key), tcgdex.variant_finish([key]))
    return rows, {"cards": len(documents), "asked": len(ids),
                  "variants": variant_keys}


def check_derivation_matches_the_database(db_url, game):
    """The rows the table holds are the rows the importer derives, for the sample.

    The claim this whole step rests on, and the one a stale import fails while
    satisfying every count above. The comparison is exact on the whole key - card
    id, kind, code - and on the price, and it is asserted in both directions: a
    row the database holds that the derivation does not produce is as much a
    failure as a price that has moved, because the first says something else
    wrote the table and the second says the import did not run.

    observed_on is compared against catalog_meta rather than against the clock:
    the row must be dated the day the sweep that wrote it sampled, and a row
    carried over from a set a later sweep could not read keeps its own older day.
    """
    block = sample(game)
    if game == "lorcana":
        derived, notes = lorcana_derived(block)
    else:
        derived, notes = pokemon_derived(block)

    ids = sorted({row["card_id"] for row in derived})
    if not ids:
        skip(f"the_importers_own_derivation_matches_{game}_rows",
             "the sample derived no priced card at all, which would mean the "
             "provider quotes nothing for any sampled card")
        return
    array = "array[" + ", ".join(sql_text(i) for i in ids) + "]::text[]"
    live = psql(db_url, (
        "select card_id, kind, code, price::text as price, source,"
        "       to_char(observed_on, 'YYYY-MM-DD') as observed_on"
        "  from public.catalog_prices"
        f" where game = {sql_text(game)} and card_id = any ({array})"), want_json=True)

    derived_map = {(r["card_id"], r["kind"], r["code"]): r for r in derived}
    live_map = {(r["card_id"], r["kind"], r["code"]): r for r in live}
    observed = psql(db_url, (
        f"select to_char(prices_observed_on, 'YYYY-MM-DD') from public.catalog_meta"
        f" where game = {sql_text(game)}"))[0][0]

    problems = []
    for key, row in sorted(derived_map.items()):
        stored = live_map.get(key)
        if stored is None:
            problems.append(f"{key[0]} {key[1]} {key[2]}: the importer derives "
                            f"{row['price']} and the table holds no such row")
            continue
        want = catalog_store.price_text(row["price"])
        if catalog_store.price_text(stored["price"]) != want:
            problems.append(f"{key[0]} {key[1]} {key[2]}: table {stored['price']}, "
                            f"importer {want}")
        elif stored["observed_on"] > observed:
            problems.append(f"{key[0]}: observed_on {stored['observed_on']} is "
                            f"later than the game's {observed}")
        if len(problems) >= 6:
            break
    if not problems:
        for key, row in sorted(live_map.items()):
            if key not in derived_map:
                problems.append(f"{key[0]} {key[1]} {key[2]}: the table holds "
                                f"{row['price']} and the importer derives no such "
                                "row")
                if len(problems) >= 6:
                    break

    name = f"the_importers_own_derivation_matches_{game}_rows"
    if problems:
        bad(name, f"{game}: {len(problems)} difference(s) between the derivation "
                  f"and the table\n" + "\n".join(problems))
        return
    stale = [r for r in live if r["observed_on"] != observed]
    detail = (f"{len(derived_map):,} derived rows over {len(ids):,} sampled cards "
              f"equal the {len(live_map):,} the table holds, price and key for key "
              f"({notes.get('sets', notes.get('asked'))} source responses re-read)")
    if stale:
        detail += (f"\n{len(stale)} of them are dated earlier than {observed}, "
                   "which is a row kept from a set a later sweep could not read")
    if game == "pokemon":
        variants = notes.get("variants") or {}
        unknown = {k: v for k, v in variants.items() if not v[1]}
        seen = ", ".join(f"{k}->{v[0]}" for k, v in sorted(variants.items()))
        detail += f"\nprovider variant keys seen: {seen}"
        if unknown:
            detail += ("\nunrecognised (stored verbatim, and counted in the note): "
                       + ", ".join(sorted(unknown)))
    ok(name, detail)


def check_finish_codes(db_url):
    """No stored finish is a finish the app knows, spelled some other way.

    This is the decision this step made, asserted rather than described. TCGdex
    renamed a pricing variant - its payload now carries "reverse-holofoil" where
    this repository's FINISH_MAP and the Dart client both say "reverseholofoil" -
    and both used to drop the price in silence. The fix folds a key's case and
    punctuation before looking it up, so the renamed key lands on the app's own
    reverse_holofoil rather than being stored beside it as a second code for one
    physical printing.

    So: a stored code that folds onto a known CardFinish code must *be* that
    code. A code that folds onto nothing is the genuinely unknown variant, which
    section 5 stores verbatim; this check counts those and says so rather than
    failing, because storing one is the rule and dropping one is what the rule
    exists to prevent.
    """
    known = {tcgdex.variant_fold(code): code
             for code in sorted(APP_FINISH_CODES)}
    rows = psql(db_url, (
        "select game, code, count(*) from public.catalog_prices"
        " where kind = 'finish' group by game, code order by game, code"))
    problems = []
    unknown = {}
    for game, code, n in rows:
        target = known.get(tcgdex.variant_fold(code))
        if target and target != code:
            problems.append(f"{game}: {code!r} is {target!r} spelled another way "
                            f"({n} row(s))")
        elif not target:
            unknown.setdefault(game, []).append(f"{code!r} ({n} row(s))")
    if problems:
        bad("no_stored_finish_is_a_known_finish_respelled", "\n".join(problems))
    else:
        detail = ("no stored finish code is one of the app's own CardFinish "
                  "codes spelled another way (" + ", ".join(sorted(APP_FINISH_CODES))
                  + ")")
        if unknown:
            for game, codes in sorted(unknown.items()):
                detail += (f"\n{game} stores a finish the app cannot name, "
                           "verbatim as section 5 says: " + ", ".join(codes))
        else:
            detail += "\nno unrecognised variant is stored at all, so every price "
            detail += "in the table is one a screen can show"
        ok("no_stored_finish_is_a_known_finish_respelled", detail)


def check_design_codes(db_url):
    """Each game stores the finishes and secondary figures section 5 gives it.

    A mapping that is merely plausible looks right in the table, so the shape is
    asserted rather than the numbers: Lorcana is two finishes and no secondary
    figure, Pokemon is the five finishes and the two Cardmarket figures, and
    nothing else is present except a finish already reported as unrecognised.
    """
    problems = []
    detail = []
    for game, (finishes, secondary) in DESIGN_CODES.items():
        rows = psql(db_url, (
            "select kind, code, count(*) from public.catalog_prices"
            f" where game = {sql_text(game)} group by kind, code order by kind, code"))
        got_finishes = {c for k, c, _ in rows if k == "finish"}
        got_secondary = {c for k, c, _ in rows if k == "secondary"}
        # A finish the app cannot name is the one allowed extra: storing it
        # verbatim is section 5's rule, and the check above reports it by name.
        # What is left after dropping those is a finish the app *does* know
        # being used for a game the design does not give it.
        folded_known = {tcgdex.variant_fold(k) for k in APP_FINISH_CODES}
        extra_f = {c for c in got_finishes - finishes
                   if tcgdex.variant_fold(c) in folded_known}
        extra_s = got_secondary - secondary
        if extra_f:
            problems.append(f"{game} stores finish(es) the design does not give "
                            f"it: {sorted(extra_f)}")
        if extra_s:
            problems.append(f"{game} stores secondary figure(s) the design does "
                            f"not give it: {sorted(extra_s)}")
        detail.append(f"{game}: finishes {sorted(got_finishes)}, secondary "
                      f"{sorted(got_secondary) or 'none'}")
    if problems:
        bad("each_game_stores_the_codes_the_design_gives_it", "\n".join(problems))
    else:
        ok("each_game_stores_the_codes_the_design_gives_it", "\n".join(detail))


def check_replacement_is_scoped_to_one_game():
    """The generated replacement deletes one game's prices and nothing else.

    Read off the generator rather than the database, because "cannot touch the
    other game" is a claim about what may be emitted. The statement is produced
    by the same method the nightly run calls, in dry-run mode, so this inspects
    the SQL that would have run rather than a paraphrase of it.
    """
    dry = catalog_store.CatalogStore("postgres://unused", dry_run=True)
    sql = dry._price_transaction(
        "lorcana",
        [{"card_id": "probe-1", "kind": "finish", "code": "nonfoil",
          "price": "1.00", "source": "lorcast", "observed_on": "2026-01-01"}],
        "2026-01-01")
    problems = []
    deletes = re.findall(r"delete\s+from\s+([a-z_.]+)([^;]*)", sql, re.I)
    if len(deletes) != 1:
        problems.append(f"the replacement emits {len(deletes)} delete(s), "
                        "expected exactly one")
    for table, rest in deletes:
        if table.lower() != "public.catalog_prices":
            problems.append(f"it deletes from {table}")
        if f"where game = 'lorcana'" not in rest:
            problems.append(f"its delete is not scoped to one game: {rest.strip()[:80]}")
    if re.search(r"delete\s+from\s+public\.(catalog_sets|catalog_cards|catalog_meta)",
                 sql, re.I):
        problems.append("it deletes a catalogue table it does not own")
    if "begin;" not in sql or "commit;" not in sql:
        problems.append("the replacement is not one transaction")
    if "prices_revision = prices_revision + 1" not in sql:
        problems.append("it does not move prices_revision")
    if not re.search(r"insert into public\.catalog_prices", sql, re.I):
        problems.append("it inserts no rows")
    if problems:
        bad("the_replacement_is_scoped_to_one_game", "\n".join(problems))
    else:
        ok("the_replacement_is_scoped_to_one_game",
           "one delete, scoped to the game; one insert into catalog_prices; one "
           "revision bump; all inside one transaction, and no other table named "
           "by any statement")


def check_refuses_to_empty_a_game(db_url, by_game):
    """An empty sweep is refused rather than obeyed, and refuses before writing.

    The analogue of the card path's refusal to empty a set, and the reason it
    matters here is concrete: --skip-polled-today makes a second run of the same
    day derive nothing at all from the history path, and a replacement that
    obeyed an empty derivation would delete the whole game's prices on the
    strength of a run that read nothing. The refusal is reached before any
    statement runs, so the table is not at risk while this is checked.
    """
    store = store_for(db_url)
    problems = []
    for game in GAMES:
        if not by_game.get(game):
            continue
        try:
            store.replace_prices(game, [], "2000-01-01", GAMES[game])
        except catalog_store.CatalogError as exc:
            if "refusing to empty" not in str(exc):
                problems.append(f"{game}: refused for the wrong reason: {exc}")
        else:
            problems.append(f"{game}: an empty sweep was accepted and would have "
                            "deleted the game's prices")
    if problems:
        bad("an_empty_sweep_is_refused_rather_than_obeyed", "\n".join(problems))
    else:
        counts = psql(db_url, (
            "select game, count(*) from public.catalog_prices group by game"
            " order by game"))
        ok("an_empty_sweep_is_refused_rather_than_obeyed",
           "an empty row set is refused for both games before any statement runs; "
           "the table still holds " + ", ".join(f"{g} {n}" for g, n in counts))


def check_reoffering_the_same_night_writes_nothing(db_url, by_game):
    """The same night's rows, offered again, write nothing and move nothing.

    This is the idempotency claim in the form it can actually be made. A
    re-run of the *importer* re-reads the provider, and a price that moved in
    between is a fact about the market rather than a failure of the write path;
    what is deterministic - and what the nightly job depends on - is that
    offering the rows the table already holds, with the same sampler day,
    changes nothing: no write, no revision bump, no row lost. The comparison is
    the same fingerprint the write path itself uses, so this drives the real
    decision rather than a copy of it.
    """
    store = store_for(db_url)
    problems = []
    detail = []
    for game in GAMES:
        before = store.read_prices(game)
        if not before:
            problems.append(f"{game}: no rows to re-offer")
            continue
        revision_before = int(store.read_meta(game)["prices_revision"])
        observed = psql(db_url, (
            f"select to_char(prices_observed_on, 'YYYY-MM-DD') from public.catalog_meta"
            f" where game = {sql_text(game)}"))[0][0]
        # Each row carries its own day, because the table is not required to be
        # all one day: a card whose set a later sweep could not read keeps the
        # day it was actually read on. Re-offering that row with today's date
        # would be a different row and would be written, which is correct
        # behaviour and not what this check is about.
        rows = [{"card_id": r["card_id"], "kind": r["kind"], "code": r["code"],
                 "price": r["price"], "observed_on": r["observed_on"]}
                for r in before]
        summary = store.replace_prices(game, rows, observed, GAMES[game])
        after = store.read_prices(game)
        revision_after = int(store.read_meta(game)["prices_revision"])
        if summary["outcome"] != "unchanged":
            problems.append(f"{game}: re-offering the same {len(before)} rows "
                            f"reported {summary['outcome']!r}")
        if revision_after != revision_before:
            problems.append(f"{game}: prices_revision moved {revision_before} -> "
                            f"{revision_after} for an unchanged night")
        if catalog_store.price_fingerprint(before) != catalog_store.price_fingerprint(after):
            problems.append(f"{game}: the rows changed on an unchanged night")
        detail.append(f"{game}: {len(before):,} rows re-offered, nothing written, "
                      f"prices_revision still {revision_after}")
    if problems:
        bad("reoffering_the_same_night_writes_nothing", "\n".join(problems))
    else:
        ok("reoffering_the_same_night_writes_nothing", "\n".join(detail))


def check_a_set_the_sweep_could_not_read_keeps_its_prices(db_url):
    """A set a sweep could not read keeps the prices it had, in the real table.

    This is the one part of the write path a night with no failures never
    exercises: the replacement is a full replacement, so a plain
    `delete where game = ...` would delete the prices of a set whose provider
    response never arrived, and the carry-over is what stops it. Today's sweeps
    failed no set, so the branch has run on paper and nowhere else - which is not
    a thing to leave unproven, because it is the difference between one 503
    costing a set's prices for a night and costing them until the set is read
    again.

    The experiment is safe by construction: the row set offered is the table's own
    rows *with one set's rows taken out*, and that set is declared carry-over. The
    effective set is therefore the table exactly as it stands, the fingerprint
    matches, and the write path returns "unchanged" without running a statement -
    so a bug in the carry-over shows up as a write, and the write is the thing
    being tested rather than something the test does to production.
    """
    store = store_for(db_url)
    problems = []
    for game in GAMES:
        before = store.read_prices(game)
        if not before:
            problems.append(f"{game}: no rows to work with")
            continue
        picked = psql(db_url, (
            "select c.set_code, count(*) from public.catalog_prices p"
            "  join public.catalog_cards c on c.game = p.game and c.id = p.card_id"
            f" where p.game = {sql_text(game)}"
            " group by c.set_code order by count(*) desc, c.set_code limit 1"))
        set_code, set_rows = picked[0][0], int(picked[0][1])
        held = psql(db_url, (
            "select id from public.catalog_cards"
            f" where game = {sql_text(game)} and set_code = {sql_text(set_code)}"),
            want_json=True)
        in_set = {row["id"] for row in held}
        offered = [{"card_id": r["card_id"], "kind": r["kind"], "code": r["code"],
                    "price": r["price"], "observed_on": r["observed_on"]}
                   for r in before if r["card_id"] not in in_set]
        if len(offered) == len(before):
            problems.append(f"{game}: set {set_code!r} holds no price row, so this "
                            "check would prove nothing")
            continue
        observed = psql(db_url, (
            f"select to_char(prices_observed_on, 'YYYY-MM-DD') from public.catalog_meta"
            f" where game = {sql_text(game)}"))[0][0]
        revision = int(store.read_meta(game)["prices_revision"])
        summary = store.replace_prices(game, offered, observed, GAMES[game],
                                       carry_over_sets=[set_code])
        after = store.read_prices(game)
        if summary["outcome"] != "unchanged":
            problems.append(f"{game}: a sweep missing set {set_code!r} reported "
                            f"{summary['outcome']!r} and would have rewritten the "
                            "table instead of keeping the set's prices")
        if summary["carried"] != set_rows:
            problems.append(f"{game}: {summary['carried']} row(s) carried over, "
                            f"the set holds {set_rows}")
        if catalog_store.price_fingerprint(before) != catalog_store.price_fingerprint(after):
            problems.append(f"{game}: the table changed")
        if int(store.read_meta(game)["prices_revision"]) != revision:
            problems.append(f"{game}: prices_revision moved")
    if problems:
        bad("a_set_the_sweep_could_not_read_keeps_its_prices", "\n".join(problems))
    else:
        ok("a_set_the_sweep_could_not_read_keeps_its_prices",
           "offering the table's own rows with one set withdrawn, and naming that "
           "set as unread, is recognised as an unchanged night: the set's rows are "
           "carried over rather than deleted, and nothing is written")


def check_second_sweep(db_url, skip_rerun):
    """A second sweep on the same day duplicates and empties nothing.

    Driven end to end through the importer rather than through the store, so the
    whole path is exercised a second time: the sweep, the derivation, the
    carry-over bookkeeping and the write. Lorcana is the game this runs for,
    because twenty-four requests is a minute and Pokemon's 220 sets are not.

    What is asserted is structure - no row lost, no duplicate, no zero, the other
    game untouched - and what is *reported* is whether the revision moved. It may
    legitimately move: a price can change between two sweeps, and this check
    would be lying if it called that a failure. The write path's own idempotency
    is asserted by the check above.
    """
    if skip_rerun:
        skip("a_second_sweep_duplicates_and_empties_nothing", "not run: --skip-rerun")
        return

    poller = os.path.join(TOOL, "poll_lorcana_prices.py")
    if not os.path.exists(poller):
        skip("a_second_sweep_duplicates_and_empties_nothing",
             f"no importer at {poller}")
        return

    before = psql(db_url, (
        "select game, count(*), count(distinct card_id),"
        "       count(distinct (card_id, kind, code))"
        "  from public.catalog_prices group by game order by game"))
    revision_before = psql(db_url, (
        "select game, prices_revision from public.catalog_meta"
        " where game in ('lorcana', 'pokemon') order by game"))

    env = dict(os.environ)
    proc = subprocess.run(
        [sys.executable, poller, "--catalog", "--db", "/tmp/prove-prices-lorcana.db",
         "--lock", "/tmp/prove-prices-lorcana.lock"],
        capture_output=True, text=True, timeout=1800, env=env,
        cwd=os.path.dirname(poller))
    if proc.returncode != 0:
        bad("a_second_sweep_duplicates_and_empties_nothing",
            f"the second sweep exited {proc.returncode}: {proc.stderr.strip()[:300]}")
        return

    after = psql(db_url, (
        "select game, count(*), count(distinct card_id),"
        "       count(distinct (card_id, kind, code))"
        "  from public.catalog_prices group by game order by game"))
    revision_after = psql(db_url, (
        "select game, prices_revision from public.catalog_meta"
        " where game in ('lorcana', 'pokemon') order by game"))
    by_game_before = {g: int(n) for g, n, _, _ in before}
    by_game_after = {g: int(n) for g, n, _, _ in after}

    problems = []
    for (g, n, cards, keys), (g2, n2, cards2, keys2) in zip(before, after):
        if n != n2:
            problems.append(f"{g}: {n} rows became {n2}")
        if n != keys:
            problems.append(f"{g}: {n} rows but {keys} distinct keys")
        if cards != cards2:
            problems.append(f"{g}: {cards} priced cards became {cards2}")
    zeros = psql(db_url, (
        "select count(*) from public.catalog_prices where price <= 0"))
    if int(zeros[0][0]):
        problems.append(f"{zeros[0][0]} zero price(s) after the second sweep")
    pokemon_before = dict(revision_before).get("pokemon")
    pokemon_after = dict(revision_after).get("pokemon")
    if pokemon_before != pokemon_after:
        problems.append("a Lorcana sweep moved Pokemon's prices_revision")
    name = "a_second_sweep_duplicates_and_empties_nothing"
    if problems:
        bad(name, "\n".join(problems))
        return
    moved = dict(revision_after).get("lorcana") != dict(revision_before).get("lorcana")
    detail = (f"a second Lorcana sweep left {by_game_after.get('lorcana', 0):,} rows "
              f"over {sum(int(c) for g, _, c, _ in after if g == 'lorcana'):,} cards, "
              f"with no duplicate and no zero")
    if moved:
        detail += ("\nLorcana's prices_revision moved, so at least one price changed "
                   "between the two sweeps; that is the market, not the write path")
    else:
        detail += "\nLorcana's prices_revision did not move: the same day's sweep "
        detail += "derived exactly the rows already stored"
    ok(name, detail)


def check_http(base, key):
    """The publishable key reads the prices, which is how a browser reaches them."""
    status, body, headers = http_get(
        base, "catalog_prices?game=eq.lorcana&select=card_id,kind,code,price,"
              "observed_on&limit=5", key)
    if status not in (200, 206) or not isinstance(body, list) or not body:
        bad("publishable_key_reads_the_prices", f"catalog_prices answered HTTP "
                                                f"{status} with {body!r}")
        return
    row = body[0]
    missing = [c for c in ("card_id", "kind", "code", "price", "observed_on")
               if c not in row]
    if missing:
        bad("publishable_key_reads_the_prices",
            f"a row read through PostgREST is missing {missing}")
        return
    status, _body, headers = http_get(
        base, "catalog_prices?game=eq.pokemon&select=card_id&limit=1", key)
    range_header = headers.get("Content-Range", "")
    ok("publishable_key_reads_the_prices",
       f"anon reads a Lorcana price row ({row['code']} {row['price']} observed "
       f"{row['observed_on']}); Pokemon range {range_header or 'not reported'}")


def check_account_tables(db_url, before):
    rows = psql(db_url, (
        "select (select count(*) from public.decks),"
        "       (select count(*) from public.collection_entries)"))
    decks, entries = (int(v) for v in rows[0])
    if (decks, entries) != before:
        bad("account_tables_are_unchanged",
            f"decks/collection_entries went from {before} to {(decks, entries)}")
    else:
        ok("account_tables_are_unchanged",
           f"decks {decks}, collection_entries {entries}, exactly as before the run")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env-file", default=None)
    ap.add_argument("--no-auth", action="store_true", help="skip the HTTP half")
    ap.add_argument("--skip-rerun", action="store_true",
                    help="do not re-run the Lorcana importer")
    args = ap.parse_args()

    if args.env_file:
        with open(args.env_file, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    os.environ.setdefault(key.strip(), value.strip())

    db_url = os.environ.get("SUPABASE_DB_URL") or os.environ.get("SUPABASE_DB_URL_POOLED")
    if not db_url or not shutil.which("psql"):
        print("this proof needs psql and a database URL; neither is optional here",
              file=sys.stderr)
        return 2
    db_url, _was_pooled = session_url(db_url)

    for path in SAMPLES.values():
        if not os.path.exists(path):
            print(f"missing {path}", file=sys.stderr)
            return 2

    # The account tables first: if the import damaged them, that should be the
    # headline rather than a line at the bottom.
    rows = psql(db_url, (
        "select (select count(*) from public.decks),"
        "       (select count(*) from public.collection_entries)"))
    accounts_before = tuple(int(v) for v in rows[0])

    print("--- the table, as the owner ---")
    by_game = check_prices_are_stored(db_url)
    if not any(by_game.get(game) for game in GAMES):
        print()
        print("no prices are stored for either game; run the importers first")
        return 1

    check_no_zero_prices(db_url)
    check_every_row_resolves(db_url)
    check_revision_and_day(db_url)
    check_design_codes(db_url)
    check_finish_codes(db_url)

    print()
    print("--- the derivation, against the provider ---")
    for game in sorted(GAMES):
        check_derivation_matches_the_database(db_url, game)

    print()
    print("--- the write path ---")
    check_replacement_is_scoped_to_one_game()
    check_refuses_to_empty_a_game(db_url, by_game)
    check_reoffering_the_same_night_writes_nothing(db_url, by_game)
    check_a_set_the_sweep_could_not_read_keeps_its_prices(db_url)

    if not args.no_auth:
        base = os.environ.get("SUPABASE_URL")
        key = os.environ.get("SUPABASE_PUBLISHABLE_KEY")
        print()
        print("--- HTTP, as the publishable key ---")
        if not base or not key:
            skip("publishable_key_reads_the_prices",
                 "SUPABASE_URL or SUPABASE_PUBLISHABLE_KEY is not set")
        else:
            check_http(base, key)

    print()
    print("--- a second sweep on the same day ---")
    check_second_sweep(db_url, args.skip_rerun)

    print()
    print("--- nothing left behind ---")
    check_account_tables(db_url, accounts_before)
    rows = psql(db_url, (
        "select count(*) from public.catalog_sets where game like 'zz%'"))
    if int(rows[0][0]):
        bad("no_probe_rows_left_behind", f"{rows[0][0]} probe set(s) remain")
    else:
        ok("no_probe_rows_left_behind",
           "no probe rows in the catalogue, and the account tables hold what "
           "they held")

    failed = sum(1 for status, _, _ in RESULTS if status == "FAIL")
    passed = sum(1 for status, _, _ in RESULTS if status == "PASS")
    skipped = sum(1 for status, _, _ in RESULTS if status == "SKIP")
    print()
    print(f"{passed} passed, {failed} failed, {skipped} skipped")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
