#!/usr/bin/env python3
"""Import the Gundam Card Game into the shared catalogue.

Design: docs/catalogue-server-side.md, section 3. One importer for one game, and
the fifth to run through tool/catalog_store.py - the module that owns the seven
rules (one transaction per set, checksum first, sets before cards, never delete a
set, record the outcome, idempotent and single-flight, no partial revision
bumps). Nothing in this file re-implements any of them.

**Why this game, and why from here.** Five games in Arcanum were catalogued only
by tcgcsv, which republishes TCGplayer's own product catalogue, and they are the
web build's worst case: their Sets tab is empty until a set is opened and they
have no search at all. Gundam is the first of the five to be moved to a source of
its own. gcgapi publishes the publisher's own English card database from a host
that sends Access-Control-Allow-Origin, so a browser can ask it directly -
measured, and it is the property tcgcsv lacks and the reason Arcanum's relay
exists at all. The tcgcsv client and its Gundam factory are deliberately left in
place: they are the fallback that makes this move reversible.

**The id is forwarded verbatim, and it has to be.** A catalog_cards row's id here
is the provider's own product_id. Gundam prints 1,148 distinct card numbers and
publishes 1,912 products, because an alternate art is a product of its own with
the same number printed on it - GD01-005 and its four parallels - so the printed
number cannot be the id: it would collapse five holdings into one. product_id is
unique over the whole catalogue (1,912 of 1,912, measured) and every one of them
begins with its own card number, which is what the collector number below and the
app's number search rely on.

**What is derived, and therefore what the parity test is for.** ids aside, this
file derives the folded set code, the collector number, the collector sort key,
the type line, the oracle id and the JSON in extras. Each one is a transcription
of lib/data/catalog/gundam_catalog.dart and names the Dart it mirrors, because
the same rule in two languages is the drift docs/catalogue-server-side.md section
7 warns about - and tool/catalog/test_id_parity.py asserts the two agree over a
committed sample of real responses, over every column of a card row and of a set
row.

**What this importer does not write: prices.** A gcgapi card object quotes no
price of any kind - there is no market price, no low, no foil and no TCGplayer
product id to join a price series to - so replace_prices has nothing to be handed
and is not called. That is a real cost of this move and it is stated in the
report rather than worked around: Gundam's prices still come from the tcgcsv
client, which is kept for exactly this reason as well as for the fallback.

Usage, from the repository root:

    set -a; . /home/zixen/arcanum/supabase.env; set +a
    python3 tool/import_gundam_catalogue.py
    python3 tool/import_gundam_catalogue.py --sets GD01,EB01
    python3 tool/import_gundam_catalogue.py --dry-run

Exit status is 0 unless every set named failed and there was more than one.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

import catalog_store

# Three rules transcribed from the Dart that every client shares, imported rather
# than written a second time: PollLorcanaPrices' file holds them because Lorcana
# needed them first and none of them is Lorcana-specific. collector_sort_key is
# TcgCard.collectorNumberSortKey, normalise_name is TcgCard.normaliseName, and
# dart_string and dart_int are the null-and-blank handling every mapping in this
# program is written in terms of.
from poll_lorcana_prices import (  # noqa: E402  (same directory as this file)
    collector_sort_key,
    dart_int,
    dart_string,
    normalise_name,
)

GAME = "gundam"
SOURCE = "gcgapi"
API = "https://api.gcgapi.com/v1"
UA = "Arcanum/1.0 (+https://github.com/arm00pv/arcanum)"

# The page size the provider will honour. 'limit' is capped at 250 server-side
# and a larger value answers 250 rows rather than refusing, so a set is read page
# by page - GD01, the largest, is 254 products. GundamCatalog._pageSize is the
# same number for the same reason.
PAGE_SIZE = 250

# The fields the type line and extras read, in the order the Dart reads them.
# Kept as data rather than inline so the two languages cannot drift about which
# fields a card carries.
STRING_EXTRAS = ("zone", "trait", "link", "source_title", "block_icon")
NUMBER_EXTRAS = ("level", "ap", "hp")

# extras keys whose Dart spelling is not the provider's field name
# (GundamCatalog._extraKey).
EXTRA_KEY_NAMES = {"source_title": "sourceTitle", "block_icon": "blockIcon"}

_WHITESPACE = re.compile(r"\s+")
_WHITESPACE_SPLIT = re.compile(r"\s+")
_NOT_CODE_CHAR = re.compile(r"[^a-z0-9]+")
_TAIL_DIGITS = re.compile(r"(\d+)$")


# ---------------------------------------------------------------------------
# Reading the provider
# ---------------------------------------------------------------------------


def get_json(url, timeout=45, retries=3):
    """GETs a URL and decodes JSON, retrying the failures worth retrying.

    A 4xx is not retried: the provider answering "no such set" is an answer, and
    repeating the question three times only makes the run slower. Anything else -
    a socket error, a 429, a 5xx - is retried with backoff, because the failure
    that matters here is a set that is half-read.
    """
    last = None
    for attempt in range(retries + 1):
        try:
            request = urllib.request.Request(
                url, headers={"Accept": "application/json", "User-Agent": UA})
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return json.loads(
                    response.read().decode("utf-8", "replace") or "null")
        except urllib.error.HTTPError as exc:  # noqa: PERF203 - reported below
            last = exc
            if 400 <= exc.code < 500 and exc.code != 429:
                raise
        except Exception as exc:  # noqa: BLE001 - retried, then raised
            last = exc
        time.sleep(0.5 * (attempt + 1))
    raise RuntimeError("could not read %s: %s" % (url, last))


def rows_of(body):
    """The 'data' array every gcgapi route answers with (GundamCatalog._rows)."""
    if isinstance(body, dict):
        rows = body.get("data")
        if isinstance(rows, list):
            return rows
    if isinstance(body, list):
        return body
    return []


def set_list(timeout=45, retries=3):
    """Every set the provider publishes: code, name and a real card count.

    One request, 28 sets. 'card_count' is the number of products the set's own
    filter returns, so it is the number the client will store for that set and
    the number the app's isCatalogued rule compares against - which is why it is
    written into the set row rather than left at zero.
    """
    return rows_of(get_json(API + "/sets", timeout=timeout, retries=retries))


def set_cards(set_code, timeout=45, retries=3, page_size=PAGE_SIZE):
    """Every product the provider files under one set, whole.

    Paged, because the page size is the provider's: 'limit' above 250 answers 250
    rows and reports its own limit in '_meta' rather than refusing. The loop
    stops on a short page, which is the provider's own statement that there is
    nothing after it, and on the total the first page reports.

    Every product of the set is returned, alternate arts included: writing a set
    replaces it, so a product left out of this list is a row deleted from the
    catalogue and a holding that stops resolving.
    """
    out = []
    offset = 0
    total = 0
    while True:
        body = get_json(
            "%s/cards?set_code=%s&limit=%d&offset=%d"
            % (API, set_code, page_size, offset),
            timeout=timeout, retries=retries)
        rows = rows_of(body)
        if isinstance(body, dict) and isinstance(body.get("_meta"), dict):
            total = dart_int(body["_meta"].get("total")) or total
        for row in rows:
            if isinstance(row, dict):
                out.append(row)
        offset += page_size
        if len(rows) < page_size:
            break
        if total and offset >= total:
            break
    return out


# ---------------------------------------------------------------------------
# The catalogue import: every rule that turns a gcgapi object into a stored row
# ---------------------------------------------------------------------------
#
# This half of the file is a transcription of lib/data/catalog/gundam_catalog.dart,
# and it is written that way on purpose. That client decides what a Gundam card
# is; this decides what gets stored; both write into the same SQLite tables on
# the client, and a collection row names a card id. If the two disagree about an
# id, a name, a rarity, a sort key, a type line or an extras key, the
# disagreement is invisible until somebody's holding renders as "--". So each
# function below names the Dart it mirrors, and tool/catalog/test_id_parity.py
# asserts the two agree over a committed sample of real responses.


def slug(value):
    """GundamCatalog._slug: lower case, letters and digits only.

    This is the form a set code is stored in everywhere in the app - the sets
    table, CatalogRepository.cardsInSet, CatalogDao.isCatalogued all compare a
    folded code - so a row that kept the provider's spelling would be a set the
    client could never mark as catalogued. For Gundam the fold is a no-op beyond
    the case: every set code the provider publishes is already letters and
    digits, so GD01 folds to gd01 and nothing is lost. That is also why the
    provider's case-insensitive set filter can be asked with the folded code and
    no lookup table is needed.
    """
    text = dart_string(value)
    if text is None:
        return ""
    return _NOT_CODE_CHAR.sub("", text.lower())


def set_type_for(code, name):
    """GundamCatalog._setTypeFor: promo, starter or expansion.

    There is no taxonomy flag in the set list, so the type is read off the code
    and the name, exactly as the other catalogues read theirs. The promotional
    runs are numbered RP, EXBP and EXRP and named "Promotion card" and "Other
    Product Card"; the starter decks are ST01 to ST14 and the deck-build box is
    SC01; everything else is a retail expansion.
    """
    upper = (code or "").upper()
    lower = (name or "").lower()
    if (upper.startswith("RP") or upper.startswith("EXBP")
            or upper.startswith("EXRP") or "promotion" in lower
            or "promo" in lower or "other product" in lower):
        return "promo"
    if (upper.startswith("ST") or upper.startswith("SC")
            or upper.startswith("SD") or lower.startswith("starter")
            or lower.startswith("structure") or lower.startswith("deck")
            or lower.startswith("intro")):
        return "starter"
    return "expansion"


def collector_number_of(printed):
    """GundamCatalog._collectorNumberOf: the digits the number ends with.

    gcgapi writes the number as the card prints it - GD01-001 - and the app
    stores the position inside the set, which is what its number search parses
    out of a query like "GD01-001" and what a binder sorts by. The tcgcsv adapter
    read the same number for this game the same way, so a card's collector number
    does not change shape when the source does. The full printed number is kept
    in extras.
    """
    text = dart_string(printed) or ""
    first = _WHITESPACE_SPLIT.split(text.strip())[0] if text.strip() else ""
    before_slash = first.split("/")[0]
    match = _TAIL_DIGITS.search(before_slash)
    return match.group(1) if match else before_slash


def text_field(raw):
    """GundamCatalog._text: a text field, with the provider's own "nothing here"
    taken out of it.

    gcgapi writes a bare hyphen where a card has no such thing - 213 cards carry
    "-" as their whole rules text, 1,115 link to no pilot, 807 deploy to no zone,
    409 carry no trait and 6 have no block icon, all measured. A hyphen stored as
    rules text, a zone or a trait is a value the app would show, search and list,
    and the card says nothing of the sort; so a bare hyphen is an absence here as
    it is in the client.
    """
    text = dart_string(raw)
    if text == "-":
        return None
    return text


def trait_text(card):
    """GundamCatalog._typeLine's trait: the printed string, else the list.

    The provider states a card's trait twice - as the bracketed string the card
    prints ("(G Generation)") and as a list of bare names ("G Generation") - and
    the printed form is preferred because the type line is shown.
    """
    printed = text_field(card.get("trait"))
    if printed is not None:
        return printed
    raw = card.get("traits")
    if not isinstance(raw, list):
        return ""
    parts = [text for text in (text_field(v) for v in raw) if text]
    return " / ".join(parts)


def type_line(card):
    """GundamCatalog._typeLine, as the stored column.

    Gundam prints the card type, its trait in brackets, the level it can be
    deployed at and the zone it deploys to, and the type line is what the app
    searches and shows, so what the provider states about a card is joined into
    it rather than left in fields nothing reads.
    """
    kind = dart_string(card.get("card_type")) or ""
    trait = trait_text(card)
    level = dart_int(card.get("level"))
    zone = text_field(card.get("zone")) or ""
    parts = []
    if kind:
        parts.append(kind)
    if trait:
        parts.append(trait)
    if level is not None:
        parts.append("Level %d" % level)
    if zone:
        parts.append(zone)
    line = " - ".join(parts)
    return line or None


def extras_of(card):
    """The extras map GundamCatalog builds, or None when there is nothing in it.

    Note what is not here, because it is the one place a plausible-looking key
    would do real damage: there is no 'tcgplayerId'. The app reads that key as
    the join key for price history and gcgapi publishes no TCGplayer product id,
    so a Bandai product id under it would be a number the app looked prices up
    with and never found. The provider's own id is stored under 'productId'
    instead, and nothing reads it as a price key.
    """
    extras = {}
    product = dart_string(card.get("product_id"))
    if product is not None:
        extras["productId"] = product
    number = dart_string(card.get("card_number"))
    if number is not None:
        extras["printedNumber"] = number
    kind = dart_string(card.get("card_type"))
    if kind is not None:
        extras["cardType"] = kind
    colour = dart_string(card.get("color"))
    if colour is not None:
        extras["color"] = colour
    for field in STRING_EXTRAS:
        value = text_field(card.get(field))
        if value is not None:
            extras[EXTRA_KEY_NAMES.get(field, field)] = value
    for field in NUMBER_EXTRAS:
        value = dart_int(card.get(field))
        if value is not None:
            extras[field] = value
    url = dart_string(card.get("detail_url"))
    if url is not None:
        extras["detailUrl"] = url
    return extras or None


def card_document(card, set_doc=None, set_code=None):
    """GundamCatalog._cardFromJson, as one catalog_cards row, or None.

    set_code is the folded code of the set being downloaded, which is the set a
    row of a set download belongs to; it is None for a card reached by its own id
    alone, which takes the code from the payload's own 'set_code' instead. Those
    two are the same string for every card the provider publishes - the payload's
    'set_code' is the set it was filed under, which is the set it was asked for,
    1,912 of 1,912 measured - so unlike the Pokemon catalogue this game's two
    paths derive one row, and there is no divergence here to carve out of the
    comparison.

    Returns None only for an object with no product_id, as the other importers
    do: such a row cannot be opened, priced, deduplicated or fetched again.
    """
    if not isinstance(card, dict):
        return None
    card_id = dart_string(card.get("product_id"))
    if not card_id:
        return None

    number = dart_string(card.get("card_number")) or ""
    payload_code = slug(card.get("set_code"))
    code = set_code if set_code is not None else payload_code
    name = dart_string(card.get("name")) or ""
    kind = dart_string(card.get("card_type")) or ""
    colour = dart_string(card.get("color")) or ""
    set_name = dart_string(card.get("set_name")) or code.upper()
    collector_number = collector_number_of(number)
    # CardArt.host is applied by the client while parsing and rewrites a relayed
    # host's URL on a web build only, so what is stored here is the provider's
    # own address - the only thing this file can honestly write. The step 2
    # adapter applies the same rule when it turns a PostgREST row into a map, or
    # Gundam art is CORS-blocked in the browser and fine on a phone.
    image = dart_string(card.get("image_url"))

    return {
        "id": card_id,
        "oracle_id": "%s|%s" % (normalise_name(name), slug(kind)),
        "set_code": code,
        "set_name": set_name,
        "name": name,
        "collector_number": collector_number,
        "collector_sort": collector_sort_key(collector_number),
        "rarity": dart_string(card.get("rarity")) or "unknown",
        # Empty rather than the provider's own word: GundamCatalog never sets
        # TcgCard.layout, so the client stores the constructor default and a
        # server row carrying "normal" would not be the row the client writes.
        "layout": "",
        "type_line": type_line(card),
        "oracle_text": text_field(card.get("effect")),
        "mana_cost": None,
        # The play cost, which is what the app sorts and filters by. A card with
        # no cost of its own leaves this null rather than costing zero.
        "cmc": dart_number(card.get("cost")),
        "colors": colour,
        "color_identity": colour,
        "artist": None,
        "flavor_text": None,
        "image_small": None,
        "image_normal": image,
        "image_large": None,
        "image_art_crop": None,
        "image_png": None,
        "back_image_small": None,
        "back_image_normal": None,
        "digital": False,
        "promo": set_type_for(code, set_name) == "promo",
        "reprint": False,
        "reserved": False,
        "full_art": False,
        "booster": False,
        "foil": False,
        "nonfoil": False,
        "edhrec_rank": None,
        # A gcgapi card object carries no release date and no set response does
        # either, so this column is null for every row rather than guessed at.
        "released_at": None,
        "extras": extras_of(card),
    }


def dart_number(raw):
    """The (x as num?)?.toDouble() in the catalog: a number, or None.

    Not a text parse: the Dart cast answers null for a string rather than
    parsing it, so a cost the provider ever spells as text is an absence here as
    well rather than a number.
    """
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        return None
    return float(raw)


def set_document(item):
    """GundamCatalog._setFromJson, as one catalog_sets row, or None.

    The set list carries everything a set row needs and nothing else: the code,
    the name and a real card count. Two columns are worth naming.

    code is the provider's set_code folded to lower case, and id is the
    provider's own spelling. The folding is not cosmetic - every read path in the
    app folds a code before it touches SQLite, so a row carrying GD01 is a set
    the client can never mark as catalogued and would re-download on every visit.
    For Gundam the fold costs nothing beyond the case, which is asserted in the
    proof rather than assumed.

    card_count is the provider's own count, which equals the number of products
    the set's filter returns, so a set is complete exactly when its rows match
    it. There is no printed_size: the provider does not distinguish a printed
    size from the size it publishes, and inventing one would be a number nothing
    could check.
    """
    if not isinstance(item, dict):
        return None
    provider_code = dart_string(item.get("set_code"))
    if not provider_code:
        return None
    code = slug(provider_code)
    if not code:
        return None
    name = dart_string(item.get("set_name")) or provider_code
    return {
        "code": code,
        "id": provider_code,
        "name": name,
        "set_type": set_type_for(code, name),
        # The provider publishes no release date for any set, and the sets table
        # sorts on this column: a guessed date would order the shelf wrongly
        # rather than harmlessly.
        "released_at": None,
        "card_count": dart_int(item.get("card_count")) or 0,
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


# ---------------------------------------------------------------------------
# The catalogue write path
# ---------------------------------------------------------------------------


def card_documents(cards, set_doc, set_code):
    """Every catalog_cards row one set's products produce, keyed by their id.

    Keyed by the row's own id, which here is the provider's product id - the id
    the set's response listed and the id the client stores - so a card's price or
    holding can be found by the id both sides already have. A repeated id keeps
    the last row, which is what the client's own rows[card.id] = row does; the
    provider publishes no repeated product id at all (1,912 of 1,912 measured),
    so this is the client's rule followed rather than a case that happens.
    """
    documents = {}
    for card in cards:
        row = card_document(card, set_doc=set_doc, set_code=set_code)
        if row is not None:
            documents[row["id"]] = row
    return documents


def import_catalogue_set(store, code, documents, set_doc, args):
    """Writes one set into the shared catalogue, or reports that it could not be.

    None means the set was not written, and the caller counts that as a failure
    so catalog_meta.last_import_ok says so. A quietly skipped set is the failure
    mode this whole design is trying to make visible.
    """
    rows = {}
    for row in documents.values():
        rows[row["id"]] = row
    try:
        return store.import_set(GAME, set_doc, list(rows.values()),
                                allow_empty=args.allow_empty_set)
    except catalog_store.CatalogError as exc:
        print("  set %s not imported: %s" % (code, exc), file=sys.stderr,
              flush=True)
        return None


def record_catalogue_outcome(store, upstream, sets_written, cards_written,
                             sets_unchanged, failed_sets, before_fingerprint,
                             named_sets=0, published=0):
    """Writes catalog_meta for the run, whether it went well or not.

    Design rule 5: a broken importer has to be a fact a client can read, so
    last_import_ok is written on the failure path too. There is no price half to
    this note, because this importer writes no prices: gcgapi quotes none, and
    replace_prices is never called from here.

    upstream is the provider's whole set list, folded, and it deliberately
    includes the sets whose cards failed to download - they are still published,
    and retiring them because one response went wrong would hide cards that are
    perfectly well catalogued. It is None when this run named a subset with
    --sets, because then "not in the list" means "not asked for" rather than
    "withdrawn".
    """
    if upstream is not None:
        what = "%d sets upstream" % len(upstream)
    elif published:
        what = "%d sets published, %d named with --sets" % (published, named_sets)
    else:
        what = "%d sets named with --sets, and the list was not read" % named_sets
    note = ("%s, %d written, %d unchanged, %d cards, %d set(s) failed; "
            "no prices: gcgapi quotes none"
            % (what, sets_written, sets_unchanged, cards_written, failed_sets))
    return store.finish(GAME, source=SOURCE, ok=failed_sets == 0, note=note,
                        upstream_codes=upstream,
                        before_fingerprint=before_fingerprint)


def parse_args(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--sets", default="",
                    help="comma-separated set codes; default is every set")
    # One lock per game, not one for the whole catalogue: every statement the
    # store generates is scoped to a game, so two importers of different games
    # write disjoint rows and have nothing to keep apart. single_flight refuses
    # rather than waits, so a shared lock would cost a whole game's night.
    ap.add_argument("--lock", default="/tmp/arcanum-catalog-gundam.lock",
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
    url = (os.environ.get("SUPABASE_DB_URL")
           or os.environ.get("SUPABASE_DB_URL_POOLED"))
    if not url:
        print("this importer needs SUPABASE_DB_URL (or SUPABASE_DB_URL_POOLED) in "
              "the environment; see /home/zixen/arcanum/supabase.env",
              file=sys.stderr)
        return None
    return catalog_store.CatalogStore(url, dry_run=args.dry_run,
                                      psql=catalog_store.find_psql())


def main():
    args = parse_args()
    store = open_store(args)
    if store is None:
        return 2
    # Design rule 6: the lock is held for the whole run, so a hand-run import and
    # the nightly timer cannot interleave.
    try:
        with catalog_store.single_flight(args.lock):
            return run(args, store)
    except catalog_store.CatalogError as exc:
        print("catalogue import refused: %s" % exc, file=sys.stderr)
        return 1


def run(args, store):
    t0 = time.time()

    listing = set_list()
    by_code = {}
    for item in listing:
        if not isinstance(item, dict):
            continue
        code = slug(item.get("set_code"))
        if code:
            by_code[code] = item
    if not by_code:
        print("the provider listed no sets; refusing to touch the catalogue",
              file=sys.stderr)
        return 1

    if args.sets:
        codes = [slug(part) for part in args.sets.split(",") if part.strip()]
        unknown = [code for code in codes if code not in by_code]
        for code in unknown:
            print("  %s is not a set the provider publishes" % code,
                  file=sys.stderr, flush=True)
    else:
        codes = list(by_code)

    print("%d set(s) to import" % len(codes), flush=True)
    if not codes:
        print("nothing to do", flush=True)
        return 0

    # Taken before a single row is written. sets_revision is the signal that
    # tells every browser its set list is stale, and it is only meaningful if the
    # comparison is against the list as it stood before this run.
    before_fingerprint = store.set_list_fingerprint(GAME)

    written = 0
    cards_written = 0
    unchanged = 0
    failed = 0

    for i, code in enumerate(codes, 1):
        item = by_code.get(code)
        if item is None:
            failed += 1
            continue
        try:
            cards = set_cards(code)
        except Exception as exc:  # noqa: BLE001 - reported, and the run goes on
            failed += 1
            print("  set %s failed: %s" % (code, exc), file=sys.stderr, flush=True)
            continue

        set_doc = set_document(item)
        if set_doc is None:
            failed += 1
            print("  set %s not imported: the provider published no set code"
                  % code, file=sys.stderr, flush=True)
            continue

        documents = card_documents(cards, set_doc, code)
        if not documents:
            # A set the provider answers with no products is far more likely to
            # be a bad response than a withdrawn set, and writing it would delete
            # every card the catalogue holds for it. Refused and counted, which
            # is what --allow-empty-set is for when it is genuinely the answer.
            failed += 1
            print("  set %s not imported: the provider listed no products for it"
                  % code, file=sys.stderr, flush=True)
            continue

        outcome = import_catalogue_set(store, code, documents, set_doc, args)
        if outcome is None:
            failed += 1
        else:
            written += 1
            cards_written += outcome["cards"]
            if outcome["outcome"] == "unchanged":
                unchanged += 1
        print("  set %d/%d %s: %d products, %d cards catalogued, %d set(s) failed"
              % (i, len(codes), code, len(cards), cards_written, failed),
              flush=True)

    # A run that named a subset must not retire the sets it did not ask for, so
    # the upstream list is withheld in that case. The codes are the folded ones,
    # because retire_sets compares against the code the catalogue stores.
    upstream = None if args.sets else [slug(item.get("set_code"))
                                       for item in listing
                                       if isinstance(item, dict)]
    summary = record_catalogue_outcome(
        store, upstream, written, cards_written, unchanged, failed,
        before_fingerprint, named_sets=len(codes), published=len(by_code))

    print("", flush=True)
    print("done in %ds - %d set(s) written, %d unchanged, %d card(s), "
          "%d set(s) failed" % (int(time.time() - t0), written, unchanged,
                                cards_written, failed), flush=True)
    if summary.get("dry_run"):
        print("dry run: no catalogue row was written", flush=True)
    else:
        print("catalogue holds %d sets and %d cards, sets_revision %d"
              % (summary["sets"], summary["cards"], summary["revision"]),
              flush=True)
    return 1 if failed and failed == len(codes) else 0


if __name__ == "__main__":
    raise SystemExit(main())
