# The decks, on the account

Status: design. Nothing here is written, nothing has been applied to the live
project (`wqycllzbwbhqiqlmbwcu`), and the local schema is still at v15. Written
against branch `web/M0-spike` as the next step of the account tables, after
[collection-sync-tombstones.md](collection-sync-tombstones.md) and
[collection-realtime.md](collection-realtime.md). It follows their habit: the
hole, the decision and its reasons, what it costs, what is still lost, and what is left to
somebody else to decide.

## The hole

The account is the collection. It is not a deck.

| Fact | Where it is written down |
| --- | --- |
| `public.decks` has exactly five columns: `id`, `user_id`, `game`, `name`, `created_at` | `docs/account-backup.md:74`, the dump header the backup script read out of `information_schema.columns` (`tool/account/backup_accounts.py:167`, `:308`) |
| It holds zero rows | the same header, `docs/account-backup.md:76`: `"rows": {"collection_entries": 7, "decks": 0}` |
| `id` is `generated always as identity` | `docs/account-backup.md:202-204`, where restoring a dump is recorded as needing `overriding system value` |
| There is no server table for a deck's contents | the account backup named the account tables and there were two: `tool/account/backup_accounts.py`, `TABLES = ("collection_entries", "decks")` as it stood when this was written. **Amended 2026-09-21:** `public.deck_cards` was created by this design's migration and joined the dump, which had been backing up decks without their contents - see `docs/account-backup.md` |
| The app has two local tables, `decks` and `deck_cards` | `lib/data/db/app_database.dart:413-438`, the `_deckSql` list |
| A line of a deck is keyed by `(deck_id, card_id, board)` with `quantity`, `sort` and `category` | `lib/data/db/app_database.dart:427-435` |

So a deck built on the phone never appears in a browser, a deck built in a
browser never appears on the phone, and the contents of either exist in one
device's SQLite and nowhere else. `public.decks` is a table that records that a
deck was named, for a client that never wrote to it: `docs/catalogue-schema.md:381-390`
records that the two account tables were read and never written by anything in
this repository, and their policy - one `FOR ALL ... USING (auth.uid() = user_id)`
with the same `WITH CHECK` - was already there.

Everything below is built on what the collection already has: the two tables on
either side of the wire, the row-by-row merge in `AccountCollection.accountWins`
(`lib/data/sync/account_collection.dart:103-118`), the unique index the push
upserts against (`:20-21`), the `deleted_at` tombstone, the pull-then-push order
(`lib/data/sync/collection_sync.dart:198-214`) and the per-game shape every
query and every announce is already scoped by. Nothing in it is new machinery.

## The decision in one paragraph

A deck's identity becomes a uuid the **client** generates, carried in a new
`public.decks.sync_id` column, because the account's `id` cannot be supplied by a
client at all. A deck's contents become rows in a new `public.deck_cards` table
shaped like `collection_entries` - keyed by `(user_id, deck_sync_id, card_id,
board)`, with a `deleted_at` tombstone of its own - rather than a `jsonb` payload
on the deck row, because a payload can only be resolved as a whole and a whole-
payload rule silently discards one device's afternoon. The conflict rule is the
collection's rule, the later edit wins and a tie goes to the account, applied
**per field** on the deck row and **per line** on its contents, so that two
devices editing one deck offline both keep what they did. Deleting a deck is a
timestamp on the deck row and touches none of its lines. The local schema goes
to v16 to carry the clocks, the ids and the marks, and the sync is built inside
the `kIsWeb` branch beside the collection's, exactly where the watcher and the
listener already are (`lib/main.dart:119-164`), so a phone keeps its decks to
itself and never needs an account to have them.

## 1. What a deck is, on the server

A deck is two things and the app already says so: `Deck` is "a deck as stored:
its identity, not its contents" (`lib/domain/decks/deck.dart:34-74`), and
`DeckContents` is the deck with the lines and the money (`:112-154`). The server
gets the same split, in two tables.

### 1.1 Two tables

~~~sql
-- Illustrative. The real migration is tool/account/0003_deck_sync.sql.
alter table public.decks
  add column sync_id    uuid        not null,
  add column format_id  text        not null default '',
  add column notes      text,
  add column updated_at timestamptz not null default now(),
  add column deleted_at timestamptz,
  add column name_at    timestamptz,
  add column format_at  timestamptz,
  add column notes_at   timestamptz;

alter table public.decks add constraint decks_user_sync unique (user_id, sync_id);
~~~

The five columns that are there today stay exactly as they are. `format_id` and
`notes` are the rest of what a deck is locally and the account cannot hold yet:
`DeckDao.createDeck` writes `format_id` and `notes` (`lib/data/db/deck_dao.dart:65-80`)
and `Deck.formatId` is what the checker judges the deck against
(`lib/domain/decks/deck.dart:53-54`, `:70`). A deck pushed to a server that had
no `format_id` would come back as "Unknown format" (`:73`), which is the same
class of loss as a deck arriving with no cards in it.

~~~sql
-- Illustrative.
create table public.deck_cards (
  user_id      uuid    not null default auth.uid(),
  game         text    not null,
  deck_sync_id uuid    not null,
  card_id      text    not null,
  board        text    not null default 'main',
  quantity     integer not null default 1,
  sort         integer not null default 0,
  category     text    not null default '',
  updated_at   timestamptz not null default now(),
  deleted_at   timestamptz,
  primary key (user_id, deck_sync_id, card_id, board),
  foreign key (user_id, deck_sync_id)
    references public.decks (user_id, sync_id) on delete cascade
);

create index deck_cards_user_game on public.deck_cards (user_id, game);
~~~

