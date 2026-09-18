-- Arcanum account, migration step 2: the account announces a change rather than
-- waiting to be asked for one.
--
-- The bug this closes is on the client, and the server's half of the fix is one
-- line. A browser carried its own work up to the account within about a second
-- and brought nothing down again until somebody reloaded the page - and the
-- reload worked, because a reload re-runs the sign-in, and a sign-in pulls. Two
-- browsers signed in to one account therefore disagreed for as long as both
-- stayed open: each showed the collection as it had been when it signed in,
-- plus whatever it had done itself.
--
-- Polling would have closed that without touching the database, and it is the
-- wrong shape: a request per device per interval, for the life of the session,
-- to be told that nothing has happened. The account can say when something has,
-- and being able to say it is not a table change - the table is exactly as it
-- was - it is membership of the publication Postgres streams logical
-- replication from:
--
--   supabase_realtime
--
-- A table that is not in that publication is invisible to Realtime whatever the
-- client asks for. Creating a table and streaming it are two separate steps,
-- and the first one is the one people remember.
--
-- What this file does not do:
--   * it does not touch the table. No column, no constraint, no index, no
--     policy and no grant changes. The proof script asserts that with
--     fingerprints taken before and after, because the claim is "one
--     publication change and nothing else", not "the migration ran".
--   * it does not set replica identity full, and that is a decision rather than
--     an omission. A removal here is an UPDATE - the row stays and deleted_at
--     is stamped on it - so nothing depends on a DELETE event arriving with its
--     columns, which is the only thing replica identity buys. It would cost the
--     whole previous row in the WAL for every card added and every quantity
--     corrected, to serve events this app never sends. And under row level
--     security it would not even work: the old record is reduced to the primary
--     key for a policy-protected table whatever the replica identity is, so an
--     old-row payload is not something this table can offer a client at all.
--     The consequence runs one way only, and it is the way the app already
--     works: everything a client needs to merge a change is in the new record.
--   * it does not stream anything else. decks stays out, because nothing has
--     asked for it.
--   * it changes no policy. The table's existing FOR ALL policy to the owner -
--     auth.uid() = user_id - is also the policy Realtime applies to a
--     subscription, so the filter a client asks with and the rows it is allowed
--     to be told about agree by construction. It is worth noticing that the
--     policy is on a column this app never writes: no edit can make a row
--     invisible to the account that owns it, which is a thing that can happen
--     to a policy written on a status column.
--
-- Reversal: 0002_realtime_collection_down.sql. It is cheap and it is complete.

begin;

-- A check rather than a bare ALTER, because enabling Realtime from the
-- dashboard's Database -> Replication page does exactly this, and a table that
-- is already in the publication would make the plain statement fail with an
-- error that reads like a broken migration. The statement is idempotent in
-- effect; it should be idempotent to run.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'collection_entries'
  ) then
    alter publication supabase_realtime add table public.collection_entries;
  end if;
end
$$;

commit;
