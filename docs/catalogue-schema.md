# The catalogue schema, as applied

Status: applied to the live project (`wqycllzbwbhqiqlmbwcu`) on 2026-09-18 by
`tool/catalog/0001_catalog_schema.sql`. Migration step 0 of
[catalogue-server-side.md](catalogue-server-side.md), and nothing further: the
four tables exist, their indexes exist, the RLS posture is fixed, `catalog_meta`
holds nine rows, and every table is empty. There is no importer, no RPC and no
client change, because step 0 delivers none of those. Section 2 of the design
document is the specification for the shape; this file records what was actually
built, what the environment forced, and how to undo it.

If this file and the SQL disagree, the SQL is what ran.

## What was applied

One transaction. Either all of it exists or the database is as it was.

### The four tables

`catalog_sets`, `catalog_cards`, `catalog_prices` and `catalog_meta`, all in
`public`, all owned by `postgres`. The column lists are transcribed from
sections 2.1, 2.2 and 5 of the design document without a single column added or
dropped, so this file does not repeat them; the reasons for each column are in
those sections. What follows is the part that is easy to get wrong when reading
the SQL.

**Three deliberate changes from the SQLite `cards` table** (design §2.2):
`prices_json` and `prices_updated_at` are absent because prices live in
`catalog_prices`; `extras` is `jsonb` rather than a JSON string so it can be
indexed later; booleans are `boolean` rather than 0/1, with the conversion
living in the adapter that will read PostgREST rows. The `faces`
reconstruction stays lossy in exactly the way it is lossy on the device - the
back face keeps its images and nothing else - because inventing a shape here
would break the mapper both paths must share.

**Two generated columns** (design §2.3), and they are the reason this step is
worth doing carefully rather than quickly:

~~~sql
alter table public.catalog_sets add column code_folded text
  generated always as (
    replace(replace(replace(replace(replace(replace(
      lower(code), '-', ''), ' ', ''), '.', ''), '/', ''), '_', ''), ':', '')
  ) stored;

alter table public.catalog_cards add column number_bare text
  generated always as (ltrim(collector_number, '0')) stored;
~~~

The six separators are `Codes.separators` (`lib/core/utils/codes.dart`),
checked against that file rather than taken from the prose: `'-'`, `' '`,
`'.'`, `'/'`, `'_'`, `':'`. This is `Codes.foldedSql`, not `Codes.fold`.
That distinction is the whole point of the column existing - a stored set code
has to fold the way the browser's own SQLite folds it, or the same query answers
differently depending on which path served it. `number_bare` is the separate
zero-padding rule, materialised so it can be indexed.

Both expressions are asserted against the live database by the proof script,
string for string, so a later migration that edits them has to do so on purpose.

**Indexes:** fifteen, including the four primary keys. Five on `catalog_cards`
that come from the read paths in design §4, two trigram indexes that make
`ILIKE '%...%'` usable over a quarter of a million rows, and the two on the
generated columns. Nothing was added beyond the design's list: an index is a
claim about which queries matter, and those queries are listed in §4.

**`catalog_meta` is seeded with nine rows**, one per `CardGame.id`
(`mtg, pokemon, lorcana, yugioh, onepiece, swu, digimon, dragonball, gundam`,
read from `lib/domain/models/card_game.dart`). They carry zero counts and
`last_import_ok = false`, so "we have never imported this game" is a row the
client can read rather than a missing row it has to interpret. The insert is
`on conflict (game) do nothing`.

### The two places the environment forced a spelling

The design wrote `using gin (lower(name) gin_trgm_ops)`. The applied index says
`extensions.gin_trgm_ops`, because `pg_trgm` is installed in the `extensions`
schema - as §2.2 asks - and the unqualified name resolves only while
`extensions` is on the `search_path`. Both work on this project today; the
qualified one keeps working if a `search_path` is ever set differently for a
role, and an index definition is a bad place to discover that. `pg_indexes`
reports it back unqualified, so it is the same index either way.

The design's revoke names `anon` and `authenticated`. The applied revoke also
names `PUBLIC`. It removes nothing that exists - Supabase grants nothing to
`PUBLIC` on a new table in `public` - and it means the posture does not depend
on that continuing to be true.

### Both files