Four things about that shape are decisions rather than transcription.

**`user_id` is on the line as well as on the deck.** The policy on every account
table is a plain comparison against a column on that table
(`tool/catalog/prove_catalogue_posture.py:84-89`), and this design keeps it that
way rather than joining to `decks` to find out whose line this is. It is also
what makes the contents streamable: the collection's realtime subscription
filters by `user_id=eq.<account>` (`lib/data/sync/account_changes.dart:81-85`),
and a table with no `user_id` cannot be filtered that way at all.

**`game` is copied onto the line, and cannot drift.** `DeckDao.updateDeck` can
change a deck's name, format and notes and has no path that changes its `game`
(`lib/data/db/deck_dao.dart:82-109`), so a line's game is fixed when the line is
created. Copying an immutable field is not denormalisation that can go wrong; it
is what makes one pull per game possible ("fetch every line of this game")
instead of a pull per deck, and what lets an arriving realtime row be announced
to the right game without a join.

**The primary key is the conflict target.** `(user_id, deck_sync_id, card_id,
board)` is the same shape as the collection's unique index
`(user_id, game, card_id, finish, condition, language, binder)`
(`docs/collection-sync-tombstones.md:55-57`) and exists for the same reason: it
is what makes a push an upsert, so a push is safe to repeat after a connection
drops (`lib/data/sync/account_table.dart:12-19`). `sort` and `category` are on
the row and deliberately not in the key: two devices' `MAX(sort) + 1`
(`lib/data/db/deck_dao.dart:180-186`) can hand the same line two different sort
numbers, and the answer is that the later edit's number wins - a cosmetic
disagreement, not two rows.

**No `created_at` on a line.** `deck_cards` locally has no such column
(`lib/data/db/app_database.dart:427-435`), the rule is that a server row is a
local row (`docs/catalogue-server-side.md` §1), and nothing asks when a card
joined a deck. Adding one would be a column the merge writes and the app drops.

**One thing about `user_id` could not be determined from this repository.**
Whether `public.decks.user_id` carries the same `default auth.uid()` that the
collection's does (`account_collection.dart:23-27`) is not recorded anywhere
here: the account backup reads column *names* out of `information_schema.columns`
and not defaults (`tool/account/backup_accounts.py:167`, `:308`), and nothing
else reads that table at all. It is the first thing step 0 must look at
(§7), and there are two answers, both cheap: if the default is there, the
client omits the owner exactly as the collection's push does; if it is not, the
column needs `alter column user_id set default auth.uid()`, or the client has to
send the owner it already knows from its session - which the policy's
`WITH CHECK (auth.uid() = user_id)` still prevents it from lying about.

### 1.2 Why rows, and not a `jsonb` payload on the deck

The alternative is one `cards jsonb` column on `public.decks`, holding the whole
list, replaced wholesale on every push. It is genuinely attractive, and both of
its advantages are real:

| | Rows (chosen) | `jsonb` payload |
| --- | --- | --- |
| Conflict granularity | per line: two devices adding different cards both keep them | per deck: the whole list is the unit, so the later push replaces every card the earlier one added |
| Idempotent push | yes, through the primary key | yes, through the deck row's key - the payload is one row |
| Atomicity | a deck is several rows written in one request; a failed request writes none of them, but the deck's row and its lines are two statements | one statement, so a deck cannot be half-written |
| Round trips | one upsert of an array, exactly as the collection's push already is (`collection_sync.dart:71-78`) | one upsert of one row |
| Local shape | the pull writes `deck_cards` directly; every screen, price join and analysis keeps working untouched | a parse path that exists nowhere else in the app, because nothing else stores a deck's contents as a document |
| Cost of a big deck | ~100 rows of ~140 bytes as an estimate - the arithmetic in this paragraph, not a measurement | one row of a few kilobytes |

**The deciding argument is the conflict-granularity row.** A deck editing session
is not one edit: a collector adds four Chieftains, removes two War Marshals and
moves a Sol Ring, and a second device does the same on the same evening. With a
payload, the second push replaces the first device's list with its own and
*nothing about that is visible afterwards* - the work is not in the account, not
in either device's database except the one that did it, and no screen can tell
the collector that something was dropped. A rule that silently loses somebody's
edits was ruled out before this document was written, and a payload cannot give
any other rule without moving the same merge into the client and leaving the
server unable to compare anything: two devices pushing inside the same window
would still overwrite each other's merged result, because the unit of conflict
is the whole list.

What would change my mind:

- **Measured deck sizes that make per-line rows expensive.** They are not: a
  Commander deck is capped at 100 cards by its format
  (`lib/domain/decks/deck_format.dart:154-171`), and 100 rows in one upsert is
  smaller than one good collection push.
- **A second server-side writer**, one that has to build a deck without being
  the client - a share link, an importer, a companion endpoint. A document is
  the right shape for "here is a deck", and if one of those arrives before the
  contents table does, the payload wins on simplicity and the merge problem has
  to be re-answered.
- **A deck that must travel as one opaque file**, for the same reason.

What is rejected on the way past: rows *plus* a `jsonb` snapshot on the deck row
for cheap list rendering. Two sources of truth for one fact is the complaint
`docs/catalogue-server-side.md` §7 makes about two ways to fill the same table,
and the counts a deck list shows are one grouped join already
(`lib/data/db/deck_dao.dart:24-42`).

### 1.3 The format rules stay in Dart, and that is a decision

`DeckFormat` is data plus one predicate: `minCards`, `maxCards`, `maxCopies`,
`singleton`, `sideboardSize`, and `unlimited`, a `bool Function(TcgCard)` for
what may be held in any number (`lib/domain/decks/deck_format.dart:11-82`,
`:70-72`). None of it goes to the server.

