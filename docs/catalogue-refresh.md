# Keeping the shared catalogue current

Status: applied to `zapp.sytes.net` on 2026-09-18. This is the schedule that
step 1 of [catalogue-server-side.md](catalogue-server-side.md) deliberately left
to whoever owned it, and nothing else: Lorcana's catalogue is now refreshed by
the nightly sweep that already samples its prices, a watcher reports a catalogue
that stops being refreshed, and no game beyond Lorcana is imported, no RPC is
added and no client changes. The import it schedules is
[catalogue-import.md](catalogue-import.md).

If this file and the units on the host disagree, the host is what ran.

## What runs when, now

All times UTC, as the timers are written.

| Unit | When | What |
| --- | --- | --- |
| `arcanum-pokemon-poll.timer` | 04:20, + up to 20m | TCGdex prices |
| `arcanum-lorcana-poll.timer` | 04:40, + up to 10m | Lorcast prices **and the shared Lorcana catalogue** |
| `arcanum-yugioh-poll.timer` | 04:55, + up to 10m | YGOPRODeck prices |
| `arcanum-mtg-rebuild.timer` | Mondays 05:30, + up to 30m | the MTGJSON slice, tens of minutes |
| `arcanum-alerts.timer` | every half hour | price alerts the phone cannot deliver itself |
| `arcanum-catalog-watch.timer` | 06:30, + up to 5m | **new**: is the shared catalogue still being refreshed |

Two lines are new in the lorcana unit, and they are the whole of the scheduling
change - one argument and one environment file:

~~~
ExecStart=/usr/bin/python3 /home/zixen/arcanum/poll_lorcana_prices.py --db /home/zixen/arcanum/data/lorcana_prices.db --catalog --skip-polled-today
EnvironmentFile=/home/zixen/arcanum/supabase.env
~~~

Before that, the unit ran the same script with no `--catalog`, so the log ended
at "database now holds ...". The catalogue was frozen at the day it was imported
by hand (the rows still carry `catalogued_at` of 19:14 to 19:16 on 2026-09-18),
and a set Lorcast publishes tomorrow would simply not have been there - which is
worse than the per-device download it replaced, because a browser has no second
source for it.

`--skip-polled-today` is not part of the catalogue change and does not alter a
normal night. The sweep keeps its own record of what it sampled, and at 04:40
nothing has been sampled that day; the flag is what stops a hand-run or a
catch-up run rewriting the day's prices with a later reading. `poll_state` held
one row per card, all dated 2026-09-18, which is why the row for tomorrow matches
nothing.

## What the import costs

Measured on the host, by hand, against the live database on a night when nothing
had changed:

~~~
price sweep alone (2026-09-18 04:43, from the unit log)   13s
the same sweep with --catalog                             29s
CPU systemd billed for the run with --catalog             3.1s
~~~

So the catalogue adds about sixteen seconds, and almost none of it is work this
host does: it is 24 `psql` processes, 24 connections through the session pooler
and 24 reads of the game's own set rows - one per set, because the checksum
comparison needs what is stored before it can skip anything. The card tables are
not written at all on a night like this one: the proof below shows
`catalogued_at` unchanged on every set.

## Why it shares the window

The three samplers run between 04:20 and 04:55 because a day that is not sampled
is a day permanently missing from every trend, and they run before the Monday
Magic rebuild rather than after it for the same reason
(`tool/deploy/README.md`). Sixteen seconds inside a fifteen-minute gap is not a
contest, and the two jobs are not really two jobs: the 24 Lorcast responses the
sweep downloads to read prices are the same 24 responses the catalogue is built
from.

Three ways of sharing the window were considered and two were rejected.

**One unit, same window - chosen.** The sweep writes a second table from data
already in hand, which is exactly the argument section 3 of the design makes for
the cheapest possible importer, and it means the catalogue cannot be fresher or
staler than the price sample it rides on: one log, one failure, one thing to
read in the morning.

**A second unit at another time, running `--catalog-only`.** Rejected. It would
fetch the same 3,208 cards a second time from a free keyless API to produce rows
the first fetch already had, and it would put the catalogue's schedule somewhere
else on the clock, which is more window to protect rather than less. It buys one
real thing - the two jobs could then fail independently - and that is bought
more cheaply inside the run, below.

**The import triggering the sampler.** Rejected for the same reason as the
second unit: chaining two units still means two downloads of one game's cards,
and it adds an ordering rule between them that has to keep being true.

