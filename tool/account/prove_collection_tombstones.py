#!/usr/bin/env python3
"""Prove that a deletion can travel through the account's collection table.

The claim this file tests is not that a column exists. It is that one column is
enough: that a holding can be removed on one device and stay removed on every
other, that re-adding it revives the row the unique index already holds rather
than inserting a second one, and that none of it disturbed the table it was
added to - which holds one real collector's holding.

Two kinds of check, and neither implies the other:

  * against the live schema, as the owner, reading pg_catalog and
    information_schema. This is where "one column and nothing else" is a
    measurement rather than a promise: the constraints, the policy, the grants,
    the indexes and the existing row are all compared with the fingerprints
    taken from this project before the migration was written.

  * against the live table, as the owner, inside a transaction that is rolled
    back. A unique index, a conflict target and a nullable column cannot be
    tested anywhere but the database that has them - SQLite in a unit test has
    a different constraint, and a fake account table has none. The probe writes
    one zz-probe holding, deletes it softly, re-adds it, and checks that the
    row that came back is the row that went away.

Credentials come from the environment, or from a KEY=VALUE file named with
--env-file. They are never printed, and nothing in this file holds a secret.

  SUPABASE_DB_URL_POOLED   required - the session pooler, port 5432

Usage:
  set -a; . /home/zixen/arcanum/supabase.env; set +a
  python3 tool/account/prove_collection_tombstones.py

Exit status is 0 only if nothing failed.
"""

from __future__ import annotations

import argparse
import os
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

# The table as it stood on 2026-09-19, read from the live project before the
# migration was written. Asserting these afterwards is how "one column was
# added" becomes a check: a migration that also, say, rewrote a policy or
# dropped an index would pass a check that only looked for the new column.
BEFORE = {
    "row16_md5": "be8a05b7b399f7dfc418398b2849df69",
    "n_rows": "1",
    "cons_md5": "284bcd1a43d57a11c87fbca9ad33bdc0",
    "pol_md5": "f46c5cf8da5eeead8007200ee17bc04b",
    "idx_md5": "93cc4a3c404f1628eb1c84805de50006",
    "grant_md5": "a77de29eee559c34252bb8df508e30ad",
}

# The fifteen columns the table had, in the order they were in. The fingerprint
# above is taken over exactly these, which is what makes it comparable at both
# ends of the migration: the sixteenth column is the thing being added and
# cannot be part of a reading that has to match before and after.
COLUMNS_16 = (
    "id,user_id,game,card_id,finish,condition,language,quantity,purchase_price,"
    "purchase_date,binder,notes,for_trade,created_at,updated_at"
)

# The client's conflict target: AccountCollection.conflictTarget in
# lib/data/sync/account_collection.dart, and the unique index the account
# already had. The revive depends on it, so it is read back rather than assumed.
CONFLICT_TARGET = "user_id,game,card_id,finish,condition,language,binder"

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

    The whole script is one process, which matters for the probe below: its
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


def check_schema(db_url):
    rows = psql(db_url, f"""
      select 'row16_md5=' || coalesce(md5(string_agg(row_to_json(t)::text, '~' order by id)), 'empty')
        from (select {COLUMNS_16} from public.collection_entries) t;
      select 'n_rows=' || count(*) from public.collection_entries;
      select 'n_cols=' || count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'collection_entries';
      select 'cons_md5=' || md5(string_agg(conname || ':' || pg_get_constraintdef(o.oid), ',' order by conname))
        from pg_constraint o where conrelid = 'public.collection_entries'::regclass;
      select 'pol_md5=' || coalesce(md5(string_agg(policyname || '|' || cmd || '|' ||
             array_to_string(roles, ',') || '|' || coalesce(qual, '-') || '|' ||
             coalesce(with_check, '-'), ',' order by policyname)), 'none')
        from pg_policies where schemaname = 'public' and tablename = 'collection_entries';
      select 'idx_md5=' || coalesce(md5(string_agg(indexdef, ',' order by indexname)), 'none')
        from pg_indexes where schemaname = 'public' and tablename = 'collection_entries';
      select 'grant_md5=' || md5(string_agg(grantee || '|' || privs, ',' order by grantee))
        from (select grantee, string_agg(distinct privilege_type, ',' order by privilege_type) as privs
                from information_schema.role_table_grants
               where table_schema = 'public' and table_name = 'collection_entries'
               group by grantee) g;
      select 'rls=' || relrowsecurity::text || ' force=' || relforcerowsecurity::text
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = 'collection_entries';
      select 'deleted_at=' || coalesce((select data_type || ' null=' || is_nullable
                from information_schema.columns
               where table_schema = 'public' and table_name = 'collection_entries'
                 and column_name = 'deleted_at'), 'ABSENT');
      select 'unique_target=' || pg_get_constraintdef(oid)
        from pg_constraint
       where conrelid = 'public.collection_entries'::regclass and contype = 'u';
    """)
    got = values(rows)

    # The pre-existing columns, one at a time. An added column is allowed to
    # move n_cols; nothing is allowed to move the fifteen.
    failures = [
        f"{name}: {got.get(name, 'missing')} != {want}"
        for name, want in BEFORE.items()
        if got.get(name) != want
    ]
    if failures:
        bad("sql_nothing_but_the_new_column_changed", "\n".join(failures))
    else:
        ok("sql_nothing_but_the_new_column_changed",
           "the row, the fifteen columns it had, the constraints, the policy, the "
           "grants and the indexes are byte-for-byte what they were before the "
           f"migration, which added one column: 15 -> {got.get('n_cols')}")

    if got.get("deleted_at") == "timestamp with time zone null=YES":
        ok("sql_deleted_at_is_a_nullable_instant",
           "timestamptz and nullable, so null means present for every row that "
           "already exists and no backfill can be wrong")
    else:
        bad("sql_deleted_at_is_a_nullable_instant", got.get("deleted_at", "missing"))

    if got.get("rls") == "true force=false":
        ok("sql_rls_untouched",
           "row level security still on and still not forced: a soft delete is an "
           "UPDATE by the owner, which the existing policy already allows")
    else:
        bad("sql_rls_untouched", got.get("rls", "missing"))

    target = got.get("unique_target", "")
    if target.replace(" ", "") == f"UNIQUE({CONFLICT_TARGET})".replace(" ", ""):
        ok("sql_conflict_target_still_there",
           f"the unique constraint on ({CONFLICT_TARGET}) is what makes a re-add a "
           "revive rather than a second row, and it is unchanged")
    else:
        bad("sql_conflict_target_still_there", f"got {target}")


