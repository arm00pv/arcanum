#!/usr/bin/env python3
"""Poll live Disney Lorcana prices from Lorcast into a local history database.

Why this exists: Lorcast publishes live *current* prices and keeps no history,
and no free Lorcana price-history API exists anywhere - there is no archive to
backfill from and no paid key to buy. A day that is not sampled here is a day
the Lorcana charts will never have, so this script samples Lorcast once a day
and accumulates the series locally, the same way poll_pokemon_prices.py does for
Pokemon.

Lorcast is asked for one set at a time: /sets lists the 23 sets and
/sets/{code}/cards answers a whole set - about 3,200 cards in total - as a bare
JSON array of full card objects, so one request per set covers the game. The
prices ride on each card as decimal *strings* under prices.usd (non-foil) and
prices.usd_foil (foil), which is exactly the pair of finishes Lorcana physically
prints. A card Lorcast quotes no price for is written as nothing at all rather
than as a zero: an absent point says "unknown", and a zero would say "worthless".

Card ids are Lorcast's own ids (crd_...) stored verbatim, because that is the id
the app catalogues and asks the companion for.

It is free, keyless, resumable and safe to run from a scheduled task.

Since migration step 1 of docs/catalogue-server-side.md it does a second job:
the same 23 requests that feed the price series also fill the shared
`catalog_sets` and `catalog_cards` tables, so a browser no longer downloads
Lorcana's whole catalogue to answer a question whose answer is the same for
everybody. The sweep is the cheapest possible importer - the data is already in
hand - and `--catalog` is what switches the second job on.

The card rows it writes have to be the rows the Dart client would have written,
byte for byte, because both paths write into the same SQLite tables and a
holding names a card id. Every rule that derives a stored value from a Lorcast
object - the id, the composed name, the oracle id, the rarity's spelling, the
collector number's sort key, the JSON in `extras` - is therefore a transcription
of `lib/data/catalog/lorcana_catalog.dart` and `lib/domain/models/tcg_card.dart`,
and tests/catalog/catalog_id_parity_test.dart asserts the two agree against a
committed sample of real responses. A rule that drifts is a card that stops
resolving, and a card that stops resolving renders as `--`.

Usage:
    python poll_lorcana_prices.py                    # poll every set
    python poll_lorcana_prices.py --sets 1,2,P1      # poll only these sets
    python poll_lorcana_prices.py --limit 500        # stop after 500 cards
    python poll_lorcana_prices.py --skip-polled-today
    python poll_lorcana_prices.py --catalog          # also import the catalogue
    python poll_lorcana_prices.py --catalog-only     # import only, sample no prices

The importer takes the database URL from the environment, never from a
command-line argument, so the password does not appear in a process listing:

    set -a; . /home/zixen/arcanum/supabase.env; set +a
    python3 poll_lorcana_prices.py --catalog
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from urllib.parse import quote

import catalog_store

API = "https://api.lorcast.com/v0"
UA = "Arcanum/1.0 (+https://github.com/arcanum)"

# Lorcast's two price fields are the two finishes the game is printed in, so the
# mapping onto the app's finish codes is direct.
FINISH_MAP = {
    "usd": "nonfoil",
    "usd_foil": "foil",
}

# The history table matches the Magic and Pokemon databases exactly, so the
# companion service reads all three without knowing which game it is looking at.
SCHEMA = [
    """
    CREATE TABLE IF NOT EXISTS history (
        card_id TEXT NOT NULL,
        finish  TEXT NOT NULL,
        date    TEXT NOT NULL,
        price   REAL NOT NULL,
        PRIMARY KEY (card_id, finish, date)
    ) WITHOUT ROWID
    """,
    "CREATE INDEX IF NOT EXISTS idx_hist ON history(card_id, finish, date DESC)",
    """
    CREATE TABLE IF NOT EXISTS poll_state (
        card_id     TEXT PRIMARY KEY,
        last_polled TEXT NOT NULL
    )
    """,
]


def get_json(url, timeout=60, retries=3):
    """GETs a URL and decodes JSON, retrying transient failures."""
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            if attempt >= retries:
                raise
        except Exception:
            if attempt >= retries:
                raise
        time.sleep(0.4 * (attempt + 1))
    return None


def money(raw):
    """Parses one of Lorcast's decimal-string prices, or None when unusable.

    The provider sends prices as strings, leaves the field out entirely for a
    card it has no market data for, and is not above sending an empty string.
    Anything that is not a finite, strictly positive number is therefore an
    absence, never a zero.
    """
    if raw is None or isinstance(raw, bool):
        return None
    try:
        value = float(str(raw).strip())
    except (TypeError, ValueError):
        return None
    if not math.isfinite(value) or value <= 0:
        return None
    return value


def prices_of(card):
    """Extracts {finish_code: usd_price} from one Lorcast card object."""
    prices = card.get("prices")
    out = {}
    if isinstance(prices, dict):
        for field, finish in FINISH_MAP.items():
            value = money(prices.get(field))
            if value is not None:
                out[finish] = value
    return out


# ---------------------------------------------------------------------------
# The catalogue import: every rule that turns a Lorcast object into a stored row
# ---------------------------------------------------------------------------
#
# This half of the file is a transcription of the Dart client, and it is written
# that way on purpose. lib/data/catalog/lorcana_catalog.dart decides what a
# Lorcana card is; this decides what gets stored; both write into the same
# SQLite tables on the client, and a collection row names a card id. If the two
# disagree about an id, a name, a rarity or a sort key, the disagreement is
# invisible until somebody's holding renders as "--". So each function below
# names the Dart it mirrors, and test/catalog/catalog_id_parity_test.dart
# asserts the two agree over a committed sample of real responses.

# Two characters the Dart composes into card text, written as escapes because an
# invisible difference in either is precisely the drift the parity test exists to
# catch, and because a literal one survives neither an editor nor a copy.
NAME_DASH = "\u2013"        # U+2013 EN DASH, between a name and its subtitle
KEYWORD_JOIN = " \u00b7 "   # U+00B7 MIDDLE DOT, between a card's keywords

# Dart's RegExp \d and \D are ASCII only; Python's are Unicode-aware by default
# and would match '٣' where Dart does not. Written out rather than flagged so
# the rule is visible.
_NOT_DIGIT = r"[^0-9]"
_DIGIT = r"[0-9]"
_NUMERIC_PREFIX = re.compile(r"^(" + _NOT_DIGIT + r"*)(" + _DIGIT + r"+)")

# Dart's RegExp \s is a fixed set, and Python's str \s is a different one - it
# includes \x1c-\x1f and \x85, which Dart's does not. Written out for the same
# reason as the digits above: this feeds oracle ids, which group the "other
# printings" list.
_DART_SPACE = re.compile(
    "[ \t\n\v\f\r\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+")

# TcgCard.normaliseName drops everything outside this set after lower-casing.
_NOT_NAME_CHAR = re.compile(r"[^a-z0-9 ]")

# The art hosts, matching CardArt.host. The importer stores the URL the
# publisher's CDN serves rather than the browser's relay: a relayed URL is a
# fact about the platform reading it, and the row is the same row on a phone.
# Step 2's adapter is where a web client applies the relay, exactly as the
# provider path applies it while parsing.
_IMAGE_CDN = "https://tcgplayer-cdn.tcgplayer.com/product"


def dart_string(raw):
    """LorcanaCatalog._string: a trimmed string, or None when absent or blank."""
    text = "" if raw is None else str(raw).strip()
    return text or None


def dart_unquoted(raw):
    """LorcanaCatalog._unquoted: drops one pair of quotes wrapping the whole string.

    Lorcast quotes some subtitles whole - the Format Coconut cards read
    '"Spectacular Singer"' - while others quote legitimately, as Ursula's
    "Baby" does. Only a pair around the entire string goes, so a quoted phrase
    inside a subtitle survives.
    """
    text = ("" if raw is None else str(raw)).strip()
    if len(text) < 2:
        return text
    if text.startswith('"') and text.endswith('"'):
        return text[1:-1].strip()
    return text


def dart_string_list(raw):
    """LorcanaCatalog._stringList: the non-empty string entries of a list, in order."""
    if not isinstance(raw, list):
        return []
    out = []
    for value in raw:
        text = dart_string(value)
        if text is not None:
            out.append(text)
    return out


def dart_int(raw):
    """LorcanaCatalog._int: a whole number, or None when absent or not one.

    Lorcana's stats are null on the cards that have none - an Action has no
    strength, a Location has no lore - so a null here is a fact about the card.
    """
    if isinstance(raw, bool):
        return None
    if isinstance(raw, (int, float)):
        return int(raw)
    return dart_int_try_parse("" if raw is None else str(raw).strip())


def dart_int_try_parse(text):
    """Dart's int.tryParse, whose grammar is narrower than Python's int().

    Python accepts surrounding whitespace, underscores ('1_0' is ten) and
    non-ASCII digits; Dart accepts none of those and does accept a 0x prefix.
    Handing collector numbers to Python's int() would make '1_0' sort as ten on
    the server and as unparseable on the phone, so the grammar is spelled out.
    """
    if not isinstance(text, str) or not text:
        return None
    sign = 1
    body = text
    if body[:1] in ("+", "-"):
        if body[0] == "-":
            sign = -1
        body = body[1:]
    if not body:
        return None
    if body[:2].lower() == "0x":
        digits = body[2:]
        if not digits or not re.fullmatch(r"[0-9a-fA-F]+", digits):
            return None
        return sign * int(digits, 16)
    if not re.fullmatch(r"[0-9]+", body):
        return None
    return sign * int(body)


def dart_code_unit_at0(text):
    """The first UTF-16 code unit of a string, as Dart's codeUnitAt(0) gives it.

    Only reachable for a collector number beginning with an astral character,
    which Lorcana does not print - but the value feeds collector_sort, and
    Python's ord() would return the code point where Dart returns the high
    surrogate, so the two would disagree about where such a card sorts.
    """
    encoded = text.encode("utf-16-le")
    return encoded[0] | (encoded[1] << 8)


def collector_sort_key(collector_number):
    """TcgCard.collectorNumberSortKey, which is what fills collector_sort.

    Numeric prefixes sort numerically and anything else sorts after,
    alphabetically - which is how a binder is ordered. The two constants are
    Dart's: a plain number sorts as itself, an unparseable one sorts last.
    """
    trimmed = collector_number.strip()
    direct = dart_int_try_parse(trimmed)
    if direct is not None:
        return direct
    match = _NUMERIC_PREFIX.match(trimmed)
    if match:
        prefix = match.group(1) or ""
        digits = dart_int_try_parse(match.group(2)) or 0
        prefix_rank = 0 if not prefix else 1 + (dart_code_unit_at0(prefix) % 64)
        return prefix_rank * 1000000 + digits
    return 1 << 30


def normalise_name(name):
    """TcgCard.normaliseName, which is what fills oracle_id for Lorcana.

    Grouping printings needs a key the provider does not publish, so the
    composed display name is folded to lower case, stripped of punctuation and
    collapsed to single spaces.
    """
    base = name.split("//")[0]
    folded = base.lower()
    folded = _NOT_NAME_CHAR.sub("", folded)
    folded = _DART_SPACE.sub(" ", folded)
    return folded.strip()


def rarity_text(raw):
    """LorcanaCatalog._rarityText: 'Super_rare' becomes 'Super Rare'.

    Lorcast spells one tier with an underscore and that string is shown on the
    rarity badge and used as a filter facet, so the separator is normalised
    here rather than left as a wire artefact in the UI.
    """
    text = dart_string(raw)
    if text is None:
        return "unknown"
    return " ".join(
        word if not word else word[0].upper() + word[1:]
        for word in text.split("_"))


def type_line(types, classifications):
    """LorcanaCatalog._typeLine: 'Character - Storyborn, Hero' or 'Action, Song'."""
    joined = ", ".join(types)
    if not classifications:
        return joined or None
    traits = ", ".join(classifications)
    return traits if not joined else f"{joined} - {traits}"


def rules_text(card):
    """LorcanaCatalog._rulesText: the text, with its keywords joined onto the end.

    A keyword such as Evasive is printed on the card but is not always spelled
    out in 'text', and search reads this field, so the keywords are appended
    rather than dropped.
    """
    raw = card.get("text")
    buffer = "" if raw is None else str(raw).strip()
    keywords = dart_string_list(card.get("keywords"))
    if keywords:
        if buffer:
            buffer += "\n\n"
        buffer += KEYWORD_JOIN.join(keywords)
    out = buffer.strip()
    return out or None


def price_value(raw):
    """LorcanaCatalog._price: a decimal string, or None.

    An absent or unparseable value is null rather than zero: a card the
    provider has no market for is unpriced, and zero would read as a real
    quote. Poll's money() is the same rule with a stricter eye, so the two
    agree about what counts as a price.
    """
    if raw is None:
        return None
    text = str(raw).strip()
    if not text:
        return None
    try:
        return float(text)
    except ValueError:
        return None


def image_uris(card, tcgplayer_id):
    """LorcanaCatalog._images: TCGplayer's JPEG when there is a product, else Lorcast.

    Lorcast serves only AVIF, which Flutter cannot be relied on to decode, so
    the JPEG on TCGplayer's CDN is used whenever the card carries the
    tcgplayer_id those URLs are keyed by. Lorcast's own URL is the fallback for
    the printings that have none, which in practice are the promos.
    """
    if tcgplayer_id is not None:
        base = f"{_IMAGE_CDN}/{tcgplayer_id}"
        return {
            "small": f"{base}_200w.jpg",
            "normal": f"{base}_400w.jpg",
            "large": f"{base}_in_1000x1000.jpg",
        }
    uris = card.get("image_uris")
    digital = uris.get("digital") if isinstance(uris, dict) else None
    if isinstance(digital, dict):
        out = {}
        for size in ("small", "normal", "large"):
            url = dart_string(digital.get(size))
            if url is not None:
                out[size] = url
        if out:
            return out
    return {}


def card_document(card, fallback_set_code=None):
    """One Lorcast card object as a catalog_cards row, or None for one with no id.

    Returns None for an object with no id, exactly as the Dart does: such a row
    cannot be opened, priced or deduplicated, and every endpoint that produces
    cards filters it out rather than putting an unreachable row on screen.
    """
    card_id = dart_string(card.get("id"))
    if card_id is None:
        return None

    name = dart_unquoted(card.get("name") or "")
    version = dart_unquoted(card.get("version") or "")
    # Lorcana prints many different cards under one name and 'version' is what
    # separates them, so the subtitle belongs in the name and in the oracle id
    # built from it. A row reading only "Elsa" is ambiguous between a dozen
    # unrelated printings.
    # Spaces around the dash, exactly as lorcana_catalog.dart composes it:
    # version.isEmpty ? name : '$name – $version'. Dropping either space
    # still reads correctly on screen and quietly changes both the displayed
    # name and the oracle id built from it.
    display_name = name if not version else f"{name} {NAME_DASH} {version}"

    set_map = card.get("set")
    if not isinstance(set_map, dict):
        set_map = {}
    set_code = (dart_string(set_map.get("code")) or fallback_set_code or "").lower()

    inks = dart_string_list(card.get("inks"))
    single = dart_string(card.get("ink"))
    # 'inks' is the full list - a handful of cards are two inks - while 'ink'
    # is Lorcast's single-ink shorthand. The list wins, and the shorthand is
    # read only when the list is absent, so a card with no ink ends up with no
    # colour rather than a guessed one.
    colors = inks if inks else ([] if single is None else [single])

    classifications = dart_string_list(card.get("classifications"))
    legalities = card.get("legalities")
    released = dart_string(card.get("released_at"))
    tcgplayer_id = dart_string(card.get("tcgplayer_id"))
    images = image_uris(card, tcgplayer_id)

    extras = {
        "inkwell": card.get("inkwell") is True,
    }
    if tcgplayer_id is not None:
        extras["tcgplayerId"] = tcgplayer_id
    for key, source in (("strength", "strength"), ("willpower", "willpower"),
                        ("lore", "lore"), ("moveCost", "move_cost")):
        value = dart_int(card.get(source))
        if value is not None:
            extras[key] = value
    if classifications:
        extras["classifications"] = classifications
    if isinstance(legalities, dict) and legalities:
        extras["legalities"] = {str(k): v for k, v in legalities.items()}

    return {
        "id": card_id,
        "oracle_id": normalise_name(display_name),
        "set_code": set_code,
        "set_name": dart_string(set_map.get("name")) or set_code,
        "name": display_name,
        "collector_number": "" if card.get("collector_number") is None
                            else str(card.get("collector_number")),
        "collector_sort": collector_sort_key(
            "" if card.get("collector_number") is None
            else str(card.get("collector_number"))),
        "rarity": rarity_text(card.get("rarity")),
        # Empty rather than the payload's "normal": LorcanaCatalog never sets
        # TcgCard.layout, so the client stores the field's default and a
        # server row carrying "normal" would not be the row the client
        # writes. This is the one field where copying the provider instead of
        # the client is wrong, and the parity test is what noticed.
        "layout": "",
        "type_line": type_line(dart_string_list(card.get("type")), classifications),
        "oracle_text": rules_text(card),
        "mana_cost": None,
        "cmc": float(card["cost"]) if isinstance(card.get("cost"), (int, float))
               and not isinstance(card.get("cost"), bool) else None,
        "colors": ",".join(colors),
        "color_identity": ",".join(colors),
        "artist": ", ".join(dart_string_list(card.get("illustrators"))) or None,
        "flavor_text": dart_string(card.get("flavor_text")),
        "image_small": images.get("small"),
        "image_normal": images.get("normal"),
        "image_large": images.get("large"),
        "image_art_crop": None,
        "image_png": None,
        "back_image_small": None,
        "back_image_normal": None,
        "digital": False,
        "promo": False,
        "reprint": False,
        "reserved": False,
        "full_art": False,
        "booster": False,
        "foil": False,
        "nonfoil": False,
        "edhrec_rank": None,
        "released_at": released,
        "extras": extras,
    }


def set_type_for(code, name):
    """LorcanaCatalog._setTypeFor: the split the provider's own naming describes.

    The promo runs are numbered P1, P2, P3 with a Q series beside them, and the
    odd event set is a named promo instead - 'cp', Challenge Promo. Everything
    else is a retail expansion. A set-type filter is only worth offering if the
    split means something, so this is the split Lorcast's naming states.
    """
    upper = code.strip().upper()
    is_promo = (upper.startswith("P") or upper.startswith("Q")
                or "promo" in name.lower())
    return "promo" if is_promo else "expansion"


def set_document(item):
    """One Lorcast set object as a catalog_sets row, or None for one with no code.

    card_count stays 0: the set list publishes no card count and the only way
    to learn one is to download the set, so a zero here means "the provider
    does not say" rather than "empty". card_row_count is what the import
    records after actually counting them, and the two are read together by the
    app's isCatalogued rule.
    """
    code = dart_string(item.get("code"))
    if code is None:
        return None
    name = item.get("name")
    name = code if name is None else str(name)
    return {
        "code": code.lower(),
        "id": dart_string(item.get("id")) or code,
        "name": name,
        "set_type": set_type_for(code, name),
        "released_at": dart_string(item.get("released_at")),
        "card_count": 0,
        "printed_size": None,
        "icon_svg_uri": None,
        "logo_uri": None,
        "series": None,
        "digital": False,
        "foil_only": False,
        "nonfoil_only": False,
        "parent_set_code": None,
        "block_code": None,
        "block": None,
        "collector_number_start": None,
    }


def set_list(timeout=60, retries=3):
    """Every set object Lorcast publishes, in the order it publishes them.

    The price sweep needs only the codes, but the catalogue import needs each
    set owner's name, id and release date as well, so the list is read once and
    both jobs are served from it.
    """
    data = get_json(f"{API}/sets", timeout=timeout, retries=retries)
    results = data.get("results") if isinstance(data, dict) else data
    return [item for item in (results or []) if isinstance(item, dict)]


def set_codes(timeout=60, retries=3):
    """Every set code, spelled exactly as Lorcast spells it.

    The casing is not decoration: the provider answers /sets/P1/cards and 404s
    /sets/p1/cards, so the code from this list is the only safe thing to request.
    """
    out = []
    for item in set_list(timeout=timeout, retries=retries):
        code = item.get("code")
        if isinstance(code, str) and code.strip():
            out.append(code.strip())
    return out


def cards_for_set(code, timeout=60, retries=3):
    """Every card object in one set, as a bare JSON array.

    A set Lorcast does not answer for is an error rather than an empty set. The
    codes are case-sensitive - "P1" answers and "p1" is a 404 - so a silent zero
    here would be indistinguishable from a set that genuinely holds no cards,
    and a whole set would go unsampled without a word in the log.
    """
    data = get_json(f"{API}/sets/{quote(code, safe='')}/cards", timeout=timeout, retries=retries)
    if data is None:
        raise ValueError(f"Lorcast has no set {code!r} (its codes are case-sensitive)")
    if not isinstance(data, list):
        raise ValueError(f"expected a bare card array, got {type(data).__name__}")
    return [c for c in data if isinstance(c, dict)]


def connect(db_path):
    """Opens the history database, creating it and its schema when absent."""
    parent = os.path.dirname(os.path.abspath(db_path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    con = sqlite3.connect(db_path)
    for stmt in SCHEMA:
        con.execute(stmt)
    con.commit()
    return con


def write_points(con, rows, state=()):
    """Writes one batch of (card_id, finish, date, price) points.

    This is the only insert path this script has, so a run is idempotent: the
    primary key is (card_id, finish, date) and every write replaces, which means
    sampling twice on one day leaves exactly one row per card and finish.

    A batch is one transaction. A run that dies part way through therefore keeps
    every batch already committed and loses at most the batch in flight, rather
    than leaving a half-written day behind.
    """
    with con:
        if rows:
            con.executemany("INSERT OR REPLACE INTO history VALUES (?,?,?,?)", rows)
        if state:
            con.executemany("INSERT OR REPLACE INTO poll_state VALUES (?,?)", state)
    return len(rows)


def import_catalogue_set(store, code, cards, docs, args):
    """Writes one set into the shared catalogue, or reports that it could not be.

    None means the set was not written, and the caller counts that as a failure
    so catalog_meta.last_import_ok says so. A quietly skipped set is the
    failure mode this whole design is trying to make visible.

    A set whose metadata was never read - which happens only under --sets on a
    host that cannot reach /sets - is written under the minimum the foreign key
    needs and nothing more, rather than being skipped.
    """
    doc = docs.get(code.lower())
    if doc is None:
        doc = {"code": code.lower(), "id": code, "name": code}
    documents = []
    for card in cards:
        built = card_document(card, code.lower())
        if built is not None:
            documents.append(built)
    try:
        return store.import_set("lorcana", doc, documents,
                                allow_empty=args.allow_empty_set)
    except catalog_store.CatalogError as exc:
        print(f"  set {code} not imported: {exc}", file=sys.stderr, flush=True)
        return None


def record_catalogue_outcome(store, upstream, sets_written, cards_written,
                             sets_unchanged, failed_sets, before_fingerprint):
    """Writes catalog_meta for the run, whether it went well or not.

    Design rule 5: a broken importer has to be a fact a client can read, so
    last_import_ok is written on the failure path too and not only on the happy
    one.

    upstream is the provider owner's whole set list, and it deliberately includes
    the sets whose cards failed to download - those sets are still published,
    and retiring them because one response went wrong would hide cards that are
    perfectly well catalogued. It is None when this run named a subset of sets
    with --sets, because then "not in the list" means "not asked for" rather
    than "withdrawn", and retiring the rest of the game would be a catastrophe
    dressed as tidiness.
    """
    note = (f"{len(upstream) if upstream else 0} sets upstream, {sets_written} written, "
            f"{sets_unchanged} unchanged, {cards_written} cards, "
            f"{failed_sets} set(s) failed")
    return store.finish("lorcana", source="lorcast", ok=failed_sets == 0,
                        note=note, upstream_codes=upstream,
                        before_fingerprint=before_fingerprint)


def parse_args(argv=None):
    ap = argparse.ArgumentParser()
    default_db = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "lorcana_prices.db")
    ap.add_argument("--db", default=default_db, help="history database to write")
    ap.add_argument("--out", default=None, help="alias for --db, for callers that name the output")
    ap.add_argument("--sets", default="", help="comma-separated set codes; default is all")
    ap.add_argument("--limit", type=int, default=0, help="stop after N cards (0 = no limit)")
    ap.add_argument("--delay", type=float, default=0.4,
                    help="seconds to wait between set requests (politeness)")
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--retries", type=int, default=3)
    ap.add_argument("--skip-polled-today", action="store_true",
                    help="do not rewrite cards already sampled today (use for a re-run)")
    ap.add_argument("--catalog", action="store_true",
                    help="also write sets and cards into the shared catalogue")
    ap.add_argument("--catalog-only", action="store_true",
                    help="import the catalogue and sample no prices")
    ap.add_argument("--lock", default="/tmp/arcanum-catalog.lock",
                    help="flock file, so two catalogue imports cannot interleave")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the SQL the catalogue import would run, and run none")
    ap.add_argument("--allow-empty-set", action="store_true",
                    help="let a set the provider answers with no cards be emptied here")
    return ap.parse_args(argv)


def open_store(args):
    """The catalogue write path, or a refusal.

    The URL comes from the environment and never from a command-line argument.
    An argument is readable in a process listing by every user on the host, and
    the session pooler URL carries the database password - the one secret this
    deployment keeps in a mode-600 file and nowhere else.
    """
    url = os.environ.get("SUPABASE_DB_URL") or os.environ.get("SUPABASE_DB_URL_POOLED")
    if not url:
        print("--catalog needs SUPABASE_DB_URL (or SUPABASE_DB_URL_POOLED) in the "
              "environment; see /home/zixen/arcanum/supabase.env", file=sys.stderr)
        return None
    return catalog_store.CatalogStore(url, dry_run=args.dry_run,
                                      psql=catalog_store.find_psql())


def main():
    args = parse_args()
    if args.catalog_only:
        args.catalog = True

    if args.catalog and args.limit:
        # A truncated download written as though it were the whole set would
        # delete the cards the limit skipped, because writing a set replaces
        # that set. The two flags contradict each other, so they are refused
        # together rather than quietly producing a smaller catalogue.
        print("--limit and --catalog contradict each other: a partial set would "
              "be imported as a complete one", file=sys.stderr)
        return 2

    store = None
    if args.catalog:
        store = open_store(args)
        if store is None:
            return 2

    if store is None:
        return run(args, None)
    # Design rule 6: the lock is held for the whole run, so a hand-run import
    # and the nightly timer cannot interleave.
    try:
        with catalog_store.single_flight(args.lock):
            return run(args, store)
    except catalog_store.CatalogError as exc:
        print(f"catalogue import refused: {exc}", file=sys.stderr)
        return 1


def run(args, store):
    db = args.out or args.db
    con = connect(db)
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    # ---- work out which sets to read
    #
    # Two spellings of a set code are in play and both are needed. A request
    # needs the provider owner's spelling: /sets/P1/cards answers and
    # /sets/p1/cards is a 404. The catalogue stores the lower-case form,
    # because that is the casing every other layer of the app stores and
    # queries. So "codes" is what gets asked for and "docs" is what gets
    # written.
    listing = []
    if args.sets:
        codes = [s.strip() for s in args.sets.split(",") if s.strip()]
        if store is not None:
            listing = set_list(timeout=args.timeout, retries=args.retries)
    else:
        listing = set_list(timeout=args.timeout, retries=args.retries)
        codes = [c for c in (dart_string(i.get("code")) for i in listing) if c]

    docs = {}
    if store is not None:
        wanted = {c.lower() for c in codes}
        for item in listing:
            doc = set_document(item)
            if doc is not None and doc["code"] in wanted:
                docs[doc["code"]] = doc

    print(f"{len(codes)} sets to scan", flush=True)
    if not codes:
        print("nothing to do", flush=True)
        con.close()
        return 0

    already = set()
    if args.skip_polled_today:
        already = {
            row[0] for row in con.execute(
                "SELECT card_id FROM poll_state WHERE last_polled = ?", (today,)
            )
        }
        print(f"{len(already)} cards already sampled today", flush=True)

    # ---- sample
    # Taken before a single row is written. sets_revision is the signal that
    # tells every browser its set list is stale, and it is only meaningful if
    # the comparison is against the list as it stood before this run.
    #
    # A catalogue that cannot be reached is a catalogue problem and not a price
    # problem. The series this sweep samples cannot be backfilled from anywhere,
    # so a database that is down at 04:40 has to cost the catalogue a night
    # rather than cost the day its prices: dropping the import here leaves the
    # run a plain price sample, the record in catalog_meta keeps whatever it
    # said yesterday, and check_catalog_freshness.py reports the stale
    # catalogue in the morning. The per-set import below is already survivable -
    # a set that fails is counted and the sampling continues - and this is the
    # one catalogue read that happens before any price is written.
    before_fingerprint = None
    if store is not None:
        try:
            before_fingerprint = store.set_list_fingerprint("lorcana")
        except catalog_store.CatalogError as exc:
            print(f"catalogue unreachable, sampling prices without importing: {exc}",
                  file=sys.stderr, flush=True)
            store = None

    t0 = time.time()
    seen = 0
    written = 0
    unpriced = 0
    failed_sets = 0
    catalogued_sets = 0
    catalogued_cards = 0
    unchanged_sets = 0

    for i, code in enumerate(codes, 1):
        if args.limit and seen >= args.limit:
            break
        try:
            cards = cards_for_set(code, timeout=args.timeout, retries=args.retries)
        except Exception as exc:
            failed_sets += 1
            print(f"  set {code} failed: {exc}", file=sys.stderr, flush=True)
            time.sleep(args.delay)
            continue

        if store is not None:
            outcome = import_catalogue_set(store, code, cards, docs, args)
            if outcome is None:
                failed_sets += 1
            else:
                catalogued_sets += 1
                catalogued_cards += outcome["cards"]
                if outcome["outcome"] == "unchanged":
                    unchanged_sets += 1
            if args.catalog_only:
                if i < len(codes):
                    time.sleep(args.delay)
                continue

        rows = []
        state = []
        for card in cards:
            if args.limit and seen >= args.limit:
                break
            card_id = card.get("id")
            if not isinstance(card_id, str) or not card_id.strip():
                continue
            card_id = card_id.strip()
            seen += 1
            if card_id in already:
                continue
            prices = prices_of(card)
            if not prices:
                unpriced += 1
            for finish, price in prices.items():
                rows.append((card_id, finish, today, price))
            state.append((card_id, today))

        written += write_points(con, rows, state)
        print(f"  set {i}/{len(codes)} {code}: {len(cards)} cards, {len(rows)} points", flush=True)
        if i < len(codes):
            time.sleep(args.delay)

    total = con.execute("SELECT COUNT(*) FROM history").fetchone()[0]
    cards_held = con.execute("SELECT COUNT(DISTINCT card_id) FROM history").fetchone()[0]
    days = con.execute("SELECT COUNT(DISTINCT date) FROM history").fetchone()[0]
    con.close()
    try:
        size = os.path.getsize(db) / (1024 * 1024)
    except OSError:
        size = 0.0

    print("", flush=True)
    print(f"done in {int(time.time() - t0)}s — {written} points written, {failed_sets} set(s) failed", flush=True)
    print(f"{len(codes)} sets read, {seen:,} cards seen, {unpriced:,} with no price at all", flush=True)
    print(f"database now holds {total:,} points across {cards_held:,} cards and {days} day(s), {size:.2f} MB", flush=True)
    print(f"  {db}", flush=True)

    if store is not None:
        # A run that named a subset must not retire the sets it did not ask
        # for, so the upstream list is withheld in that case.
        #
        # Lower-cased, because retirement compares against the code the
        # catalogue stores and Lorcast spells ten of its twenty-four in upper
        # case - P1, D23, Coconut and the rest. Passing the provider's own
        # spelling retires exactly those ten.
        upstream = None if args.sets else [c.lower() for c in codes]
        summary = record_catalogue_outcome(store, upstream, catalogued_sets,
                                           catalogued_cards, unchanged_sets,
                                           failed_sets, before_fingerprint)
        print("", flush=True)
        if summary.get("dry_run"):
            print("dry run: no catalogue row was written", flush=True)
        else:
            print(f"catalogue holds {summary['sets']:,} sets and {summary['cards']:,} cards, "
                  f"sets_revision {summary['revision']}", flush=True)

    return 1 if failed_sets and failed_sets == len(codes) else 0


if __name__ == "__main__":
    raise SystemExit(main())
