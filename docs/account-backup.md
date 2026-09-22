# The account, backed up

Status: built, installed and run against the live project (wqycllzbwbhqiqlmbwcu)
from zapp.sytes.net on 2026-09-21, on branch `web/M0-spike`. The units in
tool/deploy/ are installed and enabled: the timer fires at 07:10 UTC, and the
service was started by hand once, which is where the dumps in the backups
directory and the proof output below come from. "Installing it" below records
exactly what was run and how to check the thing is still happening.

**Amended 2026-09-22: the dump holds three tables, and there is a restore tool
that has been run.** `public.deck_cards` arrived with the deck sync after this
file was written and was not in the dump for a day - every deck's contents,
missing from the only copy of the account that survives a lost project. The
format went to version 2, and `tool/account/restore_accounts.py` turns the recipe
below into a program whose write-back has now been performed against the live
tables, on a probe account, with every other account fingerprinted either side of
it. Both are in this file: the table list under "What is backed up", the tool
and its dry run under "A restore", and the run under "The restore, performed".

If this file and the scripts disagree, the scripts are what ran.

## The hole

The account *is* the collection for the web build. A signed-in browser reads
public.collection_entries and public.decks out of the project's Supabase
Postgres, and the vault, the binders, the analytics and the deck lists are all
computed from what it finds there.

Nothing held a copy of those tables.

- **Supabase's free plan gives no point-in-time recovery.** There is no rewind,
  no snapshot, no "restore to yesterday". A `delete` without a `where`, a bad
  migration or a lost project takes every account's collection with it, and
  there is nothing to go back to.
- **The backups on the host are not the account.** zapp.sytes.net has archived
  the *phone's* database since the companion shipped - one
  arcanum-backup-<stamp>-<device>.json.gz per upload, written by
  tool/sync_server.py and read back by the vault page. Those archives are
  written by a device, out of its own SQLite. They describe the phone, not the
  two tables the web build reads, and no version of the phone's database can be
  turned into the account's rows without guessing.
- **Row level security means nobody can help.** The tables are readable by
  their owner, by the project owner, and by nobody else - which is right, and
  which also means the only thing that can copy them is a connection that
  deliberately bypasses the policies.

So the copy has to be made on purpose, by something holding the owner's
credentials, and it has to be made somewhere the account can be rebuilt from.
That is tool/account/backup_accounts.py.

## What is backed up

Every table of the account, every row, every user, connected as postgres over the
session pooler - the same connection tool/catalog_store.py makes for the catalogue
import, and for the same reason: postgres owns these tables and holds
BYPASSRLS, so a dump can see every account's rows where a policy would show it
exactly one.

| Table | What it holds |
| --- | --- |
| public.collection_entries | one row per stack a collector owns: game, card, finish, condition, language, quantity, what they paid, the binder, the note, the trade flag |
| public.decks | one row per deck: owner, game, name, format, notes, the client's own sync id, and the clocks the merge reads |
| public.deck_cards | one row per line of a deck: which deck, which printing, which board, how many, the sort, the category |

**deck_cards joined on 2026-09-21, and the gap it closed was invisible in the
worst way.** This file dumped two tables until then, from before the deck sync
existed, and nothing failed when the third arrived: the dump was still taken,
still verified, still rotated, and still held every deck's name, format and notes
- with none of its cards in them. A restore made from one of those dumps would
have given every collector their decks back empty. What found it was reading the
schema against the file rather than trusting either: public.deck_cards exists,
holds the lines, and was not in `TABLES`. The dump's format version went to 2 with
it, and the version now *names* the tables it promises, so a reader can say what
an old dump is missing instead of only what it holds:

~~~python
VERSION_TABLES = {1: ("collection_entries", "decks"),
                  2: ("collection_entries", "decks", "deck_cards")}
~~~

A version-1 dump is still readable - it is a real backup of the account as it
stood - and restoring from one is refused in as many words by the tool, because
it cannot put back what it never held.

