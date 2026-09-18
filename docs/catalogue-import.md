# The Lorcana import, as it ran

Status: applied to the live project (`wqycllzbwbhqiqlmbwcu`) on 2026-09-18 by a
run of `tool/poll_lorcana_prices.py --catalog-only` from `zapp.sytes.net`.
Migration step 1 of [catalogue-server-side.md](catalogue-server-side.md), and
nothing further: Lorcana sets and cards are in Postgres, the id derivation and
the two folding rules are asserted against it, and there is still no RPC and no
client change, because step 1 delivers neither. Section 3 of the design document
is the specification for the importer; this file records what was actually built,
what the live data forced, and how to undo it.

If this file and the code disagree, the code is what ran.

## What is in the database now

Read back from the live project after the final run:

~~~
lorcana sets       = 24
lorcana cards      = 3208
lorcana retired    = 0
all catalog_sets   = 24
all catalog_cards  = 3208
catalog_prices     = 0

game        sets_revision  set_count  card_count  last_import_ok  source
lorcana     1              24         3208        t               lorcast
the other eight games: 0, 0, 0, f, null
~~~

Two numbers in the design document are stale, and it is worth saying so rather
than silently matching them: sections 8 and 9 both describe Lorcana as 23 sets and
3,198 cards. Lorcast publishes **24 sets and 3,208 cards** today. The 24th set is
`PD1`, which post-dates the document; the ten extra cards are spread across it and
the promo runs. Nothing about the design turns on the figures, but a step whose
whole purpose is to measure should report the measurement rather than the estimate.

### What that costs

The design asks this question by name - open question 1, does the catalogue fit the
plan we are willing to pay for - and one game is enough to answer part of it:

~~~
catalog_cards heap    = 2760 kB     0.86 kB per row
catalog_cards indexes = 6768 kB     2.11 kB per row
catalog_cards toast   =   40 kB
avg rules text        =  135 chars
~~~

The indexes are two and a half times the data. That is not an accident of Lorcana
being small: the two GIN trigram indexes section 2.2 adds scale with the *length of
the text*, not with the row count, and every row of rules text contributes a trigram
entry per three characters. Extrapolating those two rates to the ~250,000 rows
section 7 anticipates gives roughly 215 MB of heap and **over 500 MB of index**,
before Magic owner{s} longer rules text is allowed for. That is a materially larger
number than the paragraph in section 7 implies, and it is the index - not the rows -
that decides whether this fits a plan. It is cheaper to know that now than after
Magic is imported.

**Correction, added after `tool/catalog/0002_search_index_expressions.sql`: much
of that 6,768 kB was churn rather than the steady size of the two trigram
indexes.** The 5,693,440 B of it that was the trigram pair was the size those
indexes had grown to under this importer's own rule 1 - every card in a changed
set deleted and reinserted, every night - and a GIN index gives that space back
only at vacuum. Built fresh on the same 3,208 rows, the same two expressions come
to 1,416 kB, and `pg_stat_user_tables` shows 3,208 inserts and 432 deletes on a
table holding 3,208 rows. So the paragraph above is right that these indexes
decide whether the plan fits, and the lever is larger than it looks: how often a
set changes is as much a part of the bill as how long the rules text is. The
measurements are in `catalogue-schema.md`.

## What was built

### `tool/catalog_store.py`

The shared write path the design names in section 3, used by this importer and ready
for the other four. It holds the seven rules and nothing game-specific:

| Rule | How it is kept |
| --- | --- |
| One transaction per set | `_set_transaction` generates one begin/commit script per set, run through `psql -f` with `ON_ERROR_STOP`, so a failure closes the connection and rolls back |
| Checksum first | `canonical_checksum` hashes the card list with sorted keys and no incidental whitespace; a match skips every card write and moves no revision |
| Sets before cards | the set upsert is the first statement inside the same transaction, because `catalog_cards` has a foreign key to it |
| Never delete a set | nothing in the module emits a delete against `catalog_sets`; `retire_sets` is the only writer of `retired_at` |
| Record the outcome | `finish` writes `catalog_meta` on the failure path as well as the happy one |
| Idempotent and single-flight | the write path is upsert-and-replace throughout, and `single_flight` holds an `flock` for the whole run |
| No partial revision bumps | `catalog_meta.sets_revision` moves once, in `finish`, and only when the set list content changed |