The one thing that did have to be separated is failure, because the two halves
are not equally replaceable. A price sample that does not happen is a hole in a
series that nothing anywhere can backfill; a catalogue import that does not
happen is a night the catalogue stays as it was, and the next night fixes it. So
the run is written to degrade in that direction: if the database cannot be
reached at 04:40, the import is dropped and the price sweep continues, and the
catalogue's staleness is reported in the morning rather than paid for by the
day's prices. That is the `set_list_fingerprint` read at the top of `run()` in
`tool/poll_lorcana_prices.py`, which was the only catalogue read that happened
before the first price was written; a set whose import fails inside the loop was
already survivable, because the sweep counts it and carries on.

## What happens when it fails

Nothing here relies on the unit's exit status, and that is deliberate rather than
an omission. The poller returns non-zero only when *every* set failed
(`return 1 if failed_sets and failed_sets == len(codes) else 0`), so a night
where three sets did not import leaves systemd reporting success and a catalogue
that is three sets behind. An `OnFailure=` unit would therefore not fire on the
case that matters most.

What the importer does instead is write the outcome down - `catalog_meta.last_import_ok`
and `last_import_note`, on the failure path as well as the happy one, which is
rule 5 of section 3 - and `tool/check_catalog_freshness.py` reads it and turns it
into a notification through the notify path this deployment already has:
`notify.json`, the topic derived from `backup.token`, and `publish()` from
`check_alerts.py`, imported rather than reimplemented. No second mechanism was
added and no new secret was invented.

It asks three questions of every game in `catalog_meta` that has a source, which
today is Lorcana alone:

| Broken thing | `systemctl status` | What the watcher reports |
| --- | --- | --- |
| A set failed to download or to write | success | `last_import_ok` false, with the run's own note |
| The run was killed part way, or the host was off | success | no import has finished since tonight's window |
| The timer was disabled, or the unit removed | nothing at all | the same fact, because freshness is what is asked |
| The database is unreachable | failure, no prices | the shared catalogue could not be read at all |
| A provider answered with a plausible but short list | success | the card count fell since the last reading |

The catalogue is read over PostgREST with the publishable key and not over psql
as the owner, for three reasons: the question worth asking is whether a client
can see a current catalogue, and a check that connects as `postgres` would answer
yes while a dropped policy left every browser with an empty Sets tab; it has to
keep working on the night the database is the broken thing, which rules out
borrowing the importer's connection; and the key it uses is public by
construction, so the unit that runs it holds no password and reads only
`SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`.

## What the importer already guarantees, and the one thing it does not

The question is the right one to ask of an unattended run, so it is worth
answering by name rather than by trusting the module's reputation.

**Enough, and it is the important half.** Every set is written in one
transaction, through `psql -f` with `ON_ERROR_STOP`, so a set that fails to
write closes its connection and rolls back: a reader sees the whole old set or
the whole new one. The checksum is compared first, so a night when nothing
changed writes no card rows and moves no revision - the run above left
`catalogued_at` at 19:14 to 19:16 while `sets_updated_at` moved to 21:46.
A set the provider answers with no cards is refused rather than emptied, a set
is never deleted (only retired), a card carrying another set's code is refused,
the account tables are unreachable from any statement the module generates, and
a `flock` keeps two imports apart. A run killed at set twelve therefore leaves
twenty-four sets that are each internally consistent, twelve of them at a newer
revision, and yesterday's record still saying yesterday - which is why the
watcher asks about freshness and not only about `last_import_ok`.

**Not covered: an answer that is plausible but short.** The guard refuses zero
cards and nothing refuses fewer, so a provider returning forty cards for a set
that holds 216 has its forty cards written, the set's `cards_revision` bumped
and the run recorded as successful. The damage lasts one night - the next good
run restores the set - but nothing in the write path notices while it is wrong,
and at 04:40 nobody is watching. Making the write path refuse it would mean
choosing a threshold, and there is no threshold to choose: a card genuinely can
leave a set,
which is the same rule-1-against-rule-4 hole `catalogue-import.md` already
records (there is no `retired_at` on `catalog_cards`, so a withdrawn card is
hard-deleted while a withdrawn set is not). So the answer here is a reading
rather than a refusal: the watcher keeps what the last run counted and reports a
card count that falls, once, to a person who can look at what changed. It is the
cheapest thing that closes the gap without a schema migration and without a guess
about how much shrinkage is normal.

The same reading covers the other silent loss: if Lorcast ever answers `/sets`
with a shorter list, every set missing from it is retired, which is a soft delete
that the next good run reverses - and it is worth exactly one look, so it is
reported and not refused.

## The proof

Run on `zapp.sytes.net`, 2026-09-18. The units were installed, then triggered by
hand.

The systemd journal for the trigger, which is also the whole of what the unit
says:

~~~
$ sudo systemctl start arcanum-lorcana-poll.service
$ journalctl -u arcanum-lorcana-poll.service --since '2026-09-18 21:46'
Sep 18 21:46:23 ubuntu-lts systemd[1]: Starting arcanum-lorcana-poll.service - Arcanum - sample Lorcana prices and refresh its shared catalogue...
Sep 18 21:46:57 ubuntu-lts systemd[1]: arcanum-lorcana-poll.service: Deactivated successfully.
Sep 18 21:46:57 ubuntu-lts systemd[1]: Finished arcanum-lorcana-poll.service - Arcanum - sample Lorcana prices and refresh its shared catalogue.
Sep 18 21:46:57 ubuntu-lts systemd[1]: arcanum-lorcana-poll.service: Consumed 3.539s CPU time.
~~~

The unit redirects its output to a file, so that is all the journal holds; the
run's own words are in `logs/poll_lorcana_prices.log`, appended by the same
unit:

~~~
24 sets to scan
3208 cards already sampled today
  set 1/24 P1: 41 cards, 0 points
  ...
  set 24/24 PD1: 8 cards, 0 points

done in 29s — 0 points written, 0 set(s) failed
24 sets read, 3,208 cards seen, 0 with no price at all
database now holds 34,584 points across 3,124 cards and 6 day(s), 5.04 MB

catalogue holds 24 sets and 3,208 cards, sets_revision 1
~~~

"3208 cards already sampled today" is `--skip-polled-today` doing its job on a
hand-run at 21:46: the day had already been sampled at 04:43 and this run did not
overwrite it. It is not what the 04:40 run prints - run against a copy of the
database whose `poll_state` reads yesterday, the same command writes the day's
points and imports the catalogue in one pass:

~~~
done in 29s — 5764 points written, 0 set(s) failed
24 sets read, 3,208 cards seen, 84 with no price at all

catalogue holds 24 sets and 3,208 cards, sets_revision 1
~~~

5,764 points is what the 04:43 sweep wrote by itself, so the flag costs a normal
night nothing.

The catalogue afterwards, as the owner:

~~~
  game   | sets_revision | set_count | card_count | last_import_ok |                            last_import_note                             | source  |       sets_updated_at
---------+---------------+-----------+------------+----------------+-------------------------------------------------------------------------+---------+-----------------------------
 lorcana |             1 |        24 |       3208 | t              | 24 sets upstream, 24 written, 24 unchanged, 3208 cards, 0 set(s) failed | lorcast | 2026-09-18 21:46:57.428389+00

 sets_total | sets_live | sets_retired
------------+-----------+--------------
         24 |        24 |            0

 cards  | prices
--------+--------
   3208 |      0

 revision_sum |            oldest             |            newest
--------------+-------------------------------+-------------------------------
           24 | 2026-09-18 19:14:02.735142+00 | 2026-09-18 19:16:20.171671+00
~~~

The last two lines are the checksum skip: 24 sets at `cards_revision` 1 between
them, and `catalogued_at` still where the hand import left it. `sets_revision`
stayed 1 because the set list did not change, which is rule 7 working. The
account tables were not read or written by any of this.

The watcher, triggered by hand:

~~~
$ sudo systemctl start arcanum-catalog-watch.service
$ cat ~/arcanum/logs/catalog_watch.log        # one block per run, appended
reading https://wqycllzbwbhqiqlmbwcu.supabase.co/rest/v1/catalog_meta as a client, judged at 2026-09-18 21:46 UTC
lorcana: 24 sets, 3208 cards, last import 2026-09-18 21:46 UTC, recorded ok=True, client reads 24 sets / 3208 cards
nothing to report
~~~

`client reads 24 sets / 3208 cards` is the count PostgREST returned to the
publishable key, so the rows and the record agree and a browser can see both.

The three failure paths were proved by hand rather than waited for, and the
notification was sent to a stand-in on the loopback instead of to the phone. The
first judges the live catalogue as though it were three days later, which is the
stale case without touching anything:

~~~
$ python3 check_catalog_freshness.py --now 2026-09-21T06:30:00Z --server http://127.0.0.1:18099
lorcana: 24 sets, 3208 cards, last import 2026-09-18 21:46 UTC, recorded ok=True, client reads 24 sets / 3208 cards
  - lorcana: no import has finished since 2026-09-21 04:40 UTC; the last one was 2026-09-18 21:46 UTC, so the shared catalogue is frozen and a new set will not be in it
1 problem(s)
notified: Arcanum catalogue needs attention

$ python3 check_catalog_freshness.py --url https://127.0.0.1:1 --server http://127.0.0.1:18099
the catalogue could not be read: ... could not be asked: <urlopen error [Errno 111] Connection refused>
1 problem(s)
~~~