The account stores `format_id` as an opaque string and never validates it. That
is deliberate, and it is the opposite of the catalogue's decision to mirror
folding rules on both sides (`docs/catalogue-server-side.md` §2.3). The reasons:

- `DeckFormats.byId` already answers null for a format this build does not have,
  and `Deck.formatLabel` already says "Unknown format" rather than crashing
  (`deck.dart:70-73`). A format added, renamed or removed in a later release
  therefore needs no migration on either side.
- `unlimited` is a predicate over a `TcgCard` - Magic's basic lands by name or
  type line, Pokémon's basic Energy by a name and type-line test
  (`deck_format.dart:124-150`). It cannot be a number and it cannot be a SQL
  expression over catalogue rows without inventing one, and every rule this
  document declines to duplicate is a rule that cannot drift.
- The rules are checked where the catalogue is: the checker needs `TcgCard`
  type lines and colour identity, which are on the device.

The consequence is honest and worth stating: the account will hold decks that
are not legal in their format, including decks that became illegal while they
sat there. It already does - the phone stores them - and nothing in the design
turns the account into a validator.

## 2. Identity, and the trap in it

### 2.1 `GENERATED ALWAYS AS IDENTITY`

`public.decks.id` is `generated always as identity` (`docs/account-backup.md:202-204`,
where the restore recipe needs `overriding system value` to put a row back with
its own id). A client cannot supply a value for such a column: Postgres refuses
the statement with SQLSTATE 428C9 rather than ignoring the value. That was given
as a measured premise for this work and is not re-measured here; what the
repository records is the identity itself and the escape hatch, and the escape
hatch is not available to a client holding only a publishable key.

That is fatal for "push my local deck id", in two ways at once. The obvious one
is that the insert fails. The less obvious one is worse: `CollectionSync`
upserts against a conflict target (`lib/data/sync/collection_sync.dart:71-78`,
`lib/data/sync/account_collection.dart:20-21`), and a client cannot name a
conflict target it cannot supply a value for. Losing the upsert means losing the
property the whole sync is built on - a push that is safe to repeat after a
dropped connection (`lib/data/sync/account_table.dart:12-19`) - and no amount of
retry logic gets it back.

### 2.2 The three options

**A client-generated uuid in a new column (chosen).** `public.decks` gains
`sync_id`, unique with `user_id`, and that pair is the conflict target. The
client knows its own decks' ids before the account has ever seen them, so an
offline browser can create a deck, edit it, and push it in one idempotent upsert
whenever the network returns.

~~~sql
-- Illustrative. The client's identity is not the account's.
create unique index decks_user_sync on public.decks (user_id, sync_id);
~~~

`sync_id` is declared `not null` with **no default**, and that is a decision.
With `default gen_random_uuid()`, a payload that forgot the column would insert
a fresh deck with a fresh id on every push - one duplicate per attempt, silently,
which is the worst failure this design can have. Without a default, the same
mistake is a not-null violation and a refused request. The collection's
`deleted_at` has the opposite rule for the opposite reason: there, a missing key
means "leave what is there" and what is there is a tombstone, so that column is
always sent even when it is null (`account_collection.dart:41-50`, the one place
where sending nothing is not the same as sending null). Both columns are traps
of the same kind, and each is spelled the way that fails loudly.

**A `local_id` column the client owns (rejected).** The client's own integer
plus its account. It works for one device and breaks for the second one, and it
breaks in the place you would least like it to: two browsers each number their
decks 1, 2, 3, so the account's row for `local_id = 1` is a *different deck* for
each of them, and the merge would fold deck 1 from one browser into deck 1 of
the other. It is a uuid with extra steps, and the extra step is the failure.

**Renumbering on pull (rejected).** Let the account own identity and have each
device adopt the account's id after its first successful push. This survives
until the first dropped response: the push becomes "insert and tell me the id",
there is no conflict target to hit on a retry, and the retry is a second deck.
Reconciliation then has to match the account's decks to the device's by
something else, and the only available something else is name and game, which
is the merge this design refuses to do (§2.3). It also cannot express a deck
created offline at all, which is the case the whole feature exists for.

The cost of the uuid is one column, one index, and one place in the app that
mints one. The repository has no uuid generator and no `uuid` dependency in
`pubspec.yaml` (`:9-39`); `uuid 4.6.0` is present in the lock file as a
transitive dependency (`pubspec.lock:1325-1332`), so making it direct adds no
new code to the graph, and the alternative - twenty lines over `Random.secure()`
in one file with a test for the shape - is the other defensible answer. Either
way it is one function, called from the migration and from `createDeck`, and
never a second implementation of the same rule (the mistake `catalogue-server-side.md`
§2.3 is written to prevent).

### 2.3 The same deck on two devices before either has synced

Two browsers, both offline, both create a deck called "Mono-Red". Each mints its
own uuid at the moment of creation, so they are two decks, and after both sync
the account holds two rows and each browser shows two decks with the same name.
Nothing is lost and nothing is merged.

That is the intended answer, and the alternative is not a merge but a guess.
Matching decks by `(game, name)` would join two decks a collector deliberately
kept apart - a Standard Mono-Red and a Commander Mono-Red are not the same deck -
and it would do it irreversibly, because the merge cannot be undone once the
contents are one list. The one case where a name match would be right - the same
deck created twice by accident, or restored from an archive that predates the
`sync_id` column (§6) - is not worth the case where it is wrong.

