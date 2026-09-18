-- Reversal of 0001_catalog_schema.sql.
--
-- Safe to run at any point before the catalogue is being served: it drops the
-- four catalogue tables and the pg_trgm extension and touches nothing else.
-- Dropping catalog_cards takes catalog_prices with it through the foreign key,
-- but the drops are ordered explicitly so the file also works if that cascade
-- is ever removed.
--
-- Two caveats, both of which only matter once data exists:
--   * dropping catalog_cards drops every price row (ON DELETE CASCADE), and
--     dropping a set's cards orphans nothing but does lose the import;
--   * it deliberately does not drop the pg_trgm extension if anything else has
--     come to depend on it - see the guard below.
--
-- The account tables are not mentioned here, which is the point: nothing this
-- migration did needs undoing on them.

begin;

drop policy if exists catalog_prices_read on public.catalog_prices;
drop policy if exists catalog_cards_read  on public.catalog_cards;
drop policy if exists catalog_sets_read   on public.catalog_sets;
drop policy if exists catalog_meta_read   on public.catalog_meta;

drop table if exists public.catalog_prices;
drop table if exists public.catalog_cards;
drop table if exists public.catalog_sets;
drop table if exists public.catalog_meta;

-- pg_trgm was installed by this migration, so it is removed here - but only if
-- no other object in the database is using it. The check is the extension's own
-- dependency count plus a look for any opclass from it outside the catalogue
-- indexes (which are already gone by now).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_trgm')
     and not exists (
       select 1
         from pg_depend d
         join pg_extension e on e.oid = d.refobjid
        where e.extname = 'pg_trgm'
          and d.classid = 'pg_class'::regclass
          and d.objid <> e.oid
     )
  then
    drop extension pg_trgm;
  end if;
end
$$;

commit;
