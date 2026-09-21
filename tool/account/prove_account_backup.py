#!/usr/bin/env python3
"""Prove the account dump can be read back, and that what it holds is the account.

The claim this file tests is not that a file appears in the backups directory.
It is that the file is a *backup*: that it can be read back by something other
than the code that wrote it, that every column of both tables is in it, that the
removals it is supposed to preserve are in it, and that the rows it holds are
the rows the database holds - measured, in one run, from both ends. A backup
that has never been read back is not a backup; it is a file that looks like one.

Seven checks, and no one of them implies another:

| Check | Why it is not implied by the others |
| --- | --- |
| The dump parses, every line is JSON, and the rows are the number the header claims | a truncated gzip is caught by gzip, but a file that lost its tail to a full disk is not |
| Every column of both tables is in every dumped row | the columns are read from information_schema in this run, so a column added later and dropped from the dump is caught instead of being discovered by a restore |
| A tombstone in the database is in the dump with the same deleted_at | the deleted rows are the ones a dump is most likely to have been told to skip, and skipping them resurrects every card somebody removed |
| The dump's rows and the live rows render to one md5 | reading a file back proves the file is readable, not that it says what the database says |
| The dumped rows insert into the table's own shape and match the live rows row for row | a text form that does not round-trip - a numeric, a timestamp - reads back fine and restores wrong |
| Rotation keeps the newest dump, and keeps a dump that did not verify | deleting the file just written, or the evidence of a failure, is a backup destroyed by its own housekeeping |
| --verify-only, run as the monitoring job runs it, agrees with a fresh dump | the monitor is a second reader of the same file, and it is the one nobody watches |

Credentials come from the environment, or from a KEY=VALUE file named with
--env-file. They are never printed, and nothing in this file holds a secret.

  SUPABASE_DB_URL_POOLED   required - the session pooler, port 5432

Usage:
  set -a; . /home/zixen/arcanum/supabase.env; set +a
  python3 tool/account/prove_account_backup.py

  # Against the newest dump already on disk, without taking another:
  python3 tool/account/prove_account_backup.py --no-dump

Every check here needs the live database. A file that cannot reach one says so
and fails; nothing is skipped quietly, and --require-db turns the one skip that
is legitimate - a database with no tombstones in it has no tombstone to check -
into a failure as well.

Exit status is 0 only if nothing failed.
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

# The same two-directory import backup_accounts makes, and for the same reason:
# from a repository checkout the module is one level up (tool/account ->
# tool/), and on the host the two scripts run flat beside the current
# catalog_store.py.
HERE = os.path.dirname(os.path.abspath(__file__))
for _candidate in (os.path.dirname(HERE), HERE):
    if _candidate not in sys.path:
        sys.path.insert(0, _candidate)
import catalog_store  # noqa: E402
import backup_accounts  # noqa: E402

TIMEOUT = 600.0

# The tables the dump is supposed to hold, taken from the module rather than
# written down twice. A third table added there is a table these checks
# immediately start requiring, and one removed there is one they stop
# requiring - either way there is one list.
TABLES = backup_accounts.TABLES

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


def verdict(name, problems, detail):
    """PASS when there is nothing wrong, FAIL when there is, SKIP when blind."""
    if problems:
        bad(name, "\n".join(problems))
    else:
        ok(name, detail)


# ---------------------------------------------------------------------------
# Reading the database, as the owner
# ---------------------------------------------------------------------------


def psql_lines(db_url, sql, timeout=TIMEOUT):
    """One script, one line per row, nothing taken on trust.

    Raw lines rather than a field-separated reading: a row's JSON is one line
    and a text column may legitimately contain any separator this might have
    chosen, so the only safe delimiter is the newline JSON escaping guarantees.

    The URL is split into the variables libpq reads from the environment and
    never passed as an argument, so the password is not visible to ps while a
    statement runs.
    """
    proc = subprocess.run(
        ["psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-f", "-"],
        input=sql, capture_output=True, text=True, timeout=timeout,
        env=catalog_store.psql_environment(db_url))
    if proc.returncode != 0:
        raise RuntimeError(f"psql: {proc.stderr.strip()[:600]}")
    return [line for line in proc.stdout.splitlines() if line != ""]


def sql_literal(value):
    """One Python value as a SQL literal. None becomes null, not the word."""
    if value is None:
        return "null"
    return "'" + str(value).replace("'", "''") + "'"


def quoted(column):
    return '"' + str(column).replace('"', '""') + '"'


def live_columns(db_url, table):
    """The live columns of one table, in the order the table stores them."""
    return psql_lines(db_url,
                      "select column_name from information_schema.columns"
                      " where table_schema = 'public'"
                      f" and table_name = {sql_literal(table)}"
                      " order by ordinal_position")


def live_rows(db_url, table, columns):
    """Every live row, rendered the way a dump renders one.

    The statement here is this file's own - the same json_build_object over the
    columns this file read from information_schema a moment ago - rather than
    the dump's generator, so that the comparison below is between the database
    and the file, and not between the dump's query and itself. Each value is
    cast to text for the reason the dump casts it: numeric and timestamptz have
    no exact JSON form.
    """
    pairs = ", ".join(f"{sql_literal(column)}, {quoted(column)}::text"
                      for column in columns)
    sql = ("begin isolation level repeatable read read only;\n"
           "set local time zone 'UTC';\n"
           f"select json_build_object({pairs})::text from public.{quoted(table)}"
           " order by 1;\n"
           "commit;")
    return [json.loads(line) for line in psql_lines(db_url, sql)]


def readings(lines):
    """Every NAME=value line as one dictionary, first '=' splitting them.

    A value that itself contains '=' survives: the name ends at the first one.
    """
    out = {}
    for line in lines:
        name, sep, value = line.partition("=")
        if sep:
            out[name] = value
    return out


# ---------------------------------------------------------------------------
# The dump
# ---------------------------------------------------------------------------


def take_fresh_dump(args):
    """Runs the command the timer runs, and returns (path, what it printed).

    The command line rather than the module's internals, because what the timer
    executes is the thing being proved - and because the one line it prints is
    a promise the monitoring job and a person both read.

    The state file and the lock are pointed at this proof's own temporary
    paths: a proof run must not overwrite the record of the run the monitor
    reads, and it must not be refused because the timer happens to hold the
    lock at that moment.
    """
    state = os.path.join(tempfile.mkdtemp(prefix="arcanum-backup-proof-"), "state.json")
    lock = os.path.join(tempfile.gettempdir(), "arcanum-account-backup-proof.lock")
    command = [sys.executable, os.path.join(HERE, "backup_accounts.py"),
               "--out-dir", args.dump_dir, "--state", state, "--lock", lock,
               "--timeout", str(args.timeout)]
    proc = subprocess.run(command, capture_output=True, text=True, timeout=args.timeout + 60)
    if proc.returncode != 0:
        return None, f"exited {proc.returncode}: {proc.stderr.strip()[:300]}"
    printed = proc.stdout.strip()
    if "\n" in printed or not printed.startswith("wrote "):
        return None, f"printed {printed!r}, which is not the one line it promises"
    path = printed.split()[1].rstrip(",")
    if not os.path.exists(path):
        return None, f"printed {path}, which is not on disk"
    return path, printed


def check_dump_reads_back(path):
    """The dump parses, every line is JSON, and the rows are the number claimed.

    Read here rather than through backup_accounts.read_dump on purpose: a file
    read back by the function that wrote it agrees with itself by construction,
    and the question is whether the file is readable at all. The module's own
    reader is exercised separately, by the --verify-only command line below.
    """
    header = None
    rows = {}
    problems = []
    physical = 0
    try:
        with gzip.open(path, "rt", encoding="utf-8") as handle:
            for number, line in enumerate(handle, 1):
                physical = number
                text = line.rstrip("\n")
                if not text.strip():
                    problems.append(f"line {number} is blank")
                    continue
                try:
                    item = json.loads(text)
                except ValueError as exc:
                    problems.append(f"line {number} is not JSON: {exc}")
                    continue
                if header is None:
                    if not isinstance(item, dict):
                        problems.append("the first line is not a JSON object")
                        header = {}
                    else:
                        header = item
                    for table in header.get("tables") or []:
                        rows.setdefault(table, [])
                    continue
                table = item.get("table") if isinstance(item, dict) else None
                if table not in rows or not isinstance(item.get("row"), dict):
                    problems.append(
                        f"line {number} is not a row of a table the header names")
                    continue
                rows[table].append(item["row"])
    except (OSError, EOFError) as exc:
        bad("the_dump_reads_back", f"{path} did not decompress: {exc}")
        return None, None

    for table in TABLES:
        if table not in rows:
            problems.append(f"the header does not list public.{table}")
            continue
        claimed = header.get("rows", {}).get(table)
        if claimed != len(rows[table]):
            problems.append(f"the header claims {claimed} {table} rows and the file "
                            f"holds {len(rows[table])}")

    total = sum(len(found) for found in rows.values())
    if physical != total + 1:
        problems.append(f"the file holds {physical} lines, which is not one header "
                        f"and {total} rows")

    detail = (f"{os.path.basename(path)}: {physical} lines, {total} rows, "
              + ", ".join(f"{len(rows.get(table, []))} {table}" for table in TABLES)
              + " - every line valid JSON and every count equal to the header's")
    verdict("the_dump_reads_back", problems, detail)
    return header, rows


def check_every_column(db_url, header, rows):
    """Every column of both tables is in every dumped row.

    The comparison is against information_schema read in this run, in both
    directions: a column the live table has and the dump does not is a column
    silently lost, and a column the dump has and the table does not is a header
    describing a table this file has never seen. Either one makes a restore
    wrong, and neither is visible by reading the dump alone.
    """
    problems = []
    detail = []
    for table in TABLES:
        live = live_columns(db_url, table)
        if not live:
            problems.append(f"public.{table} has no columns in information_schema, "
                            "so the dump cannot be compared with it")
            continue
        claimed = (header.get("columns") or {}).get(table)
        if claimed != live:
            problems.append(f"{table}: the header lists {claimed}, the live table "
                            f"has {live}")
            continue
        offenders = [index for index, row in enumerate(rows.get(table, []), 1)
                     if set(row) != set(live)]
        if offenders:
            problems.append(f"{table}: {len(offenders)} row(s) do not carry all "
                            f"{len(live)} columns, first at row {offenders[0]}")
            continue
        detail.append(f"{table}: {len(live)} columns, present in all "
                      f"{len(rows.get(table, []))} row(s)")
    verdict("every_column_of_both_tables_is_in_every_row", problems,
            "; ".join(detail))


def check_tombstones(db_url, rows, require):
    """A row the database calls deleted is in the dump, still deleted.

    The check that stops a restore from resurrecting cards. The live side is
    asked for the id and the timestamp only, because those are what "the same
    tombstone" means; the dump side is the row as it was written out.
    """
    # One line per tombstone, "id|deleted_at", read straight rather than through
    # readings(): every line would carry the same name and the dictionary would
    # keep only the last of them - which is how this check first reported six
    # tombstones in the database as one, with a passing fingerprint beside it.
    live = psql_lines(
        db_url,
        "select id::text || '|' || coalesce(deleted_at::text, 'null')"
        "  from public.collection_entries"
        " where deleted_at is not null order by id")
    if not live:
        (bad if require else skip)(
            "tombstones_survive",
            "the database holds no row with a deleted_at, so there is no "
            "tombstone to look for and this check cannot be made. It is not "
            "evidence that the dump would keep one - only a database with a "
            "removal in it can say that")
        return

    found = {row.get("id"): row.get("deleted_at") for row in rows.get("collection_entries", [])}
    problems = []
    for line in live:
        entry_id, _, deleted_at = line.partition("|")
        if entry_id not in found:
            problems.append(f"tombstone {entry_id[:8]}... is in the database and not "
                            "in the dump")
        elif found[entry_id] != deleted_at:
            problems.append(f"tombstone {entry_id[:8]}... reads {found[entry_id]!r} in "
                            f"the dump and {deleted_at!r} in the database")
    dumped_tombstones = sum(1 for value in found.values() if value is not None)
    if dumped_tombstones != len(live):
        problems.append(f"the database holds {len(live)} tombstone(s) and the dump "
                        f"holds {dumped_tombstones}")
    verdict("tombstones_survive", problems,
            f"all {len(live)} soft-deleted holding(s) are in the dump with the same "
            "deleted_at, so a restore cannot put a removed card back")


def check_restore_fingerprint(dumped, live, path):
    """What was dumped and what is in the database render to one value.

    This is the check the rest of the file rests on. Both sides are rendered by
    the same rule - backup_accounts.rows_fingerprint, over rows whose values are
    already the text Postgres produced - and the two readings are taken in the
    same run, so a row added between them is the only thing that can make them
    differ. The rule itself cannot hide a column: the fingerprint is over the
    whole row object, and the check above has already established that the row
    objects carry every live column.
    """
    dumped_fp = backup_accounts.rows_fingerprint({table: dumped[table] for table in TABLES})
    live_fp = backup_accounts.rows_fingerprint({table: live[table] for table in TABLES})
    total = sum(len(live[table]) for table in TABLES)
    if dumped_fp == live_fp:
        ok("a_restore_of_the_dump_is_the_live_account",
           f"{os.path.basename(path)} and the live tables hash to the same value: "
           f"md5 {dumped_fp} over {total} row(s) "
           + ", ".join(f"{len(live[table])} {table}" for table in TABLES))
    else:
        bad("a_restore_of_the_dump_is_the_live_account",
            f"the dumped rows hash to {dumped_fp} and the live rows to {live_fp}: "
            "the file does not hold what the database holds")


def check_restore_round_trip(db_url, columns_by_table, dumped, live):
    """The dumped rows, put back into the table's own shape, row for row.

    The fingerprint above compares two renderings of the same text. This asks
    the database the harder question: are these text values the table's own
    values, once Postgres is made to read them as the column types they belong
    to? A numeric that lost precision, a timestamp in an unreadable form or a
    boolean written as 1 instead of true would all survive the fingerprint (both
    sides carry the same text) and fail here.

    Everything happens inside a transaction that is rolled back, against
    temporary copies of the table's shape - so the account itself is never
    written to, and the check cannot be the thing that damages it. The copies
    are made with LIKE, which carries the NOT NULL constraints across and does
    not carry the identity property: decks.id is GENERATED ALWAYS AS IDENTITY,
    and a real restore has to say OVERRIDING SYSTEM VALUE, which is written
    down in docs/account-backup.md rather than here.
    """
    statements = ["begin;"]
    for table in TABLES:
        columns = columns_by_table[table]
        names = ", ".join(quoted(column) for column in columns)
        statements.append(f"create temp table restore_{table}"
                          f" (like public.{quoted(table)} including defaults);")
        values = []
        for row in dumped[table]:
            values.append("(" + ", ".join(sql_literal(row.get(column))
                                          for column in columns) + ")")
        if values:
            statements.append(f"insert into restore_{table} ({names}) values\n"
                              + ",\n".join(values) + ";")
        statements.append(f"select 'restored_{table}=' || count(*)::text"
                          f" from restore_{table};")
        # The two halves are parenthesised on purpose. EXCEPT and UNION share
        # one precedence level and associate to the left, so without them the
        # second EXCEPT would be applied to the first one's result - a
        # comparison of the live table with itself, which is always zero rows
        # and always passes.
        statements.append(
            f"select 'differs_{table}=' || count(*)::text from (("
            f"select * from restore_{table} except all select * from public.{quoted(table)})"
            " union all ("
            f"select * from public.{quoted(table)} except all select * from restore_{table})"
            ") d;")
    statements.append("rollback;")
    for table in TABLES:
        statements.append(f"select 'after_{table}=' || count(*)::text"
                          f" from public.{quoted(table)};")

    try:
        got = readings(psql_lines(db_url, "\n".join(statements)))
    except RuntimeError as exc:
        bad("the_dumped_rows_would_restore", f"the restore was refused: {exc}")
        return

    problems = []
    for table in TABLES:
        expected = len(live[table])
        if got.get(f"restored_{table}") != str(expected):
            problems.append(f"{table}: {got.get(f'restored_{table}', 'nothing')} rows were "
                            f"inserted, and the live table holds {expected}")
        if got.get(f"differs_{table}") != "0":
            problems.append(f"{table}: {got.get(f'differs_{table}')} row(s) differ "
                            "between the restored copy and the live table")
        if got.get(f"after_{table}") != str(expected):
            problems.append(f"{table}: {got.get(f'after_{table}')} rows after the "
                            f"probe, and {expected} before it")
    verdict("the_dumped_rows_would_restore", problems,
            "every dumped row was inserted as its column's own type into a copy of "
            "the table, matched the live row for row, and the transaction was rolled "
            "back with the account untouched: "
            + ", ".join(f"{len(live[table])} {table}" for table in TABLES))


# ---------------------------------------------------------------------------
# Rotation, and the monitor
# ---------------------------------------------------------------------------


def check_rotation(directory, newest):
    """Rotation deletes the old, keeps the new, and never removes a failure.

    Measured on copies in a temporary directory, because the alternative is
    measuring it on somebody's real backups. The copies are of the dump this
    run just wrote, so the reader is looking at a real dump and not at a
    fixture the rule might happen to suit.
    """
    problems = []
    try:
        with open(newest, "rb") as handle:
            body = handle.read()
    except OSError as exc:
        bad("rotation_keeps_the_newest_dump", f"could not read {newest}: {exc}")
        return

    work = tempfile.mkdtemp(prefix="arcanum-rotation-")
    try:
        stamps = ["2000-01-01T000000Z", "2000-01-02T000000Z",
                  "2000-01-03T000000Z", "2000-01-04T000000Z"]
        paths = []
        for index, stamp in enumerate(stamps):
            path = os.path.join(work, f"account-{stamp}.json.gz")
            with open(path, "wb") as handle:
                # The second one is truncated rather than whole: it is the dump
                # that did not verify, and the rule under test is that rotation
                # leaves it where it is instead of deleting the evidence.
                handle.write(body[:len(body) // 2] if index == 1 else body)
            paths.append(path)

        deleted, retired, broken = backup_accounts.rotate(work, keep=2)
        remaining = backup_accounts.dump_files(work)
        survivors = {os.path.basename(path) for path in remaining}
        if os.path.basename(paths[0]) in survivors:
            problems.append("the oldest dump survived a rotation that had room for two")
        for index in (2, 3):
            if os.path.basename(paths[index]) not in survivors:
                problems.append(f"{os.path.basename(paths[index])} was deleted although "
                                "it is one of the newest two")
        if os.path.basename(paths[1]) not in survivors:
            problems.append("the dump that does not verify was deleted: rotation "
                            "removed the only evidence that something went wrong")
        if [os.path.basename(p) for p in deleted] != [os.path.basename(paths[0])]:
            problems.append(f"rotation deleted {[os.path.basename(p) for p in deleted]}, "
                            f"expected only {os.path.basename(paths[0])}")
        if [os.path.basename(p) for p, _ in broken] != [os.path.basename(paths[1])]:
            problems.append("rotation did not report the unreadable dump as broken")

        # And the guard that is not arithmetic: with keep=0 the file it was
        # handed is a candidate, and it must still survive.
        guarded = remaining[-1]
        deleted2, retired2, broken2 = backup_accounts.rotate(work, keep=0, protect=[guarded])
        if not os.path.exists(guarded):
            problems.append("rotation with keep=0 deleted a dump it was told to protect")
        if os.path.abspath(guarded) not in {os.path.abspath(p) for p in retired2}:
            problems.append("rotation did not report the protected dump as retired")
        if [os.path.basename(p) for p, _ in broken2] != [os.path.basename(paths[1])]:
            problems.append("rotation lost track of the unreadable dump on the second pass")
    finally:
        shutil.rmtree(work, ignore_errors=True)

    # The real directory, untouched: with fewer dumps in it than KEEP there is
    # nothing for rotation to do, and the file this run wrote has to still be
    # there afterwards. If the directory ever holds more than KEEP, this says so
    # rather than deleting somebody's backups to make a point.
    live_paths = backup_accounts.dump_files(directory)
    if len(live_paths) > backup_accounts.KEEP:
        skip("rotation_keeps_the_newest_dump",
             f"{directory} holds {len(live_paths)} dumps, more than KEEP="
             f"{backup_accounts.KEEP}, so this check will not run rotation against "
             "real backups to prove a point")
        return
    deleted3, _retired3, broken3 = backup_accounts.rotate(
        directory, keep=backup_accounts.KEEP, protect=[newest])
    if deleted3:
        problems.append(f"rotation deleted {[os.path.basename(p) for p in deleted3]} "
                        f"from {directory}, which holds fewer than KEEP dumps")
    if broken3:
        problems.append(f"{[os.path.basename(p) for p, _ in broken3]} in {directory} "
                        "does not verify")
    if not os.path.exists(newest):
        problems.append("the dump this run wrote is not on disk after rotation")

    verdict("rotation_keeps_the_newest_dump", problems,
            f"KEEP={backup_accounts.KEEP}; on copies, the oldest of four went, the two "
            "newest stayed, the truncated one was kept and reported rather than "
            "deleted, and a dump named as protected survived even with keep=0; on "
            f"{directory}, with {len(live_paths)} dump(s) in it, rotation removed "
            "nothing and the file just written is still there")


def check_verify_only(args, path, header):
    """The monitoring job's command line, run against the dump just written.

    A separate process with no database access, which is the whole point of the
    mode: it is the reader that has to keep working on the night the database
    is what broke.
    """
    proc = subprocess.run(
        [sys.executable, os.path.join(HERE, "backup_accounts.py"),
         "--verify-only", "--out-dir", args.dump_dir],
        capture_output=True, text=True, timeout=args.timeout + 60)
    if proc.returncode != 0:
        bad("verify_only_agrees_with_a_fresh_dump",
            f"--verify-only exited {proc.returncode}: {proc.stderr.strip()[:300]}")
        return
    printed = proc.stdout.strip()
    newest = backup_accounts.dump_files(args.dump_dir)
    problems = []
    if not newest or os.path.basename(newest[-1]) != os.path.basename(path):
        problems.append(f"the newest dump in {args.dump_dir} is "
                        f"{os.path.basename(newest[-1]) if newest else 'nothing'}, not "
                        f"{os.path.basename(path)}")
    if os.path.basename(path) not in printed:
        problems.append(f"--verify-only printed {printed!r}, which does not name "
                        f"{os.path.basename(path)}")
    for table in TABLES:
        if f"{header['rows'][table]} {table}" not in printed:
            problems.append(f"--verify-only printed {printed!r}, which does not report "
                            f"{header['rows'][table]} {table}")
    verdict("verify_only_agrees_with_a_fresh_dump", problems,
            f"{printed!r} - the same counts the fresh dump recorded "
            f"({os.path.basename(path)})")


def check_no_credential(path, db_url):
    """The dump carries no credential. Measured, and never echoed.

    The connection string, its password and the names the credentials live
    under are looked for in the decompressed file. Only labels are printed: a
    check about a secret that prints the secret when it fails is worse than no
    check at all.
    """
    try:
        with gzip.open(path, "rb") as handle:
            text = handle.read().decode("utf-8", "replace")
    except (OSError, EOFError) as exc:
        bad("the_dump_holds_no_credential", f"could not read {path}: {exc}")
        return
    password = urlsplit(db_url).password
    suspects = [
        ("the connection's password", password),
        ("the connection string", db_url),
        ("a postgres:// URL", "postgres://"),
        ("a postgresql:// URL", "postgresql://"),
        ("the name of the credentials file", "supabase.env"),
        ("the name SUPABASE_DB_PASSWORD", "SUPABASE_DB_PASSWORD"),
    ]
    found = [label for label, needle in suspects if needle and needle in text]
    verdict("the_dump_holds_no_credential",
            [f"the dump contains {label}" for label in found],
            "the decompressed dump holds no occurrence of the connection string, its "
            "password, the credentials file's name or the names the credentials live "
            "under; what it holds is rows")


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env-file", default=None,
                        help="KEY=VALUE file to read the credentials from")
    parser.add_argument("--dump-dir", default=backup_accounts.DEFAULT_DIR,
                        help="where the dumps live (default "
                             f"{backup_accounts.DEFAULT_DIR})")
    parser.add_argument("--timeout", type=float, default=TIMEOUT)
    parser.add_argument("--no-dump", action="store_true",
                        help="read the newest dump already on disk instead of taking "
                             "a fresh one")
    parser.add_argument("--require-db", action="store_true",
                        help="treat a check that could not be made as a failure")
    return parser.parse_args(argv)


def load_env_file(path):
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            name, value = line.split("=", 1)
            name, value = name.strip(), value.strip().strip('"').strip("'")
            if name and name not in os.environ:
                os.environ[name] = value


def main(argv=None):
    args = parse_args(argv)
    if args.env_file:
        load_env_file(args.env_file)

    db_url = (os.environ.get("SUPABASE_DB_URL_POOLED")
              or os.environ.get("SUPABASE_DB_URL") or "")
    if not db_url:
        raise SystemExit("SUPABASE_DB_URL_POOLED is not set. Every check in this file "
                         "reads the live tables - the fingerprint and the tombstone "
                         "check are comparisons with the database, and a version of "
                         "this file that passed without one would be proving nothing. "
                         "Put the credentials in the environment or pass --env-file.")
    if not shutil.which("psql"):
        raise SystemExit("psql is not on PATH, so the live tables cannot be read and "
                         "nothing here can be checked.")

    print(__doc__.split("Usage:")[0].strip().splitlines()[0])
    print()
    print(f"target        {args.dump_dir} and the session pooler in "
          "SUPABASE_DB_URL_POOLED")
    print()

    print("--- The dump, taken and read back ---")
    printed = None
    if args.no_dump:
        existing = backup_accounts.dump_files(args.dump_dir)
        if not existing:
            bad("a_fresh_dump_can_be_taken",
                f"--no-dump was asked for and {args.dump_dir} holds no dump")
            path = None
        else:
            path = existing[-1]
            skip("a_fresh_dump_can_be_taken",
                 f"--no-dump: reading {os.path.basename(path)}, which is the newest "
                 "dump on disk rather than one taken by this run")
    else:
        path, printed = take_fresh_dump(args)
        if path is None:
            bad("a_fresh_dump_can_be_taken", str(printed))
        else:
            ok("a_fresh_dump_can_be_taken",
               f"the backup ran as the timer runs it and printed one line: {printed}")

    if path is None:
        for name in ("the_dump_reads_back", "every_column_of_both_tables_is_in_every_row",
                     "tombstones_survive", "a_restore_of_the_dump_is_the_live_account",
                     "the_dumped_rows_would_restore", "rotation_keeps_the_newest_dump",
                     "verify_only_agrees_with_a_fresh_dump"):
            (bad if args.require_db else skip)(name, "there is no dump to read")
        return 1

    header, dumped = check_dump_reads_back(path)
    if header is None or dumped is None:
        return 1

    print()
    print("--- The dump against the live tables ---")
    check_every_column(db_url, header, dumped)
    check_tombstones(db_url, dumped, args.require_db)

    columns = {table: live_columns(db_url, table) for table in TABLES}
    live = {table: live_rows(db_url, table, columns[table]) for table in TABLES}
    check_restore_fingerprint(dumped, live, path)
    check_restore_round_trip(db_url, columns, dumped, live)
    check_no_credential(path, db_url)

    print()
    print("--- Rotation ---")
    check_rotation(args.dump_dir, path)

    print()
    print("--- What the monitoring job calls ---")
    check_verify_only(args, path, header)

    passed = sum(1 for status, _, _ in RESULTS if status == "PASS")
    failed = sum(1 for status, _, _ in RESULTS if status == "FAIL")
    skipped = sum(1 for status, _, _ in RESULTS if status == "SKIP")
    print()
    print(f"{passed} passed, {failed} failed, {skipped} skipped")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
