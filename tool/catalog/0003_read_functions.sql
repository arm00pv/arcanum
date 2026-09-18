-- Arcanum catalogue, migration step 4: the three reads that are a function
-- rather than a filter.
--
-- Design: docs/catalogue-server-side.md, section 4, and the step 4 row of the
-- migration list in section 8. Step 2 built the whole read path out of PostgREST
-- filters, which answer every question a filter can express - a set list, a
-- set's printings, one id, one oracle id. These three cannot be written as one,
-- and the first of them the design calls "probably the largest user-visible
-- improvement in this document" and then never schedules:
--
--   catalog_cards_by_ids     the batched read a sign-in resolves a collection
--                            through. A browser that has just signed in holds
--                            thousands of holdings, which name their cards by id,
--                            and no catalogue. Before this it asked about them
--                            by pasting ids into a URL filter, which is one
--                            request per 200 ids because that is where a request
--                            line runs out; the ids now travel in the body.
--
--   catalog_search           free text over a whole game. This is the read the
--                            two trigram indexes of section 2.2 exist for, and
--                            the only one that needs the catalogue rather than
--                            this browser's cache of it.
--
--   catalog_cards_by_number  a collector number, the way a collector types it.
--                            The grammar stays in Dart - CollectorQuery.parse is
--                            the only implementation of it - and the candidates
--                            it produced arrive here as arguments.
--
-- All three are language sql, stable, security invoker, with a search_path, as
-- section 2.4 requires: they run with the caller's rights, so the row level
-- security policies of step 0 are what let them read, and there is no security
-- definer bypass anywhere in the read path. They return setof catalog_cards, so
-- a row from an RPC is the same row a select would have answered with and the
-- client's mapper never learns which of the two it is reading.
--
-- Everything runs in one transaction, so either all three functions and the
-- index below exist or nothing changed.
--
-- What this file does NOT do: it does not add a table, a column or a policy, it
-- does not touch the account tables, and it writes no catalogue data.

begin;

-- ---------------------------------------------------------------------------
-- catalog_cards_by_ids
--
-- One request for a list of ids, however long the list is. The filter this
-- replaces was a PostgREST 'id=in.(...)' in a URL, and the ids did not fit:
-- SupabaseCatalogTable split them at 3,500 characters of filter, which for
-- Lorcana's 36-character ids is under a hundred per request. The array arrives
-- in the body instead, where nothing caps it but the response, so the only bound
-- left is the one the client chooses for its own reasons.
--
-- Ordered by id so that two identical calls answer identically. The caller keys
-- the answer by id and does not depend on the order, but an unordered setof is a
-- different plan away from a different answer, and a proof that compares two of
-- them deserves better than that.
--
-- The plan is an Index Scan on catalog_cards_pkey over the (game, id) prefix -
-- measured, see tool/catalog/prove_catalogue_reads.py - which is what makes this
-- cheap enough to be the read a whole collection is reconciled through.
-- ---------------------------------------------------------------------------

create or replace function public.catalog_cards_by_ids(
  p_game text,
  p_ids  text[]
) returns setof public.catalog_cards
language sql
stable
security invoker
set search_path = public, extensions
as $$
  select c.*
    from public.catalog_cards c
   where c.game = p_game
     and c.id = any (p_ids)
   order by c.id;
$$;

-- ---------------------------------------------------------------------------
-- catalog_search
--
-- Section 4's function, spelled exactly as section 4 spells it, because the two
-- ILIKEs below are not merely what selects the rows: they are the expressions
-- the two trigram indexes of 0002 are on. Wrapping either of them in lower() or
-- coalesce() answers the same question and reads the whole table - 0002 measured
-- that on these rows before it moved the indexes, and the proof repeats the
-- measurement so the next person to 'tidy' this predicate finds out before the
-- catalogue is a quarter of a million rows.
--
-- The query is escaped here rather than by the caller. This is a public endpoint
-- reachable with the publishable key that ships inside the web bundle, so a
-- caller that forgets is not an acceptable design: a collector typing '%' must
-- search for a percent sign, and a search for literally every card in the game
-- is one keystroke away otherwise. The backslash goes first, because it is
-- LIKE's own escape character and escaping it afterwards would escape the
-- escapes. Both characters that mean something to LIKE are then quoted.
--
-- The ordering is CatalogDao.searchCached's ordering, translated: a name that
-- starts with the query, then a name that contains it, then the newest printing.
-- The local path and this one must answer in the same order or the same search
-- would look different depending on which path served it.
--
-- The limit is clamped rather than rejected: a limit of 0 is a caller that meant
-- "no preference", and 200 is as much as a search screen can render. Supabase
-- caps a PostgREST response at 1,000 rows; this is well inside it.
-- ---------------------------------------------------------------------------

