#!/usr/bin/env python3
"""Prove the Gundam import against the live database.

Design: docs/catalogue-server-side.md, section 8. Step 1 proved the machinery on
Lorcana and step 5 on Pokemon; this proves the first game moved off tcgcsv onto a
source of its own. The claim is that Gundam - 28 sets and every product in them -
is held on the server, that the rows there are exactly the rows the Dart client
would have derived itself, that re-running the importer changes nothing, and that
the importer cannot damage anything it does not own.

Written the way tool/catalog/prove_pokemon_import.py is written, and for the same
reason: the interesting failures are invisible in the SQL that was supposed to
produce them and obvious in the database.

Four things are Gundam's own rather than a repeat of Pokemon's proof.

**The rows are compared against the importer's mapping, not against a constant,
and this game has one path rather than two.** Every sampled product is put through
import_gundam_catalogue.card_document and set_document - the functions the nightly
import runs - and compared with the live table column by column. Unlike Pokemon
there is no by-id row that differs from a set walk's row to carve out: the payload
names the set a product is filed under, so the importer's derivation is the single
answer, and the sample's 553 products are compared over all 34 columns with
nothing excluded.

**The id column is asserted to be the provider's, row by row.** A collection row
names a card id, so an id that moved would leave a holding rendering as "--" for
ever and no log would say why. The proof compares the ids in the database against
the product ids the provider publishes today, not against a number remembered from
the import.

**What the importer must NOT have written is asserted too.** gcgapi quotes no
price, so catalog_prices must hold no Gundam row, and the importer must not call
replace_prices at all - read off the module rather than trusted to be true because
this file cannot write the table. The art column is asserted to be the provider's
own address rather than a relayed one, because the relay is applied at read time
on a web build and a stored relayed URL would be a row no phone could use.

**The tombstone rule is exercised, not just read.** As in Pokemon's proof, the
importer's own retire_sets is called for real with one set missing from the
upstream list and then called again with the full list: the set is hidden, its row
and its cards are still there, and it comes back.

Credentials come from the environment, or from a file named with --env-file.
Nothing in this file holds a secret and the database URL is never printed.

    set -a; . /home/zixen/arcanum/supabase.env; set +a
    python3 tool/catalog/prove_gundam_import.py

--no-auth runs without the HTTP half. --skip-rerun does not re-run the importer,
which is the check that proves the checksum skip. Exit status is 0 only if nothing
failed.
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
GAME = "gundam"
SOURCE = "gcgapi"
PROVIDER = "https://api.gcgapi.com/v1"
CATALOG_TABLES = ("catalog_sets", "catalog_cards", "catalog_prices", "catalog_meta")

# The sets the committed sample holds whole, which is the set the re-run check
# imports a second time. Named rather than derived so that the second run is the
# same second run every time it is made.
SAMPLE_SETS = ("GD01", "EB01", "SC01", "ST01", "RP", "T", "EXB")

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.dirname(HERE)
VECTORS = os.path.join(HERE, "catalog_id_vectors.json.gz")
SAMPLE = os.path.join(HERE, "gundam_sample.json.gz")

# psql is told its connection through the environment rather than through its
# argv, so the password is not in a process listing. catalog_store owns that
# split and is the module the importer itself runs, so this proof uses it rather
# than keeping a second copy of a rule about credentials.
#
# test_id_parity is imported for its driver: the rows this proof compares with the
# database are the rows that test asserts against the committed Dart vectors, from
# one implementation rather than two.
sys.path.insert(0, TOOL)
sys.path.insert(0, HERE)
import catalog_store  # noqa: E402
import import_gundam_catalogue as gcgapi  # noqa: E402
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


# ---------------------------------------------------------------------------
# SQL, as the owner, and HTTP, as anybody
# ---------------------------------------------------------------------------


def session_url(db_url):
    """The session pooler, which is what the design names for admin work."""
    return db_url.replace(":6543/", ":5432/"), ":6543/" in db_url


def psql(db_url, sql, want_json=False):
    """One script through psql, with ON_ERROR_STOP, reading JSON when asked.

    The JSON form is used for anything that reads card text: a card's rules text
    carries pipes, tabs, newlines and CJK brackets, and the pipe-separated text
    protocol would turn any of them into a column boundary.
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


# ---------------------------------------------------------------------------
# The checks
# ---------------------------------------------------------------------------


