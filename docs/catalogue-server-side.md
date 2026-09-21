# The catalogue, on the server

Status: design. Nothing here is implemented. Written against branch `web/M0-spike`.

## The decision in one paragraph

The card catalogue becomes a shared, read-only set of tables in the project's
Supabase Postgres, filled by the nightly jobs that already run on
`zapp.sytes.net`. A browser reads it through PostgREST and writes what it reads
into the SQLite it already keeps in IndexedDB, so every screen, DAO and analytic
in the app is untouched. The phone keeps asking the five providers and keeps its
own catalogue, because it has no account and must work with no network. The
existing `CardCatalog` interface is the seam: a server-backed implementation
sits beside the five provider clients, and a router picks between them per call,
falling back to the provider whenever the server is unreachable.

## 1. What moves, what stays

The catalogue is the only part of the app that is the same for everybody. That is
the whole reason to host it: a browser should not download Magic's 1,049 sets, and
then a set's 135 cards, to answer a question whose answer is identical for every
other collector. The collection, the decks and the analytics are the opposite -
they belong to one person, they are already synced (`collection_entries`,
`decks`), and they are computed on the device on purpose.

| Moves to Postgres | Stays on the device |
| --- | --- |
| Set lists, all nine games (1,049 Magic sets, 218 Pokemon, 1,035 Yu-Gi-Oh! rows, 23 Lorcana, the tcgcsv groups) | The collection, binders, wants, decks, lots, sales, sealed holdings |
| Printing rows: names, type lines, rules text, art URLs, rarity, flags, `extras` | Price history - both the app's own daily snapshots and the per-card series the companion already serves |
| Current market prices, per printing and finish | Portfolio snapshots, valuation, cost basis, every indicator and forecast |
| A search index over names and rules text | The image bytes themselves; only their URLs travel, and the browser caches them through `cached_network_image` |
| | Scanning, backups, alerts, the vault page |

Three things follow from that split and are worth stating plainly.

**Completion figures stay local.** `CatalogDao.setCompletion` counts binder slots
from the locally cached printings and joins the local collection. The server never
joins the catalogue to a user's holdings - not even to compute a percentage -
because that join is the one that would turn a public read endpoint into a way to
ask questions about somebody's collection. The Sets tab therefore shows real
progress only for sets whose cards are already on the device, exactly as it does
today.

**The phone does not change.** It has no account, it is offline-first, and its
SQLite is the source of truth. It keeps fetching from Scryfall, TCGdex,
YGOPRODeck, Lorcast and tcgcsv, keeps its seven-day set TTL, and keeps working
with the radio off. Two rules protect that: the shared catalogue is never a
dependency of the phone, and the provider path is never deleted. If the companion
later proxies the same read API over its own token (section 8, step 7), that is an
optimisation for phones, not a requirement of the app.

**Nothing about the wire shape changes for the app.** A server row is a local row.
The Postgres columns are named and typed as the SQLite columns are, so the mapper
that turns a row into a `TcgCard` is used by both paths rather than written a
third time.

## 2. The schema

Four tables in `public`, prefixed `catalog_` so they are never confused with the
account tables. The prefix rather than a `catalog` schema is deliberate: PostgREST
only exposes schemas listed in the project's API settings, and putting the tables
in a new schema means a dashboard change that can silently make every client read
nothing.

### 2.1 Sets

~~~sql
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
~~~

`cards_revision` is the invalidation signal for one set (section 6).
`cards_checksum` is the sha256 of the canonical card list the importer last wrote;
comparing it to today's means a set that has not changed is not rewritten at all.
`catalogued_at` and `card_row_count` exist so the importer can reproduce the app's
`isCatalogued` rule - a set whose provider publishes no count is catalogued once
anything is stored - and so a client can tell "we asked and there is nothing" from
"we have never asked". `retired_at` is a soft delete: a set withdrawn upstream
disappears from browsing but its rows stay, so the holdings that name its card ids
still resolve.

### 2.2 Cards

~~~sql
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
~~~

The column list is the SQLite `cards` table with three changes, each of which
earns itself. `prices_json` and `prices_updated_at` are gone, because prices are
volatile and live in their own table (section 5). `extras` is `jsonb` rather than a
JSON string, so it can be indexed and inspected later. And the `faces`
reconstruction stays lossy in exactly the way it is lossy today: the back face
keeps its images and nothing else. Fixing that is a change to `TcgCard` rather
than to a catalogue, and a schema that quietly invented a shape for it would break
the mapper.

Booleans are the one place the "same shape as SQLite" rule is not honoured,
because `boolean` is the honest type and Postgres should keep it. The adapter that
reads a PostgREST row converts them to the 0/1 the mapper expects - one function,
in one place, with a test.

Indexes, chosen from the queries in section 4 rather than from the columns:

~~~sql
create index catalog_cards_set    on public.catalog_cards (game, set_code, collector_sort, collector_number);
create index catalog_cards_name   on public.catalog_cards (game, lower(name));
create index catalog_cards_oracle on public.catalog_cards (game, oracle_id);
create index catalog_cards_number on public.catalog_cards (game, set_code, collector_number);
create index catalog_cards_rarity on public.catalog_cards (game, rarity);

create extension if not exists pg_trgm with schema extensions;
create index catalog_cards_name_trgm on public.catalog_cards using gin (name gin_trgm_ops);
create index catalog_cards_text_trgm on public.catalog_cards using gin (oracle_text gin_trgm_ops);
~~~

The two trigram indexes are what make `name ILIKE '%charizard%'` and the
rules-text half of search usable over a quarter of a million rows. They are the
only reason a shared catalogue can answer a question the local one answers with a
full scan.

**Both are on the raw columns, because the predicate compares the raw columns.**
This section first specified `lower(name)` and `lower(coalesce(oracle_text, ''))`,
which is the same mistake twice. A GIN index is matched by the expression in the
predicate and by nothing that merely means the same thing, so `name ILIKE ...`
cannot use an index on `lower(name)`, and `oracle_text ILIKE ...` cannot use one
on `coalesce(oracle_text, '')` either - the second is easy to miss, because
dropping the `lower()` is the obvious half of the fix and it is not enough on its
own. Both were measured against the imported Lorcana rows rather than reasoned
about: as first specified, section 4's predicate read the table; as written above,
it reads the indexes. pg_trgm lower-cases what it indexes whichever case the
column stores, so an index on `name` answers `ILIKE` exactly as the old one would
have, and a case-sensitive `LIKE` as well. The expression was corrected in
`tool/catalog/0002_search_index_expressions.sql`; the index names did not change.
Section 4's predicate is what these indexes are on, and it has to stay spelled
the way it is there.

### 2.3 The two folding rules, which must not drift

The app already has two implementations of "the comparison form of a code", and
they do not agree:

- `Codes.fold` (Dart, applied to a typed query) drops *everything* that is not
  `a-z0-9`.
- `Codes.foldedSql` (SQLite, applied to a stored column) strips exactly the six
  separators listed in `Codes.separators`.

The server mirrors the second one for stored columns. If it mirrored the first, a
set code containing an exotic character would fold differently on the server than
in the browser's own SQLite, and the same query would answer differently
depending on which path served it.

~~~sql
alter table public.catalog_sets add column code_folded text
  generated always as (
    replace(replace(replace(replace(replace(replace(
      lower(code), '-', ''), ' ', ''), '.', ''), '/', ''), '_', ''), ':', '')
  ) stored;

alter table public.catalog_cards add column number_bare text
  generated always as (ltrim(collector_number, '0')) stored;

create index catalog_sets_code_folded on public.catalog_sets (game, code_folded);
create index catalog_cards_number_nocase on public.catalog_cards (game, lower(number_bare));
~~~

Zero padding is a separate rule and stays separate: Digimon prints `001` where
Magic prints `1`, and the local DAO compares `ltrim(x,'0')` on both sides.
`number_bare` is that expression materialised so it can be indexed.

A test-vector file - a few hundred (input, folded) pairs generated from the Dart
functions and committed - is asserted against both the SQL expression and the Dart
one. Two hand-written implementations of one rule is the likeliest way this design
quietly stops working.

**The number index is on the expression its read compares, too.** This section
first specified `catalog_cards_number_bare` on `(game, number_bare)`, and §4
compared `c.number_bare` to the padded number, so the two agreed. §4's
comparison then turned out to be wrong - case-sensitively wrong, which is a bug
rather than a simplification, and it is recorded in full there - and the fix to
it is the same lesson §2.2 has already learnt twice above: a btree index is
matched by the expression in the predicate and by nothing that merely means the
same thing. So the index moved with the predicate rather than being joined by
another one. `tool/catalog/0003_read_functions.sql` creates
`catalog_cards_number_nocase` on `(game, lower(number_bare))` before dropping
`catalog_cards_number_bare`, and the number read is a BitmapOr of the new index
and `catalog_cards_number`. The count is still fifteen indexes: one was
replaced, not added, because two indexes on one column where only one can ever
be chosen is a write cost paid nightly for nothing. `number_bare` itself is
deliberately untouched - its expression is asserted against the committed
collector-number vectors by two proofs, and folding the column would change what
those vectors mean.

### 2.4 RLS for shared read-only data

The catalogue is public data, so the policy is one line per table and has no
per-row condition. What matters is everything else being switched off.

~~~sql
alter table public.catalog_sets   enable row level security;
alter table public.catalog_cards  enable row level security;
alter table public.catalog_prices enable row level security;
alter table public.catalog_meta   enable row level security;

-- No role but the importer may write, and the importer connects as the owner.
revoke all on public.catalog_sets, public.catalog_cards,
              public.catalog_prices, public.catalog_meta
  from anon, authenticated;
grant select on public.catalog_sets, public.catalog_cards,
                public.catalog_prices, public.catalog_meta
  to anon, authenticated;

