#!/usr/bin/env python3
"""Prove that a dump can be put back.

The backup's own proof reads a dump back and shows that the rows in it would
insert into a copy of the table. This one does the thing that has never been
done: it makes a collector's rows disappear, restores them from the dump with
tool/account/restore_accounts.py - the tool, run as the tool - and reads the
tables afterwards to see whether the account came back whole.

Nothing in here touches a real collector's rows, and that is the whole design.
The account tables point at auth.users, so a restore needs an account that
exists; this proof therefore creates one, writes a small account into it the way
a client does, dumps the project, deletes the account's rows, restores them, and
then deletes the account. The owner's own rows are fingerprinted before and
after, so "the probe account came back" and "nobody else was touched" are both
measurements rather than hopes.

What it is really checking, beyond the tool working:

  * **deck_cards is in the dump at all.** Until 2026-09-21 the dump held two
    tables and a restore would have given every collector their decks back with
    none of their cards in them. A version-1 dump is a dump with no deck cards
    in it, and this proof asserts that the dump it restores from is a version 2
    one that holds all three.
  * **A tombstone comes back a tombstone.** The dump carries soft-deleted rows
    with their `deleted_at`, and a restore that dropped or resurrected them would
    put a card back in a collection its owner removed.
  * **A dry run changes nothing.** The tool's default is to plan the restore
    inside a transaction that is rolled back; this reads the tables either side
    of that run and compares.

Credentials come from the environment, or from a KEY=VALUE file named with
--env-file. They are never printed, and nothing in this file holds a secret.

  SUPABASE_DB_URL_POOLED   required - the session pooler, port 5432
  SUPABASE_URL             required for the probe account
  SUPABASE_SECRET_KEY      required for the probe account
  SUPABASE_PUBLISHABLE_KEY required for the probe account's session

Without the last three the proof skips itself and says so rather than pretending
the restore was checked.

Usage:
  set -a; . /home/zixen/arcanum/supabase.env; set +a
  python3 tool/account/prove_account_restore.py

Exit status is 0 only if nothing failed.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
for _candidate in (os.path.dirname(HERE), HERE):
    if _candidate not in sys.path:
        sys.path.insert(0, _candidate)
import backup_accounts as backup  # noqa: E402
import catalog_store  # noqa: E402

# The marker every probe row carries, so a cleanup that misses one is visible
# rather than invisible: nothing a collector owns is called zz-probe.
GAME = "zz-probe"

# The three tables, in the order the dump lists them.
TABLES = backup.TABLES

PROBE_HOLDING = "zz-probe-card"
PROBE_DECK_SYNC = "00000000-0000-4000-8000-0000000000c1"

RESULTS = []


def record(status, name, detail):
    RESULTS.append((status, name, detail))
    print("%-4s  %s" % (status, name))
    for line in detail.splitlines():
        print("      " + line)
    sys.stdout.flush()


def ok(name, detail):
    record("PASS", name, detail)


def bad(name, detail):
    record("FAIL", name, detail)


def skip(name, detail):
    record("SKIP", name, detail)


def psql(db_url, sql, want_json=False):
    """psql as the owner, one statement, its lines back."""
    if want_json:
        sql = "select coalesce(json_agg(x), '[]'::json) from (" + sql + ") x;"
    rows = backup.psql_lines(db_url, sql)
    if want_json:
        return json.loads(rows[0]) if rows else []
    return rows


def http(method, url, headers, body=None):
    """One HTTP call, its status and its decoded body."""
    payload = None
    if body is not None:
        payload = json.dumps(body).encode("utf-8")
    request = urllib.request.Request(url, data=payload, method=method,
                                     headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=60) as answer:
            raw = answer.read().decode("utf-8", "replace")
            return answer.status, (json.loads(raw) if raw.strip() else None)
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        try:
            return exc.code, json.loads(raw)
        except ValueError:
            return exc.code, raw
    except Exception as exc:  # noqa: BLE001 - reported by the caller
        return 0, str(exc)


def fingerprint_of(db_url, table, where=""):
    """The md5 of a table's rows, rendered the way the dump renders them."""
    columns = backup.columns_of(db_url, table)
    pairs = ", ".join(backup.sql_text(c) + ", " + backup.quote_ident(c) + "::text"
                      for c in columns)
    clause = (" where " + where) if where else ""
    rows = psql(db_url,
                "select json_build_object(" + pairs + ")::text"
                " from public." + backup.quote_ident(table) + clause + " order by 1;")
    return backup.rows_fingerprint({table: [json.loads(r) for r in rows if r.strip()]})