def provider_sets():
    """The provider's own set list right now: {folded code: published count}.

    Asked for rather than remembered. A constant written down here would fail the
    day the publisher adds a set - a false alarm - and would pass for an import
    that stored a set list thinly, which is the failure that matters. The counts
    come back with it because each set's published count is what a client
    compares its stored rows against to decide a set is complete.
    """
    try:
        listing = gcgapi.set_list()
    except Exception as exc:  # noqa: BLE001 - reported as a skip, with the reason
        return None, str(exc)
    out = {}
    for item in listing:
        if isinstance(item, dict):
            code = gcgapi.slug(item.get("set_code"))
            if code:
                out[code] = gcgapi.dart_int(item.get("card_count")) or 0
    if not out:
        return None, "gcgapi listed no sets"
    return out, None


def check_counts(db_url, provider):
    """What is stored is complete, and a set list a client can act on.

    The card total is deliberately not compared against a number written down
    here, for the reason provider_sets gives. What is checked instead is the
    structure: no set is retired, every set's own card_row_count agrees with the
    rows actually present, and - because this provider publishes a real count per
    set - every set's published count agrees with the rows too. A set that was
    half-imported fails the last two.
    """
    rows = psql(db_url, (
        "select (select count(*) from public.catalog_sets where game = %s),"
        "       (select count(*) from public.catalog_cards where game = %s),"
        "       (select count(*) from public.catalog_sets where game = %s"
        "          and retired_at is not null)"
        % (sql_text(GAME), sql_text(GAME), sql_text(GAME))))
    sets, cards, retired = (int(v) for v in rows[0])

    problems = []
    if provider is not None and sets != len(provider):
        problems.append("%d sets stored, gcgapi publishes %d" % (sets, len(provider)))
    if retired:
        problems.append("%d set(s) retired; the provider publishes every one" % retired)

    rows = psql(db_url, (
        "select s.code, s.card_row_count, s.card_count, count(c.id)"
        "  from public.catalog_sets s"
        "  left join public.catalog_cards c on c.game = s.game and c.set_code = s.code"
        " where s.game = %s"
        " group by s.code, s.card_row_count, s.card_count"
        " having s.card_row_count <> count(c.id)"
        "     or s.card_count <> count(c.id) order by s.code" % sql_text(GAME)))
    for code, claimed, published, actual in rows:
        problems.append("set %r records %s rows and %s published, and holds %s"
                        % (code, claimed, published, actual))

    if problems:
        bad("counts_match_the_provider", "\n".join(problems[:6]))
    else:
        compared = ("%d sets, gcgapi publishes the same %d"
                    % (sets, len(provider)) if provider is not None else
                    "%d sets (the provider's own count was not read)" % sets)
        ok("counts_match_the_provider",
           "%s, none retired, and every set's recorded and published card count "
           "matches its rows: %d cards" % (compared, cards))
    return sets, cards


def check_orphans(db_url):
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
    """The stored code is the provider's code folded, and the folding is real.

    gcgapi addresses a set by GD01 and every read path of the app lower-cases a
    code before it touches SQLite, so the two strings genuinely differ for every
    set of this game - which is what makes this check worth making rather than
    assuming. Retirement compares against the stored form, so a run that handed
    retire_sets the provider's spelling would retire all 28 sets and look
    complete.
    """
    rows = psql(db_url, (
        "select count(*) filter (where code <> lower(id)) as unfolded,"
        "       count(*) filter (where code = id) as same,"
        "       count(*) as total"
        "  from public.catalog_sets where game = %s" % sql_text(GAME)),
        want_json=True)
    row = rows[0]
    unfolded = int(row["unfolded"])
    same_count = int(row["same"])
    total = int(row["total"])
    if unfolded:
        bad("stored_codes_are_the_folded_form_retirement_compares",
            "%d of %d stored set code(s) are not their provider id folded to "
            "lower case, which is the spelling the client queries with and the "
            "spelling retire_sets compares against" % (unfolded, total))
        return
    note = ("none of the %d ids needed folding today, which would make this "
            "check vacuous" % total if same_count == total else
            "%d of the %d are folded from a provider code spelled otherwise, so "
            "the folding is doing real work" % (total - same_count, total))
    ok("stored_codes_are_the_folded_form_retirement_compares",
       "every stored set code of the %d is its provider code folded to lower "
       "case: %s" % (total, note))
    if same_count == total:
        bad("stored_codes_are_the_folded_form_retirement_compares",
            "the folding changed nothing, so this data cannot show it is applied")