**The tombstones are in it, and that is the point.** A holding that was removed
is not a deleted row - it is the same row with `deleted_at` stamped on it, and it
has to stay that way. A dump that filtered the deleted rows out would restore a
vault with cards in it that their owner removed, on every device, with no way to
tell that they should not be there. There is no `where deleted_at is null`
anywhere in the backup path, and the proof asserts that a tombstone in the
database is in the dump with the same timestamp.

## Where it lands, and what is in it

/home/zixen/arcanum/backups/account-<UTC stamp>.json.gz, beside the phone's
archives and named the same way - account-2026-09-21T003412Z.json.gz was the
first one written. One file per run, gzipped,
newline-delimited JSON: the first line is a header, and every line after it is
one row.

~~~json
{"columns": {"collection_entries": ["id", "user_id", "game", "card_id", "finish",
 "condition", "language", "quantity", "purchase_price", "purchase_date", "binder",
 "notes", "for_trade", "created_at", "updated_at", "deleted_at"],
 "deck_cards": ["user_id", "game", "deck_sync_id", "card_id", "board",
 "quantity", "sort", "category", "updated_at", "deleted_at"],
 "decks": ["id", "user_id", "game", "name", "created_at", "sync_id",
 "format_id", "notes", "updated_at", "deleted_at", "name_at", "format_at",
 "notes_at"]},
 "created_at": "2026-09-22T005445Z", "format": "arcanum-account-dump",
 "rows": {"collection_entries": 7, "decks": 0, "deck_cards": 0},
 "tables": ["collection_entries", "decks", "deck_cards"], "version": 2}
~~~

(that header, as actually written by the first three-table dump, on 2026-09-22 -
seven holdings, no decks and no lines; the version-1 header from the day this was
built held two tables and is the reason the version had to move)

~~~json
{"table": "collection_entries", "row": {"id": "<uuid>", "game": "<game>",
 "card_id": "<id>", "quantity": "1", "purchase_price": "12.34",
 "purchase_date": "2026-09-18", "for_trade": "false",
 "created_at": "2026-09-19 23:19:10.123456+00", "deleted_at": null}}
~~~

(a row, with the collector's values replaced by placeholders - the file holds
the real ones, and this document does not)

Three things about the shape are deliberate, and each is a way a backup can be
a file without being a backup.

**Every value is text.** The ::text cast is applied to every column
server-side, so a numeric keeps its digits and a timestamptz keeps its
microseconds. Rendering them as JSON numbers and strings would make the file
shorter and the restore lossy - a price that travels through a JSON float comes
back as 12.340000000000001. The session's time zone is pinned to UTC inside the
same transaction, because timestamptz::text renders in the session's own zone
and the same instant would otherwise be two different strings.

**Both tables are read in one transaction**, repeatable read read only, so the
file is a reading of the account at one instant rather than two readings a
moment apart.

**The file is written atomically.** It is built in a .incoming- temporary file
in the same directory, flushed, fsynced - the file and then the directory - and
only then renamed onto its final name. A run interrupted halfway leaves a
temporary file that nothing reads, never a truncated archive wearing a backup's
name. The script then reads its own dump back before it calls it a backup.

Rotation keeps the newest **30** dumps (KEEP in the script), and it will not
delete a dump that failed to verify: a file that does not read back is the only
evidence that something went wrong, so it is left where it is and named in the
state file instead. A second run inside the same second is kept beside the first
(account-<stamp>.2.json.gz) rather than replacing it. Two runs cannot interleave
at all: an exclusive flock is held for the whole of one.

The run records itself in /home/zixen/arcanum/account-backup.state.json, the
shape the other jobs use:

~~~json
{
 "backup": {
  "at": "2026-09-21T004117Z",
  "bytes": 900,
  "deleted": [],
  "file": "account-2026-09-21T004117Z.json.gz",
  "kept": 8,
  "last_ok_at": "2026-09-21T004117Z",
  "last_ok_file": "account-2026-09-21T004117Z.json.gz",
  "note": "wrote account-2026-09-21T004117Z.json.gz, 7 rows in public.collection_entries and 0 rows in public.decks",
  "ok": true,
  "path": "/home/zixen/arcanum/backups/account-2026-09-21T004117Z.json.gz",
  "retired": [],
  "rows": {"collection_entries": 7, "decks": 0},
  "unverified_kept": []
 }
}
~~~