What the collector sees is a duplicate *name*, not a duplicate deck, and the fix
is in the collector's hands: delete one, and the deletion travels (§4). Whether
the deck list should say "another device has a deck with this name" is a product
question, not a design one (§8).

### 2.4 Two identities, one wire

| Identity | Owner | Where it lives |
| --- | --- | --- |
| `decks.id` (INTEGER PRIMARY KEY) | the device | `lib/data/db/app_database.dart:416`; what `deckProvider.family<int>` and every screen addresses a deck by (`lib/providers.dart:902-912`) |
| `decks.sync_id` (uuid) | the client | the new column; the only thing that crosses the wire |
| `public.decks.id` (bigint identity) | the account | never crosses down |

That is the collection's arrangement read the other way round. There, the local
table has an integer id that means nothing to the account and the merge matches
on the natural key instead (`collection_sync.dart:225-239`), and the account's
uuid is never read by the client at all: `AccountCollection.entry` builds a
holding without an `id` (`account_collection.dart:61-82`). Here the client's
identity is the one that must travel, because the client is the only party that
can name a deck before the account knows it exists.

## 3. The conflict rule

### 3.1 The rule, in the collection's words

The collection's rule is: the later edit wins, and a tie goes to the account
(`account_collection.dart:103-118`). Its order of operations - pull, then push,
always (`collection_sync.dart:198-214`) - is what makes that rule hold in both
directions, and it exists for a reason this work inherits intact: an upsert does
not compare timestamps, so a device that pushes a stale row clears whatever
newer thing is there (`docs/collection-sync-tombstones.md:69-100`).

After the sign-in's reconcile, the watcher carries up only what has moved since
the last successful push (`collection_sync.dart:94-109`) and, when a push has
failed, reconciles like a sign-in rather than writing over an edit it never read
(`lib/features/auth/collection_watcher.dart:78-87`, `:131-147`).

Decks get that rule and that order, with one extension, and the extension is
forced by a line of existing code rather than chosen for elegance.

### 3.2 The deck's own row is resolved per field, not per row

`DeckDao._touch` stamps `decks.updated_at` every time a card is added, set,
moved or removed (`lib/data/db/deck_dao.dart:272-279`, called from `:187`,
`:210`, `:245`, `:255`). Under a row-level rule, an afternoon of adding cards on
one device is an edit to the same row that holds the deck's name, and its
payload carries whatever name that device still had. Two devices, one renaming
and the other adding cards, therefore ends with the rename reverted on both -
and this is not an exotic race: *any* content edit touches the same row.

So the deck row carries a stamp per field it can independently be edited by:

~~~dart
// Illustrative. name_at, format_at and notes_at are the deck's own clocks.
// A field with no stamp has never been edited since v16 and loses to any
// stamped value. Two stamped values: later wins, a tie goes to the account.
static bool fieldWins(DateTime? local, DateTime? remote) =>
    remote != null && (local == null || !remote.isBefore(local));
~~~

`notes` on a deck and `category` on a line are the two other editable-looking
fields nothing can set today - `DeckRepository.setNotes` is defined and called
from nowhere (`lib/data/repositories/deck_repository.dart:59-63`), and
`DeckEntry.category` is only ever its default (`lib/domain/decks/deck.dart:83`,
`:92-94`, copied through `deck_dao.dart:149`). They travel because they are part
of the row and because a later release will give them a screen; the clocks cost
nothing while nothing writes them.

This is the one place the design *extends* the collection's rule instead of
reusing it, and it should be read as such. `updateDeck` already writes only the
fields it was passed, and says why: "a rename cannot quietly clear the notes the
way a whole-row update would" (`deck_dao.dart:82-85`). The merge now agrees with
the DAO that this row holds several independent edits, rather than disagreeing
with it. The alternative - one `updated_at` for the row, name and format and
notes as one object - is the collection's rule verbatim, is two columns cheaper,
and is defensible right up to the moment somebody renames a deck while their
other browser is adding cards to it.

`decks.updated_at` stays exactly what it is: the stamp that orders the deck list
(`app_database.dart:425`, `deck_dao.dart:37`) and the thing the watcher asks
about. It is not a conflict clock, and no merge decision reads it.

### 3.3 The contents are resolved per line, and a removed line is a tombstone

`deck_cards` gains `updated_at` and `deleted_at`, and every removal in `DeckDao`
becomes a mark:

| Path today | What it does after v16 |
| --- | --- |
| `removeCard` (`deck_dao.dart:234-246`) | stamps the line, leaves its quantity and sort as they were |
| `setQuantity(deck, card, board, 0)` (`:191-211`) | goes through `removeCard`, as it already does |
| `clearDeck` (`:249-256`) | marks every line of the deck |
| `moveCard` (`:214-231`) | marks the line on the old board and adds one on the new, exactly as it does now |
| `addCard` on a marked line (`:171-188`) | revives the row in place, with the new count |

That last row is the collection's rule and it is not a merge: a collector who
removed the four Chieftains and then added one owns one, so the quantity is the
new count and not a sum (`docs/collection-sync-tombstones.md:63-67`). The unique
key is what makes it a revival rather than a second row, on both sides.

Two consequences to be plain about, because both will be seen by a collector:

- **Adding copies on two devices offline does not add up.** Both devices hold
  the same line, each adds two to it, the later edit wins: the deck ends with
  the later device's number, three, not five. That is the collection's rule -
  a quantity is a value, not a delta - and a delta would be worse: a replayed
  push would double-count, and no delta can be reconciled with a removal.
