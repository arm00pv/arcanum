#!/usr/bin/env python3
"""Import Star Wars: Unlimited into the shared catalogue.

Design: docs/catalogue-server-side.md, section 3. One importer for one game, and
the sixth to run through tool/catalog_store.py - the module that owns the seven
rules (one transaction per set, checksum first, sets before cards, never delete a
set, record the outcome, idempotent and single-flight, no partial revision bumps).
Nothing in this file re-implements any of them.

**Why this game, and why from here.** Star Wars: Unlimited was one of the games
catalogued only by tcgcsv, which republishes TCGplayer's product catalogue, and
they are the web build's worst case: no Sets tab until a set is opened and no
search at all. The app now reads the publisher's own English card database
directly - lib/data/catalog/swu_catalog.dart, and
docs/catalogue-import-swu.md is the report of that half - from a host that
answers a browser with Access-Control-Allow-Origin, which is the property tcgcsv
lacks and the reason Arcanum's relay exists. This file is the other half: the
same responses, written into Postgres so a browser stops downloading them for
itself.

**What is derived, and therefore what the parity test is for.** The id is
forwarded verbatim - the publisher's cardUid, unique over the whole game, 9,729
of 9,729 measured - and everything else about a row is derived here: the folded
set code, the collector number (which for a treatment comes from the base card it
points at, not from the treatment's own), the collector sort key, the type line,
the oracle id, the oracle text and the JSON in extras. Each one is a
transcription of lib/data/catalog/swu_catalog.dart and names the Dart it mirrors,
because the same rule in two languages is the drift
docs/catalogue-server-side.md section 7 warns about - and
tool/catalog/test_id_parity.py asserts the two agree over a committed sample of
real responses, over every column of a card row and of a set row.

**What this importer does not write: prices.** No gcgapi-style price is published
here either: no key matching /price/i appears in a 250-record page, and there is
no TCGplayer product id to join a price series to. replace_prices is never
called, extras carries no 'tcgplayerId', and the cost is stated in the report
rather than worked around.

Usage, from the repository root:

    set -a; . /home/zixen/arcanum/supabase.env; set +a
    python3 tool/import_swu_catalogue.py
    python3 tool/import_swu_catalogue.py --sets SOR,SHD
    python3 tool/import_swu_catalogue.py --dry-run

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
import urllib.parse
import urllib.request

import catalog_store

# Four rules transcribed from the Dart that every client shares, imported rather
# than written a second time: PollLorcanaPrices' file holds them because Lorcana
# needed them first and none of them is Lorcana-specific. collector_sort_key is
# TcgCard.collectorNumberSortKey, dart_string and dart_int are the null-and-blank
# handling every mapping in this program is written in terms of, and normalise_name
# is TcgCard.normaliseName.
from poll_lorcana_prices import (  # noqa: E402  (same directory as this file)
    collector_sort_key,
    dart_int,
    dart_string,
)

GAME = "swu"
SOURCE = "ffg"
API = "https://admin.starwarsunlimited.com/api"
UA = "Arcanum/1.0 (+https://github.com/arm00pv/arcanum)"

# The page size the source will honour, and the largest it will honour: asking for
# 1000 answers 250 records and reports its own page size rather than refusing.
PAGE_SIZE = 250

# The card types that are not cards (SwuCatalog._tokens). A token is printed on
# the same sheet as everything else and listed beside the cards, but nothing holds
# one in a binder: left in, a search for "shield" answers with the Shield token.
TOKENS = frozenset(("Token Upgrade", "Token Unit", "Credit Token", "Force Token"))

# The filter that leaves base printings of cards and nothing else, which is what a
# set's own card count is measured over (SwuCatalog._baseOnly). Measured on Spark
# of Rebellion: 991 records, 254 with no variantOf, 252 once the tokens are out.
BASE_ONLY = (("filters[variantOf][$null]", "true"),) + tuple(
    ("filters[type][name][$notIn][%d]" % i, name)
    for i, name in enumerate(("Token Upgrade", "Token Unit", "Credit Token",
                              "Force Token")))

_NOT_CODE_CHAR = re.compile(r"[^a-z0-9]+")


# ---------------------------------------------------------------------------
# Reading the publisher
# ---------------------------------------------------------------------------


def get_json(url, timeout=60, retries=3):
    """GETs a URL and decodes JSON, retrying the failures worth retrying.

    A 4xx is not retried: the source answering "no such set" is an answer. Anything
    else - a socket error, a 429, a 5xx - is retried with backoff, which matters
    here because the host does answer 502 under load and a set that is half-read is
    a set that must not be written.
    """
    last = None
    for attempt in range(retries + 1):
        try:
            request = urllib.request.Request(url, headers={
                "Accept": "application/json",
                "Origin": "https://arcanum.example",
                "User-Agent": UA,
            })
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return json.loads(
                    response.read().decode("utf-8", "replace") or "null")
        except urllib.error.HTTPError as exc:
            last = exc
            if 400 <= exc.code < 500 and exc.code != 429:
                raise
        except Exception as exc:  # noqa: BLE001 - retried, then raised
            last = exc
        time.sleep(0.5 * (attempt + 1))
    raise RuntimeError("could not read %s: %s" % (url, last))


def rows_of(body):
    """The 'data' array every route answers with (SwuCatalog._rowsOf)."""
    if isinstance(body, dict) and isinstance(body.get("data"), list):
        return body["data"]
    return []


def total_of(body):
    """The total behind an answer, from its pagination envelope."""
    if not isinstance(body, dict):
        return 0
    meta = body.get("meta")
    if not isinstance(meta, dict):
        return 0
    pagination = meta.get("pagination")
    if not isinstance(pagination, dict):
        return 0
    return dart_int(pagination.get("total")) or 0


def cards_url(params):
    """One card-list read, as a URL.

    [params] is a list of (key, value) pairs and the filter keys carry brackets
    and a dollar sign, which urlencode percent-encodes. That is the form the
    live source answers - measured, and the form the Dart client's own browser
    requests take (`pagination%5BpageSize%5D`) - so the two languages send the
    same request under two spellings of the same string.
    """
    return "%s/card-list?%s" % (
        API, urllib.parse.urlencode([("locale", "en")] + list(params)))


def set_list(timeout=60, retries=3):
    """Every set the publisher lists: code, name and a CMS ordering value.

    One request, 27 sets, 7 KB. The list carries no card count of any kind, which
    is why a count is a second request per set - see base_count.
    """
    url = ("%s/card-expansions?locale=en&pagination[pageSize]=100" % API)
    return rows_of(get_json(url, timeout=timeout, retries=retries))


def base_count(provider_code, timeout=60, retries=3):
    """How many base printings one set holds (SwuCatalog._baseCount).

    A one-record read whose pagination envelope carries the total, which is the
    only way to a count from a source with no set endpoint that has one: 27
    requests of about 10 KB, against the 135 MB it would cost to fold the counts
    out of the card list itself.
    """
    url = cards_url([
        ("pagination[pageSize]", "1"),
        ("pagination[page]", "1"),
        ("filters[expansion][code][$eq]", provider_code),
    ] + list(BASE_ONLY))
    return total_of(get_json(url, timeout=timeout, retries=retries))


def set_cards(provider_code, timeout=60, retries=3, page_size=PAGE_SIZE):
    """Every record the publisher files under one set, whole.

    Paged, because the page cap is the source's own. The loop stops on a short
    page, which is the source's statement that there is nothing after it, and on a
    page guard so a listing that never shortens cannot spin for ever.

    Every record of the set is returned, treatments included: writing a set
    replaces it, so a record left out of this list is a row deleted from the
    catalogue and a holding that stops resolving.
    """
    out = []
    page = 1
    while True:
        url = cards_url([
            ("pagination[pageSize]", str(page_size)),
            ("pagination[page]", str(page)),
            ("filters[expansion][code][$eq]", provider_code),
        ])
        body = get_json(url, timeout=timeout, retries=retries)
        rows = rows_of(body)
        for row in rows:
            if isinstance(row, dict):
                out.append(row)
        if len(rows) < page_size or page >= 80:
            break
        page += 1
    return out


# ---------------------------------------------------------------------------
# The catalogue import: every rule that turns a record into a stored row
# ---------------------------------------------------------------------------
#
# This half of the file is a transcription of lib/data/catalog/swu_catalog.dart, and
# it is written that way on purpose. That client decides what a Star Wars:
# Unlimited card is; this decides what gets stored; both write into the same SQLite
# tables on the client, and a collection row names a card id. If the two disagree
# about an id, a name, a rarity, a sort key, a type line or an extras key, the
# disagreement is invisible until somebody's holding renders as "--". So each
# function below names the Dart it mirrors, and tool/catalog/test_id_parity.py
# asserts the two agree over a committed sample of real responses.


def slug(value):
    """Codes.fold: lower case, letters and digits only.

    This is the form a set code is stored in everywhere in the app, so a row
    carrying SOR is a set the client can never mark as catalogued and would
    re-download on every visit. Every code this game prints is letters and digits
    with nothing between them, so the fold is the case and nothing else - which the
    proof asserts rather than assumes.
    """
    text = dart_string(value) or ""
    return _NOT_CODE_CHAR.sub("", text.lower())


def set_type_for(code, name):
    """SwuCatalog._setTypeFor, over the two things the publisher states."""
    upper = (code or "").upper()
    lower = (name or "").lower()
    # The name is read before the code, and the weekly-play runs are why: JTLP is
    # "Jump to Lightspeed Weekly Play" and its code begins with J, while LOFP,
    # SECP and LAWP are the same kind of run under codes that begin with L, S and
    # L. Reading the code first typed one of the four as a promo run and the other
    # three as weekly play, which is one kind of set split in two by the first
    # letter of its code.
    if "weekly play" in lower:
        return "weekly"
    if "intro battle" in lower:
        return "starter"
    for word in ("promo", "convention", "judge", "exclusive", "prize",
                 "event pack", "gamegenic"):
        if word in lower:
            return "promo"
    if upper[:1] in ("P", "J", "C"):
        return "promo"
    return "expansion"


def attributes_of(raw):
    """SwuCatalog._attributesOf: a record's attributes, from either shape.

    Every route answers rows as {id, attributes} and relations as {data: {id,
    attributes}}, so both arrive here. A map with no 'attributes' and no 'data' is
    taken as attributes itself.
    """
    if not isinstance(raw, dict):
        return None
    inner = raw.get("attributes")
    if isinstance(inner, dict):
        return inner
    if "data" in raw:
        return None
    return raw


def relation(raw):
    """SwuCatalog._relation: the attributes of a relation, or None."""
    if not isinstance(raw, dict):
        return None
    return attributes_of(raw.get("data"))


def relation_of(attributes, key):
    """The attributes of a named relation on a record."""
    if not isinstance(attributes, dict):
        return None
    return relation(attributes.get(key))


def names_of(attributes, key):
    """SwuCatalog._names: the names of a relation that holds a list, in order."""
    if not isinstance(attributes, dict):
        return []
    raw = attributes.get(key)
    if not isinstance(raw, dict):
        return []
    data = raw.get("data")
    if not isinstance(data, list):
        return []
    out = []
    for item in data:
        name = dart_string((attributes_of(item) or {}).get("name"))
        if name:
            out.append(name)
    return out


def text_field(raw):
    """SwuCatalog._text: Dart's _string, which is blank-is-absent."""
    return dart_string(raw)


