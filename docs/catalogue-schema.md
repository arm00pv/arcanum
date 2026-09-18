# The catalogue schema, as applied

Status: applied to the live project (`wqycllzbwbhqiqlmbwcu`) on 2026-09-18 by
`tool/catalog/0001_catalog_schema.sql`. Migration step 0 of
[catalogue-server-side.md](catalogue-server-side.md), and nothing further: the
four tables exist, their indexes exist, the RLS posture is fixed, `catalog_meta`
holds nine rows, and every table is empty. There is no importer, no RPC and no
client change, because step 0 delivers none of those. Section 2 of the design
document is the specification for the shape; this file records what was actually
built, what the environment forced, and how to undo it.

Amended the same day by `tool/catalog/0002_search_index_expressions.sql`: the two
trigram indexes moved off the lowered expressions step 0 copied out of design
§2.2 and onto the raw columns §4's search compares. Step 1 has since imported
Lorcana - that import is `catalogue-import.md`'s record, not this file's - so
`catalog_cards` holds 3,208 rows rather than none, and the measurements below
were taken on them.

Amended again by `tool/catalog/0003_read_functions.sql`, which is step 4 and is
three read functions rather than schema. The one thing in it that belongs in
this file is `catalog_cards_number_bare`: 0003 replaced it with
`catalog_cards_number_nocase` on the expression §4's number read now compares,
which is recorded in its own section below.

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
claim about which queries matter, and those queries are listed in §4. The two
trigram indexes were rebuilt by 0002 onto the raw `name` and `oracle_text`
columns, because a trigram index on an expression the predicate does not compare
is an index the planner refuses - see that section below. 0003 has since
replaced the number index with one on the expression its read compares; the
count is still fifteen, because an index was swapped rather than added.

**`catalog_meta` is seeded with nine rows**, one per `CardGame.id`
(`mtg, pokemon, lorcana, yugioh, onepiece, swu, digimon, dragonball, gundam`,
read from `lib/domain/models/card_game.dart`). They carry zero counts and
`last_import_ok = false`, so "we have never imported this game" is a row the
client can read rather than a missing row it has to interpret. The insert is
`on conflict (game) do nothing`.

### The two places the environment forced a spelling

The design writes the opclass unqualified - `using gin (name gin_trgm_ops)`, and
`lower(name)` in place of `name` until 0002 moved the expression. The applied
index says `extensions.gin_trgm_ops`, because `pg_trgm` is installed in the
`extensions` schema - as §2.2 asks - and the unqualified name resolves only while
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

## 0002: the two trigram indexes, on the columns search compares

Step 0 built the two trigram indexes exactly as design §2.2 specifies them, on
`lower(name)` and `lower(coalesce(oracle_text, ''))`, and the section at the end
of this file recorded that the design contradicted itself: §4's `catalog_search`
compares the raw columns, and a GIN index is matched by the expression in the
predicate rather than by one that means the same thing. That note left the choice
to whoever writes §4's function, on the argument that the indexes belonged to
step 0 and the function to step 4. The argument was wrong. The function is
specified, the indexes are the part that was inconsistent with it, and waiting
costs a rebuild later plus a search that reads the whole table until then.

`tool/catalog/0002_search_index_expressions.sql`, one transaction and two index
definitions:

~~~sql
drop index public.catalog_cards_name_trgm;
create index catalog_cards_name_trgm on public.catalog_cards
  using gin (name extensions.gin_trgm_ops);

drop index public.catalog_cards_text_trgm;
create index catalog_cards_text_trgm on public.catalog_cards
  using gin (oracle_text extensions.gin_trgm_ops);
~~~

Both names are unchanged, so nothing that refers to these indexes has to change,
and the reversal is the two expressions it replaced.

### The measurement, before and after

The same query against the live table, as `postgres`, on the 3,208 Lorcana rows
step 1 imported, with `explain (analyze, buffers)` and costs off.

Before, with step 0's index on `lower(name)` in place:

~~~
Seq Scan on catalog_cards (actual rows=32 loops=1)
  Filter: (name ~~* '%elsa%'::text)
  Rows Removed by Filter: 3176
  Buffers: shared hit=345
~~~

The index was there and the planner read the table. The same search written the
way that index wanted it proves the index was fine and the expression was not:

~~~
Bitmap Heap Scan on catalog_cards (actual rows=32 loops=1)
  Recheck Cond: (lower(name) ~~ '%elsa%'::text)
  Heap Blocks: exact=28
  Buffers: shared hit=33
  ->  Bitmap Index Scan on catalog_cards_name_trgm (actual rows=32 loops=1)
        Index Cond: (lower(name) ~~ '%elsa%'::text)
        Buffers: shared hit=5
~~~

After 0002, on the predicate §4 actually writes:

