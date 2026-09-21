-- Reversal of 0003_deck_sync.sql.
--
-- Four statements, and the shape of the account goes back to what it was: five
-- columns on public.decks, no public.deck_cards, and no default on
-- decks.user_id - which is the state this migration found, measured and
-- recorded in its own header rather than assumed.
--
-- What is lost, and it is not nothing even though the tables are empty today:
--
--   * every deck's sync_id, which is the identity the client minted and the
--     only thing that ties a device's deck to the account's row. A deck whose
--     sync_id is dropped cannot be matched to its copy on any device, and the
--     next push under the new shape would insert a second deck rather than
--     update the one that is there. So the column can be dropped for free only
--     while no client has ever pushed a deck - which is the state today, and
--     will not be the state after step 2 ships.
--   * every row of public.deck_cards, which is a deck's entire contents. There
--     is no other copy of a pushed deck's list anywhere: the local tables are
--     the only other place it exists, on the devices that have it.
--   * the deletions and the edits recorded in deleted_at and in the three
--     field clocks. A deck deleted softly becomes a deck that is present again
--     and the next pull puts it back on every device - the bug 0001 exists to
--     fix, walked backwards, and 0001_collection_tombstones_down.sql carries
--     the extraction query to copy the marks out first. The equivalent here is:
--
--       create table deck_sync_reversed as
--         select user_id, sync_id, name_at, format_at, notes_at, deleted_at
--           from public.decks where deleted_at is not null;
--
--   * the grants, the policy, the index and the row level security flag on
--     public.deck_cards, all of which a DROP TABLE takes with the table itself.
--     Nothing else in this file has to undo them.
--
-- Nothing else is undone, because nothing else was done. public.collection_entries
-- is not mentioned by this file at all - no column, no policy, no grant, no row -
-- and neither is any part of public.decks the up migration did not add.
--
-- Dropping the default on decks.user_id is not cosmetic: a client that has
-- learned to omit the owner, the way the collection's push already does, gets a
-- not-null violation against the same table once this has run. That is the
-- design's other answer to the missing default - the client sends the owner it
-- already knows from its session - and it is the client's change to make, not
-- this file's.

begin;

-- The contents first: deck_cards holds the foreign key to the pair the unique
-- constraint below provides, so it is the thing that has to go before the
-- constraint it depends on.
drop table if exists public.deck_cards;

alter table public.decks
  drop constraint if exists decks_user_sync;

alter table public.decks
  drop column if exists sync_id,
  drop column if exists format_id,
  drop column if exists notes,
  drop column if exists updated_at,
  drop column if exists deleted_at,
  drop column if exists name_at,
  drop column if exists format_at,
  drop column if exists notes_at;

alter table public.decks
  alter column user_id drop default;

commit;
