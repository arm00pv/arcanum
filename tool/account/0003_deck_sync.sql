-- Arcanum account, migration step 3: a deck gets a shape it can travel in, and
-- the place its cards will live.
--
-- The account is the collection and it is not a deck. public.decks records that
-- a deck was named - five columns, no contents, and nothing in this repository
-- has ever written to it (docs/catalogue-schema.md:381-390) - while a deck the
-- collector actually builds lives in one device's SQLite and nowhere else. A
-- deck built on the phone never appears in a browser, a deck built in a browser
-- never appears on the phone, and the contents of either exist in one device's
-- database and are nowhere else.
--
-- The design is docs/deck-sync.md. This file is its step 0 (section 7) and
-- nothing beyond it: the server shape, empty, with a proof. There is no client
-- code here, no local schema, no sync and no UI, and none of them can be
-- verified until this shape is fixed.
--
-- What a deck needs, and why each piece of it is here:
--
--   * An identity the client owns. public.decks.id is generated always as
--     identity, so a client cannot supply a value for it - Postgres refuses the
--     statement rather than ignoring the value - and a client cannot name a
--     conflict target it cannot supply a value for. Losing the upsert means
--     losing a push that is safe to repeat after a dropped connection, which is
--     the property the whole sync is built on. sync_id is that identity, unique
--     with user_id. It is declared not null with NO default, and that is a
--     decision rather than an omission: with default gen_random_uuid() a push
--     that forgot the column would insert a fresh deck under a fresh id on
--     every attempt - one duplicate per retry, silently - where without a
--     default the same mistake is a not-null violation and a refused request.
--   * The rest of what a deck is. format_id and notes are what DeckDao.createDeck
--     already writes locally; a deck pushed to a server that had no format_id
--     comes back as "Unknown format", which is the same class of loss as a deck
--     arriving with no cards in it.
--   * A mark instead of a delete. deleted_at, for the reason migration 0001
--     added one to collection_entries: a push that cannot see a removal undoes
--     it, so a deck deleted on one device comes back on every other on the next
--     pull. A deck's deletion does not touch its lines, because a deck revived
--     by a later edit has to be revived whole rather than empty.
--   * A stamp per field the deck can be edited by independently: name_at,
--     format_at and notes_at. DeckDao._touch stamps the deck's updated_at every
--     time a card is added, set, moved or removed, so with one clock for the
--     row a rename on one device is reverted by an afternoon of adding cards on
--     another. updated_at keeps exactly the meaning it already has - the stamp
--     that orders the deck list - and no merge decision reads it.
--   * Its contents, as rows in a table rather than as a jsonb payload on the
--     deck. public.deck_cards is shaped like collection_entries: one row per
--     (deck, card, board), keyed so that a push is an upsert and safe to
--     repeat. The argument for rows is conflict granularity. With a whole-deck
--     payload the second device's push replaces the first device's list
--     wholesale, and nothing afterwards - not the account, not either device,
--     not any screen - can tell that an afternoon's work was dropped. A rule
--     that silently loses somebody's edits was ruled out before the design was
--     written (docs/deck-sync.md section 1.2).
--
-- Three things were measured against the live project (wqycllzbwbhqiqlmbwcu)
-- before this file was written, because the design could only leave them open
-- or assume them:
--
--   1. public.decks.user_id has NO default, and it needs one. Measured:
--      information_schema.columns gives column_default null for decks.user_id
--      and 'auth.uid()' for collection_entries.user_id. The collection's push
--      relies on that default rather than sending the owner it already knows
--      from its session, so a deck's push will want the same thing and the
--      default has to be there for it to have it. It is set below. The other
--      answer the design allowed - the client sends the owner itself - would
--      also work, because the policy's WITH CHECK (auth.uid() = user_id) still
--      prevents it from lying about which account the row belongs to.
--   2. The account tables' grants are Supabase's default and are wider than they
--      need to be. Measured: anon and authenticated each hold INSERT, SELECT,
--      UPDATE, DELETE, TRUNCATE, REFERENCES and TRIGGER on decks and on
--      collection_entries - and the raw ACL holds MAINTAIN as well, which
--      information_schema does not list, so the true figure is eight privileges
--      rather than seven. Row level security does not apply to TRUNCATE: a
--      grant of it is not covered by the policy that protects the rows, so a
--      role that can connect could empty the table without the policy being
--      consulted at all. The new table is granted only what a client needs.
--   3. decks holds zero rows and collection_entries holds seven. So the not null
--      columns below can be added to decks with no backfill - there is no
--      existing row to give a wrong value to - and collection_entries needs
--      nothing at all.
--
-- What this file does not do:
--   * it does not change the grants on decks or on collection_entries. The
--     default described above is wrong on both of them, and correcting it is a
--     separate decision about tables that hold a real collector's rows, argued
--     on its own. This file corrects the default only where it is creating the
--     table, which is the one place it costs nothing and breaks nobody.
--   * it does not add public.deck_cards to the supabase_realtime publication.
--     Streaming the deck tables is step 4 of the design's own table (section 7),
--     where it is 0004_realtime_decks.sql, written with the guard that makes a
--     table already streamed a no-op. A table being created and a table being
--     streamed are two separate steps, and this file is the first one.
--   * it does not touch public.collection_entries at all. Not a column, not a
--     constraint, not a policy, not a grant. The proof fingerprints that table
--     before and after, because "this migration is about decks" is a claim that
--     has to be measured on the table it is not about.
--   * it does not validate format_id against anything. The account stores the
--     format as an opaque string and the format rules stay in Dart, where the
--     card's type line and colour identity are (docs/deck-sync.md section 1.3).
--     The consequence is honest: the account will hold decks that are not legal
--     in their format, including decks that became illegal while they sat
--     there. It already holds them - the phone stores them - and nothing here
--     turns the account into a validator.
--   * it does not delete, update or backfill a single row. decks is empty, and
--     its five existing columns, its one policy, its grants and its index are
--     exactly as they were.
--
-- If decks were not empty, the first statement below would fail loudly rather
-- than invent a value: sync_id, format_id, updated_at and the rest are added
-- not null, and there is no default for a backfilled identity that would not be
-- a guess about which deck is which.
--
-- Reversal: 0003_deck_sync_down.sql. Read its header before running it - it
-- drops the deck contents with the table and the client's identities with the
-- column, and neither is recoverable from the account afterwards.

