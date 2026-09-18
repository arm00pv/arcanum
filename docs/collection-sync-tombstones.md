# Removing a card, and making the removal travel

Status: applied to the live project (`wqycllzbwbhqiqlmbwcu`) on 2026-09-18 by
`tool/account/0001_collection_tombstones.sql`, and proved by
`tool/account/prove_collection_tombstones.py`. This file records what was
built, what the live database said about it, and what was deliberately left
undone.

If this file and the SQL disagree, the SQL is what ran.

## The bug

The account is the collection. A device pushes its holdings up and pulls the
account's back down, and it never removed anything - `CollectionSync` said so in
as many words. So a card removed on a phone was still on the account, and the
next pull handed it straight back: delete a card, sync, watch it return. The
same hole ran the other way for two phones: remove a card on one and the other
would keep it and push it up again.

## What was applied

One column, and nothing else.

~~~sql
alter table public.collection_entries
  add column deleted_at timestamptz;
~~~

Null means held. A removed holding is not a second kind of row with a second
lifecycle - it is the same row with a timestamp on it - and that is the whole
design. It travels up through the same upsert and down through the same select
as every other holding, and it is compared by the same
`AccountCollection.accountWins` rule that already decided every other
conflict: the later edit wins. Removing a card is an edit made at a moment, so
it beats an older edit and loses to a newer one - which is exactly what adding
the card back is. Nothing in the sync has to know it is looking at a tombstone.

Null was the only possible value for the rows that already existed, so there was
no backfill to get wrong. The table held one real holding, belonging to a real
person, and it still does: see the proof below.

### No index, on purpose

The sync's fetch has to read the tombstones as well as the living holdings - a
deletion a device cannot see is a deletion that device will undo - so a partial
index on `deleted_at is null` would serve no query this app makes. The reads
that do filter on it are `WHERE user_id = ... AND game = ...`, which
`idx_entries_user_game` already covers. An index is a claim about which queries
matter; this step has no such claim to make.

## The two things that will bite

### A tombstone still occupies its slot

`public.collection_entries` has a unique constraint on
`(user_id, game, card_id, finish, condition, language, binder)`, and a
soft-deleted row is still a row. So adding a card back must **revive** that row -
clear `deleted_at`, bump `updated_at` - and never insert a second one, which
the constraint would refuse anyway. The local SQLite table has the same unique
index and the same rule, and `CollectionDao.addOrMerge` revives in place for
the same reason.

A revival is not a merge. The collector who removed four copies and then added
one owns one, not five, so the quantity is the new count rather than a sum; the
purchase price, the note and the trade flag come from the new stack too, because
what the deleted stack knew is not what this one is. `created_at` stays, since
it is the same row.

### A push has to name `deleted_at`, and has to happen after the pull

Two separate traps, both about the fact that the account's upsert is blind.

**The key must always be present.** PostgREST writes an upsert as an
`insert ... on conflict do update` of the columns the payload names, so a key
left out of the payload means "leave whatever is there". For a card being added
back, what is there is the tombstone - and a payload that omitted
`deleted_at` would leave it, so the card would stay deleted forever.
`AccountCollection.row` therefore always emits the column, null included,
unlike every other absent value in that map. This is the one place where
"sending nothing" is not the same as "sending null".

**The pull has to come first.** An upsert does not compare timestamps. A device
that has been asleep for a week holds a stale copy of a card its owner removed
elsewhere, and pushing that copy would clear the tombstone on the way through -
the deletion would be lost, which is the bug this work exists to fix, arriving
by a different road. `CollectionSync.sync` therefore pulls and merges first, so
the rows it then pushes are already the winner of every comparison and the blind
write puts the right thing there.

This reverses the order the file used to argue for, and it does not weaken what
that order was for. Work done offline is newer than the account's copy of the
same holding, so the merge leaves it exactly where it is and the push that
follows carries it up. What it does change is clock skew: a device whose clock
is behind now loses a comparison it used to win by writing first. That is the
same rule the pull has always applied, applied in both directions instead of
one.

The cost is that a holding pulled from the account is pushed back unchanged. It
is one upsert for the whole game either way, and the row it writes is the row
that is already there.