- **A card moved on two devices can land on two boards.** `moveCard` is a
  removal plus an add, and the local key allows one card on several boards
  (`app_database.dart:434`). If one device moves a card from main to side while
  another moves it from main to commander, the merge agrees about main (both
  removed it) and keeps both destinations. The collector sees the card once in
  the sideboard and once in the commander slot, a quantity disagreement inside
  one deck rather than a lost edit or a second deck, and fixing it is one tap.

### 3.4 Two devices, one deck, offline: what the collector sees

The laptop, offline in a hotel, renames a deck to "Krenko (v2)" and adds four
Goblin Chieftains. The other browser, offline at home, adds two Skirk
Prospectors and removes one Mogg War Marshal. Both come back online.

Whichever order they sync in, this is what the collector ends up with: **one
deck**, named "Krenko (v2)", holding four Chieftains, two Prospectors, and no
Mogg War Marshal. Nothing was asked, nothing was chosen, and nothing was lost -
the deck row's name is resolved by `name_at`, and the three line edits are
resolved line by line, so none of them competes with another.

The property worth writing down as a property, because it is what a test should
assert: **edits to different fields of a deck and to different lines of it all
survive, regardless of the order the devices sync in.** Edits to the *same*
field or the same line resolve to the later stamp, also regardless of order.
The account's tie-break is what makes the second half true: without "a tie goes
to the account", two devices could keep two different answers to the same
moment.

### 3.5 What is still lost, and what is not

Stated plainly, because the collection's file is honest about its own residue:

- **The same field, twice, offline.** Two renames of one deck: the later wins
  and the earlier is gone. Same line, same field: the later quantity wins. This
  is the collection's cost and it is the price of a rule that never has to show
  the collector a dialog.
- **Clock skew.** Devices stamp their own edits, so a device whose clock is
  behind loses comparisons it made with a device whose clock is ahead. The
  tombstone file already recorded that this reverses what the old push order did
  (`collection-sync-tombstones.md:92-96`); nothing here makes it worse or better.
- **The account can be behind for a while.** Two pushes that cross inside the
  same window can leave the account holding the older of two rows. No device
  loses its copy - the merge prefers the newer stamp, so the device that owns
  the newer edit keeps it - but the account's copy is repaired only when that
  device pushes again, and `pushAhead` does not re-offer a row it believes it has
  already carried up (`collection_sync.dart:94-109`). A full `sync` repairs it;
  a browser that is then wiped without another edit does not. This is inherited
  from the collection, not introduced here, and it is on the list of things to
  make a person decide rather than assume (§8).

## 4. Deletion

### 4.1 A deck is deleted by stamping it

`DeckDao.deleteDeck` deletes the row and lets the cascade take the lines
(`deck_dao.dart:111-114`, `app_database.dart:410-412`). On the account that is
the collection's bug exactly: a push that cannot see a removal is a push that
undoes it, and the deck comes back on every device on the next pull. So `decks`
gets `deleted_at`, a nullable timestamptz, and every read filters on it. The
local column and the local mark are the other half.

**A deck's deletion does not touch its lines.** This is a decision, and it is
the one that makes a revival whole. Deleting a deck and cascading its lines away
would mean that a deck revived by a later edit - the case §4.2 describes -
returns *empty*, having silently dropped ninety-nine cards, and the collector
who adds one card to a deck they deleted on another device gets a one-card deck
with the same name. The collection's own rule is the same rule: a removal stamps
the row and changes nothing else (`docs/collection-sync-tombstones.md:116-118`).

Every read has to learn that, and there are six in `DeckDao`: `decks`
(`:24-42`), `deck` (`:45-62`, whose own doc comment already says "or null when it
has been deleted"), `decksContaining` (`:117-128`), `entries` (`:133-152`, which
must not return the lines of a deleted deck), `cardIdsInDecks` (`:155-165`) and
`decksHolding` (`:259-269`). The last three are the ones that are easy to miss: a
card screen that says "in 1 deck" about a deck the collector deleted is the same
class of lie as a card that will not stay deleted.

### 4.2 Can deleting a deck be undone?

Two questions, and they have different answers.

**By the rule, yes.** A deletion is an edit made at a moment, so it beats an
older edit and loses to a newer one - which is exactly what adding a card to the
deck is. If a device that has not heard about the deletion edits the deck, the
deck comes back on every device, with that edit in it. The alternative -
deletion always wins - has no such resurrection, and pays for it by dropping the
other device's work without a word, which is the failure this document is not
allowed to ship.

**By the app, no.** There is no undo today: `confirmDeleteDeck` deletes and the
deck is gone (`lib/features/decks/deck_form.dart:46-75`). The tombstone makes
one possible - a "recently deleted" list is a query away, and reviving a deck
would be a newer edit on its row - but nothing in this document builds one, and
the collector is not told they have one.

What must change is the sentence. The dialog says "The deck and its list are
removed" (`deck_form.dart:55-58`), and after this work that is true of this
device and only until somebody else edits it. Either the wording grows a second
sentence, or the product decides that deletion should be final - which is a
decision with a cost (§8).

### 4.3 Nothing purges them, for the tombstone file's reason

A purged tombstone is a removal that can be undone, and the device that undoes
it is the one that has been in a drawer. `collection-sync-tombstones.md:264-279`
refuses a retention window because nothing in the app knows how long a device
can stay away, and the argument is stronger here, not weaker: the rows are
smaller, fewer, and a collector's deck list is measured in tens.

## 5. Migration: what version 16 must do

The local schema is at v15 (`app_database.dart:69`), the upgrade switch is a list
of fourteen guarded calls (`:87-102`), and every step in it has a doc comment
saying what the column means rather than what it does. v16 is the first one to
add columns to a table the collector has been using since v7, so it is the first
that has to think about what is already in those rows.

