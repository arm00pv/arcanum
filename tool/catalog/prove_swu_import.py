#!/usr/bin/env python3
"""Prove the Star Wars: Unlimited import against the live database.

Design: docs/catalogue-server-side.md, section 8, and docs/catalogue-import-swu.md,
whose server half ends by saying that this game has no proof script and that the
gap is stated rather than papered over. This is that proof. The claim is that
Star Wars: Unlimited - the 27 sets the publisher lists today and every card in
them - is held on the server, that the rows there are exactly the rows the Dart
client would have derived itself, that re-running the importer changes nothing,
and that the importer cannot damage anything it does not own.

Written the way tool/catalog/prove_gundam_import.py is written, and for the same
reason: the interesting failures are invisible in the SQL that was supposed to
produce them and obvious in the database.

Five things are this game's own rather than a repeat of Gundam's proof.

**The count is checked against the rows, not against a number.** The publisher's
set list carries no card count of any kind - one request for 27 sets, 7 KB, a
code, a name and a CMS ordering value - so a count is a *second* request per set
in both languages: a one-record read whose pagination envelope carries the total,
over the base printings that are not tokens. Nothing in this file compares a
count with a figure written down here. What is asserted instead is that
catalog_sets.card_count equals the number of distinct oracle_id the set's own
stored rows carry: two independent measurements of one fact, which measured
equal for all 27 sets - sor 252, twi 257, sec 264, ash 264 - over the 9,909 rows
the game holds and the 2,982 distinct cards in them.

**Every row the sample produces is compared, set rows included.** The 995 card
rows the sample's three whole sets derive are compared over all 34 columns with
nothing excluded, exactly as Gundam's 553 are, and the sample's 27 set rows are
compared over every column of a set row as well. One column is carved out and
the carve-out is the sample's rather than a preference: swu_sets derives a
card_count of 0 for a set the sample does not cut whole, because that number
lives in a pagination envelope the sample does not hold. The three sets it does
cut whole are compared over card_count too, and check_card_counts_are_the_rows
compares all 27 counts against the rows the sets actually hold.

**A treatment is a row of its own.** A hyperspace printing carries a cardNumber
that counts its own run rather than the card - hyperspace Luke is #001 where Luke
is #005, hyperspace IG-88 is #278 where IG-88 is #012 - so a treatment takes its
base card's number, groups with it by oracle id and keeps its own id. The rule is
exercised over every stored row that points at a base: the base row exists, the
two share a collector number, the two ids differ and nothing collapsed. A
collapse is a holding that renders as "--" and a printing nobody can tell they
own, and no log would show it.

**The art is the publisher's own address.** cdn.starwarsunlimited.com answers a
browser directly, so this game needs no relay of ours and a stored
/arcanumweb-api/art/... URL would be a row no phone could use and no web build
either. A landscape card is stored as the portrait face of the same card - 88
records of the sample are landscape, 56 leaders with the deployed unit on the
other face and 32 bases with no second face at all - so what is stored is
asserted to be the publisher's own address and, where the publisher prints a
second face, to be that face.

**Tokens are absent, and this is the game where they are listed beside the
cards.** Token Upgrade, Token Unit, Credit Token and Force Token are 70 records
of the walk that no collector holds and nothing can be done with; left in, a
search for "shield" answers with the Shield token. The sample's four are asserted
to be absent by id, and no stored row's type line may name one of the four
either, which catches a token that came from a set the sample does not hold.

Credentials come from the environment, or from a file named with --env-file.
Nothing in this file holds a secret and the database URL is never printed.

    set -a; . /home/zixen/arcanum/supabase.env; set +a
    python3 tool/catalog/prove_swu_import.py

--no-auth runs without the HTTP half. --skip-rerun does not re-run the importer,
which is the check that proves the checksum skip. Exit status is 0 only if
nothing failed.
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
GAME = "swu"
SOURCE = "ffg"
PROVIDER = "https://admin.starwarsunlimited.com/api"

# The host the publisher serves its own art from. A relayed address is the one
# thing that must never be stored, so the check is a prefix and not a search for
# a substring that happened to appear once.
ART_HOST = "https://cdn.starwarsunlimited.com/"
RELAYED = "/arcanumweb-api/art/"

CATALOG_TABLES = ("catalog_sets", "catalog_cards", "catalog_prices", "catalog_meta")

# The three sets the committed sample cuts whole, which is the set the re-run
# check imports a second time. Named rather than derived so that the second run is
# the same second run every time it is made, and it is also the sample's own
# sampled_sets: SOR alone is larger than the source's 250-row page cap, so the
# second run exercises the paging path as well.
SAMPLE_SETS = ("SOR", "C24", "G25")

# The one set asked of the publisher now, in check_ids_are_the_publishers. SOR
# rather than another set because it is the set the sample also holds whole, so
# the two halves of that check are about the same set and a disagreement between
# them is about the publisher rather than about which set was read - and because
# it holds every awkward record shape of the game at once.
LIVE_SET = "SOR"

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.dirname(HERE)
VECTORS = os.path.join(HERE, "catalog_id_vectors.json.gz")
SAMPLE = os.path.join(HERE, "swu_sample.json.gz")

# psql is told its connection through the environment rather than through its
# argv, so the password is not in a process listing. catalog_store owns that
# split and is the module the importer itself runs, so this proof uses it rather
# than keeping a second copy of a rule about credentials.
#
# test_id_parity is imported for its driver: the rows this proof compares with the
# database are the rows that test asserts against the committed Dart vectors, from
# one implementation rather than two. import_swu_catalogue is imported for the
# same reason on the other side - every rule the rows are derived by is asked of
# the importer, not spelled a second time here.
sys.path.insert(0, TOOL)
sys.path.insert(0, HERE)
import catalog_store  # noqa: E402
import import_swu_catalogue as swu  # noqa: E402
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
    the parity test agree about what a row is.
    """
    for block in read_json_gz(VECTORS).get("games", []):
        if block.get("game") == GAME:
            return [column for column in block["cards"][0] if column != "id"]
    raise SystemExit("%s holds no %s block" % (VECTORS, GAME))


