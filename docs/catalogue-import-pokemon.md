# The Pokemon import, as it ran

Status: applied to the live project (`wqycllzbwbhqiqlmbwcu`) on 2026-09-21 by a
run of `tool/poll_pokemon_prices.py --catalog-only` from `zapp.sytes.net`.
Migration step 5, the Pokemon half of it. [catalogue-server-side.md](catalogue-server-side.md)
section 3 is the specification; this file records what was built, what the live
data forced, and how to undo it.

If this file and the code disagree, the code is what ran.

## What is in the database now

Read back after the final run:

~~~
pokemon sets       = 220
pokemon cards      = 23736
pokemon retired    = 0
lorcana sets       = 24      (untouched by this step)
lorcana cards      = 3208
catalog_prices     = 0

game      sets_revision  set_count  card_count  last_import_ok  source
pokemon   2              220        23736       t               tcgdex
lorcana   1              24         3208        t               lorcast
~~~

`catalog_cards` is 38 MB for the two games' 26,944 rows together.

## Four things the live data forced

**Fifteen set ids are not lower case, and that is not cosmetic.** TCGdex
publishes `A1, A1a, A2, A2a, A2b, A3, A3a, A3b, A4, A4a, B1, B1a, B2, B2a, P-A`.
`PokemonCatalog` stores the provider's own spelling in `TcgSet.code`, but every
read path in the app folds a code to lower case before comparing it -
`CatalogRepository.cardsInSet`, `cachedCardsInSet`, `isCatalogued`,
`askedForCards`, `CatalogDao.cardByNumber`. A code stored verbatim is therefore
a set the client can never mark catalogued: it would show as never downloaded,
for ever, and the cards would be fetched again on every visit. The importer
folds to lower case in `set_document`, the cards follow it for the foreign key,
and the upstream list handed to `retire_sets` is folded too - the provider's
spelling would otherwise retire all fifteen. This is a deliberate divergence
from the Dart set row for those fifteen, and it is asserted rather than assumed:
the committed sample holds none of them, the test says so, and a re-cut that
adds one fails.

**Four sets are stored with no cards, and that is what the provider says.** The
first proof run failed on "4 set(s) stored with no cards at all", which was
Lorcana's rule applied where it does not hold. Asked directly, TCGdex returns
HTTP 200 with `"cards": []` for `jumbo`, `rc`, `sp` and `wp` while still
publishing a count for each - 160, 25, 10 and 7. `PokemonCatalog` learns a set's
cards from that response and nowhere else, so the client stores nothing for them
too, and an empty set on the server is the same answer rather than a fault. The
check now asks the provider about each stored-empty set by name and fails if the
provider lists cards for it - a half-imported set still fails, and a provider
that cannot be reached is a skip with a reason rather than a pass.

**One set was lost to a transient 503, and the re-run is what proves the
checksum skip.** The first sweep wrote 219 sets and 23,405 cards and reported
`1 set(s) failed` - `B1`, "Mega Rising" from Pokemon TCG Pocket, whose card
fetch answered HTTP 503 four times across four seconds of backoff. The importer
did the right thing: it recorded the set, carried on, and left
`catalog_meta.last_import_ok` false so the failure was a fact rather than an
empty Sets tab. The second run wrote 220 sets and 23,736 cards with the note
*"220 sets upstream, 220 written, 219 unchanged, 23736 cards, 0 set(s)
failed"* - **219 unchanged** is the checksum skip doing its job, and
`sets_revision` moved 1 to 2, which is the signal the client will invalidate on
once design section 6 is built.

**The series segment in an art URL is load bearing, and the client's fallback
for it is wrong.** TCGdex addresses art as
`assets.tcgdex.net/en/<serie>/<set>/<number>/low.webp`. Measured across ten sets
from ten different series: **the form with the series returns 200 ten times out
of ten, and the form without it returns 404 ten times out of ten.** A card's own
detail payload normally carries its `image` base URL, series included, and the
Dart uses that; `PokemonCatalog._images` is only reached when the payload has
none, and its `serie == null` branch builds `en/<set>/<number>`, which cannot
ever be right. It is reachable in practice - `bwp-BW04` has no `image` field at
all - and it affects a card resolved by id, which is the path
`resolveMissingCards` takes. On the web it is masked, because the server's rows
already carry the correct URL.

