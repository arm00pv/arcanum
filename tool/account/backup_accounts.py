#!/usr/bin/env python3
"""The account tables, dumped nightly to a file somebody could restore from.

The hole this closes. A collector's vault lives in the project's Supabase
Postgres - `public.collection_entries`, `public.decks` and `public.deck_cards`,
behind row level security - and until this file existed nothing anywhere held a
copy of it. The companion has archived the *phone's* database since it shipped,
one archive per upload, and /home/zixen/arcanum/backups is full of them; none of
those archives is the account. They are written by the phone, out of its own
SQLite, and they describe the device rather than the tables the web build reads.
The free plan has no point-in-time recovery, so a bad delete, a dropped table or
a lost project takes every account's collection with it and there is no second
copy to fall back on. This script is that second copy.

What it writes. One gzipped file of newline-delimited JSON per run, in
/home/zixen/arcanum/backups, named `account-<UTC stamp>.json.gz` the way the
phone's archives are named `arcanum-backup-<UTC stamp>-<device>.json.gz`. The
first line is a header recording the format, its version, the moment, both table
names, the row count of each and the columns each row carries; every line after
it is one row, `{"table": ..., "row": {...}}`, so a reader never has to know
which select it came from.

The rules this file keeps, and why each one is here:

  * **Tombstones are dumped, never filtered.** `collection_entries.deleted_at`
    is how a removal travels: a soft-deleted row is the *fact* that a card left
    the collection, and a dump that skipped those rows would restore a vault
    with cards in it that its owner deleted. There is no `where deleted_at is
    null` anywhere in this file, and the proof script checks that at least one
    tombstone in the database is in the dump with the same timestamp.

  * **One snapshot.** Both tables are read inside one repeatable-read,
    read-only transaction, so the file is a reading of the account at one
    instant rather than two readings a moment apart. The session's time zone is
    pinned to UTC inside it, because `timestamptz::text` renders in the
    session's own zone and a dump taken under another setting would carry
    different text for the same instant.

  * **The connection is never an argument.** psql is handed its connection
    through the environment by `catalog_store.libpq_environment`, exactly as
    the catalogue importer is, so a process listing shows `psql -f /tmp/...`
    and no password. The credentials come from the environment or from a
    KEY=VALUE file named with --env-file, they are never printed, and nothing
    here writes one into the dump or into a log.

  * **Atomic, and fsynced before the name is moved onto it.** The dump is built
    in a temporary file beside its destination, flushed and fsynced, and only
    then renamed. A run interrupted halfway therefore leaves a temporary file
    that no reader would mistake for a backup, and never a truncated archive
    wearing a backup's name.

  * **It is read back before anything is deleted.** Every dump is parsed from
    the file that was just written - gunzip, every line, and the header's row
    count against the lines actually there - and rotation only ever removes a
    file that verified. A dump that fails to verify is left where it is,
    because deleting the only copy of a failure is how a broken backup becomes
    invisible.

  * **Single-flight.** An exclusive flock, the same `catalog_store.single_flight`
    the importer holds, so a hand-run dump and the nightly timer cannot
    interleave. Idempotent: a second run writes a second file and rotates, and
    nothing it does depends on the state of the first.

  * **The outcome is recorded.** A small state file
    (/home/zixen/arcanum/account-backup.state.json, the shape the other jobs
    use) carries what the last run did and when it last succeeded, written on
    the failure path too, so a backup that has stopped happening is a fact
    somebody can read rather than a silence.

What this file deliberately does not do: it does not restore, because a restore
is a decision about somebody's collection - which rows, in what order, over what
is already there. The decision is a person's; the work is
tool/account/restore_accounts.py, which reads one of these dumps, says what
restoring it would change, and writes it back only when told to with `--apply`.
The recipe under both of them is written out in docs/account-backup.md. This file
only guarantees that the material to make one exists and can be read.

Usage:

    set -a; . /home/zixen/arcanum/supabase.env; set +a
    python3 tool/account/backup_accounts.py                # write a dump
    python3 tool/account/backup_accounts.py --dry-run      # count, write nothing
    python3 tool/account/backup_accounts.py --verify-only  # read the newest dump

Exit status is 0 only on success.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

# catalog_store owns the rule about how a connection reaches libpq, and it is
# deployed beside the importer, so it is imported here rather than copied: a
# second copy of a rule about credentials is a second thing to get wrong.
#
# Two directories are searched rather than one, and that is a deliberate
# departure from the pattern the other tools in tool/account/ use. They insert
# the *parent* of their own directory, which is right from a repository checkout
# (tool/account/ -> tool/) and wrong from this host, where the scripts run flat
# beside /home/zixen/arcanum/catalog_store.py. Searching the parent first keeps
# the repository layout working, and searching this file's own directory second
# keeps a flat deployment working. Whichever copy is found is checked below,
# because a stale catalog_store without libpq_environment in it would otherwise
# fail with an AttributeError that names nothing useful.
HERE = os.path.dirname(os.path.abspath(__file__))
for _candidate in (os.path.dirname(HERE), HERE):
    if _candidate not in sys.path:
        sys.path.insert(0, _candidate)
import catalog_store  # noqa: E402

# Every table the account is, in the order they are dumped, whole, for every
# user: this runs as the owner and bypasses row level security on purpose,
# because a backup that could only see one account would be a backup of one
# account.
#
# deck_cards joined on 2026-09-21, when the deck sync shipped and a deck stopped
# being a name with nothing in it. Until then this file dumped two tables, and
# the gap was invisible in the only way that matters: a restore made from one of
# those dumps would have given every collector their decks back - names, formats,
# notes and all - with none of their cards in them. A deck's contents are the
# account as much as its holdings are, so they are dumped like holdings.
TABLES = ("collection_entries", "decks", "deck_cards")

# The header's own name and version, so a reader a year from now can tell what
# it is holding and refuse what it does not understand rather than guess.
#
# The version names the tables, so a reader can say what a dump is missing
# rather than only what it holds: a version-1 dump is two tables by definition,
# and a restore from one has to be told that there are no deck cards in it.
FORMAT = "arcanum-account-dump"
FORMAT_VERSION = 2
VERSION_TABLES = {
    1: ("collection_entries", "decks"),
    2: TABLES,
}

# The naming, matching the phone's archives in the same directory
# (tool/sync_server.py BACKUP_PREFIX/BACKUP_SUFFIX/BACKUP_STAMP). The stamp is
# fixed width, which is what lets retention work on names alone.
BACKUP_PREFIX = "account-"
BACKUP_SUFFIX = ".json.gz"
BACKUP_STAMP = "%Y-%m-%dT%H%M%SZ"
BACKUP_STAMP_WIDTH = len("YYYY-MM-DDTHHMMSSZ")
INCOMING_PREFIX = ".incoming-"

# How many dumps to keep. Thirty nights is a month of history: long enough that
# a corruption nobody noticed for a week is still recoverable, short enough
# that a table of a few thousand rows costs a few tens of kilobytes a night.
KEEP = 30

DEFAULT_DIR = "/home/zixen/arcanum/backups"
DEFAULT_ENV_FILE = "/home/zixen/arcanum/supabase.env"
DEFAULT_STATE = "/home/zixen/arcanum/account-backup.state.json"
DEFAULT_LOCK = "/tmp/arcanum-account-backup.lock"
TIMEOUT = 900.0


class DumpError(RuntimeError):
    """A refusal, an unreadable dump, or a psql that did not answer."""


def sql_text(value):
    """One Python string as a SQL literal.

    With standard_conforming_strings on - which Postgres has defaulted to since
    9.1 - a backslash is an ordinary character and a doubled single quote is
    the whole of the escaping rule.
    """
    return "'" + str(value).replace("'", "''") + "'"


def quote_ident(name):
    """One column name as a quoted SQL identifier.

    Column names come out of information_schema rather than from a caller, so
    this is belt and braces rather than a defence - but a name this file puts
    into a statement is a name it should be willing to quote.
    """
    return '"' + str(name).replace('"', '""') + '"'


def now_stamp():
    return datetime.now(timezone.utc).strftime(BACKUP_STAMP)


# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------


def require_libpq_split():
    """Refuses a catalog_store that cannot split a URL into libpq's variables."""
    if not hasattr(catalog_store, "libpq_environment"):
        raise DumpError(
            "the catalog_store this script imported has no libpq_environment "
            f"({getattr(catalog_store, '__file__', 'unknown')}), so it is an older "
            "copy than the one this file needs. On this host the current module is "
            "/home/zixen/arcanum/catalog_store.py and the copy under "
            "/home/zixen/arcanum/tool/ is stale: run this script from the directory "
            "that holds the current one.")