def dart_number(raw):
    """The (x as num?)?.toDouble() in the catalog: a number, or None.

    Not a text parse: the Dart cast answers null for a string rather than parsing
    it, so a cost the publisher ever spells as text is an absence here as well.
    """
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        return None
    return float(raw)


def dart_num(raw):
    """The _num(raw) in the catalog, which keeps an int as an int.

    extras carries power, hp and the two upgrade numbers as they arrive, and the
    Dart keeps 4 as 4 rather than 4.0, so this does too.
    """
    if isinstance(raw, bool):
        return None
    if isinstance(raw, (int, float)):
        return raw
    return None

def type_line_of(attributes):
    """SwuCatalog._typeLine: the card's type, its deployed type and its arena.

    The publisher states those in three relations and the type line is what the
    app shows under a name and what a text search reads, so they are joined into
    it rather than left in fields nothing reads."""
    kind = dart_string((relation_of(attributes, "type") or {}).get("name")) or ""
    deployed = dart_string((relation_of(attributes, "type2") or {}).get("name")) or ""
    parts = []
    if kind:
        parts.append(kind)
    if deployed and deployed != kind:
        parts.append(deployed)
    parts.extend(names_of(attributes, "arenas"))
    line = " - ".join(parts)
    return line or None


def oracle_text_of(attributes):
    """SwuCatalog._oracleText: the two boxes a leader prints, then its text.

    A leader prints an epic action and a deploy box above its rules text, and a
    unit with a deploy box prints one too. They are the card's text as far as a
    collector - and a search over text - is concerned, so they are joined into the
    field the app searches, in the order the card prints them."""
    parts = []
    for field in ("epicAction", "deployBox", "text", "rules"):
        value = text_field(attributes.get(field))
        if value is not None:
            parts.append(value)
    return "\n\n".join(parts) if parts else None


