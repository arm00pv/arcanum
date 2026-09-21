#!/usr/bin/env python3
"""Import Digimon into the shared catalogue.

Design: docs/catalogue-server-side.md, section 3. One importer for one game, and
the seventh to run through tool/catalog_store.py - the module that owns the seven
rules (one transaction per set, checksum first, sets before cards, never delete a
set, record the outcome, idempotent and single-flight, no partial revision bumps).
Nothing in this file re-implements any of them.

**Why this game, and why from here.** Digimon was one of the games catalogued only
by tcgcsv, which republishes TCGplayer's product catalogue, and they are the web
build's worst case: no Sets tab until a set is opened and no search at all. The app
now reads Heroicc directly - lib/data/catalog/digimon_catalog.dart, and
docs/catalogue-import-digimon.md is the report of that half - from a host that
answers a browser with Access-Control-Allow-Origin, which is the property tcgcsv
lacks and the reason Arcanum's relay exists. This file is the other half: the same
responses, written into Postgres so a browser stops downloading them for itself.

**The licence is the one thing about this game that is not a technical question,**
and it was answered deliberately rather than by default. Heroicc publishes its own
content under CC BY-NC-SA 4.0: non-commercial, which this app is, and share-alike,
which the copy in Arcanum's own catalogue carries. The attribution the licence asks
for is in the app's own acknowledgements (lib/core/legal.dart), and the terms'
clause about card images - do not cover the copyright or artist name - is satisfied
by where the app draws a quantity badge: the top-right corner, above the line at
the foot of the card. All three are written down because a re-hosted copy is the
thing the licence is about.

**What is derived, and therefore what the parity test is for.** The id is forwarded
verbatim - the source's own id, BT8-022 or BT5-007_P3, unique over the game - and
everything else about a row is derived here: the folded set code, the oracle id
(the id with the parallel suffix taken off), the collector number, the collector
sort key, the rarity word behind the source's code, the type line, the oracle text
and the JSON in extras. Each one is a transcription of
lib/data/catalog/digimon_catalog.dart and names the Dart it mirrors, because the
same rule in two languages is the drift docs/catalogue-server-side.md section 7
warns about - and tool/catalog/test_id_parity.py asserts the two agree over a
committed sample of real responses, over every column of a card row and of a set
row.

**What this importer does not write: prices.** Heroicc publishes no price of any
kind, and no TCGplayer product id to join one to. replace_prices is never called,
extras carries no 'tcgplayerId', and the cost is stated in the report rather than
worked around.

**A set is written whole or it is not written.** The source answers a set one card
at a time - there is no batch route - so a walk can fail in the middle, and a set
written from a short walk would have its missing cards pruned as though the source
had withdrawn them. One card that cannot be read therefore fails its whole set; the
report says which, and the next night reads it again.

Usage, from the repository root:

    set -a; . /home/zixen/arcanum/supabase.env; set +a
    python3 tool/import_digimon_catalogue.py
    python3 tool/import_digimon_catalogue.py --sets bt-05,pb14
    python3 tool/import_digimon_catalogue.py --dry-run

--sets takes either spelling: the source's own (bt-05) or the code the app shows
(bt05), because either is what a person has in front of them when they type one.

Exit status is 0 unless every set named failed and there was more than one.
"""

from __future__ import annotations

import argparse
import concurrent.futures
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
# TcgCard.collectorNumberSortKey, and dart_string and dart_int are the null-and-blank
# handling every mapping in this program is written in terms of.
from poll_lorcana_prices import (  # noqa: E402  (same directory as this file)
    collector_sort_key,
    dart_int,
    dart_string,
)

GAME = "digimon"
SOURCE = "Heroicc"
API = "https://api.heroi.cc"
UA = "Arcanum/1.0 (+https://github.com/arm00pv/arcanum)"

RELEASES = "/releases/en/"
CARDS = "/cards/en/"

