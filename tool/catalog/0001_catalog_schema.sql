-- Arcanum catalogue, migration step 0: schema and RLS posture.
--
-- Design: docs/catalogue-server-side.md, sections 2 and 2.4, and the two price
-- and meta tables in section 5. That document is the specification; this file
-- is its transcription plus the notes below, which record the two places where
-- the environment forced a spelling the document does not mention.
--
-- What this file does NOT do, on purpose:
--   * it writes no catalogue data - the tables stay empty until step 1;
--   * it defines no functions - catalog_search and catalog_cards_by_number are
--     step 4 and are not needed to fix the posture;
--   * it touches neither public.decks nor public.collection_entries, whose
--     owner-only policies are the thing this step must leave alone.
--
-- Notes on the environment, found by inspecting the live project first:
--
--   1. Supabase's default privileges in schema public grant ALL on every newly
--      created table to anon, authenticated and service_role (pg_default_acl,
--      defaclrole postgres). So these four tables are born with INSERT, UPDATE
--      and DELETE granted to the publishable key's role. The REVOKE in section
--      2.4 is therefore load bearing rather than tidy: without it, the
--      publishable key would hold DML grants on a table that ships in the web
--      bundle. Row level security would still refuse the writes, but the
--      posture the design asks for is both barriers, not one.
--
--   2. PUBLIC is revoked from as well, which the document does not spell out.
--      It is a no-op today (Supabase grants nothing to PUBLIC on new tables),
--      and it is written down so the posture does not depend on that staying
--      true.
--
-- Everything runs in one transaction: either the four tables, their indexes,
-- their grants and the nine catalog_meta rows all exist, or nothing changed.
--
-- The importer connects as postgres, the owner of these tables, over the
-- session pooler. postgres has BYPASSRLS on this project, so the write path
-- never consults these policies, which is exactly what section 2.4 describes.
-- RLS is deliberately not FORCEd: forcing it would apply the policies to the
-- owner as well and there is no write policy for good reason.

begin;

-- Needed before the trigram indexes below. The document puts it in the
-- extensions schema, which is where this project keeps pgcrypto and uuid-ossp
-- already; public therefore stays free of extension objects.
create extension if not exists pg_trgm with schema extensions;

-- ---------------------------------------------------------------------------
-- 2.1 Sets
-- ---------------------------------------------------------------------------

create table public.catalog_sets (
  game                   text        not null,           -- CardGame.id: 'mtg', 'onepiece', ...
  code                   text        not null,           -- as the app stores it: folded to lower case
  id                     text        not null,           -- the provider's own set id
  name                   text        not null,
  set_type               text        not null default 'unknown',
  released_at            date,
  card_count             integer     not null default 0, -- 0 means "the provider does not say"
  printed_size           integer,
  icon_svg_uri           text,
  logo_uri               text,
  series                 text,
  digital                boolean     not null default false,
  foil_only              boolean     not null default false,
  nonfoil_only           boolean     not null default false,
  parent_set_code        text,
  block_code             text,
  block                  text,
  collector_number_start integer,
  cards_revision         bigint      not null default 0,
  cards_checksum         text,
  card_row_count         integer     not null default 0,
  catalogued_at          timestamptz,
  retired_at             timestamptz,
  updated_at             timestamptz not null default now(),
  primary key (game, code)
);

create index catalog_sets_game_released on public.catalog_sets (game, released_at desc);
create index catalog_sets_type          on public.catalog_sets (game, set_type);

-- ---------------------------------------------------------------------------
-- 2.2 Cards
-- ---------------------------------------------------------------------------

create table public.catalog_cards (
  game               text   not null,
  id                 text   not null,      -- provider id, exactly as the app builds it
  oracle_id          text,
  set_code           text   not null,
  set_name           text,
  name               text   not null,
  collector_number   text   not null,
  collector_sort     integer not null default 0,
  rarity             text   not null default 'unknown',
  layout             text,
  type_line          text,
  oracle_text        text,
  mana_cost          text,
  cmc                double precision,
  colors             text   not null default '',   -- comma-joined, as SQLite stores it
  color_identity     text   not null default '',
  artist             text,
  flavor_text        text,
  image_small        text,
  image_normal       text,
  image_large        text,
  image_art_crop     text,
  image_png          text,
  back_image_small   text,
  back_image_normal  text,
  digital            boolean not null default false,
  promo              boolean not null default false,
  reprint            boolean not null default false,
  reserved           boolean not null default false,
  full_art           boolean not null default false,
  booster            boolean not null default false,
  foil               boolean not null default false,
  nonfoil            boolean not null default false,
  edhrec_rank        integer,
  released_at        date,
  extras             jsonb,
  updated_at         timestamptz not null default now(),
  primary key (game, id),
  foreign key (game, set_code) references public.catalog_sets (game, code)
);

create index catalog_cards_set    on public.catalog_cards (game, set_code, collector_sort, collector_number);
create index catalog_cards_name   on public.catalog_cards (game, lower(name));
create index catalog_cards_oracle on public.catalog_cards (game, oracle_id);
create index catalog_cards_number on public.catalog_cards (game, set_code, collector_number);
create index catalog_cards_rarity on public.catalog_cards (game, rarity);