def load_env_file(path):
    """Reads KEY=VALUE lines into the environment, without overwriting it.

    The same reader the account proofs use. A variable already in the
    environment wins: what a caller exported is a more specific statement of
    what this run should connect to than a file that happens to be on disk.
    """
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            name, value = line.split("=", 1)
            name, value = name.strip(), value.strip().strip('"').strip("'")
            if name and name not in os.environ:
                os.environ[name] = value


def database_url():
    """The account connection, or a refusal that says what to set.

    SUPABASE_DB_URL_POOLED is the variable every other account tool uses - the
    session pooler on 5432, which is where admin work belongs.
    SUPABASE_DB_URL is accepted as a fallback exactly as
    tool/account/prove_collection_tombstones.py accepts it.
    """
    url = os.environ.get("SUPABASE_DB_URL_POOLED") or os.environ.get("SUPABASE_DB_URL") or ""
    if not url:
        raise DumpError("SUPABASE_DB_URL_POOLED is not set. Put it in the environment "
                        "or in the file named by --env-file.")
    return url


# ---------------------------------------------------------------------------
# psql, and the statements
# ---------------------------------------------------------------------------


def run_psql_lines(db_url, sql, take, timeout=TIMEOUT, psql=None):
    """Runs one script through psql and hands each stdout line to `take`.

    A file rather than -c, because a script of several statements is one
    session and one transaction only when psql is given the whole thing at
    once, and `-c` would run each of them as its own.

    The connection arrives in the environment and never in the argv below; see
    catalog_store.libpq_environment, which does the splitting and is the only
    place that has to know how. stderr goes to a file rather than a pipe: this
    function reads stdout as it arrives, and a pipe nobody is draining is how a
    process that writes one line too many to stderr deadlocks instead of
    failing.

    The timeout is checked per line rather than handed to subprocess.run,
    because a streaming read has no single call to put a timeout on. A psql
    that stops answering is killed and reported rather than left holding the
    single-flight lock for ever.
    """
    require_libpq_split()
    psql = psql or catalog_store.find_psql()
    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False,
                                     encoding="utf-8") as handle:
        handle.write(sql)
        sql_path = handle.name
    fd, err_path = tempfile.mkstemp(suffix=".err")
    os.close(fd)
    try:
        with open(err_path, "w", encoding="utf-8") as err_file:
            proc = subprocess.Popen(
                [psql, "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-f", sql_path],
                stdout=subprocess.PIPE, stderr=err_file, text=True,
                env=catalog_store.psql_environment(db_url))
            deadline = time.monotonic() + timeout
            try:
                for line in proc.stdout:
                    take(line)
                    if time.monotonic() > deadline:
                        proc.kill()
                        raise DumpError(f"psql did not finish within {timeout:g}s")
            finally:
                # Closing stdout first, so a psql still writing gets a broken
                # pipe and dies rather than blocking the wait below for ever.
                proc.stdout.close()
                proc.wait()
        with open(err_path, "r", encoding="utf-8") as handle:
            stderr = handle.read().strip()
    finally:
        for path in (sql_path, err_path):
            try:
                os.unlink(path)
            except OSError:
                pass
    if proc.returncode != 0:
        raise DumpError(f"psql failed: {stderr[:600]}")