def card_uids(records):
    """The cardUids one set's records state, the tokens dropped.

    Read off the publisher's own record rather than off the row the importer
    derives from it, because verbatim is the thing being asserted: an id that the
    importer folded, trimmed or re-spelled would show up here as a stored id the
    publisher never wrote, where the derived row would only ever agree with
    itself. The token rule is the importer's own constant, and the four token
    types are why this cannot be a bare list of every cardUid in the answer.
    """
    out = set()
    for row in records:
        attributes = swu.attributes_of(row)
        if attributes is None:
            continue
        kind = swu.dart_string(
            (swu.relation_of(attributes, "type") or {}).get("name")) or ""
        if kind in swu.TOKENS:
            continue
        uid = swu.dart_string(attributes.get("cardUid"))
        if uid:
            out.add(uid)
    return out


def one_stored_card_id():
    """One id the catalogue is asserted to hold, taken from the sample.

    The single-card read through PostgREST is what proves a client can fetch one
    card and not merely list them, and the id it uses must be one the catalogue
    is asserted to hold. It is taken from the sample rather than typed here, so
    that it is the same id check_row_parity and check_ids_are_the_publishers have
    already compared with the database.
    """
    rows = test_id_parity.swu_cards(read_json_gz(SAMPLE))
    return sorted(rows)[0] if rows else None


# ---------------------------------------------------------------------------
# The checks
# ---------------------------------------------------------------------------


def provider_sets():
    """The publisher's own set list right now: {folded code: code as published}.

    Asked for rather than remembered. A constant written down here would fail the
    day the publisher adds a set - a false alarm - and would pass for an import
    that stored a set list thinly, which is the failure that matters. It is one
    request for 27 sets and 7 KB, and it carries no card count of any kind, which
    is why no count is checked against it: the count is a second request per set
    and is checked against the rows instead, in check_card_counts_are_the_rows.

    The value is the code as the publisher spells it, so that a stored code that
    is not that spelling folded is reported with both strings in view.
    """
    try:
        listing_rows = swu.set_list()
    except Exception as exc:  # noqa: BLE001 - reported as a skip, with the reason
        return None, str(exc)
    out = {}
    for item in listing_rows:
        attributes = swu.attributes_of(item)
        if attributes is None:
            continue
        provider_code = swu.dart_string(attributes.get("code"))
        if provider_code:
            out[swu.slug(provider_code)] = provider_code
    if not out:
        return None, "the publisher listed no sets"
    return out, None


