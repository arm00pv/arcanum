-- Reversal of 0002_realtime_collection.sql.
--
-- One statement, and nothing is lost with it but the announcements. The table
-- is untouched either way - this migration never wrote to it - so every row,
-- every column, every policy and every grant is exactly where it was, and a
-- collection is never in the publication.
--
-- What stops working, and what keeps working:
--   * an open browser stops hearing what another browser does. It goes on
--     carrying its own work up, and it still catches up on the next reload,
--     because the sign-in's pull and the push side's watcher owe nothing to the
--     publication. So this is a downgrade to the behaviour that shipped before
--     this migration, not a break.
--   * a subscription already open is refused at its next join rather than
--     torn down where it stands, and the client's listener treats that as a
--     connection it has lost: it asks again, backs off, and the app goes on
--     working without it. Nothing needs to be restarted.
--
-- Written as a check rather than a bare DROP for the same reason the up file
-- guards its ALTER: this is run on a database nobody has inspected first, and
-- a table that is not in the publication should make this a no-op rather than
-- an error.

begin;

do $$
begin
  if exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'collection_entries'
  ) then
    alter publication supabase_realtime drop table public.collection_entries;
  end if;
end
$$;

commit;