create policy catalog_sets_read   on public.catalog_sets   for select to anon, authenticated using (true);
create policy catalog_cards_read  on public.catalog_cards  for select to anon, authenticated using (true);
create policy catalog_prices_read on public.catalog_prices for select to anon, authenticated using (true);
create policy catalog_meta_read   on public.catalog_meta   for select to anon, authenticated using (true);
~~~

Points that are easy to get wrong:

- **No insert, update or delete policy, and no DML grant.** With RLS on and no
  write policy, writes are refused; with the grant also missing, they are refused
  earlier. Both, on purpose. A single stray `grant insert` to `anon` would let
  anyone holding the publishable key - which ships inside the web bundle and is
  public by design - rewrite the catalogue every browser reads. That is the worst
  failure this design can have, and it deserves a test: a query against
  `information_schema.role_table_grants` asserting that `anon` and `authenticated`
  hold `SELECT` and nothing else on those four tables.
- **`anon`, not just `authenticated`.** An authenticated request carries the
  `authenticated` role and does not match an `anon`-only policy, so the grant and
  the policy must both name the two roles. Reading without signing in also means a
  browser whose session has lapsed shows a Sets tab rather than an empty one, and
  it costs nothing, because the data is not secret.
- **The account tables are not touched.** `decks` and `collection_entries` keep
  their owner-only policies exactly as they are. There is deliberately no policy
  anywhere that joins a catalogue table to a user's holdings.
- **The importer bypasses RLS.** It connects to Postgres directly (session pooler,
  credentials in a file with mode 600 on the host) as the table owner: not through
  PostgREST, and not with the publishable key. The secret key never leaves the
  host, which is the rule `supabase_config.dart` already states.
- **The RPCs are `security invoker` with `set search_path`.** They run with the
  caller's rights - the policies above are what let them read - and never with a
  `security definer` bypass.

## 3. Filling it and keeping it current

The nightly jobs already fetch almost all of this data and then throw most of it
away. `poll_pokemon_prices.py` reads a full TCGdex card object per card and keeps
only its prices. `poll_lorcana_prices.py` holds every Lorcana card, in 23
requests. `poll_yugioh_prices.py` downloads the whole game - 14,549 cards with all
their printings - in one 21 MB response. The cheapest importer is therefore not a
new fetcher: it is the existing sweep writing a second table.

| Unit (existing or new) | Games | What it already fetches | What it gains |
| --- | --- | --- | --- |
| `arcanum-pokemon-poll.timer` (daily, 04:20 UTC) | pokemon | TCGdex sets, then one `/cards/{id}` per card | sets, cards, current prices |
| `arcanum-lorcana-poll.timer` (daily, 04:40 UTC) | lorcana | Lorcast `/sets` and `/sets/{code}/cards` | sets, cards, current prices |
| `arcanum-yugioh-poll.timer` (daily, 04:55 UTC) | yugioh | `cardsets.php` and one `cardinfo.php` | sets, cards, current prices |
| `arcanum-mtg-rebuild.timer` (Mondays, 05:30 UTC) plus a new `catalog_import_mtg.py` | mtg | MTGJSON `AllIdentifiers` and `AllPrices`, for history | one Scryfall bulk `default_cards` download for sets, cards and current prices |
| new `arcanum-catalog-tcgcsv.timer` (daily, after 06:00 UTC) | onepiece, swu, digimon, dragonball, gundam | nothing today | `/{cat}/groups`, `/{cat}/{group}/products`, `/{cat}/{group}/prices` |

Two notes on that table. Magic's current prices come from Scryfall's bulk data
rather than MTGJSON, because the deploy notes already record that MTGJSON's
`AllPrices` covers about four fifths of printings and recent sets thinly; the bulk
file carries a `prices` object per card and closes that gap for free. And the
tcgcsv walk is genuinely new traffic - five categories, a few hundred requests a
day - but tcgcsv publishes a daily rebuild anyway, so the server is asking for the
file the mirror rebuilds nightly.

The write path is one shared module, `tool/catalog_store.py`, used by all five
importers. Its rules:

1. **One transaction per set.** Delete that set's rows, insert the new ones,
   update the set row and bump `cards_revision`, then commit. A reader sees the
   old set or the new one and never a half-written one, which is what makes the
   per-set revision mean anything.
2. **Checksum first.** Hash the canonical card list; if it equals
   `cards_checksum`, write nothing at all. Most nights most sets are unchanged and
   an import should cost one comparison.
3. **Sets before cards,** because `catalog_cards` has a foreign key to
   `catalog_sets`.
4. **Never delete a set.** A set that disappears upstream gets `retired_at`, not a
   `delete`. Holdings name card ids, and a card id that stops resolving turns a
   collection row into `--`.
5. **Record the outcome.** `catalog_meta.last_import_ok` and `last_import_note`
   per game, so a broken importer is visible as a fact rather than as an empty
   Sets tab.
6. **Idempotent and single-flight.** Safe to re-run by hand, and held by a `flock`
   on the host so two runs cannot interleave.
