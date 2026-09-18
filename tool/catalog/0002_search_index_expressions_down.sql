-- Reversal of 0002_search_index_expressions.sql.
--
-- It puts the two trigram indexes back on the expressions step 0 built them on.
-- That restores the previous state faithfully, which is what a reversal is for,
-- and it also restores everything that was wrong with it: after this runs,
-- catalog_search reads the table instead of the index again. Run it to undo
-- 0002, not to fix anything.
--
-- Nothing else needs undoing. 0002 changed two index definitions and no column,
-- no policy, no grant and no table, so catalog_cards, the account tables and
-- pg_trgm itself are all exactly as they were.

begin;

drop index if exists public.catalog_cards_name_trgm;
create index catalog_cards_name_trgm on public.catalog_cards
  using gin (lower(name) extensions.gin_trgm_ops);

drop index if exists public.catalog_cards_text_trgm;
create index catalog_cards_text_trgm on public.catalog_cards
  using gin (lower(coalesce(oracle_text, '')) extensions.gin_trgm_ops);

commit;