# How many card reads are in flight at once, and how long each one waits after it
# answers. The source is one hobbyist's server: it asks to be identified, asks that
# responses be cached, and publishes no rate limit. The Dart client walks a set one
# request at a time with 90 ms between them, which is about eleven requests a
# second; three workers with a pause behind each lands in the same place, and a
# nightly import of 7,618 cards is a few minutes either way.
WORKERS = 3
GAP = 0.12

# The rarity codes this game prints, as the words collectors read
# (DigimonCatalog._rarities). The source states a code and nothing else, so the word
# is what the row carries and the code is kept in extras under 'rarityCode', where
# the app already looks for one.
RARITIES = {
    "C": "Common",
    "U": "Uncommon",
    "R": "Rare",
    "SR": "Super Rare",
    "UR": "Ultra Rare",
    "SEC": "Secret Rare",
    "P": "Promo",
}

# The raw attributes that go into extras under their own names
# (DigimonCatalog._card): stated by the source, read by nothing in the app yet, and
# kept because a card row is the only copy of them the catalogue has.
EXTRA_ATTRIBUTES = (
    "type",
    "form",
    "attribute",
    "level",
    "dp",
    "play-cost",
    "use-cost",
    "block-icon",
    "supplemental-rarity",
)

_NOT_CODE_CHAR = re.compile(r"[^a-z0-9]+")


# ---------------------------------------------------------------------------
# Reading the source
# ---------------------------------------------------------------------------