7. **No partial revision bumps.** `catalog_meta.sets_revision` is incremented
   once, at the end, and only if the set list itself changed.

An import that fails must leave the previous revision serving. A browser that
cannot reach the catalogue at all must fall back to the providers. Both follow
from one rule: the shared catalogue is an optimisation with a working fallback,
never a hard dependency.

## 4. How a client reads it

Everything below is PostgREST, reached through the `supabase_flutter` client the
web build already holds a session in. No new public endpoint and no new server
code; CORS is the platform's problem and is already solved for the account sync.

| What the app asks (`CatalogDao` / `CatalogRepository`) | Read path |
| --- | --- |
| `loadSets(game)` - every set of a game | `GET /rest/v1/catalog_sets?game=eq.{game}&select=*&order=released_at.desc.nullslast,code&limit=1000`, paged with `Range` |
| `sets(search:, types:, sort:)` - filtering and ordering the set list | client-side, unchanged: the whole list is now one download |
| `cardsInSet(game, code)` | `GET /rest/v1/catalog_cards?game=eq.&set_code=eq.&select=*&order=collector_sort.asc,collector_number.asc,id&limit=1000`, paged |
| `cardById(game, id)` | `GET /rest/v1/catalog_cards?game=eq.&id=eq.&limit=1` |
| `cardsByIds(game, ids)`, and `resolveMissingCards` | `POST /rest/v1/rpc/catalog_cards_by_ids` with `{ "p_game": ..., "p_ids": [...] }` |
| `cardByNumber`, `searchByNumber` | `POST /rest/v1/rpc/catalog_cards_by_number` - the parse stays in Dart; the candidates it produced are passed in |
| `searchCached` when the local cache comes up short | `POST /rest/v1/rpc/catalog_search` |
| `printingsOf(game, oracleId)` | `GET /rest/v1/catalog_cards?game=eq.&oracle_id=eq.&order=released_at.asc.nullsfirst` |
| `refreshPrices(game, ids)` | `GET /rest/v1/catalog_prices?game=eq.&card_id=in.(...)`, chunked, or `rpc/catalog_prices_by_ids` for a whole collection |
| `setsFetchedAt(game)`, staleness | `GET /rest/v1/catalog_meta?select=*` - nine rows, one query, at boot |

Two rules for every read. First, **page explicitly**: Supabase caps a PostgREST
response at 1,000 rows, and Magic alone has 1,049 sets, so the set list does not
fit in one page. The order must be total - add `id` or `code` as a tiebreak - or
pages will overlap and skip rows. Second, **select the columns the table has**;
the mapper expects all of them, and a `select=` list that drops one is a silent
`null`.

The search and number functions are where the server has to reproduce ranking the
local DAO already does, so that both paths answer the same question the same way:

~~~sql
create or replace function public.catalog_search(
  p_game text, p_query text, p_limit integer default 80
) returns setof public.catalog_cards
language sql stable security invoker
set search_path = public, extensions
as $$
  select c.*
    from public.catalog_cards c
   where c.game = p_game
     and (c.name ilike '%' || p_query || '%'
          or c.oracle_text ilike '%' || p_query || '%')
   order by (c.name ilike p_query || '%') desc,          -- a name that starts with it
            (c.name ilike '%' || p_query || '%') desc,  -- then a name that contains it
            c.released_at desc nulls last               -- then the newest printing
   limit least(greatest(p_limit, 1), 200);
$$;
~~~

That is `CatalogDao.searchCached`'s ordering, translated. The caller escapes `%`
and `_` in `p_query`, or the function does; a collector typing `%` should not turn
the query into "everything".

The two `ILIKE`s in that function do more than select rows: they are the
expressions the two trigram indexes of §2.2 are on, and they are written against
the raw columns so that they match. Wrapping either one in `lower(...)` or
`coalesce(...)` gives the same results and no matching index, which over a
quarter of a million rows is a sequential scan that reads like a search. See §2.2
for the measurements.

The number lookup takes the parsed query rather than parsing it again, because
`CollectorQuery.parse` already exists in Dart and a second grammar in SQL is a
second thing to get wrong:

~~~sql
create or replace function public.catalog_cards_by_number(
  p_game text,
  p_code_candidates text[],   -- CollectorQuery.codeCandidates, folded, best guess first
  p_number text,              -- as typed: '001', '123a', '4'
  p_standalone boolean,
  p_limit integer default 80
) returns setof public.catalog_cards
language sql stable security invoker
set search_path = public, extensions
as $$
  with matched as (
    select s.code, coalesce(array_position(p_code_candidates, s.code_folded), 9999) as rank
      from public.catalog_sets s
     where s.game = p_game and s.code_folded = any (p_code_candidates)
  )
  select c.*
    from public.catalog_cards c
    left join matched m on m.code = c.set_code
   where c.game = p_game
     and (p_standalone or m.code is not null)
     and (c.collector_number = p_number
          or lower(c.number_bare) = lower(ltrim(p_number, '0')))
   order by (c.collector_number = p_number) desc,
            m.rank,
            c.released_at desc nulls last,
            c.set_code, c.collector_sort, c.collector_number
   limit least(greatest(p_limit, 1), 200);
