#!/usr/bin/env python3
"""Prove the Digimon import against the live database.

Design: docs/catalogue-server-side.md, section 8, and
docs/catalogue-import-digimon.md, which is the report of the client half this
one answers. The claim is that Digimon - the 93 English releases Heroicc lists
today and every card in them - is held on the server, that the rows there are
exactly the rows the Dart client would have derived itself, that re-running the
importer changes nothing, and that the importer cannot damage anything it does
not own.

Written the way tool/catalog/prove_swu_import.py is written, and for the same
reason: the interesting failures are invisible in the SQL that was supposed to
produce them and obvious in the database. Every rule a row is derived by is
asked of tool/import_digimon_catalogue.py rather than spelled a second time
here, and every row this file compares with the database is the row
tool/catalog/test_id_parity.py derives from the same response - one
implementation, and this file is the statement about what Postgres holds.

Four things are this game's own rather than a repeat of the Star Wars:
Unlimited proof.

**A count means something else here, and the check says so.** Heroicc's set list
states how many card *entries* a release lists, and a release lists one entry
per card it files, so the game's 7,685 entries stand over 7,541 distinct card
ids: 142 promotional cards are listed by two releases each, and P-058 is one of
them. A set's card_count is therefore *not* the number of distinct oracle ids
among its rows, and this file does not pretend it is. What is asserted instead
is that the stored count equals the count the source's own list states for that
release - read live, or from the sample's own copy of the list when the network
refuses - that every stored set carries a count above zero, and that the count
is never *below* the distinct oracle ids the set's rows hold: a release lists at
least one entry per card, so a stored count under the figure its own rows
measure is a set the source has grown since the import and a tile that
understates it. The two totals are printed.

**A card two releases list is stored once, under the first one its own record
names.** P-058 is listed by both 'p' and 'bt-08' and its record is [p, bt-08], so
it belongs to p and there is one row for it, under p. The rule is the card's own
record rather than the walk that happened to read it, which is what the client's
by-id path has always used, and it has three consequences worth holding on to.
'p' holds all 207 ids it lists. bt-08 lists 138 and holds 137 of them, because
P-058 is not its card. And three releases - the deck box set, the binder set and
one promotion, 29 entries between them - hold no rows at all, because every card
they carry is a reprint whose record names another release first; an empty set is
the right answer there and not a lost import, which is why a card count above
zero is no longer read as a promise of rows. Nothing is stored twice: 7,685
entries the source lists stand over the 7,541 rows the catalogue holds, and each
of those rows is owned by exactly one release.

**A parallel keeps its own id and its base's printed number.** BT5-007_P3 is a
printing of BT5-007: it keeps the suffix in its id, takes the base's oracle id
so the app groups the two, and - unlike a hyperspace card in Star Wars:
Unlimited, which counts its own run and so has to be renumbered to its base -
it prints the base's number and so shares its collector number, which is what
puts both printings in one binder slot. The rule is exercised over every stored
row whose id carries a parallel suffix, and the base row it points at is
asserted to be there.

**No card in this game is a token, so there is no token check.** The source
lists no token records beside the cards and the importer drops none; a check for
one would be a check about a fact this game does not have.

The licence is the one thing about this game that is not a technical question.
Heroicc publishes its own content under CC BY-NC-SA 4.0: non-commercial, which
this app is, and share-alike, which the copy in Arcanum's own catalogue carries.
The attribution the licence asks for is in lib/core/legal.dart, and this proof
is the evidence for the sentence beside it - that the copy in the catalogue is
the app's own row for row, derived by the same rules the client applies and
written by the module the importer runs, rather than a re-host of somebody
else's data.

Credentials come from the environment, or from a file named with --env-file.
Nothing in this file holds a secret and the database URL is never printed.

    set -a; . /home/zixen/arcanum/supabase.env; set +a
    python3 tool/catalog/prove_digimon_import.py

--no-auth runs without the HTTP half. --skip-rerun does not re-run the
importer, which is the check that proves the checksum skip. Exit status is 0
only if nothing failed.
"""

from __future__ import annotations

import argparse
import ast
import contextlib
import gzip
import io
import json
import os
import re
import shutil
import subprocess
import sys

TIMEOUT = 60
GAME = "digimon"
SOURCE = "Heroicc"
PROVIDER = "https://api.heroi.cc"

# The host the source serves its own art from. images.heroi.cc sends no
# Access-Control-Allow-Origin, which is the property tcgcsv lacks and the whole
# reason Arcanum's relay exists - so the address a phone reads has to be the
# source's own, and a relayed address is the one thing that must never be
# stored. The check is a prefix and not a search for a substring that happened
# to appear once.
ART_HOST = "https://images.heroi.cc/"
RELAYED = "/arcanumweb-api/art/"

CATALOG_TABLES = ("catalog_sets", "catalog_cards", "catalog_prices", "catalog_meta")

# The five releases the committed sample cuts whole, which is the set the re-run
# check imports a second time and the set the id checks read from the sample.
# Named rather than derived so that the second run is the same second run every
# time it is made, and it is also the sample's own sampled_sets, in the order the
# source lists them - between them they hold 553 of the game's 7,541 rows, and p
# and bt-08 are the pair that share P-058.
SAMPLE_SETS = ("other-promos", "p", "st-01", "bt-05", "bt-08")

# The one release asked of the source now, in check_ids_are_the_sources_own.
# bt-08 rather than another release because the sample also cuts it whole, so the
# two halves of that check are about the same release and a disagreement between
# them is about the source rather than about which release was read - and because
# it is the release that files a card printed by another set (BT5-007_P3).
LIVE_SET = "bt-08"

# The search answer the fallback check reads, and the one row of it the check is
# about: the sample's agumon search holds exactly one card that names no release,
# BT1-010_P3, which prints BT1-010. Named rather than searched for so that a
# sample which stopped holding it is a failure that says so.
FALLBACK_SEARCH = "agumon"
FALLBACK_CARD = "BT1-010_P3"
FALLBACK_NUMBER = "BT1-010"

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.dirname(HERE)
VECTORS = os.path.join(HERE, "catalog_id_vectors.json.gz")
SAMPLE = os.path.join(HERE, "digimon_sample.json.gz")

# psql is told its connection through the environment rather than through its
# argv, so the password is not in a process listing. catalog_store owns that
# split and is the module the importer itself runs, so this proof uses it rather
# than keeping a second copy of a rule about credentials.
#
# test_id_parity is imported for its driver: the rows this proof compares with the
# database are the rows that test asserts against the committed Dart vectors, from
# one implementation rather than two. import_digimon_catalogue is imported for the
# same reason on the other side - every rule the rows are derived by is asked of
# the importer, not spelled a second time here.
sys.path.insert(0, TOOL)
sys.path.insert(0, HERE)
import catalog_store  # noqa: E402
import import_digimon_catalogue as digimon  # noqa: E402
import test_id_parity  # noqa: E402

RESULTS = []


def record(status, name, detail):
    RESULTS.append((status, name, detail))
    print("%-4s  %s" % (status, name))
    for line in detail.splitlines():
        print("        %s" % line)


def ok(name, detail):
    record("PASS", name, detail)


def bad(name, detail):
    record("FAIL", name, detail)


def skip(name, detail):
    record("SKIP", name, detail)


def read_json_gz(path):
    with gzip.open(path, "rb") as fh:
        return json.loads(fh.read().decode("utf-8"))