~~~dart
/// v16: decks and their lines can travel between devices.
///
/// A deck gets an identity the client owns, because the account's own id is
/// generated always as identity and a client cannot supply one. It gets a
/// mark instead of a delete, for the reason v15 marked a stack: the account
/// holds the row too, and a sync that cannot see a removal undoes it. And it
/// gets a stamp per field it can be edited by independently, because _touch
/// stamps the deck's updated_at on every change to its contents, and one
/// row-level clock would let an afternoon of adding cards revert a rename made
/// on another device.
static Future<void> addDeckSyncColumns(DatabaseExecutor d) async { ... }
~~~

| What it adds | Why, and what the existing rows mean |
| --- | --- |
| `decks.sync_id TEXT` | the client's identity; backfilled with one uuid per existing row, walked in Dart so there is one uuid rule in the app rather than a second one in SQL |
| `CREATE UNIQUE INDEX idx_decks_sync ON decks(sync_id)` | the local twin of the account's `unique (user_id, sync_id)`; SQLite cannot add a unique constraint in place, so it is an index, exactly as `idx_entries_unique` is (`app_database.dart:276-278`) |
| `decks.name_at`, `format_at`, `notes_at INTEGER` | nullable, and null means "never edited since v16" - which loses to any stamped edit, so an existing deck is merged correctly the first time it meets the account |
| `decks.deleted_at INTEGER` | null for every existing row, because every existing row is present. `addCollectionTombstones` said it in as many words: there is no backfill to get wrong (`:452-468`) |
| `deck_cards.updated_at INTEGER NOT NULL DEFAULT 0` | backfilled from the owning deck's `updated_at`, one correlated `UPDATE`, the shape `addAlertLabels` already uses (`:477-494`). A line's clock is the last moment the deck changed, which is honest for a line that has never been edited on its own |
| `deck_cards.deleted_at INTEGER` | null everywhere, as above |

Then, in the same version and for the same reason: `deleteDeck`, `removeCard`,
`setQuantity(0)` and `clearDeck` stop deleting rows and start stamping them;
`addCard`, `setQuantity`, `moveCard`, `removeCard` and `_touch` stamp
`updated_at` on the row they touched; `updateDeck` stamps the one field clock it
was given; `createDeck` mints a `sync_id` and stamps `name_at` and `format_at`
as edits it is making now; and the six reads in §4.1 gain their filter. The
migration changes no behaviour by itself.

What it deliberately does not do: change `deck_cards.deck_id` or the local
integer id (`deckProvider.family<int>` and every screen address a deck by it,
`lib/providers.dart:902-912`); invent a `user_id` column locally (the local
tables have none anywhere, and the browser holds one account at a time - §6);
or delete anything.

The test is the v15 test's test (`test/db/migration_test.dart:592-690`): build a
v15 database by hand with a deck and its lines in it, run the upgrade, and
assert that the deck survived with an id, that its lines took the deck's stamp,
that nothing was marked deleted, and that a database created from scratch has
the same shape - which is the `_deckSql`-shared-by-both rule
(`app_database.dart:408-413`) extended to the new columns.

## 6. What breaks, what gets harder, what is given up

**Decks larger than a round trip.** A Commander deck is at most 100 lines
(`deck_format.dart:160-162`); a casual deck is capped only by the collector
(`minCards: 0`), and nothing stops four hundred. The push is one upsert of an
array - the collection already pushes a whole game in one request
(`collection_sync.dart:63-78`, `account_table.dart:38-43`) - so 100 rows is
nothing new. The **pull** is the part that changes shape: Supabase caps a
PostgREST response at 1,000 rows (`docs/catalogue-server-side.md` §4), so a
collector with a few dozen decks in one game cannot be pulled in one response.
The answer is the one the catalogue already uses for prices: page with a total
order - `order=deck_sync_id,board,card_id` - and merge every page, which is safe
because the merge is idempotent. By the arithmetic in this paragraph and not by
measurement, forty decks of ninety lines is 3,600 rows for one game, four pages,
and nine games is a sign-in's worth of requests.

**A deck whose cards resolve to nothing.** A pulled line names a printing the
device may never have downloaded, and `DeckEntry.card` is nullable for exactly
this reason: "Null for a deck imported before the printing was ever downloaded,
which the UI shows as unknown rather than dropping" (`deck.dart:96-99`). The
existing answer is already wired: `reconcileAccount` runs a second pass after
the holdings pass and calls `catalog.resolveMissingCards` for what this device
owns (`lib/features/auth/account_reconcile.dart:70-82`). Decks join that pass,
using `DeckDao.cardIdsInDecks` - a query that exists today and answers precisely
"every card id any deck of this game holds" (`deck_dao.dart:154-165`). On the web
that is the shared catalogue's batch read; on a device with no shared catalogue
it is one provider request per card, which is why the pass is worth having
before the sync ships rather than after.

**The phone.** It has no account and must not need one (`main.dart:115-118`).
Nothing in this design gives it one: the sync, the watcher and the listener are
constructed only inside the `kIsWeb` branch (`main.dart:119-164`), so the phone
gets no `DeckSync`, opens no socket, starts no timer, and behaves exactly as it
does today. It does run v16, and v16 is the only part of this work that reaches
it - a schema change, a delete that becomes a mark, and a deck that disappears
from its list while its rows stay. That is the price of one shared schema, and
it is a small one: columns that exist only on web do not exist in this
codebase's migration machinery. **Nothing on the phone ever gets an account's
decks, and the phone's decks never leave it.** That is unchanged and worth
saying, because the temptation - "the phone could sign in too" - is a different
feature than this one.