$$;
~~~

**The number comparison above is case-insensitive, and this section had it
wrong.** As first written it compared `c.number_bare = ltrim(p_number, '0')`,
which is case-sensitive, while the implementation the function exists to agree
with - `CatalogDao.searchByNumber` - compares `collector_number = ? COLLATE
NOCASE`. Thirteen collector numbers in the imported Lorcana catalogue carry
letters (`1f`, `24B`, `25ja`, `125f`, `2f`, `3f`, `4a`, `4b`, `4c`, `4d`,
`4e`, `65f`, `25zh`), so a collector typing `24b` was answered by their own
phone's SQLite and by nothing on the server: the same query answering
differently depending on which path served it, which is the failure §2.3 was
written to prevent. Measured on the live table on 2026-09-18, before the
correction: `'24b'` matched 0 rows through the predicate as this section
spelled it and 1 row through the case-insensitive one.
`tool/catalog/0003_read_functions.sql` applied the `lower()` on both sides, and
§2.2's number index moved onto the expression with it. The exact comparison
stays, and still ranks a match first: it is what makes `001` and `001` the same
printing, while the folded comparison is what makes `001` and `1` the same one.

`catalog_cards_by_ids` is the unglamorous one that matters most on the web. It
exists because a browser that has just signed in holds a collection of thousands
of rows and no catalogue, and `CatalogRepository.resolveMissingCards` currently
asks the provider once per card, four at a time. Against a server that already has
every card, the whole reconciliation is a handful of `in (...)` queries. That one
change is probably the largest user-visible improvement in this document.

### 4.1 How it is wired into the app

One new `CardCatalog` implementation, `SupabaseCatalog`, one instance per game,
plus a router:

~~~dart
class RoutedCatalog implements CardCatalog {
  RoutedCatalog({required this.game, required this.provider, required this.server});
  // server first when a session exists and the flag is on; provider on any error.
}
~~~

The router is what keeps the phone and the offline promise intact, and it is why
this is additive. `Bootstrap.create` builds the catalogue map synchronously and
must not start depending on a session, so `RoutedCatalog` answers "is there a
server?" at call time from the live `AccountService` and falls back on a caught
error rather than on a probe. It is constructed in `providers.dart` in place of
the nine existing entries, with each provider client passed through untouched.

The seam is not quite wide enough in one place. `CardCatalog` has
`fetchCardById` but no batch form, which is what makes `resolveMissingCards`
quadratic against any remote source, server or provider. The change is one method
with a default implementation, so nothing breaks and nothing else must be
rewritten:

~~~dart
/// Printings for many ids, keyed by id. Default: one request per id.
Future<Map<String, TcgCard>> fetchCardsByIds(List<String> ids) async { ... }
~~~

`SupabaseCatalog` overrides it with the RPC; the five provider clients keep the
default. `resolveMissingCards` then calls it once per batch of missing ids. This
is the only change to `lib/` the first increment needs, and it is a strict
improvement for the phone as well.

### 4.2 Mapping, done once

`_cardFromRow`, `_cardToRow`, `_pricesFrom`, `_imagesFromRow` and `_setFromRow`
are duplicated today between `app_database.dart` and `catalog_dao.dart`. A
server-backed catalogue must not add a third copy. Extract them into one file
(`lib/data/db/catalog_row.dart`), have both DAOs and the new adapter use it, and
give the adapter exactly one job: turn a PostgREST row into the map the mapper
already understands - `boolean` to `0/1`, `extras` jsonb to a JSON string, and the
price rows attached as `prices_json`.

## 5. Prices

Prices are the least stable part of the catalogue and the most game-specific, so
they get their own table, their own revision and their own refresh path. Putting
them on the card row, as SQLite does, would rewrite a quarter of a million rows
every night to change a number - bloating the table and moving the whole
catalogue's `updated_at` for no reason.

~~~sql
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
~~~

The `kind` split is the shape of `TcgPrices` written down: `byFinish` is the
`finish` rows, `secondary` is the rest. Storing finish codes as strings rather than
as an enum means a provider that starts quoting a variant the app has never heard
of - TCGdex has done this once already - is stored verbatim and appears in
`byFinish` without a migration on either side.

What each game gets, and where the importer already reads it:

| Game | Finishes | Secondary | Where the value comes from |
| --- | --- | --- | --- |
| Magic | nonfoil, foil, etched | eur, eurFoil, eurEtched, tix | Scryfall bulk `default_cards`, the `prices` object |
| Pokemon | nonfoil, holofoil, reverse_holofoil, first_edition, first_edition_holofoil | eur, eurLow | TCGdex `pricing.tcgplayer[<variant>].marketPrice ?? midPrice`, `pricing.cardmarket.trend ?? avg` |
| Yu-Gi-Oh! | nonfoil only - the source publishes no foil price at all | eur, ebay, amazon, coolstuffinc | `card_sets[].set_price`, falling back to the card-level `card_prices` figure |
| Lorcana | nonfoil, foil | none | Lorcast `prices.usd` and `prices.usd_foil`, which are decimal strings |
| tcgcsv games | nonfoil, foil | none | the group's `/prices` rows, `marketPrice`, keyed by `subTypeName` |