Three things in it are not in the design and are argued for in the code: a refusal to
empty a set the provider answers with no cards, a check that no statement ever names
`public.decks` or `public.collection_entries`, and a `--dry-run` that prints the SQL a
run would execute.

### `tool/poll_lorcana_prices.py`, extended

The design{s} own suggestion, and the cheapest possible importer: the sweep already
downloads every Lorcana card in 24 requests to read its prices, so the catalogue is a
second thing done with data already in hand. `--catalog` turns it on;
`--catalog-only` imports and samples nothing. The existing price path is untouched -
it takes no new options and its behaviour with none is unchanged, verified by running
it against a throwaway database after the change: 24 sets, 3,208 cards seen, 5,764
points.

The file now also holds every rule that turns a Lorcast object into a stored row: the
composed display name, the oracle id, the rarity spelling, `collector_sort`, the JSON
in `extras`, the art URL, the set type. Each one names the Dart it mirrors. This is
the second-language problem section 7 warns about, and the answer here is the one the
design proposes: keep each rule in one place per language, and assert the two against
each other over real data.

### The tests

| File | What it asserts |
| --- | --- |
| `tool/catalog/lorcana_sample.json.gz` | 440 real Lorcast card objects and all 24 sets, cut by `make_lorcana_sample.py` with a written-down selection rule |
| `tool/catalog/catalog_id_vectors.json.gz` | the 35 `catalog_cards` columns for each of those cards, derived from the Dart client |
| `test/catalog/catalog_id_parity_test.dart` | runs the real `LorcanaCatalog` over the sample and asserts the committed vectors are still what it derives |
| `tool/catalog/test_id_parity.py` | runs the importer{s} own functions over the same sample and asserts the same vectors |
| `tool/catalog/fold_vectors.json` | 60 code vectors and 246 collector-number vectors, generated from `Codes.fold`, `Codes.separators` and `Codes.foldedSql` |
| `test/catalog/code_fold_vectors_test.dart` | asserts the Dart half of those vectors |
| `tool/catalog/prove_lorcana_import.py` | asserts the live database: counts, ids, generated columns, scoping, idempotency, posture |

### The proof

~~~sh
set -a; . /home/zixen/arcanum/supabase.env; set +a
python3 tool/catalog/prove_lorcana_import.py
~~~

`--skip-rerun` omits the second import; `--no-auth` omits the HTTP checks. The last
run, 2026-09-18, from `zapp.sytes.net`:

~~~
--- SQL, as the owner ---
PASS  counts_match_the_provider
        all 24 of the provider sets stored, none retired, none empty, and every
        set recorded card count matches its rows: 3,208 cards
PASS  every_card_belongs_to_a_stored_set
PASS  imported_rows_equal_the_clients_derivation
        all 440 sampled cards match the Dart-derived vectors in 34 columns each
PASS  generated_columns_match_the_dart_rules
        code_folded is the deployed replace(replace(...lower(code)...)) chain;
        number_bare is ltrim(collector_number, 0)
PASS  postgres_folds_the_vectors_as_the_dart_does
        all 60 code vectors, evaluated by the deployed expression, equal the
        committed folded value
PASS  postgres_bares_the_numbers_as_the_dart_does
        all 246 collector-number vectors match
PASS  generated_columns_refuse_a_write
PASS  a_per_set_delete_leaves_every_other_set_alone
        the statement the importer emits, targeted at set 1, removed its 216 cards,
        left set 10 at 242 cards and left 2,992 of 3,208 rows
PASS  the_scoping_probe_left_no_trace
PASS  the_write_path_cannot_remove_a_set_or_an_account_row
PASS  retirement_is_a_soft_delete_and_reverses
PASS  catalog_meta_records_the_import
        sets_revision 1, 24 sets, 3208 cards, source lorcast, note: 24 sets upstream,
        24 written, 24 unchanged, 3208 cards, 0 set(s) failed
PASS  every_set_carries_a_checksum_and_a_revision
PASS  catalogue_is_still_select_only_for_clients

--- HTTP, as the publishable key ---
PASS  publishable_key_reads_the_catalogue
        24 sets readable; catalog_cards range 0-0/3208

--- the second run ---
PASS  rerun_changes_nothing
        the second run rewrote no set: all 24 keep their checksum, cards_revision and
        catalogued_at, and sets_revision stayed 1

--- nothing left behind ---
PASS  account_tables_are_unchanged
        decks 0, collection_entries 6, exactly as before the run