def check_revive(db_url):
    """The whole life of a holding, on the real table, in one rolled-back
    transaction: inserted, deleted softly, re-added.

    Written with the client's own statements - the conflict target and the
    deleted_at the sync sends - because the thing being checked is that the
    account accepts what the client will do, not that some equivalent SQL
    works.
    """
    rows = psql(db_url, f"""
      begin;

      with u as (select user_id from public.collection_entries limit 1)
      insert into public.collection_entries
        (user_id, game, card_id, finish, condition, language, binder,
         quantity, created_at, updated_at)
      select user_id, 'zz-probe', 'zz-probe', 'nonfoil', 'near_mint', 'en', '',
             3, now(), now()
        from u
      returning 'probe_id=' || id::text;

      select 'live_after_insert=' || count(*) from public.collection_entries
       where game = 'zz-probe' and deleted_at is null;

      -- The soft delete the phone now performs instead of removing the row.
      update public.collection_entries
         set deleted_at = now(), updated_at = now()
       where game = 'zz-probe';

      select 'live_after_delete=' || count(*) from public.collection_entries
       where game = 'zz-probe' and deleted_at is null;
      select 'tombstoned=' || count(*) from public.collection_entries
       where game = 'zz-probe' and deleted_at is not null;

      -- The push, as the sync spells it: the same row, deleted_at back to null,
      -- a later updated_at.
      with u as (select user_id from public.collection_entries limit 1)
      insert into public.collection_entries
        (user_id, game, card_id, finish, condition, language, binder,
         quantity, deleted_at, updated_at)
      select user_id, 'zz-probe', 'zz-probe', 'nonfoil', 'near_mint', 'en', '',
             1, null, now()
        from u
      on conflict ({CONFLICT_TARGET})
      do update set quantity = excluded.quantity,
                    deleted_at = excluded.deleted_at,
                    updated_at = excluded.updated_at
      returning 'revived_id=' || id::text,
                'revived_quantity=' || quantity::text,
                'revived_deleted_at=' || coalesce(deleted_at::text, 'null');

      select 'zz_probe_rows=' || count(*) from public.collection_entries
       where game = 'zz-probe';

      rollback;

      select 'after_rollback=' || count(*) from public.collection_entries
       where game = 'zz-probe';
    """)
    got = values(rows)
    probe_id = got.get("probe_id", "")

    if not probe_id:
        skip("revive_round_trip",
             "no holding exists to borrow a user id from; the probe cannot run "
             "without one, because user_id has a foreign key to auth.users")
        return

    failures = []
    if got.get("live_after_insert") != "1":
        failures.append(f"a fresh holding is not visible: {got.get('live_after_insert')}")
    if got.get("live_after_delete") != "0":
        failures.append(f"a soft-deleted holding is still visible: {got.get('live_after_delete')}")
    if got.get("tombstoned") != "1":
        failures.append(f"the tombstone is not in the table: {got.get('tombstoned')}")
    if got.get("revived_id") != probe_id:
        failures.append(f"re-adding made a second row: {got.get('revived_id')} != {probe_id}")
    if got.get("revived_quantity") != "1":
        failures.append(f"the revived row kept the dead row's count: {got.get('revived_quantity')}")
    if got.get("revived_deleted_at") != "null":
        failures.append(f"the revived row is still deleted: {got.get('revived_deleted_at')}")
    if got.get("zz_probe_rows") != "1":
        failures.append(f"{got.get('zz_probe_rows')} zz-probe rows, expected 1")

    if failures:
        bad("revive_round_trip", "\n".join(failures))
    else:
        ok("revive_round_trip",
           "one row: inserted, hidden by deleted_at, then revived in place by the "
           f"same upsert the sync performs - id {probe_id[:8]}..., quantity 3 -> 1, "
           "deleted_at back to null, and still one row rather than two")

    # The test must not be the thing that damages the table.
    if got.get("after_rollback") == "0":
        ok("probe_left_nothing_behind",
           "the zz-probe row was written inside a transaction and rolled back; the "
           "account holds no row for it and the real holding was never touched")
    else:
        bad("probe_left_nothing_behind", f"{got.get('after_rollback')} probe rows survived")


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
    print("--- SQL, the life of a holding, rolled back ---")
    check_revive(db_url)

    passed = sum(1 for status, _, _ in RESULTS if status == "PASS")
    failed = sum(1 for status, _, _ in RESULTS if status == "FAIL")
    skipped = sum(1 for status, _, _ in RESULTS if status == "SKIP")
    print()
    print(f"{passed} passed, {failed} failed, {skipped} skipped")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
