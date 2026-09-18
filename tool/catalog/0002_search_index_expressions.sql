-- Arcanum catalogue, migration step 0b: the two trigram indexes move onto the
-- columns search actually compares.
--
-- Design: docs/catalogue-server-side.md, section 2.2. That section specified
-- the two GIN indexes on the lowered expression and step 0 built them as
-- written:
--
--   create index catalog_cards_name_trgm on public.catalog_cards using gin (lower(name) gin_trgm_ops);
--   create index catalog_cards_text_trgm on public.catalog_cards using gin (lower(coalesce(oracle_text, '')) gin_trgm_ops);
--
-- Section 4's catalog_search, the only reader these indexes exist for, compares
-- the raw columns:
--
--   where c.name ilike '%' || p_query || '%'
--      or c.oracle_text ilike '%' || p_query || '%'
--
-- A GIN index is matched by the expression in the predicate, not by an
-- expression that merely means the same thing, so 'name ILIKE ...' cannot use
-- an index on lower(name). Measured on the live database, on the 3,208 Lorcana
-- rows in public.catalog_cards, with all of step 0's indexes in place:
--
--   name ILIKE '%elsa%'             -> Seq Scan, 345 buffers, 3176 rows removed by filter
--   lower(name) LIKE '%elsa%'       -> Bitmap Index Scan on catalog_cards_name_trgm, 33 buffers
--
-- The index was not broken, it was answering a question nobody asks. This file
-- moves both indexes onto the columns section 4 reads, which is the whole of
-- the change: pg_trgm extracts trigrams from the lower-cased text whichever
-- case the column holds, so an index on name answers ILIKE exactly as the
-- lower(name) index did, and it answers a case-sensitive LIKE as well. Nothing
-- is given up at read time, and the index that was measured at 2.11 kB per row
-- stops being paid for in a currency nobody spends.
--
-- The second index is on oracle_text, not on coalesce(oracle_text, '').
-- Section 2.2's coalesce spelling was kept minus the lower() at first, and it
-- does not work either: with an index on coalesce(oracle_text, '') as the only
-- trigram index on the table, 'oracle_text ILIKE ...' still read the table, and
-- it took an index on the bare column to get a Bitmap Index Scan. A row whose
-- oracle_text is null has no trigrams to index and matches no ILIKE pattern, so
-- the coalesce buys nothing the planner can use; if step 4 ever writes the
-- predicate as coalesce(c.oracle_text, '') ILIKE ..., the index has to move
-- again, and this note is here so that is a decision rather than a surprise.
--
-- Both indexes are dropped and rebuilt in one transaction, which locks writes
-- for the duration. On 3,208 rows that is milliseconds. At the quarter of a
-- million rows section 7 anticipates it is minutes, and the alternative -
-- CREATE INDEX CONCURRENTLY, which cannot run inside a transaction - would
-- leave an invalid index behind on failure. The importer is the only writer of
-- this table, so the lock costs a poll nothing; whoever runs this against a
-- large catalogue should still run it between imports rather than during one.
--
-- This file does not touch catalog_cards_name, the btree on (game, lower(name)),
-- which answers equality on the lowered name - there the expression is what is
-- compared and the index matches. It adds no column, no policy and no grant.

begin;

-- Same names as step 0, so nothing that names these indexes has to change and
-- the reversal is the two definitions it replaced.
drop index public.catalog_cards_name_trgm;
create index catalog_cards_name_trgm on public.catalog_cards
  using gin (name extensions.gin_trgm_ops);

drop index public.catalog_cards_text_trgm;
create index catalog_cards_text_trgm on public.catalog_cards
  using gin (oracle_text extensions.gin_trgm_ops);

commit;
