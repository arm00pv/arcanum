# The account, backed up

Status: built, installed and run against the live project (wqycllzbwbhqiqlmbwcu)
from zapp.sytes.net on 2026-09-21, on branch `web/M0-spike`. The units in
tool/deploy/ are installed and enabled: the timer next fires at 07:11 UTC, and
the service was started by hand once, which is where the dumps in the backups
directory and the proof output below come from. "Installing it" below records
exactly what was run and how to check the thing is still happening.

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

Both tables, every row, every user, connected as postgres over the session
pooler - the same connection tool/catalog_store.py makes for the catalogue
import, and for the same reason: postgres owns these tables and holds
BYPASSRLS, so a dump can see every account's rows where a policy would show it
exactly one.

| Table | What it holds |
| --- | --- |
| public.collection_entries | one row per stack a collector owns: game, card, finish, condition, language, quantity, what they paid, the binder, the note, the trade flag |
| public.decks | one row per deck: owner, game, name |

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
 "decks": ["id", "user_id", "game", "name", "created_at"]},
 "created_at": "2026-09-21T004117Z", "format": "arcanum-account-dump",
 "rows": {"collection_entries": 7, "decks": 0},
 "tables": ["collection_entries", "decks"], "version": 1}
~~~

(that header, as actually written on the day this was built - the two tables
held seven holdings and no decks)

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
against. What follows is the mechanical part, and the measurement under it is
from this project rather than from a sketch.

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

**What has not happened, and should be said plainly: this recipe has never been
run against the live tables.** It has been run into temporary copies of their
shape, inside transactions that were rolled back - by the run above, and by the
proof below. The last step, writing back over a real collector's rows, is the
one that needs a person.

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

## The proof

tool/account/prove_account_backup.py. A backup that has never been read back is
not a backup, so every check is about reading it: that it parses line by line,
that every column of both tables is in every row (compared against
information_schema in the same run, so a column added later and quietly dropped
from the dump is caught), that a tombstone is in it with the same timestamp,
that the dumped rows and the live rows hash to one md5, that those rows insert
back into the table's own shape and match it row for row, that rotation keeps
the newest dump and never deletes one that did not verify, and that
--verify-only agrees with a fresh dump. Every check needs the live database; one
that cannot be made says so and fails rather than passing quietly.

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

What the proof does not say, and should not be read as saying: that tomorrow's
dump will be right (it is a comparison with the account at the moment it ran),
that the restore recipe above has been performed on the live tables (it has
not), or that a dump exists for any night whose timer has not run.

## Files

- tool/account/backup_accounts.py - the dump: one snapshot, text values, an
  atomic write, a read back, rotation, and the state file.
- tool/account/prove_account_backup.py - the proof above.
- tool/deploy/arcanum-account-backup.service and .timer - once a day at 07:10
  UTC, after every other job of the night. Installed and enabled on
  zapp.sytes.net on 2026-09-21.
- tool/catalog_store.py - libpq_environment, which is where the rule about a
  password never reaching a command line lives.
- docs/collection-sync-tombstones.md - why a removal is a timestamp on a row,
  which is why the dump has to carry one.
- docs/catalogue-server-side.md - the owner connection, the session pooler, and
  the tables this dump deliberately leaves alone.