def psql_lines(db_url, sql, timeout=TIMEOUT):
    """Every non-empty stdout line of one script."""
    lines = []
    run_psql_lines(db_url, sql, lambda line: lines.append(line.rstrip("\n")), timeout)
    return [line for line in lines if line != ""]


def columns_of(db_url, table, timeout=TIMEOUT):
    """The live columns of one table, in their stored order.

    Read rather than written down, so a column added to the table later is
    dumped on the night it is added instead of being silently dropped from
    every dump from then on. The proof script compares the keys in a dump
    against this same reading, which is what makes a dump produced by an older
    version of this file - one missing a column - a failure rather than a
    quiet loss.
    """
    rows = psql_lines(db_url,
                      "select column_name from information_schema.columns"
                      " where table_schema = 'public'"
                      f" and table_name = {sql_text(table)}"
                      " order by ordinal_position", timeout)
    if not rows:
        raise DumpError(
            f"public.{table} has no columns this account can see: the table does "
            "not exist, or the role is not allowed to read it")
    return rows


def dump_sql(tables_columns):
    """Every table of the account, as one script, in one snapshot.

    Every value is cast to text rather than sent as its own JSON type, and that
    is the difference between a backup and a lossy copy: `numeric` and
    `timestamptz` have no exact JSON form, and a dump that rendered a price
    as a JSON number would restore 12.34 as 12.340000000000001 through any
    reader that parses JSON into floats. Text is the form Postgres itself
    round-trips, and the restore in docs/account-backup.md casts it back.

    `order by 1` sorts each table by the rendered row, which is a total order
    that needs no knowledge of any table's key and gives the same file whatever
    order the heap happens to be in.
    """
    lines = [
        "-- One snapshot for every table of the account, so the file is a reading",
        "-- of the account at one instant rather than several readings apart.",
        "begin isolation level repeatable read read only;",
        "-- timestamptz::text renders in the session's time zone, so it is pinned",
        "-- here: a dump taken under another setting would carry different text for",
        "-- the same instant, and a restore would land on a different moment.",
        "set local time zone 'UTC';",
    ]
    for table, columns in tables_columns:
        pairs = ", ".join(f"{sql_text(column)}, {quote_ident(column)}::text"
                          for column in columns)
        lines.append(
            "select json_build_object('table', " + sql_text(table)
            + ", 'row', json_build_object(" + pairs + "))::text\n"
            f"  from public.{quote_ident(table)}\n"
            " order by 1;")
    lines.append("commit;")
    return "\n".join(lines)