~~~
Bitmap Heap Scan on catalog_cards (actual rows=32 loops=1)
  Recheck Cond: (name ~~* '%elsa%'::text)
  Heap Blocks: exact=28
  Buffers: shared hit=33
  ->  Bitmap Index Scan on catalog_cards_name_trgm (actual rows=32 loops=1)
        Index Cond: (name ~~* '%elsa%'::text)
        Buffers: shared hit=5
~~~

And both halves of §4's predicate together, which is the shape step 4 ships - a
BitmapOr over the two indexes rather than a scan of the table:

~~~
Bitmap Heap Scan on catalog_cards (actual rows=36 loops=1)
  Recheck Cond: ((name ~~* '%elsa%'::text) OR (oracle_text ~~* '%elsa%'::text))
  Filter: (game = 'lorcana'::text)
  Heap Blocks: exact=31
  Buffers: shared hit=41
  ->  BitmapOr (actual rows=0 loops=1)
        ->  Bitmap Index Scan on catalog_cards_name_trgm (actual rows=32 loops=1)
              Index Cond: (name ~~* '%elsa%'::text)
        ->  Bitmap Index Scan on catalog_cards_text_trgm (actual rows=12 loops=1)
              Index Cond: (oracle_text ~~* '%elsa%'::text)
~~~

345 buffers down to 33 on the name half, and no rows removed by the filter. The
`or` between the two columns is not a hole in this: a BitmapOr of two trigram
indexes is still an index plan, and it is the one step 4 will get.

Two things this measurement does not say, since both are easy to read into it.
The index on `name` answers `ILIKE` rather than only `LIKE` because pg_trgm
extracts its trigrams from the lower-cased text whichever case the column stores,
so nothing is lost by dropping the `lower()` - the case-insensitivity lives in
the operator class, not in the expression. And `catalog_cards_name`, the btree on
`(game, lower(name))`, was left exactly as it is: equality on the lowered name is
a predicate that expression does match.

### The rules-text index is on `oracle_text`, not on `coalesce(oracle_text, '')`

The first draft of 0002 kept §2.2's `coalesce` and dropped only the `lower()` -
which is what the note at the end of this file had suggested, and it does not
work. Measured in a transaction that was rolled back, each time with one trigram
index on the table:

~~~
oracle_text ILIKE '%elsa%'  with an index on coalesce(oracle_text, '')  -> Seq Scan
oracle_text ILIKE '%elsa%'  with an index on oracle_text                -> Bitmap Index Scan
~~~

The predicate names `oracle_text`; an index on `coalesce(oracle_text, '')` is a
different expression and is not matched, for the same reason as before. Nothing
is given up by indexing the bare column: a row whose `oracle_text` is null has no
trigrams to index and matches no `ILIKE` pattern either way. This is the one part
of step 4 that 0002 cannot settle in advance - if the function is ever written
with a `coalesce` around the column, the rules-text half of search goes back to
reading the table, and it will still return the right rows while it does.

### What the indexes cost now, and how much of the old figure was never the expression

`catalogue-import.md` measured 6,768 kB of index against 2,760 kB of rows before
this migration. The two trigram indexes were 1,253,376 B and 4,440,064 B at that
point - 5,693,440 B together - and rebuilding them on the raw columns brought them
to 524,288 B and 925,696 B, 1,449,984 B together. Every index on the table went
from 6,881,280 B to 2,637,824 B.

Most of that difference is not the change of expression. Building the same two
indexes fresh, on the same rows and with the expressions step 0 used, gives
512 kB and 904 kB - 1,416 kB, which is what the two new ones cost as well, because
the expression is not what makes a trigram index big. Measured in a transaction
that created all four variants and was rolled back, before anything was applied.
The old indexes had grown to nearly four times that under the importer's churn:
`pg_stat_user_tables` reports 3,208 inserts and 432 deletes on a table that holds
3,208 rows, which is writing rule 1 doing what it says - every card in a changed
set deleted and reinserted, every night. A GIN index gives that space back only at
vacuum.

Both readings matter and they point in different directions, so neither is
folded into the other here:

- the cost figure in the import doc is the churned size, not the settled one, and
  a fresh build of the same indexes is about a quarter of it;
- but the churn is real and it comes back, so the storage bill for these two
  indexes is a function of how often a set changes, not only of how many rows
  there are.

That is a step 2 and step 3 question - whether an import replaces cards or
updates them, and how the indexes are kept tidy - and it is recorded here because
it was found here.

### Reversing 0002

`tool/catalog/0002_search_index_expressions_down.sql` puts both indexes back on
the lowered expressions. It has been run, and the up file re-applied immediately
afterwards, as a round trip rather than a claim: after the down file `pg_indexes`
reported `lower(name)` and `lower(COALESCE(oracle_text, ''::text))` again and the
search went back to a `Seq Scan` with 345 buffers, which is what reversing this
migration means; after the up file the plans above were back and `catalog_cards`
still held its 3,208 rows and 24 sets. Nothing else needs undoing - 0002 changed
two index definitions and no column, policy, grant or row.

