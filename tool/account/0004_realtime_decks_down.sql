-- Reversal of 0004_realtime_decks.sql.
--
-- Two statements, and nothing is lost with them but the announcements. Neither
-- table is touched either way - this migration never wrote to either - so every
-- row, every column, every policy and every grant is exactly where it was, and
-- both tables simply stop being streamed.
--
-- What stops working, and what keeps working:
--   * an open browser stops hearing what another browser does to a deck. It goes
--     on carrying its own work up through the push-side watcher, and it still
--     catches up on the next reload, because the sign-in's pull owes nothing to
--     the publication. So this is a downgrade to the behaviour that shipped
--     before this migration - two browsers agreeing only once one of them is
--     reloaded - and not a break.
--   * a subscription already open is refused at its next join rather than torn
--     down where it stands, and the client's deck listener treats that as a
--     connection it has lost: it asks again, backs off, and the app goes on
--     working without it. Nothing needs to be restarted.
--   * nothing about the collection changes. public.collection_entries was put in
--     the publication by 0002, which has a reversal of its own, and this file
--     names it nowhere.
--
-- Written as a check rather than a bare DROP for the same reason the up file
-- guards its ALTERs: this is run on a database nobody has inspected first, and a
-- table that is not in the publication should make this a no-op rather than an
-- error. Each table is guarded on its own, so a database where only one of the
-- two was ever streamed is reversed completely rather than half way.

begin;

do $$
begin
  if exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'deck_cards'
  ) then
    alter publication supabase_realtime drop table public.deck_cards;
  end if;

  if exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'decks'
  ) then
    alter publication supabase_realtime drop table public.decks;
  end if;
end
$$;

commit;