def get_json(url, timeout=60, retries=3):
    """GETs a URL and decodes JSON, retrying the failures worth retrying.

    A 4xx is not retried: the source answering "no such card" is an answer. Anything
    else - a socket error, a 429, a 5xx - is retried with backoff, which matters here
    because a set is a hundred separate requests and one of them failing must not
    cost the set.
    """
    last = None
    for attempt in range(retries + 1):
        try:
            request = urllib.request.Request(url, headers={
                "Accept": "application/vnd.api+json, application/json",
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


def included_of(envelope):
    """The 'included' array, which is what a route says beside its own row.

    The set list keeps its releases there and a card keeps the release it is filed
    under there, so this is not a decoration: it is the only place the source states
    either fact. (DigimonCatalog._includedOf.)
    """
    if not isinstance(envelope, dict):
        return []
    included = envelope.get("included")
    return included if isinstance(included, list) else []


def slug_of(item, prefix):
    """The id at the end of a route, or None. (DigimonCatalog._releaseSlug.)"""
    value = item.get("id") if isinstance(item, dict) else None
    if not isinstance(value, str) or not value.startswith(prefix):
        return None
    tail = value[len(prefix):]
    return tail or None


def set_list(timeout=60, retries=3):
    """Every release the source lists, in one request.

    The language object answers once and names its releases in 'included' with the
    three things a set row needs - the name, the number of card entries it lists and,
    for 87 of the 93, the date it went on sale. There is no count request here, which
    is the difference between this source and the one Star Wars: Unlimited came from.
    """
    return get_json(API + "/releases/en", timeout=timeout, retries=retries)


def release_envelope(provider_code, timeout=60, retries=3):
    """One release, with the ids of its cards and nothing else.

    A release names its cards one id at a time and there is no route that answers
    several at once (measured: /cards/en as a collection is a 404 and ?include=cards
    is ignored), so this is the first of the two reads a set costs.
    """
    return get_json(API + "/releases/en/" + provider_code, timeout=timeout,
                    retries=retries)


def card_envelope(card_id, timeout=60, retries=3):
    """One card, by its own id, as the source answers it."""
    envelope = get_json(API + "/cards/en/" + card_id, timeout=timeout,
                        retries=retries)
    if not isinstance(envelope, dict) or not isinstance(envelope.get("data"), dict):
        raise RuntimeError("the source answered no card for %s" % card_id)
    return envelope


def card_ids_of(envelope):
    """The card ids one release lists, in the source's own order."""
    found = [slug_of(item, CARDS) for item in included_of(envelope)]
    return [card_id for card_id in found if card_id is not None]


def release_name_of(envelope):
    """What the source calls the release this envelope is."""
    data = envelope.get("data") if isinstance(envelope, dict) else None
    attributes = data.get("attributes") if isinstance(data, dict) else None
    if not isinstance(attributes, dict):
        return None
    return dart_string(attributes.get("name"))


def card_envelopes(card_ids, provider_code):
    """Every card of one release, read together but returned in the release's order.

    One failure is raised rather than skipped, and the caller lets it fail the whole
    set: import_set writes the cards of a set as that set's rows, so a walk that
    quietly lost three of a hundred would prune three rows a collector may hold. The
    Dart client can afford to skip a card - it is filling a local cache, and the next
    screen reads it again - and this cannot.
    """
    found = {}

    def read(card_id):
        try:
            return card_id, card_envelope(card_id)
        except Exception as exc:  # noqa: BLE001 - reported by the caller
            raise RuntimeError("card %s of %s could not be read: %s"
                               % (card_id, provider_code, exc))
        finally:
            time.sleep(GAP)

    with concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
        for card_id, envelope in pool.map(read, card_ids):
            found[card_id] = envelope
    return found


# ---------------------------------------------------------------------------
# Deriving one set
# ---------------------------------------------------------------------------


def slug(value):
    """The code the catalogue stores: lower case, separators gone.

    Codes.fold, and the form every read path of the app compares a code in - so
    'bt-05' becomes 'bt05', which is also what a card prints. The source's own
    spelling is kept in the set row's id, because that is what a request names and
    the two are not recoverable from each other: folding throws away the dash *and*
    the version numbering of bt01-03-v1-0, which folds to bt0103v10.
    """
    return _NOT_CODE_CHAR.sub("", (dart_string(value) or "").lower())


def set_type_for(provider_code, name):
    """The kind of release this is, from the two things the source states.

    There is no genre in the set list - a release's own route carries one, and
    reading it would cost 93 requests - so the type is read off the code and the name
    exactly as the Gundam and Star Wars: Unlimited importers read theirs
    (DigimonCatalog._setTypeFor). The split that matters to a collector is starters
    against boosters against everything else.
    """
    code = (dart_string(provider_code) or "").lower()
    lower = (dart_string(name) or "").lower()
    if code.startswith("st-") or "start deck" in lower:
        return "starter"
    if (code.startswith("bt") or code.startswith("ex-") or code.startswith("rb-")
            or code.startswith("ad-") or "booster" in lower):
        return "expansion"
    return "promo"


def collector_number_of(printed):
    """The position within the set, from the number the card prints.

    The source writes the number as the card prints it - BT8-022 - and the digits at
    the end are the position, exactly as the other importers read the same number. A
    number with no dash is kept whole rather than guessed at
    (DigimonCatalog._collectorNumberOf).
    """
    text = dart_string(printed) or ""
    if not text:
        return ""
    first = text.split()[0]
    dash = first.rfind("-")
    if dash < 0 or dash == len(first) - 1:
        return first
    return first[dash + 1:]


def base_id_of(card_id):
    """The card id without the parallel suffix: the base card this printing is one of.

    BT5-007_P3 is a printing of BT5-007, and the app groups a card's printings and
    fills its binder slots on the oracle id, so this rule is what decides what "every
    printing of this card" means. The suffix must be one to three characters, which
    is what keeps an id whose own tail is longer from being cut in half
    (DigimonCatalog._baseIdOf).
    """
    underscore = card_id.rfind("_")
    if underscore <= 0:
        return card_id
    suffix = card_id[underscore + 1:]
    if not suffix or len(suffix) > 3:
        return card_id
    return card_id[:underscore]


def code_of_number(number):
    """The set a printed number names, for a card the source files under no release.

    Lower-cased and *not* folded, which is what the Dart does: the fallback reads the
    prefix of the printed number as it stands, so a card printed BT1-010 with no
    release attached is filed under 'bt1' rather than under the 'bt01' a release code
    folds to (DigimonCatalog._codeOfNumber).
    """
    printed = dart_string(number) or ""
    dash = printed.find("-")
    if dash <= 0:
        return printed.lower()
    return printed[:dash].lower()


def releases_of(data):
    """The releases a card is filed under, as the source's own codes.

    In the source's order, because the first one is the answer for a card reached by
    its id alone - 7,541 of 7,618 cards name one release, 142 name two and 77 name
    none (DigimonCatalog._releasesOf).
    """
    relationships = data.get("relationships") if isinstance(data, dict) else None
    releases = (relationships.get("releases")
                if isinstance(relationships, dict) else None)
    rows = releases.get("data") if isinstance(releases, dict) else None
    if not isinstance(rows, list):
        return []
    found = [slug_of(row, RELEASES) for row in rows]
    return [slug for slug in found if slug is not None]


def set_name_in(included, provider_code):
    """What the source calls the release [provider_code] names.

    Read from the answer's own 'included' array, which is where a card envelope
    carries the release it is filed under. A card reached in a set download is handed
    the release it was downloaded as part of and never needs this; a card reached by
    its id alone has nothing else (DigimonCatalog._setNameOf).
    """
    wanted = RELEASES + provider_code
    for item in included:
        if not isinstance(item, dict) or item.get("id") != wanted:
            continue
        meta = item.get("meta")
        if not isinstance(meta, dict):
            continue
        name = dart_string(meta.get("name"))
        if name:
            return name
    return None


def category_label(category):
    """The word the app shows for a category the source spells in lower case."""
    return {
        "digimon": "Digimon",
        "digi-egg": "Digi-Egg",
        "tamer": "Tamer",
        "option": "Option",
    }.get(category, category)


def type_line_of(attributes):
    """The type line, as the app shows and searches it.

    The source states a card's category, its species, the level it sits at and the
    form it takes; the type line is what the app shows under a name, so they are
    joined into it rather than left in fields nothing reads
    (DigimonCatalog._typeLine).
    """
    category = dart_string(attributes.get("category")) or ""
    species = dart_string(attributes.get("type")) or ""
    form = dart_string(attributes.get("form")) or ""
    level = dart_int(attributes.get("level"))
    parts = []
    if category:
        parts.append(category_label(category))
    if species:
        parts.append(species)
    if form:
        parts.append(form)
    if level is not None:
        parts.append("Lv.%d" % level)
    line = " - ".join(parts)
    return line or None


def oracle_text_of(attributes):
    """The rules text, with the boxes a card prints below and behind it.

    A Digimon card prints an inherited effect in its own box at the foot of the card,
    and a security effect on the reverse for the cards that have one. They are the
    card's text as far as a collector - and as far as a search over text - is
    concerned, so they are joined in the order the card prints them
    (DigimonCatalog._oracleText).
    """
    parts = []
    for field in ("effect", "inherited-effect", "security-effect"):
        value = dart_string(attributes.get(field))
        if value is not None:
            parts.append(value)
    return "\n\n".join(parts) or None


def names_of(raw):
    """The names in a field that holds a list of strings, in the order given."""
    if not isinstance(raw, list):
        return []
    found = [dart_string(item) for item in raw]
    return [name for name in found if name is not None]


def extras_of(attributes, card_id, releases):
    """The JSON column of one card row (DigimonCatalog._card's extras).

    Note what is NOT here: 'tcgplayerId'. The app reads that key as the join key for
    price history, and Heroicc publishes no TCGplayer product id, so one under it
    would be a number the app looked prices up with and never found.
    """
    extras = {
        "number": dart_string(attributes.get("number")) or "",
        "printedNumber": dart_string(attributes.get("number")) or "",
    }
    rarity_code = dart_string(attributes.get("rarity"))
    if rarity_code is not None:
        extras["rarityCode"] = rarity_code
    category = dart_string(attributes.get("category"))
    if category is not None:
        extras["category"] = category
    parallel = attributes.get("parallel-id")
    if isinstance(parallel, (int, float)) and not isinstance(parallel, bool):
        extras["parallelId"] = parallel
    if releases:
        extras["releases"] = list(releases)
    for field in EXTRA_ATTRIBUTES:
        value = attributes.get(field)
        if value is not None:
            extras[field] = value
    return extras


def card_document(envelope, set_code=None, set_name=None):
    """One card row, from the source's own envelope.

    Returns None for an envelope that is not a card. Every derived value names the
    Dart it is a transcription of, because a row written here and a row the client
    writes for the same card have to be the same row: the id is the key a collection
    entry holds, and a disagreement about it does not raise anywhere - it renders as
    "--" for ever, for one collector, and nothing says why.
    """
    data = envelope.get("data") if isinstance(envelope, dict) else None
    card_id = slug_of(data, CARDS)
    if card_id is None:
        return None
    attributes = data.get("attributes")
    if not isinstance(attributes, dict):
        return None

    # The card's own record decides the release, and the walk it arrived in is only
    # a fallback. That matters for the 142 cards the source files under two
    # releases - a premium parallel listed both by its own promotion and by the
    # binder set it was reprinted in - because a card is one row here: with the
    # walk deciding, the release that happened to be walked last owned the card,
    # which left Premium Bandai's own set holding 29 entries and no rows at all.
    # The first release a card names is the source's own answer, and it is the
    # order the client's by-id path has always used.
    releases = releases_of(data)
    if releases:
        provider_code = releases[0]
    elif set_code is not None:
        provider_code = set_code
    else:
        provider_code = code_of_number(attributes.get("number"))
    code = slug(provider_code)

    number = dart_string(attributes.get("number")) or ""
    rarity_code = dart_string(attributes.get("rarity"))
    image = dart_string(attributes.get("image"))
    colors = names_of(attributes.get("color"))
    play_cost = attributes.get("play-cost")
    if not isinstance(play_cost, (int, float)) or isinstance(play_cost, bool):
        play_cost = attributes.get("use-cost")
    if not isinstance(play_cost, (int, float)) or isinstance(play_cost, bool):
        play_cost = None

    # The release the row is filed under names itself in the card's own envelope;
    # the walk's own answer is only a fallback for a card whose envelope does not
    # carry the release it names.
    name = set_name_in(included_of(envelope), provider_code) or set_name
    if name is None:
        name = code.upper()

    return {
        "id": card_id,
        "oracle_id": base_id_of(card_id),
        "set_code": code,
        "set_name": name,
        "name": dart_string(attributes.get("name")) or "",
        "collector_number": collector_number_of(number),
        "collector_sort": collector_sort_key(collector_number_of(number)),
        "rarity": RARITIES.get(rarity_code, rarity_code or "unknown"),
        "layout": "",
        "type_line": type_line_of(attributes),
        "oracle_text": oracle_text_of(attributes),
        "mana_cost": None,
        "cmc": play_cost,
        "colors": ",".join(colors),
        "color_identity": ",".join(colors),
        "artist": None,
        "flavor_text": None,
        "image_small": None,
        # The source's own address, never the relay's: CardArt.host rewrites it on a
        # web build, and a stored row that already named the relay would be a row a
        # phone could not read.
        "image_normal": image,
        "image_large": None,
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
        "released_at": None,
        "extras": extras_of(attributes, card_id, releases),
    }


def card_documents(envelopes, code, name):
    """The card rows of one release that are filed under it, keyed by id.

    A release lists every card it carries and a card belongs to one release, so the
    two are not the same list: a premium parallel is listed by its promotion and by
    the binder set it was reprinted in, and the row belongs to the release the card's
    own record names first. The others are dropped here rather than written under
    this release, because the catalogue's own rule is that a card is stored under the
    set it belongs to - and because the walk of the release that owns them writes
    them, so nothing is lost. What the release *lists* is still what its set row's
    card_count says, which is the source's own number and a fact about the release
    rather than about these rows.
    """
    documents = {}
    for card_id, envelope in envelopes.items():
        document = card_document(envelope, set_code=code, set_name=name)
        if document is None:
            raise ValueError("the source answered nothing card-like for %s" % card_id)
        if document["set_code"] != code:
            continue
        documents[document["id"]] = document
    return documents


def set_document(item, provider_code):
    """One set row, from the source's own entry in its set list.

    Returns None for an entry with no name or no code. card_count is the source's own
    number, which counts the card *entries* a release lists rather than the distinct
    cards it holds - 7,685 entries across 7,541 distinct ids, because 142 promotional
    cards are listed by two releases each. That is the number the tile shows and the
    source's own fact; what a set holds is measured from the rows.
    """
    meta = item.get("meta") if isinstance(item, dict) else None
    if not isinstance(meta, dict):
        return None
    code = slug(provider_code)
    if not code:
        return None
    name = dart_string(meta.get("name")) or provider_code
    return {
        "code": code,
        "id": provider_code,
        "name": name,
        "set_type": set_type_for(provider_code, name),
        "released_at": dart_string(meta.get("date")),
        "card_count": dart_int(meta.get("cards")) or 0,
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


def import_catalogue_set(store, code, documents, set_doc, args,
                         empty_is_the_answer=False):
    """Writes one set into the shared catalogue, or reports that it could not be.

    None means the set was not written, and the caller counts that as a failure so
    catalog_meta.last_import_ok says so. A quietly skipped set is the failure mode
    this whole design is trying to make visible.

    empty_is_the_answer says the release owns no card at all, which is a real answer
    for a promotional run whose cards are all filed under the releases their own
    records name. Without it, emptying a set the catalogue holds rows for is refused
    - the guard against a bad response deleting a set - and with it, the empty list
    is what the walk measured.
    """
    rows = {}
    for row in documents.values():
        rows[row["id"]] = row
    try:
        return store.import_set(GAME, set_doc, list(rows.values()),
                                allow_empty=(args.allow_empty_set
                                             or empty_is_the_answer))
    except catalog_store.CatalogError as exc:
        print("  set %s not imported: %s" % (code, exc), file=sys.stderr,
              flush=True)
        return None


def record_catalogue_outcome(store, upstream, sets_written, cards_written,
                             sets_unchanged, failed_sets, before_fingerprint,
                             named_sets=0, published=0):
    """Writes catalog_meta for the run, whether it went well or not.

    Design rule 5: a broken importer has to be a fact a client can read, so
    last_import_ok is written on the failure path too. There is no price half to this
    note, because this importer writes no prices: the source quotes none, and
    replace_prices is never called from here.

    upstream is the source's whole set list, folded, and it deliberately includes the
    releases whose cards failed to download - they are still published, and retiring
    them because one response went wrong would hide cards that are perfectly well
    catalogued. It is None when this run named a subset with --sets, because then
    "not in the list" means "not asked for" rather than "withdrawn".
    """
    if upstream is not None:
        what = "%d sets upstream" % len(upstream)
    elif published:
        what = "%d sets published, %d named with --sets" % (published, named_sets)
    else:
        what = "%d sets named with --sets, and the list was not read" % named_sets
    note = ("%s, %d written, %d unchanged, %d cards, %d set(s) failed; "
            "no prices: the source quotes none"
            % (what, sets_written, sets_unchanged, cards_written, failed_sets))
    return store.finish(GAME, source=SOURCE, ok=failed_sets == 0, note=note,
                        upstream_codes=upstream,
                        before_fingerprint=before_fingerprint)


def parse_args(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--sets", default="",
                    help="comma-separated set codes; default is every set")
    # One lock per game, not one for the whole catalogue: every statement the store
    # generates is scoped to a game, so two importers of different games write
    # disjoint rows and have nothing to keep apart. single_flight refuses rather than
    # waits, so a shared lock would cost a whole game's night.
    ap.add_argument("--lock", default="/tmp/arcanum-catalog-digimon.lock",
                    help="flock file, so two imports of this game cannot interleave")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the SQL the catalogue import would run, and run none")
    ap.add_argument("--allow-empty-set", action="store_true",
                    help="let a release the source answers with no cards be emptied here")
    return ap.parse_args(argv)


def open_store(args):
    """The catalogue write path, or a refusal.

    The URL comes from the environment and never from a command-line argument. An
    argument is readable in a process listing by every user on the host, and the
    session pooler URL carries the database password - the one secret this deployment
    keeps in a mode-600 file and nowhere else.
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
    # Design rule 6: the lock is held for the whole run, so a hand-run import and the
    # nightly timer cannot interleave.
    try:
        with catalog_store.single_flight(args.lock):
            return run(args, store)
    except catalog_store.CatalogError as exc:
        print("catalogue import refused: %s" % exc, file=sys.stderr)
        return 1


def run(args, store):
    t0 = time.time()

    listing = included_of(set_list())
    by_code = {}
    for item in listing:
        provider_code = slug_of(item, RELEASES)
        if provider_code:
            by_code[provider_code] = item
    if not by_code:
        print("the source listed no releases; refusing to touch the catalogue",
              file=sys.stderr)
        return 1

    # Either spelling names the same release: the source's own 'bt-05' and the code
    # the app shows and a person types, 'bt05'.
    by_fold = {slug(provider_code): provider_code for provider_code in by_code}
    if args.sets:
        codes = []
        for part in args.sets.split(","):
            wanted = slug(part)
            if not wanted:
                continue
            found = by_fold.get(wanted)
            if found is None:
                print("  %s is not a release the source lists" % part.strip(),
                      file=sys.stderr, flush=True)
                continue
            codes.append(found)
    else:
        codes = list(by_code)

    print("%d release(s) to import" % len(codes), flush=True)
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
        folded = slug(provider_code)
        if item is None:
            failed += 1
            continue
        try:
            # One read for the ids, then one per card. Both before anything is
            # written, because a set is written whole or not at all.
            envelope = release_envelope(provider_code)
            card_ids = card_ids_of(envelope)
            if not card_ids:
                raise RuntimeError("the release lists no cards")
            envelopes = card_envelopes(card_ids, provider_code)
            name = release_name_of(envelope)
            if name is None:
                meta = item.get("meta") if isinstance(item.get("meta"), dict) else {}
                name = dart_string(meta.get("name"))
        except Exception as exc:  # noqa: BLE001 - reported, and the run goes on
            failed += 1
            print("  set %s failed: %s" % (folded, exc), file=sys.stderr, flush=True)
            continue

        set_doc = set_document(item, provider_code)
        if set_doc is None:
            failed += 1
            print("  set %s not imported: the source published no name for it"
                  % folded, file=sys.stderr, flush=True)
            continue

        try:
            documents = card_documents(envelopes, folded, name)
        except ValueError as exc:
            failed += 1
            print("  set %s not imported: %s" % (folded, exc), file=sys.stderr,
                  flush=True)
            continue
        # A release that lists cards and owns none of them is an answer rather than
        # a failure - every card it carries is filed under the release its record
        # names first, and each of those walks writes its own rows. What is a
        # failure is a release the source answers with no ids at all, which is
        # refused above, before a single card is read.
        outcome = import_catalogue_set(store, folded, documents, set_doc, args,
                                      empty_is_the_answer=not documents)
        if outcome is None:
            failed += 1
        else:
            written += 1
            cards_written += outcome["cards"]
            if outcome["outcome"] == "unchanged":
                unchanged += 1
        print("  set %d/%d %s: %d listed, %d filed here, %d cards catalogued, "
              "%d set(s) failed"
              % (i, len(codes), folded, len(card_ids), len(documents),
                 cards_written, failed), flush=True)

    # A run that named a subset must not retire the releases it did not ask for, so
    # the upstream list is withheld in that case. The codes are the folded ones,
    # because retire_sets compares against the code the catalogue stores.
    upstream = None if args.sets else [slug(provider_code) for provider_code in by_code]
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
