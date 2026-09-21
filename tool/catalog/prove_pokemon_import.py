#!/usr/bin/env python3
"""Prove the Pokemon import against the live database.

Design: docs/catalogue-server-side.md, section 8 step 5. Step 1 proved the
machinery on Lorcana; this proves a second game through the same machinery, at
an order of magnitude more rows and with the derivation the design calls the
sharpest edge. The claim is that Pokemon - 218 sets and every card in them - is
held on the server, that the rows there are exactly the rows the Dart client
would have derived itself, that re-running the importer changes nothing, and
that the importer cannot damage anything it does not own.

Written the way tool/catalog/prove_lorcana_import.py is written, and for the
same reason: the interesting failures are invisible in the SQL that was supposed
to produce them and obvious in the database.

Three things are Pokemon's own rather than a repeat of Lorcana's proof.

**The rows are compared against the importer's mapping, not against a
constant.** Every sampled card is put through poll_pokemon_prices.card_document
and poll_pokemon_prices.set_document - the functions the nightly import runs -
and the result is compared with the live table column by column. Those functions
are also what tool/catalog/test_id_parity.py asserts against the committed Dart
vectors, so the three cannot drift apart: this file imports the parity test's
own driver rather than keeping a second copy of it.

**Every column of every sampled card is compared, with nothing carved out.**
The committed sample holds five set responses and 323 cards, and 40 of those
cards belong to sets the sample reaches by id alone. The client derives two
different rows for such a card depending on which path it takes - a set download
carries the set's release date and an art URL with the series segment in it, a
card reached by id carries neither - and the committed Dart vectors record the
by-id row for those 40. The deployed import walks every set, so it wrote the set
walk's row, and this proof derives that row: the set responses the sample is
missing are fetched from the provider, from the same endpoint the importer read.
The first version of this file did not, and its first run failed on exactly
those rows - a release date and an art URL per card - which is the difference
between deriving what the importer derived and deriving what the client's other
path would have.

**The tombstone rule is exercised, not just read.** Lorcana's proof reads the
write path and rolls a retirement back by hand. Here the importer's own
retire_sets is called for real with one set missing from the upstream list, and
then called again with the full list: the set is hidden, its row and its cards
are still there, and it comes back.

Credentials come from the environment, or from a file named with --env-file.
Nothing in this file holds a secret and the database URL is never printed.

    set -a; . /home/zixen/arcanum/supabase.env; set +a
    python3 tool/catalog/prove_pokemon_import.py

--no-auth runs without the HTTP half. --skip-rerun does not re-run the importer,
which is the check that proves the checksum skip. Exit status is 0 only if
nothing failed.
"""

from __future__ import annotations

import argparse
import contextlib
import gzip
import io
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

TIMEOUT = 60
GAME = "pokemon"
PROVIDER = "https://api.tcgdex.net/v2/en"
CATALOG_TABLES = ("catalog_sets", "catalog_cards", "catalog_prices", "catalog_meta")

# The five sets the committed sample holds whole, which is the set the re-run
# check imports a second time. Named rather than derived so that the second run
# is the same second run every time it is made.
SAMPLE_SETS = ("base1", "swsh9tg", "swsh4.5sv", "exu", "miscp")

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.dirname(HERE)
VECTORS = os.path.join(HERE, "catalog_id_vectors.json.gz")
SAMPLE = os.path.join(HERE, "pokemon_sample.json.gz")

# psql is told its connection through the environment rather than through its
# argv, so the password is not in a process listing. catalog_store owns that
# split and is the module the importer itself runs, so this proof uses it rather
# than keeping a second copy of a rule about credentials.
#
# test_id_parity is imported for its driver: the rows this proof compares with
# the database are the rows that test asserts against the committed Dart
# vectors, from one implementation rather than two.
sys.path.insert(0, TOOL)
sys.path.insert(0, HERE)
import catalog_store  # noqa: E402
import poll_pokemon_prices as tcgdex  # noqa: E402
import test_id_parity  # noqa: E402

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
# SQL, as the owner
# ---------------------------------------------------------------------------


def session_url(db_url):
    """The session pooler, which is what the design names for admin work."""
    return db_url.replace(":6543/", ":5432/"), ":6543/" in db_url


def psql(db_url, sql, want_json=False):
    """One script through psql, with ON_ERROR_STOP, reading JSON when asked.

    The JSON form is used for anything that reads card text: a card's rules text
    contains pipes, tabs and newlines, and the pipe-separated text protocol
    would turn any of them into a column boundary.
    """
    if not isinstance(sql, str):
        raise TypeError(f"psql was handed {type(sql).__name__}, not one "
                        f"statement: {str(sql)[:200]}")
    if want_json:
        sql = f"select coalesce(json_agg(x), '[]'::json) from (\n{sql}\n) x;"
    proc = subprocess.run(
        ["psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
         "-c", sql],
        capture_output=True, text=True, timeout=TIMEOUT,
        env=catalog_store.psql_environment(db_url),
    )
    if proc.returncode != 0:
        raise RuntimeError(f"psql: {proc.stderr.strip()[:500]}")
    if want_json:
        return json.loads(proc.stdout.strip() or "[]")
    return [line.split("|") for line in proc.stdout.splitlines() if line != ""]