The record is merged rather than replaced, so a failed run leaves `ok: false`
*beside* the last good run's `last_ok_at` - the pair of facts that tells "it
has never run" from "it stopped running". The note is written on the happy path
too, for the same reason in reverse: a merged record that set no note would
leave the last failure's sentence sitting beside `ok: true`, and the loudest
thing in a file would then be a sentence about a night that was fine.

## A restore, and what it actually involves

**The dump is data, and a restore is a decision.** Which rows, over what is
already there, and whether the account is rebuilt whole or merged into what it
holds now - none of that is a thing a backup script can decide, and none of it
is what "restore" means for a collection that two devices are still syncing
against.

The decision is a person's. The mechanical part is
**tool/account/restore_accounts.py**, which is this section's recipe as a program:

~~~sh
# what would restoring the newest dump do to one collector's rows?
python3 /home/zixen/arcanum/restore_accounts.py --user someone@example.com

# the same, from a named dump, and then for real
python3 /home/zixen/arcanum/restore_accounts.py --from account-2026-09-22T005445Z.json.gz \
    --user someone@example.com --apply

# the project is gone and every account is coming back
python3 /home/zixen/arcanum/restore_accounts.py --every-account --apply
~~~

What it does, in order: reads the dump with the backup's own reader (so a file it
cannot read is a file the backup cannot read either), says which tables that dump
holds and which of them it lacks, resolves the account the rows belong to -
user_id is a foreign key to auth.users and a restore cannot invent a collector -
reads what the tables hold for that account now, and prints the four things a
restore can do to each table: rows inserted, rows replaced, rows removed, rows
already identical. Then, unless it was told `--apply`, it runs the whole restore
inside a transaction that is rolled back and checks afterwards that the tables
hold what they held. Nothing else writes to those tables while it runs, because
it takes the backup's own lock.

What it refuses: to write without being told whose rows (`--user` or
`--every-account`), to restore for an email that is not in auth.users, and - in
the words it prints - to pretend a dump that predates a table can put that table
back.

Here is the plan it prints, run against the live project's own account and the
newest dump, which is what a dry run looks like when nothing needs restoring:

~~~
account-2026-09-22T005445Z.json.gz, taken 2026-09-22T005445Z, version 2, holds 3 table(s): collection_entries 7, decks 0, deck_cards 0
  zixen15@gmail.com is 4659db53-c002-4792-bd34-daf0600559d2 in auth.users

  collection_entries   0 inserted, 0 replaced, 0 removed, 7 identical
  decks                0 inserted, 0 replaced, 0 removed, 0 identical
  deck_cards           0 inserted, 0 replaced, 0 removed, 0 identical

dry run: the statements ran inside a transaction that was rolled back, and the account still holds 7 collection_entries, 0 decks, 0 deck_cards
nothing was written. Run it again with --apply to mean it.
~~~

1. **Find out what you have, with no database in the room.**

~~~sh
python3 /home/zixen/arcanum/backup_accounts.py --verify-only
# -> account-2026-09-21T004117Z.json.gz verified: 7 collection_entries, 0 decks,
#    taken 2026-09-21T004117Z
~~~

2. **Unpack the rows of one table, one JSON object per line.**

~~~sh
zcat account-<stamp>.json.gz | tail -n +2 \
  | python3 -c 'import json,sys
for line in sys.stdin:
    item = json.loads(line)
    if item["table"] == "collection_entries":
        sys.stdout.write(json.dumps(item["row"]) + "\n")' > /tmp/incoming_entries.ndjson
wc -l < /tmp/incoming_entries.ndjson    # must equal the header row count
~~~

3. **Load them into the table's own shape, and look before you leap.** This is
   the whole of a restore, run here inside a transaction that is rolled back so
   the account is untouched until somebody decides otherwise.

