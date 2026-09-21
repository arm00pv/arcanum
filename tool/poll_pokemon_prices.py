#!/usr/bin/env python3
"""Poll live Pokemon TCG prices from TCGdex into a local history database.

Why this exists: no free, live, per-card Pokemon price-history API exists.
TCGdex publishes live *current* prices but keeps no history, and the community
price archive on GitHub stopped updating in September 2024. This script closes
that gap by sampling TCGdex once a day and accumulating the series locally, so
Arcanum can chart real Pokemon trends without a paid key.

It is free, keyless, resumable and safe to run from a scheduled task.

Since migration step 5 of docs/catalogue-server-side.md it does a second job:
the same sweep that samples prices also fills the shared catalog_sets and
catalog_cards tables, so a browser no longer downloads every Pokemon card to
answer a question whose answer is the same for everybody. The sweep is the
cheapest possible importer - every full card object is already being fetched to
read its prices - and --catalog is what switches the second job on.

The card rows it writes have to be the rows the Dart client would have written,
column for column, because both paths write into the same SQLite tables and a
holding names a card id. Every rule that derives a stored value from a TCGdex
object - the oracle id, the composed type line, the rules text, the rarity, the
collector sort key, the art URLs, the JSON in extras - is therefore a
transcription of lib/data/catalog/pokemon_catalog.dart and
lib/domain/models/tcg_card.dart, and test/catalog/catalog_id_parity_test.dart
asserts the two agree over a committed sample of real responses. A rule that
drifts is a card that stops resolving, and a card that stops resolving renders
as "--".

Two of those rules are shared with every other game and are *imported* from
poll_lorcana_prices.py rather than transcribed a second time: normalise_name is
TcgCard.normaliseName and collector_sort_key is
TcgCard.collectorNumberSortKey. Two implementations of one rule is the
likeliest way this design quietly stops working.

Usage:
    python poll_pokemon_prices.py                    # poll every card
    python poll_pokemon_prices.py --limit 500        # poll only 500 cards
    python poll_pokemon_prices.py --sets base1,sv01
    python poll_pokemon_prices.py --skip-polled-today
    python poll_pokemon_prices.py --catalog          # also import the catalogue
    python poll_pokemon_prices.py --catalog-only     # import only, sample no prices

The importer takes the database URL from the environment, never from a
command-line argument, so the password does not appear in a process listing:

    set -a; . /home/zixen/arcanum/supabase.env; set +a
    python3 poll_pokemon_prices.py --catalog
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

import catalog_store

# The two shared rules and one shared constant. They live in the Lorcana poller
# because Lorcana needed them first, and nothing about them is Lorcana-specific:
# they are transcriptions of TcgCard.normaliseName and
# TcgCard.collectorNumberSortKey, which every game's client calls.
#
# KEYWORD_JOIN is the middle dot the Dart writes with spaces around it. Pokemon
# uses it for an attack's energy cost where Lorcana uses it between keywords;
# the two characters are the same two characters, so it is imported rather than
# typed a second time - an invisible difference in either is exactly the drift
# the parity test exists to catch.
from poll_lorcana_prices import (  # noqa: E402  (same directory as this file)
    KEYWORD_JOIN,
    collector_sort_key,
    normalise_name,
)

API = "https://api.tcgdex.net/v2/en"
UA = "Arcanum/1.0 (+https://github.com/arcanum)"

# TCGdex/TCGplayer variant key -> Arcanum finish code, for the price series.
#
# This map is the *price* path's and is left exactly as it was. It is not the
# catalogue's: card rows carry no prices, and the finishes a card was printed in
# come from the card's variants map instead (see variant_types). The pricing
# block's own keys are TCGdex's to change - it now publishes "reverse-holofoil"
# where this map and the Dart client both say "reverseholofoil" - and a key
# neither has heard of contributes no price row rather than a row guessed at.
FINISH_MAP = {
    "normal": "nonfoil",
    "holofoil": "holofoil",
    "unlimitedholofoil": "holofoil",
    "reverseholofoil": "reverse_holofoil",
    "1stedition": "first_edition",
    "1steditionholofoil": "first_edition_holofoil",
}

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


def get_json(url, timeout=30, retries=3):
    """GETs a URL and decodes JSON, retrying transient failures.

    A 404 is answered as None rather than raised, and that distinction is load
    bearing for the catalogue import: it is the one answer that says "the
    provider will not address this", as opposed to "this went wrong just now".
    """
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


# ---------------------------------------------------------------------------
# The sweep: sets, cards and prices
# ---------------------------------------------------------------------------


def finish_prices(card):
    """Extracts {finish_code: usd_price} from a TCGdex card response.

    Unchanged from the price sampler this file has always been. A zero is not a
    price, so a 0.00 marketPrice contributes no row; a variant key the map has
    never heard of contributes nothing either; and a card with no market data
    contributes nothing rather than a row saying zero.
    """
    pricing = card.get("pricing") or {}
    tcg = pricing.get("tcgplayer")
    out = {}
    if isinstance(tcg, dict):
        for key, value in tcg.items():
            if not isinstance(value, dict):
                continue
            price = value.get("marketPrice") or value.get("midPrice")
            finish = FINISH_MAP.get(str(key).lower())
            if finish and isinstance(price, (int, float)) and price > 0:
                out.setdefault(finish, float(price))
    # Fall back to the variants list when the flat pricing block is absent.
    if not out:
        for variant in card.get("variants_detailed") or []:
            if not isinstance(variant, dict):
                continue
            vpricing = (variant.get("pricing") or {}).get("tcgplayer")
            if not isinstance(vpricing, dict):
                continue
            for key, value in vpricing.items():
                if not isinstance(value, dict):
                    continue
                price = value.get("marketPrice") or value.get("midPrice")
                finish = FINISH_MAP.get(str(key).lower()) or FINISH_MAP.get(
                    str(variant.get("type", "")).lower())
                if finish and isinstance(price, (int, float)) and price > 0:
                    out.setdefault(finish, float(price))
    return out


def set_list():
    """Every set object TCGdex lists, in the order it lists them.

    The price sweep needs only the ids, but the catalogue import needs each
    set's published card count and name as well, so the list is read once and
    both jobs are served from it.
    """
    data = get_json(f"{API}/sets")
    if not isinstance(data, list):
        return []
    return [item for item in data if isinstance(item, dict) and item.get("id")]


def stubs_of(body):
    """The brief card entries one set response carries, in order.

    TCGdex lists a set's cards as (id, localId, name, image) and nothing else -
    no rarity, no types, no text - which is why the client, and this script,
    fetch a full object per card. These are the same entries the price sweep has
    always taken the card ids from, and the entries the client falls back to
    when a card's own call fails.
    """
    if not isinstance(body, dict):
        return []
    cards = body.get("cards")
    if not isinstance(cards, list):
        return []
    return [c for c in cards if isinstance(c, dict) and c.get("id")]


def set_detail(set_id):
    """One set's own response: its metadata, its card stubs and its series.

    A set TCGdex does not answer for is an error rather than an empty set. The
    price sweep used to answer a failed set response with an empty card list,
    which is indistinguishable from a set that genuinely holds no cards: a whole
    set went unsampled without a word in the log, and - now that the same
    response feeds the catalogue - it would have been imported as empty. It is
    raised here instead, and the caller counts it as a failed set.

    The two things the catalogue needs beyond the price sweep's card ids come
    from this same response: the set's own metadata, which fills its catalog_sets
    row, and the series slug, which the art fallback needs.
    """
    data = get_json(f"{API}/sets/{set_id}")
    if not isinstance(data, dict):
        raise ValueError(f"TCGdex answered no set object for {set_id!r}")
    return data


def card_ids_for_set(set_id):
    """Every card id TCGdex lists for one set, in the order it lists them.

    The id-only form of set_detail, kept because it is the importer's entire
    relationship with a Pokemon card id: the id a set response lists is the id a
    card is fetched by and the id every price is sampled under. Nothing about it
    is derived, which is what tool/catalog/test_id_parity.py states as a test.
    """
    return [c["id"] for c in stubs_of(set_detail(set_id))]


def serie_id(body):
    """The series slug a set response carries, for the art URL fallback.

    TCGdex's asset CDN addresses art as en/<serie>/<set>/<number>/high.webp, so
    a card whose own response carries no image needs this slug: a URL built from
    the set id alone answers 404.
    """
    serie = body.get("serie") if isinstance(body, dict) else None
    return dart_to_string(serie.get("id")) if isinstance(serie, dict) else None


def fetch_cards(card_ids, workers):
    """Fetches one full card object per id, at the poller's own concurrency.

    Returns (card_id, card, error) for each id, and the three outcomes are
    deliberately distinct: an object, None for a card the provider answered 404
    for, and an exception for one that could not be read at all. The price path
    treats the last two alike - both are a card with no prices today - while the
    catalogue has to tell them apart, because a 404 is a fact about the card and
    a timeout is not.

    The URL is built exactly as the price sweep has always built it, with the id
    dropped into the path unescaped, and that is not laziness: it is also the
    request the Dart client builds. TCGdex's one id that needs escaping
    ("exu-%3F") therefore 404s for both, and both store the same fallback row
    for it. See stub_document.
    """

    def fetch(card_id):
        try:
            return card_id, get_json(f"{API}/cards/{card_id}"), None
        except Exception as exc:  # noqa: BLE001 - get_json has already retried
            return card_id, None, exc

    out = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        for item in pool.map(fetch, card_ids):
            out.append(item)
    return out


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
    """Writes one set's worth of (card_id, finish, date, price) points.

    This is the only insert path this script has, so a run is idempotent: the
    primary key is (card_id, finish, date) and every write replaces, which means
    sampling twice on one day leaves exactly one row per card and finish.

    A set is one transaction, so a run that dies part way through keeps every
    set already committed rather than leaving a half-written day behind.
    """
    with con:
        if rows:
            con.executemany("INSERT OR REPLACE INTO history VALUES (?,?,?,?)", rows)
        if state:
            con.executemany("INSERT OR REPLACE INTO poll_state VALUES (?,?)", state)
    return len(rows)


# ---------------------------------------------------------------------------
# The catalogue import: every rule that turns a TCGdex object into a stored row
# ---------------------------------------------------------------------------
#
# This half of the file is a transcription of the Dart client, and it is written
# that way on purpose. lib/data/catalog/pokemon_catalog.dart decides what a
# Pokemon card is; this decides what gets stored; both write into the same
# SQLite tables on the client, and a collection row names a card id. If the two
# disagree about an id, a name, a rarity, a sort key, a type line or an image
# URL, the disagreement is invisible until somebody's holding renders as "--".
# So each function below names the Dart it mirrors, and
# tool/catalog/test_id_parity.py asserts the two agree over a committed sample
# of real responses, over every column of a card row and of a set row.

# Card images are addressed under this prefix, exactly as PokemonCatalog._assets
# spells it.
ASSETS = "https://assets.tcgdex.net/en"

# The first word of a Pokemon type line, with the accent the Dart composes it
# with. Written as an escape because an invisible difference in it is precisely
# the drift the parity test exists to catch.
POKEMON_TYPE = "Pok\u00e9mon"       # U+00E9 LATIN SMALL LETTER E WITH ACUTE

# The date shape TCGdex publishes, and the only one this file reads.
_ISO_DATE = re.compile(r"^([0-9]{4})-([0-9]{2})-([0-9]{2})")


def dart_to_string(raw):
    """Dart's Object.toString(), which is what every ?.toString() here calls.

    TCGdex puts strings, numbers and booleans in the same field depending on the
    card - a damage is 30 on one attack and "10+" on the next - and the Dart
    writes every one of them through ?.toString(). So 30 becomes "30", and only
    a null stays null: not the empty string, and not a substituted default. That
    last distinction is the one this function exists for, because Python's str()
    would answer "True" for a boolean and "30.0" for an integer-valued double in
    a place where Dart answers "true" and "30".
    """
    if raw is None:
        return None
    if raw is True:
        return "true"
    if raw is False:
        return "false"
    if isinstance(raw, str):
        return raw
    if isinstance(raw, int):
        return str(raw)
    if isinstance(raw, float):
        # Dart prints an integral double with its .0 ("30.0"), and Python's repr
        # does the same for every value TCGdex publishes.
        return repr(raw)
    return str(raw)


def dart_list_join(raw, separator):
    """Dart's List.join: every element through toString, a null included.

    An attack's cost is a list of energy names and the client joins it with the
    middle dot. Anything that is not a list joins to the empty string, which is
    what "cost is List ? cost.join(...) : ''" says.
    """
    if not isinstance(raw, list):
        return ""
    parts = []
    for value in raw:
        text = dart_to_string(value)
        parts.append("null" if text is None else text)
    return separator.join(parts)


def dart_double(raw):
    """The (x as num?)?.toDouble() in the catalog: a number, or None.

    Not a text parse: the Dart cast throws on "80" rather than answering null,
    so a string hp is an absence here as well rather than a number.
    """
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        return None
    return float(raw)


def dart_int(raw):
    """The (x as num?)?.toInt() in the catalog: a whole number, or None."""
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        return None
    return int(raw)


def dart_date(raw):
    """DateTime.tryParse(...) then toIso8601String().split('T').first.

    What reaches the released_at column is the calendar day of the parsed
    DateTime, which for every shape TCGdex publishes is the day the string
    names: a date-only string parses at midnight local, and a timestamp carrying
    an offset parses to that instant, whose ISO form names the same day.

    A string that is not a date at all parses to null and is stored as null. One
    whose month or day is out of range is stored as null too, where Dart would
    normalise it - "1999-13-45" becomes the next year to DateTime.parse - because
    a date the provider never published is a worse thing to put in a sort column
    than no date, and TCGdex publishes the calendar dates it holds itself.
    """
    text = dart_to_string(raw)
    if text is None:
        return None
    match = _ISO_DATE.match(text)
    if not match:
        return None
    year, month, day = (int(match.group(index)) for index in (1, 2, 3))
    if not (1 <= month <= 12 and 1 <= day <= 31):
        return None
    return f"{year:04d}-{month:02d}-{day:02d}"


def image_uris(card_id, set_id, serie=None):
    """PokemonCatalog._images: TCGdex's extension-less base, plus a size suffix.

    The series segment is not optional decoration: en/base1/4/high.webp is a 404
    and en/base/base1/4/high.webp is the card. Ten sets from ten series were
    measured - the form with the series answered 200 ten times out of ten and
    the form without it 404 ten times out of ten - so a URL is only built when
    the series is known, and with no series this answers nothing at all. The app
    draws its card-back placeholder from an empty map rather than spending a
    request on an address known to be broken.

    serie is None on the one path that has no series in hand: a card fetched by
    its id alone, where the response carried no image of its own. The other
    candidate was looking the series up in the local sets table; it was rejected
    because it threads a database into a network adapter and because it would not
    have rescued the cards that reach this branch - bwp-BW04 and bwp-BW05 have no
    art on the CDN under either spelling (both 404, measured), while
    en/bw/bwp/BW01/low.webp, the same set, is 200.
    """
    if not serie:
        return {}
    tail = card_id.split("-")[-1]
    base = f"{ASSETS}/{serie}/{set_id}/{tail}"
    return {
        "small": f"{base}/low.webp",
        "normal": f"{base}/high.webp",
        "large": f"{base}/high.png",
    }


def card_image_uris(card, card_id, set_id, serie=None):
    """The image map the catalog builds: the payload's own URL when it has one.

    The response's own image URL is authoritative and already includes the
    series segment, which the set id alone does not. So the payload wins when it
    has an image, and _images is the last resort - which 183 of the committed
    sample's 323 cards need, because TCGdex omits the field for most older
    printings. A card with neither an image nor a series gets no art at all
    rather than a series-less URL, which is the rule image_uris states.
    """
    image = dart_to_string(card.get("image"))
    if image:
        return {
            "small": f"{image}/low.webp",
            "normal": f"{image}/high.webp",
            "large": f"{image}/high.png",
        }
    return image_uris(card_id, set_id, serie)


def type_line(category, stage):
    """PokemonCatalog._typeLine: 'Pokemon - Stage2', 'Trainer', 'Energy'.

    The switch is written out rather than paraphrased, because the Dart's own
    doc comment is wrong about one of its branches: it claims 'Energy - Special'
    where the code returns a bare 'Energy' for every Energy card, and it never
    reads trainerType at all. The code is what the client stores, so the code is
    what this mirrors.
    """
    lowered = category.lower()
    if lowered == "pokemon":
        return POKEMON_TYPE if not stage else f"{POKEMON_TYPE} - {stage}"
    if lowered == "trainer":
        return "Trainer"
    if lowered == "energy":
        return "Energy"
    return category


def rules_text(card):
    """PokemonCatalog._rulesText: the abilities, then the attacks, flattened.

    Dart's StringBuffer.writeln appends a newline after every line it writes, so
    each block ends with a blank line and the whole thing is trimmed once at the
    end. Three details are copied rather than tidied: an ability whose type is
    absent prints as "Ability", an attack's header is its cost, name and damage
    joined with *two* spaces and skipping whichever of the three are empty, and
    the cost is joined with the middle dot. This field is what search reads, so
    a character out here is a search that answers differently on the two paths.
    """
    buffer = ""
    abilities = card.get("abilities")
    if isinstance(abilities, list):
        for ability in abilities:
            if not isinstance(ability, dict):
                continue
            kind = dart_to_string(ability.get("type")) or "Ability"
            name = dart_to_string(ability.get("name")) or ""
            effect = dart_to_string(ability.get("effect")) or ""
            buffer += f"{kind}: {name}\n"
            if effect:
                buffer += effect + "\n"
            buffer += "\n"
    attacks = card.get("attacks")
    if isinstance(attacks, list):
        for attack in attacks:
            if not isinstance(attack, dict):
                continue
            cost = dart_list_join(attack.get("cost"), KEYWORD_JOIN)
            name = dart_to_string(attack.get("name")) or ""
            damage = dart_to_string(attack.get("damage")) or ""
            effect = dart_to_string(attack.get("effect")) or ""
            header = "  ".join(part for part in (cost, name, damage) if part)
            buffer += header + "\n"
            if effect:
                buffer += effect + "\n"
            buffer += "\n"
    out = buffer.strip()
    return out or None


def variant_types(card):
    """The finish codes the catalog reads out of the card's variants map.

    The variants map is TCGdex's own answer to "which physical printings does
    this card exist in" - normal, holo, reverse, firstEdition, wPromo - and the
    client reads exactly four of those keys, in this order, and ignores the
    rest. That matters here rather than being fussiness: TCGdex has already
    renamed one pricing variant once (its pricing block now says
    "reverse-holofoil" where the app's finish code is "reverse_holofoil"), and
    the rule this file follows is that a variant the app has never heard of is
    stored as nothing at all rather than mapped onto something wrong. A fifth
    key in variants reaches extras exactly as it reaches the client: not at all.
    """
    variants = card.get("variants")
    out = []
    if isinstance(variants, dict):
        if variants.get("normal") is True:
            out.append("nonfoil")
        if variants.get("holo") is True:
            out.append("holofoil")
        if variants.get("reverse") is True:
            out.append("reverse_holofoil")
        if variants.get("firstEdition") is True:
            out.append("first_edition")
    return out


def tcgplayer_id(card):
    """The tcgplayerId ??= value['productId']?.toString() in the catalog.

    The client reads the first productId it meets while walking
    pricing.tcgplayer's values in payload order, and the assignment sits outside
    the finish check - so a variant key the app's finish map does not recognise
    still contributes its product id. That id is the join key the app uses to
    pull real TCGplayer price history, so the walk is in payload order here too,
    and a null productId leaves the search open rather than ending it, which is
    what ??= does.
    """
    pricing = card.get("pricing")
    tcg = pricing.get("tcgplayer") if isinstance(pricing, dict) else None
    if not isinstance(tcg, dict):
        return None
    for value in tcg.values():
        if not isinstance(value, dict):
            continue
        product = dart_to_string(value.get("productId"))
        if product is not None:
            return product
    return None


def extras_of(card, tcgplayer):
    """The extras map the catalog builds, or None when it is empty.

    The key order is the Dart's and matters to nobody: catalog_store writes
    extras as jsonb, and jsonb sorts its own keys. What matters is which keys
    are present, because the app reads them - the TCGplayer product id, the
    finishes the card was printed in, the Pokedex number and the category - and
    that an empty map is stored as null rather than as an empty object, which is
    what the client's row carries (extras.isEmpty ? null : extras).
    """
    extras = {}
    if tcgplayer is not None:
        extras["tcgplayerId"] = tcgplayer
    variants = variant_types(card)
    if variants:
        extras["variants"] = variants
    dex = card.get("dexId")
    if isinstance(dex, list) and dex:
        extras["pokedex"] = dex[0]
    category = dart_to_string(card.get("category"))
    if category is None:
        category = ""
    if category:
        extras["category"] = category
    return extras or None


def stub_document(stub, set_doc=None, serie=None):
    """The row PokemonCatalog.fetchCardsInSet writes when a detail call fails.

    The client does not drop a card whose card call failed: it builds one from
    the set response's brief entry - id, collector number, name - with no
    rarity, no rules text, no artist, no release date and no extras, and art
    built from the series and set slugs. That is a worse row than the provider
    could have given, and it is the row the client stores, so it is the row the
    catalogue has to store too.

    One card in the committed sample lands here for real, and it is the reason
    this branch exists rather than being a theoretical safety net. TCGdex
    publishes a collector number of "%3F" as the card id "exu-%3F", which only
    addresses as a path segment when the percent sign is escaped again; the Dart
    client does not escape it, so its request reaches the router as "exu-?" and
    answers 404. The app cannot read that card back on any platform. Writing the
    fuller row the importer *could* read - it knows to escape, and the committed
    sample holds that card's full object - would mean the catalogue served art
    and rules text for a card the provider path cannot show, which is two ways
    to fill one table and the provenance problem the design warns about. So the
    importer asks for the card exactly the way the client asks for it, gets the
    same 404, and stores the same row. The card id is still stored, so a holding
    that names it resolves.
    """
    card_id = dart_to_string((stub or {}).get("id"))
    if not card_id:
        return None
    name = dart_to_string(stub.get("name"))
    if name is None:
        name = ""
    local_id = dart_to_string(stub.get("localId"))
    if local_id is None:
        local_id = ""
    set_code = set_doc["code"] if set_doc is not None else ""
    set_name = set_doc["name"] if set_doc is not None else set_code
    images = image_uris(card_id, set_code, serie)
    return {
        "id": card_id,
        "oracle_id": normalise_name(name),
        "set_code": set_code,
        "set_name": set_name,
        "name": name,
        "collector_number": local_id,
        "collector_sort": collector_sort_key(local_id),
        "rarity": "unknown",
        "layout": "",
        "type_line": None,
        "oracle_text": None,
        "mana_cost": None,
        "cmc": None,
        "colors": "",
        "color_identity": "",
        "artist": None,
        "flavor_text": None,
        # Empty when the card has neither an image of its own nor a series to
        # build one under: a null column is the row the client stores, and the
        # app draws its card back from it.
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
        # The fallback TcgCard passes no releasedAt, because the path that
        # builds it is the one that had no set object to take a date from.
        "released_at": None,
        "extras": None,
    }


def card_document(card, set_doc=None, stub=None, serie=None, requested_id=None):
    """PokemonCatalog._cardFromJson, as one catalog_cards row, or None.

    One function for both of the client's paths, exactly as the Dart has one
    function for both. set_doc is the set the card was downloaded as part of,
    and is None for a card reached by its own id alone; the difference is the
    client's own and is not smoothed over here. A set download fills released_at
    from the set, takes the set's name from the set response and the set code
    from the set id. A card reached by id has no set object at all, so it takes
    its set code from the id's own last dash and its set name from the payload's
    embedded set, and carries no release date. Both are rows the client writes,
    and tool/catalog/test_id_parity.py drives the committed sample through both
    paths for that reason.

    card is None for a card TCGdex answered no object for, which is the client's
    own fallback branch - see stub_document.

    Returns None only for an object with no id, as the Lorcana importer does:
    such a row cannot be opened, priced or deduplicated, and every endpoint that
    produces cards filters it out rather than putting an unreachable row on
    screen.
    """
    if not isinstance(card, dict):
        return stub_document(stub, set_doc, serie)

    card_id = dart_to_string(card.get("id"))
    if not card_id:
        return None

    stub_name = dart_to_string((stub or {}).get("name"))
    if stub_name is None:
        stub_name = ""
    name = dart_to_string(card.get("name"))
    if name is None:
        name = stub_name

    # resolvedSetId in the Dart: the set being downloaded, else the prefix of
    # the id that was asked for, else the prefix of the id the payload carries.
    if set_doc is not None:
        set_code = set_doc["code"]
    elif requested_id is not None:
        dash = requested_id.rfind("-")
        set_code = requested_id[:dash] if dash > 0 else ""
    elif "-" in card_id:
        set_code = card_id.split("-")[0]
    else:
        set_code = ""

    if set_doc is not None:
        set_name = set_doc["name"]
    else:
        set_name = ""
        embedded = card.get("set")
        if isinstance(embedded, dict):
            embedded_name = dart_to_string(embedded.get("name"))
            if embedded_name is not None:
                set_name = embedded_name

    # collectorNumber: the payload's own localId, else the brief entry's - or,
    # for a card reached by id alone, the tail of the id that was asked for.
    if stub is not None:
        fallback_local = dart_to_string(stub.get("localId"))
    elif requested_id is not None:
        dash = requested_id.rfind("-")
        fallback_local = requested_id[dash + 1:] if dash > 0 else requested_id
    else:
        fallback_local = None
    if fallback_local is None:
        fallback_local = ""
    collector_number = dart_to_string(card.get("localId"))
    if collector_number is None:
        collector_number = fallback_local

    rarity = dart_to_string(card.get("rarity"))
    if rarity is None:
        rarity = "unknown"

    category = dart_to_string(card.get("category"))
    if category is None:
        category = ""
    stage = dart_to_string(card.get("stage"))

    types = []
    raw_types = card.get("types")
    if isinstance(raw_types, list):
        for value in raw_types:
            if isinstance(value, str):
                types.append(value)

    images = card_image_uris(card, card_id, set_code, serie)
    released_at = set_doc.get("released_at") if set_doc is not None else None

    return {
        "id": card_id,
        "oracle_id": normalise_name(name),
        "set_code": set_code,
        "set_name": set_name,
        "name": name,
        "collector_number": collector_number,
        "collector_sort": collector_sort_key(collector_number),
        "rarity": rarity,
        # Empty rather than the provider's own word: PokemonCatalog never sets
        # TcgCard.layout, so the client stores the constructor default and a
        # server row carrying "normal" would not be the row the client writes.
        # This is the same trap the Lorcana import hit, and the parity test is
        # what caught it there.
        "layout": "",
        "type_line": type_line(category, stage),
        "oracle_text": rules_text(card),
        "mana_cost": None,
        "cmc": dart_double(card.get("hp")),
        "colors": ",".join(types),
        "color_identity": ",".join(types),
        "artist": dart_to_string(card.get("illustrator")),
        "flavor_text": dart_to_string(card.get("description")),
        # Empty when the card has neither an image of its own nor a series to
        # build one under: a null column is the row the client stores, and the
        # app draws its card back from it.
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
        "released_at": released_at,
        "extras": extras_of(card, tcgplayer_id(card)),
    }


def set_document(item=None, detail=None):
    """PokemonCatalog._setFromJson, as one catalog_sets row, or None.

    item is the entry TCGdex listed for the set in /sets, and detail is that
    set's own response. The client builds its set row from both: the list entry
    carries the card count TCGdex publishes there, the detail carries the name,
    release date, logo and series. A set whose detail response failed keeps the
    row the list entry alone describes, which is what fetchAllSets falls back
    to, and a set TCGdex listed without an id produces no row at all.

    Two columns are worth naming, and one of them is a deliberate divergence
    from the Dart.

    card_count is the provider's *official* count, and 0 means "the provider
    does not say"; card_row_count is what the import records after actually
    counting, and the app's isCatalogued rule reads the two together.

    code is the set id folded to lower case. PokemonCatalog puts the provider's
    own id in TcgSet.code, and for 205 of the 220 sets TCGdex publishes that id
    is already lower case - but fifteen are not: the Pokemon TCG Pocket sets are
    spelled A1, A1a, A2 ... B2a, and the promos P-A. Against those, folding is
    not parity with the set row the client writes, and it is not meant to be.
    Two reasons, written down here rather than discovered later.

    The first is that the client addresses a set by its folded code everywhere
    it reads one. CatalogRepository.cardsInSet, cachedCardsInSet, isCatalogued
    and askedForCards all lower-case the code before they touch SQLite;
    CatalogDao.cardByNumber states that set codes are folded to lower case
    because that is how they are stored; and app_database.dart's v4 migration
    folded the stored Lorcana set codes after keeping the provider's casing left
    nine promotional sets empty. A catalogue row carrying A1 would therefore be
    a set the client can never mark as catalogued - isCatalogued looks the code
    up in the sets table, and the folded code it asks with is not there - so
    every visit would re-download it. Storing the folded code is what makes those
    fifteen sets addressable at all.

    The second is that the client's own two paths already disagree, so there is
    no single client row to be identical to. A card downloaded as part of a set
    gets set_code = setId.toLowerCase(), while the same card reached by its own
    id gets set_code = the prefix of the id it was asked for, verbatim. Since
    catalog_cards carries a foreign key to (game, code), the card rows and the
    set row have to agree with each other; the set download is the path that
    fills a set, and this importer follows it.

    tool/catalog/test_id_parity.py states the same thing from its side: its
    pokemon case asserts that every set id in the committed sample is already
    lower case, so the folding is a no-op over the vectors, and prints that
    rather than letting it pass silently.
    """
    stub = item if isinstance(item, dict) else None
    body = detail if isinstance(detail, dict) else None

    set_id = dart_to_string(stub.get("id")) if stub else None
    if not set_id and body is not None:
        set_id = dart_to_string(body.get("id"))
    if not set_id:
        return None

    name = dart_to_string(stub.get("name")) if stub else None
    if name is None:
        name = set_id

    # The list entry's own count: cardCount.total, and 0 when it publishes no
    # counts at all. It is only ever a fallback for the detail's official count.
    published = 0
    if stub is not None:
        counts = stub.get("cardCount")
        if isinstance(counts, dict):
            total = dart_int(counts.get("total"))
            if total is not None:
                published = total

    row = {
        "code": set_id.lower(),
        "id": set_id,
        "name": name,
        "set_type": "expansion",
        "released_at": None,
        "card_count": published,
        "printed_size": None,
        # Pokemon sets have logos rather than the monochrome symbols Magic uses.
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

    if body is None:
        return row

    detail_name = dart_to_string(body.get("name"))
    if detail_name is not None:
        row["name"] = detail_name
    row["released_at"] = dart_date(body.get("releaseDate"))

    official = None
    counts = body.get("cardCount")
    if isinstance(counts, dict):
        official = dart_int(counts.get("official"))
    if official is not None:
        row["card_count"] = official
    row["printed_size"] = official

    logo = dart_to_string(body.get("logo"))
    row["logo_uri"] = None if logo is None else f"{logo}.webp"

    serie = body.get("serie")
    if isinstance(serie, dict):
        row["series"] = dart_to_string(serie.get("name"))

    row["collector_number_start"] = 1
    return row


# ---------------------------------------------------------------------------
# The catalogue write path, shared with the Lorcana importer
# ---------------------------------------------------------------------------


def import_catalogue_set(store, set_id, stubs, cards_by_id, set_doc, serie, args):
    """Writes one set into the shared catalogue, or reports that it could not be.

    None means the set was not written, and the caller counts that as a failure
    so catalog_meta.last_import_ok says so. A quietly skipped set is the failure
    mode this whole design is trying to make visible.

    Every card in the set response is written, including any the price sweep
    skipped because they were already sampled today: writing a set replaces it,
    so a card left out of this list is a card deleted from the catalogue. Rows
    are keyed by id and the last one wins, which is what the client's own
    rows[card.id] = row does with a repeated id.
    """
    documents = {}
    for stub in stubs:
        card_id = dart_to_string(stub.get("id"))
        if not card_id:
            continue
        row = card_document(cards_by_id.get(card_id), set_doc=set_doc, stub=stub,
                            serie=serie)
        if row is not None:
            documents[row["id"]] = row
    try:
        return store.import_set("pokemon", set_doc, list(documents.values()),
                                allow_empty=args.allow_empty_set)
    except catalog_store.CatalogError as exc:
        print(f"  set {set_id} not imported: {exc}", file=sys.stderr, flush=True)
        return None


def record_catalogue_outcome(store, upstream, sets_written, cards_written,
                             sets_unchanged, failed_sets, before_fingerprint,
                             named_sets=0, published=0):
    """Writes catalog_meta for the run, whether it went well or not.

    Design rule 5: a broken importer has to be a fact a client can read, so
    last_import_ok is written on the failure path too and not only on the happy
    one.

    upstream is the provider's whole set list, and it deliberately includes the
    sets whose cards failed to download - those sets are still published, and
    retiring them because one response went wrong would hide cards that are
    perfectly well catalogued. It is None when this run named a subset of sets
    with --sets, because then "not in the list" means "not asked for" rather
    than "withdrawn", and retiring the rest of the game would be a catastrophe
    dressed as tidiness.

    named_sets and published are what keep the note readable in that case.
    Without them a subset run would write "0 sets upstream", which describes the
    game as though the provider had withdrawn everything - the note is the one
    place a person reads what a run did, and it is worth the two numbers.
    """
    if upstream is not None:
        what = f"{len(upstream)} sets upstream"
    elif published:
        what = f"{published} sets published, {named_sets} named with --sets"
    else:
        what = f"{named_sets} sets named with --sets, and the list was not read"
    note = (f"{what}, {sets_written} written, "
            f"{sets_unchanged} unchanged, {cards_written} cards, "
            f"{failed_sets} set(s) failed")
    return store.finish("pokemon", source="tcgdex", ok=failed_sets == 0,
                        note=note, upstream_codes=upstream,
                        before_fingerprint=before_fingerprint)


def parse_args(argv=None):
    ap = argparse.ArgumentParser()
    default_db = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "prices", "pokemon_prices.db")
    ap.add_argument("--db", default=default_db, help="history database to write")
    ap.add_argument("--out", default=None,
                    help="alias for --db, for callers that name the output")
    ap.add_argument("--sets", default="", help="comma-separated set ids; default is all")
    ap.add_argument("--limit", type=int, default=0, help="stop after N cards (0 = no limit)")
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--skip-polled-today", action="store_true",
                    help="skip cards already sampled today (use for a daily run)")
    ap.add_argument("--catalog", action="store_true",
                    help="also write sets and cards into the shared catalogue")
    ap.add_argument("--catalog-only", action="store_true",
                    help="import the catalogue and sample no prices")
    # One lock per game, not one for the whole catalogue.
    #
    # The rule the design states is that two runs of one importer cannot
    # interleave, and every statement the store generates is scoped to a game -
    # read_sets(game), count_rows(game), retire_sets(game, ...), the card delete,
    # and the catalog_meta update. Two importers of *different* games write
    # disjoint rows and have nothing to keep apart.
    #
    # A single shared lock made them contend anyway, and the contention is not
    # theoretical. A Pokemon sweep is 717 seconds and its timer fires anywhere in
    # a twenty-minute window from 04:20, so it can still be holding the lock when
    # Lorcana's starts at 04:40. single_flight takes the lock LOCK_NB, so the
    # loser is refused rather than made to wait - and the refusal happens before
    # the sweep runs, so Lorcana would lose the day's prices as well as its
    # catalogue, and a price series built one sample a day cannot be backfilled.
    ap.add_argument("--lock", default="/tmp/arcanum-catalog-pokemon.lock",
                    help="flock file, so two imports of this game cannot interleave")
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
        # --catalog-only reads no price at all, so "already sampled today" has
        # nothing to skip: every card still has to be fetched for its row.
        args.skip_polled_today = False

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


def listed_set(by_id, set_id):
    """The set list entry for a set id, however the caller spelled it.

    TCGdex routes /sets/{id} case-insensitively and answers with its own
    spelling, so a run that names "a1" is served the set TCGdex calls "A1". The
    listing is keyed by TCGdex's spelling, so both are tried before the entry is
    given up on: it is the only source of the card count the list publishes, and
    losing it silently would make one set's row differ between a run that named
    it and a run that did not.
    """
    return by_id.get(set_id) or by_id.get(set_id.lower())


def run(args, store):
    db = args.out or args.db
    con = connect(db)
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    # ---- work out which sets to read
    listing = []
    if args.sets:
        set_ids = [s.strip() for s in args.sets.split(",") if s.strip()]
        if store is not None:
            # The set list is read for the catalogue even when a subset was
            # named, because a set's published card count is part of its row.
            listing = set_list()
    else:
        listing = set_list()
        set_ids = [item["id"] for item in listing]
    by_id = {item["id"]: item for item in listing}

    print(f"{len(set_ids)} sets to scan", flush=True)
    if not set_ids:
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
    # so a database that is down has to cost the catalogue a night rather than
    # cost the day its prices.
    before_fingerprint = None
    if store is not None:
        try:
            before_fingerprint = store.set_list_fingerprint("pokemon")
        except catalog_store.CatalogError as exc:
            print(f"catalogue unreachable, sampling prices without importing: {exc}",
                  file=sys.stderr, flush=True)
            store = None

    t0 = time.time()
    seen = 0
    written = 0
    unpriced = 0
    failed_cards = 0
    failed_sets = 0
    catalogued_sets = 0
    catalogued_cards = 0
    unchanged_sets = 0

    for i, set_id in enumerate(set_ids, 1):
        if args.limit and seen >= args.limit:
            break
        try:
            detail = set_detail(set_id)
        except Exception as exc:  # noqa: BLE001 - reported, then the sweep goes on
            failed_sets += 1
            print(f"  set {set_id} failed: {exc}", file=sys.stderr, flush=True)
            continue
        stubs = stubs_of(detail)
        serie = serie_id(detail)

        # Which cards this set needs. Without a catalogue the sweep may skip the
        # ones it already sampled today. With one it may not, because a set is
        # replaced wholesale and a card left out is a card deleted.
        wanted = []
        for stub in stubs:
            card_id = stub["id"]
            if args.limit and seen + len(wanted) >= args.limit:
                break
            if store is None and card_id in already:
                continue
            wanted.append(card_id)

        results = fetch_cards(wanted, args.workers) if wanted else []
        cards_by_id = {card_id: card for card_id, card, _ in results}

        # ---- prices
        rows = []
        state = []
        for card_id, card, error in results:
            seen += 1
            if error is not None or not isinstance(card, dict):
                failed_cards += 1
            if card_id in already:
                continue
            prices = finish_prices(card) if isinstance(card, dict) else {}
            if not prices:
                unpriced += 1
            for finish, price in prices.items():
                rows.append((card_id, finish, today, price))
            state.append((card_id, today))

        if not args.catalog_only:
            written += write_points(con, rows, state)

        # ---- the catalogue
        if store is not None:
            errored = [card_id for card_id, _, error in results if error is not None]
            set_doc = None
            outcome = None
            if errored:
                # A card that could not be read at all is not evidence about the
                # card, and rewriting the set without it would delete it. The
                # set is left exactly as yesterday left it and counted as a
                # failure, so last_import_ok says so.
                failed_sets += 1
                print(f"  set {set_id} not imported: {len(errored)} card(s) could "
                      f"not be read, e.g. {errored[0]}", file=sys.stderr, flush=True)
            else:
                set_doc = set_document(listed_set(by_id, set_id), detail)
                if set_doc is None:
                    failed_sets += 1
                    print(f"  set {set_id} not imported: TCGdex published no set id",
                          file=sys.stderr, flush=True)
                else:
                    outcome = import_catalogue_set(store, set_id, stubs, cards_by_id,
                                                   set_doc, serie, args)
                    if outcome is None:
                        failed_sets += 1
                    else:
                        catalogued_sets += 1
                        catalogued_cards += outcome["cards"]
                        if outcome["outcome"] == "unchanged":
                            unchanged_sets += 1

        if not args.catalog_only:
            print(f"  set {i}/{len(set_ids)} {set_id}: {len(stubs)} cards, "
                  f"{len(rows)} points", flush=True)
        elif i % 5 == 0 or i == len(set_ids):
            print(f"  set {i}/{len(set_ids)} {set_id}: {catalogued_cards:,} cards "
                  f"catalogued, {failed_sets} set(s) failed", flush=True)

    total = con.execute("SELECT COUNT(*) FROM history").fetchone()[0]
    cards_held = con.execute("SELECT COUNT(DISTINCT card_id) FROM history").fetchone()[0]
    days = con.execute("SELECT COUNT(DISTINCT date) FROM history").fetchone()[0]
    con.close()

    print("", flush=True)
    print(f"done in {int(time.time() - t0)}s — {written} points written, "
          f"{failed_cards} card(s) failed", flush=True)
    print(f"{len(set_ids)} sets read, {seen:,} cards seen, "
          f"{unpriced:,} with no price at all", flush=True)
    print(f"database now holds {total:,} points across {cards_held:,} cards "
          f"and {days} day(s)", flush=True)
    print(f"  {db}", flush=True)

    if store is not None:
        # A run that named a subset must not retire the sets it did not ask for,
        # so the upstream list is withheld in that case.
        #
        # And it is the folded spelling, not the provider's, because retire_sets
        # compares against the code the catalogue stores. Lorcana's importer hit
        # this with its ten upper-case promo codes and retired ten sets while
        # looking complete; Pokemon has fifteen ids that are not lower case, so
        # passing the provider's spelling here would retire exactly those.
        upstream = None if args.sets else [s.lower() for s in set_ids]
        summary = record_catalogue_outcome(store, upstream, catalogued_sets,
                                           catalogued_cards, unchanged_sets,
                                           failed_sets, before_fingerprint,
                                           named_sets=len(set_ids),
                                           published=len(listing))
        print("", flush=True)
        if summary.get("dry_run"):
            print("dry run: no catalogue row was written", flush=True)
        else:
            print(f"catalogue holds {summary['sets']:,} sets and "
                  f"{summary['cards']:,} cards, sets_revision {summary['revision']}",
                  flush=True)

    return 1 if failed_sets and failed_sets == len(set_ids) else 0


if __name__ == "__main__":
    raise SystemExit(main())