def image_of(raw):
    """The full-size URL of one art object (SwuCatalog._image)."""
    return dart_string((relation(raw) or {}).get("url"))


def art_of(attributes):
    """SwuCatalog._art: the picture the app draws for one record.

    A leader's own art is landscape - 418x300 for the leader side, with the
    deployed unit on the other face at 300x418 - and every card in the app is
    drawn at the game's portrait ratio, so a landscape card is stored as its other
    face when it has one: the same card, the same character, and nothing cropped
    off the sides.

    The flag is not a leader flag: 88 records of the committed sample are
    landscape (56 Leaders and 32 Bases) and only the leaders carry a second face,
    so a base is drawn from the only art it has.

    This is the publisher's own address and not a relayed one. CardArt.host
    rewrites a relayed host on a web build only, and this host needs no relay -
    it answers a browser with Access-Control-Allow-Origin - so what is stored is
    what both platforms read."""
    front = image_of(attributes.get("artFront"))
    back = image_of(attributes.get("artBack"))
    if attributes.get("artFrontHorizontal") is True and back:
        return back
    return front or back


def extras_of(attributes):
    """SwuCatalog._card's extras map, as the JSON a client stores.

    Note what is NOT here: 'tcgplayerId'. The app reads that key as the join key
    for price history, and this publisher states no TCGplayer product id, so one
    under that key would be a number the app looked prices up with and never
    found. Every other key is the publisher's own field under the spelling the
    Dart gives it, plus the facts the Dart derives: the printed number the row is
    filed under and the id of the base card a treatment points at.

    A key the Dart omits is omitted here too, and that is the whole difficulty of
    this function: null is not the same as absent in stored JSON, and the two
    languages have to disagree about nothing."""
    uid = dart_string(attributes.get("cardUid"))
    provider_code = dart_string((relation_of(attributes, "expansion") or {})
                                .get("code"))
    base = relation_of(attributes, "variantOf")
    base_uid = dart_string((base or {}).get("cardUid"))
    printed = dart_int((base or {}).get("cardNumber"))
    if printed is None:
        printed = dart_int(attributes.get("cardNumber"))
    variants = names_of(attributes, "variantTypes")
    traits = names_of(attributes, "traits")
    arenas = names_of(attributes, "arenas")
    keywords = names_of(attributes, "keywords")

    extras = {"cardUid": uid, "setCode": provider_code}
    serial = dart_string(attributes.get("serialCode"))
    if serial is not None:
        extras["serial"] = serial
    if printed is not None:
        extras["printedNumber"] = printed
    if base_uid is not None:
        extras["variantOf"] = base_uid
    if variants:
        extras["variantTypes"] = variants
    subtitle = dart_string(attributes.get("subtitle"))
    if subtitle is not None:
        extras["subtitle"] = subtitle
    if traits:
        extras["traits"] = traits
    if arenas:
        extras["arenas"] = arenas
    if keywords:
        extras["keywords"] = keywords
    for field in ("power", "hp", "upgradePower", "upgradeHp"):
        number = dart_num(attributes.get(field))
        if number is not None:
            extras[field] = number
    if isinstance(attributes.get("unique"), bool):
        extras["unique"] = attributes["unique"]
    if attributes.get("hyperspace") is True:
        extras["hyperspace"] = True
    if attributes.get("showcase") is True:
        extras["showcase"] = True
    return extras