~~~sql
begin;
set local time zone 'UTC';
create temp table incoming_rows (row_object jsonb);
\copy incoming_rows from '/tmp/incoming_entries.ndjson'
create temp table restored_entries (like public.collection_entries including defaults);
insert into restored_entries
select r.* from incoming_rows,
     jsonb_populate_record(null::public.collection_entries, incoming_rows.row_object) r;
select count(*) from restored_entries;   -- what came back
select count(*) from (
  (select * from restored_entries except all select * from public.collection_entries)
  union all
  (select * from public.collection_entries except all select * from restored_entries)) d;
rollback;   -- or commit something you have thought about
~~~

   jsonb_populate_record is the step that turns the dump's text back into the
   column types, and it is what the proof measures. For decks the same statement
   needs `overriding system value`, because decks.id is generated always as
   identity - which is exactly how it was written when it was tried.

Measured on 2026-09-21, against that morning's dump, over the live project:

~~~
entries_restored=7
entries_differ=0
entries_tombstoned=6
decks_restored=0
live_after_the_probe=7/0
~~~

Seven holdings came back, six of them still marked deleted, none of them
different from the live table in either direction, and the account still held
seven rows and no decks once the transaction rolled back.

**That recipe has now been run against the live tables - and it is still true
that it has never been run over a real collector's rows.** Those are different
claims and both matter. The statements that put an account back have been
executed, committed, against public.collection_entries, public.decks and
public.deck_cards in this project: a probe account was created, a small account
written into it the way a client writes one, the project dumped, the account's
rows deleted, and the dump restored - all three tables, row for row, tombstones
included - with the tool above, and then the probe rows and the account were
deleted. Every other account's rows were fingerprinted before and after and did
not move. That is `tool/account/prove_account_restore.py`, and its run is below.

What no proof can take off a person's hands is deciding to restore over a
collector's *live* rows, because that is a decision about somebody's collection
rather than a mechanic. What was missing until this run was the smaller
question - whether the mechanic works - and it is answered now rather than
assumed.

Three things to know before taking it:

- **A restore is not a merge.** Writing the dump over the tables replaces them.
  The app's own sync compares on updated_at and keeps the later edit; a restore
  has to say what it is doing, and restoring an archive taken before a removal
  brings that card back - correct for "the database is gone, put back what we
  had", and wrong for "somebody deleted the wrong row this morning".
- **The users have to exist.** user_id is a foreign key to auth.users, so rows
  can only be restored for accounts that are still there. The account rows
  themselves are the one part of this system that is not in the dump.
- **It is the whole account's collections, not one user's.** This is a dump of
  every account, which is what makes it a backup at all; a partial restore is a
  where clause somebody adds on purpose.

## How to check it is still running

Three ways, cheapest first.

~~~sh
# 1. Read the newest dump back. No credentials, no database; the exit status is the answer.
python3 /home/zixen/arcanum/backup_accounts.py --verify-only; echo $?

# 2. What the last run did, and when it last worked.
cat /home/zixen/arcanum/account-backup.state.json

# 3. The unit, once it is installed.
systemctl list-timers arcanum-account-backup.timer
systemctl status arcanum-account-backup.service
tail /home/zixen/arcanum/logs/account_backup.log
~~~

`--verify-only` is the one that matters for monitoring, because it keeps working
on the night the database is what broke. It writes nothing, needs no secrets,
and exits non-zero when the newest dump does not gunzip, when a line is not
JSON, or when the header's row count is not the number of rows actually in the
file. A job that calls it nightly has a fact to report on, and the dump's own
exit status is the same fact for the night it ran.

`--dry-run` is the fourth thing worth knowing: it connects, counts both tables
and writes nothing, so "can this host still see the account?" can be asked
without producing a file.

### Installing it

The units are in tool/deploy/ and are **installed and enabled**. The script is
deployed flat, beside catalog_store.py and beside the backups directory, which is
how every other unit here is deployed. This is what was run, in full, on
2026-09-21:

~~~sh
scp tool/account/backup_accounts.py zapp:/home/zixen/arcanum/
scp tool/deploy/arcanum-account-backup.service tool/deploy/arcanum-account-backup.timer zapp:/tmp/
sudo cp /tmp/arcanum-account-backup.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now arcanum-account-backup.timer
sudo systemctl start arcanum-account-backup.service
~~~