**Fixed by omitting the image rather than looking the series up.** With no series
there is no address that could load, so `PokemonCatalog._images` now answers
nothing at all and the app draws its card-back placeholder instead of spending a
request on a URL known to be broken; `tool/poll_pokemon_prices.image_uris`
mirrors the rule, and `test_id_parity.py` asserts it over the committed rows so
that both languages agreeing on the broken form would be a failure rather than an
agreement. The lookup from the local sets table was the other candidate and was
rejected: it threads a database into a provider client, whose job is to be a
network adapter, and it would not have rescued the cards that reach this branch -
`bwp-BW04` and `bwp-BW05` are reached by id, carry no `image`, and TCGdex
serves them no art under either spelling. `en/bwp/BW04/low.webp` and
`en/bw/bwp/BW04/low.webp` are both 404, while `en/bw/bwp/BW01/low.webp` from the
same set is 200, so a series would have bought those two a URL that is still
broken. The id vectors moved for exactly those two rows, in their three image
columns, and both halves of the parity test were run against the regenerated
file.

## What it costs

**A full sweep is 717 seconds**, and an all-unchanged night costs the same,
because a set's checksum can only be computed from cards that have been fetched -
the saving is database writes, not network. Section 6 of the design says a night
should cost "one comparison", which is true of the write and not of the fetch,
and this is the first measurement that says so.

## The lock had to stop being one lock

`tool/catalog_store.py`'s `single_flight` takes the lock with `LOCK_EX |
LOCK_NB`, so a second importer is **refused rather than made to wait** - and the
refusal happens before the sweep runs. Both pollers defaulted to the same
`/tmp/arcanum-catalog.lock`, which was harmless while one importer used it and
stops being harmless the moment Pokemon's unit carries `--catalog`: a 717-second
sweep fired anywhere inside Pokemon's twenty-minute window from 04:20 can still
be holding the lock when Lorcana's starts at 04:40, and Lorcana would then lose
**the day's prices as well as its catalogue**. A price series is built one sample
a day and cannot be backfilled, so that is the expensive half of the loss.

Each game now takes its own lock, `/tmp/arcanum-catalog-<game>.lock`. That is
safe rather than merely convenient: every statement the store generates is
scoped to a game - `read_sets(game)`, `count_rows(game)`, `retire_sets(game,
...)`, the card delete, and the `catalog_meta` update - so two importers of
different games write disjoint rows and have nothing to keep apart. The rule the
design actually states is that two runs *of one importer* cannot interleave.

## The proof

`tool/catalog/prove_pokemon_import.py`, 17 checks, run against the live database:

~~~
17 passed, 0 failed, 0 skipped
~~~

The three that are this game's own rather than a repeat of Lorcana's are: the
rows are compared against the importer's own mapping rather than a constant, over
all 34 columns of a card row with nothing carved out; the tombstone rule is
exercised by calling the importer's `retire_sets` for real with a set missing
from the upstream list and then handing the list over whole; and
`stored_codes_are_the_folded_form_retirement_compares` asserts the fifteen
folded ids, so the rule above cannot quietly stop being applied.

Its first run failed twice and both failures were in the proof rather than the
data - the empty-set rule and the by-id art URL above. That is recorded here
because a proof that has never failed has probably never run.

## Undoing it

~~~sql
delete from public.catalog_cards where game = 'pokemon';
delete from public.catalog_sets  where game = 'pokemon';
delete from public.catalog_prices where game = 'pokemon';
update public.catalog_meta set sets_revision = 0, prices_revision = 0,
  set_count = 0, card_count = 0, sets_updated_at = null,
  last_import_ok = false, last_import_note = null, source = null
 where game = 'pokemon';
~~~

Then take `pokemon` out of `sharedCatalogueGames` in
`lib/data/catalog/shared_catalogue.dart`, which is the only client-side line that
knows the server holds it. The provider path was never removed, so a browser goes
back to asking TCGdex without a release. Removing it from the unit is
`--catalog` off `arcanum-pokemon-poll.service`; removing it from the schedule
entirely is `systemctl disable --now arcanum-pokemon-poll.timer`.