def sql_text(value):
    """A Python string as a SQL literal. The same rule the importer uses."""
    return "'" + str(value).replace("'", "''") + "'"


def http_get(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {
        "Accept": "application/json",
        "User-Agent": "Arcanum/1.0 (+https://github.com/arcanum)"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            body = resp.read().decode("utf-8", "replace")
            return resp.status, json.loads(body or "null"), dict(resp.headers)
    except urllib.error.HTTPError as exc:
        return exc.code, None, dict(exc.headers or {})


def postgrest_get(base, path, key):
    return http_get(f"{base.rstrip('/')}/rest/v1/{path}",
                    {"apikey": key, "Accept": "application/json",
                     "Prefer": "count=exact"})


# ---------------------------------------------------------------------------
# Reading the committed sample
# ---------------------------------------------------------------------------


def read_json_gz(path):
    with gzip.open(path, "rb") as fh:
        return json.loads(fh.read().decode("utf-8"))


class ProviderView:
    """The parts of the provider's answer the committed sample does not hold.

    The sample cuts five sets whole and reaches 40 of its 323 cards by id alone.
    A card row needs its set: the release date, the set name and the series slug
    the art URL is built from all come from the set's own response. The deployed
    import walks every set and therefore had them; a derivation from the sample
    alone does not have them, and the first run of this proof compared those 40
    rows against a row shape the database never held. So the missing set
    responses are fetched here, from the same endpoint and by the same function
    the importer reads them with.

    Each set is fetched once, and a failure is remembered rather than retried:
    the caller reports which rows it could not derive instead of failing a
    database check for a network reason.
    """

    def __init__(self):
        self._listing = None
        self._details = {}
        self._errors = {}

    def _listed(self):
        if self._listing is None:
            try:
                self._listing = {item["id"]: item for item in tcgdex.set_list()}
            except Exception as exc:  # noqa: BLE001 - the caller reports it
                self._listing = {}
        return self._listing

    def context(self, set_id):
        """The (list entry, set response) pair for one set, or (None, None).

        None means the provider could not be read for that set, and reason()
        says why. The list entry may still be None while the response is not: it
        is only the source of the card count the list publishes, which no card
        row reads.
        """
        if set_id not in self._details and set_id not in self._errors:
            try:
                self._details[set_id] = tcgdex.set_detail(set_id)
            except Exception as exc:  # noqa: BLE001 - the caller reports it
                self._errors[set_id] = str(exc)
        if set_id in self._errors:
            return None, None
        return self._listed().get(set_id), self._details[set_id]

    def reason(self, set_id):
        """Why one set could not be read, for a report that names the cause."""
        return self._errors.get(set_id)


def sampled_cards():
    """The committed sample's full card objects, keyed by id."""
    sample = read_json_gz(SAMPLE)
    cards = {}
    for card in sample["cards"]:
        if isinstance(card, dict) and isinstance(card.get("id"), str):
            cards[card["id"]] = card
    return cards


def derived_rows(provider):
    """The rows the importer derives for the sample: (rows, unavailable, sampled).

    Every row is built by poll_pokemon_prices.set_document and card_document -
    the functions the nightly import runs - from the sample's own set responses
    where it holds them and from the provider's set response where it does not,
    which is where the import got them too. unavailable maps a card id to the
    reason its row could not be derived, and happens only when a set response
    could not be read.

    test_id_parity.pokemon_cards is deliberately not the driver here. That
    function answers a different question - "what rows do the two languages
    derive from these responses" - and for the 40 cards the sample reaches by id
    it derives the client's by-id row, which carries no release date and an art
    URL without the series segment. The database holds the set walk's row,
    because the set walk is the path the importer takes. Comparing the one
    against the other was this file's first bug; the fix is to derive what the
    importer derived rather than to carve the difference out of the comparison.
    The parity test still uses its own driver for those 40 cards, correctly:
    the committed Dart vectors hold the by-id row, and that is the row it
    asserts the importer's functions reproduce.

    One card is stored through the importer's fallback branch rather than from
    its payload: "exu-%3F" cannot be addressed as a path segment by the client,
    so the importer asks for it the way the client does, gets the same 404 and
    stores the row the client stores. test_id_parity.client_addressable_id is
    that rule, imported rather than written a second time.
    """
    cards = sampled_cards()
    contexts = {}
    for item, body in test_id_parity.pokemon_set_downloads(read_json_gz(SAMPLE)):
        contexts[item["id"]] = (item, body)

    rows = {}
    unavailable = {}
    for card_id, card in cards.items():
        embedded = card.get("set")
        set_id = embedded.get("id") if isinstance(embedded, dict) else None
        if set_id in contexts:
            item, body = contexts[set_id]
        else:
            item, body = provider.context(set_id)
            if body is None:
                unavailable[card_id] = (f"the response for set {set_id!r} could "
                                        f"not be read: {provider.reason(set_id)}")
                continue
        set_doc = tcgdex.set_document(item, body)
        serie = tcgdex.serie_id(body)
        stub = None
        for candidate in tcgdex.stubs_of(body):
            if candidate.get("id") == card_id:
                stub = candidate
                break
        if test_id_parity.client_addressable_id(card_id) != card_id:
            row = tcgdex.card_document(None, set_doc=set_doc, stub=stub, serie=serie)
        else:
            row = tcgdex.card_document(card, set_doc=set_doc, stub=stub, serie=serie)
        if row is not None:
            rows[row["id"]] = row
    return rows, unavailable, set(cards)


def vectors_card_columns():
    """The columns of a card row, taken from the committed vectors.

    Read from the file rather than typed here so that a column added to the row
    shape is compared without this file being edited, and so that this proof and
    the parity test agree about what a row is.
    """
    blocks = read_json_gz(VECTORS).get("games", [])
    for block in blocks:
        if block.get("game") == GAME:
            return [column for column in block["cards"][0] if column != "id"]
    raise SystemExit(f"{VECTORS} holds no {GAME} block")


# ---------------------------------------------------------------------------
# The checks
# ---------------------------------------------------------------------------


def provider_set_count():
    """How many sets TCGdex publishes right now, or None when unreachable.

    The count is asked for rather than remembered. A constant written down here
    would fail the day the publisher adds a set - a false alarm - and would pass
    for an import that stored 218 sets thinly, which is the failure that
    matters; the structural checks below are what catch that one, and this is
    what catches a set list that was cut short.
    """
    try:
        status, body, _ = http_get(f"{PROVIDER}/sets")
    except Exception as exc:  # noqa: BLE001 - reported as a skip, with the reason
        return None, str(exc)
    if status != 200 or not isinstance(body, list):
        return None, f"TCGdex answered HTTP {status}"
    return len([s for s in body if isinstance(s, dict) and s.get("id")]), None


def provider_card_entries(set_ids):
    """How many card entries the provider's own response lists for each set.

    Returns (counts, error). Only ever asked for the sets the catalogue holds
    empty, which is four of them: the provider's own response is the only thing
    that can say whether an empty set is the provider's answer or a
    half-imported one. A set TCGdex cannot be asked about is reported as an
    error rather than guessed at.
    """
    counts = {}
    for set_id in set_ids:
        try:
            status, body, _ = http_get(f"{PROVIDER}/sets/{set_id}")
        except Exception as exc:  # noqa: BLE001 - reported, with the reason
            return {}, str(exc)
        if status != 200 or not isinstance(body, dict):
            return {}, f"TCGdex answered HTTP {status} for set {set_id!r}"
        entries = body.get("cards")
        counts[set_id] = len(entries) if isinstance(entries, list) else 0
    return counts, None


def check_counts(db_url, provider_sets):
    """What is stored is complete, and a set list a client can act on.

    The card total is deliberately not compared against a number written down
    here, for the reason provider_set_count gives. What is checked instead is the
    structure: no set is retired, and every set's own card_row_count agrees with
    the rows actually present. A set that was half-imported fails the last of
    those.

    A set stored with no cards is deliberately NOT a failure here, and the check
    that used to make it one was wrong. Four sets TCGdex publishes - jumbo,
    rc, sp and wp - answer with an empty card list while still carrying a
    published card count; a browser learns a set's cards from that response and
    from nowhere else, so the client stores nothing for them and neither does
    the catalogue. Whether an empty set is the provider's answer or a
    half-imported set is asked of the provider by name in
    check_sets_stored_empty_are_the_providers_own_empty_sets.
    """
    rows = psql(db_url, (
        f"select (select count(*) from public.catalog_sets where game = {sql_text(GAME)}),"
        f"       (select count(*) from public.catalog_cards where game = {sql_text(GAME)}),"
        f"       (select count(*) from public.catalog_sets where game = {sql_text(GAME)}"
        "          and retired_at is not null)"))
    sets, cards, retired = (int(v) for v in rows[0])

    problems = []
    if provider_sets is not None and sets != provider_sets:
        problems.append(f"{sets} sets stored, TCGdex publishes {provider_sets}")
    if retired:
        problems.append(f"{retired} set(s) retired; the provider publishes every one")

    rows = psql(db_url, (
        "select s.code, s.card_row_count, count(c.id)"
        "  from public.catalog_sets s"
        "  left join public.catalog_cards c on c.game = s.game and c.set_code = s.code"
        f" where s.game = {sql_text(GAME)}"
        " group by s.code, s.card_row_count"
        " having s.card_row_count <> count(c.id) order by s.code"))
    for code, claimed, actual in rows:
        problems.append(f"set {code!r} records {claimed} cards and holds {actual}")

    if problems:
        bad("counts_match_the_provider", "\n".join(problems[:6]))
    else:
        compared = (f"{sets} sets, TCGdex publishes the same {provider_sets}"
                    if provider_sets is not None else
                    f"{sets} sets (the provider's own count was not read)")
        ok("counts_match_the_provider",
           f"{compared}, none retired, and every set's recorded card count "
           f"matches its rows: {cards:,} cards")
    return sets, cards


def check_sets_stored_empty_are_the_providers_own_empty_sets(db_url):
    """A set the catalogue holds with no cards is a set whose response lists none.

    Four sets TCGdex publishes answer with an empty card list while still
    carrying a published card count - jumbo (Jumbo cards, 160), rc (Radiant
    Collection, 25), sp (Sample, 10) and wp (W Promotional, 7) - and a browser
    learns a set's cards from that response and from nowhere else, so the client
    stores nothing for them and so does the catalogue. Lorcana's proof asserts
    "no set was stored empty", which is right where Lorcast publishes no such
    set, and it fails on a correct Pokemon catalogue; the claim asserted here
    instead is the true one, set by set and against the provider rather than
    against a rule of thumb: every set stored with no cards is a set the
    provider's own response lists no cards for, and one that the provider was
    actually asked about. A set the provider lists cards for and the catalogue
    holds empty is still a failure, and is what a half-imported set looks like.
    """
    rows = psql(db_url, (
        "select code, id, name, card_count, catalogued_at is not null as asked"
        f"  from public.catalog_sets where game = {sql_text(GAME)}"
        " and card_row_count = 0 order by code"), want_json=True)
    if not rows:
        ok("sets_stored_empty_are_the_providers_own_empty_sets",
           "no set is stored with no cards at all")
        return

    counts, error = provider_card_entries([row["id"] for row in rows])
    if error:
        skip("sets_stored_empty_are_the_providers_own_empty_sets",
             f"{len(rows)} set(s) are stored with no cards and TCGdex cannot be "
             f"asked whether that is its own answer: {error}")
        return

    problems = []
    confirmed = []
    for row in rows:
        entries = counts.get(row["id"], 0)
        if entries:
            problems.append(f"{row['code']!r} ({row['name']}) holds no cards and "
                            f"TCGdex lists {entries} in its own response for it")
        elif not row["asked"]:
            problems.append(f"{row['code']!r} ({row['name']}) holds no cards and "
                            "was never catalogued, so the provider was never asked")
        else:
            confirmed.append(f"{row['code']} ({row['name']}, which TCGdex "
                             f"publishes a count of {row['card_count']} for)")
    if problems:
        bad("sets_stored_empty_are_the_providers_own_empty_sets",
            "\n".join(problems))
    else:
        ok("sets_stored_empty_are_the_providers_own_empty_sets",
           f"{len(confirmed)} set(s) are stored with no cards because TCGdex "
           f"lists no cards in its own response for them: " + ", ".join(confirmed))


def check_orphans(db_url):
    rows = psql(db_url, (
        "select count(*) from public.catalog_cards c"
        "  left join public.catalog_sets s on s.game = c.game and s.code = c.set_code"
        " where s.code is null"))
    orphans = int(rows[0][0])
    if orphans:
        bad("every_card_belongs_to_a_stored_set",
            f"{orphans} card rows name a set that is not in catalog_sets")
    else:
        ok("every_card_belongs_to_a_stored_set",
           "no card row names a set that is not stored, so every holding resolves")


def check_set_codes_are_stored_form(db_url):
    """The stored code is the provider's id folded, which is what retirement compares to.

    Pokemon is where this rule stops being theoretical. Fifteen of the 220 set
    ids TCGdex publishes are not lower case - the Pokemon TCG Pocket sets A1,
    A1a, A2 ... B2a and the promos P-A - so the code the catalogue stores and
    the id the provider publishes genuinely differ for those sets, and the
    importer folds on purpose. Two things follow, and both are asserted.

    Every stored code is its id folded. A row that kept the provider's spelling
    is a set the client can never mark as catalogued, because it lower-cases
    every set code it queries with; the argument is in
    poll_pokemon_prices.set_document.

    And the folding is not vacuous - some stored code really is not its id -
    which is what makes the retirement spelling matter: retire_sets is handed
    the folded list, and handing it the provider's spelling instead would retire
    all fifteen of those sets on every run. The counts check above is where that
    would show up, since a retired set is one the provider still publishes. Both
    numbers are printed, so a day when the folding became a no-op says so.
    """
    rows = psql(db_url, (
        "select count(*) filter (where code <> lower(id)) as unfolded,"
        "       count(*) filter (where code <> id) as folded_from_a_different_id,"
        "       count(*) as total"
        f"  from public.catalog_sets where game = {sql_text(GAME)}"), want_json=True)
    row = rows[0]
    unfolded = int(row["unfolded"])
    differing = int(row["folded_from_a_different_id"])
    total = int(row["total"])
    if unfolded:
        bad("stored_codes_are_the_folded_form_retirement_compares",
            f"{unfolded} of {total} stored set code(s) are not their provider id "
            "folded to lower case, which is the spelling the client queries with "
            "and the spelling retire_sets compares against")
        return
    note = (f"{differing} of them are folded from an id TCGdex spells otherwise, "
            f"so the folding rule is doing real work and retirement compares "
            f"against the folded list" if differing else
            f"none of the {total} ids needed folding today, so the folding rule "
            f"is currently a no-op and is untested by this data")
    ok("stored_codes_are_the_folded_form_retirement_compares",
       f"every stored set code of the {total} is its provider id folded to lower "
       f"case: {note}")


def check_row_parity(db_url, provider):
    """The rows the importer derives, against the rows in Postgres.

    This is the claim the whole step rests on. tool/catalog/test_id_parity.py
    proves the two languages derive the same rows from the same responses; this
    proves the rows in the database are the rows the importer derives from those
    responses, which is a different statement - an import that predates a rule
    change satisfies the first and fails this.

    Every column of every sampled card is compared, and nothing is carved out.
    The set context the sample does not hold is fetched from the provider (see
    ProviderView), so what is compared is the row the import wrote rather than
    the client's by-id row. The first version of this check compared the by-id
    row for the 40 cards the sample reaches by id, and failed on two of their
    columns: released_at, which the by-id path leaves empty and the set walk
    fills from the set, and the art URL, which the by-id path builds without the
    series segment. Both were the check's fault rather than the importer's - the
    database holds the set walk's row because the set walk is the path the
    importer takes - and carving those columns out would have left the real
    question unasked.

    A card whose row could not be derived, because a set response could not be
    read, is reported as a skip naming the reason rather than counted as a
    database failure.
    """
    derived, unavailable, sampled = derived_rows(provider)
    columns = vectors_card_columns()

    ids = sorted(derived)
    array = "array[" + ", ".join(sql_text(i) for i in ids) + "]::text[]"
    selected = ", ".join(["id"] + columns)
    live = psql(db_url, (
        f"select {selected} from public.catalog_cards"
        f" where game = {sql_text(GAME)} and id = any ({array})"), want_json=True)
    by_id = {row["id"]: row for row in live}

    missing = [i for i in ids if i not in by_id]
    if missing:
        bad("imported_rows_equal_the_importer_derivation",
            f"{len(missing)} of {len(ids)} sampled cards are not in the database, "
            f"e.g. {missing[:3]}")
        return

    def same(a, b):
        if isinstance(a, bool) or isinstance(b, bool):
            return a is b
        if isinstance(a, (int, float)) and isinstance(b, (int, float)):
            return abs(a - b) < 1e-9
        if isinstance(a, dict) and isinstance(b, dict):
            return set(a) == set(b) and all(same(a[k], b[k]) for k in a)
        if isinstance(a, list) and isinstance(b, list):
            return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
        return a == b

    problems = []
    differing = 0
    for card_id in ids:
        row, live_row = derived[card_id], by_id[card_id]
        for column in columns:
            if not same(row.get(column), live_row.get(column)):
                differing += 1
                if differing <= 6:
                    problems.append(f"{card_id}.{column}: database "
                                    f"{live_row.get(column)!r} != importer "
                                    f"{row.get(column)!r}")
                break
    if problems:
        if differing > 6:
            problems.append(f"... and {differing - 6} more row(s) differ")
        bad("imported_rows_equal_the_importer_derivation", "\n".join(problems))
        return

    compared = (f"all {len(ids)} of the sample's {len(sampled)} cards match the "
                f"rows the importer derives in {len(columns)} columns each, with "
                f"no column excluded")
    if unavailable:
        ok("imported_rows_equal_the_importer_derivation", compared)
        skip("imported_rows_equal_the_importer_derivation (the rest of the sample)",
             f"{len(unavailable)} of the sample's {len(sampled)} cards were not "
             "compared, because the set context they need could not be read: "
             + "; ".join(f"{card_id}: {why}" for card_id, why
                         in sorted(unavailable.items())[:3]))
    else:
        ok("imported_rows_equal_the_importer_derivation",
           compared + ", and every card in the sample was comparable")


def check_sampled_sets_are_whole(db_url):
    """Every card a committed set response lists is a row the database holds.

    The provider's own answer for a set is the one statement about that set's
    size that does not come from this repository: the set response names its
    cards, and a stored set that is short of one of them is a set a browser
    would render incomplete. Only the five sampled sets can be checked this way
    without downloading the other 213, which is why it is a separate check from
    the counts above.
    """
    sample = read_json_gz(SAMPLE)
    problems = []
    checked = 0
    for item, body in test_id_parity.pokemon_set_downloads(sample):
        set_id = item.get("id")
        listed = sorted(c["id"] for c in tcgdex.stubs_of(body))
        if not listed:
            continue
        checked += 1
        array = "array[" + ", ".join(sql_text(i) for i in listed) + "]::text[]"
        rows = psql(db_url, (
            f"select count(*) from public.catalog_cards where game = {sql_text(GAME)}"
            f" and set_code = {sql_text(str(set_id).lower())} and id = any ({array})"))
        found = int(rows[0][0])
        if found != len(listed):
            problems.append(f"set {set_id!r} lists {len(listed)} cards and "
                            f"{found} of them are stored")
    if problems:
        bad("every_sampled_set_is_whole_against_the_provider", "\n".join(problems))
    else:
        ok("every_sampled_set_is_whole_against_the_provider",
           f"all {checked} sets the committed sample holds a response for list "
           "ids the catalogue holds, so none of them was stored short")


def check_generated_columns_on_pokemon_rows(db_url):
    """The folded code and the bare number are populated on the new rows.

    Pokemon is the game the bare-number rule exists for: its collector numbers
    are "1", "TG01", "SV001", "!" and "%3F", and the number search compares
    ltrim of them. The expression itself is asserted against the committed
    vectors by the Lorcana proof; what is new here is that 23,735 rows of this
    game have gone through it and come out populated.
    """
    rows = psql(db_url, (
        f"select count(*) from public.catalog_cards where game = {sql_text(GAME)}"
        " and (number_bare is null"
        "      or number_bare is distinct from ltrim(collector_number, '0'))"))
    wrong = int(rows[0][0])
    rows = psql(db_url, (
        f"select count(*) from public.catalog_sets where game = {sql_text(GAME)}"
        " and code_folded is null"))
    unfolded = int(rows[0][0])
    if wrong or unfolded:
        bad("generated_columns_are_populated_on_the_new_rows",
            f"{wrong} card row(s) carry a bare number the expression does not "
            f"produce, {unfolded} set row(s) have no folded code")
    else:
        ok("generated_columns_are_populated_on_the_new_rows",
           "every card row's number_bare is ltrim of its collector number and "
           "every set row carries a folded code, so the two search columns are "
           "usable for Pokemon")


def check_this_step_writes_no_price_rows(db_url):
    """Step 5 writes no prices, and the zero-is-not-a-price rule is step 6's.

    Price rows are catalog_prices' business and section 5 is explicit that a
    zero is not a price: TCGdex's pricing block quotes 0.00 for a printing with
    no market, and the app reads an absent finish as unknown while a stored
    0.00 would read as a real quote. This importer writes no price row at all -
    it samples prices into the companion's local history database, which is a
    different table in a different place - so the rule cannot be got wrong here,
    and asserting that the table is untouched is how the boundary stays visible
    rather than being assumed. It also means a variant key the app has never
    heard of cannot reach a stored card row: a card's finishes come from the
    card's own variants map, not from the pricing block, and a pricing key
    neither language knows contributes nothing rather than something guessed at.
    """
    rows = psql(db_url, (
        f"select count(*) from public.catalog_prices where game = {sql_text(GAME)}"))
    stored = int(rows[0][0])
    if stored:
        bad("no_price_rows_are_written_by_this_step",
            f"catalog_prices holds {stored} {GAME} row(s); this importer writes "
            "none, so something else wrote them or it is doing step 6's job")
    else:
        ok("no_price_rows_are_written_by_this_step",
           "catalog_prices holds no Pokemon rows: this step imports the "
           "catalogue and nothing else, so the zero-is-not-a-price rule is "
           "step 6's to keep")


def check_the_importer_cannot_delete_a_set():
    """The module emits no statement that removes a set, and never a bare delete.

    Read off the code rather than the database, because "cannot" is a claim about
    what may be generated.
    """
    fake_set = {"code": "zz-probe", "id": "zz", "name": "probe"}
    fake_card = {"id": "zz-probe-1", "set_code": "zz-probe", "name": "probe",
                 "collector_number": "1"}
    store = catalog_store.CatalogStore("postgres://unused", dry_run=True)
    sql = store._set_transaction(GAME, fake_set, [fake_card], "checksum",
                                 bump=True, retire=None)

    problems = []
    if re.search(r"delete\s+from\s+public\.catalog_sets", sql, re.I):
        problems.append("the write path emits a delete of catalog_sets")
    for statement in re.findall(r"delete\s+from[^;]*", sql, re.I):
        if "where" not in statement.lower():
            problems.append(f"an unscoped delete is emitted: {statement[:80]}")
        elif "game =" not in statement or "set_code =" not in statement:
            problems.append(f"a delete not scoped to one game and set: {statement[:80]}")

    def refused(statement):
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                store._run(statement)
            return False
        except catalog_store.CatalogError:
            return True

    if not refused("delete from public.collection_entries where true;"):
        problems.append("the guard allowed a statement against collection_entries")
    if not refused("delete from public.decks where true;"):
        problems.append("the guard allowed a statement against decks")
    if refused("select 1 from public.catalog_sets where name = 'look at your decks';"):
        problems.append("the guard refused a statement that only mentions decks "
                        "in a literal, which is what card text is")

    if problems:
        bad("the_write_path_cannot_remove_a_set_or_an_account_row",
            "\n".join(problems))
    else:
        ok("the_write_path_cannot_remove_a_set_or_an_account_row",
           "no delete of catalog_sets is generated; every card delete is scoped "
           "to one game and one set code; statements against the account tables "
           "are refused even when a card literal mentions them")


def check_retirement_is_a_soft_delete(db_url):
    """A set that disappears upstream is retired, never deleted.

    Design rule 4, exercised through the importer's own retire_sets rather than
    through hand-written SQL: one published set is left out of the upstream
    list, which retires it, and the list is then handed over whole, which
    un-retires it. What is asserted in between is the point of the rule - the
    set row is still there, and so is every card in it, so the holdings that
    name those card ids still resolve.
    """
    rows = psql(db_url, (
        f"select code from public.catalog_sets where game = {sql_text(GAME)}"
        " and retired_at is null order by code"))
    codes = [row[0] for row in rows]
    if len(codes) < 2:
        skip("a_retired_set_keeps_its_row_and_its_cards",
             f"only {len(codes)} live set(s) to experiment on")
        return
    victim = codes[0]

    store = catalog_store.CatalogStore(
        os.environ.get("SUPABASE_DB_URL") or os.environ.get("SUPABASE_DB_URL_POOLED"),
        psql=catalog_store.find_psql())

    def snapshot():
        rows = psql(db_url, (
            "select (select count(*) from public.catalog_sets"
            f"         where game = {sql_text(GAME)} and retired_at is null),"
            "       (select count(*) from public.catalog_sets"
            f"         where game = {sql_text(GAME)} and code = {sql_text(victim)}),"
            "       (select count(*) from public.catalog_cards"
            f"         where game = {sql_text(GAME)} and set_code = {sql_text(victim)})"))
        return tuple(int(v) for v in rows[0])

    live_before, row_before, cards_before = snapshot()
    try:
        store.retire_sets(GAME, [c for c in codes if c != victim])
        live_retired, row_retired, cards_retired = snapshot()
        store.retire_sets(GAME, codes)
        live_after, row_after, cards_after = snapshot()
    except Exception as exc:  # noqa: BLE001 - reported, and the set is put back below
        bad("a_retired_set_keeps_its_row_and_its_cards",
            f"the retirement experiment failed: {exc}")
        return

    problems = []
    if live_retired != live_before - 1:
        problems.append(f"retiring one set left {live_retired} visible, "
                        f"expected {live_before - 1}")
    if row_retired != 1:
        problems.append(f"the retired set's row is gone ({row_retired} found)")
    if cards_retired != cards_before:
        problems.append(f"the retired set lost cards: {cards_before} -> "
                        f"{cards_retired}")
    if (live_after, row_after, cards_after) != (live_before, row_before, cards_before):
        problems.append("re-publishing the set did not restore it exactly")

    if problems:
        bad("a_retired_set_keeps_its_row_and_its_cards", "\n".join(problems))
    else:
        ok("a_retired_set_keeps_its_row_and_its_cards",
           f"set {victim!r} left out of the upstream list was retired rather than "
           f"deleted - its row and its {cards_before:,} cards were still there, "
           f"({live_retired} sets visible) - and handing the list over whole "
           f"restored all {live_after} sets")


def check_meta(db_url, sets, cards):
    rows = psql(db_url, (
        "select sets_revision, set_count, card_count, last_import_ok,"
        "       coalesce(last_import_note, ''), coalesce(source, ''),"
        "       sets_updated_at is not null"
        f"  from public.catalog_meta where game = {sql_text(GAME)}"))
    revision, set_count, card_count, ok_flag, note, source, dated = rows[0]
    problems = []
    if ok_flag != "t":
        problems.append("last_import_ok is false")
    if int(set_count) != sets or int(card_count) != cards:
        problems.append(f"catalog_meta says {set_count}/{card_count}, the tables "
                        f"hold {sets}/{cards}")
    if source != "tcgdex":
        problems.append(f"source is {source!r}, expected 'tcgdex'")
    if dated != "t":
        problems.append("sets_updated_at is null")
    if not note:
        problems.append("last_import_note is empty")
    if problems:
        bad("catalog_meta_records_the_import", "\n".join(problems))
    else:
        ok("catalog_meta_records_the_import",
           f"sets_revision {revision}, {set_count} sets, {card_count} cards, "
           f"source tcgdex, note: {note}")
    return int(revision)


def check_checksums(db_url, sets):
    rows = psql(db_url, (
        "select count(*) from public.catalog_sets"
        f" where game = {sql_text(GAME)} and (cards_checksum is null"
        "   or cards_checksum = '' or cards_revision = 0 or catalogued_at is null)"))
    incomplete = int(rows[0][0])
    if incomplete:
        bad("every_set_carries_a_checksum_and_a_revision",
            f"{incomplete} of {sets} sets have no checksum, revision or "
            "catalogued_at, so the next run would rewrite them")
    else:
        ok("every_set_carries_a_checksum_and_a_revision",
           f"all {sets} sets carry a checksum, a non-zero cards_revision and a "
           "catalogued_at, so an unchanged night costs one comparison")


def check_catalogue_is_still_read_only(db_url):
    names = ",".join(sql_text(t) for t in CATALOG_TABLES)
    rows = psql(db_url, (
        "select grantee, table_name,"
        "       coalesce(string_agg(distinct privilege_type, ',' order by privilege_type), '')"
        "  from information_schema.role_table_grants"
        " where table_schema = 'public'"
        f"   and table_name in ({names})"
        "   and grantee in ('anon','authenticated')"
        " group by 1, 2 order by 2, 1"))
    seen = {(g, t): p for g, t, p in rows}
    problems = [f"{g} on {t}: {seen.get((g, t), 'no grants')}"
                for t in CATALOG_TABLES
                for g in ("anon", "authenticated")
                if seen.get((g, t)) != "SELECT"]
    if problems:
        bad("catalogue_is_still_select_only_for_clients", "\n".join(problems))
    else:
        ok("catalogue_is_still_select_only_for_clients",
           "anon and authenticated still hold SELECT and nothing else, so the "
           "Pokemon import did not widen the posture step 0 fixed")


def check_http(base, key, sets):
    status, body, _ = postgrest_get(
        base, f"catalog_sets?game=eq.{GAME}&select=code&limit=1000", key)
    if status not in (200, 206) or not isinstance(body, list):
        bad("publishable_key_reads_the_catalogue",
            f"catalog_sets answered HTTP {status}")
        return
    if len(body) != sets:
        bad("publishable_key_reads_the_catalogue",
            f"the publishable key sees {len(body)} sets, the importer wrote {sets}")
        return
    status, cards, headers = postgrest_get(
        base, f"catalog_cards?game=eq.{GAME}&select=id&limit=1", key)
    if status not in (200, 206):
        bad("publishable_key_reads_the_catalogue",
            f"catalog_cards answered HTTP {status}")
        return
    total = headers.get("Content-Range", "")
    status, one, _ = postgrest_get(
        base, f"catalog_cards?game=eq.{GAME}&id=eq.base1-1&select=id,name,oracle_id", key)
    if status not in (200, 206) or not isinstance(one, list) or len(one) != 1:
        bad("publishable_key_reads_the_catalogue",
            f"a single card read answered HTTP {status} with {len(one or [])} rows")
        return
    ok("publishable_key_reads_the_catalogue",
       f"{len(body)} sets and catalog_cards range {total or 'not reported'} "
       f"readable; base1-1 reads back as {one[0].get('name')!r} "
       f"({one[0].get('oracle_id')!r})")


def check_rerun_changes_nothing(db_url, sets, cards, revision, skip_rerun):
    """Re-runs the importer over unchanged data and compares everything it could move.

    The second run is the only one that can prove the checksum skip, so the
    second run happens. It is bounded to the five sets the committed sample
    holds whole - the whole game is 23,735 cards and a second full import would
    cost as much as the first for no more information - and every set in the
    game is compared afterwards, because a run that named a subset must touch
    that subset and nothing else.

    Counts alone would not catch a run that rewrote every row to the same
    values; the checksums, the revisions and catalogued_at are compared too, so
    a rewrite shows up even when the content is identical.
    """
    if skip_rerun:
        skip("rerun_changes_nothing", "not run: --skip-rerun")
        return

    poller = os.path.join(TOOL, "poll_pokemon_prices.py")
    if not os.path.exists(poller) or not shutil.which(sys.executable):
        skip("rerun_changes_nothing", f"no importer at {poller}")
        return

    def snapshot():
        return psql(db_url, (
            "select code, coalesce(cards_checksum, ''), cards_revision,"
            "       card_row_count, catalogued_at::text"
            f"  from public.catalog_sets where game = {sql_text(GAME)}"
            " order by code"))

    before = snapshot()
    proc = subprocess.run(
        [sys.executable, poller, "--catalog-only", "--sets", ",".join(SAMPLE_SETS)],
        capture_output=True, text=True, timeout=3600,
        cwd=os.path.dirname(poller), env=os.environ)
    if proc.returncode != 0:
        bad("rerun_changes_nothing",
            f"the second run exited {proc.returncode}: {proc.stderr.strip()[:300]}")
        return
    after = snapshot()

    if before != after:
        changed = [(b[0], b[2], a[2]) for b, a in zip(before, after) if b != a]
        bad("rerun_changes_nothing",
            f"{len(changed)} set(s) moved on a second run, e.g. {changed[:3]} "
            "(code, revision before, revision after)")
        return

    counts = psql(db_url, (
        f"select (select count(*) from public.catalog_sets where game = {sql_text(GAME)}),"
        f"       (select count(*) from public.catalog_cards where game = {sql_text(GAME)}),"
        f"       (select sets_revision from public.catalog_meta where game = {sql_text(GAME)})"))
    new_sets, new_cards, new_revision = (int(v) for v in counts[0])
    if (new_sets, new_cards) != (sets, cards) or new_revision != revision:
        bad("rerun_changes_nothing",
            f"after the second run: {new_sets} sets, {new_cards} cards, revision "
            f"{new_revision}; expected {sets}, {cards}, {revision}")
    else:
        ok("rerun_changes_nothing",
           f"the second run rewrote no set: all {sets} keep their checksum, "
           f"cards_revision and catalogued_at, so the five sets it was asked for "
           f"were skipped on their checksums and the other {sets - len(SAMPLE_SETS)} "
           f"were never touched; sets_revision stayed {revision}")


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
                    help="do not re-run the importer to prove the checksum skip")
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

    for path in (VECTORS, SAMPLE):
        if not os.path.exists(path):
            print(f"missing {path}", file=sys.stderr)
            return 2

    # The account tables first: if the import damaged them, that should be the
    # headline rather than a line at the bottom.
    rows = psql(db_url, (
        "select (select count(*) from public.decks),"
        "       (select count(*) from public.collection_entries)"))
    accounts_before = tuple(int(v) for v in rows[0])

    print("--- SQL, as the owner ---")

    provider = ProviderView()
    provider_sets, why = provider_set_count()
    if provider_sets is None:
        skip("counts_match_the_provider (the provider's own set list)",
             f"TCGdex could not be read: {why}. The stored set list is still "
             "checked for structure, but not against a remembered number")
    sets, cards = check_counts(db_url, provider_sets)
    if sets is None or cards is None:
        print()
        print("the catalogue is not in a state worth proving further")
        return 1

    check_orphans(db_url)
    check_set_codes_are_stored_form(db_url)
    check_sets_stored_empty_are_the_providers_own_empty_sets(db_url)
    check_row_parity(db_url, provider)
    check_sampled_sets_are_whole(db_url)
    check_generated_columns_on_pokemon_rows(db_url)
    check_this_step_writes_no_price_rows(db_url)
    check_the_importer_cannot_delete_a_set()
    check_retirement_is_a_soft_delete(db_url)
    revision = check_meta(db_url, sets, cards)
    check_checksums(db_url, sets)
    check_catalogue_is_still_read_only(db_url)

    if not args.no_auth:
        base = os.environ.get("SUPABASE_URL")
        key = os.environ.get("SUPABASE_PUBLISHABLE_KEY")
        print()
        print("--- HTTP, as the publishable key ---")
        if not base or not key:
            skip("publishable_key_reads_the_catalogue",
                 "SUPABASE_URL or SUPABASE_PUBLISHABLE_KEY is not set")
        else:
            check_http(base, key, sets)

    print()
    print("--- the second run ---")
    check_rerun_changes_nothing(db_url, sets, cards, revision, args.skip_rerun)

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
