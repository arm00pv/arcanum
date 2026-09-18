# An open browser, hearing what the other one did

Status: the client is built and the migration is written. **The migration has
not been applied to the live project (`wqycllzbwbhqiqlmbwcu`) from the machine
this was written on**, because the credentials that would apply it - the session
pooler URL and `psql` - are not there, and neither is the admin key that would
prove delivery. What was run, what it reported and what it could not reach are
all in "The proof" below, unedited.

The change itself is one line of Postgres and about two hundred lines of Dart.
It is written as migration step 2 of the account tables, after
[collection-sync-tombstones.md](collection-sync-tombstones.md), and it follows
that file's habit: what was applied, the two things that will bite, the proof,
and the reversal.

## The bug

A browser carried its own work up to the account in about a second - a card
added or removed reached Supabase almost immediately - and brought nothing down
again until the page was reloaded. Two browsers signed in to one account
therefore disagreed for as long as both stayed open, each showing the collection
as it had been at its own sign-in plus whatever it had done itself. The reload
fixed it, and the reload is the clue: it re-runs the sign-in, and a sign-in
pulls. The pull was never the broken half. Nothing was asking for one.

## What was built

### The server: membership of a publication

`tool/account/0002_realtime_collection.sql`:

~~~sql
alter publication supabase_realtime add table public.collection_entries;
~~~

That is the whole change, guarded by a check against `pg_publication_tables`
so that a table already toggled on from the dashboard's Database -> Replication
page makes this a no-op rather than an error. It touches no column, no
constraint, no index, no policy and no grant, and the proof script measures that
rather than promising it.

**Nothing was added to the table, and that is the point of the paragraph.** A
table that is not in `supabase_realtime` is invisible to Realtime whatever the
client asks for - creating a table and streaming it are two separate steps, and
the first is the one people remember. Nothing about the table's shape decides
it.

**`replica identity full` was deliberately not set.** A removal here is an
UPDATE - the row stays and `deleted_at` is stamped on it - so nothing depends
on a DELETE arriving with its columns, which is the only thing replica identity
buys. It would cost the whole previous row in the WAL for every card added and
every quantity corrected, to serve events this app never sends. Under row level
security it would not even work: for a policy-protected table the old record is
reduced to the primary key whatever the replica identity is. The consequence
runs one way and it is the way the app already works: everything the merge needs
is in the new record.

### The client: one merge, one announcement, one seam

- `lib/data/sync/account_changes.dart` - `AccountChanges`, the seam, and
  `SupabaseAccountChanges`, the real one over the socket. The seam exists for
  the same reason `AccountTable` does: what happens once a change has arrived is
  the part that has to be right, and a websocket is not a thing a test can be
  relied on to have.
- `lib/data/sync/collection_sync.dart` - `mergeRow` and `pullChanged`, both
  going through the same private `_merge` that `pull` uses, and therefore
  through `AccountCollection.accountWins`. There is exactly one place where two
  copies of a holding are weighed and this work did not add a second one.
- `lib/features/auth/collection_listener.dart` - `CollectionListener`: subscribe,
  merge every row as it arrives, gather the games that moved, tell the screens
  once per `settle` window, and pull the whole account whenever the subscription
  goes live.
- `lib/main.dart` - built inside the `kIsWeb` branch, beside the push-side
  watcher, so a phone holds no socket and hears nothing.

### The merge is the pull's merge

A row announced by the account goes through `CollectionSync.mergeRow`, which is
`_merge` - the same comparison `pull` makes. The later edit wins, a tie goes to
the account, and a tombstone arriving from another device is a row with a
deletion stamped on it, so it hides the card here by the same rule that hides it
after a sign-in's pull. That is why the removal case needed no code: it is not a
special case, it never was.

### What is coalesced, and what is not

