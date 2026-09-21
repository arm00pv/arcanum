# The Digimon move, as it stands

Status: **the client half.** The app reads Heroicc's card database directly - sets
with their counts and dates, cards, search, and pictures through Arcanum's relay -
and the shared catalogue on Supabase does not hold the game. The server half is not a
technical decision for this game: Heroicc's data is CC BY-NC-SA 4.0, so re-hosting it
is a redistribution with a share-alike obligation attached, and that belongs to the
owner of the app rather than to its code. Everything below the line is the client.

Digimon was one of the games catalogued only through tcgcsv, which republishes
TCGplayer's product catalogue: on the web build those games had no Sets tab until a
set was opened and no search across the game at all. Gundam and Star Wars: Unlimited
have left first; [catalogue-source-survey.md](catalogue-source-survey.md) is the
survey that picked this one, and [catalogue-import-swu.md](catalogue-import-swu.md)
is the closest precedent for the shape of a move.

If this file and the code disagree, the code is what ran.

## Why this source

Heroicc is a community database built from Bandai's own card data, and - measured
2026-09-21 - it answers a browser directly: every route sends a single
`Access-Control-Allow-Origin: *`. Its set list is the best of the four remaining
candidates by a distance: one request, 93 releases, and each one carries a name, a
card count **and a release date**. 87 of the 93 are dated, which makes Digimon the
first game in the app whose Sets tab can sort by Newest truthfully rather than
falling back to the name order the dateless games use.

Its ids separate the printings, which is the property that decides whether a holding
survives a move: `BT5-007` and its four parallels are `_P1` to `_P4`, five ids for
one printed number, and the card states the grouping itself as
`relationships.alternate-arts`. 3,331 of the game's 7,618 cards carry such a suffix.

## What the live data forced

Measured over the whole game: 93 releases, 7,685 entries, 7,541 distinct card ids,
7,618 cards in the bulk file, 3,331 of them parallels.

**The id is the source's own**, `BT8-022` or `BT5-007_P3`. An id derived from the
printed number would collapse a quarter of the game onto half as many rows and merge
a collector's two holdings into one.

**A parallel keeps the number printed on its card** and groups with its base by
oracle id, so a binder slot is the card and not the treatment.

**A card is filed under the release it names, not the set its number names.** 7,541
cards name one release, 142 name two and 77 name none. A pre-release winner is
printed `BT5-007` and filed under `bt-08`; it belongs to bt-08 because that is where
a collector finds it. The 77 that name nothing fall back to their number, and the 142
that name two are given to the first the source lists (large-scale-tournaments before
store-events) with the full list kept in extras.

**The rarity is a code**, not a word: C, U, R, SR, UR, SEC and P, plus six cards and
one whose rarity field reads `デジモン` - a data error in the source. The word
collectors read is the row's rarity; the code goes in extras under 'rarityCode',
which is the key the app already looks for.

## Two things the live checks found that the unit tests could not

**A screen hands a catalogue the folded code and this source addresses a slug.**
Every read path of the app folds a set code to lower case with its separators gone,
so the screen asks for `bt08` while the source's release is `bt-08` - and the two are
not recoverable from each other, because `bt01-03-v1-0` folds to `bt0103v10`. Every
set download in the app was a 404 that way, and the source answers a 404 without CORS
headers, so the browser reported it as a CORS failure rather than as a missing set.
The catalogue now reads the mapping from the set list once per session. The unit tests
could not see it: they hand the adapter the slug, because that is what a release is
addressed by.

**A 404 is null, not an exception.** `fetchCardById` answers null for an id the source
does not hold, which is the interface's own contract - the caller is filling in a row
that already exists, and that row keeps the placeholder it had.

## What the move costs

**No price of any kind.** No price field exists anywhere in a card record, so extras
carries no 'tcgplayerId' and `refreshPrices` answers nothing. Digimon has no prices in
the app after this, as Gundam and Star Wars: Unlimited have none after their moves.

**Every picture comes through Arcanum's relay.** `images.heroi.cc` sends no
`Access-Control-Allow-Origin` at all, so `CardArt._relayed` and the relay's own origin
table both gained a `heroic` entry, and the relay was redeployed: a card's webp now
answers 200 `image/webp`, 59,198 bytes for BT8-022. This is the second game whose data
needs no relay and whose pictures do.

**A set download is one request per card.** A release lists its cards as ids and there
is no route that answers several at once (`/cards/en` as a collection is a 404 and
`?include=cards` is ignored). NEW AWAKENING is 138 cards and the largest promotional
run is 667 entries; the downloads are paced at 90 ms and progress is reported per
card. It is the shape the Pokemon catalogue already has.

**The terms, which are why there is no server half yet.** Heroicc's own documentation
licenses its content CC BY-NC-SA 4.0 and asks that a User-Agent be sent and that
responses be cached. Reading the data into a device's own cache is what that licence
encourages and is what this does; **re-hosting it on Supabase is a redistribution**,
so the share-alike obligation would attach to Arcanum's own catalogue - a decision for
a person. The same page carries a clause that touches the screen: *"you must not
cover, crop, or clip off the copyright or artist name on card images"*. Arcanum draws
the whole card at the game's own ratio, so nothing is cropped, but an owned card
carries a quantity badge over one corner of the art, and whether that counts as
covering is the owner's call. Both are quoted in the catalogue's own comment so the
next reader meets them where the decision is.

## The proofs

* `test/catalog/digimon_catalog_test.dart`, 18 tests against canned JSON:API
  envelopes - the parallel kept apart and grouped with its base, the card filed under
  the release it names, the 77-file fallback to the number, the rarity word and code,
  the type line, the art host left alone, a refused card costing one card and no more,
  the folded code resolved to the slug, and the number search.
* `tool/catalog/probe_digimon_live.dart`, run as
  `flutter test tool/catalog/probe_digimon_live.dart`: the real source. 93 sets, 87
  dated, 7,685 entries, bt-08's 138 cards holding 114 distinct cards between them, a
  parallel printing answering as bt08 / #007 / oracle BT5-007, and a number search for
  BT5-007 answering its five printings and nothing else. Not part of the suite - it
  needs the network, so the suite does not pick it up.
* And a browser, on the deployed build: the Sets tab reading *All 93 · Expansion 37 ·
  Promo 33 · Starter 23*, newest first with real dates, and a set's cards drawn from
  the relay's own copy of the art.

The id check the Gundam report asks for was run before this move, not after: the
account holds one Magic card and six Magic tombstones with no deck lines, so no row
anywhere names a Digimon card.
