#!/usr/bin/env python3
"""Prove that a deck has a shape on the account before anything writes to it.

The claim this file tests is not that eight columns and a table exist. It is that
the account can hold a deck and its contents at all: that the identity the client
mints has somewhere to live and something to be unique against, that a line of a
deck belongs to that deck and to nobody else's, that a client is allowed to write
its own rows and refused anybody else's, and that none of it disturbed the tables
it was added to - one of which holds a real collector's seven holdings.

Three kinds of check, and none of them implies another:

  * against the live schema, as the owner, reading pg_catalog and
    information_schema. This is where "eight columns, one table and nothing
    else" is a measurement rather than a promise: the columns public.decks
    already had, its constraint, its policy, its grants, its index and its rows
    are compared with the fingerprint taken from this project before the
    migration was written, and public.collection_entries is fingerprinted the
    same way before and after, because a migration that touches nothing has to
    be shown to touch nothing.

  * against the live table, as a session that is not its owner, inside a
    transaction that is rolled back. A policy cannot be tested anywhere but the
    database that has one - a fake account table has no row level security and
    SQLite has neither RLS nor a uuid - so the probe writes a deck for two real
    accounts and then, as the authenticated role holding one account's claims,
    writes its own line and is refused the other account's.

  * against the two migration files, read as text. The down file is not run, and
    that is deliberate: it drops a deck's entire contents by design, and running
    it to see whether it works would destroy exactly what it warns about. What is
    checked instead is that every object the up file creates has a matching
    statement in the down file, and that the down file's statements name no
    table the up file did not create. This one is a reading and not a
    measurement, and it is reported as one.

Credentials come from the environment, or from a KEY=VALUE file named with
--env-file. They are never printed, and nothing in this file holds a secret.

  SUPABASE_DB_URL_POOLED   required - the session pooler, port 5432

Usage:
  set -a; . /home/zixen/arcanum/supabase.env; set +a
  python3 tool/account/prove_deck_sync_shape.py

Exit status is 0 only if nothing failed.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys

# psql is told its connection through the environment rather than through its
# argv, so the password is not in a process listing. catalog_store owns that
# split and is deployed alongside the importer, so it is imported here rather
# than copied: a second copy of a rule about credentials is a second thing to
# get wrong.
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import catalog_store  # noqa: E402

UP_FILE = "0003_deck_sync.sql"
DOWN_FILE = "0003_deck_sync_down.sql"

# public.decks as it stood on 2026-09-21, read from the live project before the
# migration was written. Asserting these afterwards is how "eight columns were
# added" becomes a check: a migration that also, say, rewrote the policy or
# dropped an index would pass a check that only looked for the new columns.
#
# Two fingerprints are deliberately taken over a *subset* of what the table
# holds, because the rest is the thing being added and cannot be part of a
# reading that has to match at both ends:
#
#   * decks_cons_md5 is taken over the constraints that were already there -
#     decks_pkey and decks_user_id_fkey - and not over the unique constraint this
#     migration adds.
#   * decks_idx_md5 is taken over decks_pkey only, for the same reason: the
#     unique constraint brings an index of its own.
#
# decks_user_id_default is not in this dict either, but for the opposite reason:
# it is the one reading the migration is *supposed* to change, from absent to
# auth.uid(), and it is asserted on its own below.
BEFORE_DECKS = {
    "decks_row_md5": "empty",
    "decks_n_rows": "0",
    "decks_cons_md5": "71f700c2ade9228bab3518a0898a2bbc",
    "decks_pol_md5": "f21f4ec1cb90be24ace4ea77f4681ca2",
    "decks_idx_md5": "909139763ef419d76b766ea6b18baffa",
    "decks_grant_md5": "a77de29eee559c34252bb8df508e30ad",
    "decks_acl_md5": "07a1191517ecfeb98e89a2258317d35a",
    "decks_rls": "true force=false",
}

# public.collection_entries is not mentioned by the migration at all, so every
# reading of it has to be identical before and after. It held seven holdings,
# sixteen columns and one policy on 2026-09-21.
BEFORE_ENTRIES = {
    "entries_row_md5": "c033dfe24e260d4745cd18eeacc2d75e",
    "entries_n_rows": "7",
    "entries_n_cols": "16",
    "entries_cons_md5": "284bcd1a43d57a11c87fbca9ad33bdc0",
    "entries_pol_md5": "f46c5cf8da5eeead8007200ee17bc04b",
    "entries_idx_md5": "93cc4a3c404f1628eb1c84805de50006",
    "entries_grant_md5": "a77de29eee559c34252bb8df508e30ad",
    "entries_acl_md5": "07a1191517ecfeb98e89a2258317d35a",
    "entries_rls": "true force=false",
}

# The five columns decks already had, in the order they were in. The fingerprint
# above is taken over exactly these, which is what makes it comparable at both
# ends of the migration.
COLUMNS_5 = "id,user_id,game,name,created_at"

# The sixteen collection_entries columns, likewise.
ENTRIES_COLUMNS = (
    "id,user_id,game,card_id,finish,condition,language,quantity,purchase_price,"
    "purchase_date,binder,notes,for_trade,created_at,updated_at,deleted_at"
)

# data_type;is_nullable;column_default, as information_schema renders them. Every
# added column is read back rather than assumed: the default on sync_id is the
# one the design argues about, and "not null, no default" is a claim about a
# column that a check for the column's name would not test.
ADDED_DECK_COLUMNS = {
    "sync_id": "uuid;NO;ABSENT",
    "format_id": "text;NO;''::text",
    "notes": "text;YES;ABSENT",
    "updated_at": "timestamp with time zone;NO;now()",
    "deleted_at": "timestamp with time zone;YES;ABSENT",
    "name_at": "timestamp with time zone;YES;ABSENT",
    "format_at": "timestamp with time zone;YES;ABSENT",
    "notes_at": "timestamp with time zone;YES;ABSENT",
}

DECK_CARDS_COLUMNS = {
    "user_id": "uuid;NO;auth.uid()",
    "game": "text;NO;ABSENT",
    "deck_sync_id": "uuid;NO;ABSENT",
    "card_id": "text;NO;ABSENT",
    "board": "text;NO;'main'::text",
    "quantity": "integer;NO;1",
    "sort": "integer;NO;0",
    "category": "text;NO;''::text",
    "updated_at": "timestamp with time zone;NO;now()",
    "deleted_at": "timestamp with time zone;YES;ABSENT",
}

# The client's conflict target: DeckSync's upsert target in the design's step 2,
# spelled the same way the collection spells its own. The foreign key from
# deck_cards points at it, so it is read back rather than assumed.
DECK_CONFLICT_TARGET = "UNIQUE (user_id, sync_id)"
DECK_CARDS_KEY = "PRIMARY KEY (user_id, deck_sync_id, card_id, board)"
DECK_CARDS_FK = ("FOREIGN KEY (user_id, deck_sync_id) REFERENCES decks(user_id, "
                 "sync_id) ON DELETE CASCADE")
DECK_CARDS_INDEX = ("CREATE INDEX deck_cards_user_game ON public.deck_cards "
                    "USING btree (user_id, game)")
DECK_CARDS_POLICY = ("a collector sees their own deck cards;ALL;public;"
                     "(auth.uid() = user_id);(auth.uid() = user_id)")

# The four privileges a client needs, and the four that a Supabase project hands
# a new table by default and this migration takes back. MAINTAIN is on the
# second list because the server is PostgreSQL 17 and the raw ACL holds it,
# even though information_schema does not enumerate it.
CLIENT_ROLES = ("anon", "authenticated", "service_role")
OWNER_ROLE = "postgres"
FOUR = {"DELETE", "INSERT", "SELECT", "UPDATE"}
FORBIDDEN = {"TRUNCATE", "REFERENCES", "TRIGGER", "MAINTAIN"}

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


def psql(db_url, sql):
    """One script, tab-separated, no header. Returns a list of rows of fields.

    The whole script is one process, which matters for the probes below: their
    statements have to share a transaction, and that transaction has to be
    rolled back whether or not an assertion in the middle failed.

    The URL is split into the variables libpq reads from the environment and
    never passed as an argument, so the password is not visible to ps while a
    statement runs.
    """
    proc = subprocess.run(
        ["psql", "-X", "-q", "-A", "-t", "-F", "|",
         "-v", "ON_ERROR_STOP=1", "-f", "-"],
        input=sql, capture_output=True, text=True, timeout=120,
        env=catalog_store.psql_environment(db_url),
    )
    if proc.returncode != 0:
        raise RuntimeError(f"psql: {proc.stderr.strip()[:600]}")
    return [line.split("|") for line in proc.stdout.splitlines() if line != ""]


def psql_allow_failure(db_url, sql):
    """One script that is expected to be refused. Returns (status, stderr)."""
    proc = subprocess.run(
        ["psql", "-X", "-q", "-A", "-t", "-F", "|",
         "-v", "ON_ERROR_STOP=1", "-f", "-"],
        input=sql, capture_output=True, text=True, timeout=120,
        env=catalog_store.psql_environment(db_url),
    )
    return proc.returncode, proc.stderr


def values(rows):
    """Every NAME=value field of every row, flattened.

    psql renders each select as its own set of rows and this file asks for
    one-column answers, so a reader that took row[0] only would silently read
    nothing and report it as a missing column.
    """
    out = {}
    for row in rows:
        for field in row:
            name, sep, value = field.partition("=")
            if sep:
                out[name] = value
    return out


def compare(got, want, name, headline):
    """Every reading in want must equal the reading now. Reports all misses."""
    failures = [
        f"{key}: {got.get(key, 'missing')} != {value}"
        for key, value in want.items()
        if got.get(key) != value
    ]
    if failures:
        bad(name, "\n".join(failures))
    else:
        ok(name, headline)


def check_columns(got, prefix, expected, name, headline):
    failures = []
    for column, want in sorted(expected.items()):
        have = got.get(prefix + column, "missing")
        if have != want:
            failures.append(f"{column}: {have} != {want}")
    if failures:
        bad(name, "\n".join(failures))
    else:
        ok(name, f"{headline} ({len(expected)} columns, each read back)")


def schema_sql():
    return f"""
      select 'decks_row_md5=' || coalesce(md5(string_agg(row_to_json(t)::text, '~' order by id)), 'empty')
        from (select {COLUMNS_5} from public.decks) t;
      select 'decks_n_rows=' || count(*) from public.decks;
      select 'decks_n_cols=' || count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'decks';
      select 'decks_cons_md5=' || coalesce(md5(string_agg(conname || ':' || pg_get_constraintdef(o.oid), ',' order by conname)), 'none')
        from pg_constraint o where conrelid = 'public.decks'::regclass
         and conname in ('decks_pkey', 'decks_user_id_fkey');
      select 'decks_pol_md5=' || coalesce(md5(string_agg(policyname || '|' || cmd || '|' ||
             array_to_string(roles, ',') || '|' || coalesce(qual, '-') || '|' ||
             coalesce(with_check, '-'), ',' order by policyname)), 'none')
        from pg_policies where schemaname = 'public' and tablename = 'decks';
      select 'decks_idx_md5=' || coalesce(md5(string_agg(indexdef, ',' order by indexname)), 'none')
        from pg_indexes where schemaname = 'public' and tablename = 'decks'
         and indexname = 'decks_pkey';
      select 'decks_grant_md5=' || md5(string_agg(grantee || '|' || privs, ',' order by grantee))
        from (select grantee, string_agg(distinct privilege_type, ',' order by privilege_type) as privs
                from information_schema.role_table_grants
               where table_schema = 'public' and table_name = 'decks'
               group by grantee) g;
      select 'decks_acl_md5=' || coalesce(md5(string_agg(r.rolname || '|' || priv, ',' order by r.rolname)), 'none')
        from (select a.grantee, string_agg(distinct a.privilege_type, ',' order by a.privilege_type) as priv
                from pg_class c cross join lateral aclexplode(c.relacl) a
               where c.oid = 'public.decks'::regclass group by a.grantee) g
        join pg_roles r on r.oid = g.grantee;
      select 'decks_rls=' || relrowsecurity::text || ' force=' || relforcerowsecurity::text
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = 'decks';
      select 'decks_user_id_default=' || coalesce((select column_default
                from information_schema.columns
               where table_schema = 'public' and table_name = 'decks'
                 and column_name = 'user_id'), 'ABSENT');
      select 'decks_user_sync=' || coalesce((select pg_get_constraintdef(oid)
                from pg_constraint
               where conrelid = 'public.decks'::regclass
                 and conname = 'decks_user_sync'), 'ABSENT');
      select 'col_' || column_name || '=' || data_type || ';' || is_nullable || ';' ||
             coalesce(column_default, 'ABSENT')
        from information_schema.columns
       where table_schema = 'public' and table_name = 'decks'
         and column_name in ('sync_id', 'format_id', 'notes', 'updated_at',
                             'deleted_at', 'name_at', 'format_at', 'notes_at');

      select 'entries_row_md5=' || coalesce(md5(string_agg(row_to_json(t)::text, '~' order by id)), 'empty')
        from (select {ENTRIES_COLUMNS} from public.collection_entries) t;
      select 'entries_n_rows=' || count(*) from public.collection_entries;
      select 'entries_n_cols=' || count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'collection_entries';
      select 'entries_cons_md5=' || coalesce(md5(string_agg(conname || ':' || pg_get_constraintdef(o.oid), ',' order by conname)), 'none')
        from pg_constraint o where conrelid = 'public.collection_entries'::regclass;
      select 'entries_pol_md5=' || coalesce(md5(string_agg(policyname || '|' || cmd || '|' ||
             array_to_string(roles, ',') || '|' || coalesce(qual, '-') || '|' ||
             coalesce(with_check, '-'), ',' order by policyname)), 'none')
        from pg_policies where schemaname = 'public' and tablename = 'collection_entries';
      select 'entries_idx_md5=' || coalesce(md5(string_agg(indexdef, ',' order by indexname)), 'none')
        from pg_indexes where schemaname = 'public' and tablename = 'collection_entries';
      select 'entries_grant_md5=' || md5(string_agg(grantee || '|' || privs, ',' order by grantee))
        from (select grantee, string_agg(distinct privilege_type, ',' order by privilege_type) as privs
                from information_schema.role_table_grants
               where table_schema = 'public' and table_name = 'collection_entries'
               group by grantee) g;
      select 'entries_acl_md5=' || coalesce(md5(string_agg(r.rolname || '|' || priv, ',' order by r.rolname)), 'none')
        from (select a.grantee, string_agg(distinct a.privilege_type, ',' order by a.privilege_type) as priv
                from pg_class c cross join lateral aclexplode(c.relacl) a
               where c.oid = 'public.collection_entries'::regclass group by a.grantee) g
        join pg_roles r on r.oid = g.grantee;
      select 'entries_rls=' || relrowsecurity::text || ' force=' || relforcerowsecurity::text
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = 'collection_entries';

      select 'deck_cards_exists=' || count(*) from pg_tables
       where schemaname = 'public' and tablename = 'deck_cards';
      select 'dc_n_cols=' || count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'deck_cards';
      select 'dc_col_' || column_name || '=' || data_type || ';' || is_nullable || ';' ||
             coalesce(column_default, 'ABSENT')
        from information_schema.columns
       where table_schema = 'public' and table_name = 'deck_cards';
      select 'dc_pk=' || coalesce((select pg_get_constraintdef(oid) from pg_constraint
                where conrelid = 'public.deck_cards'::regclass and contype = 'p'), 'ABSENT');
      select 'dc_fk=' || coalesce((select pg_get_constraintdef(oid) from pg_constraint
                where conrelid = 'public.deck_cards'::regclass and contype = 'f'), 'ABSENT');
      select 'dc_idx=' || coalesce((select indexdef from pg_indexes
                where schemaname = 'public' and tablename = 'deck_cards'
                  and indexname = 'deck_cards_user_game'), 'ABSENT');
      select 'dc_idx_all=' || coalesce(string_agg(indexdef, ',' order by indexname), 'none')
        from pg_indexes where schemaname = 'public' and tablename = 'deck_cards';
      select 'dc_policy=' || coalesce(string_agg(policyname || ';' || cmd || ';' ||
             array_to_string(roles, ',') || ';' || coalesce(qual, '-') || ';' ||
             coalesce(with_check, '-'), ',' order by policyname), 'none')
        from pg_policies where schemaname = 'public' and tablename = 'deck_cards';
      select 'dc_rls=' || relrowsecurity::text || ' force=' || relforcerowsecurity::text
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = 'deck_cards';
      select 'dc_grant_' || grantee || '=' || string_agg(distinct privilege_type, ',' order by privilege_type)
        from information_schema.role_table_grants
       where table_schema = 'public' and table_name = 'deck_cards'
       group by grantee;
      select 'dc_acl_' || r.rolname || '=' || string_agg(distinct a.privilege_type, ',' order by a.privilege_type)
        from pg_class c cross join lateral aclexplode(c.relacl) a
        join pg_roles r on r.oid = a.grantee
       where c.oid = 'public.deck_cards'::regclass group by r.rolname;
      select 'dc_n_rows=' || count(*) from public.deck_cards;

      select 'realtime_tables=' || coalesce(string_agg(tablename, ',' order by tablename), 'none')
        from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public';
    """


def check_schema(db_url):
    got = values(psql(db_url, schema_sql()))

    compare(got, BEFORE_DECKS, "sql_decks_is_what_it_was",
            "the five columns it had, its rows, its constraint, its policy, its "
            "index and its grants - read both through information_schema and "
            "through the raw ACL, which is where a privilege "
            "information_schema does not list would show up - are exactly what "
            "they were before the migration")

    compare(got, BEFORE_ENTRIES, "sql_collection_entries_untouched",
            "the table this migration is not about is byte-for-byte what it "
            "was: seven holdings, sixteen columns, its constraint, its policy, "
            "its index and its grants all unchanged")

    if got.get("decks_n_cols") == "13":
        ok("sql_decks_gained_exactly_eight_columns",
           "five columns became thirteen, and the eight new ones are the "
           "migration's whole column change")
    else:
        bad("sql_decks_gained_exactly_eight_columns",
            f"{got.get('decks_n_cols', 'missing')} columns, expected 13")

    if got.get("decks_user_id_default") == "auth.uid()":
        ok("sql_decks_user_id_now_defaults_to_the_owner",
           "decks.user_id had NO default - measured absent before this "
           "migration, not assumed - and now carries auth.uid(), the default "
           "collection_entries.user_id already had. It is what lets a deck's "
           "push omit the owner the way the collection's push does, and the "
           "policy's WITH CHECK still stops a client lying about who owns the row")
    else:
        bad("sql_decks_user_id_default_now_defaults_to_the_owner",
            f"got {got.get('decks_user_id_default', 'missing')}")

    check_columns(got, "col_", ADDED_DECK_COLUMNS, "sql_decks_new_columns",
                  "every column the migration adds to public.decks")

    if got.get("col_sync_id") == "uuid;NO;ABSENT":
        ok("sql_the_client_identity_has_no_default",
           "sync_id is a not-null uuid with no default: a payload that forgot "
           "it is a refused request, rather than a fresh deck under a fresh id "
           "on every retry")
    else:
        bad("sql_the_client_identity_has_no_default", got.get("col_sync_id", "missing"))

    target = got.get("decks_user_sync", "")
    if target.replace(" ", "") == DECK_CONFLICT_TARGET.replace(" ", ""):
        ok("sql_the_conflict_target_exists",
           f"unique (user_id, sync_id) is what a push upserts against, and what "
           "makes a push safe to repeat after a connection drops")
    else:
        bad("sql_the_conflict_target_exists", f"got {target}")

    if got.get("deck_cards_exists") == "1":
        ok("sql_deck_cards_exists", "the contents table is there")
    else:
        bad("sql_deck_cards_exists", "no public.deck_cards")

    check_columns(got, "dc_col_", DECK_CARDS_COLUMNS, "sql_deck_cards_columns",
                  "every column of public.deck_cards")

    if got.get("dc_n_cols") == str(len(DECK_CARDS_COLUMNS)):
        ok("sql_deck_cards_has_exactly_those_columns",
           f"{len(DECK_CARDS_COLUMNS)} columns and no more - no created_at, "
           "because a server row is a local row and the local table has none")
    else:
        bad("sql_deck_cards_has_exactly_those_columns",
            f"{got.get('dc_n_cols', 'missing')} columns, expected {len(DECK_CARDS_COLUMNS)}")

    pk = got.get("dc_pk", "")
    if pk.replace(" ", "") == DECK_CARDS_KEY.replace(" ", ""):
        ok("sql_deck_cards_key_is_the_conflict_target",
           "(user_id, deck_sync_id, card_id, board): the same shape as the "
           "collection's unique index, and the reason a push is an upsert. sort "
           "and category are on the row and not in the key, because two devices "
           "can disagree about a sort number without there being two lines")
    else:
        bad("sql_deck_cards_key_is_the_conflict_target", f"got {pk}")

    fk = got.get("dc_fk", "")
    if fk.replace(" ", "") == DECK_CARDS_FK.replace(" ", ""):
        ok("sql_a_line_is_tied_to_its_deck",
           "the line points at (user_id, sync_id) of public.decks and cascades: "
           "a line cannot name a deck that does not exist, and a line cannot "
           "borrow another account's deck_sync_id without changing its user_id "
           "with it")
    else:
        bad("sql_a_line_is_tied_to_its_deck", f"got {fk}")

    idx = got.get("dc_idx", "")
    if idx.replace(" ", "") == DECK_CARDS_INDEX.replace(" ", ""):
        ok("sql_one_pull_per_game_is_indexed",
           "deck_cards_user_game covers 'every line of this game', which is the "
           "shape the pull takes - a deck list is a grouped join over these rows "
           "and the counts would be wrong for a device that pulled only decks")
    else:
        bad("sql_one_pull_per_game_is_indexed", f"got {idx}")

    if got.get("dc_rls") == "true force=false":
        ok("sql_deck_cards_has_row_level_security",
           "on and not forced, the same posture as the two tables beside it")
    else:
        bad("sql_deck_cards_has_row_level_security", got.get("dc_rls", "missing"))

    policy = got.get("dc_policy", "")
    if policy.replace(" ", "") == DECK_CARDS_POLICY.replace(" ", ""):
        ok("sql_the_policy_is_the_owner_only_shape",
           "one policy, for every command, to public, comparing auth.uid() with "
           "a column on this table - the shape the two account tables already "
           "have, so the filter a client asks with and the rows it is allowed to "
           "see agree by construction")
    else:
        bad("sql_the_policy_is_the_owner_only_shape", f"got {policy}")

    check_grants(got)

    # This reading has changed since 0003 was written, and the change is the
    # design's own step 4. When this proof was written the publication held
    # collection_entries and nothing else, and that was the assertion: creating a
    # table and streaming it are two separate steps, and 0003 was the first one
    # for public.deck_cards. 0004_realtime_decks.sql is the second, and it put
    # both deck tables in. So the check reads the state the two steps together
    # leave - the three account tables and nothing beside them - rather than the
    # state 0003 left on its own, which no longer exists on any database this
    # has been applied to. prove_deck_realtime.py is the proof of the step that
    # changed it; this one only has to stop claiming the opposite.
    if got.get("realtime_tables") == "collection_entries,deck_cards,decks":
        ok("sql_the_publication_is_what_the_steps_left",
           "the publication holds the three account tables and nothing else: "
           "collection_entries, which 0002 streamed, and decks and deck_cards, "
           "which 0004 streamed. That is not 0003's doing - its own statements "
           "mention no publication at all, which the check below reads out of "
           "the file - and the deck tables being streamed is what the deck "
           "listener needs")
    else:
        bad("sql_the_publication_is_what_the_steps_left",
            f"publication holds {got.get('realtime_tables', 'missing')}")

    if got.get("dc_n_rows") == "0":
        ok("sql_deck_cards_is_empty",
           "the shape is shipped empty, as step 0 says: it delivers no user "
           "value and nothing can be verified until it is fixed")
    else:
        bad("sql_deck_cards_is_empty", f"{got.get('dc_n_rows')} rows")


def check_grants(got):
    """The four privileges and no others.

    Read twice on purpose. information_schema enumerates the SQL standard's
    privileges and does not list MAINTAIN; the raw ACL is the complete answer.
    A check that read only information_schema would report "no TRUNCATE" about a
    table that has it.
    """
    failures = []
    for role in CLIENT_ROLES:
        acl = got.get(f"dc_acl_{role}", "missing")
        if acl == "missing":
            failures.append(f"{role}: no ACL entry at all")
            continue
        have = set(acl.split(","))
        if have != FOUR:
            failures.append(f"{role}: {acl} != {','.join(sorted(FOUR))}")
    if failures:
        bad("sql_grants_are_exactly_the_four_a_client_needs", "\n".join(failures))
    else:
        ok("sql_grants_are_exactly_the_four_a_client_needs",
           "anon, authenticated and service_role each hold SELECT, INSERT, "
           "UPDATE and DELETE and nothing else. Supabase's default privileges "
           "for this schema hand a new table all eight, and the raw ACL records "
           "that the tables beside it still do - this migration narrows the "
           "default only where it creates the table")

    forbidden = []
    for key, acl in got.items():
        if not key.startswith("dc_acl_"):
            continue
        role = key[len("dc_acl_"):]
        have = set(acl.split(","))
        held = sorted(have & FORBIDDEN)
        if held and role != OWNER_ROLE:
            forbidden.append(f"{role} holds {','.join(held)}")
    if forbidden:
        bad("sql_no_role_can_truncate_the_table", "\n".join(forbidden))
    else:
        ok("sql_no_role_can_truncate_the_table",
           "neither TRUNCATE nor REFERENCES nor TRIGGER nor MAINTAIN is held by "
           "any role but the owner. Row level security does not apply to "
           "TRUNCATE, so a grant of it is not covered by the policy that "
           "protects the rows - it is a way to empty the table that never asks "
           "whose rows they are")

    owner = got.get(f"dc_acl_{OWNER_ROLE}", "missing")
    if owner == "missing":
        bad("sql_the_owner_still_owns_it", "no ACL entry for the owner")
    else:
        ok("sql_the_owner_still_owns_it",
           f"postgres owns the table and holds {owner}. Every privilege by "
           "virtue of ownership: a REVOKE cannot take them away and does not "
           "need to. The four granted to a client are the four operations the "
           "sync performs")


def probe_users(db_url):
    """Two real accounts, borrowed rather than invented.

    public.decks.user_id is a foreign key to auth.users, so a uuid picked out of
    the air cannot own a deck and the probe could not tell a policy refusal from
    a missing account. Two distinct accounts are needed because half of what is
    being tested is one account being refused another account's row.
    """
    rows = psql(db_url, """
      select 'first=' || (select id::text from auth.users order by id limit 1);
      select 'second=' || coalesce((select id::text from auth.users
                                     where id <> (select id from auth.users order by id limit 1)
                                     order by id limit 1), '');
    """)
    got = values(rows)
    return got.get("first", ""), got.get("second", "")


def check_own_write(db_url, a, b):
    """A client writes its own line, and the row that lands is its own.

    Run as the authenticated role with the claims PostgREST sets, because the
    thing being checked is that the account accepts what a client will do - the
    column default standing in for the owner, and the policy's WITH CHECK
    passing - not that some equivalent SQL as the owner works.

    Written inside one transaction and rolled back, whether or not an assertion
    in the middle failed.
    """
    rows = psql(db_url, f"""
      begin;

      -- A deck for each account, written as the owner: decks.id is generated
      -- always as identity and this probe is about deck_cards' policy.
      insert into public.decks (user_id, game, name, sync_id)
      values ('{a}', 'zz-probe', 'zz-probe a', '00000000-0000-4000-8000-0000000000a1'),
             ('{b}', 'zz-probe', 'zz-probe b', '00000000-0000-4000-8000-0000000000b1');

      select 'probe_decks=' || count(*) from public.decks where game = 'zz-probe';

      -- The claims PostgREST sets for a signed-in client, and the role it runs
      -- as. auth.uid() reads exactly these.
      select set_config('request.jwt.claims',
                        json_build_object('sub', '{b}', 'role', 'authenticated')::text,
                        true);
      select 'uid_before_switch=' || coalesce(auth.uid()::text, 'null');

      set local role authenticated;

      -- The client's own row. user_id is omitted, so it comes from the column
      -- default, and the policy's WITH CHECK has to accept it.
      insert into public.deck_cards (game, deck_sync_id, card_id, board, quantity)
      values ('zz-probe', '00000000-0000-4000-8000-0000000000b1', 'zz-probe-card', 'main', 2);

      select 'own_row_visible=' || count(*) from public.deck_cards where game = 'zz-probe';
      select 'own_row_owner=' || coalesce((select user_id::text from public.deck_cards
                                            where game = 'zz-probe' limit 1), 'none');
      select 'own_row_quantity=' || coalesce((select quantity::text from public.deck_cards
                                               where game = 'zz-probe' limit 1), 'none');

      reset role;

      select 'row_seen_by_the_owner=' || count(*) from public.deck_cards where game = 'zz-probe';

      rollback;

      select 'cards_after_rollback=' || count(*) from public.deck_cards where game = 'zz-probe';
      select 'decks_after_rollback=' || count(*) from public.decks where game = 'zz-probe';
    """)
    got = values(rows)

    if got.get("probe_decks") != "2":
        bad("own_write_setup", f"the probe wrote {got.get('probe_decks')} decks, expected 2")
        return

    failures = []
    if got.get("uid_before_switch") != b:
        failures.append(f"auth.uid() is {got.get('uid_before_switch')}, not the account whose claims were set")
    if got.get("own_row_visible") != "1":
        failures.append(f"the client cannot see its own row: {got.get('own_row_visible')} visible")
    if got.get("own_row_owner") != b:
        failures.append(f"the row landed under {got.get('own_row_owner')} rather than the session's account")
    if got.get("own_row_quantity") != "2":
        failures.append(f"the row kept the wrong quantity: {got.get('own_row_quantity')}")
    if got.get("row_seen_by_the_owner") != "1":
        failures.append(f"the row is not in the table: {got.get('row_seen_by_the_owner')}")

    if failures:
        bad("rls_lets_a_client_write_its_own_row", "\n".join(failures))
    else:
        ok("rls_lets_a_client_write_its_own_row",
           "as authenticated, holding one account's claims, a client inserted a "
           "line without naming the owner; the column default filled it in from "
           "auth.uid(), the WITH CHECK accepted it, and the row that landed "
           "belongs to that account and to no other")

    if got.get("cards_after_rollback") == "0" and got.get("decks_after_rollback") == "0":
        ok("probe_left_nothing_behind",
           "the probe decks and the probe line were written inside a "
           "transaction and rolled back; the account holds no row for either")
    else:
        bad("probe_left_nothing_behind",
            f"{got.get('cards_after_rollback')} lines and "
            f"{got.get('decks_after_rollback')} decks survived the rollback")


def check_foreign_write(db_url, a, b):
    """The same client, the other account's row. It has to be refused.

    The other account's deck is written first, so the foreign key is satisfied
    and the only thing left that can refuse the second statement is the policy.
    A check that skipped that would pass on a foreign-key error and call it row
    level security.
    """
    status, stderr = psql_allow_failure(db_url, f"""
      begin;

      insert into public.decks (user_id, game, name, sync_id)
      values ('{a}', 'zz-probe', 'zz-probe a', '00000000-0000-4000-8000-0000000000a1');

      select set_config('request.jwt.claims',
                        json_build_object('sub', '{b}', 'role', 'authenticated')::text,
                        true);

      set local role authenticated;

      insert into public.deck_cards (user_id, game, deck_sync_id, card_id, board)
      values ('{a}', 'zz-probe', '00000000-0000-4000-8000-0000000000a1', 'zz-probe-card', 'main');

      select 'this_statement_should_never_run=1';
    """)

    if status == 0:
        bad("rls_refuses_another_accounts_row",
            "the statement succeeded: one account wrote a line into another "
            "account's deck")
        return

    lowered = stderr.lower()
    if "row-level security policy" in lowered and "foreign key" not in lowered:
        ok("rls_refuses_another_accounts_row",
           "a session holding one account's claims was refused a row claiming "
           "the other's, by the policy - the error names row level security and "
           "not a foreign key, and the deck it named existed, so the policy is "
           "the only thing that could have refused it")
    elif "foreign key" in lowered:
        bad("rls_refuses_another_accounts_row",
            "the statement was refused by the foreign key rather than by the "
            f"policy: {stderr.strip()[:300]}")
    else:
        bad("rls_refuses_another_accounts_row", f"refused, but not by the policy: {stderr.strip()[:300]}")

    after = values(psql(db_url, """
      select 'cards_after_refusal=' || count(*) from public.deck_cards where game = 'zz-probe';
      select 'decks_after_refusal=' || count(*) from public.decks where game = 'zz-probe';
    """))
    if after.get("cards_after_refusal") == "0" and after.get("decks_after_refusal") == "0":
        ok("refused_write_left_nothing_behind",
           "the refused transaction was never committed and the connection that "
           "held it is gone; the account holds nothing for zz-probe")
    else:
        bad("refused_write_left_nothing_behind",
            f"{after.get('cards_after_refusal')} lines and "
            f"{after.get('decks_after_refusal')} decks survived")


def statements(path):
    """The SQL in a migration file, with its comments removed.

    Both files explain themselves at length, and a check that searched the raw
    text would pass on a sentence rather than on a statement: "the down file
    mentions deck_cards" is not the claim, "the down file drops it" is.
    """
    lines = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            code = line.split("--", 1)[0].rstrip()
            if code.strip():
                lines.append(code)
    return "\n".join(lines)


def check_down_reverses_up():
    """A reading of the two files, not a measurement of the database.

    The down migration is deliberately not run. Running it would drop a deck's
    entire contents and every client's identity, and the point of the file is
    that it does that - so what is checked here is that it is complete against
    the up file, statement by statement, and that it is scoped to what the up
    file created.
    """
    up_path = os.path.join(HERE, UP_FILE)
    down_path = os.path.join(HERE, DOWN_FILE)
    for path in (up_path, down_path):
        if not os.path.exists(path):
            bad("down_reverses_up", f"{os.path.basename(path)} is missing")
            return
    up = statements(up_path)
    down = statements(down_path)

    missing = []
    for what, in_up, in_down in (
        ("the contents table", "create table public.deck_cards",
         r"drop table if exists public\.deck_cards"),
        ("the unique constraint", "add constraint decks_user_sync unique (user_id, sync_id)",
         r"drop constraint if exists decks_user_sync"),
        ("the owner default the migration added", "alter column user_id set default auth.uid()",
         r"alter column user_id drop default"),
    ):
        if in_up not in " ".join(up.split()):
            missing.append(f"{what}: not found in {UP_FILE}")
        if not re.search(in_down, down):
            missing.append(f"{what}: no statement in {DOWN_FILE} undoes it")

    for column in ADDED_DECK_COLUMNS:
        if f"add column {column}" not in up:
            missing.append(f"column {column}: not added by {UP_FILE}")
        if f"drop column if exists {column}" not in down:
            missing.append(f"column {column}: not dropped by {DOWN_FILE}")

    if missing:
        bad("down_reverses_up", "\n".join(missing))
    else:
        ok("down_reverses_up",
           f"every object {UP_FILE} creates has a statement in {DOWN_FILE} that "
           f"undoes it: the table, the unique constraint, the eight columns and "
           "the owner default. Read as text - the down file is not run, because "
           "running it is what it warns about")

    named = set(re.findall(r"public\.(\w+)", down))
    if named == {"decks", "deck_cards"}:
        ok("down_touches_only_what_the_up_touched",
           "the only tables the down file's statements name are decks and "
           "deck_cards. It does not mention collection_entries at any point, "
           "and it cannot: the up file never touched it either")
    else:
        bad("down_touches_only_what_the_up_touched",
            f"the down file's statements name {sorted(named)}")

    statements_down = re.sub(r"\s+", " ", down).lower()
    leftovers = [word for word in ("grant ", "revoke ", "create policy", "drop policy",
                                   "enable row level security")
                 if word in statements_down]
    if leftovers:
        bad("down_needs_no_grant_or_policy_statements", ", ".join(leftovers))
    else:
        ok("down_needs_no_grant_or_policy_statements",
           "the grants, the policy, the index and the row level security flag "
           "all belong to public.deck_cards and a DROP TABLE takes them with "
           "the table; nothing else in the down file has to undo them")

    if "supabase_realtime" in re.sub(r"\s+", " ", up):
        bad("up_leaves_the_publication_alone",
            "the up file's statements mention supabase_realtime")
    else:
        ok("up_leaves_the_publication_alone",
           "no statement in the up file touches a publication. Streaming the "
           "deck tables is step 4, in a migration of its own")


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env-file", help="KEY=VALUE file to read the credentials from")
    args = parser.parse_args()

    if args.env_file:
        with open(args.env_file, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                name, value = line.split("=", 1)
                name, value = name.strip(), value.strip().strip('"').strip("'")
                if name and name not in os.environ:
                    os.environ[name] = value

    db_url = (os.environ.get("SUPABASE_DB_URL_POOLED")
              or os.environ.get("SUPABASE_DB_URL") or "")
    if not db_url:
        raise SystemExit("SUPABASE_DB_URL_POOLED is not set. Put it in the "
                         "environment or pass --env-file.")
    if not shutil.which("psql"):
        raise SystemExit("psql is not on PATH.")

    print(__doc__.split("Usage:")[0].strip().splitlines()[0])
    print()
    print("target        the session pooler in SUPABASE_DB_URL_POOLED")
    print()
    print("--- SQL, as the owner ---")
    check_schema(db_url)

    print()
    print("--- SQL, as a client, rolled back ---")
    first, second = probe_users(db_url)
    if not first or not second:
        skip("rls_lets_a_client_write_its_own_row",
             "fewer than two accounts exist to borrow, and the probe needs two: "
             "one whose row is written and one whose row is refused")
        skip("rls_refuses_another_accounts_row", "same")
    else:
        check_own_write(db_url, first, second)
        check_foreign_write(db_url, first, second)

    print()
    print("--- the two migration files, read ---")
    check_down_reverses_up()

    passed = sum(1 for status, _, _ in RESULTS if status == "PASS")
    failed = sum(1 for status, _, _ in RESULTS if status == "FAIL")
    skipped = sum(1 for status, _, _ in RESULTS if status == "SKIP")
    print()
    print(f"{passed} passed, {failed} failed, {skipped} skipped")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