-- Note added later, when 0002_search_index_expressions.sql was written: these two
-- index definitions are the ones step 0 ran, and they were superseded. Section
-- 2.2 has since been corrected and the indexes now stand on the raw name and
-- oracle_text columns, which is what section 4's search compares; a trigram index
-- on an expression the predicate does not use is never chosen by the planner.
-- This file is left as it ran - if it is ever reversed and applied again, the two
-- indexes come back on the lowered expressions and 0002 has to be applied again
-- after it.
--
-- The operator class is spelled extensions.gin_trgm_ops rather than the bare
-- gin_trgm_ops of the document. Both resolve in this project - extensions is on
-- the search_path - but the qualified form does not depend on that, and an
-- index definition is a poor place to find out that a search_path changed.
create index catalog_cards_name_trgm on public.catalog_cards
  using gin (lower(name) extensions.gin_trgm_ops);
create index catalog_cards_text_trgm on public.catalog_cards
  using gin (lower(coalesce(oracle_text, '')) extensions.gin_trgm_ops);

-- ---------------------------------------------------------------------------
-- 2.3 The two folding rules
--
-- The expression for code_folded mirrors Codes.separators in
-- lib/core/utils/codes.dart - ['-', ' ', '.', '/', '_', ':'] - and not
-- Codes.fold, which drops everything that is not a-z0-9. A stored column is
-- compared with foldedSql, so the server must fold the way foldedSql does or
-- the same query answers differently depending on which path served it.
-- ---------------------------------------------------------------------------

alter table public.catalog_sets add column code_folded text
  generated always as (
    replace(replace(replace(replace(replace(replace(
      lower(code), '-', ''), ' ', ''), '.', ''), '/', ''), '_', ''), ':', '')
  ) stored;

-- Zero padding is a separate rule from separators and stays separate: Digimon
-- prints '001' where Magic prints '1', and the local DAO compares
-- ltrim(x, '0') on both sides. Materialised so it can be indexed.
alter table public.catalog_cards add column number_bare text
  generated always as (ltrim(collector_number, '0')) stored;

create index catalog_sets_code_folded on public.catalog_sets (game, code_folded);
create index catalog_cards_number_bare on public.catalog_cards (game, number_bare);

-- ---------------------------------------------------------------------------
-- 5. Prices and meta
-- ---------------------------------------------------------------------------

create table public.catalog_prices (
  game        text not null,
  card_id     text not null,
  kind        text not null check (kind in ('finish', 'secondary')),
  code        text not null,          -- a CardFinish.code, or 'eur', 'tix', 'ebay', ...
  price       numeric(12,2) not null,
  source      text not null,          -- 'scryfall', 'tcgdex', 'ygoprodeck', 'lorcast', 'tcgcsv'
  observed_on date not null,
  primary key (game, card_id, kind, code),
  foreign key (game, card_id) references public.catalog_cards (game, id) on delete cascade
);

create table public.catalog_meta (
  game               text primary key,
  sets_revision      bigint not null default 0,
  prices_revision    bigint not null default 0,
  set_count          integer not null default 0,
  card_count         integer not null default 0,
  sets_updated_at    timestamptz,
  prices_observed_on date,
  last_import_ok     boolean not null default false,
  last_import_note   text,
  source             text
);

-- The nine rows the client reads at boot. They are written now, empty of
-- counts, so that "we have never imported this game" is a row with
-- last_import_ok = false rather than a missing row the client has to
-- interpret. CardGame.id in lib/domain/models/card_game.dart, in the order the
-- enum declares them.
insert into public.catalog_meta (game) values
  ('mtg'),
  ('pokemon'),
  ('lorcana'),
  ('yugioh'),
  ('onepiece'),
  ('swu'),
  ('digimon'),
  ('dragonball'),
  ('gundam')
on conflict (game) do nothing;

-- ---------------------------------------------------------------------------
-- 2.4 RLS for shared read-only data
--
-- The catalogue is public data, so the policy per table is one line with no
-- per-row condition. Everything else is switched off.
-- ---------------------------------------------------------------------------

alter table public.catalog_sets   enable row level security;
alter table public.catalog_cards  enable row level security;
alter table public.catalog_prices enable row level security;
alter table public.catalog_meta   enable row level security;

-- No role but the importer may write, and the importer connects as the owner
-- and bypasses RLS. Both barriers are wanted: no DML grant, and no write
-- policy. A single stray grant insert to anon would let anyone holding the
-- publishable key rewrite the catalogue every browser reads.
revoke all on public.catalog_sets, public.catalog_cards,
              public.catalog_prices, public.catalog_meta
  from anon, authenticated, public;

grant select on public.catalog_sets, public.catalog_cards,
                public.catalog_prices, public.catalog_meta
  to anon, authenticated;

create policy catalog_sets_read   on public.catalog_sets   for select to anon, authenticated using (true);
create policy catalog_cards_read  on public.catalog_cards  for select to anon, authenticated using (true);
create policy catalog_prices_read on public.catalog_prices for select to anon, authenticated using (true);
create policy catalog_meta_read   on public.catalog_meta   for select to anon, authenticated using (true);

commit;