Four rules the importer inherits from the existing provider clients, because the
app has to render the same numbers from either path:

- **A zero is not a price.** YGOPRODeck's `"0.00"` means "no market data" and is
  stored as no row at all. A finish with no row is unknown; `priceFor` returns
  null and `from` skips it, exactly as today.
- **Per printing where the source has one.** For Yu-Gi-Oh! that means keying the
  price by the synthetic printing id rather than the passcode.
  `poll_yugioh_prices.py` already rebuilds that id from `_printingId` in
  `ygo_catalog.dart`, and its docstring already says why: a series stored under any
  other key is a series the app never asks for. The same argument holds for every
  game here.
- **`observed_on` is the sampler's day, not the moment of the write.** The app can
  finally say when a price was read; `TcgPrices.updatedAt` is null everywhere today
  because no provider ever states one.
- **Full replacement per game, nightly.** Prices are cheap to recompute and
  expensive to diff: `delete ... where game = ...` then insert, in one transaction,
  then bump `prices_revision`.

**History stays where it is.** The companion's `/v1/history/{cardId}.json` already
serves daily series for four games, the app already treats it as its first source,
and Magic's slice is 13 million points. Postgres is the wrong home for that:
nobody needs a series through a row filter, and the egress would be paid twice.
Prices in Postgres are current prices only.

## 6. The web client's cache, and what invalidates it

There is no new cache. The browser already keeps a full SQLite - sqlite3 compiled
to WebAssembly, in IndexedDB, in a dedicated worker - and `CatalogDao` already
writes into it. The server path fills the same tables through the same upserts, so
every screen, filter, sort and completion calculation keeps working, and a set
that has been opened once is instant and needs no network.

What the server adds is a way to know the cache is behind:

- `catalog_meta` is read once at boot and once after sign-in: nine rows carrying
  `sets_revision`, `prices_revision` and the two dates per game.
- The client remembers what it last saw in SQLite's existing `meta` table, under
  `catalog_sets_rev:<game>` and `catalog_prices_rev:<game>`. No schema change is
  needed for those two.
- The per-set revision wants a column, so the app's schema goes to v15:
  `alter table sets add column cards_revision INTEGER NOT NULL DEFAULT 0`. A
  migration is the honest way to hold a fact about a set, and the app already has
  fourteen of them. The alternative - one `meta` row per set - works, but turns
  1,049 sets into 1,049 keys.

| Signal | What the client does |
| --- | --- |
| `sets_revision` for a game has moved | re-download that game's set list, one paged query, written through `upsertSets` |
| `cards_revision` for one set has moved | clear that set's cached printings and its `catalogued_at`, so the next open re-downloads it. Other sets untouched |
| `prices_revision` for a game has moved | refetch prices for the cards this client actually holds, bounded and batched, written through `updatePrices` |
| the local row is missing entirely | unchanged: `isCatalogued` decides, exactly as it does today |

Three consequences worth writing down.

**A revision is an invalidation signal, not a presence signal.**
`clearCachedCatalog` deletes rows and leaves the revisions in `meta`. If the
client read a matching revision as "I have it", the Sets tab would come back empty
and stay empty. Presence stays with `isCatalogued`; the revision only ever says
"what you have is old".

**Revisions replace the TTL; they do not join it.** Two independent invalidation
mechanisms in one code path is how a browser ends up re-downloading a set on every
visit. `CatalogRepository.setCacheTtl` becomes a floor - never refetch the set list
more than once per session, however the revisions move - and the revision becomes
the reason to refetch at all. If that is too subtle to be worth it, the simpler
rule is: when a session exists, the revision wins and the TTL is ignored.

**The browser cache is disposable, and on iOS it may be taken away.** Safari
evicts a non-installed site's storage after about a week of disuse, and any user
can clear site data. Nothing may depend on the cache surviving. A cold start costs
one set-list query and then one query per set opened - which is the cost model the
app already has on a fresh install, so it is a known quantity rather than a new
one.

## 7. What breaks, what gets harder, what is given up

These are real, and several of them are the price of the design rather than
problems to be solved later.

**One broken nightly import is now visible to everybody at once.** Today a bad
provider response costs one device a stale set. Tomorrow it costs every browser
the same set at the same time. The mitigations are the soft delete, the checksum
skip, `last_import_ok` per game, and the provider fallback in `RoutedCatalog` -
but the failure mode is new, and the alerting has to exist before the first game
ships rather than after.