begin;

-- 1. The deck row. Eight columns, added in one statement because they are one
--    change to one table and there is no ordering between them.
alter table public.decks
  add column sync_id    uuid        not null,
  add column format_id  text        not null default '',
  add column notes      text,
  add column updated_at timestamptz not null default now(),
  add column deleted_at timestamptz,
  add column name_at    timestamptz,
  add column format_at  timestamptz,
  add column notes_at   timestamptz;

-- The default decks.user_id never had. Measured absent, not assumed absent -
-- see the header. It is what lets a push omit the owner exactly as the
-- collection's push does.
alter table public.decks
  alter column user_id set default auth.uid();

-- The client's identity, and the conflict target a push upserts against. A
-- constraint rather than a bare unique index because this is a rule about the
-- table and not a tuning decision about a query: two decks of one account must
-- not share a sync_id, and the pair is what a foreign key from the contents
-- table points at.
alter table public.decks
  add constraint decks_user_sync unique (user_id, sync_id);

comment on column public.decks.sync_id is
  'The identity the client minted for this deck, before the account had ever '
  'seen it. The only identity that crosses the wire: the account''s own id is '
  'generated always as identity and a client cannot supply one, and the device''s '
  'local integer id means nothing here. Unique with user_id, which is the pair a '
  'push upserts against and the pair public.deck_cards points at. Deliberately '
  'not null with no default: a payload that forgot it is refused rather than '
  'inserted as a second deck under a fresh id.';

comment on column public.decks.updated_at is
  'When this deck was last changed. It orders the deck list and nothing else: '
  'the merge reads name_at, format_at and notes_at, because a single clock for '
  'the row cannot tell a rename on one device from an afternoon of adding cards '
  'on another.';

comment on column public.decks.deleted_at is
  'When this deck was deleted, or null while it is present. A tombstone rather '
  'than a deletion, for the reason collection_entries.deleted_at is one: a push '
  'that cannot see a removal undoes it, and the deck would come back on every '
  'device on the next pull. A deck''s deletion does not touch its lines, so that '
  'a deck revived by a later edit is revived whole rather than empty. Nothing '
  'purges these rows: a purged tombstone is a deletion that a device which has '
  'been offline for a month can undo.';