def probe_account(url, secret, publishable):
    """A real account for the probe rows to belong to, and a session for it.

    public.decks.user_id is a foreign key to auth.users, so a uuid out of the air
    cannot own a deck: the account has to exist. It is deleted at the end, and the
    email is stamped so two runs cannot collide.
    """
    email = "zz-restore-probe-%d@example.com" % int(time.time())
    password = base64.b64encode(os.urandom(24)).decode().replace("/", "x")
    status, body = http("POST", url + "/auth/v1/admin/users",
                        {"apikey": secret, "Authorization": "Bearer " + secret,
                         "Content-Type": "application/json"},
                        {"email": email, "password": password,
                         "email_confirm": True})
    if status not in (200, 201) or not isinstance(body, dict):
        return None, None, None, None, "the probe account could not be created: %s %s" % (status, body)
    user_id = body["id"]
    status, body = http("POST", url + "/auth/v1/token?grant_type=password",
                        {"apikey": publishable, "Content-Type": "application/json"},
                        {"email": email, "password": password})
    if status != 200 or not isinstance(body, dict):
        return email, user_id, None, None, "the probe account could not sign in: %s %s" % (status, body)
    return email, user_id, body["access_token"], password, None


def write_probe_rows(url, publishable, token, user_id):
    """A small account, written the way a client writes one.

    Through PostgREST with the probe's own session rather than in SQL as the
    owner, because the rows a restore has to put back are the rows the app
    writes: the column defaults, the policy's WITH CHECK and the tombstone the
    client stamps are all part of what has to survive a round trip.
    """
    headers = {"apikey": publishable, "Authorization": "Bearer " + token,
               "Content-Type": "application/json", "Prefer": "return=minimal"}
    stamps = "2026-01-0%dT0%d:00:00Z"
    holdings = [
        {"game": GAME, "card_id": PROBE_HOLDING, "finish": "nonfoil",
         "condition": "NM", "language": "en", "quantity": 4,
         "purchase_price": 12.34, "purchase_date": "2026-01-01", "binder": "box 1"},
        {"game": GAME, "card_id": PROBE_HOLDING + "-two", "finish": "foil",
         "condition": "LP", "language": "en", "quantity": 1,
         "purchase_price": 0.05, "purchase_date": "2026-01-02", "for_trade": True},
        {"game": GAME, "card_id": PROBE_HOLDING + "-gone", "finish": "nonfoil",
         "condition": "NM", "language": "en", "quantity": 2,
         "purchase_price": 3.5, "purchase_date": "2026-01-03",
         "deleted_at": stamps % (4, 4)},
    ]
    for row in holdings:
        status, body = http("POST", url + "/rest/v1/collection_entries", headers, row)
        if status not in (200, 201, 204):
            return "a holding would not write: %s %s" % (status, body)

    status, body = http("POST", url + "/rest/v1/decks", headers,
                        {"game": GAME, "name": "zz-probe deck",
                         "sync_id": PROBE_DECK_SYNC, "format_id": "commander",
                         "notes": "written by the restore proof"})
    if status not in (200, 201, 204):
        return "the deck would not write: %s %s" % (status, body)

    lines = [
        {"game": GAME, "deck_sync_id": PROBE_DECK_SYNC, "card_id": PROBE_HOLDING,
         "board": "main", "quantity": 4, "sort": 1, "category": "Ramp"},
        {"game": GAME, "deck_sync_id": PROBE_DECK_SYNC,
         "card_id": PROBE_HOLDING + "-two", "board": "side", "quantity": 2,
         "sort": 2, "category": "Removal"},
        {"game": GAME, "deck_sync_id": PROBE_DECK_SYNC,
         "card_id": PROBE_HOLDING + "-gone", "board": "main", "quantity": 1,
         "sort": 3, "deleted_at": stamps % (5, 5)},
    ]
    for row in lines:
        status, body = http("POST", url + "/rest/v1/deck_cards", headers, row)
        if status not in (200, 201, 204):
            return "a deck line would not write: %s %s" % (status, body)
    return None


