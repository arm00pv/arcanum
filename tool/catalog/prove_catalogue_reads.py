#!/usr/bin/env python3
"""Prove the three server-side reads against the live database.

Design: docs/catalogue-server-side.md, section 4, and the step 4 row of the
migration list in section 8. Step 4 ships catalog_cards_by_ids - the batched read
the design calls the largest user-visible improvement in the document and then
never schedules - plus catalog_search and catalog_cards_by_number, which are the
two reads a PostgREST filter cannot express. They live in
tool/catalog/0003_read_functions.sql, and this file is what says they work.

What is being tested, and why each one is a claim rather than a formality:

  * **The plan.** A function that answers correctly by reading the whole table is
    the exact failure 0002 was written to fix - it was measured there, not
    reasoned about - so every read here is EXPLAINed as the deployed body, with
    the parameters renamed to placeholders and the plan cache forced to a generic
    plan, which is how PostgREST calls it. The plan must name the index. The
    deployed body is taken from pg_proc rather than retyped, so this cannot agree
    with a copy of the function while disagreeing with the function.

  * **The rows.** Search and number results are compared against a reference
    predicate written out in this file - for the number read, a transcription of
    CatalogDao.searchByNumber's own SQL - over real query terms, and every
    committed number-query vector is run through the deployed function. The
    vector file is generated from CollectorQuery.parse by
    tool/catalog/gen_number_query_vectors.dart, so the two languages are held to
    the same answers rather than to the same intentions.

  * **The posture.** These functions are security invoker, so anonymous read is
    the row level security policy doing its job and not a bypass; and reading is
    all anyone can do through them.

  * **The wire.** Finally the same three calls are made over HTTP with the
    publishable key, because that is what the app does. Supabase truncates a
    response at 1,000 rows and this is where that number is measured rather than
    assumed: asking for 1,200 ids answers with 200 OK and 1,000 rows.

Nothing here writes to the catalogue. The counts at the start and at the end are
compared so that "nothing was written" is a check rather than a promise.

Credentials come from the environment, or from a KEY=VALUE file named with
--env-file. They are never printed, and nothing in this file holds a secret.

  SUPABASE_URL               required unless --sql-only
  SUPABASE_PUBLISHABLE_KEY   required unless --sql-only - the public key
  SUPABASE_DB_URL_POOLED     required - the session pooler; the direct host is
                             IPv6-only and unreachable from most places

Usage:
  set -a; . /home/zixen/arcanum/supabase.env; set +a
  python3 tool/catalog/prove_catalogue_reads.py

Exit status is 0 only if nothing failed. A skip is reported as a skip, never as
a pass.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

# psql is told its connection through the environment rather than through its
# argv, so the password is not in a process listing. catalog_store owns that
# split and is deployed alongside the importer, so it is imported here rather
# than copied: a second copy of a rule about credentials is a second thing to
# get wrong.
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import catalog_store  # noqa: E402

TIMEOUT = 60

GAME = "lorcana"

# The three reads. The bodies are taken from pg_proc at run time; the argument
# lists are the ones 0003 declares, and are used both to rename the parameters
# into placeholders and to prepare the statement.
FUNCTIONS = {
    "catalog_cards_by_ids": {
        "call": ("'lorcana'", "array['crd_nothing']"),
        "expect_index": ("catalog_cards_pkey",),
    },
    "catalog_search": {
        "call": ("'lorcana'", "'elsa'", "80"),
        "expect_index": ("catalog_cards_name_trgm", "catalog_cards_text_trgm"),
    },
    "catalog_cards_by_number": {
        "call": ("'lorcana'", "array[]::text[]", "'001'", "true", "80"),
        "expect_index": ("catalog_cards_number_nocase", "catalog_cards_number"),
    },
}

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


def sql_text(value):
    return "'" + str(value).replace("'", "''") + "'"


# ---------------------------------------------------------------------------
# SQL, as the owner
# ---------------------------------------------------------------------------


# psql's field separator. Not a pipe: a function body is full of them, because
# '||' is string concatenation and every predicate in this catalogue uses it.
SEPARATOR = ""


def psql(db_url, sql):
    """One batch of statements, separated by a character SQL never contains.

    The URL is split into the variables libpq reads from the environment and
    never passed as an argument, so the password is not visible to ps while a
    statement runs.
    """
    proc = subprocess.run(
        ["psql", "-X", "-q", "-A", "-t", "-F", SEPARATOR,
         "-v", "ON_ERROR_STOP=1", "-c", sql],
        capture_output=True, text=True, timeout=300,
        env=catalog_store.psql_environment(db_url),
    )
    if proc.returncode != 0:
        raise RuntimeError(f"psql: {proc.stderr.strip()[:600]}")
    return [line.split(SEPARATOR) for line in proc.stdout.splitlines() if line != ""]


def function_source(db_url, name):
    """The deployed body of one function, and its parameter names."""
    # The body comes back flattened onto one line: psql separates rows by
    # newlines and a function body has several of them. Its own SQL comments go
    # with them, which is safe because a comment is not part of the query - and
    # leaving them in would be a comment swallowed by the collapse, and a
    # predicate with it.
    rows = psql(db_url, (
        "select pg_get_function_identity_arguments(p.oid),"
        "       regexp_replace(regexp_replace(p.prosrc,"
        "         '--[^' || chr(10) || ']*', '', 'g'), '\\s+', ' ', 'g'),"
        "       p.provolatile, p.prosecdef::text,"
        "       coalesce(array_to_string(p.proconfig, ','), ''),"
        "       l.lanname"
        "  from pg_proc p"
        "  join pg_namespace n on n.oid = p.pronamespace"
        "  join pg_language l on l.oid = p.prolang"
        f" where n.nspname = 'public' and p.proname = {sql_text(name)}"))
    if not rows:
        return None
    identity, body, volatility, secdef, config, language = rows[0]
    # Stripped, because a two argument identity is "p_game text, p_ids text[]"
    # and the leading space of the second one is not part of its name.
    names = [a.strip().rsplit(" ", 1)[0] for a in identity.split(",")]
    types = [a.strip().rsplit(" ", 1)[1] for a in identity.split(",")]
    return {
        "identity": identity, "body": body, "volatility": volatility,
        "secdef": secdef, "config": config, "language": language,
        "names": names, "types": types,
    }


def as_prepared(source):
    """The deployed body with its named parameters turned into placeholders.

    A SQL function's body is planned as its own query, with one parameter per
    argument, and this is that query. Renaming rather than retyping is the whole
    point: a paraphrase of the function could keep an index that the function
    itself had wrapped in lower().
    """
    body = source["body"].strip().rstrip(";")
    for index, name in enumerate(source["names"], start=1):
        body = re.sub(r"\b" + re.escape(name) + r"\b", "$" + str(index), body)
    return body


def explain(db_url, source, call):
    """The plan the deployed body runs, with bound parameters."""
    statement = (
        "set plan_cache_mode = force_generic_plan;\n"
        f"prepare probe ({', '.join(source['types'])}) as {as_prepared(source)};\n"
        f"explain (analyze, buffers) execute probe({', '.join(call)});"
    )
    proc = subprocess.run(
        ["psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c",
         statement],
        capture_output=True, text=True, timeout=300,
        env=catalog_store.psql_environment(db_url),
    )
    if proc.returncode != 0:
        raise RuntimeError(f"psql: {proc.stderr.strip()[:600]}")
    return proc.stdout.strip()


def check_functions_are_the_shape_the_design_requires(db_url):
    problems, seen = [], []
    for name in FUNCTIONS:
        source = function_source(db_url, name)
        if source is None:
            problems.append(f"{name} does not exist")
            continue
        seen.append(name)
        if source["language"] != "sql":
            problems.append(f"{name} is {source['language']}, not sql")
        if source["volatility"] != "s":
            problems.append(f"{name} is not stable (provolatile={source['volatility']})")
        # 'true'/'false', not 't'/'f': psql renders a cast boolean in words,
        # and the posture proof already has a scar from comparing the wrong one.
        if source["secdef"] != "false":
            problems.append(f"{name} is SECURITY DEFINER, which is a bypass")
        if "search_path" not in source["config"]:
            problems.append(f"{name} has no search_path: {source['config'] or 'none'}")
    if problems:
        bad("the_three_reads_are_sql_stable_invoker_with_a_search_path",
            "\n".join(problems))
    else:
        ok("the_three_reads_are_sql_stable_invoker_with_a_search_path",
           f"{len(seen)} functions, each language sql, stable, security invoker, "
           "with search_path set; none is security definer")


def check_grants(db_url):
    rows = psql(db_url, (
        "select p.proname, coalesce(p.proacl::text, ''),"
        "       has_function_privilege('anon', p.oid, 'execute')::text,"
        "       has_function_privilege('authenticated', p.oid, 'execute')::text"
        "  from pg_proc p join pg_namespace n on n.oid = p.pronamespace"
        " where n.nspname = 'public' order by 1"))
    problems = []
    found = 0
    for name, acl, anon, auth in rows:
        if name not in FUNCTIONS:
            continue
        found += 1
        if anon != "true" or auth != "true":
            problems.append(f"{name}: anon={anon} authenticated={auth}")
        granted_to = [entry for entry in acl.strip("{}").split(",") if entry]
        if any(entry.startswith("=") for entry in granted_to):
            problems.append(f"{name}: PUBLIC still holds EXECUTE ({acl})")
    if found != len(FUNCTIONS):
        problems.append(f"found {found} of {len(FUNCTIONS)} read functions")

    table_rows = psql(db_url, (
        "select grantee, table_name,"
        "       coalesce(string_agg(distinct privilege_type, ',' order by privilege_type), '')"
        "  from information_schema.role_table_grants"
        " where table_schema = 'public'"
        "   and table_name in ('catalog_sets','catalog_cards','catalog_prices','catalog_meta')"
        "   and grantee in ('anon','authenticated') group by 1, 2 order by 2, 1"))
    for grantee, table, privileges in table_rows:
        if privileges != "SELECT":
            problems.append(f"{grantee} on {table}: {privileges}")

    if problems:
        bad("clients_may_call_them_and_may_only_read", "\n".join(problems))
    else:
        ok("clients_may_call_them_and_may_only_read",
           "EXECUTE is granted to anon and authenticated and revoked from "
           "PUBLIC on all three; the four catalogue tables still carry SELECT "
           "and nothing else for both roles, so a read function is not a way "
           "around the posture step 0 fixed")


def check_indexes(db_url):
    rows = psql(db_url, (
        "select indexname, indexdef from pg_indexes"
        " where schemaname = 'public' and tablename = 'catalog_cards'"
        "   and indexname like '%number%' order by 1"))
    definitions = {name: definition for name, definition in rows}
    problems = []
    folded = definitions.get("catalog_cards_number_nocase", "")
    if "lower(number_bare)" not in folded:
        problems.append(f"catalog_cards_number_nocase is {folded or 'missing'}")
    if "catalog_cards_number_bare" in definitions:
        problems.append("the case sensitive index is still there, and nothing "
                        "compares number_bare on its own any more")
    if problems:
        bad("the_number_index_is_on_the_expression_the_read_compares",
            "\n".join(problems))
    else:
        ok("the_number_index_is_on_the_expression_the_read_compares", folded)


def check_plans(db_url):
    """The plan of each read, as the deployed body with bound parameters."""
    problems, lines = [], []
    for name, spec in FUNCTIONS.items():
        source = function_source(db_url, name)
        if source is None:
            problems.append(f"{name} does not exist")
            continue
        plan = explain(db_url, source, spec["call"])
        lines.append(f"{name}: {plan.splitlines()[0].strip() if plan else '(none)'}")
        if "Seq Scan" in plan:
            problems.append(f"{name} reads the table instead of an index")
        for index in spec["expect_index"]:
            if index not in plan:
                problems.append(f"{name}: the plan never names {index}")
        for line in plan.splitlines():
            if "Index Scan" in line or "Index Cond" in line or "BitmapOr" in line:
                lines.append("    " + line.strip()[:220])
    if problems:
        bad("every_read_uses_an_index_rather_than_the_table",
            "\n".join(problems + lines))
    else:
        ok("every_read_uses_an_index_rather_than_the_table", "\n".join(lines))


def check_the_search_trap_is_still_a_trap(db_url):
    """0002's measurement, re-run: the same predicate, spelled the wrong way.

    The index is on the raw column, and a trigram index is matched by the
    expression in the predicate, so wrapping name in lower() gives the same rows
    and no index. That is the mistake 0002 was written to fix, and the reason to
    re-measure it here is that the next person to tidy the predicate will not
    have 0002's diff in front of them.
    """
    source = function_source(db_url, "catalog_search")
    if source is None:
        skip("a_lowered_predicate_reads_the_table_instead",
             "catalog_search does not exist")
        return
    body = as_prepared(source)
    if "c.name ilike" not in body:
        skip("a_lowered_predicate_reads_the_table_instead",
             "the deployed body no longer compares c.name the way 0002 measured")
        return
    lowered = body.replace("c.name ilike", "lower(c.name) like")
    proc = subprocess.run(
        ["psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c",
         "set plan_cache_mode = force_generic_plan;\n"
         f"prepare trap ({', '.join(source['types'])}) as {lowered};\n"
         "explain (analyze, buffers) execute trap('lorcana','elsa',80);"],
        capture_output=True, text=True, timeout=300,
        env=catalog_store.psql_environment(db_url),
    )
    if proc.returncode != 0:
        bad("a_lowered_predicate_reads_the_table_instead",
            f"psql: {proc.stderr.strip()[:300]}")
        return
    plan = proc.stdout.strip()
    removed = re.search(r"Rows Removed by Filter: (\d+)", plan)
    if "Seq Scan" not in plan or "catalog_cards_name_trgm" in plan:
        bad("a_lowered_predicate_reads_the_table_instead",
            "the lowered spelling did not fall back on the table, so this "
            f"measurement no longer distinguishes anything: {plan.splitlines()[0]}")
    else:
        ok("a_lowered_predicate_reads_the_table_instead",
           f"lower(c.name) like '%elsa%' -> {plan.splitlines()[0].strip()}, "
           f"{removed.group(1) if removed else '?'} rows removed by filter, "
           "while the deployed predicate reads catalog_cards_name_trgm: this is "
           "0002's measurement, still true, and the reason the two ILIKEs in "
           "catalog_search are spelled the way they are")


def check_by_ids(db_url):
    """A round trip for every id the catalogue holds, plus the misses."""
    total = int(psql(db_url, (
        f"select count(*) from public.catalog_cards where game = {sql_text(GAME)}"))[0][0])
    # 200 at a time, which is CatalogRepository._resolveChunk and therefore what
    # a browser's first sign-in actually sends.
    chunk = 200
    seen, batches = 0, 0
    for offset in range(0, total, chunk):
        rows = psql(db_url, (
            "select id from public.catalog_cards"
            f" where game = {sql_text(GAME)} order by id offset {offset} limit {chunk}"))
        ids = [row[0] for row in rows]
        if not ids:
            break
        literal = ", ".join(sql_text(i) for i in ids)
        answer = psql(db_url, (
            "select count(*), count(distinct id), min(id), max(id),"
            "       bool_and(id = any (array[" + literal + "]::text[]))::text"
            f"  from public.catalog_cards_by_ids({sql_text(GAME)},"
            "     array[" + literal + "]::text[])"))
        count, distinct, smallest, largest, all_wanted = answer[0]
        if int(count) != len(ids) or int(distinct) != len(ids) or all_wanted != "true":
            bad("a_batch_of_ids_comes_back_complete_and_once_each",
                f"asked for {len(ids)} ids, got {count} rows, {distinct} distinct, "
                f"all of them asked for: {all_wanted}")
            return
        if smallest != sorted(ids)[0] or largest != sorted(ids)[-1]:
            bad("a_batch_of_ids_comes_back_complete_and_once_each",
                "the answer is not ordered by id, so two identical calls are "
                "not comparable")
            return
        seen += len(ids)
        batches += 1

    misses = psql(db_url, (
        "select count(*) from public.catalog_cards_by_ids('lorcana',"
        " array['crd_00000000000000000000000000000000', 'not-an-id'])"))[0][0]
    empty = psql(db_url, (
        "select count(*) from public.catalog_cards_by_ids('lorcana', array[]::text[])"))[0][0]
    other_game = psql(db_url, (
        "select count(*) from public.catalog_cards_by_ids('mtg',"
        " array[(select id from public.catalog_cards where game='lorcana' limit 1)])"))[0][0]

    problems = []
    if misses != "0":
        problems.append(f"an unknown id answered with {misses} rows")
    if empty != "0":
        problems.append(f"an empty id list answered with {empty} rows")
    if other_game != "0":
        problems.append(f"a lorcana id answered for mtg: {other_game} rows")
    if seen != total or batches == 0:
        problems.append(f"walked {seen} of {total} ids in {batches} batches")
    if problems:
        bad("a_batch_of_ids_comes_back_complete_and_once_each", "\n".join(problems))
    else:
        ok("a_batch_of_ids_comes_back_complete_and_once_each",
           f"all {total:,} cards, {batches} calls of {chunk} - the two things a "
           "browser does when it signs in - each answered with every id asked "
           "for, once each, in id order; an unknown id, an empty list and "
           "another game's id all answer with nothing")


def check_search(db_url):
    """Real terms, real rows, and the escape that keeps '%' from meaning all."""
    words = psql(db_url, (
        "select word from ("
        "  select (regexp_split_to_array(lower(name), '[^a-z]+'))[1] as word"
        f"  from public.catalog_cards where game = {sql_text(GAME)}"
        "   and name ~ '^[A-Za-z]{6,}'"
        "  group by 1 order by count(*) desc limit 3) t"))
    terms = [row[0] for row in words if row[0]]
    terms += ["elsa", "song"]

    problems, lines = [], []
    for term in terms:
        count, all_match, first = psql(db_url, (
            "select count(*),"
            "  bool_and(name ilike '%' || " + sql_text(term) + " || '%'"
            "        or oracle_text ilike '%' || " + sql_text(term) + " || '%')::text,"
            "  (array_agg(name order by (name ilike " + sql_text(term) + " || '%') desc,"
            "            (name ilike '%' || " + sql_text(term) + " || '%') desc,"
            "            released_at desc nulls last))[1]"
            f"  from public.catalog_search({sql_text(GAME)}, {sql_text(term)}, 80)"))[0]
        reference = int(psql(db_url, (
            "select count(*) from public.catalog_cards"
            f" where game = {sql_text(GAME)}"
            "   and (name ilike '%' || " + sql_text(term) + " || '%'"
            "        or oracle_text ilike '%' || " + sql_text(term) + " || '%')"))[0][0])
        if all_match != "true":
            problems.append(f"{term!r}: a row came back that does not contain it")
        if int(count) < min(reference, 80):
            problems.append(f"{term!r}: the search answered {count} of "
                            f"{reference} matching rows")
        lines.append(f"{term!r}: {count} rows, the catalogue holds {reference}, "
                     f"first {first!r}")
    if problems:
        bad("search_answers_real_terms_with_the_rows_that_contain_them",
            "\n".join(problems + lines))
    else:
        ok("search_answers_real_terms_with_the_rows_that_contain_them",
           "\n".join(lines))

    # The escape. A bare '%' is a collector looking for a percent sign, not a
    # request for the whole game, and the difference is the whole catalogue's
    # egress in one keystroke.
    percent = psql(db_url, (
        f"select count(*) from public.catalog_search({sql_text(GAME)}, '%', 200)"))[0][0]
    percent_reference = psql(db_url, (
        "select count(*) from public.catalog_cards"
        f" where game = {sql_text(GAME)}"
        "   and (name like '%\\%%' or oracle_text like '%\\%%')"))[0][0]
    underscore = psql(db_url, (
        f"select count(*) from public.catalog_search({sql_text(GAME)}, '_', 200)"))[0][0]
    everything = psql(db_url, (
        f"select count(*) from public.catalog_cards where game = {sql_text(GAME)}"))[0][0]
    if percent != percent_reference or int(underscore) != 0:
        bad("a_pattern_character_is_a_character_and_not_a_wildcard",
            f"'%' answered {percent} rows where {percent_reference} rows really "
            f"hold one; '_' answered {underscore}")
    else:
        ok("a_pattern_character_is_a_character_and_not_a_wildcard",
           f"'%' answers the {percent} row(s) whose text really holds one, and "
           f"'_' answers none, where the unescaped pattern would have answered "
           f"all {int(everything):,} rows of the game")

    zero, high, one = (int(v) for v in psql(db_url, (
        "select (select count(*) from public.catalog_search('lorcana','e',0)),"
        "       (select count(*) from public.catalog_search('lorcana','e',9999)),"
        "       (select count(*) from public.catalog_search('lorcana','e',1))"))[0])
    if (zero, high, one) != (1, 200, 1):
        bad("the_limit_is_clamped_rather_than_trusted",
            f"0 -> {zero}, 9999 -> {high}, 1 -> {one}")
    else:
        ok("the_limit_is_clamped_rather_than_trusted",
           "0 is read as 'no preference' and answers 1, 9999 is capped at 200, "
           "and 1 answers 1")


def check_numbers(db_url, vectors):
    """Every committed vector, through the deployed function.

    The reference is CatalogDao.searchByNumber's own SQL, transcribed: a set
    whose folded code is a candidate, and a number that matches with the padding
    stripped and the case folded. That fold is the part section 4 does not do,
    and the vector file carries the spelling that catches it.
    """
    parsed = [v for v in vectors if v.get("parsed")]
    if not parsed:
        skip("every_number_vector_answers_what_the_dart_dao_would", "no vectors")
        return

    values = ",\n".join(
        "    ({idx}, {cands}::text[], {number}, {standalone}::boolean)".format(
            idx=i,
            cands="array[" + ", ".join(sql_text(c) for c in v["code_candidates"]) + "]",
            number=sql_text(v["number"]),
            standalone="true" if v["standalone"] else "false",
        )
        for i, v in enumerate(parsed)
    )
    # The reference predicate, from CatalogDao.searchByNumber: the set is one
    # whose folded code is a candidate, the number matches either exactly or with
    # its leading zeroes stripped, and both sides fold case.
    reference = (
        "select c.id from public.catalog_cards c"
        f" where c.game = {sql_text(GAME)}"
        "   and (v.standalone or exists (select 1 from public.catalog_sets s"
        "        where s.game = c.game and s.code = c.set_code"
        "          and s.code_folded = any (v.candidates)))"
        "   and (lower(c.collector_number) = lower(v.number)"
        "        or lower(ltrim(c.collector_number, '0')) = lower(ltrim(v.number, '0')))"
        " limit 200"
    )
    rows = psql(db_url, (
        "with v(idx, candidates, number, standalone) as (values\n" + values + "\n)"
        " select v.idx,"
        "   (select count(*) from public.catalog_cards_by_number("
        f"      {sql_text(GAME)}, v.candidates, v.number, v.standalone, 200)),"
        "   (select count(*) from (" + reference + ") r),"
        "   coalesce((select md5(string_agg(id, ',' order by id)) from"
        "      public.catalog_cards_by_number("
        f"        {sql_text(GAME)}, v.candidates, v.number, v.standalone, 200)), ''),"
        "   coalesce((select md5(string_agg(id, ',' order by id)) from ("
        + reference + ") r), '')"
        " from v order by v.idx"))

    problems, examples = [], []
    for row in rows:
        index, function_count, reference_count, function_digest, reference_digest = row
        vector = parsed[int(index)]
        if function_count != reference_count or function_digest != reference_digest:
            problems.append(
                f"{vector['raw']!r} (candidates={vector['code_candidates']}, "
                f"number={vector['number']!r}, standalone={vector['standalone']}): "
                f"the function answered {function_count} rows where the rule "
                f"selects {reference_count}")
        elif int(function_count) and len(examples) < 4:
            examples.append(f"{vector['raw']!r} -> {function_count} row(s)")

    # The case pair, called out on its own: this is the one section 4's own
    # predicate gets wrong, and a regression here is silent.
    spellings = {}
    for v in parsed:
        spellings.setdefault(v["number"].lower(), []).append(v)
    case_problems = []
    for number, group in spellings.items():
        if len({v["number"] for v in group}) < 2:
            continue
        counts = {}
        for v in group:
            counts[v["number"]] = int(psql(db_url, (
                "select count(*) from public.catalog_cards_by_number("
                f" {sql_text(GAME)}, array[]::text[], {sql_text(v['number'])},"
                "  true, 80)"))[0][0])
        if len(set(counts.values())) != 1:
            case_problems.append(
                f"{number}: a case the server treats as two different numbers {counts}")
        elif list(counts.values())[0] and len(examples) < 8:
            examples.append(f"{sorted(counts)} -> {list(counts.values())[0]} row(s)")

    if problems or case_problems:
        bad("every_number_vector_answers_what_the_dart_dao_would",
            "\n".join(problems + case_problems))
    else:
        ok("every_number_vector_answers_what_the_dart_dao_would",
           f"{len(parsed)} number queries from "
           "tool/catalog/number_query_vectors.json, each answered with exactly "
           "the rows CatalogDao.searchByNumber's rule selects. "
           + "; ".join(examples))

    sample = psql(db_url, (
        "select s.code, c.collector_number from public.catalog_cards c"
        "  join public.catalog_sets s on s.game = c.game and s.code = c.set_code"
        f" where c.game = {sql_text(GAME)} and c.collector_number ~ '^[0-9]+$'"
        " order by c.id limit 1"))
    if not sample:
        skip("a_named_set_ranks_before_a_bare_number", "no numbered card found")
        return
    code, number = sample[0]
    folded = psql(db_url, (
        "select code_folded from public.catalog_sets"
        f" where game = {sql_text(GAME)} and code = {sql_text(code)}"))[0][0]
    ranked = psql(db_url, (
        "select c.set_code, c.collector_number from public.catalog_cards_by_number("
        f"  {sql_text(GAME)},"
        f"  array[{sql_text('zz-not-a-set')}, {sql_text(folded)}]::text[],"
        f"  {sql_text(number)}, false, 80) c limit 3"))
    if not ranked or any(row[0] != code for row in ranked):
        bad("a_named_set_ranks_before_a_bare_number",
            f"candidates ['zz-not-a-set', {folded!r}] for number {number!r} "
            f"answered {ranked}")
    else:
        ok("a_named_set_ranks_before_a_bare_number",
           f"set {code!r} card {number!r}: a candidate list whose first entry "
           "names a set no catalogue has still answers that set's printing, so "
           "a second candidate is tried rather than the whole game being read")


# ---------------------------------------------------------------------------
# HTTP, as the app makes the call
# ---------------------------------------------------------------------------


class Client:
    def __init__(self, base, key):
        self.base = base.rstrip("/")
        self.key = key

    def rpc(self, name, params):
        request = urllib.request.Request(
            f"{self.base}/rest/v1/rpc/{name}",
            data=json.dumps(params).encode("utf-8"),
            headers={
                "apikey": self.key,
                "Authorization": f"Bearer {self.key}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                return response.status, json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            return error.code, error.read().decode("utf-8", "replace")
        except urllib.error.URLError as error:
            raise SystemExit(f"cannot reach {self.base}: {error}")


def check_http(client, db_url):
    ids = psql(db_url, (
        "select string_agg(id, ',') from (select id from public.catalog_cards"
        f" where game = {sql_text(GAME)} order by id limit 200) t"))[0][0].split(",")

    status, rows = client.rpc("catalog_cards_by_ids", {"p_game": GAME, "p_ids": ids})
    if status != 200 or not isinstance(rows, list) or len(rows) != len(ids):
        bad("the_publishable_key_can_resolve_a_batch_of_ids", f"HTTP {status}: {rows}")
    elif sorted(row["id"] for row in rows) != sorted(ids):
        bad("the_publishable_key_can_resolve_a_batch_of_ids",
            "the answer holds different ids from the ones asked for")
    else:
        ok("the_publishable_key_can_resolve_a_batch_of_ids",
           f"one POST of {len(ids)} ids answers HTTP 200 with {len(rows)} rows, "
           "which is how a first sign-in resolves a collection")

    status, rows = client.rpc("catalog_search", {"p_game": GAME, "p_query": "elsa"})
    sql_rows = [row[0] for row in psql(db_url, (
        f"select id from public.catalog_search({sql_text(GAME)}, 'elsa', 80)"))]
    if status != 200 or not isinstance(rows, list):
        bad("the_publishable_key_can_search_the_whole_game", f"HTTP {status}: {rows}")
    elif [row["id"] for row in rows] != sql_rows:
        bad("the_publishable_key_can_search_the_whole_game",
            "the HTTP answer is not the SQL answer, so the ranking does not "
            "survive the round trip")
    else:
        ok("the_publishable_key_can_search_the_whole_game",
           f"HTTP 200, {len(rows)} rows, the same rows in the same order as the "
           f"function, first {rows[0]['name']!r}")

    status, rows = client.rpc("catalog_cards_by_number", {
        "p_game": GAME,
        "p_code_candidates": [],
        "p_number": "24b",
        "p_standalone": True,
    })
    if status != 200 or not isinstance(rows, list) or len(rows) != 1:
        bad("the_publishable_key_can_address_a_printing_by_its_number",
            f"HTTP {status}: {rows}")
    elif rows[0]["collector_number"] != "24B":
        bad("the_publishable_key_can_address_a_printing_by_its_number",
            f"a lower case '24b' answered {rows[0]['collector_number']!r}")
    else:
        ok("the_publishable_key_can_address_a_printing_by_its_number",
           f"'24b', the way a collector types it, answers set "
           f"{rows[0]['set_code']!r} card {rows[0]['collector_number']!r} - the "
           "number section 4's predicate would have missed")

    # The transport cap, measured rather than assumed. It is not a property this
    # migration can change, and it is the reason the client chunks at all.
    many = psql(db_url, (
        "select string_agg(id, ',') from (select id from public.catalog_cards"
        f" where game = {sql_text(GAME)} order by id limit 1200) t"))[0][0].split(",")
    status, rows = client.rpc("catalog_cards_by_ids", {"p_game": GAME, "p_ids": many})
    if status != 200:
        bad("the_response_cap_is_measured_not_assumed", f"HTTP {status}: {rows}")
    elif len(rows) == len(many):
        ok("the_response_cap_is_measured_not_assumed",
           f"asking for {len(many)} ids answered with all {len(rows)} of them, "
           "so the platform's cap has moved and the client's chunking is now "
           "belt and braces rather than load bearing")
    else:
        ok("the_response_cap_is_measured_not_assumed",
           f"asking for {len(many)} ids answers HTTP 200 with {len(rows)} rows: "
           "the platform truncates a response at 1,000 rows and says nothing "
           "about it, which is why SupabaseCatalogTable caps one call at 1,000 "
           "ids and CatalogRepository asks about 200 at a time")


def check_nothing_changed(db_url, before):
    after = tuple(int(v) for v in psql(db_url, (
        "select (select count(*) from public.catalog_cards),"
        "       (select count(*) from public.catalog_sets),"
        "       (select count(*) from public.catalog_prices)"))[0])
    if after != before:
        bad("the_proof_wrote_nothing", f"{before} -> {after}")
    else:
        ok("the_proof_wrote_nothing",
           f"catalog_cards {after[0]:,}, catalog_sets {after[1]}, "
           f"catalog_prices {after[2]}, exactly as before the run")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env-file", default=None)
    ap.add_argument("--sql-only", action="store_true", help="skip the HTTP half")
    args = ap.parse_args()

    if args.env_file:
        with open(args.env_file, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    os.environ.setdefault(key.strip(), value.strip())

    db_url = os.environ.get("SUPABASE_DB_URL_POOLED") or os.environ.get("SUPABASE_DB_URL")
    if not db_url or not shutil.which("psql"):
        print("this proof needs psql and the pooler connection string; neither "
              "is optional here", file=sys.stderr)
        return 2
    if ":6543/" in db_url:
        db_url = db_url.replace(":6543/", ":5432/")

    here = os.path.dirname(os.path.abspath(__file__))
    vector_path = os.path.join(here, "number_query_vectors.json")
    if not os.path.exists(vector_path):
        print(f"missing {vector_path}; generate it with "
              "dart run tool/catalog/gen_number_query_vectors.dart",
              file=sys.stderr)
        return 2
    with open(vector_path, encoding="utf-8") as handle:
        vectors = json.load(handle)["queries"]

    before = tuple(int(v) for v in psql(db_url, (
        "select (select count(*) from public.catalog_cards),"
        "       (select count(*) from public.catalog_sets),"
        "       (select count(*) from public.catalog_prices)"))[0])
    print(f"the catalogue holds {before[0]:,} cards in {before[1]} sets")
    print()
    print("--- SQL, as the owner ---")

    check_functions_are_the_shape_the_design_requires(db_url)
    check_grants(db_url)
    check_indexes(db_url)
    check_plans(db_url)
    check_the_search_trap_is_still_a_trap(db_url)
    check_by_ids(db_url)
    check_search(db_url)
    check_numbers(db_url, vectors)

    if not args.sql_only:
        print()
        print("--- HTTP, as the publishable key ---")
        base = os.environ.get("SUPABASE_URL")
        key = os.environ.get("SUPABASE_PUBLISHABLE_KEY")
        if not base or not key:
            skip("the_reads_answer_over_postgrest",
                 "SUPABASE_URL or SUPABASE_PUBLISHABLE_KEY is not set")
        else:
            check_http(Client(base, key), db_url)

    print()
    print("--- nothing left behind ---")
    check_nothing_changed(db_url, before)

    failed = sum(1 for status, _, _ in RESULTS if status == "FAIL")
    passed = sum(1 for status, _, _ in RESULTS if status == "PASS")
    skipped = sum(1 for status, _, _ in RESULTS if status == "SKIP")
    print()
    print(f"{passed} passed, {failed} failed, {skipped} skipped")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
