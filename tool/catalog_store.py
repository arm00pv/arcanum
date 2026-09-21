#!/usr/bin/env python3
"""The shared write path for the card catalogue.

Design: docs/catalogue-server-side.md, section 3. One module serves all five
nightly importers, because the rules below are the same for every game and the
only thing that varies is where the rows come from.

What this module is responsible for, and why each rule exists:

  * **One transaction per set.** A set's cards are deleted and rewritten, its
    set row updated and its `cards_revision` bumped inside a single
    transaction, so a browser reading through PostgREST sees the whole old set
    or the whole new one and never half of each. A per-set revision is
    meaningless otherwise.

  * **Checksum first.** The card list is canonicalised and hashed; if the hash
    matches `catalog_sets.cards_checksum` nothing about that set's cards is
    written and no revision moves. On most nights most sets are unchanged, and
    an import should cost one comparison rather than a quarter of a million
    row writes.

  * **Sets before cards.** `catalog_cards` has a foreign key to
    `catalog_sets (game, code)`, so the set row is written first inside the
    same transaction.

  * **Never delete a set.** A set that disappears upstream is given
    `retired_at`; its row and its cards stay. Collection rows name card ids,
    and an id that stops resolving renders as `--` for ever. Sets are the unit
    this module refuses to destroy, and `retire_sets` is the only thing that
    writes `retired_at`.

  * **Refuse to empty a set.** A provider answering an empty card list for a
    set that currently holds rows is far more likely to be a bad response than
    a withdrawn set, and the delete-then-insert above would destroy the set on
    the strength of it. That case is refused and reported, not obeyed.

  * **Record the outcome.** `catalog_meta.last_import_ok` and
    `last_import_note` per game, so a broken importer is a fact a client can
    read rather than an empty Sets tab it has to interpret.

  * **No partial revision bumps.** `catalog_meta.sets_revision` moves once, at
    the end, and only when the set list itself changed.

  * **One transaction per game's prices, and a full replacement.** A game's
    current prices are deleted and rewritten whole - section 5's rule, because a
    price is cheap to recompute and expensive to diff - and the game's
    `prices_revision` moves with them in the same transaction. Unlike a set,
    whose cards are never removed, the price table is meant to be replaced: what
    it holds is tonight's number, not a record of yesterday's. Two consequences
    are handled rather than assumed: a game's prices are only ever written by a
    sweep that covered the whole game, and a set the sweep could not read keeps
    the rows it already had instead of being deleted for a provider's bad night.

Two boundaries this module holds deliberately:

  * **It cannot touch the account tables.** `public.decks` and
    `public.collection_entries` hold real collector data and are not part of
    the catalogue. Every statement this module generates passes through
    `_forbid_account_tables`, which refuses anything naming them. That is a
    cheap guard against a future edit in this file, and it is the reason the
    guard is here rather than in a review checklist.

  * **It connects as the owner, over the session pooler.** Not PostgREST, not
    with an API key. The catalogue's RLS posture grants `anon` and
    `authenticated` SELECT and nothing else; `postgres` owns these tables and
    has BYPASSRLS, which is the write path design section 2.4 describes. The
    URL therefore comes from the host's credentials file and is never printed -
    and it is never handed to `psql` as an argument either. `libpq_environment`
    splits it into the variables libpq reads from the environment, so what a
    process listing shows is `psql -f /tmp/...` and no password. That function
    is where the reasons are; the short version is that a command line is
    readable by every user on the host and a process's environment is not.

There is no Postgres driver on the host - no psycopg, no asyncpg - and adding
one would mean a dependency the rest of the deployment does not have. This
module therefore speaks to `psql`, exactly as tool/catalog/prove_catalogue_posture.py
does, and generates SQL it runs from a file. The one thing that has to be got
right about generating SQL is quoting, so `sql_literal` is the only place a
value becomes text, and it refuses to run against a server on which
`standard_conforming_strings` is off - the setting that makes a doubled single
quote the complete escaping rule for a string literal.

Usage, from an importer:

    store = CatalogStore(os.environ["SUPABASE_DB_URL"])
    for code in codes:
        store.import_set("lorcana", set_doc, cards)
    store.replace_prices("lorcana", price_rows, observed_on, "lorcast",
                         carry_over_sets=unswept)
    store.finish("lorcana", source="lorcast")
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import tempfile
from contextlib import contextmanager
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from urllib.parse import parse_qsl, unquote, urlsplit

# The columns an importer supplies for a set, in a fixed order. Everything else
# on catalog_sets is bookkeeping this module owns: cards_revision,
# cards_checksum, card_row_count, catalogued_at, retired_at, updated_at. The
# generated code_folded is not listed because it cannot be written at all.
SET_COLUMNS = (
    "code", "id", "name", "set_type", "released_at", "card_count",
    "printed_size", "icon_svg_uri", "logo_uri", "series", "digital",
    "foil_only", "nonfoil_only", "parent_set_code", "block_code", "block",
    "collector_number_start",
)

# The columns of one card row, in a fixed order, matching section 2.2. The
# generated number_bare is absent for the same reason code_folded is.
CARD_COLUMNS = (
    "id", "oracle_id", "set_code", "set_name", "name", "collector_number",
    "collector_sort", "rarity", "layout", "type_line", "oracle_text",
    "mana_cost", "cmc", "colors", "color_identity", "artist", "flavor_text",
    "image_small", "image_normal", "image_large", "image_art_crop",
    "image_png", "back_image_small", "back_image_normal", "digital", "promo",
    "reprint", "reserved", "full_art", "booster", "foil", "nonfoil",
    "edhrec_rank", "released_at", "extras",
)

# Columns that are jsonb, and so need a cast rather than a bare literal. extras
# is the only one: the document stores it as jsonb rather than as the JSON
# string SQLite keeps, which is the one deliberate difference between the two
# shapes for anything other than booleans.
_JSON_COLUMNS = frozenset({"extras"})

# The columns of one price row that come from the row itself, in a fixed order,
# matching section 5. game, source and observed_on are not here because they are
# properties of the night rather than of a card: one sweep has one source and one
# observation day, and replace_prices writes them onto every row it stores.
PRICE_COLUMNS = ("card_id", "kind", "code", "price")

# The two kinds the table's own check constraint allows. A finish is a physical
# printing the app prices per finish; a secondary figure is a provider's own
# number - a Cardmarket euro, a ticket - which the app shows without calling it a
# finish.
PRICE_KINDS = ("finish", "secondary")

# price is numeric(12,2) and takes an explicit cast, for the same reason extras
# takes one: a bare text literal would be coerced by position, and the cast is
# what states the type instead of leaving it to the shape of the statement.
_NUMERIC_COLUMNS = frozenset({"price"})

# How many price rows one insert statement carries. The whole game goes in one
# transaction either way; this only keeps a single statement from being a
# megabyte of text, which is a debugging convenience and nothing more.
_PRICE_BATCH = 2000

# The scale of the column, as a value rather than as a format string, so that
# rounding and the text both come from one place.
_TWO_PLACES = Decimal("0.01")

# Tables this module must never write. Checked on every statement rather than
# trusted to care, because the cost of the check is nothing and the cost of
# being wrong is a collector's collection.
_ACCOUNT_TABLES = ("decks", "collection_entries")

# Refused for the same reason: a value this module cannot quote safely must
# stop the import rather than reach the database.
_SAFE_STRING_SETTING = "standard_conforming_strings"


class CatalogError(RuntimeError):
    """A refusal, a failed statement, or a broken assumption about the server."""


def sql_literal(value):
    """Renders one Python value as a SQL literal, or refuses.

    With standard_conforming_strings on - which Postgres has defaulted to since
    9.1 and which _check_server verifies - a backslash is an ordinary character
    and the *only* escape a single-quoted literal needs is a doubled single
    quote. Every other byte, including newlines and tabs and non-ASCII text,
    travels unchanged. That is the whole of the rule, and it is why this
    function is short enough to read.

    None becomes null, booleans become true/false rather than 0/1 because the
    catalogue keeps the honest type, and a non-finite float is refused rather
    than silently stored as NaN.
    """
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if not math.isfinite(value):
            raise CatalogError(f"refusing to store a non-finite number: {value!r}")
        return repr(value)
    if isinstance(value, (dict, list)):
        return sql_literal(json.dumps(value, ensure_ascii=False, sort_keys=True))
    text = str(value).replace("'", "''")
    return "'" + text + "'"


# One string literal, including the doubled quotes that put a quote inside one.
_SQL_LITERAL = re.compile(r"'(?:[^']|'')*'", re.S)

# An account table named by a statement rather than by a card.
_ACCOUNT_REFERENCE = re.compile(r"\b(decks|collection_entries)\b")


def _forbid_account_tables(sql):
    """Refuses a statement that names an account table.

    The literals come out first, and that is not a detail. The first version of
    this guard searched the whole statement, and a Lorcana card whose rules text
    mentions decks made it refuse two entire sets - an import that reported
    failure, wrote twelve sets out of twenty-four, and looked like a guard
    working rather than a guard misfiring. Stripping literals leaves only the
    statement's own words, so a table can no longer hide inside card text and
    card text can no longer be mistaken for a table.
    """
    match = _ACCOUNT_REFERENCE.search(_SQL_LITERAL.sub("''", sql))
    if match:
        raise CatalogError(f"refusing a statement naming public.{match.group(1)}")
    return sql


def canonical_checksum(cards):
    """The sha256 of a canonical card list, used to skip unchanged sets.

    Sorted by id and serialised with sorted keys and no incidental whitespace,
    so the same cards hash the same way whatever order the provider returned
    them in and whatever order the importer built its dictionaries in. A
    checksum that moved for a cosmetic reason would defeat the entire point of
    having one.
    """
    canonical = sorted(cards, key=lambda c: str(c.get("id", "")))
    blob = json.dumps(canonical, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":"), default=str)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def set_fingerprint(rows):
    """A hash of the set list's own descriptive content.

    Deliberately excludes the bookkeeping columns - revisions, checksums, row
    counts, catalogued_at, retired_at, updated_at - because those change every
    time an import runs and would make every night look like a new set list.
    What is left is exactly the content a client would have to re-download:
    the nine columns of a set row the app renders.
    """
    fields = ("code", "id", "name", "set_type", "released_at", "card_count",
              "printed_size", "icon_svg_uri", "logo_uri", "series", "digital",
              "foil_only", "nonfoil_only", "parent_set_code", "block_code",
              "block", "collector_number_start")
    canonical = []
    for row in rows:
        canonical.append({f: _normalise(row.get(f)) for f in fields})
    canonical.sort(key=lambda r: str(r["code"]))
    blob = json.dumps(canonical, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":"))
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def _normalise(value):
    """One value in the form both a psql reading and an importer agree on.

    psql renders a boolean as 't'/'f', a date as 'YYYY-MM-DD' and a number as
    text, while an importer holds Python types. Comparing the two without this
    would report the set list as changed on every single run.
    """
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        text = value.strip()
        if text in ("t", "true"):
            return True
        if text in ("f", "false"):
            return False
        return text or None
    return value


def price_text(value):
    """One price as the exact text the numeric(12,2) column stores, or a refusal.

    **A zero is not a price.** Design section 5 states it as a rule the importers
    inherit from the provider clients, and this is where it stops being a habit:
    TCGdex and YGOPRODeck both answer 0.00 for a printing with no market, the app
    reads an absent row as unknown and a stored 0.00 as a real quote of nothing,
    so a zero or a negative is refused here rather than stored. The importers
    drop one long before this point; the refusal is the guard that keeps the rule
    from being broken by an edit that never reads this far.

    Two decimal places, rounded half-up, which is what Postgres itself does when
    a value goes into numeric(12,2). Doing it here as well is not belt and
    braces: it is what makes the row the importer derived and the row the
    database holds *the same row*, so an unchanged night can be recognised by
    comparison and skipped instead of rewritten. A float left unrounded would
    come back from the database a hair different and every night would look new.
    """
    if value is None or isinstance(value, bool):
        raise CatalogError(f"a price must be a number, not {value!r}")
    try:
        amount = Decimal(str(value).strip())
    except (InvalidOperation, ValueError) as exc:
        raise CatalogError(f"a price must be a number, not {value!r}") from exc
    if not amount.is_finite():
        raise CatalogError(f"refusing to store a non-finite price: {value!r}")
    amount = amount.quantize(_TWO_PLACES, rounding=ROUND_HALF_UP)
    if amount <= 0:
        raise CatalogError(
            f"refusing to store {amount} as a price: a zero is not a price, and "
            "an absent row already says the market quoted nothing")
    return f"{amount:f}"


def _day_text(value):
    """One observed_on as the date the column stores, or None."""
    if value is None:
        return None
    text = str(value).strip()
    return text[:10] or None


def _canonical_prices(rows):
    """A price set in the one form an importer and a psql reading agree on.

    The reading hands a numeric back as text with its scale ('1.20') and a date
    as 'YYYY-MM-DD', while the importer holds a Python float and the day it
    sampled on. The two are put in the same shape here - the price through
    price_text, which is the column's own rule, the day truncated to its date -
    and sorted by key, so the comparison in replace_prices answers a question
    about the rows rather than about how they were spelled.
    """
    out = []
    for row in rows:
        out.append((
            str(row["card_id"]),
            str(row["kind"]),
            str(row["code"]),
            price_text(row["price"]),
            _day_text(row.get("observed_on")) or "",
            str(row.get("source") or ""),
        ))
    out.sort()
    return out


def price_fingerprint(rows):
    """The sha256 of a game's whole price set, in that canonical form.

    One hash rather than a row-by-row comparison, because the question the
    nightly import asks is only ever "is tonight's set the set the server already
    holds?", and a hash answers it without a diff of twenty thousand tuples.
    """
    blob = json.dumps(_canonical_prices(rows), ensure_ascii=False,
                      separators=(",", ":"))
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------------------
# The connection, as libpq reads it
# ---------------------------------------------------------------------------

# The five parts a Postgres URL carries, and the environment variable libpq
# reads each one from. These are libpq's own names; nothing here is invented,
# because a misspelt one is not an error anywhere - it is a psql that connects
# to the wrong place.
_URL_PARTS = {
    "host": "PGHOST",
    "port": "PGPORT",
    "user": "PGUSER",
    "password": "PGPASSWORD",
    "dbname": "PGDATABASE",
}

# The connection settings a URL carries as query parameters, and the variable
# each one becomes. sslmode is the one that matters here, and the reason this
# list exists at all: the session pooler's URL says ?sslmode=require, and a
# split that dropped it would leave libpq on its default of prefer - which
# still negotiates TLS with this server, so nothing would look wrong while the
# requirement had quietly stopped being one.
_URL_PARAMETERS = {
    "sslmode": "PGSSLMODE",
    "sslrootcert": "PGSSLROOTCERT",
    "sslcert": "PGSSLCERT",
    "sslkey": "PGSSLKEY",
    "sslcrl": "PGSSLCRL",
    "application_name": "PGAPPNAME",
    "connect_timeout": "PGCONNECT_TIMEOUT",
    "options": "PGOPTIONS",
    "target_session_attrs": "PGTARGETSESSIONATTRS",
    "channel_binding": "PGCHANNELBINDING",
    "gssencmode": "PGGSSENCMODE",
    "client_encoding": "PGCLIENTENCODING",
    "keepalives": "PGKEEPALIVES",
    "keepalives_idle": "PGKEEPALIVESIDLE",
    "keepalives_interval": "PGKEEPALIVESINTERVAL",
    "keepalives_count": "PGKEEPALIVESCOUNT",
    "passfile": "PGPASSFILE",
}

# Parameters a client library reads and libpq does not. Ignored rather than
# refused: the refusal below is for a setting that would have reached libpq and
# changed the connection, and these never do.
_DRIVER_PARAMETERS = frozenset({"pgbouncer"})


def _decoded(part):
    """One URL part with its percent-encoding removed, or None.

    urlsplit hands userinfo back exactly as the URL spells it, which is the
    right thing for it to do and the wrong thing to give libpq.
    """
    return None if part is None else unquote(part)


def libpq_environment(db_url):
    """The connection, as the environment libpq reads, not as an argument.

    A psql given its connection as a URL has that URL in its command line, and
    a command line is readable by every user on the host: ps shows the
    password, percent-encoding and all, for as long as each statement runs.
    Splitting the URL into the variables libpq actually reads leaves a process
    listing showing `psql -f /tmp/...` and nothing else.

    The split is done with urlsplit rather than by cutting the string at its
    punctuation, and that is the whole reason this function exists. A password
    containing '@' or '!' arrives percent-encoded - this deployment's contains
    both - and a split that handed libpq the encoded text would fail
    authentication with an error that names nothing useful: libpq would be
    asking to authenticate as a user whose password literally contains '%40'.
    Every part is unquoted here, which is the decode a URL is defined to have.

    Two refusals, both deliberately loud. A URL that names no host or no
    database is refused rather than passed on, because libpq answers a missing
    host by connecting over the local socket - a psql talking to whatever
    Postgres happens to be on this machine, silently, which is a worse bug than
    the one being fixed here. And a query parameter libpq has no variable for
    is refused rather than dropped, because sslmode is one of them.

    PGPASSWORD is in the result, so the password is in the environment of the
    psql this module spawns. That is as far as a subprocess can be hidden: a
    process's environment is readable by its owner and by root, while its
    command line is readable by every user on the host.
    """
    parts = urlsplit(db_url)
    if parts.scheme not in ("postgres", "postgresql"):
        raise CatalogError(
            f"the database URL is not a Postgres URL: scheme {parts.scheme!r}")
    try:
        # .hostname strips an IPv6 literal's brackets; .port raises on anything
        # that is not a number, which is a URL this module will not guess at.
        found = {
            "host": parts.hostname,
            "port": None if parts.port is None else str(parts.port),
            "user": _decoded(parts.username),
            "password": _decoded(parts.password),
            "dbname": _decoded(parts.path[1:]),
        }
    except ValueError as exc:
        raise CatalogError(f"could not read the database URL: {exc}") from exc

    environment = {_URL_PARTS[part]: value
                   for part, value in found.items() if value}

    for name, value in parse_qsl(parts.query, keep_blank_values=True):
        variable = _URL_PARTS.get(name) or _URL_PARAMETERS.get(name)
        if variable:
            # A parameter wins over the part it duplicates: a URL carrying both
            # has said the second one more specifically.
            environment[variable] = value
        elif name not in _DRIVER_PARAMETERS:
            raise CatalogError(
                f"the database URL carries a parameter libpq has no variable "
                f"for: {name!r}. Dropping it could change the connection with "
                "nothing to show for it, so it is refused instead")

    for variable, what in (("PGHOST", "host"), ("PGDATABASE", "database")):
        if not environment.get(variable):
            raise CatalogError(
                f"the database URL names no {what}: libpq answers a missing "
                "host or database by connecting over the local socket rather "
                "than by failing, which would be a worse bug than the one "
                "this split exists to fix")
    return environment


def psql_environment(db_url):
    """os.environ with this URL's connection merged into it.

    The ambient environment comes first and stays: psql needs PATH and HOME
    like any other program, and the host hands this importer its credentials by
    exporting them in the first place. The URL's own parts overwrite the
    connection variables, because the URL is the more specific statement of
    what this run is connecting to.
    """
    environment = dict(os.environ)
    environment.update(libpq_environment(db_url))
    return environment


@contextmanager
def single_flight(path):
    """Holds an exclusive lock so two importers cannot interleave.

    Design rule 6. The lock is advisory, so it only binds processes that ask
    for it, which is every importer this repository runs. A crashed run
    releases it on process exit; flock is the kernel's, not a file's contents,
    so a stale lock file is harmless.

    fcntl is imported here rather than at the top of the file because it does
    not exist on Windows, and the rest of this module - the row derivation, the
    checksum, the SQL building - is worth being able to import and test on a
    development machine. Taking a lock on a platform that cannot take one is
    refused rather than skipped: an import that believes it is single-flight
    and is not is worse than one that will not start.
    """
    try:
        import fcntl
    except ImportError:
        raise CatalogError(
            "this platform has no flock, so two imports cannot be kept apart; "
            "the catalogue importer runs on the host, which has it")
    handle = open(path, "w")
    try:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise CatalogError(f"another import holds {path}")
        handle.write(str(os.getpid()))
        handle.flush()
        yield
    finally:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        finally:
            handle.close()


class CatalogStore:
    """Writes catalogue rows for one game at a time, over psql."""

    def __init__(self, db_url, dry_run=False, psql="psql", timeout=300):
        if not db_url:
            raise CatalogError("no database URL: set SUPABASE_DB_URL or pass one")
        self.db_url = db_url
        self.dry_run = dry_run
        self.psql = psql
        self.timeout = timeout
        self._checked = False
        self._environment = None

    # ----------------------------------------------------------------- psql

    def _connection(self):
        """The environment psql is spawned with, parsed once per process.

        Parsed on first use rather than in __init__ so that a dry run - which
        spawns no psql at all, and which the proofs construct around a
        placeholder URL - does not need a connection string that resolves.
        It is still parsed before any statement runs, so a URL this module
        refuses is refused before anything is written rather than halfway
        through a set.
        """
        if self._environment is None:
            self._environment = psql_environment(self.db_url)
        return self._environment

    def _run(self, sql, workdir=None):
        """Runs one SQL script, from a file, with ON_ERROR_STOP.

        A file rather than -c because a set's transaction is several statements
        and psql would otherwise send each -c as its own transaction. With
        ON_ERROR_STOP a failed statement ends psql immediately, the connection
        closes, and the open transaction rolls back - which is what makes "a
        failed import leaves the previous revision serving" true rather than
        hoped for.

        The connection arrives in the environment and never in the argv below.
        That is the difference between a password only its owner can read out
        of /proc and one every user on the host can read out of ps; see
        libpq_environment, which does the splitting and is the only place that
        has to know how.
        """
        _forbid_account_tables(sql)
        if self.dry_run:
            print("---- dry run, would execute ----")
            print(sql if len(sql) < 4000 else sql[:4000] + "\n... (truncated)")
            return ""
        with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False,
                                         encoding="utf-8", dir=workdir) as fh:
            fh.write(sql)
            path = fh.name
        try:
            proc = subprocess.run(
                [self.psql, "-X", "-q", "-A", "-t",
                 "-v", "ON_ERROR_STOP=1", "-f", path],
                capture_output=True, text=True, timeout=self.timeout,
                env=self._connection(),
            )
        finally:
            os.unlink(path)
        if proc.returncode != 0:
            raise CatalogError(f"psql failed: {proc.stderr.strip()[:600]}")
        return proc.stdout

    def query_json(self, select_sql):
        """Runs a SELECT and returns rows as Python values.

        The result is built by Postgres as one JSON array rather than as
        pipe-separated text, because a card's rules text contains pipes, tabs
        and newlines and a text protocol would turn any of them into a column
        boundary.
        """
        sql = f"select coalesce(json_agg(x), '[]'::json) from (\n{select_sql}\n) x;"
        out = self._run(sql)
        text = out.strip()
        if not text:
            return []
        try:
            return json.loads(text)
        except json.JSONDecodeError as exc:
            raise CatalogError(f"could not read a JSON answer from psql: {exc}")

    def check_server(self):
        """Verifies the two assumptions quoting depends on, once per process."""
        if self._checked or self.dry_run:
            return
        rows = self.query_json(
            f"select current_setting('{_SAFE_STRING_SETTING}') as scs,"
            f"       current_setting('server_version') as version,"
            f"       current_user as who,"
            f"       (select count(*) from information_schema.tables"
            f"         where table_schema='public' and table_name like 'catalog\\_%') as tables")
        if not rows:
            raise CatalogError("could not read the server's settings")
        row = rows[0]
        if row["scs"] != "on":
            raise CatalogError(
                f"{_SAFE_STRING_SETTING} is {row['scs']!r}: sql_literal's escaping "
                "rule would be wrong on this server")
        if int(row["tables"]) != 4:
            raise CatalogError(
                f"expected the four catalog_ tables, found {row['tables']}: "
                "apply tool/catalog/0001_catalog_schema.sql first")
        self._checked = True
        return row

    # ------------------------------------------------------------- reading

    def read_sets(self, game):
        """Every set row for a game, including retired ones."""
        return self.query_json(
            "select code, id, name, set_type, to_char(released_at,'YYYY-MM-DD') as released_at,"
            "       card_count, printed_size, icon_svg_uri, logo_uri, series,"
            "       digital, foil_only, nonfoil_only, parent_set_code, block_code,"
            "       block, collector_number_start, cards_revision, cards_checksum,"
            "       card_row_count, retired_at is not null as retired"
            f"  from public.catalog_sets where game = {sql_literal(game)}"
            "  order by code")

    def read_meta(self, game):
        rows = self.query_json(
            "select game, sets_revision, prices_revision, set_count, card_count,"
            "       to_char(prices_observed_on, 'YYYY-MM-DD') as prices_observed_on,"
            "       last_import_ok, last_import_note, source"
            f"  from public.catalog_meta where game = {sql_literal(game)}")
        if not rows:
            raise CatalogError(
                f"no catalog_meta row for {game!r}: step 0 seeds nine of them")
        return rows[0]

    def read_prices(self, game):
        """Every current-price row one game holds, as the table spells it.

        price is selected as text rather than as a number on purpose. psql
        renders numeric(12,2) as '1.20', which is exactly the text price_text
        produces, so the comparison in replace_prices compares the database's own
        spelling of the row with the importer's instead of round-tripping a
        decimal through a float on the way.
        """
        return self.query_json(
            "select card_id, kind, code, price::text as price, source,"
            "       to_char(observed_on, 'YYYY-MM-DD') as observed_on"
            f"  from public.catalog_prices where game = {sql_literal(game)}"
            "  order by card_id, kind, code")

    def card_ids_in_sets(self, game, codes):
        """Every card id the catalogue holds for a set of set codes.

        Used by the price path to find the cards of a set the sweep could not
        read, whose stored prices are carried over rather than deleted. The codes
        are folded to lower case here for the reason retire_sets states at
        length: catalog_cards.set_code holds the *stored* spelling, and a game
        whose provider spells a code in upper case would match nothing at all
        while looking like it had.
        """
        folded = sorted({str(c).strip().lower() for c in (codes or ())
                         if str(c).strip()})
        if not folded:
            return set()
        array = "array[" + ", ".join(sql_literal(c) for c in folded) + "]::text[]"
        rows = self.query_json(
            f"select id from public.catalog_cards where game = {sql_literal(game)}"
            f" and set_code = any ({array})")
        return {row["id"] for row in rows}

    def count_rows(self, game):
        """The catalogue's real size for a game, read back from the tables."""
        rows = self.query_json(
            "select (select count(*) from public.catalog_sets"
            f"         where game = {sql_literal(game)} and retired_at is null) as sets,"
            "       (select count(*) from public.catalog_cards"
            f"         where game = {sql_literal(game)}) as cards,"
            "       (select count(*) from public.catalog_sets"
            f"         where game = {sql_literal(game)} and retired_at is not null) as retired")
        return rows[0]

    # ------------------------------------------------------------- writing

    def import_set(self, game, set_doc, cards, allow_empty=False):
        """Writes one set and its cards, in one transaction, or writes nothing.

        Returns a dict describing what happened, because the caller's log is
        the only place a skipped set and an unchanged set can be told apart.

        The checksum is compared first. When it matches, no card row is written
        and `cards_revision` does not move - but the set row is still
        reconciled if its own content differs, because a set that was renamed
        upstream is a real change that is not part of a card checksum, and
        leaving the old name in place for ever would be the wrong kind of
        cheap.
        """
        self.check_server()
        code = set_doc.get("code")
        if not code:
            raise CatalogError(f"a set with no code cannot be stored: {set_doc!r}")

        cards = list(cards)
        for card in cards:
            if card.get("set_code") != code:
                raise CatalogError(
                    f"card {card.get('id')!r} carries set_code "
                    f"{card.get('set_code')!r} but is being written to {code!r}: "
                    "a card must be stored under the set it belongs to")

        checksum = canonical_checksum(cards)
        stored = {row["code"]: row for row in self.read_sets(game)}
        current = stored.get(code)
        unchanged = current is not None and current.get("cards_checksum") == checksum

        if not cards and current is not None and int(current.get("card_row_count") or 0) > 0:
            if not allow_empty:
                raise CatalogError(
                    f"refusing to empty set {code!r}: the provider returned no cards "
                    f"but {current['card_row_count']} are stored. A provider hiccup "
                    "is likelier than a withdrawn set, and the rewrite below would "
                    "destroy it. Pass allow_empty to mean it.")

        set_changed = self._set_row_differs(current, set_doc)
        if unchanged and not set_changed:
            return {"code": code, "outcome": "unchanged", "cards": len(cards),
                    "checksum": checksum, "revision": current.get("cards_revision")}

        sql = self._set_transaction(game, set_doc, cards, checksum,
                                    bump=not unchanged,
                                    retire=False if not set_changed else None)
        self._run(sql)
        return {"code": code, "outcome": "written", "cards": len(cards),
                "checksum": checksum}

    def _set_row_differs(self, current, set_doc):
        """Whether the set's own content would change, ignoring bookkeeping."""
        if current is None:
            return True
        for column in SET_COLUMNS:
            if column == "code":
                continue
            if _normalise(current.get(column)) != _normalise(set_doc.get(column)):
                return True
        return False

    def _set_transaction(self, game, set_doc, cards, checksum, bump, retire):
        """The whole of one set's write, as a single transaction.

        Order matters and is not incidental: the set row goes in before the
        cards, because catalog_cards carries a foreign key to it, and the
        deletion is scoped to this game and this set code, because an importer
        may only ever remove what it is about to reinsert.
        """
        g = sql_literal(game)
        code = sql_literal(set_doc["code"])
        lines = ["begin;", ""]

        columns = ("game",) + SET_COLUMNS
        values = [g] + [sql_literal(set_doc.get(c)) for c in SET_COLUMNS]
        updatable = [c for c in SET_COLUMNS if c != "code"]
        lines.append(
            f"insert into public.catalog_sets ({', '.join(columns)})\n"
            f"values ({', '.join(values)})\n"
            "on conflict (game, code) do update set\n  "
            + ",\n  ".join(f"{c} = excluded.{c}" for c in updatable)
            + ",\n  updated_at = now(),\n  retired_at = null;")
        lines.append("")

        # Scoped to this set. Nothing else in the catalogue is reachable from
        # this statement, and nothing in the account tables is reachable from
        # any statement in this file.
        lines.append(f"delete from public.catalog_cards where game = {g} and set_code = {code};")
        lines.append("")

        if cards:
            card_columns = ("game",) + CARD_COLUMNS
            rows = []
            for card in cards:
                rendered = [g]
                for column in CARD_COLUMNS:
                    value = card.get(column)
                    literal = sql_literal(value)
                    if column in _JSON_COLUMNS and value is not None:
                        literal += "::jsonb"
                    rendered.append(literal)
                rows.append("(" + ", ".join(rendered) + ")")
            conflict = ", ".join(f"{c} = excluded.{c}" for c in CARD_COLUMNS)
            lines.append(
                f"insert into public.catalog_cards ({', '.join(card_columns)})\nvalues\n"
                + ",\n".join(rows) + "\n"
                f"on conflict (game, id) do update set\n  {conflict},\n  updated_at = now();")
            lines.append("")

        # The revision is the invalidation signal a client reads, so it moves
        # only when the cards it describes actually changed.
        bump_sql = "cards_revision = cards_revision + 1," if bump else ""
        lines.append(
            "update public.catalog_sets set\n"
            f"  {bump_sql}\n"
            f"  cards_checksum = {sql_literal(checksum)},\n"
            f"  card_row_count = {len(cards)},\n"
            "  catalogued_at = now(),\n"
            "  retired_at = null,\n"
            "  updated_at = now()\n"
            f"where game = {g} and code = {code};")
        lines.append("")
        lines.append("commit;")
        return "\n".join(lines)

    def retire_sets(self, game, keep_codes):
        """Soft-deletes the sets this game no longer publishes.

        The only writer of retired_at. A set is never removed: its cards are
        what a collection row's id resolves against, and a set row that is
        merely hidden costs nothing while a deleted one turns somebody's
        holdings into `--`.

        keep_codes are in *stored* form - the lower-case spelling the catalogue
        keeps - not the provider's own. The two differ for any game whose
        provider spells a code in upper case, and passing the provider's
        spelling here retires every such set while looking like it worked.
        """
        self.check_server()
        keep = sorted(set(keep_codes or ()))
        g = sql_literal(game)
        if keep:
            array = "array[" + ", ".join(sql_literal(c) for c in keep) + "]::text[]"
            sql = ("begin;\n"
                   "update public.catalog_sets\n"
                   "   set retired_at = now(), updated_at = now()\n"
                   f" where game = {g} and retired_at is null and not (code = any ({array}));\n"
                   "update public.catalog_sets\n"
                   "   set retired_at = null, updated_at = now()\n"
                   f" where game = {g} and retired_at is not null and code = any ({array});\n"
                   "commit;")
        else:
            raise CatalogError(
                f"refusing to retire every set of {game!r}: an empty upstream list "
                "is a failed fetch, not a withdrawn game")
        return self._run(sql)

    def replace_prices(self, game, rows, observed_on, source, carry_over_sets=(),
                       allow_empty=False):
        """Replaces one game's whole current-price set, in one transaction.

        Design section 5's rule, and the one place this module deliberately goes
        past what that section spells out. The rule is *full replacement per
        game, nightly*: delete the game's rows and insert tonight's, in one
        transaction, then move prices_revision. That is what happens here. The
        refinement is what the rule assumes and the sweep does not always
        deliver - that every set of the game was read this run.

        A sweep that could not read a set is not evidence that the set has no
        prices, and a plain `delete where game = ...` would read it as exactly
        that: a provider's 503 on one set response would delete a whole set's
        prices and leave them missing until the next night. So the cards of a set
        the caller names in carry_over_sets keep the rows the table already holds
        for them, their old observed_on included, and everything the sweep *did*
        read is replaced as the rule says. On a complete sweep - the ordinary
        case - there is nothing to carry over and this is a plain replacement.

        `rows` are dicts of card_id, kind, code and price; source is an argument
        because one sweep has one publisher. observed_on is an argument too, and
        it is the sweep's *sampler day* rather than the moment this statement
        runs: the app can finally say when a price was seen, and
        `TcgPrices.updatedAt` is null everywhere today because no provider states
        one. A row may carry its own observed_on, which wins over the argument -
        the table is not required to be all one day, since a card whose set a
        later sweep could not read keeps the older day it was actually read on,
        and a caller that re-offers stored rows has to be able to say so.

        An unchanged night writes nothing. The comparison is between the set the
        caller derived and the set the table holds, in one canonical form
        (price_fingerprint), so re-running an importer on a day it has already
        run costs one read and no write - the same bargain the card path strikes
        with its checksum, and the reason prices_revision is a signal a client
        can act on rather than a counter that moves every night regardless.
        """
        self.check_server()
        day = _day_text(observed_on)
        if not day:
            raise CatalogError(
                "a price row needs the day it was observed on: observed_on is "
                "the sampler's day, and a row without one cannot be dated")
        if not source:
            raise CatalogError("a price row needs the source it came from")

        derived = {}
        for row in rows:
            card_id = str(row.get("card_id") or "").strip()
            kind = str(row.get("kind") or "").strip()
            code = str(row.get("code") or "").strip()
            if not card_id:
                raise CatalogError(f"a price row needs a card id: {row!r}")
            if kind not in PRICE_KINDS:
                raise CatalogError(
                    f"a price row's kind is {kind!r}, and catalog_prices allows "
                    f"{' or '.join(PRICE_KINDS)}")
            if not code:
                raise CatalogError(f"a price row needs a code: {row!r}")
            row_day = _day_text(row.get("observed_on")) or day
            derived[(card_id, kind, code)] = {
                "card_id": card_id,
                "kind": kind,
                "code": code,
                "price": price_text(row.get("price")),
                "source": source,
                "observed_on": row_day,
            }

        carried_ids = self.card_ids_in_sets(game, carry_over_sets)
        stored = self.read_prices(game)

        # Tonight's set: everything the sweep read, plus the rows of the cards it
        # could not read. A derived row for a carried-over card is dropped rather
        # than kept - the night made no statement about that set, so the row that
        # survives is the one the last night that could read it wrote.
        effective = {key: row for key, row in derived.items() if key[0] not in carried_ids}
        carried = 0
        for row in stored:
            key = (str(row["card_id"]), str(row["kind"]), str(row["code"]))
            if key[0] in carried_ids:
                effective[key] = {
                    "card_id": key[0], "kind": key[1], "code": key[2],
                    "price": str(row["price"]), "source": str(row["source"]),
                    "observed_on": _day_text(row["observed_on"]),
                }
                carried += 1

        if not effective and stored and not allow_empty:
            raise CatalogError(
                f"refusing to empty {game!r} prices: the sweep derived no row at "
                f"all while the table holds {len(stored)}. A provider that answers "
                "nothing is likelier than a game whose every price vanished, and "
                "the replacement below would destroy the table on the strength of "
                "it. Pass allow_empty to mean it.")

        meta = {} if self.dry_run else self.read_meta(game)
        revision = int(meta.get("prices_revision") or 0)
        summary = {
            "rows": len(effective),
            "derived": len(effective) - carried,
            "carried": carried,
            "dropped": len(derived) - (len(effective) - carried),
            "carry_over_sets": sorted({str(c).strip().lower()
                                       for c in (carry_over_sets or ())}),
            "stored": len(stored),
            "observed_on": day,
            "source": source,
        }
        if price_fingerprint(stored) == price_fingerprint(effective.values()):
            summary.update({"outcome": "unchanged", "revision": revision})
            return summary

        sql = self._price_transaction(game, effective.values(), day)
        out = [line for line in self._run(sql).splitlines() if line.strip()]
        written = None
        if out and out[-1].strip().lstrip("-").isdigit():
            written = int(out[-1].strip())
        if written is None and not self.dry_run:
            # The transaction ends with `returning prices_revision`, so psql
            # prints the new value and this is the path nobody expects to take.
            # It reads the value back rather than adding one to a guess, because
            # a log line that is merely plausible is worse than an extra query.
            written = int(self.read_meta(game).get("prices_revision") or 0)
        summary.update({"outcome": "written", "revision": written,
                        "dry_run": self.dry_run})
        return summary

    def _price_transaction(self, game, rows, observed_on):
        """The whole of one game's price night, as a single transaction.

        Three statements and one commit. The delete is scoped to the game - never
        to the table, never to a set - because a game's prices are exactly what
        this replacement owns. The inserts follow inside the same transaction, so
        a browser reading through PostgREST sees yesterday's prices or tonight's
        and never a table with a hole in it; that is the whole reason the
        revision this statement moves means anything. And prices_revision moves
        with the rows it describes, returning the new value so the caller can log
        it rather than guess at it.
        """
        g = sql_literal(game)
        rows = list(rows)
        lines = ["begin;", ""]
        lines.append(f"delete from public.catalog_prices where game = {g};")
        lines.append("")

        columns = ("game",) + PRICE_COLUMNS + ("source", "observed_on")
        for start in range(0, len(rows), _PRICE_BATCH):
            rendered = []
            for row in rows[start:start + _PRICE_BATCH]:
                values = [g]
                for column in PRICE_COLUMNS:
                    value = row.get(column)
                    literal = sql_literal(value)
                    if value is not None and column in _NUMERIC_COLUMNS:
                        literal += "::numeric"
                    values.append(literal)
                values.append(sql_literal(row.get("source")))
                values.append(sql_literal(row.get("observed_on")))
                rendered.append("(" + ", ".join(values) + ")")
            lines.append(
                f"insert into public.catalog_prices ({', '.join(columns)})\nvalues\n"
                + ",\n".join(rendered) + ";")
            lines.append("")

        lines.append(
            "update public.catalog_meta set\n"
            "  prices_revision = prices_revision + 1,\n"
            f"  prices_observed_on = {sql_literal(observed_on)}\n"
            f"where game = {g}\n"
            "returning prices_revision;")
        lines.append("")
        lines.append("commit;")
        return "\n".join(lines)

    def set_list_fingerprint(self, game):
        """What the game's set list looks like right now.

        Taken before an import starts, and compared against the same reading
        taken after it, so that a set list which gained, lost or renamed a
        set moves sets_revision once. Reading it only at the end would compare
        the state after the import with the state after the import, which is
        always equal and always zero.
        """
        return set_fingerprint(self.read_sets(game))

    def finish(self, game, source=None, ok=True, note=None, upstream_codes=None,
               before_fingerprint=None):
        """Records the outcome, and moves sets_revision only if it should.

        Design rule 7: the game's set-list revision is incremented once, here,
        and only when the set list's content actually changed. Moving it on
        every run would make every browser re-download every set list every
        night for nothing.
        """
        self.check_server()
        if self.dry_run:
            # A dry run has no readings to reconcile against, because nothing
            # was read either. Saying so is more use than reporting a revision
            # that was never compared.
            print(f"---- dry run: catalog_meta for {game!r} would be written here ----")
            return {"revision": None, "sets": None, "cards": None,
                    "retired": None, "moved": None, "dry_run": True}
        before = self.read_meta(game)
        if before_fingerprint is None:
            # No reading was handed in, so the comparison below cannot be made
            # and the revision is left where it is rather than guessed at.
            before_fingerprint = self.set_list_fingerprint(game)

        if upstream_codes is not None:
            self.retire_sets(game, upstream_codes)

        # Compared against the reading taken before the import began, so the
        # fingerprint also notices a set appearing, disappearing or being
        # renamed upstream - any of which is a set list a client has to
        # re-download.
        revision = int(before.get("sets_revision") or 0)
        if before_fingerprint != self.set_list_fingerprint(game):
            revision += 1

        counts = self.count_rows(game)
        fields = {
            "sets_revision": revision,
            "set_count": counts["sets"],
            "card_count": counts["cards"],
            "last_import_ok": bool(ok),
            "last_import_note": note,
            "source": source,
        }
        assignments = ",\n  ".join(
            f"{k} = {sql_literal(v)}" for k, v in fields.items())
        sql = ("begin;\n"
               "update public.catalog_meta set\n  " + assignments +
               ",\n  sets_updated_at = now()\n"
               f"where game = {sql_literal(game)};\n"
               "commit;")
        self._run(sql)
        return {"revision": revision, "sets": counts["sets"], "cards": counts["cards"],
                "retired": counts["retired"], "moved": revision != int(before.get("sets_revision") or 0)}


def find_psql():
    """The psql to use, or a clear refusal."""
    path = shutil.which("psql")
    if not path:
        raise CatalogError(
            "no psql on PATH. This host has no Postgres driver, so the importer "
            "speaks to psql; install postgresql-client or run from the host.")
    return path