Every row is merged the moment it arrives; only the telling of the screens is
gathered. A quarter of a second is long enough to collapse a bulk import on
another device into one rebuild per game, and short enough that the collector,
who is looking at the window the change came from, cannot see the two browsers
disagree. `announceCollectionChange` is called per game, and only for the games
that actually changed, so a change in a vault nobody is looking at is merged
without rebuilding the one they are - the same reason the sign-in's reconcile
announces per game.

### Reconnection, and the account that will not speak

Three separate things, because they fail in three different places.

1. **The socket drops.** The realtime client reconnects it and rejoins the
   channel on its own, and the rejoined channel reports itself live again.
2. **Every time the subscription goes live**, including that rejoin, the
   listener pulls every game. Realtime has no memory: a change made while the
   wire was down is never replayed, and no amount of subscribing brings it back.
   A pull does. The first subscription gets the same treatment, and it is not
   wasted there either - a sign-in's pull and a socket's join are not the same
   instant, and a change made between them has no other way in.
3. **A subscription the account will not accept** - a network that refuses
   websockets, a token it rejects, Realtime switched off for the project - is
   asked for again, waiting twice as long each time up to thirty seconds. The
   app keeps working meanwhile: the sign-in's pull still runs, the watcher still
   carries work up, and the only thing missing is the hearing. This is worth
   being exact about: **when Realtime is unavailable, this browser is back to
   the behaviour that shipped before this change** - up to the account in a
   second, down only on a reload. That is a floor, not a fallback that polls.

The catch-up is a `pull` and not a `sync`, because catching up is about what
arrived; what leaves is the push-side watcher's business on its own tick, and it
is the side that knows what this browser has already carried up.

### One trap worth naming

A subscription is accepted optimistically. The join reply says ok and echoes the
binding back **for any table, streamed or not**, and the verdict on whether this
client may be told about this table arrives afterwards on a system event - which
the Dart client forwards as a subscription error, and which the listener
therefore treats as a connection it has lost rather than as live. Measured on
this project, not reasoned about; see the proof below. Anything that reads a
subscription as a yes and stops there is reading nothing.

## The proof

`tool/account/prove_collection_realtime.py`. Three kinds of check, and none
implies another:

| Check | Why it is not implied by the others |
| --- | --- |
| SQL: `public.collection_entries` is in `supabase_realtime` | This is the only reading of membership anywhere in the file. Nothing the client can see settles it |
| SQL: the publication is a table list, and streams inserts, updates and deletes | `FOR ALL TABLES` would make `add table` impossible, and a publication without UPDATE would stream no removal - because a removal here is an update |
| SQL: the constraints, policy, grants and indexes are byte-for-byte what the tombstone migration left | The claim is "one publication change and nothing else". A step that also rewrote a policy would pass anything that only looked for the publication |
| Live: the join is accepted for the real table | It is also accepted for a table that does not exist, which is why it proves nothing on its own |
| Live: a nonexistent table is refused in the same words as a real one | The control that stops the previous line from being read as a publication check |
| Live, with a session: a row written for a probe account arrives, whole, and so does its removal | The only live proof of the whole chain: publication, policy, the account filter, and the new-record payload the merge reads |

The delivery check needs `SUPABASE_SECRET_KEY` - it creates a confirmed probe
account, signs in with the publishable key, subscribes as that account, writes
through PostgREST and waits for the events, then deletes the holding and the
account. Without the key it reports SKIP and says what is missing.

### What a run on this machine said

Run on 2026-09-18 from the Windows box this work was done on, with only the
publishable key - which is in the repository, on purpose, since it ships in the
web bundle. Nothing was applied and nothing was written.

~~~
--- SQL, as the owner ---
SKIP  sql_publication_streams_edits
        SUPABASE_DB_URL_POOLED is not set, or psql is not on PATH, so the
        publication cannot be read out of pg_catalog
SKIP  sql_collection_entries_is_in_the_publication
SKIP  sql_nothing_but_the_publication_changed
SKIP  sql_the_table_is_the_one_the_client_knows