**Ids are the sharpest edge.** The app's card ids are derived, not merely
forwarded. Yu-Gi-Oh! printings are synthesised as
`<passcode>:<setCode>:<printingCode>:<raritySlug>`, tcgcsv products are
`<groupId>-<productId>`, and Yu-Gi-Oh!'s 1,035 sets share 646 codes which the
client disambiguates with a numeric suffix. If the Python importer derives any of
these a character differently, every holding that names such a card stops
resolving - silently, because a missing card renders as `--`.
`poll_yugioh_prices.py` already documents this trap and already mirrors
`_printingId`. The importer must do the same for all nine games, and there must be
a test comparing the server's ids for a sample of a few hundred cards per game
against the ids the Dart provider clients produce. That test is the most valuable
thing in this document.

**The same rules now exist in two languages.** Code folding, the collector-number
grammar, `collector_sort`, rarity normalisation, the Pokémon and tcgcsv `oracleId`
schemes, promo derivation, name cleaning. Some of it is avoided by keeping the
parse in Dart and passing candidates to the server. The rest is not: the importer
computes `collector_sort` and the folded code, and if Python's version drifts from
Dart's, sorting and search disagree between the two paths. The mitigation is a
committed test-vector file asserted from both sides, and the discipline to keep
each rule in one place per language.

**Supabase becomes a ceiling and a bill.** Nine games of cards with rules text is
roughly a quarter of a million rows and hundreds of megabytes, and every browser
pulls sets out of it, so egress is a recurring monthly cost rather than a one-off.
The free plan's database is measured in hundreds of megabytes; check the current
figures and measure a real import after the first game, before committing to all
nine.

**Public read means public bulk download.** The publishable key ships inside the
web bundle, so `grant select to anon` means anyone can mirror the catalogue. Card
data is not secret, so this is a bandwidth and terms question rather than a
security one - but it is a different posture from today, where each client fetches
from the providers directly. tcgcsv republishes TCGplayer's own product catalogue;
re-hosting it in our database is redistribution, and the attribution in
`lib/core/legal.dart` would have to be re-read with that in mind. If that is
uncomfortable the answer is `authenticated`-only policies, not a different design:
it is a decision, and it is in section 9.

**First paint does not get faster; the set list and search do.** The first visit
to a set is a PostgREST round trip instead of a provider round trip, of
comparable size, minus the provider's rate limit. What actually changes is that
the Sets tab is populated before anything is downloaded, and search covers the
whole catalogue rather than what happens to be cached.

**Two ways to fill the same table.** The fallback writes provider rows into the
same SQLite tables the server path writes. They agree because both go through
`TcgCard` and one mapper, but a bug in either direction produces a cache whose
provenance is invisible. The revision keys already proposed are worth having for
exactly this reason: they make it possible to tell which path wrote what, and to
force a re-download after a bad answer.

**The web build still cannot work offline.** There is no service worker, and this
design does not add one. The catalogue cache makes a loaded page fast; it does not
make a closed tab work with no network.

**What is given up.** Per-device control of catalogue freshness, since the
seven-day TTL becomes the server's decision rather than the collector's. The
phone's independence from any hosted service, if that rule is ever relaxed for
convenience. And the plainest property of the current design: the catalogue is
fetched from the publisher by the device that needs it, so no third party can be
wrong about a card on our behalf.

## 8. Migration order

The smallest first step that delivers real value is one game, end to end. The
schema, the importer, the revisions and the read path are all exercised by a
single small game, and everything after it is the same work with more data. No
step requires a big-bang rewrite, and no step breaks the phone.

| Step | What ships | Why here |
| --- | --- | --- |
| **0. Schema and posture** | The four tables, indexes, generated columns, grants and policies, `catalog_meta` rows for all nine games. Empty. A test asserting `anon` holds only `SELECT`. | Nothing else can be verified until the posture is fixed, and the posture is the expensive thing to change later. Delivers no user value; keep it small. |
| **1. One game imported** | `tool/catalog_store.py` and an extended `poll_lorcana_prices.py` (23 sets, 3,198 cards), plus the id-parity test and the fold vectors. | Lorcana is the smallest real catalogue and the first game the web build serves badly. It proves the id derivation, the checksum, the revisions and the per-set transaction at a size a person can read. |
| **2. One game read** | `SupabaseCatalog`, `RoutedCatalog`, the extracted mapper, a Settings flag, web only. `fetchCardsByIds` with its default implementation, and `resolveMissingCards` using it. | The first user-visible step: Lorcana's Sets tab stops being empty and its search covers the whole game. It also delivers the batch card fetch, which helps every game on the web today. **Amended 2026-09-21:** the flag shipped off and now defaults on, and the games are listed once in `sharedCatalogueGames` rather than named in the switch's own sentence - see §8.1. |
| **3. The five tcgcsv games** | The new `arcanum-catalog-tcgcsv.timer`, its importer, and routers for five games. | The web build's worst case: they go through the CORS relay, they have no search at all, and the Sets tab is empty until a group is opened. |
| **4. Search and numbers** | The `catalog_search` and `catalog_cards_by_number` RPCs, and `CatalogRepository.search` asking the server when the local cache comes up short. | Search is the feature that genuinely needs the whole catalogue, and it needs rows to search: steps 1 to 3. |
| **5. Magic, Pokemon, Yu-Gi-Oh!** | The Scryfall bulk import and the two extended pollers. | The three big catalogues and the three hardest id derivations, done once the machinery has been proved on six easier games. |
| **6. Current prices** | `catalog_prices` written by all five importers, `prices_revision` refresh in the client, `observed_on` shown where the app already shows a price date. | Prices are the most volatile and most game-specific part, and the client refresh path touches code that already works. Last, so a bug there cannot delay the catalogue. |
| **7. Optional: the phone, through the companion** | A read-only proxy on zapp.sytes.net serving the same shapes to a token-holding phone. | Only once the catalogue is proven, and only as an optimisation. The phone must never need it. |