def card_document(row):
    """SwuCatalog._card, as one catalog_cards row, or None.

    Returns None for a record that is not a card: no id, no expansion, or a token.
    Everything else is a mapping rather than a decision, and the three decisions
    worth naming are the id, the collector number and the oracle id.

    The id is the publisher's cardUid, verbatim: it is unique over the whole game
    - 9,729 records of the walk carried 9,729 distinct values - and it is what
    survives a reprint. cardId is null on most records and names a related card
    where it is set (61 distinct values over 250) and validationId repeats (228
    over 250), so neither of those is an id.

    The collector number is the base card's. A hyperspace, foil, prestige,
    showcase or promo record carries a cardNumber of its own that counts something
    other than the card - hyperspace Luke is 1 where Luke is 5, and hyperspace
    IG-88 is 278 where IG-88 is 12 - so a record that points at a base with
    variantOf takes the base's number, which is the one printed on the card. It
    also makes the app's binder slots come out right: a slot is a (name, number)
    pair, so a collector who owns Luke owns that slot whichever treatment they
    hold.

    The oracle id is the base card's id for a treatment and the record's own id
    otherwise, which is what groups the treatments of one card together in the
    app's other-printings list."""
    attributes = attributes_of(row)
    if attributes is None:
        return None
    uid = dart_string(attributes.get("cardUid"))
    if not uid:
        return None

    type_name = dart_string((relation_of(attributes, "type") or {}).get("name")) or ""
    if type_name in TOKENS:
        return None

    expansion = relation_of(attributes, "expansion")
    provider_code = dart_string((expansion or {}).get("code"))
    if not provider_code:
        return None
    set_name = dart_string((expansion or {}).get("name")) or provider_code.upper()
    code = slug(provider_code)

    base = relation_of(attributes, "variantOf")
    base_uid = dart_string((base or {}).get("cardUid"))
    printed = dart_int((base or {}).get("cardNumber"))
    if printed is None:
        printed = dart_int(attributes.get("cardNumber"))

    title = dart_string(attributes.get("title")) or ""
    subtitle = dart_string(attributes.get("subtitle"))
    variants = names_of(attributes, "variantTypes")
    aspects = names_of(attributes, "aspects")
    foil = any("foil" in name.lower() for name in variants)
    collector_number = "" if printed is None else "%03d" % printed

    return {
        "id": uid,
        "oracle_id": base_uid or uid,
        "set_code": code,
        "set_name": set_name,
        # The name as the game prints it: a card's subtitle is half of what it is
        # called - "Luke Skywalker, Faithful Friend" - and the app shows one name
        # per card. It is also what keeps two leaders of the same name apart in a
        # binder slot.
        "name": title if subtitle is None else "%s, %s" % (title, subtitle),
        "collector_number": collector_number,
        "collector_sort": collector_sort_key(collector_number),
        "rarity": dart_string((relation_of(attributes, "rarity") or {})
                              .get("name")) or "unknown",
        # Empty rather than a word: SwuCatalog never sets TcgCard.layout, so the
        # client stores the constructor default and a server row carrying
        # "normal" would not be the row the client writes.
        "layout": "",
        "type_line": type_line_of(attributes),
        "oracle_text": oracle_text_of(attributes),
        "mana_cost": None,
        "cmc": dart_number(attributes.get("cost")),
        "colors": ",".join(aspects),
        "color_identity": ",".join(aspects),
        "artist": dart_string(attributes.get("artist")),
        "flavor_text": None,
        "image_small": None,
        "image_normal": art_of(attributes),
        "image_large": None,
        "image_art_crop": None,
        "image_png": None,
        "back_image_small": None,
        "back_image_normal": None,
        "digital": False,
        # A printing filed under a promotional run is a promotional card, and here
        # the set is not the only place it is stated: prerelease, judge, prize-wall
        # and movie promos sit inside a retail set and are named in the printing's
        # own variant types.
        "promo": (set_type_for(provider_code, set_name) == "promo"
                   or any(("Promo" in name) or ("Judge" in name)
                          or ("Prize" in name) for name in variants)),
        "reprint": False,
        "reserved": False,
        "full_art": False,
        "booster": False,
        "foil": foil,
        "nonfoil": not foil,
        "edhrec_rank": None,
        # The publisher states no release date for a card or for a set, and the
        # sets table sorts on this column: a guessed date would order the shelf
        # wrongly rather than harmlessly.
        "released_at": None,
        "extras": extras_of(attributes),
    }