The second is a state file that claims more than the catalogue holds, which is
how the count comparison is proved without pretending a set went missing:

~~~
$ python3 check_catalog_freshness.py --state <a state file saying 9999 cards> --server ...
  - lorcana: the catalogue holds 3208 cards where the last reading saw 9999 - 6791 rows left the table, which the checksum skip cannot explain
  - lorcana: the catalogue holds 24 sets where the last reading saw 30; a set may have been retired upstream, which is worth one look and is undone by the next good run
2 problem(s)
~~~

and what the stand-in received, topic redacted:

~~~
{
  "topic": "<redacted>",
  "title": "Arcanum catalogue needs attention",
  "message": "lorcana: no import has finished since 2026-09-21 04:40 UTC; ...",
  "priority": 3,
  "tags": ["warning"]
}
~~~

The topic is the one `check_alerts.py` derives from `backup.token`, which is to
say the same topic the phone already listens to for price alerts. That was the
choice to argue with: an operator alarm and a collector's price alert sharing one
channel. The alternative was a second notification path with a second secret and
a second thing for the collector to subscribe to, for a message that arrives at
most once a day and is about the same app. `notify.json` remains the one place
its priority and destination are set.

## What is not settled

**The window is a fact about one game.** Lorcana's import rides on the 04:40
sampler because that sampler already downloads Lorcana. Steps 3 and 5 add five
games that have no sampler to ride on, and their importers will need windows of
their own - the design's table already sketches `arcanum-catalog-tcgcsv.timer`
after 06:00. When one of them is imported, `WINDOWS` in
`check_catalog_freshness.py` has to learn its hour; until it does, the watcher
reports the game as one nobody knows when to expect rather than passing it
silently.

**06:30 is a compromise, and it is not on the critical path.** The watcher runs
after the whole sampling window so that "nothing has finished since the window"
means what it says, which also means a failure at 04:40 is reported two hours
later rather than immediately. Nothing in the catalogue is worse for those two
hours.

**The freshness rule assumes the window does not move.** If the lorcana timer is
ever rescheduled, the hour in the watcher has to move with it; an hour that is
later than the real one reports every night, and an hour that is earlier reports
nothing at all. Nothing checks the two against each other.

**A catch-up run can produce one false alarm.** All four timers carry
`Persistent=true`, so a host that was off at 04:40 runs the import when it comes
back. If it comes back after 06:30 the watcher has already reported the catalogue
stale, correctly, and the run that fixes it happens shortly afterwards.

**The importer hands the connection URL to `psql` as an argument.** This change
does not make that worse - the poller's own command line is clean, which is what
`EnvironmentFile` above is for - but it is worth writing down, because it was
found while arguing that the password stays out of a process listing and it does
not. `catalog_store._run` passes `self.db_url` in `psql`'s argv, and `ps` shows
it, password included, for as long as each statement runs - measured on the host,
not inferred from the source. Two fixes were tried against the live pooler:

~~~
PGDATABASE=<the URI> psql ...        -> ignored; psql fell back to the local socket
PGHOST/PGPORT/PGUSER/PGDATABASE/     -> connected, and nothing sensitive in ps
  PGPASSWORD/PGSSLMODE=<split out>
~~~

so the fix is to split the URL into the `PG*` variables before spawning `psql`,
not to put the URI in an environment variable. It belongs to whoever owns the
shared write path rather than to the schedule, because every importer inherits
`_run` - and it is a one-line change there rather than a change here.

**`last_import_note` is only as good as the importer's counting.** It says how
many sets were written, unchanged and failed, and nothing about which - so the
notification for a partial night says "3 set(s) failed" and the log has the
names. That is enough to know something is wrong, which is what the watcher is
for; it is not enough to know what.

## Reversing it

Two lines, and nothing structural - the catalogue is rows and the schedule is a
unit file.

~~~
# stop importing, keep sampling exactly as before 2026-09-18
sudo systemctl stop arcanum-catalog-watch.timer
sudo systemctl disable arcanum-catalog-watch.timer
# then remove --catalog and --skip-polled-today from ExecStart in
# /etc/systemd/system/arcanum-lorcana-poll.service, and:
sudo systemctl daemon-reload
~~~

Removing `--catalog` leaves the catalogue frozen at whatever the last import
wrote rather than empty, which is the state it was in before this change. The
watcher would then report it as stale, correctly, which is the other reason to
disable it rather than leave it running.

The state file and the log are the only other traces:
`/home/zixen/arcanum/catalog.state.json` and
`/home/zixen/arcanum/logs/catalog_watch.log`. Deleting the state file costs one
night of the count comparison and nothing else.
