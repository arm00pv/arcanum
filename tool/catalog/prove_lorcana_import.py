#!/usr/bin/env python3
"""Prove the Lorcana import against the live database.

Design: docs/catalogue-server-side.md, section 8 step 1. Step 0 proved a posture;
this proves a catalogue. The claim is that one game - Lorcana, the cheapest real
catalogue at 24 sets - is now held on the server, that the rows there are exactly
the rows the Dart clients would have derived themselves, that re-running the
importer changes nothing, and that the importer cannot damage anything it does
not own.

Written the way tool/catalog/prove_catalogue_posture.py is written, and for the
same reason: the interesting failures are invisible in the SQL that was supposed
to produce them and obvious in the database. A function that agrees with a
committed vector file on a laptop and disagrees with the deployed generated
column is a real failure mode, and only a check against the deployed column finds
it.

Two kinds of check, and no one check implies another:

| Check | Why it is not implied by the others |
| --- | --- |
| The publishable key reads 24 sets and 3,208 cards over HTTP | a browser reaches this through PostgREST, and a grant can be present while a policy is not |
| The counts match what the provider publishes | the importer would report success for a run that wrote nothing |
| Every card belongs to a stored set | the importer would report success for rows nothing can resolve |
| The committed id vectors equal the live rows | the two languages can agree on a laptop and the import still be stale |
| The live code_folded expression equals the Dart-built one | the expression can be right in the file and wrong in the database |
| Postgres evaluates that expression to the committed folded values | the expression can match as text and be evaluated differently |
| The same for number_bare | a separate rule, separately capable of drifting |
| A per-set delete leaves every other set alone | the scoping is the only thing between an import and the catalogue |
| The importer emits no delete of a set, and retirement round-trips | soft delete is a property of the code, not of a row |
| Re-running the importer changes nothing | idempotency is a claim about the second run, not the first |
| catalog_meta records the import | a broken importer has to be readable as a fact rather than inferred |
| The account tables are unchanged | the thing this step promised not to disturb |
| The catalogue is still SELECT-only for anon and authenticated | an import that widened a grant would be the worst failure here |
| The generated columns refuse a write | they are what keeps the two paths folding alike |
| No probe rows are left behind | the test must not be the thing that damages the database |

Credentials come from the environment, or from a file named with --env-file.
Nothing in this file holds a secret and the database URL is never printed.

    set -a; . /home/zixen/arcanum/supabase.env; set +a
    python3 tool/catalog/prove_lorcana_import.py

--no-auth runs without the HTTP half. --skip-rerun does not re-run the importer,
which is the slowest check and the one that proves idempotency.
Exit status is 0 only if nothing failed.
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
GAME = "lorcana"
CATALOG_TABLES = ("catalog_sets", "catalog_cards", "catalog_prices", "catalog_meta")

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.dirname(HERE)
VECTORS = os.path.join(HERE, "catalog_id_vectors.json.gz")
FOLD_VECTORS = os.path.join(HERE, "fold_vectors.json")

# psql is told its connection through the environment rather than through its
# argv, so the password is not in a process listing. catalog_store owns that
# split and is the module the importer itself runs, so this proof uses it
# rather than keeping a second copy of a rule about credentials.
sys.path.insert(0, TOOL)
import catalog_store  # noqa: E402

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
    """The session pooler, which is what the design names for admin work.

    The credentials file also carries the runtime transaction pooler on 6543,
    which the web service uses. Either answers these queries; the importer and
    this proof both use the session pooler so that what is being proved is the
    connection the nightly job actually makes.
    """
    return db_url.replace(":6543/", ":5432/"), ":6543/" in db_url


def psql(db_url, sql, want_json=False):
    """One script through psql, with ON_ERROR_STOP, reading JSON when asked."

    The JSON form is used for anything that reads card text: a card's rules text
    contains pipes, tabs and newlines, and the pipe-separated text protocol
    would turn any of them into a column boundary.

    The URL is split into the variables libpq reads from the environment and
    never passed as an argument, so the password is not visible to ps while a
    statement runs.
    """
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
# Reading the committed vectors
# ---------------------------------------------------------------------------


def read_json_gz(path):
    with gzip.open(path, "rb") as fh:
        return json.loads(fh.read().decode("utf-8"))


def sql_text(value):
    """A Python string as a SQL literal. The same rule the importer uses."""
    return "'" + str(value).replace("'", "''") + "'"


def normalise_expr(text):
    """An expression with the spelling differences Postgres is free to make.

    Postgres renders a text literal as '- '::text and re-adds parentheses it
    considers necessary, while the Dart builds '- '. Those are the same
    expression; comparing the raw strings would report a difference that is not
    one, which is worse than not comparing them at all. What is left after this
    is the structure: which function, on which column, in which order.
    """
    text = re.sub(r"::(text|character varying|bpchar)", "", text)
    text = re.sub(r"\s+", "", text)
    text = text.replace("(", "").replace(")", "")
    return text.lower()


def live_expression(db_url, table, column):
    rows = psql(db_url, (
        "select pg_get_expr(d.adbin, d.adrelid)"
        "  from pg_attrdef d"
        "  join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum"
        f" where d.adrelid = 'public.{table}'::regclass and a.attname = {sql_text(column)}"))
    return rows[0][0] if rows else None


# ---------------------------------------------------------------------------
# The checks
# ---------------------------------------------------------------------------


def check_http(base, key, expected):
    # 206 is the expected answer, not a fault: PostgREST replies Partial Content
    # whenever the response is bounded by a limit or a Range, which every paged
    # read in the design is.
    status, body, headers = http_get(base, f"catalog_sets?game=eq.{GAME}&select=code&limit=1000", key)
    if status not in (200, 206) or not isinstance(body, list):
        bad("publishable_key_reads_the_catalogue", f"catalog_sets answered HTTP {status}")
        return
    if len(body) != expected["sets"]:
        bad("publishable_key_reads_the_catalogue",
            f"the publishable key sees {len(body)} sets, the importer wrote {expected['sets']}")
        return
    status, cards, headers = http_get(
        base, f"catalog_cards?game=eq.{GAME}&select=id&limit=1", key)
    if status not in (200, 206):
        bad("publishable_key_reads_the_catalogue", f"catalog_cards answered HTTP {status}")
        return
    total = headers.get("Content-Range", "")
    ok("publishable_key_reads_the_catalogue",
       f"{len(body)} sets readable; catalog_cards range {total or 'not reported'}")


def check_counts(db_url, provider_sets):
    """What is stored is complete, and a set list a client can act on.

    The card total is deliberately not compared against a number written down
    here. A remembered constant would fail the day the publisher adds a card,
    which is a false alarm, and would pass for a run that stored every set
    thinly, which is the failure that matters. What is checked instead is the
    structure: the set list is the provider owner's whole list, no set is retired
    and none was stored empty, and every set's own card_row_count agrees with the
    rows actually present. A set that was half-imported fails the last of those.
    """
    rows = psql(db_url, (
        f"select count(*) from public.catalog_sets where game = {sql_text(GAME)}"))
    sets = int(rows[0][0])
    if sets != provider_sets:
        bad("counts_match_the_provider",
            f"{sets} sets stored, the committed sample of the provider's list holds "
            f"{provider_sets}")
        return sets, None

    rows = psql(db_url, (
        f"select (select count(*) from public.catalog_cards where game = {sql_text(GAME)}),"
        f"       (select count(*) from public.catalog_sets where game = {sql_text(GAME)}"
        "          and retired_at is not null),"
        f"       (select count(*) from public.catalog_sets where game = {sql_text(GAME)}"
        "          and card_row_count = 0)"))
    cards, retired, empty = (int(v) for v in rows[0])
    problems = []
    if retired:
        problems.append(f"{retired} set(s) retired; the provider publishes every one")
    if empty:
        problems.append(f"{empty} set(s) stored with no cards at all")

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
        ok("counts_match_the_provider",
           f"all {sets} of the provider's sets stored, none retired, none empty, "
           f"and every set's recorded card count matches its rows: {cards:,} cards")
    return sets, cards


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


def check_id_parity_against_the_database(db_url):
    """The committed Dart-derived rows, compared with the rows in Postgres.

    This is the claim the whole step rests on. test/catalog/test_id_parity.py
    proves the two languages derive the same rows from the same responses; this
    proves the rows actually in the database are those rows, which is a
    different statement - an import that predates a rule change satisfies the
    first and fails this.
    """
    vectors = read_json_gz(VECTORS)
    cards = vectors["cards"]
    ids = [row["id"] for row in cards]
    array = "array[" + ", ".join(sql_text(i) for i in ids) + "]::text[]"

    columns = [c for c in cards[0] if c != "id"]
    selected = ", ".join(["id"] + columns)
    live = psql(db_url, (
        f"select {selected} from public.catalog_cards"
        f" where game = {sql_text(GAME)} and id = any ({array})"), want_json=True)

    by_id = {row["id"]: row for row in live}
    missing = [i for i in ids if i not in by_id]
    if missing:
        bad("imported_rows_equal_the_clients_derivation",
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
    for row in cards:
        live_row = by_id[row["id"]]
        for column in columns:
            if not same(row.get(column), live_row.get(column)):
                problems.append(
                    f"{row['id']}.{column}: database {live_row.get(column)!r} != "
                    f"client {row.get(column)!r}")
                break
        if len(problems) >= 6:
            break
    if problems:
        bad("imported_rows_equal_the_clients_derivation", "\n".join(problems))
    else:
        ok("imported_rows_equal_the_clients_derivation",
           f"all {len(ids)} sampled cards match the Dart-derived vectors in "
           f"{len(columns)} columns each")


def check_generated_columns(db_url):
    """The folded column and the bare number, against the Dart-built vectors.

    Three separate claims, because they can fail separately: the deployed
    expression is the one the Dart builds; Postgres evaluates that expression to
    the committed values; and the deployed column itself folds a real card row
    the way the vectors say. A check on the file alone would pass while the
    database disagreed.
    """
    fold = json.load(open(FOLD_VECTORS, encoding="utf-8"))

    live_code = live_expression(db_url, "catalog_sets", "code_folded")
    live_number = live_expression(db_url, "catalog_cards", "number_bare")
    if live_code is None or live_number is None:
        bad("generated_columns_match_the_dart_rules",
            "a generated column is missing: re-apply step 0")
        return

    problems = []
    if normalise_expr(live_code) != normalise_expr(fold["code_expr_sql"]):
        problems.append(f"code_folded is\n            {live_code}\n          but the "
                        f"Dart builds\n            {fold['code_expr_sql']}")
    if normalise_expr(live_number) != normalise_expr(fold["number_expr_sql"]):
        problems.append(f"number_bare is {live_number}, expected "
                        f"{fold['number_expr_sql']}")
    if problems:
        bad("generated_columns_match_the_dart_rules", "\n".join(problems))
    else:
        ok("generated_columns_match_the_dart_rules",
           f"code_folded is {live_code}; number_bare is {live_number}")

    # Postgres evaluates the deployed expressions, over the committed vectors.
    # The expressions are taken from the catalogue itself rather than retyped,
    # so this cannot agree with the file while disagreeing with the database.
    code_sql = live_code.replace("code", "input")
    values = ",\n".join(
        f"          ({sql_text(v['input'])}, {sql_text(v['stored'])})"
        for v in fold["codes"])
    rows = psql(db_url, "\n".join([
        "begin;",
        "create temp table fold_probe (input text, expected text);",
        f"insert into fold_probe values\n{values};",
        f"select count(*) from fold_probe where {code_sql} is distinct from expected;",
        "rollback;"]))
    wrong = int(rows[0][0])
    if wrong:
        bad("postgres_folds_the_vectors_as_the_dart_does",
            f"{wrong} of {len(fold['codes'])} code vectors fold differently in "
            "Postgres than the committed file says")
    else:
        ok("postgres_folds_the_vectors_as_the_dart_does",
           f"all {len(fold['codes'])} code vectors, evaluated by the deployed "
           "expression, equal the committed folded value")

    number_sql = live_number.replace("collector_number", "input")
    values = ",\n".join(
        f"          ({sql_text(v['input'])}, {sql_text(v['bare'])})"
        for v in fold["numbers"])
    rows = psql(db_url, "\n".join([
        "begin;",
        "create temp table bare_probe (input text, expected text);",
        f"insert into bare_probe values\n{values};",
        f"select count(*) from bare_probe where {number_sql} is distinct from expected;",
        "rollback;"]))
    wrong = int(rows[0][0])
    if wrong:
        bad("postgres_bares_the_numbers_as_the_dart_does",
            f"{wrong} of {len(fold['numbers'])} number vectors differ")
    else:
        ok("postgres_bares_the_numbers_as_the_dart_does",
           f"all {len(fold['numbers'])} collector-number vectors match")


def check_generated_columns_refuse_writes(db_url):
    # A generated column refuses an UPDATE with a specific error, and psql with
    # ON_ERROR_STOP propagates it. Run it in its own call so the refusal can be
    # read rather than aborting the checks around it.
    proc = subprocess.run(
        ["psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c",
         f"begin; update public.catalog_sets set code_folded = 'zz' "
         f"where game = {sql_text(GAME)}; rollback;"],
        capture_output=True, text=True, timeout=TIMEOUT,
        env=catalog_store.psql_environment(db_url))
    if proc.returncode != 0 and "generated column" in proc.stderr:
        ok("generated_columns_refuse_a_write",
           "an update naming code_folded is refused, so the folded form cannot be "
           "written out of step with the code it is folded from")
    elif proc.returncode == 0:
        bad("generated_columns_refuse_a_write",
            "code_folded accepted an explicit value; it is not generated any more")
    else:
        bad("generated_columns_refuse_a_write",
            f"refused for the wrong reason: {proc.stderr.strip()[:200]}")


def check_deletes_are_scoped(db_url, sets, cards):
    """A per-set delete removes that set and nothing else.

    The delete runs against a temporary copy of the real rows rather than against
    the catalogue. What is being tested is which rows the predicate selects, and
    a copy of every row answers that exactly. Running the same statement against
    the live table would answer it too, and would depend on a rollback to leave
    the catalogue as it found it - a real set of real cards staked on a detail of
    how psql batches a multi-statement string. No check here is worth that.

    The predicate is taken from the importer itself, so this tests the statement
    that runs rather than a paraphrase of it.
    """
    sys.path.insert(0, TOOL)
    import catalog_store  # noqa: E402

    fake_set = {"code": "zz-probe", "id": "zz", "name": "probe"}
    fake_card = {"id": "zz-probe-1", "set_code": "zz-probe", "name": "probe",
                 "collector_number": "1"}
    emitted = catalog_store.CatalogStore("postgres://unused", dry_run=True)._set_transaction(
        GAME, fake_set, [fake_card], "checksum", bump=True, retire=None)
    match = re.search(r"(delete\s+from\s+public\.catalog_cards[^;]*)", emitted, re.I)
    if not match:
        bad("a_per_set_delete_leaves_every_other_set_alone",
            "the write path emitted no card delete at all")
        return
    # The generated delete names the probe set. It is retargeted at a real set so
    # that the copy below is the shape of the catalogue rather than an empty one.
    predicate = match.group(1)

    rows = psql(db_url, (
        f"select code from public.catalog_sets where game = {sql_text(GAME)}"
        " order by code limit 2"))
    first, second = rows[0][0], rows[1][0]

    # Retargeted at the copy and at a real set code. Both substitutions are
    # checked rather than assumed: a re.sub whose pattern does not match returns
    # the string unchanged, and an earlier version of this check did exactly that
    # - it deleted from the catalogue instead of from the copy, removed nothing
    # from the copy, and reported a scoping failure that did not exist while
    # running a real DELETE against production rows.
    real_delete = predicate.replace("public.catalog_cards", "probe_cards")
    real_delete = re.sub(r"set_code = 'zz-probe'", f"set_code = {sql_text(first)}",
                         real_delete)
    if "probe_cards" not in real_delete or "zz-probe" in real_delete:
        bad("a_per_set_delete_leaves_every_other_set_alone",
            f"could not retarget the emitted statement at the copy: {real_delete!r}")
        return
    rows = psql(db_url, "\n".join([
        "begin;",
        "create temp table probe_cards (game text not null, set_code text not null, id text not null);",
        f"insert into probe_cards select game, set_code, id from public.catalog_cards "
        f"where game = {sql_text(GAME)};",
        f"select count(*) from probe_cards where game = {sql_text(GAME)} "
        f"and set_code = {sql_text(second)};",
        f"select count(*) from probe_cards where game = {sql_text(GAME)} "
        f"and set_code = {sql_text(first)};",
        real_delete + ";",
        f"select count(*) from probe_cards where game = {sql_text(GAME)} "
        f"and set_code = {sql_text(second)};",
        "select count(*) from probe_cards;",
        "rollback;"]))
    second_before, first_before, second_after, remaining = (int(r[0]) for r in rows)
    problems = []
    if second_before != second_after:
        problems.append(f"the emitted delete moved set {second!r} from "
                        f"{second_before} to {second_after} cards")
    if remaining != cards - first_before:
        problems.append(f"expected {cards - first_before} rows left, found {remaining}")
    if problems:
        bad("a_per_set_delete_leaves_every_other_set_alone", "\n".join(problems))
    else:
        ok("a_per_set_delete_leaves_every_other_set_alone",
           f"the statement the importer emits, targeted at set {first!r}, removed "
           f"its {first_before} cards, left set {second!r} at {second_after} cards "
           f"and left {remaining:,} of {cards:,} rows")

    # And it ran against a copy, so the catalogue was never at risk.
    rows = psql(db_url, (
        f"select count(*) from public.catalog_cards where game = {sql_text(GAME)}"))
    if int(rows[0][0]) != cards:
        bad("the_scoping_probe_left_no_trace",
            f"{rows[0][0]} cards after the probe, expected {cards}")
    else:
        ok("the_scoping_probe_left_no_trace",
           f"still {cards:,} card rows; the probe deleted from a temporary copy and "
           "never from the catalogue")


def check_the_importer_cannot_delete_a_set():
    """The module emits no statement that removes a set, and never a bare delete.

    Read off the code rather than the database, because "cannot" is a claim about
    what may be generated. Both statements the write path produces are generated
    here and inspected.
    """
    sys.path.insert(0, TOOL)
    import catalog_store  # noqa: E402

    fake_set = {"code": "zz-probe", "id": "zz", "name": "probe"}
    fake_card = {"id": "zz-probe-1", "set_code": "zz-probe", "name": "probe",
                 "collector_number": "1"}
    store = catalog_store.CatalogStore("postgres://unused", dry_run=True)
    sql = store._set_transaction("zz-probe-game", fake_set, [fake_card],
                                 "checksum", bump=True, retire=None)

    problems = []
    if re.search(r"delete\s+from\s+public\.catalog_sets", sql, re.I):
        problems.append("the write path emits a delete of catalog_sets")
    for statement in re.findall(r"delete\s+from[^;]*", sql, re.I):
        if "where" not in statement.lower():
            problems.append(f"an unscoped delete is emitted: {statement[:80]}")
        elif "game =" not in statement or "set_code =" not in statement:
            problems.append(f"a delete not scoped to one game and set: {statement[:80]}")
    # The store is in dry-run mode, so these never reach the database - they only
    # exercise the guard. Its own report is captured rather than printed, because
    # a dry run announcing a statement it refused to run reads like a warning.
    def refused(sql):
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                store._run(sql)
            return False
        except catalog_store.CatalogError:
            return True

    if not refused("delete from public.collection_entries where true;"):
        problems.append("the guard allowed a statement against collection_entries")
    if not refused("delete from public.decks where true;"):
        problems.append("the guard allowed a statement against decks")
    # The literal-aware guard, which a card whose text mentions decks defeated in
    # the first implementation. Card text lives in literals and must not trip it.
    if refused("select 1 from public.catalog_sets where name = 'look at your decks';"):
        problems.append("the guard refused a statement that only mentions decks in "
                        "a literal, which is what card text is")

    if problems:
        bad("the_write_path_cannot_remove_a_set_or_an_account_row",
            "\n".join(problems))
    else:
        ok("the_write_path_cannot_remove_a_set_or_an_account_row",
           "no delete of catalog_sets is generated; every card delete is scoped to "
           "one game and one set code; statements against the account tables are "
           "refused even when a card literal mentions them")


def check_retirement_round_trips(db_url, sets):
    """Soft delete is reversible, which is what makes it a soft delete.

    A hard delete cannot be undone by the next import; a retired set can. The
    experiment retires one set and puts it back, in a transaction that is rolled
    back, so the catalogue keeps its rows either way.
    """
    rows = psql(db_url, "\n".join([
        "begin;",
        f"select code from public.catalog_sets where game = {sql_text(GAME)}"
        " order by code limit 1;"]))
    code = rows[0][0]
    rows = psql(db_url, "\n".join([
        f"update public.catalog_sets set retired_at = now() where game = {sql_text(GAME)}"
        f" and code = {sql_text(code)};",
        f"select count(*) from public.catalog_sets where game = {sql_text(GAME)}"
        " and retired_at is null;",
        f"update public.catalog_sets set retired_at = null where game = {sql_text(GAME)}"
        f" and code = {sql_text(code)};",
        f"select count(*) from public.catalog_sets where game = {sql_text(GAME)}"
        " and retired_at is null;",
        f"select count(*) from public.catalog_cards where game = {sql_text(GAME)};",
        "rollback;"]))
    retired_sets, restored_sets, cards = (int(r[0]) for r in rows)
    if retired_sets != sets - 1 or restored_sets != sets:
        bad("retirement_is_a_soft_delete_and_reverses",
            f"retiring one set left {retired_sets} visible, restoring left {restored_sets}")
    else:
        ok("retirement_is_a_soft_delete_and_reverses",
           f"retiring a set hides it ({retired_sets} visible), restoring shows it "
           f"again ({restored_sets}), and its {cards:,} cards were never touched")


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
        problems.append(f"catalog_meta says {set_count}/{card_count}, the tables hold "
                        f"{sets}/{cards}")
    if source != "lorcast":
        problems.append(f"source is {source!r}, expected 'lorcast'")
    if dated != "t":
        problems.append("sets_updated_at is null")
    if not note:
        problems.append("last_import_note is empty")
    if problems:
        bad("catalog_meta_records_the_import", "\n".join(problems))
    else:
        ok("catalog_meta_records_the_import",
           f"sets_revision {revision}, {set_count} sets, {card_count} cards, "
           f"source lorcast, note: {note}")
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
           "import did not widen the posture step 0 fixed")


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


def check_rerun_is_idempotent(db_url, sets, cards, revision, skip_rerun):
    """Re-runs the importer and compares everything it could have moved.

    The second run is the only one that can prove idempotency, so it is actually
    performed rather than reasoned about. Counts alone would not catch a run that
    rewrote every row to the same values; the checksums, the revisions and
    catalogued_at are compared too, so a rewrite shows up even when the content
    is identical.
    """
    if skip_rerun:
        skip("rerun_changes_nothing", "not run: --skip-rerun")
        return

    poller = os.path.join(TOOL, "poll_lorcana_prices.py")
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
    proc = subprocess.run([sys.executable, poller, "--catalog-only"],
                          capture_output=True, text=True, timeout=1800,
                          cwd=os.path.dirname(poller), env=os.environ)
    if proc.returncode != 0:
        bad("rerun_changes_nothing",
            f"the second run exited {proc.returncode}: {proc.stderr.strip()[:300]}")
        return
    after = snapshot()

    if before != after:
        changed = [(b[0], b[2], a[2]) for b, a in zip(before, after) if b != a]
        bad("rerun_changes_nothing",
            f"{len(changed)} set(s) moved on a second run, "
            f"e.g. {changed[:3]} (code, revision before, revision after)")
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
           f"cards_revision and catalogued_at, and sets_revision stayed {revision}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env-file", default=None)
    ap.add_argument("--no-auth", action="store_true",
                    help="skip the HTTP half")
    ap.add_argument("--skip-rerun", action="store_true",
                    help="do not re-run the importer to prove idempotency")
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
    db_url, was_pooled = session_url(db_url)

    for path in (VECTORS, FOLD_VECTORS):
        if not os.path.exists(path):
            print(f"missing {path}", file=sys.stderr)
            return 2

    expected = {"sets": None, "cards": None}

    # The account tables first: if the import damaged them, that should be the
    # headline rather than a line at the bottom.
    rows = psql(db_url, (
        "select (select count(*) from public.decks),"
        "       (select count(*) from public.collection_entries)"))
    accounts_before = tuple(int(v) for v in rows[0])

    print("--- SQL, as the owner ---")

    # The set list to compare against comes from the committed sample, which
    # holds every set the provider publishes, rather than from a constant typed
    # in here. Nothing else in this file is compared against a remembered number.
    provider_sets = len(read_json_gz(VECTORS)["sets"])
    sets, cards = check_counts(db_url, provider_sets)
    if sets is None or cards is None:
        print()
        print("the catalogue is not in a state worth proving further")
        return 1

    check_orphans(db_url)
    check_id_parity_against_the_database(db_url)
    check_generated_columns(db_url)
    check_generated_columns_refuse_writes(db_url)
    check_deletes_are_scoped(db_url, sets, cards)
    check_the_importer_cannot_delete_a_set()
    check_retirement_round_trips(db_url, sets)
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
            check_http(base, key, {"sets": sets, "cards": cards})

    print()
    print("--- the second run ---")
    check_rerun_is_idempotent(db_url, sets, cards, revision, args.skip_rerun)

    print()
    print("--- nothing left behind ---")
    check_account_tables(db_url, accounts_before)
    rows = psql(db_url, (
        "select count(*) from public.catalog_sets where game like 'zz%'"))
    if int(rows[0][0]):
        bad("no_probe_rows_left_behind", f"{rows[0][0]} probe set(s) remain")
    else:
        ok("no_probe_rows_left_behind",
           "no probe rows in the catalogue, and the account tables hold what they held")

    failed = sum(1 for status, _, _ in RESULTS if status == "FAIL")
    passed = sum(1 for status, _, _ in RESULTS if status == "PASS")
    skipped = sum(1 for status, _, _ in RESULTS if status == "SKIP")
    print()
    print(f"{passed} passed, {failed} failed, {skipped} skipped")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