def card_documents(rows, set_code):
    """Every catalog_cards row one set's records produce, keyed by their id.

    Keyed by the row's own id, which is the publisher's cardUid - the id the
    client stores and a holding names - so a repeated id keeps the last row, which
    is what the client's own found[card.id] = card does. The publisher publishes
    no repeated cardUid at all (9,729 of 9,729 measured), so this is the client's
    rule followed rather than a case that happens. Tokens and records with no id
    are dropped by card_document and never reach this map.

    set_code is passed and asserted rather than trusted: every card of a set
    download is the set it was asked for (catalog_store refuses a row whose
    set_code disagrees), so a record filed under another expansion is a record
    this importer has misread."""
    documents = {}
    for row in rows:
        document = card_document(row)
        if document is None:
            continue
        if set_code is not None and document["set_code"] != set_code:
            raise ValueError(
                "record %s is filed under %s but was read from %s"
                % (document["id"], document["set_code"], set_code))
        documents[document["id"]] = document
    return documents


def set_document(item, card_count):
    """SwuCatalog.fetchAllSets, as one catalog_sets row, or None.

    code is the publisher's code folded to lower case and id is its own spelling:
    every read path in the app folds a code before it touches SQLite, so a row
    carrying SOR is a set the client can never mark as catalogued.

    card_count is the number of base printings the set holds, which is what the
    publisher prints on the cards - 252 for Spark of Rebellion, where the same
    filter answers 991 for every record in the set. It is a second request per set
    because the set list carries no count, and the client pays the same 27
    requests for the same reason. printed_size is null: the source states one size
    and not two, and writing the same number twice would invent a distinction
    nothing makes."""
    attributes = attributes_of(item)
    if attributes is None:
        return None
    provider_code = dart_string(attributes.get("code"))
    if not provider_code:
        return None
    code = slug(provider_code)
    if not code:
        return None
    name = dart_string(attributes.get("name")) or provider_code
    return {
        "code": code,
        "id": provider_code,
        "name": name,
        "set_type": set_type_for(provider_code, name),
        "released_at": None,
        "card_count": card_count,
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


def import_catalogue_set(store, code, documents, set_doc, args):
    """Writes one set into the shared catalogue, or reports that it could not be.

    None means the set was not written, and the caller counts that as a failure so
    catalog_meta.last_import_ok says so. A quietly skipped set is the failure mode
    this whole design is trying to make visible."""
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
    this note, because this importer writes no prices: the publisher quotes none,
    and replace_prices is never called from here.

    upstream is the publisher's whole set list, folded, and it deliberately
    includes the sets whose cards failed to download - they are still published,
    and retiring them because one response went wrong would hide cards that are
    perfectly well catalogued. It is None when this run named a subset with
    --sets, because then "not in the list" means "not asked for" rather than
    "withdrawn"."""
    if upstream is not None:
        what = "%d sets upstream" % len(upstream)
    elif published:
        what = "%d sets published, %d named with --sets" % (published, named_sets)
    else:
        what = "%d sets named with --sets, and the list was not read" % named_sets
    note = ("%s, %d written, %d unchanged, %d cards, %d set(s) failed; "
            "no prices: the publisher quotes none"
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
    ap.add_argument("--lock", default="/tmp/arcanum-catalog-swu.lock",
                    help="flock file, so two imports of this game cannot interleave")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the SQL the catalogue import would run, and run none")
    ap.add_argument("--allow-empty-set", action="store_true",
                    help="let a set the publisher answers with no cards be emptied here")
    return ap.parse_args(argv)


def open_store(args):
    """The catalogue write path, or a refusal.

    The URL comes from the environment and never from a command-line argument. An
    argument is readable in a process listing by every user on the host, and the
    session pooler URL carries the database password - the one secret this
    deployment keeps in a mode-600 file and nowhere else."""
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
        attributes = attributes_of(item)
        if attributes is None:
            continue
        provider_code = dart_string(attributes.get("code"))
        if provider_code:
            by_code[provider_code] = item
    if not by_code:
        print("the publisher listed no sets; refusing to touch the catalogue",
              file=sys.stderr)
        return 1

    if args.sets:
        # Upper case, because that is the spelling the publisher filters by and
        # the spelling this run's request will carry.
        codes = [part.strip().upper() for part in args.sets.split(",")
                 if part.strip()]
        for code in codes:
            if code not in by_code:
                print("  %s is not a set the publisher publishes" % code,
                      file=sys.stderr, flush=True)
    else:
        codes = list(by_code)

    print("%d set(s) to import" % len(codes), flush=True)
    if not codes:
        print("nothing to do", flush=True)
        return 0

    # Taken before a single row is written. sets_revision is the signal that tells
    # every browser its set list is stale, and it is only meaningful if the
    # comparison is against the list as it stood before this run.
    before_fingerprint = store.set_list_fingerprint(GAME)

    written = 0
    cards_written = 0
    unchanged = 0
    failed = 0

    for i, provider_code in enumerate(codes, 1):
        item = by_code.get(provider_code)
        if item is None:
            failed += 1
            continue
        folded = slug(provider_code)
        try:
            # Two reads per set, and both before anything is written: the count
            # the set row carries, and every record the set holds.
            count = base_count(provider_code)
            records = set_cards(provider_code)
        except Exception as exc:  # noqa: BLE001 - reported, and the run goes on
            failed += 1
            print("  set %s failed: %s" % (folded, exc), file=sys.stderr,
                  flush=True)
            continue

        set_doc = set_document(item, count)
        if set_doc is None:
            failed += 1
            print("  set %s not imported: the publisher published no set code"
                  % folded, file=sys.stderr, flush=True)
            continue

        try:
            documents = card_documents(records, folded)
        except ValueError as exc:
            failed += 1
            print("  set %s not imported: %s" % (folded, exc), file=sys.stderr,
                  flush=True)
            continue
        if not documents:
            # A set the publisher answers with no records is far more likely to be
            # a bad response than a withdrawn set, and writing it would delete
            # every card the catalogue holds for it. Refused and counted, which is
            # what --allow-empty-set is for when it is genuinely the answer.
            failed += 1
            print("  set %s not imported: the publisher listed no records for it"
                  % folded, file=sys.stderr, flush=True)
            continue

        outcome = import_catalogue_set(store, folded, documents, set_doc, args)
        if outcome is None:
            failed += 1
        else:
            written += 1
            cards_written += outcome["cards"]
            if outcome["outcome"] == "unchanged":
                unchanged += 1
        print("  set %d/%d %s: %d records, %d cards catalogued, %d set(s) failed"
              % (i, len(codes), folded, len(records), cards_written, failed),
              flush=True)

    # A run that named a subset must not retire the sets it did not ask for, so the
    # upstream list is withheld in that case. The codes are the folded ones, because
    # retire_sets compares against the code the catalogue stores.
    upstream = None if args.sets else [
        slug((attributes_of(item) or {}).get("code")) for item in listing
        if attributes_of(item) is not None]
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
    sys.exit(main())
