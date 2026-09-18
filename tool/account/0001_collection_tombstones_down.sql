-- Reversal of 0001_collection_tombstones.sql.
--
-- One statement, and it is not free. Dropping the column drops every deletion
-- recorded in it: a holding that was removed softly becomes a holding that is
-- present again, and the next pull on any device puts those cards back into
-- every collection. That is the bug this migration exists to fix, walked
-- backwards.
--
-- It was safe to run on 2026-09-19 only because no client had yet written a
-- tombstone: the column was minutes old and every row in the table was present.
-- Run it after the app has shipped this change and the deletions have to be
-- extracted first, or accepted as lost:
--
--   create table collection_tombstones_reversed as
--     select id, user_id, game, card_id, deleted_at
--       from public.collection_entries where deleted_at is not null;
--
-- Nothing else is undone, because nothing else was done. The column's comment
-- and the one existing row's other columns are untouched by the drop.

begin;

alter table public.collection_entries
  drop column if exists deleted_at;

commit;
