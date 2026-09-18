#!/usr/bin/env python3
"""Prove the catalogue's RLS posture against the live database.

Design: docs/catalogue-server-side.md, section 2.4. The claim being tested is
that the four catalog_ tables are readable by anyone holding the publishable
key and writable by nobody, that a signed-in collector can read them too, and
that none of this changed what one account can see of another account's
collection. A claim about security that has not been run is not a claim, so
this script asserts each of those against the deployed project rather than
against the SQL that was supposed to produce them.

Two kinds of check, and the distinction matters:

  * over HTTP, as PostgREST, with the keys a browser and the server actually
    hold. This is the only way to test the posture as it is experienced: the
    grants, the row level security policies and the key handling are all in the
    path. These checks run anywhere with network access.

  * over SQL, as the owner, reading pg_catalog and information_schema. This
    catches the things a request cannot distinguish - a write that failed for
    the wrong reason, a grant that reappears, a policy that was never created -
    and it is where the design's own required test lives (anon holds SELECT and
    nothing else). These need psql and a database URL and are skipped without
    them; a skip is reported as a skip, never as a pass.

Credentials come from the environment, or from a KEY=VALUE file named with
--env-file. They are never printed, and nothing in this file holds a secret.

  SUPABASE_URL               required
  SUPABASE_PUBLISHABLE_KEY   required - the public key, the client's key
  SUPABASE_SECRET_KEY        required unless --no-auth - the admin key, used
                             only to create and delete one throwaway account
                             and to take a privileged reference reading
  SUPABASE_DB_URL_POOLED     optional - enables the SQL checks
  (SUPABASE_DB_URL is accepted as a fallback name)

Usage:
  SUPABASE_URL=... SUPABASE_PUBLISHABLE_KEY=... SUPABASE_SECRET_KEY=... \
  SUPABASE_DB_URL_POOLED=... python3 tool/catalog/prove_catalogue_posture.py

or, on a host that already holds them:

  set -a; . /home/zixen/arcanum/supabase.env; set +a
  python3 tool/catalog/prove_catalogue_posture.py

Exit status is 0 only if nothing failed.
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

TIMEOUT = 30

CATALOG_TABLES = ("catalog_sets", "catalog_cards", "catalog_prices", "catalog_meta")
ACCOUNT_TABLES = ("decks", "collection_entries")

# CardGame.id in lib/domain/models/card_game.dart. The nine rows step 0 seeds.
GAMES = (
    "mtg", "pokemon", "lorcana", "yugioh", "onepiece",
    "swu", "digimon", "dragonball", "gundam",
)

# The account tables' posture, read from the live project before this migration
# was written. Asserting it afterwards is how "the account tables were not
# touched" becomes a check rather than a promise.
ACCOUNT_POLICIES = {
    "decks": ("a collector sees their own decks", "ALL", "public",
              "(auth.uid() = user_id)", "(auth.uid() = user_id)"),
    "collection_entries": ("a collector sees their own cards", "ALL", "public",
                           "(auth.uid() = user_id)", "(auth.uid() = user_id)"),
}

# Codes.separators in lib/core/utils/codes.dart. The generated column must fold
# exactly these six, in this order, or the server folds a stored set code
# differently from the browser's own SQLite.
SEPARATORS = ("-", " ", ".", "/", "_", ":")

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
# HTTP, as PostgREST
# ---------------------------------------------------------------------------


class Client:
    def __init__(self, base):
        self.base = base.rstrip("/")

    def call(self, method, path, key, token=None, body=None, prefer=None, base_path="rest/v1"):
        url = f"{self.base}/{base_path}/{path}"
        data = None if body is None else json.dumps(body).encode("utf-8")
        headers = {"apikey": key, "Accept": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        if data is not None:
            headers["Content-Type"] = "application/json"
        if prefer:
            headers["Prefer"] = prefer
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                return resp.status, resp.read().decode("utf-8", "replace"), dict(resp.headers)
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read().decode("utf-8", "replace"), dict(exc.headers)
        except urllib.error.URLError as exc:
            raise SystemExit(f"cannot reach {self.base}: {exc}")

    def rows(self, path, key, token=None):
        status, text, _ = self.call("GET", path, key, token)
        if status != 200:
            return status, None, text
        return status, json.loads(text or "[]"), text


def message_of(text):
    try:
        parsed = json.loads(text)
    except Exception:
        return (text or "").strip()[:200]
    if isinstance(parsed, dict):
        for field in ("message", "error_description", "error", "hint", "details"):
            if parsed.get(field):
                return str(parsed[field])
    return str(parsed)[:200]


def check_reads(client, label, key, token, expect_meta_rows):
    """Every catalogue table answers a SELECT, and catalog_meta answers with
    the nine seeded rows rather than merely with 200."""
    failures = []
    for table in CATALOG_TABLES:
        status, body, text = client.rows(f"{table}?select=*&limit=1", key, token)
        if status != 200 or not isinstance(body, list):
            failures.append(f"{table}: HTTP {status} {message_of(text)}")
    if failures:
        bad(f"{label}_reads_catalog_tables", "\n".join(failures))
    else:
        ok(f"{label}_reads_catalog_tables",
           "select=* on all four tables answers 200 with a JSON array")

    status, body, text = client.rows("catalog_meta?select=game&order=game", key, token)
    if status != 200:
        bad(f"{label}_reads_catalog_meta", f"HTTP {status} {message_of(text)}")
    elif len(body) != expect_meta_rows:
        bad(f"{label}_reads_catalog_meta",
            f"expected {expect_meta_rows} rows, got {len(body)}")
    else:
        ok(f"{label}_reads_catalog_meta",
           f"{len(body)} catalog_meta rows readable: {','.join(r['game'] for r in body)}")


WRITE_PROBES = {
    "catalog_sets": {"game": "zz-probe", "code": "zz-probe", "id": "zz-probe",
                     "name": "posture probe"},
    "catalog_cards": {"game": "zz-probe", "id": "zz-probe", "set_code": "zz-probe",
                      "name": "posture probe", "collector_number": "0"},
    "catalog_prices": {"game": "zz-probe", "card_id": "zz-probe", "kind": "finish",
                       "code": "nonfoil", "price": 0.01, "source": "probe",
                       "observed_on": "2000-01-01"},
    "catalog_meta": {"game": "zz-probe"},
}

# Each update carries a column that table actually has. This is not decoration:
# PostgREST checks the payload against its schema cache before it checks the
# role's privileges, so an update body naming a column another table lacks
# comes back 400 "could not find the column" - a refusal, but a refusal that
# proves nothing about the posture.
UPDATE_PROBES = {
    "catalog_sets": {"name": "posture probe"},
    "catalog_cards": {"name": "posture probe"},
    "catalog_prices": {"price": 0.02},
    "catalog_meta": {"last_import_note": "posture probe"},
}

# Every write attempt carries a filter, so that a posture that is wrong fails
# as a refused write rather than as a rewritten catalogue.
WRITE_PATHS = {
    "insert": lambda t: (t, WRITE_PROBES[t]),
    "update": lambda t: (f"{t}?game=eq.zz-probe", UPDATE_PROBES[t]),
    "delete": lambda t: (f"{t}?game=eq.zz-probe", None),
}


def check_writes(client, label, key, token):
    """INSERT, UPDATE and DELETE are all refused, on all four tables.

    Refused for the right reason, too: PostgREST answers 401 for an anonymous
    request and 403 for a signed-in one when the role lacks the privilege, and
    a bare 2xx here would mean the publishable key - which ships in the web
    bundle - can rewrite the catalogue every browser reads."""
    expect = 401 if label == "publishable_key" else 403
    for verb, path_of in WRITE_PATHS.items():
        failures, seen = [], []
        for table in CATALOG_TABLES:
            path, body = path_of(table)
            method = {"insert": "POST", "update": "PATCH", "delete": "DELETE"}[verb]
            status, text, _ = client.call(method, path, key, token, body,
                                          prefer="return=representation")
            seen.append(f"{table}: {status}")
            if 200 <= status < 300:
                failures.append(f"{table}: HTTP {status} ACCEPTED {text[:120]}")
            elif status != expect:
                failures.append(f"{table}: HTTP {status} (expected {expect}) {message_of(text)}")
        if failures:
            bad(f"{label}_cannot_{verb}", "\n".join(failures))
        else:
            ok(f"{label}_cannot_{verb}",
               f"all four tables refused with HTTP {expect}: {'; '.join(seen)}")


def cleanup_probe_rows(client, secret, base_path="rest/v1"):
    """Nothing should have been written, so this deletes nothing. It exists so
    that a posture that has regressed leaves no trace in the catalogue, and it
    runs through the key that is allowed to write."""
    for table in ("catalog_prices", "catalog_cards", "catalog_sets", "catalog_meta"):
        client.call("DELETE", f"{table}?game=eq.zz-probe", secret)


# ---------------------------------------------------------------------------
# SQL, as the owner
# ---------------------------------------------------------------------------


def psql(db_url, sql):
    """One query, tab-separated, no header. Returns a list of rows of fields."""
    proc = subprocess.run(
        ["psql", db_url, "-X", "-q", "-A", "-t", "-F", "|", "-v", "ON_ERROR_STOP=1",
         "-c", sql],
        capture_output=True, text=True, timeout=120,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"psql: {proc.stderr.strip()[:400]}")
    return [line.split("|") for line in proc.stdout.splitlines() if line != ""]


def session_url(db_url):
    """The credentials file recommends the session pooler for migrations; the
    transaction pooler on 6543 is what the service uses at runtime. Either
    answers these queries, but the session pooler is the one the design names
    for admin work, so use it when the URL carries the runtime port."""
    if ":6543/" in db_url:
        return db_url.replace(":6543/", ":5432/"), True
    return db_url, False


def check_sql(db_url, expect_meta_rows):
    grant_sql = f"""
      select grantee, table_name,
             coalesce(string_agg(distinct privilege_type, ',' order by privilege_type), '')
        from information_schema.role_table_grants
       where table_schema = 'public'
         and table_name in ({",".join("'" + t + "'" for t in CATALOG_TABLES)})
         and grantee in ('anon','authenticated')
       group by 1, 2 order by 2, 1
    """
    rows = psql(db_url, grant_sql)
    seen = {(g, t): p for g, t, p in rows}
    failures = []
    for table in CATALOG_TABLES:
        for grantee in ("anon", "authenticated"):
            privs = seen.get((grantee, table), "")
            if privs != "SELECT":
                failures.append(f"{grantee} on {table}: {privs or 'no grants'}")
    if failures:
        bad("sql_anon_and_authenticated_hold_only_select", "\n".join(failures))
    else:
        ok("sql_anon_and_authenticated_hold_only_select",
           "information_schema.role_table_grants: SELECT, and nothing else, "
           "for anon and authenticated on all four tables")

    dml_sql = f"""
      select t, r,
             has_table_privilege(r, 'public.' || t, 'insert')::text,
             has_table_privilege(r, 'public.' || t, 'update')::text,
             has_table_privilege(r, 'public.' || t, 'delete')::text
        from unnest(array[{",".join("'" + t + "'" for t in CATALOG_TABLES)}]) t
        cross join unnest(array['anon','authenticated']) r
        order by t, r
    """
    rows = psql(db_url, dml_sql)
    # psql renders a cast boolean as 'true'/'false', not 't'/'f'. Comparing
    # against the right spelling matters here: this check is the one that would
    # otherwise report success for a role that can write.
    failures = [f"{t}/{r}: insert={i} update={u} delete={d}"
                for t, r, i, u, d in rows if any(v == "true" for v in (i, u, d))]
    if failures:
        bad("sql_no_dml_privilege_at_all", "\n".join(failures))
    else:
        ok("sql_no_dml_privilege_at_all",
           "has_table_privilege is false for INSERT, UPDATE and DELETE on "
           "every table, for both roles")

    rls_sql = f"""
      select c.relname, c.relrowsecurity::text
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public'
         and c.relname in ({",".join("'" + t + "'" for t in CATALOG_TABLES)})
       order by 1
    """
    rows = psql(db_url, rls_sql)
    off = [t for t, rls in rows if rls not in ("t", "true")]
    if len(rows) != len(CATALOG_TABLES):
        bad("sql_rls_enabled_on_all_four", f"only found {len(rows)} of the four tables")
    elif off:
        bad("sql_rls_enabled_on_all_four", f"row level security off on {off}")
    else:
        ok("sql_rls_enabled_on_all_four", "relrowsecurity is true on all four tables")

    policy_sql = f"""
      select tablename, policyname, cmd, permissive,
             array_to_string(roles, ',') as roles, coalesce(qual, '') as qual
        from pg_policies
       where schemaname = 'public'
         and tablename in ({",".join("'" + t + "'" for t in CATALOG_TABLES)})
       order by tablename, policyname
    """
    rows = psql(db_url, policy_sql)
    failures = []
    for table in CATALOG_TABLES:
        mine = [r for r in rows if r[0] == table]
        if len(mine) != 1:
            failures.append(f"{table}: {len(mine)} policies, expected exactly 1")
            continue
        _, name, cmd, permissive, roles, qual = mine[0]
        if (cmd, permissive, roles, qual.strip()) != ("SELECT", "PERMISSIVE",
                                                      "anon,authenticated", "true"):
            failures.append(f"{table}: {name} cmd={cmd} roles={roles} qual={qual}")
    if failures:
        bad("sql_one_true_select_policy_per_table", "\n".join(failures))
    else:
        ok("sql_one_true_select_policy_per_table",
           "one FOR SELECT policy per table, to anon,authenticated, USING (true); "
           "no write policy exists to be found")

    meta_sql = f"select game from public.catalog_meta order by game"
    rows = [r[0] for r in psql(db_url, meta_sql)]
    if sorted(rows) != sorted(GAMES):
        bad("sql_catalog_meta_has_the_nine_games",
            f"expected {sorted(GAMES)}, got {sorted(rows)}")
    else:
        ok("sql_catalog_meta_has_the_nine_games",
           f"{len(rows)} rows: {','.join(rows)}")

    acct_sql = f"""
      select tablename, policyname, cmd, permissive,
             array_to_string(roles, ',') as roles,
             coalesce(qual, '') as qual, coalesce(with_check, '') as with_check
        from pg_policies
       where schemaname = 'public'
         and tablename in ({",".join("'" + t + "'" for t in ACCOUNT_TABLES)})
       order by tablename
    """
    rows = psql(db_url, acct_sql)
    failures = []
    for table in ACCOUNT_TABLES:
        mine = [r for r in rows if r[0] == table]
        want = ACCOUNT_POLICIES[table]
        if len(mine) != 1:
            failures.append(f"{table}: {len(mine)} policies, expected 1")
            continue
        _, name, cmd, permissive, roles, qual, with_check = mine[0]
        got = (name, cmd, roles, qual, with_check)
        if got != want:
            failures.append(f"{table}: {got} != {want}")

    priv_sql = f"""
      select table_name,
             coalesce(string_agg(distinct privilege_type, ',' order by privilege_type), '')
        from information_schema.role_table_grants
       where table_schema = 'public'
         and table_name in ({",".join("'" + t + "'" for t in ACCOUNT_TABLES)})
         and grantee in ('anon','authenticated')
       group by 1 order by 1
    """
    for table, privs in psql(db_url, priv_sql):
        missing = {"SELECT", "INSERT", "UPDATE", "DELETE"} - set(privs.split(","))
        if missing:
            failures.append(f"{table}: {sorted(missing)} no longer granted to "
                            f"anon/authenticated (got {privs})")

    if failures:
        bad("sql_account_tables_unchanged", "\n".join(failures))
    else:
        ok("sql_account_tables_unchanged",
           "decks and collection_entries still carry their owner-only policy "
           "(auth.uid() = user_id, ALL, to PUBLIC) and their pre-existing grants; "
           "nothing this migration did reached them")

    gen_sql = """
      select column_name, generation_expression
        from information_schema.columns
       where table_schema = 'public'
         and is_generated = 'ALWAYS'
         and table_name in ('catalog_sets','catalog_cards')
       order by table_name, column_name
    """
    got = {name: expr for name, expr in psql(db_url, gen_sql)}
    expected_fold = "lower(code)"
    for sep in SEPARATORS:
        expected_fold = f"replace({expected_fold}, '{sep}'::text, ''::text)"
    failures = []
    if got.get("code_folded") != expected_fold:
        failures.append(f"code_folded\n  got  {got.get('code_folded')}\n  want {expected_fold}")
    if got.get("number_bare") != "ltrim(collector_number, '0'::text)":
        failures.append(f"number_bare: {got.get('number_bare')}")
    if failures:
        bad("sql_generated_columns_match_the_dart_rules", "\n".join(failures))
    else:
        ok("sql_generated_columns_match_the_dart_rules",
           "code_folded strips the six Codes.separators from lower(code); "
           "number_bare is ltrim(collector_number,'0')")

    # A positive control. Everything above asserts that clients are refused;
    # on its own that would also be true of a table nothing can write to at
    # all, which would make step 1's importer impossible. So: the owner writes
    # a set, inside a transaction that is rolled back, and it succeeds.
    control = """
      begin;
      insert into public.catalog_sets (game, code, id, name)
        values ('zz-probe', 'zz-probe', 'zz-probe', 'posture probe');
      select 'inserted';
      rollback;
      select count(*) from public.catalog_sets where game = 'zz-probe';
    """
    try:
        rows = psql(db_url, control)
    except RuntimeError as exc:
        bad("sql_owner_can_still_write", str(exc))
    else:
        values = [field for row in rows for field in row]
        if "inserted" in values and values[-1] == "0":
            ok("sql_owner_can_still_write",
               "the owner connection inserted a catalog_sets row inside a "
               "transaction and rolled it back: the write path step 1 needs is "
               "open, and the refusals above are a permission decision rather "
               "than a table nothing can write to")
        else:
            bad("sql_owner_can_still_write", f"unexpected result: {values}")


# ---------------------------------------------------------------------------
# The authenticated session, and account isolation
# ---------------------------------------------------------------------------


def make_probe_user(client, secret):
    """A throwaway confirmed account, so that 'an authenticated session' means
    a real JWT from a real sign-in rather than a role spelled into a header.
    The account is deleted at the end; it holds no rows anywhere."""
    email = f"catalogue-posture-probe-{secrets.token_hex(6)}@marquezhv.com"
    password = secrets.token_urlsafe(24)
    status, text, _ = client.call(
        "POST", "admin/users", secret,
        body={"email": email, "password": password, "email_confirm": True},
        base_path="auth/v1")
    if status not in (200, 201):
        raise SystemExit(f"could not create the probe account: HTTP {status} {message_of(text)}")
    user_id = json.loads(text)["id"]
    status, text, _ = client.call(
        "POST", "token?grant_type=password", PUBLISHABLE_KEY,
        body={"email": email, "password": password}, base_path="auth/v1")
    if status != 200:
        raise SystemExit(f"probe account could not sign in: HTTP {status} {message_of(text)}")
    token = json.loads(text)["access_token"]
    return user_id, token, email


def delete_probe_user(client, secret, user_id):
    client.call("DELETE", f"admin/users/{user_id}", secret, base_path="auth/v1")


def check_account_isolation(client, token, secret, probe_id):
    """The catalogue work must not have loosened anything on the account
    tables. Two readings, because either alone is weak: the probe sees none of
    the rows that exist, and the rows that exist are still there to be seen by
    the privileged view."""
    status, text, _ = client.call(
        "GET", f"collection_entries?select=user_id", secret, None)  # privileged read
    if status != 200:
        skip("account_isolation_reference_read",
             f"privileged read of collection_entries: HTTP {status} {message_of(text)}")
        return
    all_rows = json.loads(text)
    others = [r for r in all_rows if r.get("user_id") != probe_id]

    status, text, _ = client.call("GET", "collection_entries?select=id,user_id", secret, None)
    other_ids = [r["id"] for r in json.loads(text) if r.get("user_id") != probe_id]

    status, body, text = client.rows("collection_entries?select=id,user_id", PUBLISHABLE_KEY, token)
    mine = [] if status != 200 else body
    leaked = [r for r in mine if r.get("user_id") != probe_id]
    if status != 200:
        bad("authenticated_sees_only_its_own_collection_entries",
            f"HTTP {status} {message_of(text)}")
    elif leaked:
        bad("authenticated_sees_only_its_own_collection_entries",
            f"{len(leaked)} rows belonging to another account are readable")
    else:
        ok("authenticated_sees_only_its_own_collection_entries",
           f"the probe account reads {len(mine)} collection_entries rows; "
           f"{len(all_rows)} rows exist in the table in total, "
           f"{len(others)} of them belonging to other accounts")

    if not other_ids:
        skip("authenticated_cannot_read_another_accounts_row",
             "no other account holds a collection_entries row to aim at")
    else:
        target = other_ids[0]
        status, body, text = client.rows(
            f"collection_entries?select=id&id=eq.{target}", PUBLISHABLE_KEY, token)
        if status != 200:
            bad("authenticated_cannot_read_another_accounts_row",
                f"HTTP {status} {message_of(text)}")
        elif body:
            bad("authenticated_cannot_read_another_accounts_row",
                f"the probe account read row {target[:8]}... by id")
        else:
            ok("authenticated_cannot_read_another_accounts_row",
               f"a row that the privileged view can see (id {target[:8]}...) "
               f"does not appear when the probe account asks for it by id")

        status, body, text = client.rows(
            f"collection_entries?select=id&id=eq.{target}", PUBLISHABLE_KEY, None)
        if status != 200:
            bad("anonymous_cannot_read_another_accounts_row",
                f"HTTP {status} {message_of(text)}")
        elif body:
            bad("anonymous_cannot_read_another_accounts_row",
                "a collection_entries row is readable with the publishable key alone")
        else:
            ok("anonymous_cannot_read_another_accounts_row",
               "the same row is invisible to the publishable key with no session")

    status, body, text = client.rows("decks?select=id,user_id", PUBLISHABLE_KEY, token)
    if status != 200:
        bad("authenticated_reads_only_its_own_decks", f"HTTP {status} {message_of(text)}")
    else:
        leaked = [r for r in body if r.get("user_id") != probe_id]
        if leaked:
            bad("authenticated_reads_only_its_own_decks",
                f"{len(leaked)} decks belonging to another account are readable")
        else:
            ok("authenticated_reads_only_its_own_decks",
               f"the probe account reads {len(body)} decks")

    status, body, text = client.rows("collection_entries?select=id", PUBLISHABLE_KEY, None)
    if status == 200 and body:
        bad("anonymous_cannot_read_collection_entries",
            f"{len(body)} rows readable with the publishable key alone")
    elif status != 200:
        bad("anonymous_cannot_read_collection_entries", f"HTTP {status} {message_of(text)}")
    else:
        ok("anonymous_cannot_read_collection_entries",
           "the publishable key with no session reads no collection_entries rows at all")


def account_counts(client, secret):
    """Row counts of the two account tables, read with the key that bypasses
    row level security. Taken before and after so that "the account tables were
    not touched" is an observation about the live table rather than an
    inference from what the script intended to do."""
    counts = {}
    for table in ACCOUNT_TABLES:
        status, text, _ = client.call("GET", f"{table}?select=id", secret, None)
        counts[table] = len(json.loads(text)) if status == 200 else None
    return counts


def check_no_leftovers(client, secret, probe_id, before):
    status, text, _ = client.call(
        "GET", f"collection_entries?select=id&user_id=eq.{probe_id}", secret, None)
    rows = json.loads(text) if status == 200 else None
    status2, text2, _ = client.call("GET", "catalog_sets?select=game&game=eq.zz-probe", secret, None)
    probe_rows = json.loads(text2) if status2 == 200 else None
    after = account_counts(client, secret)
    if rows is None or probe_rows is None:
        bad("no_probe_rows_left_behind", "could not take the privileged reading")
    elif rows or probe_rows:
        bad("no_probe_rows_left_behind",
            f"collection_entries rows for the probe account: {len(rows)}; "
            f"zz-probe catalogue rows: {len(probe_rows)}")
    elif after != before:
        bad("no_probe_rows_left_behind",
            f"the account tables changed: {before} -> {after}")
    else:
        ok("no_probe_rows_left_behind",
           "the probe account holds no collection_entries rows, the account "
           "tables hold exactly the rows they held before this script ran, and "
           "no zz-probe row exists in the catalogue: every write attempt was refused")


# ---------------------------------------------------------------------------
# Running it
# ---------------------------------------------------------------------------


def load_env_file(path):
    """KEY=VALUE, comments allowed. Existing environment variables win, so a
    shell that has already sourced the real file is not overridden."""
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            name, value = line.split("=", 1)
            name, value = name.strip(), value.strip().strip('"').strip("'")
            if name and name not in os.environ:
                os.environ[name] = value


def required(name, *fallbacks):
    for candidate in (name,) + fallbacks:
        value = os.environ.get(candidate, "").strip()
        if value:
            return value
    raise SystemExit(
        f"{name} is not set. Put it in the environment or pass --env-file.")


def main():
    global PUBLISHABLE_KEY

    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env-file", help="KEY=VALUE file to read the credentials from")
    parser.add_argument("--no-auth", action="store_true",
                        help="skip the signed-in checks (no probe account is created)")
    parser.add_argument("--require-sql", action="store_true",
                        help="treat the SQL checks being unavailable as a failure")
    args = parser.parse_args()

    if args.env_file:
        load_env_file(args.env_file)

    base = required("SUPABASE_URL").rstrip("/")
    PUBLISHABLE_KEY = required("SUPABASE_PUBLISHABLE_KEY")
    secret = "" if args.no_auth else required("SUPABASE_SECRET_KEY")
    db_url = os.environ.get("SUPABASE_DB_URL_POOLED") or os.environ.get("SUPABASE_DB_URL") or ""

    print(__doc__.split("Usage:")[0].strip().splitlines()[0])
    print()
    print(f"target        {base}")
    print(f"client key    publishable ({len(PUBLISHABLE_KEY)} chars, from the environment)")
    print(f"admin key     {'present' if secret else 'not used (--no-auth)'}")
    print(f"database      {'present' if db_url else 'not set'}"
          f"{' - SQL checks skipped' if not db_url else ''}")
    print()
    print("--- HTTP, as the publishable key ---")

    client = Client(base)
    check_reads(client, "publishable_key", PUBLISHABLE_KEY, None, len(GAMES))
    check_writes(client, "publishable_key", PUBLISHABLE_KEY, None)

    before = account_counts(client, secret) if secret else {}
    print(f"        account table row counts before the run: {before}")

    probe_id, probe_created = None, False
    if not args.no_auth:
        print()
        print("--- HTTP, as a signed-in collector ---")
        probe_id, token, probe_email = make_probe_user(client, secret)
        probe_created = True
        print(f"        probe account created and signed in: {probe_email} "
              f"(id {probe_id[:8]}...), to be deleted at the end")
        check_reads(client, "authenticated", PUBLISHABLE_KEY, token, len(GAMES))
        check_writes(client, "authenticated", PUBLISHABLE_KEY, token)

        print()
        print("--- HTTP, the account tables, which this work must not have touched ---")
        check_account_isolation(client, token, secret, probe_id)
    else:
        print()
        print("--- authenticated checks skipped (--no-auth) ---")

    print()
    print("--- SQL, as the owner ---")
    if not db_url:
        skip("sql_checks", "no database URL in the environment")
    elif not shutil.which("psql"):
        skip("sql_checks", "psql is not on PATH")
    else:
        url, rewritten = session_url(db_url)
        if rewritten:
            print("        using the session pooler (port 5432) rather than the "
                  "runtime transaction pooler (6543)")
        check_sql(url, len(GAMES))

    if probe_created:
        delete_probe_user(client, secret, probe_id)
        print()
        print(f"probe account {probe_id[:8]}... deleted")
        check_no_leftovers(client, secret, probe_id, before)
    cleanup_probe_rows(client, secret)

    passed = sum(1 for status, _, _ in RESULTS if status == "PASS")
    failed = sum(1 for status, _, _ in RESULTS if status == "FAIL")
    skipped = sum(1 for status, _, _ in RESULTS if status == "SKIP")
    print()
    print(f"{passed} passed, {failed} failed, {skipped} skipped")
    if skipped and args.require_sql:
        print("a skip was treated as a failure because --require-sql was given")
        failed += skipped
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())