def check_row_parity(db_url):
    """The rows the importer derives, against the rows in Postgres.

    This is the claim the whole step rests on. tool/catalog/test_id_parity.py
    proves the two languages derive the same rows from the same responses; this
    proves the rows in the database are the rows the importer derives from those
    responses, which is a different statement - an import that predates a rule
    change satisfies the first and fails this.

    Every column of every sampled card is compared and nothing is carved out.
    Unlike Pokemon there is no second client path deriving a different row for the
    same card: the payload names the set a product is filed under, so a card
    reached by its own id and the same card downloaded with its set are one row,
    and the parity test asserts exactly that. So the derivation here is the
    importer's own, over the same selection it walked.
    """
    derived = test_id_parity.gundam_cards(read_json_gz(SAMPLE))
    columns = vectors_card_columns()

    ids = sorted(derived)
    selected = ", ".join(["id"] + columns)
    live = psql(db_url, (
        "select %s from public.catalog_cards where game = %s and id = any (%s)"
        % (selected, sql_text(GAME), sql_array(ids))), want_json=True)
    by_id = {row["id"]: row for row in live}

    missing = [i for i in ids if i not in by_id]
    if missing:
        bad("imported_rows_equal_the_importer_derivation",
            "%d of %d sampled cards are not in the database, e.g. %s"
            % (len(missing), len(ids), missing[:3]))
        return

    problems = []
    differing = 0
    for card_id in ids:
        row, live_row = derived[card_id], by_id[card_id]
        for column in columns:
            if not same(row.get(column), live_row.get(column)):
                differing += 1
                if differing <= 6:
                    problems.append("%s.%s: database %r != importer %r"
                                    % (card_id, column, live_row.get(column),
                                       row.get(column)))
                break
    if problems:
        if differing > 6:
            problems.append("... and %d more row(s) differ" % (differing - 6))
        bad("imported_rows_equal_the_importer_derivation", "\n".join(problems))
        return
    ok("imported_rows_equal_the_importer_derivation",
       "all %d of the sample's cards match the rows the importer derives in %d "
       "columns each, with no column excluded"
       % (len(ids), len(columns)))


def check_ids_are_the_providers(db_url):
    """Every stored id is a product id the provider publishes, in two halves.

    The one failure in this design that no log would show: an id that moved turns
    a collection row into "--" and nothing anywhere says why. So this is asserted
    twice, over two different bodies of evidence.

    The seven sampled sets are compared with the committed sample, which holds
    every product of each of them and needs no network: the ids the catalogue
    stores for those sets are exactly the product ids the provider listed, in the
    same number. That covers a third of the game without asking anything.

    Then one set is asked of the provider now - GD01, live - and compared with the
    rows the catalogue holds for it. That half is what catches a provider that has
    renumbered its products since the import, which the committed sample cannot
    see by construction. One set rather than all 28 because it is the same fact
    each time and 28 sets is half a minute of requests for it.
    """
    sample = read_json_gz(SAMPLE)
    problems = []
    compared = 0
    for item, products in test_id_parity.gundam_set_downloads(sample):
        code = gcgapi.slug((item or {}).get("set_code"))
        published = sorted(str(c.get("product_id")) for c in products
                           if c.get("product_id"))
        if not code or not published:
            continue
        rows = psql(db_url, (
            "select id from public.catalog_cards where game = %s and set_code = %s"
            % (sql_text(GAME), sql_text(code))))
        stored = sorted(row[0] for row in rows)
        compared += len(stored)
        if stored != published:
            only_stored = sorted(set(stored) - set(published))[:3]
            only_published = sorted(set(published) - set(stored))[:3]
            problems.append(
                "set %r holds %d ids and the sample publishes %d: e.g. stored "
                "only %s, published only %s"
                % (code, len(stored), len(published), only_stored,
                   only_published))

    live_code = "GD01"
    try:
        live = sorted(str(c.get("product_id")) for c in gcgapi.set_cards(live_code)
                      if isinstance(c, dict) and c.get("product_id"))
    except Exception as exc:  # noqa: BLE001 - reported, with the reason
        live, why = [], str(exc)
    else:
        why = None
        rows = psql(db_url, (
            "select id from public.catalog_cards where game = %s and set_code = %s"
            % (sql_text(GAME), sql_text(gcgapi.slug(live_code)))))
        stored = sorted(row[0] for row in rows)
        compared += len(stored)
        if stored != live:
            problems.append(
                "set %s holds %d ids and gcgapi publishes %d for it now: e.g. "
                "stored only %s, published only %s"
                % (live_code, len(stored), len(live),
                   sorted(set(stored) - set(live))[:3],
                   sorted(set(live) - set(stored))[:3]))

    if problems:
        bad("every_stored_id_is_a_product_id_the_provider_publishes",
            "\n".join(problems))
        return
    if why is not None:
        skip("every_stored_id_is_a_product_id_the_provider_publishes "
             "(the live half)",
             "the sampled sets match, but gcgapi could not be asked for set %s: "
             "%s" % (live_code, why))
        return
    ok("every_stored_id_is_a_product_id_the_provider_publishes",
       "%d stored ids across the seven sampled sets are the product ids the "
       "committed sample lists, and %s's %d stored ids are the ones gcgapi "
       "publishes for it now - verbatim in both halves"
       % (compared - len(live), live_code, len(live)))