**Restore, and archives that predate the column.** `decks` and `deck_cards` are
both in the backup's user tables (`lib/data/backup/backup_archive.dart:42-52`)
and a restore replaces them wholesale
(`lib/data/backup/backup_service.dart:444-472`). After v16 an archive carries
`sync_id`, so restoring onto a second device lands rows that are *the same
decks* and merge correctly - which is a property and not an accident: identity
lives in the archive because the archive copies whole rows. An archive written
before v16 carries no ids, so a restored deck cannot be matched to the account's
copy of it and arrives as a new deck (§2.3). The mitigation, matching on
`(game, name, created_at)`, is a heuristic that can join two decks a collector
wanted apart, and it is refused here for the same reason name-matching is
refused. One more restore note: a restore writes the archive's own stamps, so it
is not an edit and cannot revive a deck the account deleted afterwards; and a
restored deck the account has never seen will not travel up until something
edits it or the next sign-in reconciles, because `ahead()` asks "has anything
moved since I last pushed" (`collection_sync.dart:121-133`) and restored rows
are old. That second half is inherited by the collection and should be fixed
rather than copied - `CollectionWatcher` already has the notion of being unsure
(`collection_watcher.dart:78-87`), and a restore is a thing that ought to make
it unsure.

**Realtime is a second table, and the seam is per-table.**
`SupabaseAccountChanges` has one table name as a constant and one channel per
table (`lib/data/sync/account_changes.dart:50`, `:70`), and the change that
arrives is `payload.newRecord` (`:86`) - for a line removal that is a row with
`deleted_at` stamped on it, so exactly as with the collection nothing needs
`replica identity full` (`docs/collection-realtime.md`, "What was built"). The
work is: the table name becomes a constructor argument, `public.decks` and
`public.deck_cards` join `supabase_realtime` in a migration of their own, and a
second listener merges arrivals through the same `DeckSync.mergeRow` and tells
the screens once - `deckRevisionProvider` exists for this and every deck
provider already watches it (`lib/providers.dart:878-899`). Two open browsers
agreeing without a reload is the last step in §7 rather than the first, because
it is the only part of this work that is optional: without it a browser carries
work up and brings news down on the next pull, which is a downgrade to older
behaviour and not a break.

**A pull and a push are not symmetric in cost, and the deck list is a join.**
`DeckDao.decks` computes `card_count`, `side_count` and `unique_cards` from a
grouped join over `deck_cards` (`deck_dao.dart:24-42`). That means a deck list
is only correct for a device that has pulled that game's *lines*, not just its
decks - so a lazy "pull the contents when the deck is opened" design would show
every deck as empty until it was opened. The pull is per game for that reason,
and it is the same decision the counts already force.

**One account per device is assumed, and decks inherit the assumption.** The
local `collection_entries` and `decks` tables have no user column, and the sync
offers everything local to whoever is signed in. A browser that signs out and
signs in as a second account therefore hands the first account's rows to the
second - today, for the collection; decks join that on the day they sync. It is
not a thing this document fixes, and it is on the list for a person (§8).

**Sealed, lots, sales and wants have the same problem and are not in scope.**
They are in a backup and nowhere else: `sealed_products`
(`app_database.dart:503-520`), `card_lots` (`:524-536`), `card_sales`
(`:538-557`) and `wanted_cards` (`:386-394`). Two of the four are shaped like
things this document already knows how to move - `wanted_cards` is
`(game, card_id, note, created_at)`, which is a collection row without the parts
that make it a holding, and sealed product is a per-game list of holdings whose
identity wants to be `(game, set_code, product_id)`. The one that is genuinely
harder is the pair around cost basis: `card_lots.entry_id` and
`card_sales.entry_id` point at a *local* `collection_entries.id`
(`app_database.dart:529`, `:551`), and the account's entry has no such id - its
identity is the natural key (`account_collection.dart:20-21`). A lot therefore
has to learn to reference the holding by `(game, card_id, finish, condition,
language, binder)` before it can travel, which is a change to a local table
rather than a copy of this one. They are named here so that the next reader does
not assume decks were the whole problem.

**What is given up.** The one-statement delete with a cascade behind it, and
with it the property that a browser's storage shrinks when a collector tidies
up: tombstoned decks and lines stay, forever, on every device (§4.3). The
last-writer-wins simplicity of one clock per row: the deck row now carries a
clock per editable field and the merge reads three of them. And a little
honesty in the deletion dialog, which can no longer promise that a deleted deck
is gone.

## 7. Migration order

Small steps, each of which ships something, none of which breaks the phone, and
each reversible on its own. The order is forced in two places: the local columns
must exist before anything writes them, and a push must never exist without a
pull (`collection-sync-tombstones.md:82-100`).