--- Realtime, without a session ---
PASS  realtime_the_join_is_accepted_whatever_the_table
        the join answered ok and echoed the binding back - event *, table
        collection_entries, filter user_id=eq.00000000-... - which is what a
        subscribed channel looks like from the client, and is also what a
        channel that will never deliver anything looks like
PASS  realtime_the_verdict_does_not_name_the_publication
        a table that does not exist is refused with the same words as one that
        does - 'check Realtime is enabled for the given connect parameters' -
        so that message cannot be read as 'this table is not streamed'
SKIP  realtime_a_subscription_without_a_session_is_refused
        the publishable key alone cannot subscribe to this table ... Realtime
        checks the subscription as the client's role, and with no session there
        is no account for the row policy to match

--- Realtime, with a session ---
SKIP  realtime_a_change_reaches_a_signed_in_browser
        SUPABASE_SECRET_KEY is not set, so no probe account can be made

2 passed, 0 failed, 6 skipped
~~~

**So the publication state of the live project is not known from here.** The
migration is written to be safe either way - it does nothing if the table is
already streamed - and it must be applied, and this script re-run with
`--require-sql` and the admin key, from a machine that holds the credentials:

~~~sh
set -a; . /home/zixen/arcanum/supabase.env; set +a
psql "$SUPABASE_DB_URL_POOLED" -X -v ON_ERROR_STOP=1 \
  -f tool/account/0002_realtime_collection.sql
python3 tool/account/prove_collection_realtime.py --require-sql
~~~

`--require-sql` turns a skipped SQL section into a failure, so a green run can
only mean the publication was read and found correct. Without it, the four SQL
lines above are SKIPs and the run says so rather than passing quietly.

The one thing the run above did establish is the trap in the previous section,
with a live negative control rather than a citation: a subscription to a table
that does not exist is accepted at the join and refused a moment later with the
same sentence as a real one, so "the client subscribed" is not evidence that
anything will ever be delivered.

## Reversing it

`tool/account/0002_realtime_collection_down.sql`:

~~~sh
psql "$SUPABASE_DB_URL_POOLED" -X -v ON_ERROR_STOP=1 \
  -f tool/account/0002_realtime_collection_down.sql
~~~

Nothing is lost with it but the announcements. The table is untouched either
way - this migration never wrote to it - so every row, column, policy and grant
is exactly where it was. An open browser stops hearing what another browser
does, goes on carrying its own work up, and still catches up on the next
reload: a downgrade to the behaviour that shipped before this migration, not a
break. A subscription already open is refused at its next join rather than torn
down where it stands, and the client treats that as a connection it has lost -
it asks again, backs off, and the app goes on working.

## What the tests say

`test/features/collection_listener_test.dart`, on a real in-memory SQLite and a
fake account socket, with no live connection anywhere in it:

- a card added on another browser arrives while this one is open;
- a removal made on another browser hides the card here, and the row stays in
  the table because the row is what carries the removal;
- an older row from the account loses to newer work here, and announces
  nothing;
- a burst of fifty changes announces once, and not once per row;
- a change in another vault is merged and announced for that vault only;
- a connection that came back catches up on what it missed while it was down;
- an account that will not announce changes is asked again, and the catch-up
  runs when it finally accepts;
- a browser with no account asks for nothing at all.

## Files

- `tool/account/0002_realtime_collection.sql` - what is to be executed, with
  the reasoning inline.
- `tool/account/0002_realtime_collection_down.sql` - the reversal.
- `tool/account/prove_collection_realtime.py` - the proof above.
- Client: `lib/data/sync/account_changes.dart`,
  `lib/data/sync/account_collection.dart` (`gameOf`),
  `lib/data/sync/collection_sync.dart` (`mergeRow`, `pullChanged`),
  `lib/features/auth/collection_listener.dart`, `lib/main.dart`.
- Tests: `test/features/collection_listener_test.dart`.