PASS  no_probe_rows_left_behind

18 passed, 0 failed, 0 skipped
~~~

Four of those checks are worth reading twice, because each is a different kind of
claim and none is implied by the others.

**`imported_rows_equal_the_clients_derivation` is the one that matters.**
`test_id_parity.py` proves the two languages derive the same rows from the same
responses; this proves the rows *in the database* are those rows. An import that
predates a rule change satisfies the first and fails this, which is exactly the case
that would turn a collector holding into `--`.

**`postgres_folds_the_vectors_as_the_dart_does` closes the folding loop.** The
expression it evaluates is read out of `pg_attrdef` rather than retyped, so it cannot
agree with the committed file while disagreeing with the deployed column. The
separate `generated_columns_match_the_dart_rules` check compares that same expression
textually against the string `Codes.foldedSql` builds - so a change to
`Codes.separators` fails both, in two different ways.

**`rerun_changes_nothing` re-runs the importer.** Idempotency is a claim about the
second run, so the second run happens. It compares checksums, revisions and
`catalogued_at` per set rather than counts alone: a run that rewrote every row to the
same values would leave the counts identical and is caught here.

**`the_scoping_probe_left_no_trace` is a safety net with a story behind it.** The
first version of that check copied the real rows into a temporary table and then ran
the importer delete against them - except the emitted statement names
`public.catalog_cards`, so it deleted from the catalogue and tested nothing. It was
rolled back and no data was lost, which is luck rather than design. The check now
retargets the statement at the copy and asserts that both substitutions happened.

## The five things running it changed

Each of these was found by running something, not by reading the design.

**`TcgCard.layout` is empty for Lorcana, and the payload is not.** `LorcanaCatalog`
never sets the field, so the client stores the constructor default; the Lorcast object
says `normal`. An importer that copies the provider stores a row the client would
never have written. The parity test found this on its first run.

**The name is composed with spaces around the dash.** `lorcana_catalog.dart` builds
the name, a space, an en dash, a space, then the version; the first transcription left
the spaces out. It reads correctly on screen either way, and it changes both the
displayed name and the oracle id built from it - so it would have broken reprint
grouping silently. Also caught by the parity test on its first run.

**A card whose rules text says decks defeated the account-table guard.** The first
guard searched the whole statement for the table names, and a Lorcana card mentions
decks, so it refused two entire sets. The import reported two failures and looked like
a guard doing its job. It now strips SQL string literals first, which is where card
text always lives, and the proof asserts that a literal mentioning decks is allowed
while a statement naming the table is refused.

**Ten of Lorcana set codes are upper case, and the catalogue stores lower case.**
Retirement compares the provider list against stored codes, so passing `P1`, `D23` and
`Coconut` as published retired exactly those ten sets. The catalogue looked complete
and was ten sets short; the next run un-retired them. `retire_sets` now documents that
its codes are in stored form.

**`sets_revision` was comparing the set list with itself.** `finish` read the set list
after the import had already written it, so the before and after readings were always
equal and the revision could never have moved. The importer now takes the reading
before it writes anything and hands it to `finish`.

## Reversing it

There is no down migration, because there is nothing structural to undo: step 1 adds
no table, no column, no index and no policy. The catalogue is rows, and reversing it
means removing them.

~~~sql
-- Every card, then every set, then the record of the import.
begin;
delete from public.catalog_cards where game = 'lorcana';
delete from public.catalog_sets  where game = 'lorcana';
update public.catalog_meta set sets_revision = 0, set_count = 0, card_count = 0,
       sets_updated_at = null, last_import_ok = false,
       last_import_note = null, source = null
 where game = 'lorcana';
commit;
~~~

That is safe today and will not stay safe. It hard-deletes card ids, and a collection
row naming one of them renders as `--`; the design own argument for never deleting a
set applies to its cards too. Once the web client is reading this catalogue (step 2),
the reversal becomes `update ... set retired_at = now()` rather than a delete, and
this section will have to say so.

The other half of the reversal is the importer itself: it is a script and a module,
and removing them from the host stops the import. The copy of `poll_lorcana_prices.py`
that was deployed over is kept at
`/home/zixen/arcanum/poll_lorcana_prices.py.bak-before-catalog`.

