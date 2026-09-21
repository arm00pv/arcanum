# The Digimon move, as it stands

Status: **both halves.** The app reads Heroicc's card database directly - sets with
their counts and dates, cards, search, and pictures through Arcanum's relay - and the
shared catalogue on Supabase holds the game as well, imported by
`tool/import_digimon_catalogue.py` every night at 06:15 UTC.

The server half was not a technical decision for this game and it was not taken
quietly. Heroicc's data is CC BY-NC-SA 4.0: re-hosting it is a redistribution with a
share-alike obligation attached, and that belongs to the owner of the app rather than
to its code. It was put to him as a question with the obligations spelled out, and he
answered it: import it. What follows from that answer is written down in
[The licence](#the-licence) below, and in the importer's own docstring, so the next
reader meets the terms where the decision is.

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
that name two are filed under **the first release each card names** - the source's own
answer, and the order the record states it in - with the whole list kept in extras.

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

**The terms**, which were the one question about this game that code could not
answer. Heroicc's own documentation licenses its content CC BY-NC-SA 4.0 and asks that
a User-Agent be sent and that responses be cached. See [The licence](#the-licence).

## The licence

Three obligations come with CC BY-NC-SA 4.0, and each one has an answer that is a
line of code or a line of this file rather than a promise:

* **Attribution.** `lib/core/legal.dart` names Heroicc in the app's own
  acknowledgements, with the licence and the words "non-commercial" beside it, and
  says what Arcanum reads from it. That entry was added with the client half, before
  there was anything to re-host.
* **NonCommercial.** Arcanum is a personal, non-commercial application: it is not
  sold, it carries no advertising, and nothing in it is offered as a data service.
  The catalogue is read by its owner and by the people he invites.
* **ShareAlike.** The copy this importer writes carries the same licence as the
  original - it is the source's data, row for row, and not a derived work with
  conditions of its own. The catalogue is not published as a dataset; what is served
  is what the app itself reads.

And one clause of those terms touches the screen: *"you must not cover, crop, or clip
off the copyright or artist name on card images"*, beside *"you must not add your own
watermarks, stamps, or logos to card images"*. Arcanum draws the whole card at the
game's own ratio - the grid was fixed at measured ratios for exactly that reason - so
nothing is cropped. An owned card does carry a quantity badge over the art, and where
it sits was checked rather than assumed: it is the **top-right** corner
(`lib/widgets/card_thumbnail.dart`), above the copyright and artist line that runs
along the foot of a Digimon card, so it covers neither. The badge is the app's own
control over the picture and not a mark added to the image; the owner was asked about
it directly and kept it where it is.

## The server half

`tool/import_digimon_catalogue.py`, the seventh importer through
`tool/catalog_store.py`. Its shape:

* **One request per card.** A release lists ids and nothing answers several cards at
  once, so a set is one request plus one per card - 7,685 entries over 93 releases.
  Three workers with a pause behind each, which is about the pace the app's own client
  keeps, brings the whole game in at **25 minutes measured** - 1,498 seconds for the
  first full run on 2026-09-21, and 1,542 for the run after the ownership rule changed,
  with every one of the 93 releases answering. The unit is given an hour and finishes
  in half of it.
* **A set is written whole or not at all.** `import_set` writes a set's rows as that
  set's rows, so a walk that quietly lost three cards of a hundred would prune three
  rows a collector may hold. One card that cannot be read fails its whole release, and
  the report says which. The client can afford to skip a card - it is filling a local
  cache - and the importer cannot.
* **No prices.** `replace_prices` is never called, no price row is written for the
  game, and extras carries no `tcgplayerId` - a key the app reads as the join key for
  a price series, where a value would be a number it looked up and never found.
* **A card is filed under the first release its own record names**, whichever walk
  found it, and each walk writes the cards that belong to it. A release lists every
  card it carries and a card belongs to one release, so the two lists are not the
  same: the premium and binder runs list parallels that are also listed by the
  expansions and promotions they came from. The catalogue's own rule is that a card
  is stored under the set it belongs to, and this is what that rule means for a
  source that files a card twice - see the parity bullet below for what the walk
  rule produced instead.
* **The art is stored as the source writes it.** `https://images.heroi.cc/...`, never
  the relay's address: the relay rewrite belongs to the client, on a web build only,
  and a row that already named the relay would be a row a phone could not read.

`arcanum-digimon-import.timer` runs it nightly at 06:15 UTC, after Star Wars:
Unlimited's 05:45 and before the freshness watcher's 06:30 read - the window in
`tool/check_catalog_freshness.py` is the hour by which it should have finished, and
the two move together.

## The proofs

* `test/catalog/digimon_catalog_test.dart`, 19 tests against canned JSON:API
  envelopes - the parallel kept apart and grouped with its base, the card filed under
  the release it names, a card a second release reprints filed under the release it
  names first rather than the deck the walk was reading, the 77-card fallback to the
  number, the rarity word and code, the type line, the art host left alone, a refused
  card costing one card and no more, the folded code resolved to the slug, and the
  number search answering every printing that carries the number.
* `tool/catalog/probe_digimon_live.dart`, run as
  `flutter test tool/catalog/probe_digimon_live.dart`: the real source. 93 sets, 87
  dated, 7,685 entries, bt-08's 138 cards holding 114 distinct cards between them, a
  parallel printing answering as bt08 / #007 / oracle BT5-007, and a number search for
  BT5-007 answering its five printings and nothing else. Not part of the suite - it
  needs the network, so the suite does not pick it up.
* And a browser, on the deployed build: the Sets tab reading *All 93 · Expansion 37 ·
  Promo 33 · Starter 23*, newest first with real dates, and a set's cards drawn from
  the relay's own copy of the art.

For the server half, three things rather than one:

* `tool/catalog/make_digimon_sample.py` cut `tool/catalog/digimon_sample.json.gz`:
  the source's whole set list and five releases walked end to end - other-promos, p,
  st-01, bt-05 and bt-08, in the source's own listing order - 553 cards, 1,746 KiB raw
  and 167 KiB gzipped. It holds both directions of the cross-filing (bt-08 lists
  BT5-007_P3, whose number belongs to bt-05; bt-05 lists BT2-028_P1), 106 parallels,
  the 58 cards the source files under two releases, and two captured searches - a
  collector number and a name.
* **The parity test, both halves.** `test/catalog/catalog_id_parity_test.dart` drives
  the real client over that sample - 553 cards walked set by set and then reached a
  second time by their ids alone - and writes the rows both languages are held to;
  `tool/catalog/test_id_parity.py` derives the same rows through the importer's own
  functions. Every column of a card row and of a set row is compared: 553 card rows and
  93 set rows, all matching.

  It found the rule that decides which release a card two releases list belongs to,
  and the way it found it is worth stating. **P-058 is listed by both `p` and
  `bt-08`**, and the first version of this move let the *walk* decide: the row was
  written by the walk that found it, so the release walked last owned the card, and
  the by-id path - which can only name the first release the card's own record lists
  - derived a different row for the same card. The test failed on exactly that one
  card of 553, which is what it is for.

  The answer is the card's own record: **a card is filed under the first release it
  names**, and a walk that finds it elsewhere does not move it. Three things follow,
  and all three are asserted now. The two paths derive the same row for all 553
  sampled cards, with no exceptions. The rule is independent of the order the source
  lists its releases in, which the walk rule was not - reorder the set list and cards
  would have changed sets. And a release ends up holding the cards that belong to it
  rather than the count of the entries it lists, which is not a cosmetic difference:
  under the walk rule, **Premium Bandai's own set held 29 entries and no rows at all**,
  because every card it carries is also carried by a later release, and the app draws
  a set's page from those rows. The live proof caught that one; the sample could not,
  because it does not cut Premium Bandai.
  **And it found a bug in the shared write path, which is the other reason this
  narrative is here.** `catalog_store.import_set` skips a set whose card checksum it
  has already written - the rule that makes an unchanged night cost one comparison.
  But a checksum describes the set's *own* card list, and the rows a set owns can
  move: when this move gave a card to the release it names, importing that release
  took the row away from the release that had it, and the release left behind kept
  the checksum it had written. The next run compared that checksum, skipped the set,
  and the moved rows were deleted by the release that no longer owned them -
  **108 of the game's 7,541 cards were then stored nowhere**, 29 of them Premium
  Bandai's, which is the set that had first shown the problem. The skip now compares
  the ids the table actually holds for the set with the ids about to be written, one
  small read per set, and the class of bug is closed for every importer rather than
  for this one. Nothing but a live run could have found it: the sample, the parity
  test and the unit tests all agreed, and the catalogue was quietly missing cards.

* `tool/catalog/prove_digimon_import.py` is the proof against the live catalogue: the
  counts against the source's own set list, the set codes and types the importer
  derives, the counts each release states against the rows it holds, every row of the
  sample against the row the database serves, the parallel rule, the art addresses,
  the fallback to a printed number for the card no release lists, the absence of
  prices, the retirement and rerun rules, and the read-only posture. It is the same
  instrument as the one Star Wars: Unlimited got, and it ran **20 passed, 0 failed, 0
  skipped** on 2026-09-21 against the live catalogue. What it measured, in its own
  words:

  > 93 sets, the source lists the same 93, none retired, every one carrying a count of
  > its own, and 82 of the codes needed more than a case change (bt-05 stored as
  > bt05): 7541 cards

  > all 93 stored releases: ... the 93 release(s) read from the source's own release
  > envelopes, read now hold exactly the ids they list and own, 7541 row(s) between
  > them; the list counts 7685 card entries upstream where the catalogue holds 7541
  > distinct ids in 7541 rows (4287 distinct oracle ids); 3 release(s) own none of
  > what they list and hold no rows, which is right: deckboxsetbeelzemon lists 6
  > entries and owns none of them: premiumbandai x6; pb17 lists 19 ...;
  > premiumbinderset lists 4 ...

  > all 553 of the sample's cards match the rows the importer derives in every one of
  > the 34 columns beside the id, with set_code and set_name among them - a card is
  > filed under the release its own record names, and the sample holds every record -
  > and its 93 set rows match in all 17 columns of a set row

  > all 3254 stored parallels keep their own id, take their base card's oracle id and
  > share its collector number

  > the second run rewrote no set: all 93 keep their checksum, cards_revision and
  > catalogued_at ...; sets_revision stayed 1

  > decks 0, collection_entries 7, exactly as before the run

The id check the Gundam report asks for was run before this move, not after: the
account holds one Magic card and six Magic tombstones with no deck lines, so no row
anywhere names a Digimon card.