def check_counts(db_url, provider):
    """Every published set is a row, folded, and no stored set is unpublished.

    The card total is deliberately not compared against a number written down
    here, for the reason provider_sets gives. What is checked is the set list as
    a structure: the stored codes are the publisher's codes folded, in the same
    number and both ways round, no set is retired, and no set carries a card
    count of zero - a set stored with no count is a set no client can tell is
    complete. The count itself is checked against the set's own rows in
    check_card_counts_are_the_rows.
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
        problems.append("%d set(s) are retired; the publisher lists every one" % retired)
    if uncounted:
        problems.append("%d set(s) carry a card count of zero, which a client "
                        "reads as a set whose size the publisher does not state"
                        % uncounted)

    beyond_case = []
    if provider is not None:
        rows = psql(db_url, "select code from public.catalog_sets where game = %s"
                    % sql_text(GAME))
        stored = sorted(row[0] for row in rows)
        unpublished = [code for code in stored if code not in provider]
        missing = [code for code in sorted(provider) if code not in set(stored)]
        if sets != len(provider):
            problems.append("%d sets stored, the publisher lists %d"
                            % (sets, len(provider)))
        if missing:
            problems.append("%d set(s) the publisher lists are not stored: %s"
                            % (len(missing), missing[:4]))
        if unpublished:
            problems.append("%d stored set(s) the publisher does not list: %s"
                            % (len(unpublished), unpublished[:4]))
        # How much work the fold does is reported rather than asserted here. The
        # fold itself is checked in full in
        # check_stored_codes_are_the_folded_form, against the importer's own
        # slug; a failure raised here for a code that folded correctly would be a
        # false alarm about an import that did exactly what it should.
        beyond_case = [code for code in stored
                       if code in provider and code != provider[code].lower()]

    if problems:
        bad("counts_match_the_publisher", "\n".join(problems[:6]))
    else:
        if provider is None:
            compared = "%d sets (the publisher's own list was not read)" % sets
            fold = ""
        else:
            compared = ("%d sets, the publisher lists the same %d"
                        % (sets, len(provider)))
            fold = ("and the fold is the case alone for every one of them"
                    if not beyond_case else
                    "and %d of the codes needed more than a case change"
                    % len(beyond_case))
            fold = ", " + fold
        ok("counts_match_the_publisher",
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
    """The stored code is the provider code folded, and the folding is real.

    The publisher addresses a set by SOR and every read path of the app folds a
    code before it touches SQLite, so for this game the two strings genuinely
    differ for every set - which is what makes this worth asking rather than
    assuming. It also matters more here than elsewhere: retire_sets compares
    against the stored form, so a run that handed it the publisher's spelling
    would retire all 27 sets at once and look like a complete import.

    The fold is the importer's own slug, asked for rather than spelled a second
    time in SQL: this game's rule is lower case with everything that is not a
    letter or a digit dropped, and a regexp_replace here would be a second
    implementation of it that no test would compare with the first.
    """
    rows = psql(db_url, (
        "select code, id from public.catalog_sets where game = %s order by code"
        % sql_text(GAME)), want_json=True)
    if not rows:
        bad("stored_codes_are_the_folded_form_retirement_compares",
            "no set rows to check")
        return
    wrong = [(row["code"], row["id"]) for row in rows
             if row["code"] != swu.slug(row["id"])]
    unfolded = [row for row in rows if row["code"] == row["id"]]
    if wrong:
        bad("stored_codes_are_the_folded_form_retirement_compares",
            "%d of %d stored codes are not the importer's slug of the "
            "publisher's own code, which is the spelling the client queries with "
            "and the spelling retire_sets compares against, e.g. %s"
            % (len(wrong), len(rows), wrong[:3]))
        return
    if len(unfolded) == len(rows):
        bad("stored_codes_are_the_folded_form_retirement_compares",
            "the publisher spells every one of the %d codes the way the "
            "catalogue stores it, so this data cannot show the fold is applied"
            % len(rows))
        return
    ok("stored_codes_are_the_folded_form_retirement_compares",
       "all %d stored codes are its own provider code through the importer's "
       "slug - %d of them a code the publisher spells in another case, so the "
       "folding is doing real work"
       % (len(rows), len(rows) - len(unfolded)))


def check_set_types_are_the_importers(db_url):
    """Every stored set_type is set_type_for's own answer, and one of four.

    The rule reads the set's name before its code, and the weekly-play runs are
    why: JTLP is "Jump to Lightspeed Weekly Play" and its code begins with J,
    while LOFP, SECP and LAWP are the same kind of run under codes that begin
    with L, S and L. A reader that took the code first would type one of the four
    as a promo run and the other three as weekly play - one kind of set split in
    two by the first letter of its code - so the stored column is compared with
    the importer's own function over the two things the publisher states, and not
    with a list of kinds written down here.

    The four kinds are the only ones that function can return, which is asserted
    as well: a fifth spelling in the column would be a set type no client knows.
    """
    rows = psql(db_url, (
        "select code, id, name, set_type from public.catalog_sets"
        " where game = %s order by code" % sql_text(GAME)), want_json=True)
    allowed = ("expansion", "promo", "weekly", "starter")
    wrong = []
    kinds = {}
    for row in rows:
        expected = swu.set_type_for(row["id"], row["name"])
        kinds[row["set_type"]] = kinds.get(row["set_type"], 0) + 1
        if row["set_type"] != expected:
            wrong.append("set %s (%s, %r) is stored as %r and set_type_for gives %r"
                         % (row["code"], row["id"], row["name"],
                            row["set_type"], expected))
    strange = sorted(set(kinds) - set(allowed))
    problems = wrong[:6]
    if strange:
        problems.append("%d kind(s) outside the four set_type_for can return: %s"
                        % (len(strange), strange))
    if problems:
        bad("set_types_are_the_ones_the_importer_derives", "\n".join(problems))
    else:
        ok("set_types_are_the_ones_the_importer_derives",
           "all %d sets carry set_type_for's own answer, over the four kinds it "
           "can give: %s" % (len(rows), listing(sorted(kinds), kinds)))


def check_card_counts_are_the_rows(db_url):
    """card_count equals the distinct oracle ids the set's own rows carry.

    This is the strongest check this game has, and the one docs/catalogue-
    import-swu.md quotes. The published count and the stored rows are two
    independent measurements of one fact: the count comes from a one-record
    request whose envelope carries a total over the base printings, and the rows
    are what the import wrote. Nothing in this file holds a copy of the numbers -
    the four the report quotes are read here and printed, so that a set the
    publisher grows is reported as a disagreement rather than as a stale
    constant.

    count(distinct oracle_id) ignores nulls, which is why the null oracle ids are
    counted separately and asserted to be zero: a set whose rows carried no
    oracle id at all would otherwise look like a set of no cards and pass.
    """
    rows = psql(db_url, (
        "select s.code as code, s.card_count as card_count,"
        "       count(distinct c.oracle_id) as distinct_oracles,"
        "       count(*) filter (where c.id is not null and c.oracle_id is null)"
        "         as null_oracles,"
        "       count(c.id) as stored_rows"
        "  from public.catalog_sets s"
        "  left join public.catalog_cards c"
        "    on c.game = s.game and c.set_code = s.code"
        " where s.game = %s"
        " group by s.code, s.card_count"
        " order by s.code" % sql_text(GAME)), want_json=True)

    problems = []
    quoted = {}
    for row in rows:
        code = row["code"]
        claimed = int(row["card_count"])
        oracles = int(row["distinct_oracles"])
        quoted[code] = claimed
        if int(row["stored_rows"]) == 0:
            problems.append("set %s holds no card rows at all, where the "
                            "publisher lists a set with %d cards in it"
                            % (code, claimed))
        if int(row["null_oracles"]):
            problems.append("set %s holds %d row(s) with no oracle id, which "
                            "count(distinct) does not count"
                            % (code, int(row["null_oracles"])))
        if claimed != oracles:
            problems.append("set %s records %d cards and its stored rows carry "
                            "%d distinct oracle ids" % (code, claimed, oracles))

    totals = psql(db_url, (
        "select count(distinct oracle_id), count(*) from public.catalog_cards"
        " where game = %s" % sql_text(GAME)))
    distinct_cards, total_rows = (int(v) for v in totals[0])

    if problems:
        bad("card_count_equals_the_distinct_oracle_ids_of_its_rows",
            "\n".join(problems[:6]))
        return
    biggest = sorted(quoted, key=lambda code: (-quoted[code], code))[:4]
    ok("card_count_equals_the_distinct_oracle_ids_of_its_rows",
       "all %d sets: the count the publisher's own envelope gave equals the "
       "distinct oracle ids the set's rows carry - %s - and the %d stored rows "
       "hold %d distinct cards between them"
       % (len(quoted), ", ".join("%s %d" % (code, quoted[code])
                                 for code in sorted(biggest)),
          total_rows, distinct_cards))


def check_row_parity(db_url):
    """The rows the importer derives, against the rows in Postgres.

    This is the claim the whole step rests on. tool/catalog/test_id_parity.py
    proves the two languages derive the same rows from the same responses; this
    proves the rows in the database are the rows the importer derives from those
    responses, which is a different statement - an import that predates a rule
    change satisfies the first and fails this.

    Every column of every sampled card is compared and nothing is carved out: 995
    rows over 34 columns. The sample's 27 set rows are compared too, because a
    set row is a row this importer derives and a stale one is a shelf a client
    draws wrongly, and every set column is compared rather than the two a card
    sheet happens to show.

    One column is carved out for the sets the sample does not cut whole, and the
    carve-out is the sample's rather than a preference: swu_sets derives a
    card_count of 0 for those, because the count lives in a one-record request's
    pagination envelope and the sample holds the set list and three whole sets and
    no other envelope. The three it does hold whole are compared over card_count
    as well, and check_card_counts_are_the_rows compares all 27 against the rows
    those sets actually hold.
    """
    sample = read_json_gz(SAMPLE)
    problems = []

    derived = test_id_parity.swu_cards(sample)
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

    sampled = {swu.slug(code) for code in SAMPLE_SETS}
    derived_sets = test_id_parity.swu_sets(sample)
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
    whole = 0
    sets_differing = 0
    for code in codes:
        live_row = by_code.get(code)
        if live_row is None:
            continue
        compared = (set_columns if code in sampled
                    else [c for c in set_columns if c != "card_count"])
        if code in sampled:
            whole += 1
        for column in compared:
            if not same(derived_sets[code].get(column), live_row.get(column)):
                sets_differing += 1
                if sets_differing <= 6:
                    problems.append("set %s.%s: database %r != importer %r"
                                    % (code, column, live_row.get(column),
                                       derived_sets[code].get(column)))
                break

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
            "that went up after it was cut, and counts_match_the_publisher is the "
            "live statement about those" % (len(unseen), ", ".join(unseen[:4])))
    ok("imported_rows_equal_the_importer_derivation",
       "all %d of the sample's cards match the rows the importer derives in %d "
       "columns each with no column excluded, and its %d set rows match in %d "
       "columns each - card_count among them for the %d sets the sample cuts "
       "whole, where a count is a request the sample does not hold%s"
       % (len(ids), len(columns), len(codes), len(set_columns) - 1, whole, note))


def check_ids_are_the_publishers(db_url):
    """Every stored id is a cardUid the publisher states, in two halves.

    The one failure in this design that no log would show: an id that moved turns
    a collection row into "--" and nothing anywhere says why. So this is asserted
    twice, over two different bodies of evidence, and both times against the
    publisher's own spelling rather than against a number remembered from the
    import.

    The three sampled sets are compared with the committed sample, which holds
    every record of each of them, needs no network, and states each cardUid
    verbatim: a fold, a trim or a dropped separator shows up here. That covers 995
    of the game's 9,909 rows.

    None of that can see a publisher that has added or renumbered since the
    sample was cut, which is why one set is then asked of the publisher now: SOR,
    live, 991 records over four pages. One set rather than 27 because it is the
    same fact each time and the whole walk is 135 MB of the source's own answers.
    """
    sample = read_json_gz(SAMPLE)
    problems = []
    compared = 0
    for item, records in test_id_parity.swu_set_downloads(sample):
        code = swu.slug(swu.dart_string(
            (swu.attributes_of(item) or {}).get("code")))
        published = sorted(card_uids(records))
        if not code or not published:
            continue
        stored = sorted(row[0] for row in psql(db_url, (
            "select id from public.catalog_cards where game = %s and set_code = %s"
            % (sql_text(GAME), sql_text(code)))))
        compared += len(stored)
        if stored != published:
            problems.append(
                "set %s holds %d ids and the sample states %d: e.g. stored only "
                "%s, published only %s"
                % (code, len(stored), len(published),
                   sorted(set(stored) - set(published))[:3],
                   sorted(set(published) - set(stored))[:3]))

    try:
        live_records = swu.set_cards(LIVE_SET)
    except Exception as exc:  # noqa: BLE001 - reported, with the reason
        live, why = [], str(exc)
    else:
        why = None
        live = sorted(card_uids(live_records))
        stored = sorted(row[0] for row in psql(db_url, (
            "select id from public.catalog_cards where game = %s and set_code = %s"
            % (sql_text(GAME), sql_text(swu.slug(LIVE_SET))))))
        compared += len(stored)
        if stored != live:
            problems.append(
                "set %s holds %d ids and the publisher states %d for it now: e.g. "
                "stored only %s, published only %s"
                % (LIVE_SET, len(stored), len(live),
                   sorted(set(stored) - set(live))[:3],
                   sorted(set(live) - set(stored))[:3]))

    if problems:
        bad("every_stored_id_is_a_card_uid_the_publisher_publishes",
            "\n".join(problems))
        return
    if why is not None:
        skip("every_stored_id_is_a_card_uid_the_publisher_publishes (the live half)",
             "the three sampled sets match the committed sample, but the "
             "publisher could not be asked for %s: %s" % (LIVE_SET, why))
        return
    ok("every_stored_id_is_a_card_uid_the_publisher_publishes",
       "%d stored ids across the three sampled sets are the cardUids the "
       "committed sample states, and %s's %d stored ids are the ones the "
       "publisher states for it now - verbatim in both halves"
       % (compared - len(live), LIVE_SET, len(live)))


def check_no_stored_row_is_a_token(db_url):
    """No stored row is a token, by id and by type line.

    The publisher lists four card types that are not cards - Token Upgrade,
    Token Unit, Credit Token and Force Token - beside the cards, on the same
    sheet, 70 records of the walk. Nothing holds one in a binder and nothing can
    be done with one; left in, a search for "shield" answers with the Shield
    token and a set's own count stops being the number printed on its cards.

    Two halves, because the first one cannot see a set the sample does not hold:
    the cardUids the sample's own token records carry are asserted not to be
    stored ids, and no stored row's type line is allowed to begin with one of the
    four names - the type line is where the importer puts the publisher's type,
    so a token that got past the drop is named there.
    """
    tokens = test_id_parity.swu_tokens(read_json_gz(SAMPLE))
    rows = psql(db_url, (
        "select (select count(*) from public.catalog_cards"
        "          where game = %s and id = any (%s)) as sampled_token_uids,"
        "       (select count(*) from public.catalog_cards"
        "          where game = %s"
        "            and split_part(coalesce(type_line, ''), ' - ', 1)"
        "                = any (%s)) as token_type_rows"
        % (sql_text(GAME), sql_array(sorted(tokens)),
           sql_text(GAME), sql_array(sorted(swu.TOKENS)))), want_json=True)
    stored_tokens = int(rows[0]["sampled_token_uids"])
    typed_tokens = int(rows[0]["token_type_rows"])
    problems = []
    if stored_tokens:
        problems.append("%d of the sample's %d token cardUids are stored as cards"
                        % (stored_tokens, len(tokens)))
    if typed_tokens:
        problems.append("%d stored row(s) have a type line naming one of the "
                        "four token types" % typed_tokens)
    if problems:
        bad("no_stored_row_is_a_token", "\n".join(problems))
    else:
        ok("no_stored_row_is_a_token",
           "none of the sample's %d token cardUids is stored and no row's type "
           "line names %s, so the 70 token records of the walk are absent rather "
           "than filed beside the cards"
           % (len(tokens), ", ".join(sorted(swu.TOKENS))))


def check_treatments_are_their_own_rows(db_url):
    """A treatment is its own row, numbered as its base card and grouped with it.

    A hyperspace, foil, prestige, showcase or promo record carries a cardNumber of
    its own that counts its run rather than the card - hyperspace Luke is #001
    where Luke is #005, hyperspace IG-88 is #278 where IG-88 is #012 - so a row
    that points at a base takes the base's number. That is what makes the app's
    binder slots come out right: a slot is a (name, number) pair, so a collector
    who owns Luke owns that slot whichever treatment they hold.

    What must not happen is the other half of it: the treatment collapsing into
    its base's row. A collection row names a card id, so two printings stored
    under one id is a holding that renders as "--" and a printing nobody can tell
    they own. Three things are asserted, over every stored row that points at a
    base and not over the sample, so that all 9,909 rows are covered: the base row
    is there, the two share a collector number, and the two ids differ. The
    grouping is asserted too - a treatment's oracle id is the base it points at,
    which is what the app's other-printings list reads - and it is asserted
    against the same column rather than derived from it.
    """
    rows = psql(db_url, (
        "select count(c.id) as treatments,"
        "       count(*) filter (where b.id is null) as missing_base,"
        "       count(*) filter (where c.id = c.extras->>'variantOf') as self_base,"
        "       count(*) filter (where b.collector_number"
        "                          is distinct from c.collector_number)"
        "         as renumbered,"
        "       count(*) filter (where c.oracle_id"
        "                          is distinct from c.extras->>'variantOf')"
        "         as ungrouped"
        "  from public.catalog_cards c"
        "  left join public.catalog_cards b"
        "    on b.game = c.game and b.id = c.extras->>'variantOf'"
        " where c.game = %s and c.extras ? 'variantOf'" % sql_text(GAME)),
        want_json=True)
    row = rows[0]
    treatments = int(row["treatments"])
    problems = []
    if treatments < 50:
        problems.append("only %d row(s) point at a base card, too few for this "
                        "check to prove anything" % treatments)
    if int(row["missing_base"]):
        problems.append("%d treatment(s) point at a base row the catalogue does "
                        "not hold, so their number came from nowhere and the "
                        "card they are a printing of is missing"
                        % int(row["missing_base"]))
    if int(row["self_base"]):
        problems.append("%d row(s) are stored under the id of the base they "
                        "point at, which is the collapse this rule exists to "
                        "stop" % int(row["self_base"]))
    if int(row["renumbered"]):
        problems.append("%d treatment(s) carry a collector number their base "
                        "card does not, so the two printings of one card land in "
                        "two binder slots" % int(row["renumbered"]))
    if int(row["ungrouped"]):
        problems.append("%d treatment(s) do not group with the base card they "
                        "point at" % int(row["ungrouped"]))
    if problems:
        bad("a_treatment_is_its_own_row_numbered_as_its_base", "\n".join(problems))
    else:
        ok("a_treatment_is_its_own_row_numbered_as_its_base",
           "all %d stored treatments keep their own id, share their base card's "
           "collector number, group with the base they point at, and every base "
           "row they point at is present" % treatments)


def check_art_is_the_publishers_own_address(db_url):
    """The stored art is the publisher's URL, not a relayed one.

    CardArt.host rewrites a relayed host's URL on a web build while the client
    parses, so a row the provider path writes in a browser would already hold a
    relayed address and the same row on a phone would not. This publisher needs
    no relay at all - cdn.starwarsunlimited.com answers a browser with
    Access-Control-Allow-Origin - so what is stored is the publisher's own
    address and both platforms read the same string.

    Two halves. Every stored row is asserted to carry an address on that host and
    none a relayed one, over all 9,909 rows. And the landscape rule is named
    rather than left to check_row_parity's column comparison: a leader prints
    418x300 with the deployed unit on the other face at 300x418, so a landscape
    card with a second face is stored as that face, while a base is landscape
    with no second face at all and is drawn from the only art it has. 88 records
    of the sample are landscape and only 56 of them have a face to draw from,
    which is what makes "the other face when there is one" the rule rather than
    "a leader".
    """
    rows = psql(db_url, (
        "select id, image_normal from public.catalog_cards where game = %s"
        % sql_text(GAME)), want_json=True)
    stored = {row["id"]: row for row in rows}
    relayed = [row["id"] for row in rows
               if isinstance(row.get("image_normal"), str)
               and RELAYED in row["image_normal"]]
    missing = [row["id"] for row in rows if row.get("image_normal") is None]
    wrong_host = [row["id"] for row in rows
                  if isinstance(row.get("image_normal"), str)
                  and not row["image_normal"].startswith(ART_HOST)]
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

    landscapes = 0
    faces = 0
    misdrawn = []
    for row in read_json_gz(SAMPLE).get("cards") or []:
        attributes = swu.attributes_of(row)
        if attributes is None or attributes.get("artFrontHorizontal") is not True:
            continue
        uid = swu.dart_string(attributes.get("cardUid"))
        live = stored.get(uid)
        if live is None:
            # Not this check's business: a row that is not stored at all is
            # reported by check_row_parity and by the id check.
            continue
        landscapes += 1
        back = swu.image_of(attributes.get("artBack"))
        if back:
            faces += 1
        expected = back or swu.image_of(attributes.get("artFront"))
        if live.get("image_normal") != expected:
            misdrawn.append("%s is stored as %r and the publisher prints %r"
                            % (uid, live.get("image_normal"), expected))
    if faces < 5 or landscapes - faces < 5:
        problems.append("the sample holds %d stored landscape records with a "
                        "second face and %d without, too few to prove the rule"
                        % (faces, landscapes - faces))
    problems.extend(misdrawn[:3])

    if problems:
        bad("stored_art_is_the_publishers_own_address", "\n".join(problems))
    else:
        ok("stored_art_is_the_publishers_own_address",
           "all %d rows carry art on cdn.starwarsunlimited.com and none carries "
           "a relayed address; of the sample's %d landscape cards that are "
           "stored, the %d with a second face are drawn from it and the %d "
           "without keep the art they have"
           % (len(rows), landscapes, faces, landscapes - faces))


def check_no_price_rows(db_url):
    """The source quotes no price, so the importer writes none - in code and in data.

    No key matching /price/i appears in a 250-record page of this source, and
    there is no TCGplayer product id on a record to join a price series to -
    extras deliberately carries no 'tcgplayerId'. replace_prices therefore has
    nothing to be handed, and this asserts both halves of that: the module never
    calls it, and the table holds no row for this game. A price row appearing here
    would be a number from nowhere, and a column of "--" on the card sheet is the
    honest state until a priced source for this game exists.
    """
    # Read off the module's syntax tree rather than its text: the file names
    # replace_prices in its own docstring - twice, to say that it is *not* called
    # - and a grep that cannot tell a sentence from a call reports a failure on
    # this very fact.
    with open(os.path.join(TOOL, "import_swu_catalogue.py"),
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

    Design rule 4, exercised through the importer's own retire_sets rather than
    through hand-written SQL: one published set is left out of the upstream list,
    which retires it, and the list is then handed over whole, which un-retires it.
    What is asserted in between is the point of the rule - the set row is still
    there, and so is every card in it, so the holdings that name those card ids
    still resolve.

    The list handed over is in stored form, because that is the spelling
    retire_sets compares against: for this game the publisher spells a set SOR
    where the catalogue stores sor, and a run that handed the publisher's spelling
    to this call would retire all 27 sets and look like it had worked.
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
    it may expect. The id is one the sample states and check_ids_are_the_
    publishers has compared with the database, so a failure here is about the
    key's reach and not about which card was asked for.

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
    run happens. It is bounded to the three sets the committed sample holds whole,
    and every set in the game is compared afterwards, because a run that named a
    subset must touch that subset and nothing else - and because the importer
    withholds the upstream list for a named subset, so it must not retire the 24
    sets it was not asked for.

    Counts alone would not catch a run that rewrote every row to the same values;
    the checksums, the revisions and catalogued_at are compared too, so a rewrite
    shows up even when the content is identical.
    """
    if skip_rerun:
        skip("rerun_changes_nothing", "not run: --skip-rerun")
        return

    importer = os.path.join(TOOL, "import_swu_catalogue.py")
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
           "cards_revision and catalogued_at, so the three sets it was asked for "
           "were skipped on their checksums and the other %d were never touched; "
           "sets_revision stayed %d"
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

    provider, why = provider_sets()
    if provider is None:
        skip("counts_match_the_publisher (the publisher's own set list)",
             "%s could not be read: %s. The stored set list is still checked for "
             "structure and against its own rows, but not against the live list"
             % (PROVIDER, why))
    sets, cards = check_counts(db_url, provider)
    if not sets:
        print()
        print("the catalogue holds no Star Wars: Unlimited set, so there is "
              "nothing here to prove")
        return 1

    check_orphans(db_url)
    check_stored_codes_are_the_folded_form(db_url)
    check_set_types_are_the_importers(db_url)
    check_card_counts_are_the_rows(db_url)
    check_row_parity(db_url)
    check_ids_are_the_publishers(db_url)
    check_no_stored_row_is_a_token(db_url)
    check_treatments_are_their_own_rows(db_url)
    check_art_is_the_publishers_own_address(db_url)
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
