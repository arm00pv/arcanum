# Does the catalogue fit the plan we pay for?

Status: measurement. Answers open question 1 of `catalogue-server-side.md` §9.
Measured 2026-09-21 against the live project and the live host. Every number
below says whether it was measured or estimated, because the difference is the
whole point of writing it down.

## The short answer

**No, not on the free plan, and the reason to care is not the size.**

The size comes out somewhere between 320 MB and 400 MB against a hard 500 MB
ceiling, which is uncomfortable rather than impossible. What settles the
question is the line next to it in Supabase's own pricing table:

> Automatic backups — **Not included** on Free; 7 days on Pro.

A free project has no automatic backup and no point-in-time recovery. Supabase's
backup documentation says so in as many words and tells free-tier projects to
export their own data and keep it off-site. A catalogue is reproducible - it can
be fetched from the providers again tomorrow. A collector's vault is not. So the
plan decision is really about the vault, and the catalogue size is the smaller
half of it.

## What a card row costs

Measured, from the 3,208 Lorcana rows that are already imported:

| | bytes | per row |
| --- | --- | --- |
| heap (the row data) | 2,760 kB | 860 B |
| indexes | 2,568 kB | 800 B |
| **total** | **5,368 kB** | **1.67 kB** |

So a card costs about 1.7 kB once it is indexed, and roughly half of that is the
indexes. The breakdown of the row data itself:

| column group | bytes | share of the row |
| --- | --- | --- |
| \`extras\` (jsonb) | 642 kB | 24.5% |
| \`oracle_text\` (rules text) | 433 kB | 16.5% |
| \`flavor_text\` | 124 kB | 4.7% |
| \`type_line\` | 88 kB | 3.4% |
| \`name\` | 86 kB | 3.3% |
| everything else | 1,253 kB | 47.6% |

Two things follow that were not obvious before measuring.

**Rules text is cheap, and its index is not.** \`oracle_text\` is 16.5% of the row
data, but \`catalog_cards_text_trgm\` - the trigram index over it - is 904 kB,
the single largest index on the table and 35% of all index space. Dropping
rules text from the server catalogue saves 433 kB of rows **and** 904 kB of
index, which together is **25% of the whole table**.

**\`extras\` is the largest single column and buys nothing.** At 642 kB it is
bigger than rules text, it is not indexed, and it is a jsonb of provider
leftovers. Nobody has measured what the app actually reads out of it.

## How many rows the nine games are

Measured 2026-09-21, each from the source the importer would read:

| game | rows | where the number comes from |
| --- | --- | --- |
| mtg | **107,632** | Scryfall \`default_cards\`; the count is the API's own \`total_cards\` for all printings since 1993 |
| yugioh | **44,752** | distinct printing ids in the live sampler's price history. The app's Yu-Gi-Oh! ids are per *printing*, not per card, so this - not the 14,549 cards - is the row count |
| pokemon | **23,735** | rows in the live sampler's \`poll_state\`, which is one row per TCGdex card. TCGdex's own card list agrees at 23,736 |
| lorcana | **3,208** | imported and verified |
| onepiece, swu, digimon, dragonball, gundam | *estimated* 10,000–25,000 | **not measured.** tcgcsv is walked per group and nothing on this host has counted it |
| **total** | **189,000–204,000** | |

Yu-Gi-Oh!'s 44,752 is a floor rather than a count: the sampler only stores a
series for a printing that has a price, so a printing the source prices at
nothing is invisible to it.

## What that projects to

At the measured 1.67 kB per row, 190,000 rows is **317 MB** and 204,000 is
**341 MB**.

That is the floor, and it is not the honest estimate, for one reason: Magic is
57% of the rows and its rules text is much longer than Lorcana's. Lorcana's
\`oracle_text\` averages 151 characters; a Magic card's averages nearer 300. If a
Magic row is 30% heavier than the Lorcana average the total grows by about a
sixth, to **370–400 MB**.

Against a **500 MB** database ceiling, before autovacuum headroom and before the
bloat a nightly full rewrite of a game leaves behind. The honest reading is that
it does not fit with any margin, and it certainly does not fit eight games plus
Magic while leaving room to grow.

## The three ways out, and what each costs

**A. Pay for Pro.** $25 a month. 8 GB of database instead of 500 MB, and daily
backups retained for seven days instead of none. It answers the size question
and the backup question in one move. The catalogue as designed then fits with
room to spare, and nothing in \`catalogue-server-side.md\` has to change.

**B. Drop \`oracle_text\` from the server catalogue.** Measured saving: 25% of
the table, bringing the estimate to roughly 280–300 MB. Rules-text search stays
on the provider path, so a search for words inside a card's rules answers only
from what the device has cached - which is what it does today. This is the
fallback §9 already proposes, and it is a feature given up rather than a bug:
"search by what the card does" is a genuine thing to lose.

**C. Import fewer games.** Lorcana plus the five tcgcsv games is 13,000–28,000
rows - about 50 MB, comfortably inside the free plan. It is also the set the
web build serves worst today, so it is the largest visible improvement for the
least data. Magic, Pokémon and Yu-Gi-Oh! stay on the provider path on the web
exactly as they are now on the phone.

**A and B are not exclusive**, and neither is A and C. If the plan is upgraded
the size stops mattering and the answer becomes "import everything, keep rules
text"; if it is not, the choice is between losing rules-text search (B) and
losing three games (C).

## What is deliberately not decided here

The same question as §9.3 of the design doc is still open and still needs a
person: tcgcsv republishes TCGplayer's product catalogue, and re-hosting it in
our own database is redistribution rather than a read-through. That is a terms
question, not a size one, and it gates option C as much as it gates step 3.

## How to re-measure

The four numbers that matter, and where to get them:

~~~sh
# rows and the cost of one, from the live project
psql "$SUPABASE_DB_URL" -c "select count(*) from public.catalog_cards"
psql "$SUPABASE_DB_URL" -c "select pg_size_pretty(pg_total_relation_size('public.catalog_cards'))"

# how many rows the next game would add, from the sampler that already knows
python3 -c "import sqlite3; c=sqlite3.connect('file:/home/zixen/arcanum/data/yugioh_prices.db?mode=ro',uri=True); print(c.execute('select count(distinct card_id) from history').fetchone()[0])"

# what Scryfall says its own bulk file holds
curl -s 'https://api.scryfall.com/cards/search?q=year%3E%3D1993&unique=prints' | head -c 200
~~~

Re-measure after the first big import rather than trusting the projection: the
whole of this document is one small game's rows multiplied by a number. The
next real import is the measurement, and everything above is a forecast.
