# The Gundam import, as it ran

Status: applied to the live project (`wqycllzbwbhqiqlmbwcu`) on 2026-09-21 by a
run of `tool/import_gundam_catalogue.py` from `zapp.sytes.net`. Gundam is the
first of the five games that were catalogued only by tcgcsv to be moved onto a
source of its own, which is what the web build needs: those five had an empty
Sets tab until a set was opened and no search across the game at all.
[catalogue-server-side.md](catalogue-server-side.md) sections 3, 7 and 8 are the
specification; this file records what was built, what the live data forced, and
how to undo it.

If this file and the code disagree, the code is what ran.

## What is in the database now

Read back after the final run:

~~~
gundam sets        = 28
gundam cards       = 1912
gundam prices      = 0
gundam retired     = 0
lorcana sets       = 24      (untouched by this step)
lorcana cards      = 3208
pokemon sets       = 220     (untouched by this step)
pokemon cards      = 23736
catalog_prices     = gundam 0, lorcana 5764, pokemon 72161

game        sets_revision  set_count  card_count  last_import_ok  source
gundam      1              28         1912        t               gcgapi
~~~

The first run took 62 seconds and wrote everything; the second took 25 seconds and
wrote nothing, which is the checksum skip doing its job - *28 sets written, 28
unchanged, 1912 cards, 0 set(s) failed*.

## Why this source, and what it cost

gcgapi publishes the publisher's own English card database from a host that sends
`Access-Control-Allow-Origin`: a browser can ask it directly, which is the
property tcgcsv lacks and the reason Arcanum's relay exists at all. It answers a
set list with a real card count (28 sets, each count equal to the number of
products its own filter returns), a set's products page by page, a single product
by id, and a search over names *and* rules text - `?name=zaku` answers 39
products and `?effect=repair` answers 74, both measured.

Three things it does not have, all of them real losses against tcgcsv and none of
them papered over:

**No price of any kind.** There is no market price, no low and no foil figure on a
card object, and no TCGplayer product id to join a price series to. So
`replace_prices` is never called by this importer, `catalog_prices` holds no
row for the game, and `extras` deliberately carries no `tcgplayerId` - the key
the app reads as the price-history join key. Gundam's prices still come from the
tcgcsv client, which is kept for this reason as well as for the fallback.

**No release date for any set.** The sets table sorts on `released_at`, so Gundam
sets come back in name order rather than newest first until a source for the date
is found.

**Art needs the relay.** Bandai's image host sends no `Access-Control-Allow-Origin`
at all - measured 2026-09-21, refused for every one of the 1,912 product images -
so `CardArt._relayed` and the relay's own `ART_ORIGINS` table both gained a
`gundam` entry in this change. **The relay has to be redeployed for that to
take effect**; until it is, a browser draws the card-back placeholder where a
phone draws the card. Nothing else about the move depends on a host of ours.

## Four things the live data forced

**The printed number cannot be the id, and this is the game where that bites.**
1,912 products carry 1,148 card numbers: an alternate art is a product of its own
with the same number printed on it - GD01-005 has four parallels, two of them
sharing a rarity - and one card number is printed on as many as nine products
(ST01-001). An id derived from the number would store, look unique, and silently
collapse a collector's two holdings into one row. The id is therefore the
provider's `product_id`, verbatim, and both halves of the parity test assert
that over a sample that holds 202 products sharing a number.

**Every set code is folded, and the fold is not a no-op here.** The provider
addresses a set by `GD01` and every read path of the app lower-cases a code
before it touches SQLite, so the code and the provider's spelling differ for all
28 sets. The row keeps both: `code` is the folded form the client queries with,
`id` is the provider's own. The provider's filter is case-insensitive, so the
folded code is a usable query and no lookup table is needed. The proof asserts the
folding *and* that it changed something, because a check that passes vacuously is
worse than no check.

**A bare hyphen is the provider's way of writing "nothing here".** 213 cards carry
"-" as their whole rules text, 1,115 link to no pilot, 807 deploy to no zone, 409
carry no trait and 6 have no block icon. Stored as they arrive, a Resource card's
type line reads "RESOURCE - - - -" and its rules text is a hyphen the app would
show and search. The client and the importer both read a bare hyphen as absent.

**A card is filed in the set the payload names, not the set its number names.**
74 of the sample's 553 products have a number belonging to another set - EXB-001_p7
is listed in SC01 - which is the same shape tcgcsv's groups have and is why the
row's set code comes from the payload. It also means this game's two client paths
- a set download and a card reached by its id - derive one row rather than two,
which the parity test asserts instead of assuming.

## The proof

`tool/catalog/prove_gundam_import.py`, 17 checks, run against the live database:

~~~
17 passed, 0 failed, 0 skipped
~~~

Two of its checks failed on their first run, and both were the proof rather than
the data, which is recorded here because a proof that has never failed has
probably never run. Its id check compared every stored id of the game against the
product ids of one set, which is 1,912 rows against 254; it now compares the seven
sampled sets against the committed sample and one set against the provider live.
And its price check searched the importer's *text* for `replace_prices` - a
word the file's own docstring uses to say it is *not* called - and now reads the
module's syntax tree for a call.

The checks this game has rather than a repeat of Pokemon's: every stored id is a
product id the provider publishes today, in both halves above; the stored art is
the provider's own address and names the product it shows, because a relayed URL
in the column would be a row that works in a browser and not on a phone; and the
importer never calls `replace_prices` and leaves no row in `catalog_prices`, which
is what a source that quotes no price should leave behind.

## Undoing it

~~~sql
delete from public.catalog_cards where game = 'gundam';
delete from public.catalog_sets  where game = 'gundam';
delete from public.catalog_prices where game = 'gundam';
update public.catalog_meta set sets_revision = 0, prices_revision = 0,
  set_count = 0, card_count = 0, sets_updated_at = null,
  last_import_ok = false, last_import_note = null, source = null
 where game = 'gundam';
~~~

Then take `gundam` out of `sharedCatalogueGames` in
`lib/data/catalog/shared_catalogue.dart`, and put `CardGame.gundam` back on
`TcgcsvCatalog.gundam()` in `lib/providers.dart`. Both factories are still in
the tree - the tcgcsv one because the four remaining games share it and because it
is what makes this move reversible - so the rollback is one line and no release.

**The one thing that does not reverse cleanly is an id.** tcgcsv names a Gundam
product `<groupId>-<productId>`, this source names it `GD01-001`, and no field on
either side joins the two: gcgapi publishes no TCGplayer product id. A device that
has cached Gundam under tcgcsv ids keeps those rows and keeps resolving the
holdings that name them, because the cache is never pruned; a device that has
never held them resolves them against the new catalogue, where they do not exist,
and a holding renders as `--`. That is a decision for a person before the other
four games follow, and it is recorded in this step's report rather than solved
here.