### 8.1 What the flag turned out to mean

It shipped off by default, which was the cautious thing to do while there was one
game on the server and its import was fresh, and it had a cost that only became
visible once it was measured: **a switch that is off until somebody finds it
means the step never runs.** The shared catalogue, the fallback under it, and the
whole first user-visible improvement were all behind a control nobody had a
reason to look for. A rollback switch that is off is not a rollback switch; it is
an opt-in.

It now defaults on, and the thing that makes that safe is not the default but
`RoutedCatalog`: it answers from the provider whenever the catalogue fails or has
nothing to say, so the worst case of a server that is wrong, empty or absent is
one wasted request. That property was already tested before this changed; what
changed is that a collector now exercises it rather than a test doing so.

Two consequences worth stating, because both were wrong at the moment the second
game was added to the server:

- **The set of games lives in one place**, `lib/data/catalog/shared_catalogue.dart`,
  and both `providers.dart` and `main.dart` read it. The factory in `main.dart`
  builds a server catalogue for whichever game it is asked about and does not
  decide which games those are.
- **The switch's sentence is built from that set**, so it cannot go on saying
  "Read Lorcana from Arcanum" after the server has taken on a second game. That
  is exactly what it said for the length of one commit, and a control that
  misdescribes itself is worse than a missing one because the collector trusts
  it.

Rollback at every step is the same: turn the Settings flag off. The provider path
is never removed, so a game can go back to being per-device at any time without a
release.

## 9. Open questions

These need a person, not more design.

1. **Does the catalogue fit the plan we are willing to pay for?** ~~Measure a real
   import in step 1 and extrapolate to nine games with rules text before importing
   Magic.~~ **Measured 2026-09-21: no, not with margin.** The nine games come to
   about 190,000–204,000 rows and 370–400 MB against a 500 MB ceiling, and the
   free plan carries no automatic backup at all, which is the larger half of the
   problem. `docs/catalogue-size.md` records the measurements and the three ways
   out. The fallback this question proposed - card rows without `oracle_text`,
   which is 25% of the table once its trigram index goes with it - is one of
   them, and it still costs a feature. **This needs a person to choose; it gates
   step 5.**
2. **Is the catalogue readable without an account?** `anon` makes the Sets tab work
   for a lapsed session and makes the whole catalogue publicly mirrorable.
   `authenticated`-only is a one-line policy change with a real consequence either
   way.
3. **Is re-hosting tcgcsv's (TCGplayer's) product catalogue in our own database
   acceptable?** A terms question rather than a technical one, and it is the one
   import source with no obvious standing.
4. **Which games first, and is Lorcana the right pilot?** If the goal is the
   largest visible improvement in the web build, the five tcgcsv games come first;
   if the goal is the cheapest proof, Lorcana does.
5. **Do the five provider clients stay forever?** Keeping them is what makes the
   fallback and the phone work. Keeping them also means two catalogue
   implementations to test and keep honest for as long as the app exists. The
   recommendation is to keep them; the decision belongs to a person.
6. **Should the companion serve the catalogue to phones?** It would help a phone
   open a set it has never seen, and it would make the phone depend on a host that
   can be down. The recommendation is opt-in and late.
7. **One source of truth for folding and sorting** - a shared vector file asserted
   on both sides, or move the rule into Postgres and have Dart call it? The vector
   file is cheaper and keeps the phone independent.
8. **Do we show the price's observation date?** `TcgPrices.updatedAt` is null
   everywhere today and the server can fill it honestly. That changes what several
   screens say, so it is a product decision.
9. **Should a set publish a slot count,** so the Sets tab can show real progress
   before a set is opened? One generated number per set on the server, but it
   changes `SetCompletion`, which is app code.
10. **Who is told when an import fails, and how much of the previous revision is
    kept?** The host has systemd timers, logs and a notify path already; the
    catalogue needs a policy, and it needs one before step 1 rather than after.
11. **Does the importer live in this repository's `tool/` beside the pollers, or
    somewhere of its own?** In the repository keeps the id-derivation rules next
    to the Dart they must match, which is the whole argument for it.