def same(a, b):
    """Structural equality over decoded JSON, numbers compared numerically."""
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return abs(a - b) < 1e-9
    if isinstance(a, dict) and isinstance(b, dict):
        return set(a) == set(b) and all(same(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    return a == b


def listing(names, values):
    """A short 'a x2, b x1' tally, for a detail line that has to stay one line."""
    return ", ".join("%s x%d" % (name, values[name]) for name in names)


# ---------------------------------------------------------------------------
# SQL, as the owner, and HTTP, as anybody
# ---------------------------------------------------------------------------


def session_url(db_url):
    """The session pooler, which is what the design names for admin work."""
    return db_url.replace(":6543/", ":5432/"), ":6543/" in db_url


def psql(db_url, sql, want_json=False):
    """One script through psql, with ON_ERROR_STOP, reading JSON when asked.

    The JSON form is used for anything that reads card text: card rules text
    carries pipes, tabs, newlines and CJK brackets, and the pipe-separated text
    protocol would turn any of them into a column boundary. Every column of a
    JSON read is aliased, because json_agg turns two columns of the same name
    into one key and the second count would silently replace the first.
    """
    if not isinstance(sql, str):
        raise TypeError("psql was handed %s, not one statement: %s"
                        % (type(sql).__name__, str(sql)[:200]))
    if want_json:
        sql = "select coalesce(json_agg(x), '[]'::json) from (\n%s\n) x;" % sql
    proc = subprocess.run(
        ["psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c", sql],
        capture_output=True, text=True, timeout=TIMEOUT,
        env=catalog_store.psql_environment(db_url))
    if proc.returncode != 0:
        raise RuntimeError("psql: %s" % proc.stderr.strip()[:500])
    if want_json:
        return json.loads(proc.stdout.strip() or "[]")
    return [line.split("|") for line in proc.stdout.splitlines() if line != ""]


def sql_text(value):
    """A Python string as a SQL literal. The same rule the importer uses."""
    return "'" + str(value).replace("'", "''") + "'"


def sql_array(values):
    return "array[" + ", ".join(sql_text(v) for v in values) + "]::text[]"


def http_get(url, headers=None):
    import urllib.error
    import urllib.request

    req = urllib.request.Request(url, headers=headers or {
        "Accept": "application/json",
        "User-Agent": "Arcanum/1.0 (+https://github.com/arm00pv/arcanum)"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            body = resp.read().decode("utf-8", "replace")
            return resp.status, json.loads(body or "null"), dict(resp.headers)
    except urllib.error.HTTPError as exc:
        return exc.code, None, dict(exc.headers or {})


def postgrest_get(base, path, key):
    return http_get("%s/rest/v1/%s" % (base.rstrip("/"), path),
                    {"apikey": key, "Accept": "application/json",
                     "Prefer": "count=exact"})


def http_send(url, method, headers, body):
    """One request that is not a GET, answered as (status, text).

    Separate from http_get because a write attempt has no JSON answer to decode:
    a refusal comes back as a PostgREST error object and a success comes back
    empty, and what this proof reads either way is the status.
    """
    import urllib.error
    import urllib.request

    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code, (exc.read() or b"").decode("utf-8", "replace")


def vectors_card_columns():
    """The columns of a card row, taken from the committed vectors.

    Read from the file rather than typed here so that a column added to the row
    shape is compared without this file being edited, and so that this proof and
    the parity test agree about what a row is. This game's row is 35 columns
    wide and the id is the key rows are fetched by, so 34 columns are compared
    column by column.
    """
    for block in read_json_gz(VECTORS).get("games", []):
        if block.get("game") == GAME:
            return [column for column in block["cards"][0] if column != "id"]
    raise SystemExit("%s holds no %s block" % (VECTORS, GAME))


def one_stored_card_id():
    """One id the catalogue is asserted to hold, taken from the sample.

    The single-card read through PostgREST is what proves a client can fetch one
    card and not merely list them, and the id it uses must be one the catalogue
    is asserted to hold. It is taken from the sample rather than typed here, so
    that it is the same id check_row_parity and check_ids_are_the_sources_own
    have already compared with the database.
    """
    rows = test_id_parity.digimon_cards(read_json_gz(SAMPLE))
    return sorted(rows)[0] if rows else None


def releases_in(envelope):
    """The releases an answer of the source's set list names, folded.

    The value is a pair: the code as the source spells it - 'bt-05', where the
    catalogue stores 'bt05' - and the number of card entries the release's own
    entry states, which is the count a set row is asserted against in
    check_card_counts_are_the_sources. The count is the source's own fact about
    its own listing and not a number this file remembers.
    """
    out = {}
    for item in digimon.included_of(envelope):
        provider_code = digimon.slug_of(item, digimon.RELEASES)
        if not provider_code:
            continue
        meta = item.get("meta") if isinstance(item, dict) else None
        stated = meta.get("cards") if isinstance(meta, dict) else None
        if isinstance(stated, bool) or not isinstance(stated, (int, float)):
            stated = None
        out[digimon.slug(provider_code)] = (provider_code,
                                            None if stated is None else int(stated))
    return out


def live_releases():
    """The source's own release list right now, through the importer's own read.

    Asked for rather than remembered. A constant written down here would fail the
    day the source adds a release - a false alarm - and would pass for an import
    that stored a set list thinly, which is the failure that matters. It is one
    request for 93 releases, and it carries each release's own card count, which
    is why this game needs no count request per set: the number is in the list.

    Returns (None, why) when it cannot be read, so that this degrades to a skip
    rather than to a failure about the network.
    """
    try:
        envelope = digimon.set_list()
    except Exception as exc:  # noqa: BLE001 - reported as a skip, with the reason
        return None, str(exc)
    out = releases_in(envelope)
    if not out:
        return None, "the source listed no releases"
    return out, None


def sample_releases():
    """The same mapping, from the sample's own copy of the set list.

    The sample holds the whole set list - 93 releases, each with its name, its
    count and, for 87 of them, its date - so the count a set row is asserted
    against is available with no network at all. It is the list as it stood when
    the sample was cut, which is why the live read is preferred and this is what
    the check falls back to when the source cannot be reached.
    """
    return releases_in(read_json_gz(SAMPLE).get("sets"))


def sample_release_lists(codes):
    """The ids the releases the sample cuts whole list, and their card records.

    The offline half of read_release_lists, and the same shape: the sample holds
    five whole release envelopes - the ids each of them lists - and every record
    of those cards, so ownership is answerable with no network at all. Used both
    where the sample is the evidence and where the source refuses and this is
    what the id half of check_card_counts_are_the_sources degrades to.
    """
    sample = read_json_gz(SAMPLE)
    releases = sample.get("releases") or {}
    listed = {}
    for slug in codes:
        envelope = releases.get(slug)
        if not isinstance(envelope, dict):
            continue
        ids = digimon.card_ids_of(envelope)
        if ids:
            listed[digimon.slug(slug)] = ids
    return listed, (sample.get("cards") or {})


def listers_of(listed):
    """Which releases list each card, from the id lists just read."""
    out = {}
    for code, ids in listed.items():
        for card_id in ids:
            out.setdefault(card_id, []).append(code)
    return out


def owner_of(card_id, envelopes, listers):
    """The release a card's row belongs to, as the importer derives it.

    The first release the card's own record names, folded: the source's own
    answer about where a card belongs, and the rule the importer and the client
    both apply. A card whose record names no release at all is filed under the
    walk that reached it - the importer's fallback - and that is the whole answer
    where one release lists it, the 77 cards of this game whose own record names
    no release included. Where two releases list a card that names none of them,
    the row belongs to whichever walk wrote it last, which is
    not a fact this proof can state from the data, and None is returned so the
    caller reports it rather than guessing.
    """
    envelope = envelopes.get(card_id) or {}
    named = digimon.releases_of(envelope.get("data"))
    if named:
        return digimon.slug(named[0])
    if len(listers) == 1:
        return listers[0]
    return None


def read_release_lists(source, stored):
    """The ids every release lists, and the card records ownership has to ask for.

    One request per release, through the importer's own release_envelope and
    card_ids_of, because a release's envelope is the only place its card list is
    stated. What that answer does NOT carry is ownership: its included entries are
    stubs - an id, a link and a type, with no attributes and no relationships - so
    the envelope says who a release lists and never who owns what. Ownership is
    the card's own record, one request per card, so it is asked - through the
    importer's own polite reader, card_envelopes - only where it can change the
    verdict: a card two releases list, and a card a release lists without holding
    it. Everything else is owned by the one release that lists it, which is also
    the importer's fallback for a card whose record names nothing.

    Returns (listed, envelopes, why). why is the reason the live half could not be
    read, and then the caller compares the five releases the sample cuts instead:
    a proof that failed here would be a report about the network rather than
    about the catalogue.
    """
    listed = {}
    try:
        for folded, (spelling, _count) in sorted(source.items()):
            ids = digimon.card_ids_of(digimon.release_envelope(spelling))
            if not ids:
                raise RuntimeError("release %s listed no cards" % spelling)
            listed[folded] = ids
    except Exception as exc:  # noqa: BLE001 - reported, with the reason
        return {}, {}, "its release envelopes could not be read: %s" % exc
    listers = listers_of(listed)
    questioned = sorted(card_id for card_id, codes in listers.items()
                        if len(codes) > 1
                        or not any(card_id in stored.get(code, ()) for code in codes))
    try:
        envelopes = digimon.card_envelopes(questioned, "the ownership question")
    except Exception as exc:  # noqa: BLE001 - reported, with the reason
        return {}, {}, ("the records of the cards it lists twice could not be "
                        "read: %s" % exc)
    return listed, envelopes, None


def gone_to(ids, envelopes, listers):
    """A 'pb01 x6, ex04 x1' tally of the releases that own the cards this one lists.

    For the detail line of a release that owns none of what it lists, which is
    the case that has to be told apart from an import that lost the release's
    rows: the answer is where the cards went, and it is read off the same records
    ownership was decided from.
    """
    tally = {}
    for card_id in ids:
        owner = owner_of(card_id, envelopes, listers.get(card_id, [])) or "nowhere"
        tally[owner] = tally.get(owner, 0) + 1
    return listing(sorted(tally), tally)


# ---------------------------------------------------------------------------
# The checks
# ---------------------------------------------------------------------------


def check_counts(db_url, provider):
    """Every release the source lists is a row, folded, and no stored set is not.

    The card total is deliberately not compared against a number written down
    here, and for this game that is not only caution: the source's own total
    counts card entries, so it is not the number of rows the catalogue holds.
    The per-release comparison is check_card_counts_are_the_sources. What this
    check is about is the set list as a structure: the stored codes are the
    source's codes folded, in the same number and both ways round, no set is
    retired, and no set carries a card count of zero - a set stored with no
    count is a set no client can tell is complete.
    """
    rows = psql(db_url, (
        "select (select count(*) from public.catalog_sets where game = %s),"
        "       (select count(*) from public.catalog_cards where game = %s),"
        "       (select count(*) from public.catalog_sets where game = %s"
        "          and retired_at is not null),"
        "       (select count(*) from public.catalog_sets where game = %s"
        "          and card_count <= 0)"
        % (sql_text(GAME), sql_text(GAME), sql_text(GAME), sql_text(GAME))))
    sets, cards, retired, uncounted = (int(v) for v in rows[0])

    problems = []
    if retired:
        problems.append("%d set(s) are retired; the source lists every one" % retired)
    if uncounted:
        problems.append("%d set(s) carry a card count of zero, which a client "
                        "reads as a release whose size the source does not state"
                        % uncounted)

    beyond_case = []
    if provider is not None:
        rows = psql(db_url, "select code from public.catalog_sets where game = %s"
                    % sql_text(GAME))
        stored = sorted(row[0] for row in rows)
        unpublished = [code for code in stored if code not in provider]
        missing = [code for code in sorted(provider) if code not in set(stored)]
        if sets != len(provider):
            problems.append("%d sets stored, the source lists %d"
                            % (sets, len(provider)))
        if missing:
            problems.append("%d release(s) the source lists are not stored: %s"
                            % (len(missing), missing[:4]))
        if unpublished:
            problems.append("%d stored set(s) the source does not list: %s"
                            % (len(unpublished), unpublished[:4]))
        # How much work the fold does is reported rather than asserted here. The
        # fold itself is checked in full in
        # check_stored_codes_are_the_folded_form, against the importer's own
        # slug; and for this game almost every code needs more than a case
        # change, because the source spells a release 'bt-05' where the
        # catalogue stores 'bt05'. A failure raised here for a code that folded
        # correctly would be a false alarm about an import that did exactly what
        # it should.
        beyond_case = [code for code in stored
                       if code in provider and code != provider[code][0].lower()]

    if problems:
        bad("counts_match_the_source", "\n".join(problems[:6]))
    else:
        if provider is None:
            compared = "%d sets (the source's own list was not read)" % sets
            fold = ""
        else:
            compared = ("%d sets, the source lists the same %d"
                        % (sets, len(provider)))
            fold = ("and every code is the source's own spelling through the "
                    "fold, in the form the client queries with"
                    if not beyond_case else
                    "and %d of the codes needed more than a case change (bt-05 "
                    "stored as bt05)" % len(beyond_case))
            fold = ", " + fold
        ok("counts_match_the_source",
           "%s, none retired, every one carrying a count of its own%s: %d cards"
           % (compared, fold, cards))
    return sets, cards


def check_orphans(db_url):
    """No card row names a set the catalogue does not hold.

    catalog_cards carries a foreign key to catalog_sets, so this cannot happen
    through the write path - which is exactly why it is worth asking: it is the
    cheapest way to see that the key is still there and that the two tables were
    written by the same run.
    """
    rows = psql(db_url, (
        "select count(*) from public.catalog_cards c"
        "  left join public.catalog_sets s on s.game = c.game and s.code = c.set_code"
        " where s.code is null"))
    orphans = int(rows[0][0])
    if orphans:
        bad("every_card_belongs_to_a_stored_set",
            "%d card rows name a set that is not in catalog_sets" % orphans)
    else:
        ok("every_card_belongs_to_a_stored_set",
           "no card row names a set that is not stored, so every holding resolves")


def check_stored_codes_are_the_folded_form(db_url):
    """The stored code is the source's code folded, and the folding is real.

    The source addresses a release by bt-05 and every read path of the app folds
    a code before it touches SQLite, so for this game the two strings differ for
    82 of the 93 releases - which is what makes this worth asking rather than
    assuming. It also matters more here than elsewhere: retire_sets compares
    against the stored form, so a run that handed it the source's spelling would
    retire all 93 sets at once and look like a complete import.

    The fold is the importer's own slug, asked for rather than spelled a second
    time in SQL: this game's rule is lower case with everything that is not a
    letter or a digit dropped, and a regexp_replace here would be a second
    implementation of it that no test would compare with the first. The stored
    id keeps the source's spelling, because folding throws away the dash and the
    version numbering of bt01-03-v1-0, which is not recoverable.
    """
    rows = psql(db_url, (
        "select code, id from public.catalog_sets where game = %s order by code"
        % sql_text(GAME)), want_json=True)
    if not rows:
        bad("stored_codes_are_the_folded_form_retirement_compares",
            "no set rows to check")
        return
    wrong = [(row["code"], row["id"]) for row in rows
             if row["code"] != digimon.slug(row["id"])]
    unfolded = [row for row in rows if row["code"] == row["id"]]
    if wrong:
        bad("stored_codes_are_the_folded_form_retirement_compares",
            "%d of %d stored codes are not the importer's slug of the source's "
            "own spelling, which is the form the client queries with and the "
            "form retire_sets compares against, e.g. %s"
            % (len(wrong), len(rows), wrong[:3]))
        return
    if len(unfolded) == len(rows):
        bad("stored_codes_are_the_folded_form_retirement_compares",
            "the source spells every one of the %d codes the way the catalogue "
            "stores it, so this data cannot show the fold is applied" % len(rows))
        return
    ok("stored_codes_are_the_folded_form_retirement_compares",
       "all %d stored codes are its own release code through the importer's "
       "slug, with the source's spelling kept in the row's id - %d of them a "
       "code the fold really changes (bt-05 stored as bt05), so the folding is "
       "doing work rather than agreeing by accident"
       % (len(rows), len(rows) - len(unfolded)))


def check_set_types_are_the_importers(db_url):
    """Every stored set_type is set_type_for's own answer, and one of three.

    There is no genre in the source's set list - a release's own route carries
    one, and reading it would cost 93 requests - so the type is read off the
    code and the name, and the split that matters to a collector is starters
    against boosters against everything else. Over the 93 releases the code
    decides every one of them; the name is the fallback for a release whose code
    says nothing, and the one release that names a booster is an expansion whose
    code already says so. The stored column is compared with the importer's own
    function over the two things the source states rather than with a list of
    kinds written down here.

    The three kinds are the only ones that function can return, which is
    asserted as well: a fourth spelling in the column would be a set type no
    client knows. How the 93 releases split across them is printed, because that
    split is the thing a reader wants to sanity-check against the shelf.
    """
    rows = psql(db_url, (
        "select code, id, name, set_type from public.catalog_sets"
        " where game = %s order by code" % sql_text(GAME)), want_json=True)
    allowed = ("starter", "expansion", "promo")
    wrong = []
    kinds = {}
    for row in rows:
        expected = digimon.set_type_for(row["id"], row["name"])
        kinds[row["set_type"]] = kinds.get(row["set_type"], 0) + 1
        if row["set_type"] != expected:
            wrong.append("set %s (%s, %r) is stored as %r and set_type_for gives %r"
                         % (row["code"], row["id"], row["name"],
                            row["set_type"], expected))
    strange = sorted(set(kinds) - set(allowed))
    problems = wrong[:6]
    if strange:
        problems.append("%d kind(s) outside the three set_type_for can return: %s"
                        % (len(strange), strange))
    if problems:
        bad("set_types_are_the_ones_the_importer_derives", "\n".join(problems))
    else:
        ok("set_types_are_the_ones_the_importer_derives",
           "all %d stored releases carry set_type_for's own answer, over the "
           "three kinds it can give: %s"
           % (len(rows), listing(sorted(kinds), kinds)))


def check_card_counts_are_the_sources(db_url, source, where):
    """Every set holds exactly the rows it owns, and its count is the source's own.

    Two facts that look like one and are not. card_count is the number of card
    *entries* the source lists for a release - 7,685 of them across the game
    where the catalogue holds 7,541 distinct ids - and the rows a release holds
    are the entries it lists that it *owns*, because a card is stored under the
    first release its own record names. So a promotional run holds its 207 cards,
    bt-08 lists 138 and holds 137 of them, and the three releases that carry
    nothing but reprints - the deck box set, the binder set and one promotion,
    between them 29 entries - hold no rows at all. That last case is the right
    answer and not a lost import, which is why this check no longer reads a count
    above zero as a promise of rows: it reads ownership instead, and a release
    that owns cards and holds none is still the failure it was written for.

    What is asserted, then: the stored ids of every release compared equal the ids
    that release lists and owns; the set row's card_count equals the count the
    source's own list states for it, which the sample's copy of the list carries
    for all 93 releases whether or not the network answers; every stored row
    carries an oracle id, or the printings of one card would stop grouping; and a
    release that owns nothing of what it lists says so in the detail, with the
    entries it lists and a tally of where those cards went.

    The ids each release lists are read live, one request per release through the
    importer's own release_envelope and card_ids_of. Ownership is not in that
    answer: a release envelope's included entries are stubs, so who owns a card is
    only in the card's own record, which costs a request each and is therefore
    asked only where the answer can change the verdict - a card two releases list,
    and a card a release lists without holding it. Everything else is owned by the
    one release that lists it. When the source refuses, the id half degrades to
    the five releases the sample cuts whole and the detail says which and why; the
    count half stays complete either way.

    The totals are printed, because the three numbers are the shape of this game:
    the entries the source's list counts upstream, the ids the catalogue holds,
    and the rows the releases compared own between them.
    """
    rows = psql(db_url, (
        "select id, set_code, oracle_id from public.catalog_cards where game = %s"
        % sql_text(GAME)), want_json=True)
    stored = {}
    oracles = set()
    null_oracles = 0
    for row in rows:
        stored.setdefault(row["set_code"], []).append(row["id"])
        if row.get("oracle_id") is None:
            null_oracles += 1
        else:
            oracles.add(row["oracle_id"])
    for code in stored:
        stored[code] = sorted(stored[code])
    counted = {row["code"]: int(row["card_count"]) for row in psql(db_url, (
        "select code, card_count from public.catalog_sets where game = %s"
        % sql_text(GAME)), want_json=True)}

    problems = []
    if null_oracles:
        problems.append("%d stored row(s) carry no oracle id, so the printings of "
                        "one card would not group under it" % null_oracles)

    # The count the tile shows, against the count the source's own list states.
    # The row's card_count is the source's number and stays the source's number:
    # what changed is what may be concluded from it, not what it is.
    unnamed = sorted(code for code in counted
                     if code not in source or source[code][1] is None)
    for code in sorted(counted):
        stated = source.get(code)
        if stated is None or stated[1] is None or counted[code] == stated[1]:
            continue
        problems.append("set %s records %d cards and the source's own list counts "
                        "%d for %s" % (code, counted[code], stated[1], stated[0]))

    # The rows each release holds, against the ids it lists and owns.
    listed, envelopes, why = read_release_lists(source, stored)
    if why is None:
        read_from = "the source's own release envelopes, read now"
    else:
        # The network refused, so the id half runs over the five releases the
        # sample cuts whole and says so rather than reporting a failure about a
        # connection. The count half above is complete either way.
        listed, envelopes = sample_release_lists(SAMPLE_SETS)
        read_from = "the sample's copies of the five releases the sample cuts"
    listers = listers_of(listed)
    owned = 0
    owning_none = []
    for code in sorted(listed):
        ids = listed[code]
        expected = sorted(card_id for card_id in ids
                          if owner_of(card_id, envelopes, listers[card_id]) == code)
        owned += len(expected)
        held = stored.get(code, [])
        if held == expected:
            if not held:
                owning_none.append(
                    "%s lists %d entries and owns none of them: %s"
                    % (code, counted.get(code, len(ids)),
                       gone_to(ids, envelopes, listers)))
            continue
        problems.append(
            "set %s holds %d row(s) and owns %d of the %d id(s) it lists: stored "
            "only %s, owned only %s"
            % (code, len(held), len(expected), len(ids),
               sorted(set(held) - set(expected))[:3],
               sorted(set(expected) - set(held))[:3]))

    if problems:
        bad("every_stored_set_holds_the_rows_its_release_lists",
            "\n".join(problems[:6]))
        return
    if not counted:
        bad("every_stored_set_holds_the_rows_its_release_lists",
            "no set rows to check")
        return

    entries = sum(count for _spelling, count in source.values()
                  if count is not None)
    distinct_ids = len({row["id"] for row in rows})
    notes = []
    if owning_none:
        notes.append("%d release(s) own none of what they list and hold no rows, "
                     "which is right: %s"
                     % (len(owning_none), "; ".join(owning_none[:3])))
    if why is not None:
        notes.append("the id half covers the %d release(s) the sample cuts whole, "
                     "because %s, so the other %d stored set(s) are compared "
                     "against the counts alone"
                     % (len(listed), why, len(counted) - len(listed)))
    if unnamed:
        notes.append("%d stored set(s) the list used here does not name (%s), "
                     "which are counts_match_the_source's business rather than "
                     "this check's"
                     % (len(unnamed), ", ".join(unnamed[:4])))
    note = "".join("; " + line for line in notes)
    biggest = sorted(counted, key=lambda code: (-counted[code], code))[:4]
    ok("every_stored_set_holds_the_rows_its_release_lists",
       "all %d stored releases: card_count is the count %s carries - %s - every "
       "row carries an oracle id, and the %d release(s) read from %s hold exactly "
       "the ids they list and own, %d row(s) between them; the list counts %d card "
       "entries upstream where the catalogue holds %d distinct ids in %d rows "
       "(%d distinct oracle ids)%s"
       % (len(counted), where,
          ", ".join("%s %d" % (code, counted[code]) for code in sorted(biggest)),
          len(listed), read_from, owned, entries, distinct_ids, len(rows),
          len(oracles), note))


def check_row_parity(db_url):
    """The rows the importer derives, against the rows in Postgres.

    This is the claim the whole step rests on. tool/catalog/test_id_parity.py
    proves the two languages derive the same rows from the same responses; this
    proves the rows in the database are the rows the importer derives from those
    responses, which is a different statement - an import that predates a rule
    change satisfies the first and fails this.

    Every column of every sampled card is compared, the id excepted: 553 rows
    over 34 columns. The sample's 93 set rows are compared over every column of a
    set row as well, card_count included and with no carve-out at all - unlike
    the Star Wars: Unlimited proof, where the count lives in a request the sample
    does not hold. Here the count is in the set list, and the sample holds the
    whole set list, so the column the tile draws is compared like any other.

    Nothing is exempt, and this game's own rule is why nothing has to be: a card
    is filed under the first release its own record names, and the sample holds
    every card's own record. So the sample derives the row the catalogue holds for
    a card wherever that card sits - including a card one of the five sampled
    releases lists and another release owns, because the owner is read from the
    card's record rather than from the release that happened to read it. The
    columns that name the release are therefore compared like every other column,
    and a row filed by an import that predates this rule fails here instead of
    passing quietly under a weaker assertion.
    """
    sample = read_json_gz(SAMPLE)
    problems = []

    derived = test_id_parity.digimon_cards(sample)
    columns = vectors_card_columns()
    ids = sorted(derived)
    live = psql(db_url, (
        "select %s from public.catalog_cards where game = %s and id = any (%s)"
        % (", ".join(["id"] + columns), sql_text(GAME), sql_array(ids))),
        want_json=True)
    by_id = {row["id"]: row for row in live}
    missing = [i for i in ids if i not in by_id]
    if missing:
        problems.append("%d of the sample's %d cards are not in the database, "
                        "e.g. %s" % (len(missing), len(ids), missing[:3]))
    cards_differing = 0
    for card_id in ids:
        row, live_row = derived.get(card_id), by_id.get(card_id)
        if live_row is None:
            continue
        for column in columns:
            if not same(row.get(column), live_row.get(column)):
                cards_differing += 1
                if cards_differing <= 6:
                    problems.append("%s.%s: database %r != importer %r"
                                    % (card_id, column, live_row.get(column),
                                       row.get(column)))
                break
    if cards_differing > 6:
        problems.append("... and %d more card row(s) differ" % (cards_differing - 6))

    derived_sets = test_id_parity.digimon_sets(sample)
    set_columns = list(catalog_store.SET_COLUMNS)
    codes = sorted(derived_sets)
    live_sets = psql(db_url, (
        "select %s from public.catalog_sets where game = %s and code = any (%s)"
        % (", ".join(set_columns), sql_text(GAME), sql_array(codes))), want_json=True)
    by_code = {row["code"]: row for row in live_sets}
    missing_sets = [code for code in codes if code not in by_code]
    if missing_sets:
        problems.append("the sample lists %d set(s) the catalogue does not hold: "
                        "%s" % (len(missing_sets), missing_sets[:4]))
    sets_differing = 0
    for code in codes:
        live_row = by_code.get(code)
        if live_row is None:
            continue
        for column in set_columns:
            if not same(derived_sets[code].get(column), live_row.get(column)):
                sets_differing += 1
                if sets_differing <= 6:
                    problems.append("set %s.%s: database %r != importer %r"
                                    % (code, column, live_row.get(column),
                                       derived_sets[code].get(column)))
                break
    if sets_differing > 6:
        problems.append("... and %d more set row(s) differ"
                        % (sets_differing - 6))

    rows = psql(db_url, (
        "select code from public.catalog_sets where game = %s"
        " and not (code = any (%s)) order by code"
        % (sql_text(GAME), sql_array(codes))))
    unseen = [row[0] for row in rows]

    if problems:
        bad("imported_rows_equal_the_importer_derivation", "\n".join(problems))
        return
    note = ("" if not unseen else
            "; the %d stored set(s) the sample does not list (%s) are the ones "
            "that went up after it was cut, and counts_match_the_source is the "
            "live statement about those" % (len(unseen), ", ".join(unseen[:4])))
    ok("imported_rows_equal_the_importer_derivation",
       "all %d of the sample's cards match the rows the importer derives in "
       "every one of the %d columns beside the id, with set_code and set_name "
       "among them - a card is filed under the release its own record names, and "
       "the sample holds every record - and its %d set rows match in all %d "
       "columns of a set row, card_count included, because this game's count is "
       "in the set list the sample holds whole%s"
       % (len(ids), len(columns), len(codes), len(set_columns), note))


def check_ids_are_the_sources_own(db_url):
    """Every stored id is an id the source states, in two halves.

    The one failure in this design that no log would show: an id that moved
    turns a collection row into "--" and nothing anywhere says why. So this is
    asserted twice, over two different bodies of evidence, and both times
    against the source's own spelling rather than against a number remembered
    from the import.

    A release's stored ids are the ids it lists *and owns*, and the two are not
    the same list: the source lists a card under every release that carries it
    while the card belongs to the first release its own record names. P-058 is
    the case to hold on to - bt-08 lists it and p owns it, because its own record
    is [p, bt-08] - so 'p' holds all 207 ids it lists and bt-08 holds 137 of its
    138. What is compared, for each of the five sampled releases, is therefore
    the ids its envelope lists whose owner is itself, the owner read through the
    importer's own releases_of and slug. Both differences are printed, and the id
    a release lists and does not own is named in the detail with the record that
    decided it.

    None of that can see a source that has added or renumbered since the sample
    was cut, which is why one release is then asked of the source now: bt-08,
    live, whose own 'included' array names its cards one id at a time. There the
    envelope gives the ids and the open question is only about the ids it lists
    and does not hold: a row under a release can only have come from that
    release's own walk, so an id bt-08 holds is bt-08's by construction and needs
    no asking, while an id bt-08 lists and does not hold has to be owned by
    another release that holds it - read from its own record, one request per
    such id through the importer's own card_envelope, which for this game is one
    card. An id the source lists that no row holds at all is the failure this
    half exists for.
    """
    sample = read_json_gz(SAMPLE)
    envelopes = sample.get("cards") or {}
    problems = []
    compared = 0
    note = ""
    for slug, card_ids in test_id_parity.digimon_set_downloads(sample).items():
        code = digimon.slug(slug)
        if not code or not card_ids:
            continue
        expected = sorted(card_id for card_id in card_ids
                          if owner_of(card_id, envelopes, [code]) == code)
        not_owned = sorted(set(card_ids) - set(expected))
        stored = sorted(row[0] for row in psql(db_url, (
            "select id from public.catalog_cards where game = %s and set_code = %s"
            % (sql_text(GAME), sql_text(code)))))
        compared += len(stored)
        if not_owned and not note:
            held = owner_of(not_owned[0], envelopes, [code])
            note = ("; %s is listed by %s and owned by %s, because its own record "
                    "names [%s]" % (not_owned[0], slug, held,
                                    ", ".join(digimon.releases_of(
                                        (envelopes.get(not_owned[0]) or {})
                                        .get("data")))))
        if stored != expected:
            problems.append(
                "set %s holds %d ids where the %d it lists and owns are another "
                "set: stored only %s, expected only %s (%d of its %d listed ids "
                "belong to another release)"
                % (code, len(stored), len(expected),
                   sorted(set(stored) - set(expected))[:3],
                   sorted(set(expected) - set(stored))[:3],
                   len(not_owned), len(card_ids)))

    try:
        live = sorted(digimon.card_ids_of(digimon.release_envelope(LIVE_SET)))
    except Exception as exc:  # noqa: BLE001 - reported, with the reason
        live, why, elsewhere = [], str(exc), []
    else:
        why = None
        stored = sorted(row[0] for row in psql(db_url, (
            "select id from public.catalog_cards where game = %s and set_code = %s"
            % (sql_text(GAME), sql_text(digimon.slug(LIVE_SET))))))
        invented = sorted(set(stored) - set(live))
        elsewhere = sorted(set(live) - set(stored))
        if invented:
            problems.append(
                "set %s holds %d id(s) its own envelope does not list for it now, "
                "e.g. %s" % (LIVE_SET, len(invented), invented[:3]))
        if elsewhere:
            records, filed = {}, {}
            try:
                records = digimon.card_envelopes(elsewhere, LIVE_SET)
                rows = psql(db_url, (
                    "select id, set_code from public.catalog_cards where game = %s"
                    " and id = any (%s)"
                    % (sql_text(GAME), sql_array(elsewhere))), want_json=True)
                filed = {row["id"]: row["set_code"] for row in rows}
            except Exception as exc:  # noqa: BLE001 - reported, with the reason
                why = ("the records of the %d id(s) %s lists and does not hold "
                       "could not be read: %s" % (len(elsewhere), LIVE_SET, exc))
            else:
                for card_id in elsewhere:
                    owner = owner_of(card_id, records, [digimon.slug(LIVE_SET)])
                    named = digimon.releases_of((records.get(card_id) or {})
                                                .get("data"))
                    if owner == digimon.slug(LIVE_SET):
                        problems.append(
                            "%s is listed by %s, is held by no row there, and its "
                            "own record names %s, so %s is where its row belongs"
                            % (card_id, LIVE_SET,
                               "[%s]" % ", ".join(named) if named
                               else "no release at all", owner))
                    elif filed.get(card_id) != owner:
                        problems.append(
                            "%s is listed by %s and owned by %s, and the catalogue "
                            "stores it under %r"
                            % (card_id, LIVE_SET, owner, filed.get(card_id)))

    if problems:
        bad("every_stored_id_is_the_sources_own", "\n".join(problems))
        return
    if why is not None:
        skip("every_stored_id_is_the_sources_own (the live half)",
             "the five sampled releases hold the ids the committed sample states "
             "- %d stored ids, in every case the ids the release lists and owns%s "
             "- but %s could not be read: %s"
             % (compared, note, LIVE_SET, why))
        return
    ok("every_stored_id_is_the_sources_own",
       "%d stored ids across the five sampled releases are the ids those "
       "releases list and own, so a card the source lists twice is held once, "
       "under the release its own record names first%s; and %s holds %d ids the "
       "source states for it now, with the %d it lists and does not own held "
       "under the release its record names: verbatim in both halves"
       % (compared, note, LIVE_SET, len(live) - len(elsewhere),
          len(elsewhere)))


def check_parallels_are_their_own_rows(db_url):
    """A parallel is a row of its own, grouped with its base and numbered as it.

    The source names a printing once and both languages forward that name
    verbatim - BT5-007_P3 beside BT5-007 - and the suffix is what keeps the
    parallel a printing a collector can hold separately, while the oracle id,
    the same id with the suffix taken off, is what groups the two. What must not
    happen is the collapse: a parallel stored under its base's id would look
    unique, would store, and would merge two holdings into one for ever.

    Where this game differs from Star Wars: Unlimited is the printed number.
    There a hyperspace card counts its own run and has to be renumbered to its
    base's number; here the source prints the *base's* number on every parallel,
    so the two rows share a collector number and must, because a binder slot is
    a (name, number) pair - 106 of the sample's 553 cards are parallels and every
    one of them shares its base's number. That is asserted over every stored
    parallel whose base row is stored, and the suffix rule itself over every
    stored row whose id carries one, through the importer's own base_id_of
    rather than through a regexp written here.

    The base row a parallel points at is asserted to be present wherever the
    sample holds it, so a base printing dropped by an import shows up as the
    missing row it is. The count of parallels is floored as well: a catalogue
    whose rows carried no suffix at all would make every assertion above true
    and empty, and 3,331 of the game's cards are parallels.
    """
    rows = psql(db_url, (
        "select id, oracle_id, collector_number, set_code"
        " from public.catalog_cards where game = %s" % sql_text(GAME)),
        want_json=True)
    numbers = {row["id"]: row.get("collector_number") for row in rows}
    parallels = [row for row in rows if digimon.base_id_of(row["id"]) != row["id"]]
    sample_ids = set(read_json_gz(SAMPLE).get("cards") or {})

    problems = []
    if len(parallels) < 50:
        problems.append("only %d stored row(s) carry a parallel suffix, too few "
                        "for this check to prove anything" % len(parallels))
    beside = 0
    for row in parallels:
        card_id = row["id"]
        base = digimon.base_id_of(card_id)
        if row.get("oracle_id") != base:
            problems.append("%s groups under %r rather than under the base card "
                            "it is a version of, %s"
                            % (card_id, row.get("oracle_id"), base))
        if row.get("id") == row.get("oracle_id"):
            problems.append("%s is stored under the id of the base it is a "
                            "version of, which is the collapse this rule exists "
                            "to stop" % card_id)
        if base not in numbers:
            if base in sample_ids:
                problems.append("%s is stored and the base printing the sample "
                                "holds for it, %s, is not" % (card_id, base))
            continue
        beside += 1
        if numbers[base] != row.get("collector_number"):
            problems.append("%s carries collector number %r where its base card "
                            "%s carries %r, so the two printings of one card "
                            "land in two binder slots"
                            % (card_id, row.get("collector_number"), base,
                               numbers[base]))

    if problems:
        bad("a_parallel_is_its_own_row_numbered_as_its_base", "\n".join(problems))
        return
    example = sorted(parallels, key=lambda row: row["id"])[0]
    ok("a_parallel_is_its_own_row_numbered_as_its_base",
       "all %d stored parallels keep their own id, take their base card's "
       "oracle id and share its collector number - e.g. %s beside %s - and no "
       "row is stored under the id of the base it points at; the %d whose base "
       "row is stored were compared with it"
       % (len(parallels), example["id"], digimon.base_id_of(example["id"]),
          beside))


def check_art_is_the_sources_own_address(db_url):
    """The stored art is the source's own address, not a relayed one.

    images.heroi.cc sends no Access-Control-Allow-Origin, which is the property
    tcgcsv lacks and the whole reason Arcanum's relay exists: CardArt.host
    rewrites a relayed host's URL on a web build while the client parses, so a
    row that already named the relay would be a row a phone could not load. The
    address the catalogue stores is therefore asserted to be the source's own -
    over every row, on the host, and never with /arcanumweb-api/art/ in it.

    The second half is the format. The source serves WebP, and 553 of the 553
    records the sample holds end in .webp; what is asserted is that at least 90%
    of the stored addresses do, because a record the source later serves in
    another format is a curiosity while a set of rows pointing somewhere else
    entirely is the failure this check is for.
    """
    rows = psql(db_url, (
        "select id, image_normal from public.catalog_cards where game = %s"
        % sql_text(GAME)), want_json=True)
    relayed = [row["id"] for row in rows
               if isinstance(row.get("image_normal"), str)
               and RELAYED in row["image_normal"]]
    missing = [row["id"] for row in rows if row.get("image_normal") is None]
    wrong_host = [row["id"] for row in rows
                  if isinstance(row.get("image_normal"), str)
                  and not row["image_normal"].startswith(ART_HOST)]
    webp = [row["id"] for row in rows
            if isinstance(row.get("image_normal"), str)
            and row["image_normal"].endswith(".webp")]
    problems = []
    if relayed:
        problems.append("%d row(s) store a relayed URL, e.g. %s"
                        % (len(relayed), relayed[:3]))
    if wrong_host:
        problems.append("%d row(s) carry art from another host, e.g. %s"
                        % (len(wrong_host), wrong_host[:3]))
    if missing:
        problems.append("%d row(s) carry no art at all, e.g. %s"
                        % (len(missing), missing[:3]))
    if not rows:
        problems.append("no card rows to check")
    elif len(webp) * 10 < len(rows) * 9:
        problems.append("only %d of %d stored addresses (%d%%) end in .webp, "
                        "where the source serves WebP for every record the "
                        "sample holds" % (len(webp), len(rows),
                                          100 * len(webp) // len(rows)))

    if problems:
        bad("stored_art_is_the_sources_own_address", "\n".join(problems))
    else:
        ok("stored_art_is_the_sources_own_address",
           "all %d rows carry art on images.heroi.cc with no relayed address "
           "among them, and %d of them (%d%%) end in .webp, which is the format "
           "the source serves"
           % (len(rows), len(webp), 100 * len(webp) // len(rows)))


def check_the_fallback_files_a_card_under_its_printed_number():
    """The branch the sample cannot put in the database, asserted as a rule.

    A card the source files under no release is unreachable by a set walk: a
    walk starts from a release's own card list, so no import can ever reach
    BT1-010_P3 and no stored row exists to compare it with. What is asserted
    here is therefore the rule the importer and the client both implement rather
    than a row - and it is asserted through the importer's own card_document
    with no set_code, because that is the shape of the call the client makes
    when it reaches a card by its id alone.

    The rule is the printed number read as it stands and *not* folded. The card
    prints BT1-010, so its set code is 'bt1'; the release that carries the rest
    of its family is bt01-03-v1-0, whose fold begins 'bt01' and is bt0103v10 in
    full. The fallback's answer is deliberately the other one, and it is what
    the app's own read paths hold: 'bt1' is not a code any release folds to, so
    a card like this is found by its number and its id and never under a release.

    The sample's agumon search holds exactly one card that names no release, and
    the check asserts that premise as well as the rule: if the source ever files
    that card under a release, or files another card under none, this says so
    instead of quietly testing something else.
    """
    searches = read_json_gz(SAMPLE).get("searches") or {}
    envelope = searches.get(FALLBACK_SEARCH)
    rows = (envelope or {}).get("data") if isinstance(envelope, dict) else None
    if not isinstance(rows, list) or not rows:
        bad("the_fallback_files_a_card_under_its_printed_number",
            "the sample holds no %r search answer to read" % FALLBACK_SEARCH)
        return

    unreleased = [row for row in rows
                  if isinstance(row, dict) and not digimon.releases_of(row)]
    problems = []
    if len(unreleased) != 1:
        problems.append("the sample's %s search holds %d card(s) naming no "
                        "release, where this check is about the one it has "
                        "always been about" % (FALLBACK_SEARCH, len(unreleased)))
    if not unreleased:
        bad("the_fallback_files_a_card_under_its_printed_number",
            "\n".join(problems))
        return

    row = unreleased[0]
    card_id = digimon.slug_of(row, digimon.CARDS)
    printed = (row.get("attributes") or {}).get("number")
    if card_id != FALLBACK_CARD or printed != FALLBACK_NUMBER:
        problems.append("the release-less card the sample holds is %s printing "
                        "%r, where this check is about %s printing %s"
                        % (card_id, printed, FALLBACK_CARD, FALLBACK_NUMBER))

    document = digimon.card_document({"data": row})
    if document is None:
        problems.append("the importer derives no row at all for %s" % card_id)
        bad("the_fallback_files_a_card_under_its_printed_number",
            "\n".join(problems))
        return
    by_number = digimon.code_of_number(printed)
    code = document.get("set_code")
    if code != by_number:
        problems.append("%s is filed under %r and the importer's own "
                        "code_of_number gives %r for the number it prints"
                        % (card_id, code, by_number))
    if code == "bt01":
        problems.append("%s is filed under 'bt01', the folded spelling a release "
                        "code would give, where the fallback reads the number as "
                        "printed and answers 'bt1'" % card_id)
    held = sorted(folded for folded in sample_releases() if folded == code)

    if problems:
        bad("the_fallback_files_a_card_under_its_printed_number",
            "\n".join(problems))
        return
    ok("the_fallback_files_a_card_under_its_printed_number",
       "%s names no release, prints %s and is filed under %r by the importer's "
       "own card_document with no set_code - the printed prefix lower-cased and "
       "not folded, where the release that carries its family, bt01-03-v1-0, "
       "folds to bt0103v10%s. That card is not in the catalogue and cannot be: "
       "no release lists it, so no walk reaches it and there is no stored row "
       "to compare - what is asserted here is the rule both languages apply"
       % (card_id, printed, code,
          "" if not held else ", and %d release(s) in the list fold to it" % len(held)))


def check_no_price_rows(db_url):
    """The source quotes no price, so the importer writes none - in code and in data.

    No key matching /price/i appears in a card record of this source, and there
    is no TCGplayer product id on a record to join a price series to - extras
    deliberately carries no 'tcgplayerId'. replace_prices therefore has nothing
    to be handed, and this asserts both halves of that: the module never calls
    it, and the table holds no row for this game. A price row appearing here
    would be a number from nowhere, and a column of "--" on the card sheet is
    the honest state until a priced source for this game exists.
    """
    # Read off the module's syntax tree rather than its text: the file names
    # replace_prices in its own docstring and in the function that would call it
    # - twice, to say that it is *not* called - and a grep that cannot tell a
    # sentence from a call reports a failure on this very fact.
    with open(os.path.join(TOOL, "import_digimon_catalogue.py"),
              encoding="utf-8") as fh:
        tree = ast.parse(fh.read())
    calls = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        name = (func.attr if isinstance(func, ast.Attribute)
                else func.id if isinstance(func, ast.Name) else None)
        if name == "replace_prices":
            calls.append(getattr(node, "lineno", 0))
    problems = []
    if calls:
        problems.append("the importer calls replace_prices at line(s) %s, and "
                        "this source quotes no price to give it" % calls)
    rows = psql(db_url, (
        "select count(*) from public.catalog_prices where game = %s"
        % sql_text(GAME)))
    stored = int(rows[0][0])
    if stored:
        problems.append("catalog_prices holds %d row(s) for this game" % stored)
    if problems:
        bad("the_importer_writes_no_price_and_the_table_holds_none",
            "\n".join(problems))
    else:
        ok("the_importer_writes_no_price_and_the_table_holds_none",
           "the importer never calls replace_prices and catalog_prices holds no "
           "row for this game, which is what a source that quotes no price "
           "should leave behind")


def check_the_importer_cannot_delete_a_set():
    """The module emits no statement that removes a set, and never a bare delete.

    Read off the code rather than the database, because "cannot" is a claim about
    what may be generated. A set is the unit this design refuses to destroy: its
    cards are what a collection row's id resolves against, so a deleted set is
    somebody's holdings turning into "--".
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
            problems.append("an unscoped delete is emitted: %s" % statement[:80])
        elif "game =" not in statement or "set_code =" not in statement:
            problems.append("a delete not scoped to one game and set: %s"
                            % statement[:80])

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

    Design rule 4, exercised through the store's own retire_sets rather than
    through hand-written SQL: one published set is left out of the upstream list,
    which retires it, and the list is then handed over whole, which un-retires
    it. What is asserted in between is the point of the rule - the set row is
    still there, and so is every card in it, so the holdings that name those
    card ids still resolve.

    The list handed over is in stored form, because that is the spelling
    retire_sets compares against: the source spells a release 'bt-05' where the
    catalogue stores 'bt05', and a run that handed the source's spelling to this
    call would retire all 93 sets and look as though it had worked.
    """
    rows = psql(db_url, (
        "select code from public.catalog_sets where game = %s"
        " and retired_at is null order by code" % sql_text(GAME)))
    codes = [row[0] for row in rows]
    if len(codes) < 2:
        skip("a_retired_set_keeps_its_row_and_its_cards",
             "only %d live set(s) to experiment on" % len(codes))
        return
    victim = codes[0]

    store = catalog_store.CatalogStore(
        os.environ.get("SUPABASE_DB_URL")
        or os.environ.get("SUPABASE_DB_URL_POOLED"),
        psql=catalog_store.find_psql())

    def snapshot():
        rows = psql(db_url, (
            "select (select count(*) from public.catalog_sets"
            "         where game = %s and retired_at is null),"
            "       (select count(*) from public.catalog_sets"
            "         where game = %s and code = %s),"
            "       (select count(*) from public.catalog_cards"
            "         where game = %s and set_code = %s)"
            % (sql_text(GAME), sql_text(GAME), sql_text(victim),
               sql_text(GAME), sql_text(victim))))
        return tuple(int(v) for v in rows[0])

    live_before, row_before, cards_before = snapshot()
    try:
        store.retire_sets(GAME, [c for c in codes if c != victim])
        live_retired, row_retired, cards_retired = snapshot()
        store.retire_sets(GAME, codes)
        live_after, row_after, cards_after = snapshot()
    except Exception as exc:  # noqa: BLE001 - reported, and the set is put back
        with contextlib.suppress(Exception):
            # The experiment failed halfway, so the set may be hidden while the
            # account tables read as though it were not. Put it back before
            # reporting, and report the failure either way.
            store.retire_sets(GAME, codes)
        bad("a_retired_set_keeps_its_row_and_its_cards",
            "the retirement experiment failed: %s" % exc)
        return

    problems = []
    if live_retired != live_before - 1:
        problems.append("retiring one set left %d visible, expected %d"
                        % (live_retired, live_before - 1))
    if row_retired != 1:
        problems.append("the retired set's row is gone (%d found)" % row_retired)
    if cards_retired != cards_before:
        problems.append("the retired set lost cards: %d -> %d"
                        % (cards_before, cards_retired))
    if (live_after, row_after, cards_after) != (live_before, row_before,
                                                cards_before):
        problems.append("re-publishing the set did not restore it exactly")

    if problems:
        bad("a_retired_set_keeps_its_row_and_its_cards", "\n".join(problems))
    else:
        ok("a_retired_set_keeps_its_row_and_its_cards",
           "set %r left out of the upstream list was retired rather than deleted "
           "- its row and its %d cards were still there (%d sets visible) - and "
           "handing the list over whole restored all %d sets"
           % (victim, cards_before, live_retired, live_after))


def check_meta(db_url, sets, cards):
    """catalog_meta says what the run left behind, including that it left no prices.

    A client reads this row at boot to decide whether its cache is stale, so a
    false last_import_ok is a browser that never refreshes and a missing source is
    a game nothing can attribute. prices_revision is asserted to be zero and not
    merely unmentioned: this importer has no price half, so a price revision that
    moved would be a night whose prices nobody can explain.
    """
    rows = psql(db_url, (
        "select sets_revision, prices_revision, set_count, card_count,"
        "       last_import_ok, coalesce(last_import_note, ''),"
        "       coalesce(source, ''), sets_updated_at is not null"
        "  from public.catalog_meta where game = %s" % sql_text(GAME)))
    if not rows:
        bad("catalog_meta_records_the_import",
            "catalog_meta holds no row for %s, so a client cannot tell whether "
            "it has ever been imported" % GAME)
        return 0
    revision, prices, set_count, card_count, ok_flag, note, source, dated = rows[0]
    problems = []
    if ok_flag != "t":
        problems.append("last_import_ok is false")
    if int(set_count) != sets or int(card_count) != cards:
        problems.append("catalog_meta says %s/%s, the tables hold %d/%d"
                        % (set_count, card_count, sets, cards))
    if source != SOURCE:
        problems.append("source is %r, expected %r" % (source, SOURCE))
    if dated != "t":
        problems.append("sets_updated_at is null")
    if not note:
        problems.append("last_import_note is empty")
    if int(revision) <= 0:
        problems.append("sets_revision is %s: no client has ever been told its "
                        "set list is stale" % revision)
    if int(prices) != 0:
        problems.append("prices_revision is %s, and this importer writes no "
                        "prices at all" % prices)
    if problems:
        bad("catalog_meta_records_the_import", "\n".join(problems))
    else:
        ok("catalog_meta_records_the_import",
           "sets_revision %s, prices_revision %s, %s sets, %s cards, source %s, "
           "note: %s" % (revision, prices, set_count, card_count, SOURCE, note))
    return int(revision)


def check_checksums(db_url, sets):
    """Every set carries a checksum, so an unchanged night costs one comparison.

    The checksum is what makes the nightly run cheap and what makes this proof's
    re-run check possible at all: a set with no checksum is rewritten every night
    whether or not anything upstream changed, which is a hundred thousand row
    writes for nothing and a cards_revision that moves for no reason a client can
    see.
    """
    rows = psql(db_url, (
        "select count(*) from public.catalog_sets"
        " where game = %s and (cards_checksum is null"
        "   or cards_checksum = '' or cards_revision = 0 or catalogued_at is null)"
        % sql_text(GAME)))
    incomplete = int(rows[0][0])
    if incomplete:
        bad("every_set_carries_a_checksum_and_a_revision",
            "%d of %d sets have no checksum, revision or catalogued_at, so the "
            "next run would rewrite them" % (incomplete, sets))
    else:
        ok("every_set_carries_a_checksum_and_a_revision",
           "all %d sets carry a checksum, a non-zero cards_revision and a "
           "catalogued_at, so an unchanged night costs one comparison" % sets)


def check_catalogue_is_still_read_only(db_url):
    """The catalogue is readable by a client and writable only by its owner.

    Design section 2.4's posture, asked of the database rather than assumed: the
    publishable key ships inside the web bundle, so a grant it should not have is
    a catalogue every browser can rewrite. This is step 0's posture re-asserted
    after an import, because the cheapest way to break a grant is to add a table
    or a policy while moving one game's rows into place.
    """
    names = ",".join(sql_text(t) for t in CATALOG_TABLES)
    rows = psql(db_url, (
        "select grantee, table_name,"
        "       coalesce(string_agg(distinct privilege_type, ',' order by "
        "privilege_type), '')"
        "  from information_schema.role_table_grants"
        " where table_schema = 'public'"
        "   and table_name in (%s)"
        "   and grantee in ('anon','authenticated')"
        " group by 1, 2 order by 2, 1" % names))
    seen = {(g, t): p for g, t, p in rows}
    problems = ["%s on %s: %s" % (g, t, seen.get((g, t), "no grants"))
                for t in CATALOG_TABLES
                for g in ("anon", "authenticated")
                if seen.get((g, t)) != "SELECT"]
    if problems:
        bad("catalogue_is_still_select_only_for_clients", "\n".join(problems))
    else:
        ok("catalogue_is_still_select_only_for_clients",
           "anon and authenticated hold SELECT on all four tables and nothing "
           "else, so this import did not widen the posture step 0 fixed")


def check_http(base, key, sets, card_id):
    """A client holding the publishable key reads the catalogue and cannot write it.

    The read half is what a browser does with this key: the game's set list, one
    card by its id, and the range header that tells a client how many card rows
    it may expect. The id is one the sample states and
    check_ids_are_the_sources_own has compared with the database, so a failure
    here is about the key's reach and not about which card was asked for.

    The write half is the claim the SQL grant check makes, asked from outside.
    The body is an empty JSON array, which is an insert of zero rows: a posture
    that has regressed writes nothing even as this catches it, and nothing has to
    be cleaned up afterwards. The publishable key is the anon role, which
    PostgREST answers with 401 when it lacks the privilege - 403 is accepted too,
    because a key that resolved to a signed-in role would be refused the same way
    and the point of the check is the refusal, not its code.
    """
    problems = []
    read = ""
    status, body, _ = postgrest_get(
        base, "catalog_sets?game=eq.%s&select=code&limit=1000" % GAME, key)
    if status not in (200, 206) or not isinstance(body, list):
        problems.append("catalog_sets answered HTTP %s" % status)
    else:
        read = "%d sets" % len(body)
        if len(body) != sets:
            problems.append("the publishable key sees %d sets, the importer "
                            "wrote %d" % (len(body), sets))

    if card_id is None:
        problems.append("the sample states no card id to read back")
    else:
        status, one, _ = postgrest_get(
            base, "catalog_cards?game=eq.%s&id=eq.%s&select=id,name,set_code"
            % (GAME, card_id), key)
        if status not in (200, 206) or not isinstance(one, list) or len(one) != 1:
            problems.append("card %s read back HTTP %s with %d rows"
                            % (card_id, status, len(one or [])))
        else:
            read += ", and %s reads back as %r in set %r" % (
                card_id, one[0].get("name"), one[0].get("set_code"))

    status, _, headers = postgrest_get(
        base, "catalog_cards?game=eq.%s&select=id&limit=1" % GAME, key)
    total = headers.get("Content-Range", "")

    status, text = http_send(
        "%s/rest/v1/catalog_sets" % base.rstrip("/"), "POST",
        {"apikey": key, "Accept": "application/json",
         "Content-Type": "application/json", "Prefer": "return=minimal"}, [])
    refusal = "catalog_sets refused the insert with HTTP %d" % status
    if status not in (401, 403):
        problems.append("catalog_sets answered HTTP %s to an insert by the "
                        "publishable key, which is not the refusal this posture "
                        "promises: %s" % (status, (text or "").strip()[:120]))
        refusal = ""

    if problems:
        bad("publishable_key_reads_the_catalogue_and_cannot_write_it",
            "\n".join(problems))
    else:
        ok("publishable_key_reads_the_catalogue_and_cannot_write_it",
           "%s and catalog_cards range %s are readable, and %s - an empty array, "
           "so no row was written either way"
           % (read, total or "not reported", refusal))


def check_rerun_changes_nothing(db_url, sets, cards, revision, skip_rerun):
    """Re-runs the importer over unchanged data and compares everything it could move.

    The second run is the only one that can prove the checksum skip, so the second
    run happens. It is bounded to the five releases the committed sample holds
    whole, and every set in the game is compared afterwards, because a run that
    named a subset must touch that subset and nothing else - and because the
    importer withholds the upstream list for a named subset, so it must not retire
    the 88 releases it was not asked for. The codes are handed over in the
    sample's own spelling, which is what the source addresses a release by and
    what the importer folds before it compares anything.

    Counts alone would not catch a run that rewrote every row to the same values;
    the checksums, the revisions and catalogued_at are compared too, so a rewrite
    shows up even when the content is identical.
    """
    if skip_rerun:
        skip("rerun_changes_nothing", "not run: --skip-rerun")
        return

    importer = os.path.join(TOOL, "import_digimon_catalogue.py")
    if not os.path.exists(importer) or not shutil.which(sys.executable):
        skip("rerun_changes_nothing", "no importer at %s" % importer)
        return

    def snapshot():
        return psql(db_url, (
            "select code, coalesce(cards_checksum, ''), cards_revision,"
            "       card_row_count, catalogued_at::text"
            "  from public.catalog_sets where game = %s order by code"
            % sql_text(GAME)))

    before = snapshot()
    proc = subprocess.run(
        [sys.executable, importer, "--sets", ",".join(SAMPLE_SETS)],
        capture_output=True, text=True, timeout=3600,
        cwd=os.path.dirname(importer), env=os.environ)
    if proc.returncode != 0:
        bad("rerun_changes_nothing",
            "the second run exited %d: %s" % (proc.returncode,
                                              proc.stderr.strip()[:300]))
        return
    after = snapshot()

    if before != after:
        changed = [(b[0], b[2], a[2]) for b, a in zip(before, after) if b != a]
        bad("rerun_changes_nothing",
            "%d set(s) moved on a second run, e.g. %s (code, revision before, "
            "revision after)" % (len(changed), changed[:3]))
        return

    counts = psql(db_url, (
        "select (select count(*) from public.catalog_sets where game = %s),"
        "       (select count(*) from public.catalog_cards where game = %s),"
        "       (select sets_revision from public.catalog_meta where game = %s)"
        % (sql_text(GAME), sql_text(GAME), sql_text(GAME))))
    new_sets, new_cards, new_revision = (int(v) for v in counts[0])
    if (new_sets, new_cards) != (sets, cards) or new_revision != revision:
        bad("rerun_changes_nothing",
            "after the second run: %d sets, %d cards, revision %d; expected %d, "
            "%d, %d" % (new_sets, new_cards, new_revision, sets, cards, revision))
    else:
        ok("rerun_changes_nothing",
           "the second run rewrote no set: all %d keep their checksum, "
           "cards_revision and catalogued_at, so the five releases it was asked "
           "for were skipped on their checksums and the other %d were never "
           "touched; sets_revision stayed %d"
           % (sets, sets - len(SAMPLE_SETS), revision))


def check_account_tables(db_url, before):
    """The account tables hold exactly what they held before any of this ran.

    decks and collection_entries are a collector's own data and are not part of
    the catalogue. catalog_store refuses every statement that names them, and
    this is the check that says the refusal held for a whole run rather than for
    the statement that was read.
    """
    rows = psql(db_url, (
        "select (select count(*) from public.decks),"
        "       (select count(*) from public.collection_entries)"))
    decks, entries = (int(v) for v in rows[0])
    if (decks, entries) != before:
        bad("account_tables_are_unchanged",
            "decks/collection_entries went from %s to %s"
            % (before, (decks, entries)))
    else:
        ok("account_tables_are_unchanged",
           "decks %d, collection_entries %d, exactly as before the run"
           % (decks, entries))


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

    db_url = (os.environ.get("SUPABASE_DB_URL")
              or os.environ.get("SUPABASE_DB_URL_POOLED"))
    if not db_url or not shutil.which("psql"):
        print("this proof needs psql and a database URL; neither is optional here",
              file=sys.stderr)
        return 2
    db_url, _was_pooled = session_url(db_url)

    for path in (VECTORS, SAMPLE):
        if not os.path.exists(path):
            print("missing %s" % path, file=sys.stderr)
            return 2

    # The account tables first: if the import damaged them, that should be the
    # headline rather than a line at the bottom.
    rows = psql(db_url, (
        "select (select count(*) from public.decks),"
        "       (select count(*) from public.collection_entries)"))
    accounts_before = tuple(int(v) for v in rows[0])

    print("--- SQL, as the owner ---")

    # The source's own list, live if it answers. When it does not, the checks
    # below still run: counts_match_the_source keeps its structural half, and the
    # count per release is compared against the sample's own copy of the list,
    # which is the same 93 releases as they stood when it was cut.
    releases, why = live_releases()
    if releases is None:
        skip("counts_match_the_source (the source's own release list)",
             "%s could not be read: %s. The stored set list is still checked for "
             "structure and against its own rows, and each set's count is "
             "compared against the sample's own copy of the list, but not "
             "against the live list" % (PROVIDER, why))
        counted, counted_from = sample_releases(), \
            "the sample's own copy of the source's set list"
    else:
        counted, counted_from = releases, "the source's own list, read now"

    sets, cards = check_counts(db_url, releases)
    if not sets:
        print()
        print("the catalogue holds no Digimon release, so there is nothing here "
              "to prove")
        return 1

    check_orphans(db_url)
    check_stored_codes_are_the_folded_form(db_url)
    check_set_types_are_the_importers(db_url)
    check_card_counts_are_the_sources(db_url, counted, counted_from)
    check_row_parity(db_url)
    check_ids_are_the_sources_own(db_url)
    check_parallels_are_their_own_rows(db_url)
    check_art_is_the_sources_own_address(db_url)
    check_the_fallback_files_a_card_under_its_printed_number()
    check_no_price_rows(db_url)
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
            skip("publishable_key_reads_the_catalogue_and_cannot_write_it",
                 "SUPABASE_URL or SUPABASE_PUBLISHABLE_KEY is not set")
        else:
            check_http(base, key, sets, one_stored_card_id())

    print()
    print("--- the second run ---")
    check_rerun_changes_nothing(db_url, sets, cards, revision, args.skip_rerun)

    print()
    print("--- nothing left behind ---")
    check_account_tables(db_url, accounts_before)
    rows = psql(db_url, (
        "select count(*) from public.catalog_sets where game like 'zz%'"))
    if int(rows[0][0]):
        bad("no_probe_rows_left_behind", "%s probe set(s) remain" % rows[0][0])
    else:
        ok("no_probe_rows_left_behind",
           "no probe rows in the catalogue, and the account tables hold what "
           "they held")

    failed = sum(1 for status, _, _ in RESULTS if status == "FAIL")
    passed = sum(1 for status, _, _ in RESULTS if status == "PASS")
    skipped = sum(1 for status, _, _ in RESULTS if status == "SKIP")
    print()
    print("%d passed, %d failed, %d skipped" % (passed, failed, skipped))
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