## Where a removal is recorded, on the device

Every path that takes a stack out of the collection writes the mark, because one
path left behind is the bug again by another door:

| Path | What it does |
| --- | --- |
| `CollectionDao.delete` | marks the row, drops its lots |
| `CollectionDao.setQuantity(0)` | goes through `delete` |
| `CollectionDao.deleteAllForCard` | marks every stack of the printing |
| `CollectionDao.clear` | marks every stack of the game, or of every game |
| `LotsDao.recordSale` selling the last copy | marks the row |
| `LotsDao.undoSale` on a marked row | revives it in place |

A removal stamps the row and changes nothing else - the quantity, the binder and
the note are left as they were. What is gone is gone, and the row's last state
is the honest record of what was removed.

Everything the collector sees filters on `deleted_at IS NULL`: every read in
`CollectionDao`, the two ownership queries in `providers.dart`, and the set
completion count in `CatalogDao.setCompletion`. The two that deliberately do
not are `addOrMerge`, which has to find the dead row in order to revive it, and
the sync, which is the thing that carries the removal.

Backups are left alone. A backup copies whole tables and restores them whole, so
a tombstone travels in an archive the way every other row does, and restoring an
archive taken before a removal restores the collection as it was then. The
merge of two devices' archives is additive and never clears a mark, so it cannot
undo a removal either.

## The proof

### The schema, and the row that was already there

The migration was applied, reversed and applied again, with the table read at
every step. Run on the server as the owner over the session pooler:

~~~
########## 1. BEFORE (as it stood before this migration was written)
row16_md5=be8a05b7b399f7dfc418398b2849df69
n_rows=1
n_cols=15
deleted_at=ABSENT
cons_md5=284bcd1a43d57a11c87fbca9ad33bdc0
pol_md5=f46c5cf8da5eeead8007200ee17bc04b
idx_md5=93cc4a3c404f1628eb1c84805de50006
grant_md5=a77de29eee559c34252bb8df508e30ad
rls=true force=false

########## 2. UP
applied 0001_collection_tombstones.sql
row16_md5=be8a05b7b399f7dfc418398b2849df69
n_rows=1
n_cols=16
deleted_at=timestamp with time zone null=YES
cons_md5=284bcd1a43d57a11c87fbca9ad33bdc0
pol_md5=f46c5cf8da5eeead8007200ee17bc04b
idx_md5=93cc4a3c404f1628eb1c84805de50006
grant_md5=a77de29eee559c34252bb8df508e30ad
rls=true force=false

########## 3. DOWN (the reversal)
applied 0001_collection_tombstones_down.sql
row16_md5=be8a05b7b399f7dfc418398b2849df69
n_rows=1
n_cols=15
deleted_at=ABSENT
...

########## 4. UP again
applied 0001_collection_tombstones.sql
row16_md5=be8a05b7b399f7dfc418398b2849df69
n_rows=1
n_cols=16
deleted_at=timestamp with time zone null=YES
...
~~~

`row16_md5` is a fingerprint of the row's fifteen original columns, in their
original order, taken at all four readings: identical every time. The
constraints, the policy, the grants and the indexes are identical too, so the
only thing that moved between the first reading and the last is that the table
has one more column in it.

It was safe to reverse only because no client had yet written a tombstone. The
reversal drops the deletions with the column - see the note in
`0001_collection_tombstones_down.sql` before running it again.

### What the client will do, against the real table

`tool/account/prove_collection_tombstones.py`. A unique index, a conflict
target and a nullable column cannot be tested anywhere but the database that has
them: SQLite in a unit test has a different constraint and the fake account
table has none. So the script writes one `zz-probe` holding, removes it softly,
adds it back with the client's own conflict target and payload, and checks that
the row that came back is the row that went away - all inside a transaction that
is rolled back, so the collector's real holding is never touched.

~~~
set -a; . /home/zixen/arcanum/supabase.env; set +a
python3 tool/account/prove_collection_tombstones.py
~~~

Last run, 2026-09-18, from `zapp.sytes.net`:

~~~
PASS  sql_nothing_but_the_new_column_changed
        the row, the fifteen columns it had, the constraints, the policy, the
        grants and the indexes are byte-for-byte what they were before the
        migration, which added one column: 15 -> 16
PASS  sql_deleted_at_is_a_nullable_instant
        timestamptz and nullable, so null means present for every row that
        already exists and no backfill can be wrong
PASS  sql_rls_untouched
        row level security still on and still not forced: a soft delete is an
        UPDATE by the owner, which the existing policy already allows
PASS  sql_conflict_target_still_there
        the unique constraint on (user_id,game,card_id,finish,condition,
        language,binder) is what makes a re-add a revive rather than a second
        row, and it is unchanged
PASS  revive_round_trip
        one row: inserted, hidden by deleted_at, then revived in place by the
        same upsert the sync performs - id 67f53fe8..., quantity 3 -> 1,
        deleted_at back to null, and still one row rather than two
PASS  probe_left_nothing_behind
        the zz-probe row was written inside a transaction and rolled back; the
        account holds no row for it and the real holding was never touched

6 passed, 0 failed, 0 skipped
~~~

The real holding, read after all of the above:

~~~
row_md5=be8a05b7b399f7dfc418398b2849df69   (its fifteen original columns)
n_rows=1
n_tombstones=0
row={"id":"7eac3c85-...","game":"mtg","quantity":1,...,"deleted_at":null}
~~~

### What the tests say

Unit tests, on a real in-memory SQLite and a fake account table that resolves a
repeated write through the unique key exactly as the real one does - a fake that
merged more cleverly would hide the failure mode the ordering exists to prevent:

- `test/data/collection_sync_test.dart` - a removal is a tombstone on the
  account rather than an absence; **a card removed on one device stays removed
  on a second device that never heard the edit**; a card removed on one device
  and added again on the other comes back **once**, on the row the account
  already had; a removed card is not offered as owned anywhere.
- `test/collection/tombstones_test.dart` - the local half: the row survives a
  removal and leaves every read, adding the card back revives that row with the
  new stack's quantity and price, clearing a collection marks every stack,
  selling the last copy marks rather than drops and undoing the sale brings the
  stack back visible.
- `test/data/account_collection_test.dart` - `deleted_at` is always in the
  payload and round trips, and a removal is compared like any other edit.
- `test/db/migration_test.dart` - the v15 step marks a v14 database's existing
  holdings as held, leaves the unique index that makes a revival possible, and a
  database created from scratch has the column too.

## Purging: decided against

These rows are not deleted, and nothing purges them.

A purged tombstone is a removal that can be undone. The tombstone is the only
record that a card left, and it is the thing that stops an offline device from
putting it back: purge one and a phone that has been in a drawer for a month
will revive the card on its next sync, on every device, with no way to tell that
it should not have. A retention window would have to be longer than the longest
any device stays away, and nothing in this app knows that number - a collector
can leave a tablet offline for a year.

The cost of keeping them is a row of a few dozen bytes per removed card. It is
not a cost worth trading a deletion for. If a purge is ever wanted, it needs a
retention window that can be justified rather than guessed, and it is a separate
migration with its own proof.

## Reversing it

~~~sh
psql "$SESSION_POOLER_URL" -X -v ON_ERROR_STOP=1 \
  -f tool/account/0001_collection_tombstones_down.sql
~~~

One statement, and read its header first: dropping the column drops every
deletion recorded in it, and every card removed since the app shipped this
change comes back on every device. Before the client shipped it, that was
nothing.

## Files

- `tool/account/0001_collection_tombstones.sql` - what was executed, with the
  reasoning inline.
- `tool/account/0001_collection_tombstones_down.sql` - the reversal.
- `tool/account/prove_collection_tombstones.py` - the proof above.
- Client: `lib/domain/models/collection_entry.dart`,
  `lib/data/db/app_database.dart` (schema v15),
  `lib/data/db/collection_dao.dart`, `lib/data/db/lots_dao.dart`,
  `lib/data/db/catalog_dao.dart`, `lib/data/sync/account_collection.dart`,
  `lib/data/sync/account_table.dart`, `lib/data/sync/collection_sync.dart`,
  `lib/providers.dart`.