comment on column public.decks.name_at is
  'When the deck''s name was last edited, or null if it has never been edited '
  'since the client began stamping. The stamp that resolves a name conflict, and '
  'one of the three clocks that make this row several independent edits rather '
  'than one.';

comment on column public.decks.format_at is
  'When the deck''s format was last edited, or null if it never has been. Read '
  'by the merge exactly as name_at is, and independently of it.';

comment on column public.decks.notes_at is
  'When the deck''s notes were last edited, or null if they never have been. '
  'Nothing in the app can set notes yet, so this clock costs nothing while it is '
  'unused - and a later release that gives notes a screen will not need a '
  'migration to make them merge correctly.';

-- 2. The contents. One row per (deck, card, board), shaped like a holding:
--    user_id on the row so that the policy is a plain comparison against a
--    column of the table rather than a join to decks, and so that the table can
--    be filtered by account when it is streamed - a table with no user_id
--    cannot be filtered that way at all.
create table public.deck_cards (
  user_id      uuid        not null default auth.uid(),
  game         text        not null,
  deck_sync_id uuid        not null,
  card_id      text        not null,
  board        text        not null default 'main',
  quantity     integer     not null default 1,
  sort         integer     not null default 0,
  category     text        not null default '',
  updated_at   timestamptz not null default now(),
  deleted_at   timestamptz,
  constraint deck_cards_pkey primary key (user_id, deck_sync_id, card_id, board),
  constraint deck_cards_deck_fkey
    foreign key (user_id, deck_sync_id)
    references public.decks (user_id, sync_id)
    on delete cascade
);

-- game is copied onto every line and cannot drift: nothing that changes a
-- deck's name, format or notes has any path that changes its game, so a line's
-- game is fixed when the line is created. It is what makes one pull per game
-- possible - "every line of this game" - rather than a pull per deck.
create index deck_cards_user_game on public.deck_cards (user_id, game);

comment on table public.deck_cards is
  'A deck''s lines. Keyed by (user_id, deck_sync_id, card_id, board) - the same '
  'shape as the collection''s unique index and for the same reason: it is what '
  'makes a push an upsert, so a push is safe to repeat after a connection drops. '
  'A card can be on two boards of one deck, so the board is part of the key. '
  'sort and category are on the row and deliberately not in the key: two '
  'devices can hand one line two different sort numbers, and the answer is that '
  'the later edit wins - a cosmetic disagreement, not two rows. There is no '
  'created_at, because a server row is a local row and the local table has none.';

comment on column public.deck_cards.deleted_at is
  'When this line was removed from its deck, or null while it is there. A '
  'tombstone for the same reason the deck''s is one, and it keeps the slot that '
  'the primary key holds, so re-adding the card revives this row in place with '
  'the new count rather than inserting a second one.';

comment on column public.deck_cards.updated_at is
  'When this line was last changed. The whole of the conflict rule for a line: '
  'the later stamp wins and a tie goes to the account row.';

-- 3. Ownership, in the shape the two account tables already have: one policy,
--    for every command, to the owner.
alter table public.deck_cards enable row level security;

create policy "a collector sees their own deck cards"
  on public.deck_cards
  for all
  to public
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- 4. Grants. Supabase's default privileges for this schema hand a new table
--    every privilege there is - INSERT, SELECT, UPDATE, DELETE, TRUNCATE,
--    REFERENCES, TRIGGER and MAINTAIN - to anon, authenticated and service_role.
--    For a client's table that is wider than it needs to be, and one of the
--    extras is not covered by the policy above: row level security does not
--    apply to TRUNCATE, so a granted TRUNCATE is a way to empty the table that
--    never consults the row's owner. The other two extras are about the table's
--    shape rather than its rows, which is not something a client has any
--    business doing either.
--
--    So the default is revoked and exactly four privileges are granted back:
--    the four operations the sync performs. service_role is a server-side role
--    rather than a client and is given the same four, so that an operator's tool
--    can still read and repair the table; it is deliberately not given the
--    extras either. postgres owns the table and holds every privilege by virtue
--    of owning it - a REVOKE cannot take those away and does not need to.
revoke all on table public.deck_cards from anon, authenticated, service_role;

grant select, insert, update, delete on table public.deck_cards
  to anon, authenticated, service_role;

commit;