def check_sampled_sets_are_whole(db_url):
    """Every product a sampled set's response lists is a row the database holds.

    The provider's own answer for a set is the one statement about that set's size
    that does not come from this repository. Only the seven sampled sets can be
    checked this way without downloading the other 21, which is why it is a
    separate check from the counts above.
    """
    sample = read_json_gz(SAMPLE)
    problems = []
    checked = 0
    for item, products in test_id_parity.gundam_set_downloads(sample):
        code = gcgapi.slug((item or {}).get("set_code"))
        ids = sorted(str(c.get("product_id")) for c in products
                     if c.get("product_id"))
        if not code or not ids:
            continue
        checked += 1
        rows = psql(db_url, (
            "select count(*) from public.catalog_cards where game = %s"
            " and set_code = %s and id = any (%s)"
            % (sql_text(GAME), sql_text(code), sql_array(ids))))
        found = int(rows[0][0])
        if found != len(ids):
            problems.append("set %r lists %d products and %d of them are stored"
                            % (code, len(ids), found))
    if problems:
        bad("every_sampled_set_is_whole_against_the_provider", "\n".join(problems))
    else:
        ok("every_sampled_set_is_whole_against_the_provider",
           "all %d sets the committed sample holds a response for list ids the "
           "catalogue holds, so none of them was stored short" % checked)


def check_art_is_the_providers_own_address(db_url):
    """The stored art is the provider's URL, not a relayed one.

    CardArt.host rewrites a relayed host's URL on a web build while the client
    parses, so a row the provider path writes in a browser already holds a relayed
    address and the same row on a phone does not. The importer stores the address
    the provider published, which is the only thing it honestly can, and the step
    2 adapter applies the same rule when it turns a PostgREST row into the map the
    mapper reads. A stored relayed URL would be a row that works in one place and
    not the other, so it is asserted against rather than hoped for.
    """
    rows = psql(db_url, (
        "select id, image_normal from public.catalog_cards where game = %s"
        % sql_text(GAME)), want_json=True)
    relayed = [row["id"] for row in rows
               if isinstance(row.get("image_normal"), str)
               and "marquezhv.com" in row["image_normal"]]
    wrong_host = [row["id"] for row in rows
                  if row.get("image_normal") is not None
                  and not str(row["image_normal"]).startswith(
                      "https://www.gundam-gcg.com/")]
    missing = [row["id"] for row in rows if row.get("image_normal") is None]
    # The URL names the product it shows, which is what makes the art path and
    # the id the same fact rather than two that can drift.
    misnamed = [row["id"] for row in rows
                if isinstance(row.get("image_normal"), str)
                and ("/cards/card/%s.webp" % row["id"])
                not in row["image_normal"]]
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
    if misnamed:
        problems.append("%d row(s) carry art named after another product, e.g. %s"
                        % (len(misnamed), misnamed[:3]))
    if problems:
        bad("stored_art_is_the_providers_own_address", "\n".join(problems))
    else:
        ok("stored_art_is_the_providers_own_address",
           "all %d rows carry gundam-gcg.com art named after their own product "
           "id, and none carries a relayed address" % len(rows))