Note that `/home/zixen/arcanum/tool/` now mirrors `tool/` from this repository, so the
proof and its vectors can be run on the host from the same relative paths. The systemd
unit still runs the flat `/home/zixen/arcanum/poll_lorcana_prices.py`, and **that unit
has not been changed**: the nightly job still samples prices and still does not import
the catalogue. Wiring it up is one argument - add `--catalog` to `ExecStart` in
`arcanum-lorcana-poll.service` - and it is deliberately left to whoever decides the
timing, because the import and the sample now compete for the same 04:40 window and the
import is the slower half.

## Notes for whoever does step 2

**The art URLs are platform-dependent and the column is not.** `CardArt.host` rewrites
a CDN URL through Arcanum relay on a web build, and `LorcanaCatalog._images` calls it
while *parsing* - so a row the provider path writes on web already holds a relayed URL
and the same row on a phone does not. The importer stores the direct CDN URL, which is
the only thing it honestly can, and `CatalogDao._cardToRow` stores `imageUris[...]`
verbatim. So the step 2 adapter must apply `CardArt.host` when it turns a PostgREST row
into the map the mapper reads, or Lorcana art will be CORS-blocked on the web build
only. Section 4.2 says the adapter one job is boolean and jsonb conversion; this is a
second job it has to do.

**The per-set card delete cascades into `catalog_prices`.** The foreign key in section
5 is `on delete cascade`, and rule 1 replaces a set cards by deleting them first. On a
night when a set *has* changed, its price rows go with it and stay gone until that game
price importer runs. The checksum skip means this does not happen on an unchanged night,
which is most nights, but step 6 should decide the order of the two imports rather than
discovering it.

**`card_count` is 0 for every Lorcana set, and that is correct.** The set list publishes
no count, so 0 means the provider does not say, and `card_row_count` is what the import
actually stored. A Sets tab showing 0/0 for a set it has not opened is reading the right
column the wrong way.

**`sets_revision` is 1, and a client that has never synced should still fetch.** The
revision is an invalidation signal, not a presence signal - section 6 says so - and it
has moved exactly once, from nothing to a full Lorcana catalogue.

## What the design gets wrong

Short, and none of it blocks step 2.

**Rule 1 and rule 4 contradict each other at different granularities.** Rule 4 protects
a set from deletion because holdings name card ids and a card id that stops resolving
turns a collection row into `--`. Rule 1 deletes and reinserts every card in a set on
every changed night. A card withdrawn upstream while its set remains is hard-deleted,
and the holding that names it renders as `--` - the exact failure rule 4 exists to
prevent, reached through rule 1. `catalog_cards` has no `retired_at` column to soften
it, and adding one is a schema migration rather than a change to this importer, so it
was left alone and is recorded here. The practical question is whether a card should be
retired when it disappears from a set it used to be in, and it belongs with the rest of
step 2.

**Two set codes are in play and section 3 only mentions one.** Rule 4 needs the provider
list of sets; `catalog_sets.code` holds the lower-case form (section 2.1). A caller that
passes the provider spelling retires every set whose code is not already lower case - ten
of Lorcana twenty-four. The design should say which form the retirement list is in,
because the failure is silent and looks like a complete catalogue.

**The trigram indexes are the expensive part, and section 2.2 sizes them as if they were
not.** Measured above: 6,768 kB of index to 2,760 kB of rows, on the smallest real
catalogue in the design, and the ratio worsens with longer rules text. Section 7 says
roughly a quarter of a million rows and hundreds of megabytes as though the rows were the
cost. If the plan is tight, the lever is the two GIN indexes or `oracle_text` itself, not
the row count. Two corrections to make before acting on that number: the indexes
are on the raw columns now rather than on the lowered expressions, so search uses
them (`catalogue-schema.md`), and most of the 6,768 kB was churn from rule 1
rather than the size a fresh build reaches - 1,416 kB for the same two indexes on
the same rows.

**The design does not say how the importer reaches Postgres, and the answer is narrower
than section 2.4 implies.** Section 2.4 says the credentials are in a file with mode 600
on the host, which is true - but there is no Postgres driver on that host, so the importer
speaks to `psql` exactly as `prove_catalogue_posture.py` does. That is the right call
rather than adding a dependency, and every importer after this one inherits it.

**`tool/catalog_store.py` is inconsistent with step 0 own layout.** The design names it at
`tool/catalog_store.py` and it was put there, while the migration SQL, the proof script and
the vectors live in `tool/catalog/`. Both spellings appear in section 3 and section 8. It is
followed as written rather than quietly tidied; moving it is a rename and a one-line import
in five files.
