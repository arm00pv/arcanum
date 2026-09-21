# The Star Wars: Unlimited move, as it stands

Status: **the app reads the publisher's own card database; the shared catalogue on
Supabase does not hold the game yet.** That is the two halves of a move, and this
file records the first one - its source, its measurements and its costs - with the
second one stated at the end as the next step. When the importer runs, its numbers
go in beside these.

The game was one of the five catalogued only through tcgcsv, which republishes
TCGplayer's product catalogue: on the web build those five had no Sets tab until a
set was opened and no search across the game at all. Gundam was the first to leave,
and [catalogue-import-gundam.md](catalogue-import-gundam.md) is what that cost; the
four that remain are surveyed in [catalogue-source-survey.md](catalogue-source-survey.md),
which is what picked this one.

If this file and the code disagree, the code is what ran.

## Why this source

Fantasy Flight publishes the game's English card database itself, and - measured
2026-09-21, with a real `Origin` sent - it answers a browser directly:

~~~
GET /api/card-list?locale=en&pagination[pageSize]=250
    200, 3,451,707 bytes, Access-Control-Allow-Origin: <the origin sent>
GET https://cdn.starwarsunlimited.com/SWH_01_229_Cell_Block_Guard_*.png
    200, 64,390 bytes, 300x418, Access-Control-Allow-Origin: *
~~~

**It is the only source of the four that needs no relay of ours**, for the data or
for the art, which is why it was worth doing first: every other candidate is
refused by the browser on one of the two - `api.swu-db.com` sends no
`Access-Control-Allow-Origin` on any GET (its `OPTIONS` preflight does, which is a
trap rather than a fix), and every art host found for One Piece, Digimon and
Fusion World refuses, including Bandai's own.

The filter grammar it answers is the rest of the reason: name, subtitle and rules
text in one `$or` query ("luke" answers 65 records, "shield token" 417), a
collector number inside a set (`filters[cardNumber][$eq]=5` with
`filters[expansion][code][$eq]=SOR` answers two records), a batch of ids in one
read (`filters[cardUid][$in][0..n]`), and a set's own codes with
`filters[expansion][code][$eq]`.

## What the live data forced

All of it measured over the whole game: 9,979 records, 135 MB, 27 sets, 3,022 base
printings, 9,729 distinct `cardUid` in the 9,729 records the walk completed.

**`cardUid` is the id, and neither of the two fields that look like one is.**
`cardId` is null on most records and names a *related* card where it is set (61
distinct values over 250 records); `validationId` repeats (228 over 250). `cardUid`
is unique across the game and is what the catalogue stores, verbatim.

**A treatment's own card number counts something other than the card.** Hyperspace
Luke carries `cardNumber` 1 where Luke carries 5, and hyperspace IG-88 carries 278
where IG-88 carries 12. Every treatment record points at its base with `variantOf`,
which embeds the base's own attributes, so a variant takes the base's card number -
and its base's id as the row's oracle id, which is what groups the treatments of one
card together. Over Spark of Rebellion that is 987 rows and **252 distinct numbers**,
which is the size printed on the cards.

**A leader is printed landscape and every tile in the app is portrait.** A leader's
`artFront` is 418x300 with the deployed unit on `artBack` at 300x418, and a unit's
own art is already portrait. So a leader is drawn from the portrait face of the same
card: the same character, nothing cropped, and the game's own ratio (488/680, which
the app already had for this game) intact.

**Tokens are listed beside the cards and are not cards.** `Token Upgrade`,
`Token Unit`, `Credit Token` and `Force Token` are 70 records that no collector
holds and that nothing can be done with; left in, a search for "shield" answers
with the Shield token. They are dropped, and Spark of Rebellion's 991 records become
987 cards and 252 base printings - exactly the set size.

**The set list carries no card count, and there is no set endpoint that does.**
`/api/card-expansions` answers 27 sets in 7 KB with their code, name and a CMS
ordering value; `/api/expansions` and `/api/sets` both 404. So the counts are 27
one-record reads of the card list, whose pagination envelope carries the total:
about 10 KB each, against the 135 MB it would cost to fold them out of the walk.
What is counted is base printings with the tokens excluded - 252 for Spark of
Rebellion, which is the number a player knows.

## What the move costs

**No price of any kind.** No key matching `/price/i` appears anywhere in a
250-record page, and there is no TCGplayer product id to join a price series to, so
`extras` deliberately carries no `tcgplayerId` and `refreshPrices` answers nothing.
Star Wars: Unlimited has no prices anywhere in the app after this, exactly as Gundam
has none after its own move.

**No release date.** The set records carry the CMS publish date, which is months
before the street date - Spark of Rebellion is published 2023-11-28 and released
2024-03-08 - and a date the app sorts its shelf by is worse invented than absent.
Sets therefore come back in name order, which is Gundam's position too.

**An undocumented, unversioned internal API.** The paths were read out of the
site's own requests rather than out of documentation, and it may change or start
requiring a token without notice.

## The client, and how it is proven

`lib/data/catalog/swu_catalog.dart` is the whole of it: the set list, a set's
cards, one card, a batch of ids, three-field search, and the collector-number
lookup (which the other four provider clients cannot do at all - their numbers are
answered from the local cache). `TcgcsvCatalog.starWarsUnlimited` is still in the
tree and nothing wires it, which is what makes the move reversible in one line.

Two proofs, and they are different proofs:

* `test/catalog/swu_catalog_test.dart`, 21 tests against canned envelopes - the id
  verbatim, the treatment's number and grouping, the leader's portrait face, the
  promo filed inside a retail set, the dropped token, the batch-of-ids query, and
  the one case where nothing is asked for at all.
* `tool/catalog/probe_swu_live.dart`, run as `flutter test tool/catalog/probe_swu_live.dart`,
  which walks the real source: 27 sets, 2,982 base printings, Spark of Rebellion at
  987 cards and 252 distinct numbers, Luke at `#005` with its hyperspace printing
  at `#005` too, 65 search hits for "luke", and both records answered by a batch
  read. **Not part of the suite** - it needs the network, so the suite does not
  pick it up.

The id check the Gundam report asks for was run before the move, not after it: the
account holds one Magic card and six Magic tombstones with no deck lines, so no row
anywhere names a Star Wars: Unlimited card and the new ids break nothing.

## The server half, which is not written yet

The shared catalogue gains nothing from this on its own: the browser now reads
cards, sets and search from the publisher directly, which is what the web build
needed, but every device still downloads them for itself. The move is complete when
`tool/import_swu_catalogue.py` writes the game into `catalog_sets` and
`catalog_cards` through `tool/catalog_store.py`, `swu` joins
`sharedCatalogueGames`, and a timer runs it - at which point the same three
consequences Gundam's import had apply: the set list must be folded per set, the
counts come from the same 27 reads, and `replace_prices` is never called because
there is nothing to call it with.

## Undoing it

Put `CardGame.starWarsUnlimited` back on `TcgcsvCatalog.starWarsUnlimited()` in
`lib/providers.dart` and the game is where it was: the tcgcsv client is untouched
and the relay still serves it. Devices that cached the new ids keep those rows -
the cache is never pruned - and a holding naming one renders as `--` on a device
that has the old catalogue, which is the id cost of any move and was measured as
zero for this one.