def wipe_probe_rows(db_url, user_id):
    """The loss the restore is for: the account's rows are gone."""
    for table in ("deck_cards", "decks", "collection_entries"):
        psql(db_url, "delete from public." + backup.quote_ident(table)
             + " where user_id = " + backup.sql_text(user_id) + ";")


def run_tool(args, dump, email, apply_it):
    """The tool, run as the tool: a subprocess, its exit status and its words."""
    command = [sys.executable, os.path.join(HERE, "restore_accounts.py"),
               "--from", dump, "--out-dir", os.path.dirname(dump),
               "--user", email]
    if args.env_file:
        command += ["--env-file", args.env_file]
    if apply_it:
        command.append("--apply")
    done = subprocess.run(command, capture_output=True, text=True, timeout=600,
                          env=os.environ, cwd=os.path.dirname(HERE))
    return done.returncode, (done.stdout or "") + (done.stderr or "")


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="prove a dump can be put back, with the tool that puts it back")
    ap.add_argument("--env-file", default=None,
                    help="a KEY=VALUE file to read the credentials from")
    args = ap.parse_args(argv)

    if args.env_file and os.path.exists(args.env_file):
        backup.load_env_file(args.env_file)

    db_url = os.environ.get("SUPABASE_DB_URL_POOLED") or os.environ.get("SUPABASE_DB_URL")
    url = (os.environ.get("SUPABASE_URL") or "").rstrip("/")
    secret = os.environ.get("SUPABASE_SECRET_KEY") or ""
    publishable = os.environ.get("SUPABASE_PUBLISHABLE_KEY") or ""
    if not db_url:
        print("this proof needs SUPABASE_DB_URL_POOLED: it restores into the live "
              "project", file=sys.stderr)
        return 2
    if not (url and secret and publishable):
        skip("a_dump_can_be_put_back",
             "SUPABASE_URL, SUPABASE_SECRET_KEY or SUPABASE_PUBLISHABLE_KEY is not "
             "set, so no probe account can be made - and the account tables point "
             "at auth.users, so there is no other account a restore could be "
             "measured against without touching a real collector's rows")
        print("0 passed, 0 failed, 1 skipped")
        return 0

    print("Restore an account from a dump, and read the tables afterwards.")
    print("")
    print("target   %s and the three account tables" % ("the session pooler"))
    print("")

    email = user_id = token = None
    created = None
    workdir = tempfile.mkdtemp(prefix="arcanum-restore-proof-")
    owner_before = {}
    try:
        email, user_id, token, _password, problem = probe_account(url, secret, publishable)
        if problem:
            bad("a_dump_can_be_put_back", problem)
            return 1
        created = user_id

        problem = write_probe_rows(url, publishable, token, user_id)
        if problem:
            bad("a_dump_can_be_put_back", problem)
            return 1

        # The owner's own rows, fingerprinted so "nobody else was touched" is a
        # measurement. zz-probe rows are excluded: they are the ones being moved.
        for table in TABLES:
            owner_before[table] = fingerprint_of(
                db_url, table, "game <> " + backup.sql_text(GAME))

        print("--- The dump ---")
        record_ = backup.write_dump(db_url, workdir)
        header, dumped = backup.read_dump(record_["path"])
        mine = {table: [row for row in dumped.get(table, [])
                        if row.get("user_id") == user_id] for table in TABLES}
        counts = ", ".join("%d %s" % (len(mine[table]), table) for table in TABLES)
        if header.get("version") != backup.FORMAT_VERSION or len(header["tables"]) != len(TABLES):
            bad("a_dump_holds_every_table_of_the_account",
                "the dump is version %s and holds %s, where this reader writes "
                "version %s with %s - a dump missing a table is a restore missing "
                "a table" % (header.get("version"), ", ".join(header["tables"]),
                             backup.FORMAT_VERSION, ", ".join(TABLES)))
        elif any(not mine[table] for table in TABLES):
            bad("a_dump_holds_every_table_of_the_account",
                "the probe account's rows are not all in the dump: " + counts)
        else:
            ok("a_dump_holds_every_table_of_the_account",
               "%s - the probe account, written as a client writes one, inside a "
               "version %s dump of every account"
               % (counts.replace("collection_entries", "holding(s)")
                       .replace("decks", "deck(s)").replace("deck_cards", "line(s)"),
                  header.get("version")))

        print("")
        print("--- The loss, and the plan ---")
        wipe_probe_rows(db_url, user_id)
        left = {table: len(psql(db_url, "select 1 from public." + backup.quote_ident(table)
                                + " where user_id = " + backup.sql_text(user_id)))
                for table in TABLES}
        if any(left.values()):
            bad("the_rows_are_gone_before_the_restore",
                "the probe account still holds %s after the wipe" % left)
        else:
            ok("the_rows_are_gone_before_the_restore",
               "every row the probe account had is gone, which is the state a "
               "restore is for")

        code, words = run_tool(args, record_["path"], email, apply_it=False)
        planned = [line for line in words.splitlines() if "inserted" in line]
        if code != 0 or len(planned) != len(TABLES):
            bad("the_plan_says_what_a_restore_would_change",
                ("the tool exited %d without planning all %d tables:"
                 % (code, len(TABLES))) + chr(10) + words)
        else:
            ok("the_plan_says_what_a_restore_would_change",
               "; ".join(line.strip() for line in planned))

        after_plan = {table: len(psql(db_url, "select 1 from public."
                                      + backup.quote_ident(table)
                                      + " where user_id = " + backup.sql_text(user_id)))
                      for table in TABLES}
        if any(after_plan.values()):
            bad("a_dry_run_leaves_the_tables_alone",
                "the dry run left %s, where the account had nothing" % after_plan)
        elif "dry run" not in words:
            bad("a_dry_run_leaves_the_tables_alone",
                "the tool did not say it was a dry run:" + chr(10) + words)
        else:
            ok("a_dry_run_leaves_the_tables_alone",
               "the plan ran inside a transaction that was rolled back and the "
               "account still holds nothing, which is what the tool's own dry run "
               "asserts of itself")

        print("")
        print("--- The restore ---")
        code, words = run_tool(args, record_["path"], email, apply_it=True)
        if code != 0:
            bad("a_restore_puts_the_rows_back",
                ("the tool exited %d:" % code) + chr(10) + words)
        else:
            problems = []
            for table in TABLES:
                restored = fingerprint_of(db_url, table,
                                          "user_id = " + backup.sql_text(user_id))
                wanted = backup.rows_fingerprint({table: mine[table]})
                if restored != wanted:
                    problems.append("%s came back different (md5 %s against %s)"
                                    % (table, restored[:8], wanted[:8]))
            if problems:
                bad("a_restore_puts_the_rows_back", chr(10).join(problems))
            else:
                ok("a_restore_puts_the_rows_back",
                   "all three tables hash to the value the dump holds them at: "
                   "%s, row for row, over every column"
                   % ", ".join("%d %s" % (len(mine[table]), table) for table in TABLES))

        tombstones = psql(db_url,
                          "select json_build_object('table', 'collection_entries', "
                          "'deleted_at', deleted_at::text)::text from public.collection_entries "
                          "where user_id = " + backup.sql_text(user_id)
                          + " and deleted_at is not null"
                          " union all "
                          "select json_build_object('table', 'deck_cards', 'deleted_at', "
                          "deleted_at::text)::text from public.deck_cards "
                          "where user_id = " + backup.sql_text(user_id)
                          + " and deleted_at is not null;", want_json=False)
        wanted_tombstones = sorted(
            row["deleted_at"] for table in TABLES for row in mine[table]
            if row.get("deleted_at"))
        got_tombstones = sorted(json.loads(line)["deleted_at"] for line in tombstones
                                if line.strip())
        if got_tombstones != wanted_tombstones or not wanted_tombstones:
            bad("a_restored_tombstone_is_still_deleted",
                "the dump holds %s and the tables hold %s - a restored row that "
                "lost its deleted_at is a card put back in a collection its owner "
                "removed" % (wanted_tombstones, got_tombstones))
        else:
            ok("a_restored_tombstone_is_still_deleted",
               "%d soft-deleted row(s) came back soft-deleted with the timestamps "
               "the dump carries: %s"
               % (len(got_tombstones), ", ".join(got_tombstones)))

        lines_back = len(psql(db_url, "select 1 from public.deck_cards where user_id = "
                               + backup.sql_text(user_id)))
        if lines_back != len(mine["deck_cards"]):
            bad("a_decks_lines_come_back",
                "%d of the deck's %d line(s) came back" % (lines_back,
                                                           len(mine["deck_cards"])))
        else:
            ok("a_decks_lines_come_back",
               "the deck's %d line(s) came back, which is the hole this whole "
               "change closes: a dump that held two tables would have restored "
               "the deck's name and none of its cards" % lines_back)

        print("")
        print("--- Nothing else moved ---")
        problems = []
        for table in TABLES:
            after = fingerprint_of(db_url, table, "game <> " + backup.sql_text(GAME))
            if after != owner_before[table]:
                problems.append("%s changed" % table)
        if problems:
            bad("another_accounts_rows_are_untouched",
                "the restore reached past the account it was told to restore: "
                + ", ".join(problems))
        else:
            ok("another_accounts_rows_are_untouched",
               "every other account's rows in all three tables hash to what they "
               "hashed to before the restore, so a restore scoped to one collector "
               "stayed inside that collector")

    finally:
        # The test must not be the thing that leaves a mess behind. The lines go
        # first because they point at the deck, then the deck, then the holdings,
        # then the account itself.
        try:
            if created:
                wipe_probe_rows(db_url, created)
                http("DELETE", url + "/auth/v1/admin/users/" + created,
                     {"apikey": secret, "Authorization": "Bearer " + secret})
            shutil.rmtree(workdir, ignore_errors=True)
        except Exception as exc:  # noqa: BLE001 - reported below, never raised
            print("cleanup had trouble: %s" % exc)

    print("")
    print("--- Nothing left behind ---")
    left = []
    for table in TABLES:
        rows = psql(db_url, "select 1 from public." + backup.quote_ident(table)
                    + " where game = " + backup.sql_text(GAME))
        if rows:
            left.append("%s: %d row(s)" % (table, len(rows)))
    accounts = psql(db_url, "select 1 from auth.users where email like 'zz-restore-probe-%'")
    if accounts:
        left.append("%d probe account(s) still registered" % len(accounts))
    if left:
        bad("nothing_is_left_behind", chr(10).join(left))
    else:
        ok("nothing_is_left_behind",
           "no probe row in any of the three tables and no probe account in "
           "auth.users")

    passed = sum(1 for status, _, _ in RESULTS if status == "PASS")
    failed = sum(1 for status, _, _ in RESULTS if status == "FAIL")
    skipped = sum(1 for status, _, _ in RESULTS if status == "SKIP")
    print("")
    print("%d passed, %d failed, %d skipped" % (passed, failed, skipped))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
