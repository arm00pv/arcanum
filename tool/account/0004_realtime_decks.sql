-- Arcanum account, migration step 4: the account announces a deck changing, the
-- way it already announces a holding changing.
--
-- The bug this closes is the one 0002 closed for the collection, one table pair
-- along. A browser carries its own work up to the account within about a second
-- and brings nothing down again until somebody reloads the page - and the reload
-- works, because a reload re-runs the sign-in, and a sign-in pulls. Two browsers
-- signed in to one account therefore disagree for as long as both stay open:
-- each shows its decks as they were when it signed in, plus whatever it has done
-- itself. Rename a deck on the laptop and the desktop goes on showing the old
-- name; add four Chieftains on the desktop and the laptop never hears about them
-- until it is reloaded.
--
-- Polling would have closed that without touching the database, and it is the
-- wrong shape for the reason 0002 gives: a request per device per interval, for
-- the life of the session, to be told that nothing has happened. The account can
-- say when something has, and being able to say it is not a table change - the
-- tables are exactly as 0003 left them - it is membership of the publication
-- Postgres streams logical replication from:
--
--   supabase_realtime
--
-- A table that is not in that publication is invisible to Realtime whatever the
-- client asks for. Creating a table and streaming it are two separate steps, and
-- the first one is the one people remember: 0003 created public.deck_cards and
-- deliberately left it out of here, because streaming the deck tables is this
-- step and not that one.
--
-- Why both tables, and not just the deck:
--
--   * public.decks carries what a deck row is edited by - the name, the format,
--     the notes, and the mark that says the deck has been deleted. A browser
--     that hears about a line and not about the deck would go on showing a
--     deleted deck, and a rename made on another browser would never arrive.
--   * public.deck_cards carries the contents, and its rows move independently:
--     adding one card to a deck stamps that line and the deck's updated_at, but
--     a line can also move on its own when it arrives from the account. A
--     browser subscribed to the deck rows alone would show a deck whose cards
--     are a pull out of date, which is the half of the feature a collector
--     notices first.
--
-- What this file does not do:
--   * it does not touch either table. No column, no constraint, no index, no
--     policy and no grant changes. The proof script asserts that with
--     fingerprints taken before and after - including a fingerprint of
--     public.collection_entries, which this migration must not touch either -
--     because the claim is "two publication changes and nothing else", not
--     "the migration ran".
--   * it does not set replica identity full, and that is a decision rather than
--     an omission, exactly as it was in 0002. A removal in either deck table is
--     an UPDATE - the row stays and deleted_at is stamped on it - so nothing
--     depends on a DELETE event arriving with its columns, which is the only
--     thing replica identity buys. It would cost the whole previous row in the
--     WAL for every card added to a deck and every count corrected, to serve
--     events this app never sends. And under row level security it would not
--     even work: the old record is reduced to the primary key whatever the
--     replica identity is, so an old-row payload is not something these tables
--     can offer a client at all. The consequence runs one way only, and it is
--     the way the app already works: everything the merge needs to weigh a deck
--     or a line is in the new record.
--   * it does not change a policy. Both tables' existing FOR ALL policy to the
--     owner - auth.uid() = user_id - is also the policy Realtime applies to a
--     subscription, so the filter a client asks with (user_id=eq.<account>) and
--     the rows it is allowed to be told about agree by construction. That is
--     also why deck_cards carries user_id on the line rather than reaching it
--     through a join to decks: a table with no user_id cannot be filtered by
--     account at all.
--   * it does not stream anything else. public.collection_entries was put in by
--     0002 and stays; the catalogue tables are not the account's and are not
--     mentioned here.
--   * it does not enable anything for the phone. Nothing on the phone opens a
--     socket either way - the listener is built only in the browser's branch of
--     main() - and this file is server-side shape, not client behaviour.
--
-- Reversal: 0004_realtime_decks_down.sql. One statement pair and nothing lost
-- but the announcements.

begin;

-- A check rather than a bare ALTER, for the reason 0002's is one: enabling
-- Realtime from the dashboard's Database -> Replication page does exactly this,
-- and a table that is already in the publication would make the plain statement
-- fail with an error that reads like a broken migration. The statement is
-- idempotent in effect; it should be idempotent to run.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'decks'
  ) then
    alter publication supabase_realtime add table public.decks;
  end if;

  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'deck_cards'
  ) then
    alter publication supabase_realtime add table public.deck_cards;
  end if;
end
$$;

commit;