## 0003: the number index, on the expression its read compares

Step 4 is the three reads that cannot be written as one PostgREST filter -
`catalog_cards_by_ids`, `catalog_search` and `catalog_cards_by_number` - and it
is `tool/catalog/0003_read_functions.sql`. Three functions are not a schema
change, so what this file records of it is the one index it moved, and the fact
that it moved nothing else.

§4 compared `c.number_bare` to `ltrim(p_number, '0')`, so 0001 built
`catalog_cards_number_bare` on `(game, number_bare)` for exactly that predicate.
0003 corrected the comparison to `lower(number_bare)` on both sides, because the
case-sensitive one was a bug rather than a simplification: thirteen imported
Lorcana collector numbers carry letters, so the server answered nothing for
`24b` where the phone's own SQLite answered, and the two paths disagreeing about
one query is the failure the folding rules of §2.3 exist to prevent. That
correction is recorded where the predicate is written -
`catalogue-server-side.md` §4 - with the measurement that found it.

A btree index is matched by the expression in the predicate and by nothing that
merely means the same thing, so the corrected predicate would have left the old
index unused and the read on `catalog_cards_number` alone. 0003 creates the
replacement before dropping the old one, so there is no moment at which the read
has no index to use:

~~~sql
create index if not exists catalog_cards_number_nocase
  on public.catalog_cards (game, lower(number_bare));

drop index if exists public.catalog_cards_number_bare;
~~~

Measured on the live table the same day, with the deployed body taken out of
`pg_proc` and prepared with its parameters bound, `'24b'` against Lorcana is a
BitmapOr of the two indexes - `catalog_cards_number` for the exact comparison
and `catalog_cards_number_nocase` for the folded one, whose index condition is
`(game = $1) AND (lower(number_bare) = lower(ltrim($3, '0')))` - and it answers
the single row it should. The index is on the expression rather than on the
column, and `number_bare` itself is untouched, deliberately: its expression is
asserted against the committed collector-number vectors by two proofs, and
changing the column to fold case would change what those vectors mean.

### Reversing 0003

`tool/catalog/0003_read_functions_down.sql` drops the three functions and puts
`catalog_cards_number_bare` back, creating it before dropping its replacement.
Nothing else needs undoing: 0003 added no table, no column, no policy and no
privilege on any table, so the four tables, the posture and the account tables
are exactly as they were. The index is undone with the predicate rather than
left behind, because an index on `lower(number_bare)` with nothing comparing
`lower(number_bare)` is a nightly write cost for no reader at all.

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

That is 0001 only. 0002 reverses separately, in the section above, and the reason
it is worth saying here is that `0001_catalog_schema.sql` still holds the two
trigram index definitions on the lowered expressions - it records what ran, and
what ran is what it says. So reversing 0001 and applying it again puts the
unusable indexes back, and 0002 has to be applied again after it. A note in 0001
says the same thing where the definitions are.

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

## What step 4 inherits, now that the indexes have moved

This section used to record an inconsistency rather than a decision. Design §2.2
specified the two trigram indexes on `lower(name)` and
`lower(coalesce(oracle_text, ''))` and §4's `catalog_search` compares `c.name`
and `c.oracle_text`; a GIN trigram index is used only when the predicate's
expression matches the indexed expression, so the index that existed to make
search work over a quarter of a million rows would not have been used. The first
measurement of it was synthetic - a throwaway table of 50,000 rows inside a
rolled-back transaction, with `pg_trgm` 1.6:

~~~
name ILIKE '%card49999%'          with an index on lower(name)   -> Seq Scan
lower(name) LIKE '%card49999%'    with an index on lower(name)   -> Bitmap Index Scan
name ILIKE '%card49999%'          with an index on name          -> Bitmap Index Scan
~~~

That was left for whoever writes §4's function, because the indexes were step
0's and the function was step 4's. It should not have been: the inconsistency was
in the indexes, the predicate is settled, and the second measurement - on the
real table, above - says the same thing with real rows in it. 0002 has moved the
indexes, so §4's two `ILIKE`s are the indexed expressions and step 4 changes
nothing:

- `c.name ilike '%' || p_query || '%'` uses `catalog_cards_name_trgm`;
- `c.oracle_text ilike '%' || p_query || '%'` uses `catalog_cards_text_trgm`;
- the two together are a BitmapOr of both, which is the plan in the section
  above.

What step 4 must not do is tidy either predicate into `lower(...)` or
`coalesce(...)`. Both would work, both would return exactly the right rows, and
both would leave the index unused with no error and nothing in the plan that
looks wrong to a reader who is not looking for a Seq Scan.

The one thing still open is not about the expression but about the size:
`catalogue-import.md`'s cost estimate for these two indexes is the size they
reach under the importer's delete-and-reinsert churn rather than the size a fresh
build has, and the difference is a factor of four. That is recorded above, and it
belongs to step 2 rather than to step 4.