def row_counts(db_url, timeout=TIMEOUT):
    """How many rows each table holds, as the owner.

    One script for every count, so the numbers describe the same instant.
    """
    rows = psql_lines(db_url,
                      "begin isolation level repeatable read read only;"
                      + " union all".join(
                          " select " + sql_text("count=" + table + "=")
                          + " || count(*)::text from public." + quote_ident(table)
                          for table in TABLES)
                      + "; commit;", timeout)
    counts = {}
    for line in rows:
        label, _, number = line.partition("=")
        if label != "count" or "=" not in number:
            continue
        table, _, value = number.partition("=")
        counts[table] = int(value)
    if sorted(counts) != sorted(TABLES):
        raise DumpError("could not count every table of the account: "
                        + ", ".join(sorted(counts)) + " answered")
    return counts


# ---------------------------------------------------------------------------
# The file
# ---------------------------------------------------------------------------


def canonical_row(row):
    """One row, rendered so that two readings of it compare equal.

    Keys sorted, no incidental whitespace, every value already text. This is
    the form the fingerprint below is taken over, and the proof script uses the
    same function on the rows it reads back out of the database - which is what
    makes the two fingerprints comparable at all.
    """
    return json.dumps({str(key): (None if value is None else str(value))
                       for key, value in row.items()},
                      ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def rows_fingerprint(rows_by_table):
    """The md5 of a whole account's worth of rows.

    Sorted by the canonical rendering of each row, so the fingerprint does not
    depend on the order the rows arrived in - which is the property a restore
    needs, because a restored table has no order. The table name and its row
    count are folded in first, so a dump that lost a table, or lost a row from
    one, cannot hash to the same value as the database it came from.
    """
    digest = hashlib.md5()
    for table in sorted(rows_by_table):
        rows = sorted(canonical_row(row) for row in rows_by_table[table])
        digest.update(table.encode("utf-8"))
        digest.update(b"\n")
        digest.update(str(len(rows)).encode("utf-8"))
        digest.update(b"\n")
        for line in rows:
            digest.update(line.encode("utf-8"))
            digest.update(b"\n")
    return digest.hexdigest()


def read_dump(path):
    """One dump, every line parsed, with the header checked against the body.

    Returns (header, {table: [row, ...]}). Raises DumpError naming the line
    that is wrong, because "the dump is corrupt" is not an answer anybody can
    act on.

    Four things are checked here and each is a way a dump can be worthless
    while still being a file: that it gunzips at all, that every line is JSON,
    that the header is the format this version writes, and that the rows
    actually present are the number the header claims. The last one is the
    whole reason this reader is not just json.loads in a loop - a truncated
    gzip is caught by gzip itself, but a file that lost its last hundred lines
    to a full disk is not.
    """
    header = None
    rows = {}
    try:
        with gzip.open(path, "rt", encoding="utf-8") as handle:
            for number, line in enumerate(handle, 1):
                text = line.strip()
                if not text:
                    raise DumpError(f"line {number} is blank")
                try:
                    item = json.loads(text)
                except ValueError as exc:
                    raise DumpError(f"line {number} is not JSON: {exc}")
                if header is None:
                    header = item
                    if not isinstance(header, dict):
                        raise DumpError("the first line is not a JSON object")
                    if header.get("format") != FORMAT:
                        raise DumpError(
                            f"the header names format {header.get('format')!r}, "
                            f"not {FORMAT!r}")
                    version = header.get("version")
                    if not isinstance(version, int) or version > FORMAT_VERSION:
                        raise DumpError(
                            f"the header is version {version!r}, and this reader "
                            f"understands version {FORMAT_VERSION} and older - a "
                            "dump written by a newer backup is one this reader "
                            "cannot know the shape of")
                    expected = VERSION_TABLES.get(version)
                    if expected is not None and tuple(header.get("tables") or ()) != expected:
                        raise DumpError(
                            f"a version {version} dump holds "
                            f"{', '.join(header.get('tables') or []) or 'no tables'}, "
                            f"where that version means {', '.join(expected)}")
                    for key in ("created_at", "tables", "rows", "columns"):
                        if key not in header:
                            raise DumpError(f"the header has no {key!r}")
                    for table in header["tables"]:
                        if table not in header["rows"] or table not in header["columns"]:
                            raise DumpError(
                                f"the header names table {table!r} without a row "
                                "count or a column list for it")
                        rows[table] = []
                    continue
                if not isinstance(item, dict) or not isinstance(item.get("row"), dict):
                    raise DumpError(f"line {number} is not a row object")
                table = item.get("table")
                if table not in rows:
                    raise DumpError(
                        f"line {number} names table {table!r}, which the header "
                        "does not list")
                rows[table].append(item["row"])
    except DumpError:
        raise
    except (OSError, EOFError) as exc:
        # gzip.BadGzipFile is an OSError; a file that stops in the middle of its
        # stream raises EOFError. Both mean the same thing here.
        raise DumpError(f"{path} did not decompress: {exc}")

    if header is None:
        raise DumpError(f"{path} is empty: it holds no header")
    for table in TABLES:
        if table not in rows:
            raise DumpError(f"the header does not list public.{table}")
    for table, found in rows.items():
        claimed = header["rows"][table]
        if not isinstance(claimed, int) or claimed != len(found):
            raise DumpError(
                f"the header claims {claimed} {table} rows and the file holds "
                f"{len(found)}")
        columns = set(header["columns"][table])
        for index, row in enumerate(found, 1):
            if set(row) != columns:
                missing = sorted(columns - set(row))
                extra = sorted(set(row) - columns)
                raise DumpError(
                    f"{table} row {index} does not carry the header's columns "
                    f"(missing {missing}, unexpected {extra})")
    return header, rows


def dump_files(directory):
    """Every dump in a directory, oldest first.

    Names sort chronologically because the stamp in them is fixed width, which
    is what lets retention work on names alone. Two dumps written inside the
    same second carry names that cannot say which came first - the second one
    has ".2" in front of its extension - so those, and only those, are ordered
    by the time they were written instead.
    """
    try:
        names = os.listdir(directory)
    except OSError:
        return []
    names = [name for name in names
             if name.startswith(BACKUP_PREFIX) and name.endswith(BACKUP_SUFFIX)]

    def order(name):
        try:
            written = os.path.getmtime(os.path.join(directory, name))
        except OSError:
            written = 0.0
        return (name[:len(BACKUP_PREFIX) + BACKUP_STAMP_WIDTH], written, name)

    return [os.path.join(directory, name) for name in sorted(names, key=order)]


def verify_dump(path):
    """Checks one dump's integrity without a database. Returns its header."""
    header, _rows = read_dump(path)
    return header


def rotate(directory, keep=KEEP, protect=()):
    """Deletes the oldest dumps beyond `keep`, and never one that did not verify.

    Returns (deleted, retired, broken). A dump that cannot be read back is kept
    where it is and reported as broken rather than removed: it is the only
    evidence that something went wrong with a run, and deleting it is how a
    broken backup becomes invisible. A dump that cannot be unlinked is left
    too - it is a backup, and a stubborn one is no reason to report a run that
    succeeded as a failure.

    `protect` is redundant with the arithmetic - the file just written is the
    newest, and rotation never reaches it - and it is here anyway, because
    "rotation does not delete the file it was just handed" is worth being true
    by construction rather than by counting.
    """
    paths = dump_files(directory)
    guarded = {os.path.abspath(path) for path in protect}
    deleted, retired, broken = [], [], []
    for path in paths[:max(0, len(paths) - keep)]:
        if os.path.abspath(path) in guarded:
            retired.append(path)
            continue
        try:
            verify_dump(path)
        except DumpError as exc:
            broken.append((path, str(exc)))
            continue
        try:
            os.remove(path)
            deleted.append(path)
        except OSError as exc:
            retired.append((path, str(exc)))
    return deleted, retired, broken


def reserve_name(directory, stamp):
    """The name this dump will have, and the temporary file it is built in.

    A second run inside the same second is kept beside the first rather than
    replacing it - `account-<stamp>.2.json.gz`, which is how the companion names a
    second upload in the same second (tool/sync_server.py backup_name). The
    temporary file is created with O_EXCL, so two runs that did somehow get
    past the single-flight lock cannot both decide on one name and then lose a
    dump to each other.
    """
    for attempt in range(1, 1000):
        again = "" if attempt == 1 else ".%d" % attempt
        name = f"{BACKUP_PREFIX}{stamp}{again}{BACKUP_SUFFIX}"
        path = os.path.join(directory, name)
        if os.path.exists(path):
            continue
        incoming = os.path.join(directory, INCOMING_PREFIX + name)
        try:
            # Mode 600: a dump of somebody's collection is theirs, and the
            # directory it sits in is the only place it needs to be readable.
            fd = os.open(incoming, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            continue
        except OSError as exc:
            raise DumpError(f"could not create {incoming}: {exc}")
        os.close(fd)
        return name, path, incoming
    raise DumpError(f"no free name for a dump stamped {stamp} in {directory}")


def fsync_directory(directory):
    """Flushes a directory entry, so a rename survives a power cut.

    The file's own contents are fsynced before the rename; without this the
    rename itself can still be the thing that is lost, which leaves a dump
    whose bytes are on the disk and whose name is not.
    """
    try:
        fd = os.open(directory, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def write_dump(db_url, directory, timeout=TIMEOUT, created_at=None):
    """Writes one dump and returns what landed, as a record.

    The rows are spooled to a temporary file as they arrive and the compressed
    file is written afterwards, in one pass, header first. That is not
    decoration: the header has to record how many rows the body holds, so the
    body has to be counted before the header can be written, and reading a
    whole account into memory to count it is how a backup of a real collection
    runs the host out of memory.
    """
    tables_columns = [(table, columns_of(db_url, table, timeout)) for table in TABLES]
    try:
        os.makedirs(directory, exist_ok=True)
    except OSError as exc:
        raise DumpError(f"could not make {directory}: {exc}")

    created = created_at or now_stamp()
    counts = {table: 0 for table in TABLES}
    spool = tempfile.NamedTemporaryFile("w+b", suffix=".ndjson", delete=False,
                                        dir=directory, prefix=INCOMING_PREFIX)
    spool_path = spool.name
    try:
        def take(line):
            text = line.rstrip("\n")
            if not text:
                return
            try:
                item = json.loads(text)
            except ValueError as exc:
                raise DumpError(f"psql answered a line that is not JSON: {exc}")
            table = item.get("table") if isinstance(item, dict) else None
            if table not in counts:
                raise DumpError(f"psql answered a row for {table!r}, which is not one "
                                f"of {', '.join(TABLES)}")
            if not isinstance(item.get("row"), dict):
                raise DumpError(f"psql answered a {table} row that is not an object")
            counts[table] += 1
            spool.write(text.encode("utf-8") + b"\n")

        run_psql_lines(db_url, dump_sql(tables_columns), take, timeout)
        spool.flush()
        os.fsync(spool.fileno())
        spool.close()
        spool = None

        header = {
            "format": FORMAT,
            "version": FORMAT_VERSION,
            "created_at": created,
            "tables": list(TABLES),
            "rows": counts,
            "columns": {table: columns for table, columns in tables_columns},
        }
        name, path, incoming = reserve_name(directory, created)
        with open(incoming, "wb") as raw:
            # mtime=0 in the gzip header: the moment is in the file's own first
            # line, and a second copy of it in the container is one more thing
            # that can disagree.
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz:
                gz.write((json.dumps(header, ensure_ascii=False, sort_keys=True,
                                     separators=(", ", ": ")) + "\n").encode("utf-8"))
                with open(spool_path, "rb") as body:
                    shutil.copyfileobj(body, gz, 1 << 20)
            raw.flush()
            os.fsync(raw.fileno())
        os.replace(incoming, path)
        fsync_directory(directory)
    finally:
        if spool is not None:
            spool.close()
        try:
            os.unlink(spool_path)
        except OSError:
            pass

    # Read back before it is called a backup, and before rotation is allowed to
    # look at anything. A file that fails here is left where it is: it is the
    # evidence, and --verify-only will go on reporting it.
    header, _rows = read_dump(path)

    return {
        "ok": True,
        "at": created,
        "file": name,
        "path": path,
        "bytes": os.path.getsize(path),
        "rows": header["rows"],
        "last_ok_at": created,
        "last_ok_file": name,
    }


# ---------------------------------------------------------------------------
# The state file
# ---------------------------------------------------------------------------


def read_state(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        return data.get("backup") if isinstance(data, dict) and isinstance(data.get("backup"), dict) else {}
    except (OSError, ValueError):
        return {}


def write_state(path, record):
    """Records what the run did, keeping the last good run's facts.

    Merged rather than replaced, so a failure does not erase when the backup
    last worked - that pair of facts, `ok: false` beside `last_ok_at`, is the
    thing a person reads to tell "it never ran" from "it stopped running".
    """
    merged = dict(read_state(path))
    merged.update(record)
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump({"backup": merged}, handle, indent=1, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except OSError as exc:
        # Not fatal: the dump is written, and the next run records a fresh
        # record. Losing the note is not worth failing a backup over.
        print(f"state not written ({exc})", file=sys.stderr)


def record_failure(path, note):
    write_state(path, {"ok": False, "at": now_stamp(), "note": note})


# ---------------------------------------------------------------------------
# The modes
# ---------------------------------------------------------------------------


def dry_run(db_url, args):
    """Connects, counts, and writes nothing.

    The same connection the dump makes and the same tables it reads, so a run
    that answers here will answer for real - which is the only thing a dry run
    is for.
    """
    counts = row_counts(db_url, args.timeout)
    detail = " and ".join(f"{counts[table]} in public.{table}" for table in TABLES)
    print(f"dry run: {detail}; nothing was written")
    return 0


def verify_only(args):
    """Reads the newest dump back, and touches no database.

    This is what a monitoring job calls: it needs no credentials, it is safe to
    run while a dump is being written (it looks for the newest complete name,
    and a dump in progress is a `.incoming-` name this never matches), and
    its exit status is the answer.
    """
    paths = dump_files(args.out_dir)
    if not paths:
        print(f"no dump in {args.out_dir}: nothing has been backed up yet",
              file=sys.stderr)
        return 1
    path = paths[-1]
    try:
        header = verify_dump(path)
    except DumpError as exc:
        print(f"{os.path.basename(path)} FAILED verification: {exc}", file=sys.stderr)
        return 1
    detail = ", ".join(f"{header['rows'][table]} {table}" for table in header["tables"])
    print(f"{os.path.basename(path)} verified: {detail}, taken {header['created_at']}")
    return 0


def run(args, db_url):
    """Writes a dump, rotates, and records the outcome."""
    record = write_dump(db_url, args.out_dir, args.timeout)
    deleted, retired, broken = rotate(args.out_dir, args.keep, protect=[record["path"]])
    detail = " and ".join(f"{record['rows'][table]} rows in public.{table}"
                          for table in TABLES)
    record.update({
        "kept": len(dump_files(args.out_dir)),
        "deleted": [os.path.basename(path) for path in deleted],
        "unverified_kept": [os.path.basename(path) for path, _ in broken],
        "retired": [os.path.basename(path) for path in retired],
        # Written on the happy path too, and that is the point rather than
        # bookkeeping: the record is merged with the one before it, so a run
        # that set no note would leave the last failure's sentence sitting
        # beside "ok": true - and the note would then be the most alarming
        # thing in a file that says everything is fine.
        "note": f"wrote {record['file']}, {detail}",
    })
    write_state(args.state, record)
    print(f"wrote {record['path']}, {detail}, {record['kept']} dump(s) kept")
    return 0


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env-file", default=DEFAULT_ENV_FILE,
                        help="KEY=VALUE file to read the credentials from "
                             f"(default {DEFAULT_ENV_FILE})")
    parser.add_argument("--out-dir", default=DEFAULT_DIR,
                        help=f"where the dumps are written (default {DEFAULT_DIR})")
    parser.add_argument("--keep", type=int, default=KEEP,
                        help=f"how many dumps to keep (default {KEEP})")
    parser.add_argument("--state", default=DEFAULT_STATE,
                        help=f"what the last run did (default {DEFAULT_STATE})")
    parser.add_argument("--lock", default=DEFAULT_LOCK,
                        help="flock file, so two runs cannot interleave")
    parser.add_argument("--timeout", type=float, default=TIMEOUT,
                        help="seconds psql may take before it is killed")
    parser.add_argument("--dry-run", action="store_true",
                        help="connect, count the rows, and write nothing")
    parser.add_argument("--verify-only", action="store_true",
                        help="read the newest dump back; touches no database")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)

    if args.env_file:
        if os.path.exists(args.env_file):
            load_env_file(args.env_file)
        elif args.env_file != DEFAULT_ENV_FILE:
            # The default file is read when it is there and passed over when it
            # is not, because a run whose credentials are already exported -
            # or a --verify-only run, which needs none - must not fail on the
            # absence of a file it was never going to read. A file named
            # explicitly and not there is a refusal.
            print(f"{args.env_file} does not exist", file=sys.stderr)
            return 2

    # Before the credentials: --verify-only reads a file and opens no
    # connection, so it works on a host that has neither psql nor a password.
    if args.verify_only:
        try:
            return verify_only(args)
        except DumpError as exc:
            print(f"verification failed: {exc}", file=sys.stderr)
            return 1

    try:
        db_url = database_url()
        require_libpq_split()
        catalog_store.find_psql()
    except (DumpError, catalog_store.CatalogError) as exc:
        print(str(exc), file=sys.stderr)
        return 2

    if args.dry_run:
        try:
            return dry_run(db_url, args)
        except (DumpError, catalog_store.CatalogError) as exc:
            print(f"dry run failed: {exc}", file=sys.stderr)
            return 1

    try:
        with catalog_store.single_flight(args.lock):
            return run(args, db_url)
    except (DumpError, catalog_store.CatalogError) as exc:
        record_failure(args.state, str(exc))
        print(f"backup failed: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001 - a failed backup has to be a fact
        # Deliberately broad. The timer runs this where nobody is watching, and
        # a traceback in a log with no state file beside it is a backup that
        # stopped happening without saying so. The exception's own words are
        # kept, and the next run still fails the same way if the cause is real.
        record_failure(args.state, f"{type(exc).__name__}: {exc}")
        print(f"backup failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