And this is what came back, so that "installed" is a measurement rather than a
claim:

~~~text
Created symlink /etc/systemd/system/timers.target.wants/arcanum-account-backup.timer
  -> /etc/systemd/system/arcanum-account-backup.timer.
NEXT                          LEFT  LAST  PASSED  UNIT
Mon 2026-09-21 07:11:19 UTC   6h    -     -       arcanum-account-backup.timer

arcanum-account-backup.service - Arcanum - dump the account tables to a restorable archive
     Active: inactive (dead) since Mon 2026-09-21 00:57:41 UTC; 6s ago
TriggeredBy: ● arcanum-account-backup.timer
    Process: 746663 ExecStart=/usr/bin/python3 /home/zixen/arcanum/backup_accounts.py (code=exited, status=0/SUCCESS)
     CPU: 333ms
~~~

The run it took wrote

~~~text
wrote /home/zixen/arcanum/backups/account-2026-09-21T005740Z.json.gz, 7 rows in
public.collection_entries and 0 rows in public.decks, 10 dump(s) kept
~~~

and the two commands a person checks it with, run afterwards and both exiting 0:

~~~sh
python3 /home/zixen/arcanum/backup_accounts.py --verify-only
# account-2026-09-21T005740Z.json.gz verified: 7 collection_entries, 0 decks, taken 2026-09-21T005740Z
python3 /home/zixen/arcanum/backup_accounts.py --dry-run
# dry run: 7 in public.collection_entries and 0 in public.decks; nothing was written
~~~

`07:10 UTC`, and the time is chosen against the rest of the night rather
than for its own sake. Pokemon fires at 04:20, lorcana at 04:40, Yu-Gi-Oh! at
04:55, the weekly Magic rebuild at 05:30 on Mondays and the catalogue watcher at
06:30; each of those can be deferred by its own randomized delay or by
Persistent=true to the next boot. Seven ten is after all of them and after the
watcher's read, so a dump never contends with an import for the database, and
never lands in the middle of a window whose answer is still being written. The
timer carries `Persistent=true` for the reason the samplers do - a night that
was missed should be taken at the next opportunity rather than skipped - and it
matters more here than anywhere else, because a backup is the one job whose
absence has no second copy to fall back on.

## What is deliberately NOT backed up

- **The catalogue.** catalog_sets, catalog_cards, catalog_prices, catalog_meta
  and their search functions are hundreds of megabytes of somebody else's data
  - TCGplayer's, Scryfall's, Lorcast's - and every row of it can be fetched
  again from the providers that publish it. Backing it up would be storing a
  copy of a copy and paying for it nightly. What a restore would lose with it is
  the cards_revision numbers, which cost one import to rebuild.