| Step | What ships | Why here |
| --- | --- | --- |
| **0. The server shape** | `tool/account/0003_deck_sync.sql` and its reversal: the eight columns on `public.decks`, `public.deck_cards` with its primary key, index, policy and grants, the `(user_id, sync_id)` unique constraint, and `tool/account/prove_deck_sync.py` in the shape of `prove_collection_tombstones.py`. Empty. The proof's first job is the one reading this repository cannot settle from here: whether `public.decks.user_id` carries `default auth.uid()` | Nothing else can be verified until the shape is fixed, and the collection's push depends on that default rather than on a client-supplied owner (`account_collection.dart:23-27`). Delivers no user value; keep it small |
| **1. The local schema, v16** | The migration and DAO changes of §5, the six filtered reads, and `test/db/migration_test.dart`'s v15-style test. Web and phone | The half everything else stands on, and the half that touches the phone - so it goes first, alone, where it is easy to see and easy to reverse |
| **2. Decks travel** | `lib/data/sync/account_deck.dart` (the payload and the merge, mirroring `AccountCollection`), `lib/data/sync/deck_table.dart` (the `AccountTable` twin), `lib/data/sync/deck_sync.dart` (pull, then push, then the `pushAhead`/`ahead` pair), a `DeckWatcher` beside `CollectionWatcher`, the second pass in `reconcileAccount` extended to `cardIdsInDecks`, all built inside the `kIsWeb` branch of `main.dart` | The first step a collector can see: sign in on a second browser and the decks are there, with their cards. Pull ships in the same step as push, because a push without a pull is the bug the tombstones file was written about |
| **3. Deletion tells the truth** | The wording of `confirmDeleteDeck`, and whatever §8 decides about a recently-deleted list | Until this ships, the app promises something the merge does not keep. Deliberately after step 2, because it is the step that needs a decision rather than code |
| **4. Two browsers agree while both are open** | `tool/account/0004_realtime_decks.sql` (both tables into `supabase_realtime`, guarded so a table already streamed is a no-op), the table name as a parameter of `SupabaseAccountChanges`, and a deck listener announcing through `deckRevisionProvider` | The last step, and the only optional one: without it a browser carries work up and brings news down on the next pull, which is a downgrade to older behaviour rather than a break |

Rollback, step by step: 0 is a reversal script, 1 is a schema version a later
release can simply stop using, 2 reverts by not constructing the sync, 3 is
words, and 4 is `alter publication ... drop table` with nothing lost but the
announcements. No step removes the provider path, the phone's behaviour, or a
single row.

## 8. Open questions that need a person

1. **Is deleting a deck final, or revivable?** The rule says revivable, the
   dialog says removed, and a collector who deletes a deck on the laptop and
   then adds a card to it from a device that never heard would see it return.
   The three options are: keep revival and change the wording; add a "recently
   deleted" list so the revival is something the collector can see and use; or
   make deletion final with a mark that always wins, which is the only option
   that costs an offline device its edits silently. This gates step 3, and it is
   a product decision, not a merge rule.
2. **Is the account ever allowed to be behind, and who repairs it?** §3.5's
   crossing-pushes window is inherited from the collection and is real for both
   tables. Deciding to leave it means deciding that a device which is wiped
   without another edit loses that edit; deciding to fix it is a change to
   `CollectionSync` as much as to `DeckSync`.
3. **Does a second account on one browser inherit the first one's decks?** The
   local tables have no user column and the sync offers everything local to
   whoever signs in. This is true of the collection today and decks will make it
   more visible, because a deck list is short enough to read. Partition, wipe on
   a different sign-in, or leave it and document it.
4. **Should the deck list say when another device has a deck with the same
   name?** It cannot be merged (§2.3) and it is worth one line of UI to say so.
   The decision is whether a name collision is worth telling anybody about.
5. **Is a deck something a collector can give to somebody else?** The identity
   work makes a deck addressable (`sync_id`) and the policy is owner-only, so
   sharing is a read policy and a copy. Deck lists are the most portable thing
   anyone builds here, and the answer changes nothing in §1 unless it is yes - in
   which case §1.2's answer deserves a second look.
6. **`uuid`, or twenty lines over `Random.secure()`?** `uuid 4.6.0` is already
   in the dependency graph transitively (`pubspec.lock:1325-1332`); the other
   answer is one function and one test. A person should choose once, because the
   same question comes back for the sealed and wants tables.
7. **Do we ever show a deck's last-changed time?** The account has `updated_at`
   and the list already orders by it, but nothing shows it, and "changed 3 days
   ago on another device" is a different product than a list of decks.
8. **Does the account keep a deleted deck's lines for ever?** §4.1 says yes, and
   the argument is that a revival has to be whole. A person should confirm that
   a deck deleted years ago keeps its hundred rows in Postgres for ever, or say
   what the retention window is and who justifies it - the tombstone file
   refused to guess one (`collection-sync-tombstones.md:264-279`).

## Files

Existing, read while writing this:

- `lib/domain/decks/deck.dart`, `lib/domain/decks/deck_format.dart` - what a
  deck is and what a format means.
- `lib/data/db/deck_dao.dart`, `lib/data/repositories/deck_repository.dart` -
  every write this design has to stop deleting and start stamping.
- `lib/data/db/app_database.dart` - the `_deckSql` pair (`:413-438`) and the
  fourteen migrations v16 follows.
- `lib/data/sync/account_collection.dart`, `account_table.dart`,
  `collection_sync.dart`, `account_changes.dart` - the shapes being mirrored.
- `lib/features/auth/account_reconcile.dart`, `collection_watcher.dart`,
  `lib/main.dart` - where a second sync is built and told about.
- `lib/providers.dart` (`:863-944`) - the deck providers and the announcement
  seam.
- `docs/account-backup.md` - the measured shape of both account tables.
- `docs/collection-sync-tombstones.md`, `docs/collection-realtime.md`,
  `docs/catalogue-server-side.md` - the decisions this one builds on.

Proposed, none of which exists yet:

- `tool/account/0003_deck_sync.sql` and `0003_deck_sync_down.sql` - the server
  tables, indexes, policy and grants.
- `tool/account/0004_realtime_decks.sql` and its reversal - the publication.
- `tool/account/prove_deck_sync.py`, `prove_deck_realtime.py` - in the shapes of
  the collection's two proofs.
- `lib/data/sync/account_deck.dart`, `lib/data/sync/deck_table.dart`,
  `lib/data/sync/deck_sync.dart`, `lib/features/auth/deck_watcher.dart`,
  `lib/features/auth/deck_listener.dart`.
