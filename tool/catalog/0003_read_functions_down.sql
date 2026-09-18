-- Reversal of 0003_read_functions.sql.
--
-- It drops the three read functions and puts the number index back the way 0001
-- created it. Nothing else needs undoing: 0003 added no table, no column, no
-- policy and no privilege on the tables, so catalog_cards, catalog_sets, the
-- account tables and the catalogue's own posture are exactly as they were.
--
-- After this runs the reads are back to the PostgREST filters of step 2, which
-- means two things the client depends on stop working: SupabaseCatalogTable's
-- catalog_cards_by_ids and catalog_search calls both fail, and the router falls
-- back to the providers. That is the designed failure - the shared catalogue is
-- an optimisation with a working fallback - so a reversal here costs a browser
-- its fast sign-in and nothing else.
--
-- The index swap is undone rather than left behind, because it exists only for
-- the predicate that is being dropped with the function: an index on
-- lower(number_bare) with nothing comparing lower(number_bare) is a nightly
-- write cost for no reader at all. It is created before the other is dropped, so
-- the table is never without one.
--
-- Dropping the functions also drops their own grants, which is why none are
-- revoked explicitly: a dropped function has no ACL to revoke.

begin;

drop function if exists public.catalog_cards_by_number(text, text[], text, boolean, integer);
drop function if exists public.catalog_search(text, text, integer);
drop function if exists public.catalog_cards_by_ids(text, text[]);

create index if not exists catalog_cards_number_bare
  on public.catalog_cards (game, number_bare);

drop index if exists public.catalog_cards_number_nocase;

commit;