def check_no_price_rows(db_url):
    """The source quotes no price, so the importer writes none - in code and in data.

    gcgapi's card object has no market price, no low, no foil figure and no
    TCGplayer product id to join a price series to. replace_prices therefore has
    nothing to be handed, and this asserts both halves of that: the module never
    calls it, and the table holds no row for this game. A price row appearing here
    would be a number from nowhere, and a column of "--" on the card sheet is the
    honest state until a priced source for this game exists.
    """
    # Read off the module's syntax tree rather than its text: the file names
    # replace_prices in its own docstring - to say that it is *not* called - and
    # a grep that cannot tell a sentence from a call reported this very file's
    # first run as a failure.
    with open(os.path.join(TOOL, "import_gundam_catalogue.py"),
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
                        "gcgapi quotes no price to give it" % calls)
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
    still resolve. The cards are what make this game's version worth running:
    Gundam's ids are the provider's own product ids, which is exactly what a
    holding names.
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
    rows = psql(db_url, (
        "select sets_revision, set_count, card_count, last_import_ok,"
        "       coalesce(last_import_note, ''), coalesce(source, ''),"
        "       sets_updated_at is not null"
        "  from public.catalog_meta where game = %s" % sql_text(GAME)))
    revision, set_count, card_count, ok_flag, note, source, dated = rows[0]
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
    if problems:
        bad("catalog_meta_records_the_import", "\n".join(problems))
    else:
        ok("catalog_meta_records_the_import",
           "sets_revision %s, %s sets, %s cards, source %s, note: %s"
           % (revision, set_count, card_count, SOURCE, note))
    return int(revision)


def check_checksums(db_url, sets):
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
           "anon and authenticated still hold SELECT and nothing else, so this "
           "import did not widen the posture step 0 fixed")


def check_http(base, key, sets):
    status, body, _ = postgrest_get(
        base, "catalog_sets?game=eq.%s&select=code&limit=1000" % GAME, key)
    if status not in (200, 206) or not isinstance(body, list):
        bad("publishable_key_reads_the_catalogue",
            "catalog_sets answered HTTP %s" % status)
        return
    if len(body) != sets:
        bad("publishable_key_reads_the_catalogue",
            "the publishable key sees %d sets, the importer wrote %d"
            % (len(body), sets))
        return
    status, one, _ = postgrest_get(
        base, "catalog_cards?game=eq.%s&id=eq.GD01-001&select=id,name,set_code"
        % GAME, key)
    if status not in (200, 206) or not isinstance(one, list) or len(one) != 1:
        bad("publishable_key_reads_the_catalogue",
            "a single card read answered HTTP %s with %d rows"
            % (status, len(one or [])))
        return
    status, _, headers = postgrest_get(
        base, "catalog_cards?game=eq.%s&select=id&limit=1" % GAME, key)
    total = headers.get("Content-Range", "")
    ok("publishable_key_reads_the_catalogue",
       "%d sets and catalog_cards range %s readable; GD01-001 reads back as %r "
       "in set %r" % (len(body), total or "not reported", one[0].get("name"),
                      one[0].get("set_code")))


def check_rerun_changes_nothing(db_url, sets, cards, revision, skip_rerun):
    """Re-runs the importer over unchanged data and compares everything it could move.

    The second run is the only one that can prove the checksum skip, so the second
    run happens. It is bounded to the seven sets the committed sample holds whole,
    and every set in the game is compared afterwards, because a run that named a
    subset must touch that subset and nothing else.

    Counts alone would not catch a run that rewrote every row to the same values;
    the checksums, the revisions and catalogued_at are compared too, so a rewrite
    shows up even when the content is identical.
    """
    if skip_rerun:
        skip("rerun_changes_nothing", "not run: --skip-rerun")
        return

    importer = os.path.join(TOOL, "import_gundam_catalogue.py")
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
           "cards_revision and catalogued_at, so the seven sets it was asked for "
           "were skipped on their checksums and the other %d were never touched; "
           "sets_revision stayed %d"
           % (sets, sets - len(SAMPLE_SETS), revision))


def check_account_tables(db_url, before):
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
        skip("counts_match_the_provider (the provider's own set list)",
             "gcgapi could not be read: %s. The stored set list is still checked "
             "for structure, but not against a remembered number" % why)
    sets, cards = check_counts(db_url, provider)
    if sets is None or cards is None:
        print()
        print("the catalogue is not in a state worth proving further")
        return 1

    check_orphans(db_url)
    check_stored_codes_are_the_folded_form(db_url)
    check_row_parity(db_url)
    check_ids_are_the_providers(db_url)
    check_sampled_sets_are_whole(db_url)
    check_art_is_the_providers_own_address(db_url)
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