- **Price history.** The daily series live in SQLite on the companion
  (/home/zixen/arcanum/data/*.db), sampled by the pollers, and the current
  prices the app shows come from the providers. None of it is in Postgres, so
  none of it is in this dump, and a restore does not touch it. The companion's
  own databases are a separate question with their own answers: the Magic slice
  is rebuildable from MTGJSON, and the sampled games are not, which is what
  their timers are for.
- **The accounts themselves.** auth.users - the addresses, the password hashes
  - belongs to Supabase Auth and is deliberately not copied into a file on
  another host. A dump that carried it would turn a backup of a collection into
  a copy of everybody's identity. The consequence is written above: a restore
  needs those accounts to still exist.
- **The phone's database.** The phone uploads its own archives through the
  companion (/v1/backup), device by device, and has since it shipped. Nothing
  here changes that, and nothing here reads it.
- **Anything off this host.** The dump lands on the same machine as the
  companion, which does leave two copies of the account in two places that fail
  independently: Supabase holding the live rows, and the host holding the dump.
  Losing either one is survivable. Losing both at once - which takes both
  providers failing, not one - is the hole that is left, and it is the reason
  the dump is a plain gzipped file anything can read rather than something only
  this script can.
- **Encryption.** The file is mode 600 and holds rows in the clear. There is no
  second password to lose, and nothing in the dump is more sensitive than what
  the app already shows its owner. If it is ever copied off the host, that is
  the point to think about encryption, not before.

## The proofs

Two of them now, and they answer different questions: whether the dump can be
read, and whether the dump can be put back.

**tool/account/prove_account_backup.py** - A backup that has never been read back
is not a backup, so every check is about reading it: that it parses line by line,
that every column of every table is in every row (compared against
information_schema in the same run, so a column added later and quietly dropped
from the dump is caught), that a tombstone is in it with the same timestamp,
that the dumped rows and the live rows hash to one md5, that those rows insert
back into the table's own shape and match it row for row, that rotation keeps
the newest dump and never deletes one that did not verify, and that
--verify-only agrees with a fresh dump. Every check needs the live database; one
that cannot be made says so and fails rather than passing quietly.

**tool/account/prove_account_restore.py** - the restore itself, performed. It
creates a probe account, writes a small account into it through the API the way a
client writes one - three holdings, one of them a tombstone, a deck, and three of
its lines, one of them a tombstone - takes a real dump of the whole project,
deletes the account's rows, and then runs `restore_accounts.py` twice: once as a
dry run, and once with --apply. Afterwards it hashes all three tables against the
dump, checks the tombstones came back soft-deleted with their own timestamps,
checks the deck's lines came back at all, fingerprints every *other* account's
rows before and after to prove the restore stayed inside the account it was told
to restore, and deletes the probe account and its rows. Without the admin key it
skips itself and says why, rather than reporting a restore it never ran.

Last run, 2026-09-21, on zapp.sytes.net, as the owner over the session pooler. The
proof takes a dump of its own to read back - the examples above are the nightly
run's, and the file named here is the proof's:

~~~
Prove the account dump can be read back, and that what it holds is the account.

target        /home/zixen/arcanum/backups and the session pooler in SUPABASE_DB_URL_POOLED

--- The dump, taken and read back ---
PASS  a_fresh_dump_can_be_taken
        the backup ran as the timer runs it and printed one line: wrote /home/zixen/arcanum/backups/account-2026-09-21T004117Z.json.gz, 7 rows in public.collection_entries and 0 rows in public.decks, 3 dump(s) kept
PASS  the_dump_reads_back
        account-2026-09-21T004117Z.json.gz: 8 lines, 7 rows, 7 collection_entries, 0 decks - every line valid JSON and every count equal to the header's

--- The dump against the live tables ---
PASS  every_column_of_both_tables_is_in_every_row
        collection_entries: 16 columns, present in all 7 row(s); decks: 5 columns, present in all 0 row(s)
PASS  tombstones_survive
        all 6 soft-deleted holding(s) are in the dump with the same deleted_at, so a restore cannot put a removed card back
PASS  a_restore_of_the_dump_is_the_live_account
        account-2026-09-21T004117Z.json.gz and the live tables hash to the same value: md5 9a2fd173dfee7b4e489c783b0c0bd2eb over 7 row(s) 7 collection_entries, 0 decks
PASS  the_dumped_rows_would_restore
        every dumped row was inserted as its column's own type into a copy of the table, matched the live row for row, and the transaction was rolled back with the account untouched: 7 collection_entries, 0 decks
PASS  the_dump_holds_no_credential
        the decompressed dump holds no occurrence of the connection string, its password, the credentials file's name or the names the credentials live under; what it holds is rows

--- Rotation ---
PASS  rotation_keeps_the_newest_dump
        KEEP=30; on copies, the oldest of four went, the two newest stayed, the truncated one was kept and reported rather than deleted, and a dump named as protected survived even with keep=0; on /home/zixen/arcanum/backups, with 7 dump(s) in it, rotation removed nothing and the file just written is still there

--- What the monitoring job calls ---
PASS  verify_only_agrees_with_a_fresh_dump
        'account-2026-09-21T004117Z.json.gz verified: 7 collection_entries, 0 decks, taken 2026-09-21T004117Z' - the same counts the fresh dump recorded (account-2026-09-21T004117Z.json.gz)

9 passed, 0 failed, 0 skipped
~~~

**The first run of this file failed, and the failure was worth keeping.** It
reported `8 passed, 1 failed`: the tombstones check asked the database for one
line per tombstone, all named the same thing, through a helper that collected
them into a dictionary - so six tombstones became one, and the check said the
database held one where the dump held six. The dump was right and the proof was
wrong, which is the useful direction for that bug to point. The reading is
straight lines now, and it passes.

What that proof does not say, and should not be read as saying: that tomorrow's
dump will be right (it is a comparison with the account at the moment it ran), or
that a dump exists for any night whose timer has not run.

### The restore, performed

prove_account_restore.py, run on 2026-09-22 on zapp.sytes.net, against the live
project, with the owner's connection and an admin key that made one probe account
and deleted it again:

~~~
Restore an account from a dump, and read the tables afterwards.

target   the session pooler and the three account tables

--- The dump ---
PASS  a_dump_holds_every_table_of_the_account
      3 holding(s), 1 deck(s), 3 line(s) - the probe account, written as a client
      writes one, inside a version 2 dump of every account

--- The loss, and the plan ---
PASS  the_rows_are_gone_before_the_restore
      every row the probe account had is gone, which is the state a restore is for
PASS  the_plan_says_what_a_restore_would_change
      collection_entries   3 inserted, 0 replaced, 0 removed, 0 identical ...
      decks                1 inserted, 0 replaced, 0 removed, 0 identical  (22)
      deck_cards           3 inserted, 0 replaced, 0 removed, 0 identical ...
PASS  a_dry_run_leaves_the_tables_alone
      the plan ran inside a transaction that was rolled back and the account still
      holds nothing, which is what the tool's own dry run asserts of itself

--- The restore ---
PASS  a_restore_puts_the_rows_back
      all three tables hash to the value the dump holds them at: 3
      collection_entries, 1 decks, 3 deck_cards, row for row, over every column
PASS  a_restored_tombstone_is_still_deleted
      2 soft-deleted row(s) came back soft-deleted with the timestamps the dump
      carries: 2026-01-04 04:00:00+00, 2026-01-05 05:00:00+00
PASS  a_decks_lines_come_back
      the deck's 3 line(s) came back, which is the hole this whole change closes:
      a dump that held two tables would have restored the deck's name and none of
      its cards

--- Nothing else moved ---
PASS  another_accounts_rows_are_untouched
      every other account's rows in all three tables hash to what they hashed to
      before the restore, so a restore scoped to one collector stayed inside that
      collector

--- Nothing left behind ---
PASS  nothing_is_left_behind
      no probe row in any of the three tables and no probe account in auth.users

9 passed, 0 failed, 0 skipped
~~~

The deck came back as id 22 - the dumped identity value, through the column that
is `generated always as identity`, which is what the OVERRIDING SYSTEM VALUE in
the insert is for. Its three lines came back with it, including the one whose
`deleted_at` is stamped: a line removed from a deck is a tombstone like a holding
is, and a restore that dropped it would put a card back in a deck its owner took
it out of.

## Files

- tool/account/backup_accounts.py - the dump: one snapshot, text values, an
  atomic write, a read back, rotation, and the state file. It holds the format,
  the reader and the connection rules that the restore tool uses rather than
  copying.
- tool/account/restore_accounts.py - the restore: verify, resolve the account,
  say what would change, run it inside a transaction that is rolled back, and
  write it only when told to with --apply.
- tool/account/prove_account_backup.py - the reading proof above.
- tool/account/prove_account_restore.py - the restore proof above, which creates
  and deletes its own probe account and touches no collector's rows.
- tool/deploy/arcanum-account-backup.service and .timer - once a day at 07:10
  UTC, after every other job of the night. Installed and enabled on
  zapp.sytes.net on 2026-09-21.
- tool/catalog_store.py - libpq_environment, which is where the rule about a
  password never reaching a command line lives.
- docs/collection-sync-tombstones.md - why a removal is a timestamp on a row,
  which is why the dump has to carry one.
- docs/catalogue-server-side.md - the owner connection, the session pooler, and
  the tables this dump deliberately leaves alone.