create or replace function public.catalog_search(
  p_game  text,
  p_query text,
  p_limit integer default 80
) returns setof public.catalog_cards
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with escaped as (
    select replace(replace(replace(coalesce(p_query, ''), '\', '\\'), '%', '\%'), '_', '\_') as q
  )
  select c.*
    from public.catalog_cards c, escaped e
   where c.game = p_game
     and (c.name ilike '%' || e.q || '%'
          or c.oracle_text ilike '%' || e.q || '%')
   order by (c.name ilike e.q || '%') desc,          -- a name that starts with it
            (c.name ilike '%' || e.q || '%') desc,  -- then a name that contains it
            c.released_at desc nulls last            -- then the newest printing
   limit least(greatest(coalesce(p_limit, 80), 1), 200);
$$;

-- ---------------------------------------------------------------------------
-- catalog_cards_by_number
--
-- Section 4's function, with one deliberate departure recorded at the bottom of
-- this comment.
--
-- The parse happens in Dart and only in Dart. CollectorQuery.parse already
-- decides what part of "LOB-EN001" is a set code ("loben" first, then "lob", and
-- only the catalogue knows which), what the number is ("001"), and whether the
-- query stands on its own; a second grammar in SQL would be a second thing to
-- get wrong, and the two would disagree about "Mewtwo 2" eventually.
--
-- The set candidates are folded already - Codes.fold drops everything outside
-- a-z0-9 - so they are compared against code_folded, which is the generated
-- column of 0001 built from Codes.separators. array_position is the ranking: the
-- caller puts its best guess first, and that is the order the answer comes back
-- in. A candidate that matches no set is simply not in the cte, which is what
-- makes an unknown code (with p_standalone false) answer with nothing rather
-- than with the whole game.
--
-- The number is compared twice on purpose. The exact comparison is what makes
-- '001' and '001' the same printing and ranks it first; the folded comparison is
-- what makes '001' and '1' the same printing, because Digimon pads and Magic
-- does not, and it folds case as well - see the departure below.
--
-- The departure. Section 4 compares number_bare to ltrim(p_number, '0') both
-- ways round, case sensitively, and that is a bug rather than a simplification:
-- CatalogDao.searchByNumber - the implementation this function exists to agree
-- with - compares "collector_number = ? COLLATE NOCASE". Thirteen collector
-- numbers in the imported Lorcana catalogue carry letters ('1f', '24B', '25ja',
-- '125f'), so a collector typing '24b' is answered by their own phone's SQLite
-- and by nothing on the server: the same query answering differently depending
-- on which path served it, which is the failure section 2.3 was written to
-- prevent. lower() on both sides is one line and no scan, because 0003 also
-- replaces the index that comparison used with one on the expression it now
-- compares - the same lesson 0002 recorded for search, on a different index.
--
-- The limit is clamped for the same reason search's is.
-- ---------------------------------------------------------------------------

create or replace function public.catalog_cards_by_number(
  p_game            text,
  p_code_candidates text[],
  p_number          text,
  p_standalone      boolean,
  p_limit           integer default 80
) returns setof public.catalog_cards
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with matched as (
    select s.code,
           coalesce(array_position(p_code_candidates, s.code_folded), 9999) as rank
      from public.catalog_sets s
     where s.game = p_game
       and s.code_folded = any (coalesce(p_code_candidates, '{}'::text[]))
  )
  select c.*
    from public.catalog_cards c
    left join matched m on m.code = c.set_code
   where c.game = p_game
     and (coalesce(p_standalone, false) or m.code is not null)
     and (c.collector_number = p_number
          or lower(c.number_bare) = lower(ltrim(p_number, '0')))
   order by (c.collector_number = p_number) desc,
            m.rank,
            c.released_at desc nulls last,
            c.set_code, c.collector_sort, c.collector_number
   limit least(greatest(coalesce(p_limit, 80), 1), 200);
$$;

-- ---------------------------------------------------------------------------
-- The index the number read compares against
--
-- 0001 created catalog_cards_number_bare on (game, number_bare) for section 4's
-- predicate. The predicate now compares lower(number_bare), and a btree index is
-- matched by the expression in the comparison and by nothing that merely means
-- the same thing - so the old index would sit there unused while the read fell
-- back on the (game, set_code, collector_number) index or, worse, on the table.
-- It is replaced rather than joined: two indexes on one column where only one
-- can ever be chosen is a write cost paid nightly for nothing.
--
-- The new index is created before the old one is dropped, so there is no moment
-- at which the read has no index to use.
--
-- number_bare itself is untouched, deliberately. Its expression is asserted
-- against tool/catalog/fold_vectors.json by two committed proofs, and changing
-- the column to fold case would change what those vectors mean. An index on the
-- expression the predicate uses gets the same answer without moving the rule.
-- ---------------------------------------------------------------------------

create index if not exists catalog_cards_number_nocase
  on public.catalog_cards (game, lower(number_bare));

drop index if exists public.catalog_cards_number_bare;

-- ---------------------------------------------------------------------------
-- Who may call them
--
-- Postgres grants EXECUTE on a new function to PUBLIC, so these three would be
-- callable by anyone with the publishable key whether or not this file said so.
-- Step 0's posture is written down rather than inherited - the tables revoke
-- from anon, authenticated and PUBLIC and then grant SELECT back, so that the
-- posture does not depend on a default staying what it is - and the functions
-- follow the same rule. EXECUTE to anon and authenticated is exactly what a
-- PostgREST RPC needs and it is all they get; these are security invoker, so the
-- grant is permission to ask, never permission to read.
-- ---------------------------------------------------------------------------

revoke all on function public.catalog_cards_by_ids(text, text[]) from public;
revoke all on function public.catalog_search(text, text, integer) from public;
revoke all on function public.catalog_cards_by_number(text, text[], text, boolean, integer) from public;

grant execute on function public.catalog_cards_by_ids(text, text[]) to anon, authenticated;
grant execute on function public.catalog_search(text, text, integer) to anon, authenticated;
grant execute on function public.catalog_cards_by_number(text, text[], text, boolean, integer) to anon, authenticated;

commit;