- `tool/catalog/0001_catalog_schema.sql` - what was executed, with the reasoning
  inline.
- `tool/catalog/0001_catalog_schema_down.sql` - the reversal.

## The RLS posture, and why it is both barriers

~~~sql
alter table public.catalog_sets   enable row level security;
alter table public.catalog_cards  enable row level security;
alter table public.catalog_prices enable row level security;
alter table public.catalog_meta   enable row level security;

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
~~~

The catalogue is the same for everybody and contains nothing private, so the
policy has no per-row condition and the interesting content is everything that
is switched off. The design argues this in §2.4 and is not repeated here. What
is worth recording is the environment fact that makes the revoke load-bearing
rather than tidy:

**A new table in `public` on this project is born writable by both client
roles.** Supabase's default privileges (`pg_default_acl`, grantor `postgres`)
give `anon`, `authenticated` and `service_role` `arwdDxtm` on every table created
in `public`. So `catalog_sets` arrived with INSERT, UPDATE and DELETE already
granted to the role the publishable key authenticates as - the key that ships
inside the web bundle. Row level security would still have refused those writes,
because no write policy exists, but the design asks for both barriers on
purpose: the grant is the barrier that does not depend on a policy staying
absent, and the policy is the barrier that does not depend on a grant staying
revoked.

Two things follow:

- Any future table in `public` inherits the same defaults, including whatever
  later steps add next to these. The revoke has to be written for each one, and
  the proof script is what notices if it is forgotten.
- `service_role` deliberately keeps its grants. It bypasses RLS by attribute, it
  is never in a browser, and the secret key that authenticates as it is what the
  proof script uses as its privileged reference view.

`postgres` owns all four tables and has `BYPASSRLS` on this project, so the
importer - which connects as `postgres` over the session pooler, not through
PostgREST and not with any API key - writes without consulting a policy. That is
the write path design §2.4 describes. RLS is deliberately **not** forced:
`FORCE ROW LEVEL SECURITY` would apply the policies to the owner as well, and
there is no write policy for the owner to pass, because there is no reason for
one.

### The account tables

`public.decks` and `public.collection_entries` were read, never written. They
keep the policy they already had - one `FOR ALL` policy each, to `PUBLIC`,
`USING (auth.uid() = user_id)` with the same `WITH CHECK` - and their
pre-existing grants, which do include INSERT, UPDATE and DELETE for `anon` and
`authenticated`, because those tables are meant to be written by their owner.
No policy anywhere joins a catalogue table to a user's holdings, which is the
property design §1 and §2.4 both insist on. The proof script asserts the policy
text, the roles and the grants against the values read from the live project
before this migration was written, so "untouched" is checked rather than
promised.

## The proof

`tool/catalog/prove_catalogue_posture.py`. It runs against the deployed project
rather than against the SQL that was supposed to produce the posture, because
the only interesting failures - a grant that came back, a policy that was never
created, a key that is accepted where it should not be - are invisible in the
SQL and obvious in a request.

~~~sh
set -a; . /home/zixen/arcanum/supabase.env; set +a
python3 tool/catalog/prove_catalogue_posture.py
~~~

Or anywhere else with the credentials in the environment:

~~~sh
SUPABASE_URL=... SUPABASE_PUBLISHABLE_KEY=... SUPABASE_SECRET_KEY=... \
SUPABASE_DB_URL_POOLED=... python3 tool/catalog/prove_catalogue_posture.py
~~~

`--no-auth` runs only the anonymous half and creates no probe account;
`--require-sql` turns a skipped SQL section into a failure. Without a database
URL or `psql`, the SQL checks report `SKIP` and never `PASS`.

What it checks, and why no one check implies another:

| Check | Why it is not implied by the others |
| --- | --- |
| The publishable key reads all four tables and reads the nine `catalog_meta` rows | a read returning 200 and no rows would also be true of a table nobody may read |
| The publishable key is refused INSERT, UPDATE and DELETE on all four | this is the failure the design calls the worst one it can have |
| A signed-in collector reads all four tables | an `authenticated` request does not match an `anon`-only policy, so the two roles are separate claims |
| A signed-in collector is refused INSERT, UPDATE and DELETE on all four | the same, for writes |
| A signed-in collector sees only its own `collection_entries` and `decks`, and cannot fetch another account's row by id | the account tables' isolation, tested from a real session rather than reasoned about |
| The publishable key with no session reads no `collection_entries` at all | the anonymous case of the same property |
| SQL: `anon` and `authenticated` hold `SELECT` and nothing else | the test design §2.4 asks for by name |
| SQL: `has_table_privilege` is false for INSERT, UPDATE and DELETE | an independent reading from the grant view, and a privilege can arrive by role membership the grant view does not show |
| SQL: RLS is enabled on all four | RLS off plus a SELECT grant is readable and writable by everyone |
| SQL: exactly one `FOR SELECT ... USING (true)` policy per table, and no write policy | a permissive write policy would be invisible to the grant check |
| SQL: the nine games are seeded | the client reads this table at boot |
| SQL: the account tables' policies and grants are unchanged | the thing this task promised not to disturb |
| SQL: the two generated columns match the Dart folding rules | the rule that must not drift between the server and the browser |
| SQL: the owner can still write, via an insert inside a rolled-back transaction | a positive control: without it, every refusal above would also be explained by a table nothing can write to |
| No probe rows left behind, and the account tables hold the counts they held before the run | the test must not be the thing that damages the database |

The probe account is created through the admin API with `email_confirm`, signed
in with the publishable key to get a real JWT, and deleted at the end of the
run; its absence is checked afterwards. Nothing is written to `decks` or
`collection_entries` at any point, by the script or by the migration.

### What a run says

Last run, 2026-09-18, from `zapp.sytes.net`, against the live project:

~~~
--- HTTP, as the publishable key ---
PASS  publishable_key_reads_catalog_tables
        select=* on all four tables answers 200 with a JSON array
PASS  publishable_key_reads_catalog_meta
        9 catalog_meta rows readable: digimon,dragonball,gundam,lorcana,mtg,onepiece,pokemon,swu,yugioh
PASS  publishable_key_cannot_insert
        all four tables refused with HTTP 401
PASS  publishable_key_cannot_update
        all four tables refused with HTTP 401
PASS  publishable_key_cannot_delete
        all four tables refused with HTTP 401

--- HTTP, as a signed-in collector ---
PASS  authenticated_reads_catalog_tables
PASS  authenticated_reads_catalog_meta
PASS  authenticated_cannot_insert
        all four tables refused with HTTP 403
PASS  authenticated_cannot_update
        all four tables refused with HTTP 403
PASS  authenticated_cannot_delete
        all four tables refused with HTTP 403

--- HTTP, the account tables ---
PASS  authenticated_sees_only_its_own_collection_entries
        the probe account reads 0 collection_entries rows; 1 rows exist in the
        table in total, 1 of them belonging to other accounts
PASS  authenticated_cannot_read_another_accounts_row
        a row the privileged view can see (id 7eac3c85...) does not appear when
        the probe account asks for it by id
PASS  anonymous_cannot_read_another_accounts_row
PASS  authenticated_reads_only_its_own_decks
PASS  anonymous_cannot_read_collection_entries

--- SQL, as the owner ---
PASS  sql_anon_and_authenticated_hold_only_select
PASS  sql_no_dml_privilege_at_all
PASS  sql_rls_enabled_on_all_four
PASS  sql_one_true_select_policy_per_table
PASS  sql_catalog_meta_has_the_nine_games
PASS  sql_account_tables_unchanged
PASS  sql_generated_columns_match_the_dart_rules
PASS  sql_owner_can_still_write

probe account deleted
PASS  no_probe_rows_left_behind

24 passed, 0 failed, 0 skipped
~~~

Two details are worth remembering when reading that output later. Anonymous
writes are refused with **401** and signed-in ones with **403**: PostgREST
answers 401 when the request is anonymous and 403 when a role is signed in but
lacks the privilege, so the number is about who asked rather than about what was
refused. And PostgREST validates an update body against its schema cache before
it checks privileges, so a probe naming a column the table does not have comes
back 400 and proves nothing - the script therefore sends each table a body that
table can accept. Both were found by running it: the first version reported a
false failure on UPDATE, and its DML-privilege check could not have failed at
all.

## Reversing it

`tool/catalog/0001_catalog_schema_down.sql`, run the way the up file was:

~~~sh
psql "$SESSION_POOLER_URL" -X -v ON_ERROR_STOP=1 -f tool/catalog/0001_catalog_schema_down.sql
~~~

It drops the four policies, then the four tables in foreign-key order, then
`pg_trgm` - and only if nothing else in the database has come to depend on the
extension.

It has been run. The reversal was applied to the live project and the up file
re-applied immediately afterwards, as a round trip rather than as a claim:
after the down file the only relations left in `public` were the two account
tables and their indexes, `pg_trgm` was gone, and both account policies and row
counts were exactly as they had been; after the up file the four tables, all
fifteen indexes, `pg_trgm` and the SELECT-only grants were back, and the proof
script passed all twenty-four checks again. The tables were empty at both ends
of that round trip, which is the only reason it was safe to do. `catalog_prices` would go with `catalog_cards` through
`ON DELETE CASCADE`, but the drops are ordered explicitly so the file still
works if that cascade is ever removed.

What reversal does not do, and should not: it does not touch `decks` or
`collection_entries`, because this migration never touched them. There is
nothing on the account side to restore. It also cannot restore a catalogue - at
this step there is no data to lose, but once step 1 has imported a game, dropping
these tables throws that import away and it has to be re-run. Reversing step 0 is
a deliberate act with a psql session, unlike the later steps, where rollback is a
Settings flag in the app.

If a client is shipped against these tables before they are dropped, the failure
is a PostgREST 404 on `catalog_*` and the fallback that covers it is the
provider fallback in `RoutedCatalog` - which is step 2 and does not exist yet.

## Notes for whoever does step 1

- The tables are empty on purpose. An empty catalogue and a missing one look
  identical to a client that only counts rows; `catalog_meta.last_import_ok` is
  the difference, and it is `false` for all nine games right now.
- `set_count` and `card_count` in `catalog_meta` are the importer's to
  maintain. Nothing on the server computes them.
- The importer connects as `postgres` over the session pooler (port 5432). The
  runtime transaction pooler on 6543 is what the web service uses; the proof
  script rewrites 6543 to 5432 for its SQL checks because the design names the
  session pooler for admin work.
- The database password contains `@` and `!` and has to be percent-encoded in a
  URL. It is not written down here, or anywhere in the repository.

## One thing in the design that step 4 will have to resolve

Recorded here because it was found while building the indexes, and because it is
cheaper to settle now than after step 4 has written the search function.

Section 2.2 specifies the two trigram indexes on the lowered expression:

~~~sql
create index catalog_cards_name_trgm on public.catalog_cards using gin (lower(name) gin_trgm_ops);
create index catalog_cards_text_trgm on public.catalog_cards using gin (lower(coalesce(oracle_text, '')) gin_trgm_ops);
~~~

Section 4's `catalog_search` searches the raw columns:

~~~sql
where c.name ilike '%' || p_query || '%'
   or c.oracle_text ilike '%' || p_query || '%'
~~~

A GIN trigram index is used only when the predicate's expression matches the
indexed expression, and `name ILIKE ...` does not match an index on
`lower(name)`. Measured on the live database, on a throwaway table of 50,000
rows inside a rolled-back transaction, with `pg_trgm` 1.6:

~~~
name ILIKE '%card49999%'          with an index on lower(name)   -> Seq Scan
lower(name) LIKE '%card49999%'    with an index on lower(name)   -> Bitmap Index Scan
name ILIKE '%card49999%'          with an index on name         -> Bitmap Index Scan
~~~

So as the two sections stand, the index that exists to make search usable over a
quarter of a million rows will not be used, and step 4 would ship a sequential
scan that looks indexed. The design is not wrong about wanting the index; it is
inconsistent about which expression it is on. Either the indexes move to the raw
columns - which is enough, since `gin_trgm_ops` supports `ILIKE` directly, and
which also makes the indexes usable by a case-sensitive `LIKE` - or
`catalog_search` compares `lower(name) LIKE lower(p_query) || '%'`. The first
is the smaller change and the one that costs nothing at read time; it is a
change to two index definitions here and to nothing else. It was left alone in
this step because this step implements section 2.2 as written, and the choice
belongs with whoever writes section 4's function.
