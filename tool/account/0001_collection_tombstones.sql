-- Arcanum account, migration step 1: a holding can be deleted, and the
-- deletion can travel.
--
-- The account-backed collection pushes and pulls holdings and never removes one,
-- which is safe but incomplete: a collector who removes a card on their phone
-- still has it on the account, so the next pull puts it back. The fix is not a
-- second code path - a tombstone is not a different kind of row - it is one
-- timestamp on the row that is already there. A deleted holding is the same
-- holding with deleted_at set, so it travels through the same upsert and the
-- same select the sync already does, and a later edit supersedes it by the same
-- updated_at rule that already decides every other conflict.
--
-- Null means present, not unknown. That is what makes the column safe to add to
-- a live table: every row that exists is a row somebody owns, so null is the
-- only correct value for all of them, and no backfill can be wrong.
--
-- Why no index. The sync's fetch has to read the tombstones as well as the
-- living rows - a deleted holding it cannot see is a deletion it cannot merge -
-- so a partial index on "deleted_at is null" would serve no query this app
-- makes, and the reads that do filter on it are already covered by
-- idx_entries_user_game. An index is a claim about which queries matter, and
-- this step has no such claim to make.
--
-- What this file does not do:
--   * it does not purge. Decided below, in the comment on the column.
--   * it touches no other column, no constraint, no policy and no grant. The
--     table's RLS posture already restricts every operation to the owner, and a
--     soft delete is an UPDATE like any other, so it is already covered.
--   * it deletes no row. There is one real holding in this table and it stays
--     exactly as it is; its deleted_at is null, which is what "present" means.
--
-- Reversal: 0001_collection_tombstones_down.sql. Read its header before running
-- it - it drops the deletions with the column.

begin;

alter table public.collection_entries
  add column deleted_at timestamptz;

comment on column public.collection_entries.deleted_at is
  'When this holding was removed from the collection, or null while it is still '
  'held. A tombstone rather than a deletion so that removing a card on one '
  'device removes it everywhere: the row keeps its place in the unique index '
  'and travels through the same push and pull as every other row. Re-adding the '
  'card clears this column and bumps updated_at on the same row, because the '
  'unique index on (user_id, game, card_id, finish, condition, language, binder) '
  'means the slot is still occupied and a second insert would not be a second '
  'copy but an error. Nothing purges these rows: a purged tombstone is a '
  'deletion that a device which has been offline for a month can undo, and the '
  'rows are a few dozen bytes each. If a purge is ever wanted it has to be '
  'justified against a retention window longer than any device stays away, and '
  'it is a separate migration.';

commit;
