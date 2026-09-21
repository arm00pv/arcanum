# Card-data sources for the four games still on tcgcsv

Written 2026-09-21, after the Gundam move, as the survey the next move starts
from. Section 3 of [catalogue-server-side.md](catalogue-server-side.md) is the
specification a move is built against and
[catalogue-import-gundam.md](catalogue-import-gundam.md) is what one move
actually cost; this file is the step before either of those - which sources
exist for the four games still catalogued only through tcgcsv, and which of
them a browser can read.

**Its recommendation was taken: Star Wars: Unlimited moved first, onto the
official FFG API at `https://admin.starwarsunlimited.com/api/`.**
[catalogue-import-swu.md](catalogue-import-swu.md) is that move, both halves: the
app reads the publisher's cards, sets, search and art directly, and
`arcanum-swu-import.timer` keeps the shared catalogue's copy current nightly.
The survey's other three games stand as written, and the costs it warned about
for this one - no price of any kind, an undocumented internal API - are what the
move paid.

A measured survey. Every URL, status code, header value,
count and byte size below was produced by a real request from this machine
(curl.exe on Windows, PowerShell 5.1) in the session that wrote this file.
Nothing was read off a vendor's documentation and repeated as fact; where a
number could not be obtained it says **not measured** instead.

The four games are the ones still catalogued only through tcgcsv, i.e. the web
build's worst case: no Sets tab until a set is opened, and no search across the
game. tcgcsv is **not** a candidate here - it is what is being replaced - so it
appears nowhere below except as a baseline where a comparison is unavoidable.

Method, so the numbers can be reproduced:

- Data probes: `curl.exe -s -g -L -D - -o <file> -H 'Origin: https://arcanum.example' -A '<UA>' <url>`
- CORS is read from the **exact** `Access-Control-Allow-Origin` header of the
  response the browser would receive, with a distinct non-empty Origin sent
  (`https://arcanum.example`), so an origin echo is distinguishable from `*`.
  A second probe with `Origin: https://example.org` was used on the one host that
  turned out to echo.
- HTML pages were fetched with a Chrome UA; API endpoints with a Chrome UA as
  well, except the Heroicc bulk file (fetched with `Arcanum/1.0`) - noted where
  it matters.
- No source here needs a credential that this session held, and no credential
  was printed or stored.

## Measured after the survey: TCGplayer's image CDN stopped answering

On 2026-09-21, while the Star Wars: Unlimited move was being checked:

~~~
GET https://tcgplayer-cdn.tcgplayer.com/product/712892_400w.jpg
  403  application/xml  <Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>
~~~

Every product image tcgcsv publishes is refused - from the droplet *and* from a
residential machine, with no `User-Agent` and with a browser's, with and without a
`Referer`, and for the `200w`, `400w` and `in_1000x1000` forms alike. So it is not
a block of our host and not a header we can set: the host that tcgcsv's image URLs
point at no longer serves them. One Piece, Digimon and Dragon Ball art is a
card-back placeholder in the web build and on a phone until a working address is
found, and the relay is not at fault - it answers 502 because upstream does, which
is exactly what `/arcanumweb-api/art/tcgplayer/...` returned when a live browser
asked for a One Piece set's cards.

It sharpens what the rest of this file is measuring: for the three games that
remain, a candidate source's **art host** is now worth as much as its data host,
and `api.swu-db.com` - the one tcgcsv-era source that still carries prices - is
refused by the browser for both. The game that has moved reads its art from
`cdn.starwarsunlimited.com`, which answers 200 with `*`.

## Why the last two games stay where they are

Written after Gundam, Star Wars: Unlimited and Digimon had moved, and after measuring
the two that were left more closely than the survey itself did. Both verdicts are
measurements rather than preferences, and both are the kind of thing that is much
cheaper to find now than after a move.

### One Piece: optcgapi has no id a collection can hold

The source is attractive - it is the only candidate of the four that carries prices
(5,374 of its 5,549 records quote a market price, median $0.43, scraped daily) - and
its API is fully browser-callable: every route answers `Access-Control-Allow-Origin:
*`. Its art needs the relay (the media host sends no ACAO), which is a cost this
project has paid twice already.

It fails on the one thing a catalogue cannot be casual about. Four endpoints were
pulled whole on 2026-09-21 - `/allSetCards/` 3,654, `/allSTCards/` 626, `/allPromos/`
1,082, `/allDonCards/` 187, 5,549 records between them - and over all of them:

~~~
distinct card_image_id         5,117 of 5,549
distinct card_image_id|set_id  5,509 of 5,549
distinct card_image (the URL)  5,408 of 5,549
~~~

**No field, and no simple composite of them, is unique.** The near-miss is the image
URL, and it is the wrong answer twice over: 141 records share one (they are the
records with no image at all, which would collapse into a single row), and a URL that
carries a scraper's own hash suffix - `OP04-089_VSSo9UA.jpg` beside `OP04-089.jpg` for
what the source files as two printings of one card - is not an address anything should
be keyed by.

What makes a printing distinct here is the *name*: a tournament promo is filed under
its base card's number with the base set's number spelled without the dash
(`OP01-077` under `OP01`) and is told apart only by `Perona (Championship 2024
Finalist Card Set Vol. 2)`. An id built from the name is an id that moves whenever the
source edits a name, and every holding that names it renders as "--".

The failure this avoids is the one the Gundam report was written about: an id scheme
that stores, looks unique and silently merges two of a collector's holdings into one
row. One Piece therefore stays on tcgcsv, whose TCGplayer product ids are stable and
unique even though its Sets tab and its search are nothing. What would change the
verdict is a source that names a printing once and never again.

### Dragon Ball: there is nothing to move it to

Measured in the same survey, and unchanged: no keyless JSON source exists for Fusion
World. `apitcg.com` and JustTCG both answer `401 API key is required`; Bandai's own
card list is HTML with no `Access-Control-Allow-Origin` and ignores its own `page`
parameter (pages 1 to 6 byte-identical), and its art host refuses the browser too.
Without a source, the game keeps tcgcsv and its TCGplayer ids - which is the same
answer as One Piece's, reached from the opposite direction.

### What that leaves

Three of the five games tcgcsv used to catalogue have left it: Gundam (gcgapi), Star
Wars: Unlimited (the publisher's own database) and Digimon (Heroicc, client half). The
two that remain are not a backlog: one has no source, and the other has a source whose
ids cannot be trusted. The relay still serves their catalogues, and their art is
served by nobody: tcgplayer-cdn.tcgplayer.com refuses every product image with `403
AccessDenied` (measured above), so those two games draw the card-back placeholder on
the web build and on a phone. That is the live cost of their staying, and it is
written here rather than in a bug tracker because nothing in this project can fix it.

## How to read CORS below

A browser is allowed to read a cross-origin response only if the response
carries exactly one `Access-Control-Allow-Origin` value that is either `*` or
the page's own origin. Two values (`*, *`) are a refusal, and so is **no
header at all** - which is the state of most of the image hosts in this survey.
A refused image is not a broken image: it never arrives, and the app draws the
card-back placeholder. A refused JSON endpoint is worse, because the catalogue
path itself dies.

### Every host measured, and what it said

| Host / path | What it serves | `Access-Control-Allow-Origin` |
| --- | --- | --- |
| `api.gcgapi.com/v1/sets` | Gundam JSON (baseline for this method) | `*` |
| `optcgapi.com/api/allSets/`, `/allSetCards/`, `/sets/OP-01/`, `/sets/card/OP01-001/`, `/sets/filtered/?card_name=Luffy`, `/allSTCards/`, `/allPromos/`, `/allDonCards/`, `/sets/card/twoweeks/OP01-001/` | One Piece JSON | `*` |
| `optcgapi.com/media/static/Card_Images/OP01-001.jpg` | One Piece art | **none** (refused) |
| `en.onepiece-cardgame.com/images/cardlist/card/OP17-001.png` | Bandai's own One Piece art | **none** (refused) |
| `admin.starwarsunlimited.com/api/card-list`, `/api/cards`, `/api/card/details/5` | SWU JSON, official | `https://arcanum.example` (echo; `https://example.org` echoed as itself), plus `Access-Control-Allow-Credentials: true` |
| `cdn.starwarsunlimited.com/…png` | SWU art, official | `*` |
| `api.swu-db.com/cards/search?q=set:sor`, `/cards/sor`, `/cards/sor/10`, `/catalog/traits` | SWU JSON, community | **none on every GET**. Its `OPTIONS` preflight answers `Access-Control-Allow-Origin: *` with `Allow-Methods: GET,OPTIONS` - which does not help: a simple cross-origin GET is never preflighted. Refused. |
| `cdn.swu-db.com/images/cards/SOR/010.png` | swu-db art (302 target) | **none** (refused) |
| `api.heroi.cc/releases/en`, `/releases/en/bt-08`, `/cards/en/BT8-022`, `/search?q=agumon`, `/bulk-data` | Digimon JSON, official-sourced | `*` |
| `images.heroi.cc/cards/en/BT8-022.webp` | Heroicc art | **none** (refused) |
| `assets.heroi.cc/bulk-data/en-2026-07-03-013655.json` | Heroicc bulk file | `*` (+ `Access-Control-Allow-Methods: GET`) |
| `digimoncard.io/api-public/search`, `/getAllCards` | Digimon JSON, community | `*` (header spelled lower-case) |
| `www.dbs-cardgame.com/fw/images/cards/card/en/FB06-002.webp` | Fusion World art, official | **none** (refused) |
| `www.dbs-cardgame.com/fw/en/cardlist/` | Fusion World card list, official | **none** (HTML page) |
| `api.justtcg.com/v1/cards` | multi-game JSON | `*` - but 401 `{"error":"API key is required","code":"MISSING_API_KEY"}` |
| `apitcg.com/api/one-piece/cards` (308 -> 200) | multi-game JSON | `*` - but `{"error":"API key is required, register into: https://apitcg.com/platform"}` |

Two summary facts follow from that table, and both matter more than any
individual count:

1. **The only source in this survey whose JSON *and* art a browser may call
   directly is the official Star Wars: Unlimited API and its CDN.** Art needs
   no relay there.
2. **Every image host found for One Piece, Digimon and Dragon Ball Fusion
   World refuses the browser** - including Bandai's own (`en.onepiece-cardgame.com`,
   `www.dbs-cardgame.com`), exactly as `www.gundam-gcg.com` did for Gundam. Any
   of those three moves adds a `CardArt._relayed` entry and a relay redeploy, the
   same cost the Gundam move paid.

---

## 1. onepiece (One Piece Card Game)

### C1a. OPTCG API - **rank 1 for this game**

- **Base:** `https://optcgapi.com/api/`. Endpoints taken from the site's own
  documentation page (`https://optcgapi.com/documentation`, 67,394 bytes) and then
  called: `/allSets/`, `/allSetCards/`, `/allSTCards/`, `/allPromos/`,
  `/allDonCards/`, `/sets/{set_id}/`, `/sets/card/{card_id}/`,
  `/sets/filtered/?card_name=`, `/sets/card/twoweeks/{card_id}/`.
- **Key / account:** none. The documentation states it plainly: *"The API doesn't
  require authentication, and it is open for anyone to use."*
- **CORS:** `Access-Control-Allow-Origin: *` on every JSON endpoint measured
  (nine of them). The art host is the exception - see Art.
- **Completeness, measured:**
  - set list: `/api/allSets/` -> **22 sets**, 1,244 bytes:
    OP-01…OP-17, EB-01…EB-04, PRB-01, PRB-02 (with two odd ids, `OP14-EB04` and
    `OP15-EB04`). **No card count per set and no release date** on this endpoint.
  - all cards of the sets: `/api/allSetCards/` -> **3,654 records**, 2,481,702
    bytes, covering all 22 set ids in one request.
  - starter decks: `/api/allSTCards/` -> **626 records**, 420,278 bytes, 36 set
    ids.
  - promos: `/api/allPromos/` -> **1,082 records**, 747,359 bytes.
  - DON!!: `/api/allDonCards/` -> **187 records**, 82,067 bytes.
  - one set: `/api/sets/OP-01/` -> **154 records**, 98,190 bytes.
  - one card by id: `/api/sets/card/OP01-001/` -> **2 records** (the base
    printing and its parallel), 1,093 bytes.
  - search: `/api/sets/filtered/?card_name=Luffy` -> **120 records**, 88,771
    bytes. This is a name search; whether it also covers rules text is **not
    measured**.
  - prices: `/api/sets/card/twoweeks/OP01-001/` -> 2 records carrying
    `Day1_Inventory_Price` … `Day13_Market_Price`, 2,522 bytes.
- **Id scheme:** this is the source's weak point and it was measured twice.
  `card_set_id` is the printed number (`OP01-001`) and is **not unique**: 3,654
  records carry only 2,379 distinct numbers, and **756 numbers have more than one
  record** (OP05-119 has nine, OP05-074 and OP09-093 seven each). Parallels add a
  suffix to a second field, `card_image_id` (`OP01-001` -> `OP01-001_p1`), but
  that field is **not unique either**: 3,604 distinct values over 3,654 records,
  because the same printed number is reprinted in another set with the same
  suffix (OP04-089 exists in OP-04 and in PRB-01; OP03-081 `_p1` exists in both
  OP-03 and OP-04). Only the image URL itself is unique across the 3,654 (3,654
  of 3,654) - which is a poor id, because the file names are not stable
  (`OP04-089.jpg` vs `OP04-089_VSSo9UA.jpg` for the same number in two sets). A
  correct id here is a composite of at least set id and image id, or the URL.
  **Alternate arts are separable, which is the property that matters** - they are
  separate records with a distinguishing name ("… (Parallel)") and a
  distinguishing image - but the id has to be built, not forwarded, and the
  importer and the Dart client must build it identically.
- **Art:** `https://optcgapi.com/media/static/Card_Images/OP01-001.jpg` -> 200,
  153,213 bytes, **measured 600x838** (decoded with System.Drawing), and
  **no `Access-Control-Allow-Origin` at all**. A browser cannot draw this art;
  it would need a relay entry. Bandai's own host
  (`https://en.onepiece-cardgame.com/images/cardlist/card/OP17-001.png`, 200,
  197,837 bytes, 600x838) sends no ACAO either, so One Piece art needs the relay
  whichever source is chosen.
- **Prices:** yes, and this is unique in this survey. Every record carries
  `market_price` and `inventory_price` as numbers, plus `date_scraped`
  (2026-09-20 / 2026-09-21 in the payloads I read), plus a 13-day per-card
  series endpoint. **No TCGplayer product id** - so the app's price-history join
  key (`extras['tcgplayerId']`) cannot be filled from here; the series would have
  to come from this source's own 13-day window instead of the companion's
  history.
- **Terms, quoted from its documentation page:** *"This API is consumption
  only! You can't just submit cards directly into our database! You can only use
  GET requests on this API."*; *"please try not to do an insane amount of API
  calls each day!"*; *"the API is run by me on my VPS that I pay for monthly, so
  please try not to hurt my wallet too much."*; *"Created by DomoSlime (AKA
  Dom). One Piece and the One Piece Trading Card Game data are trademarks of
  Eiichiro Oda, Bandai, Shonen Jump, and Viz Media. Please support the official
  release of the Trading Card Game, Manga, and Anime!"* Redistribution into our
  own database: **not stated**. There is no rate limit expressed as a number,
  only a request not to abuse it, and no SLA - it is one person's VPS.

### C1b. Bandai's own English card database - rank 2

- **Base:** `https://en.onepiece-cardgame.com/cardlist/`.
- **Key / account:** none.
- **CORS:** the card list is an HTML page and sends **no ACAO**; its images send
  **no ACAO** either. Not browser-callable for data or art.
- **Completeness, measured:** `?search=true` -> 302 -> 200, 453,474 bytes of HTML
  containing **810 card-number matches**, with parallel art paths in the same
  page (`/images/cardlist/card/OP17-001.png`, `…_p1.png`, `…_p2.png`). No
  JSON endpoint is referenced from the page; I did not find one, and I did not
  invent one. This is a scrape of a publisher's HTML, which means a per-card
  parser to maintain, and no search endpoint of its own beyond the form.
- **Id scheme:** printed number plus a parallel suffix in the image name; the
  HTML does not publish an id. **Not measured** beyond that.
- **Prices:** none on the card list. This source quotes no price.
- **Terms:** **not measured** (I did not read Bandai's terms page).

### C1c. apitcg.com - rank 3

- **Base:** `https://apitcg.com/api/one-piece/cards`.
- **Key / account:** **yes, an API key is required.** Measured: 308 -> 200 with
  body `{"error":"API key is required, register into: https://apitcg.com/platform"}`,
  ACAO `*`. Its own docs path `https://docs.apitcg.com/api-reference/cards`
  returned 404 to me.
- **Everything else about it: not measured** - with no key there is nothing to
  count. Registering an account to measure a candidate is a decision for a
  person, not for this session.

---

## 2. swu (Star Wars: Unlimited)

### C2a. The official FFG/Asmodee card API - **rank 1 for this game, and the pick below**

- **Base:** `https://admin.starwarsunlimited.com/api/`. Found in the site's own
  JavaScript: one chunk contains
  `tk.create({baseURL:"https://admin.starwarsunlimited.com/api/"})` and the
  endpoint names `card-list`, `card-list/meta`, `cards`, `cardsByIds`,
  `card/details/{id}`, `card-printings`. I then called
  `/card-list?locale=en`, `/cards?locale=en`, `/card/details/5?locale=en`.
- **Key / account:** **none.** Every call above answered 200 anonymously. (The
  same bundle contains a token-carrying helper that adds `X-Asmo-Token` for
  logged-in calls; public reads do not need it.)
- **CORS, measured:** `Access-Control-Allow-Origin: https://arcanum.example` when
  the Origin is `https://arcanum.example`, and `https://example.org` when it is
  `https://example.org` - a single echoed value, which is what a browser
  accepts, **plus `Access-Control-Allow-Credentials: true`**. The credentials
  header with a reflected origin is a permissive posture on their side (any
  site can read it with a user's cookies); for us it is simply "the browser may
  call it", and no cookie is sent.
- **Completeness, measured:**
  - the whole catalogue: `/api/cards?locale=en&pagination[pageSize]=250` -> 250
    records and `{"pagination":{"page":1,"pageSize":250,"pageCount":40,"total":9979}}`
    -> **9,979 records in 40 pages**. The last page
    (`pagination[page]=40`) answers 229 records, so the total is exact.
  - **The page size is the provider's, not the caller's, again:**
    `pagination[pageSize]=1000` is silently answered with
    `pageSize: 250` rather than refusing.
  - single card by id: `/api/card/details/5?locale=en` -> 200, 18,255 bytes.
    (`/api/card/5` -> 404; the path is `card/details`.)
  - search over names: `/api/card-list?locale=en&filters[title][$containsi]=luke`
    -> `total: 65` out of 9,979 - a real server-side name search. A plain
    `?title=luke` was ignored (still `total: 9979`). Search over rules text:
    **not measured** (no filter for it was found).
  - **set list: there is none of its own.** `/api/expansions` and `/api/sets`
    both 404, and the bundle's own endpoint literals contain no expansion
    endpoint. Every card record carries its `expansion`
    (`{"code":"SOR","name":"Spark of Rebellion","publishedAt":"2023-11-28T17:20:54.956Z","sortValue":19,…}`),
    so a set list has to be **derived from the card walk**, with the card count
    computed by grouping records - and see the next point for why the obvious
    field must not be used.
  - `cardCount` is **not** the set's card count: on the SOR page the values
    are 252, 20, 4 and 2, because it is the denominator of the card's printed
    "005/252" (the front-end builds `numberTotal` as
    `cardNumber.padStart(cardCount.length) + '/' + cardCount`). Taking it as
    the set size would be wrong for every token and sub-group row.
- **Id scheme:** **`cardUid`, and the printed number cannot be the id.** On one
  250-record page there are 250 distinct `cardUid` and only **241 distinct
  `cardNumber`**. The collisions are exactly the case the Gundam report warns
  about: number 1 of the page holds Director Krennic (SWH_01_001), the
  "Experience" token, Luke Skywalker with `hyperspace: true`
  (SWOP_0106_001_…_HYP), "Takedown" (SWOP_0104_001_OP) and Darth Vader alt art
  (SWH_0104_001_…_Alt_Art) - five products, one printed number, two of them the
  same card in two arts. The record also carries `hyperspace`, `unique`,
  `showcase`, `variantTypes` (name "Standard", `variantId: "01"`,
  `foil: false`), `variantOf` and `reprintOf`, so an alternate art is told
  apart from the base printing structurally. `/api/cards` records additionally
  embed a `variants` list grouped into hyperspace/showcase/other - the
  leaner `card-list` records do not - which is a second, nested way the same
  alternate appears and a double-counting trap for an importer.
- **Art:** `artFront.data.attributes.url` on `https://cdn.starwarsunlimited.com/`,
  **`Access-Control-Allow-Origin: *`** - the only art host in this survey a
  browser may fetch. Measured sizes: leader `SWH_01_005_Luke_Skywalker_Leader_ce133fc923.png`
  418x300, 63,349 bytes; unit `SWH_01_229_Cell_Block_Guard_a62b77b8b4.png`
  300x418, 64,390 bytes (both decoded with System.Drawing, and the payload also
  publishes width/height per format).
- **Prices:** **none.** A regex for any key matching `/price/i` over a 250-record
  page returned **zero matches**. There is no market, low or foil figure, and no
  TCGplayer product id in the payload. This is the Gundam cost, repeated: prices
  would stay on the tcgcsv client, and `catalog_prices` would hold no SWU rows.
- **Terms, from `https://starwarsunlimited.com/terms-of-use` (last revision
  2025-02-06, 16,526 characters of text):** *"You will not transmit any bugs,
  viruses, trojan horses, bots, scrapers, or any like or related programming
  through or to the Star Wars: Unlimited Website."* and *"Provided you abide by
  the Terms, FFG grants you permission to access the Star Wars: Unlimited
  Website for personal use and/or limited commercial use as expressly permitted
  herein."* Nothing in that page addresses re-hosting the card database, the
  API, or rate limits: **redistribution not stated**. Note the tension - the API
  is the site's own, undocumented, and the terms forbid scrapers on the site.

### C2b. SWU DB - rank 2, and the source that would keep prices

- **Base:** `https://api.swu-db.com`; documentation at `https://www.swu-db.com/api`
  (18,372 bytes). Endpoints called: `/cards/{set}`, `/cards/{set}/{number}`,
  `/cards/search?q=`, `/catalog/traits`.
- **Key / account:** none.
- **CORS, measured and decisive:** **every GET sends no
  `Access-Control-Allow-Origin` at all** - `/cards/search?q=set:sor` (200,
  168,880 bytes), `/cards/sor` (200, 891,013 bytes), `/cards/sor/10` (200, 910
  bytes), `/catalog/traits` (200, 732 bytes). Its `OPTIONS` preflight *does*
  answer `*` with `Allow-Methods: GET,OPTIONS`, which is a trap rather than a
  fix: a plain cross-origin GET is not preflighted, so the browser blocks the
  answer it never got permission to read. **Refused for the browser**, and the
  art CDN is refused too.
- **Completeness, measured:** `/cards/sor` -> **950 records** with fields
  `Set, Number, Name, Type, Aspects, Traits, Arenas, cid, Cost, Power, HP, FrontText, DoubleSided, Rarity, Unique, Artist, VariantType, MarketPrice, FoilPrice, FrontArt, tcgplayerId, LowPrice, LowFoilPrice` -
  a set list, all cards of a set, a single card by set+number, and a
  search endpoint (`/cards/search?q=` with a documented query language,
  `q=set:sor`, `p=n c>3`). 950 records for one set of 252 cards means
  every printing/variant is its own record, told apart by `VariantType`.
- **Id scheme:** `cid` (e.g. `5449704164`) is the unique card id, with `Number`
  and `VariantType` alongside; a collector's two holdings of one printed number
  are separable. This is the cleanest id model of any candidate here.
- **Art:** `FrontArt` on `https://cdn.swu-db.com/images/cards/SOR/059.png`; the
  `?format=image` route 302s to it. `/cards/sor/10?format=image` -> 302 ->
  200, 263,771 bytes, **no ACAO on either hop**. Refused for the browser.
- **Prices:** **yes** - `MarketPrice`, `LowPrice`, `FoilPrice`,
  `LowFoilPrice` **and `tcgplayerId`** (`"540180"` for SOR/059), which is the
  app's price-history join key. If keeping SWU prices matters more than the
  browser property, this is the source that keeps them.
- **Terms:** the documentation page states **no licence, no rate limit, no
  attribution requirement** - searched for "licen", "terms", "permission",
  "attribute", "rate limit", "commercial": **not stated**.

---

## 3. digimon (Digimon Card Game)

### C3a. Heroicc - **rank 1 for this game**

- **Base:** `https://api.heroi.cc` (a JSON:API). The docs at
  `https://heroi.cc/docs/api` name `assets.heroi.cc` in prose but the worked
  examples on its own sub-pages give the real host `api.heroi.cc`; I called
  `/releases`, `/releases/en`, `/releases/en/bt-08`,
  `/cards/en/BT8-022`, `/search?q=…`, `/bulk-data`.
- **Key / account:** none.
- **CORS, measured:** `Access-Control-Allow-Origin: *` on `/releases/en`
  (22,581 bytes), `/releases/en/bt-08` (21,488 bytes), `/cards/en/BT8-022`
  (1,579 bytes), `/search?q=agumon` (87,463 bytes), `/bulk-data` (1,479 bytes)
  and on the bulk file itself (`206 Partial Content`, `*`,
  `Content-Range: bytes 0-2047/25381271`). The API is fully browser-callable.
- **Completeness, measured:**
  - set list with a card count per set: `/releases/en` -> one language object
    listing **93 English releases**, and the response's `included` array carries
    **all 93 with a `meta.cards` count** (Large-Scale Tournaments 667, Store
    Events 395, Promotion Card [P] 207, Other Promos 61, Premium Bandai 29,
    Other Products 20, GAIA RED [ST-01] 16, COCYTUS BLUE [ST-02] 16, …); the
    counts sum to 7,685 card entries. **This is the only candidate here that
    answers a set list with a real count per set in one request.**
  - a set's cards: `/releases/en/bt-08` -> `included` holds **138 card ids**
    (e.g. `/cards/en/BT8-001` … and `/cards/en/BT5-007_P3`).
  - a single card by id: `/cards/en/BT8-022` -> 200, 1,579 bytes, with
    `faqs, language, notes, parallel-id, image, play-cost, security-effect, effect, rarity, category, block-icon, color, number, name, type`.
  - search: `/search?q=agumon` -> **60 records** with
    `{"total-cards":154,"summary":"1 - 60 of 154 cards where the language is \"en\" and the name or number includes \"agumon\""}`;
    `/search?q=Wargreymon` -> 60 of 63. It matches names and numbers; rules text
    **not measured**.
  - bulk: `/bulk-data` lists **English Cards, 25,381,271 bytes**, at
    `https://assets.heroi.cc/bulk-data/en-2026-07-03-013655.json` (Last-Modified
    2026-07-03) - one download for the whole English game, in the same card
    shape the API returns. A 99,317,918-byte all-languages file exists too.
  - release dates exist but not on the summary line: `/releases/en/bt-08` gives
    `"date":"2022-05-13"`, `"genre":"Booster Pack"` and a `cardlist-uri` back to
    Bandai's own page. The 93-row summary carries **no date**, so dates cost 93
    requests (or one bulk read).
- **Id scheme:** the id is `/cards/en/<number>` where the number carries the
  parallel suffix, and the record carries `parallel-id` as a number: measured
  on one card, `/cards/en/BT5-007` (parallel-id 0), `_P1` (1), `_P2` (2),
  `_P3` (3), `_P4` (4) - five products, one printed number, five ids, all five
  returned by a search for `BT5-007`. WarGreymon is the same shape across
  AD1-004_P1, BT1-025_P1/_P2/_P3. **Alternate arts are separable.** BT8-022 has
  no parallel and correctly returns one record.
- **Art:** `https://images.heroi.cc/cards/en/BT8-022.webp` -> 200, 59,198 bytes,
  **no `Access-Control-Allow-Origin`** - refused for the browser, so a relay
  entry would be needed. Dimensions: System.Drawing cannot decode WebP (it
  throws "Out of memory"), so I read the container header by hand: bytes are
  `52 49 46 46 | 36 e7 00 00 | 57 45 42 50 | 56 50 38 20 | 50 84 02 | 9d 01 2a | ae 01 | 58 02`,
  a VP8 lossy frame of **430x600**. `/cards/en/BT8-022_P1.webp` -> 403, because
  that parallel does not exist - the 403 is a correct answer, not a broken host.
- **Prices:** **none found.** The card object has no price field. This source
  quotes no price.
- **Terms, quoted from `https://heroi.cc/docs/api`:** original content is
  *"licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0
  International License (CC BY-NC-SA 4.0)"*; *"You must acknowledge that all data
  and imagery originating from © Akiyoshi Hongo, Toei Animation © BANDAI remain
  their intellectual property"*; *"You must not cover, crop, or clip off the
  copyright or artist name on card images"*; *"You must not add your own
  watermarks, stamps, or logos to card images"*; *"Caching of responses is
  encouraged. While no specific rate limits are imposed currently, this is
  subject to change."*; *"Specifying an explicit User-Agent header is recommended
  and may eventually be required."*; *"All data is sourced from official data
  sources only."* The **NonCommercial** clause is the one to read twice.

### C3b. DigimonCard.io - rank 2

- **Base:** `https://digimoncard.io/api-public` (docs at
  `https://digimoncard.io/api-documentation`, 157,169 bytes): `/search` and
  `/getAllCards`, and no third endpoint is documented.
- **Key / account:** none.
- **CORS, measured:** `access-control-allow-origin: *` (header spelled
  lower-case) on both endpoints. Browser-callable.
- **Completeness, measured:** `/search?n=agumon&series=Digimon%20Card%20Game`
  -> **75 records**, 65,661 bytes, with `name, type, id, level, play_cost,
  evolution_cost, …, main_effect, source_effect, alt_effect, series, pretty_url,
  date_added, set_name`; `/getAllCards?series=Digimon%20Card%20Game` -> **4,481
  records** (name and card number only), 208,379 bytes; a search by exact number
  (`?card=BT5-007`) -> **1 record**. There is no set-list endpoint: set names
  arrive as a `set_name` array on each card (one card listed six packs), with
  **no count per set**.
- **Id scheme - and this is why it is rank 2:** `id` **is the printed card
  number** ("BT4-016"), and a search for a card with four parallels returns
  **one** record: `?card=BT5-007` -> 1 record, `?card=BT8-022` -> 1 record. 75
  records for "agumon" carry 75 distinct ids, i.e. no parallel ever appears as a
  second record. **The alternate arts are not in this dataset at all, or are
  merged into the base record** - which is the silent merge the Gundam report
  describes, and here it cannot even be detected from the payload, because there
  is no parallel field to look at.
- **Art:** **there is no image field** - the string "image" does not occur
  anywhere in the search payload. Art cannot be built from this API at all, and
  the terms forbid hotlinking the site's own images. Its image host was
  therefore **not measured**.
- **Prices:** none in the payload (there is a "Price Analysis" page on the site;
  the API does not expose it - no price key exists in the card object).
- **Terms, quoted from its API documentation:** *"Do not mirror, republish,
  sublicense, sell, resell, or offer the API dataset as a competing data service
  without prior written permission."*; *"Do not hotlink images hosted by
  DigimonCard.io. You must download any images you use and serve them from your
  own hosting or infrastructure."*; *"Where practical, identify DigimonCard.io as
  the source and link to this API documentation."*; *"Requests are rate limited
  to 15 requests per 10 seconds"*, with a *"1-hour temporary block"* on breach.
  The first clause is the problem: importing this dataset into a shared
  catalogue that every client reads is mirroring/republishing it.

### C3c. Bandai's own English Digimon card list - rank 3

- **Base:** `https://world.digimoncard.com/cards/index.php?search=true` (the form
  action found in the page at `https://world.digimoncard.com/cards/?search=true`).
- **Key / account:** none. **CORS:** the HTML sends none; its card images send
  none. Not browser-callable.
- **Completeness, measured:** `/cards/?search=true&category=522039` -> 200,
  1,503,379 bytes, **60 card numbers and 164 `card_img` occurrences**, with
  parallel art at `/images/cardlist/card/EX13-001.png` and
  `…EX13-001_P1.png` and a `/images/cardlist/parallel/` marker. A bare
  `?search=true` returns the search form with no cards, so a query parameter
  is required - and there is no documented JSON view. This is a scrape of the
  publisher's HTML, with parallels visible in the markup but no ids beyond the
  printed number.
- **Prices:** none seen. **Terms:** **not measured.**

---

## 4. dragonball (Dragon Ball Super Card Game: Fusion World)

This is the weakest game in the survey, and it is worth stating plainly: I
found **no keyless JSON source for Fusion World at all**.

### C4a. Bandai's own English Fusion World card list - **rank 1 by default**

- **Base:** `https://www.dbs-cardgame.com/fw/en/cardlist/` (the page's form action is
  the same path; parameters `search=true`, `q`, `category[]`,
  `card_type[]`, `color[]`, and a `wild` flag seen in a real URL).
- **Key / account:** none. **CORS:** no ACAO on the HTML (66,445 bytes) and none
  on the art (`/fw/images/cards/card/en/FB06-002.webp`, 87,838 bytes). Not
  browser-callable for data or art.
- **Completeness, measured:** `?search=true&wild=1` -> 200, 142,913 bytes with
  **91 distinct FB numbers**; `?search=true&category[]=583001` -> 140 distinct
  (FB01-001 onwards, i.e. one set); `?search=true&q=Son%20Goku` -> 323 distinct,
  so **there is a free-text name search and a per-set listing in the HTML**.
  `&page=2` through `&page=6` each returned the byte-identical page (91
  cards, same first three) - **the `page` parameter is ignored**, the pager is
  client-side over the DOM, so a query is answered whole.
- **Id scheme:** the printed number (`FB05-006`) with parallels as
  `…_p1.webp` in the art paths, measured on
  `FB06-002.webp` and `FB06-002_p1.webp` (105,494 bytes). There is no id
  field in the markup. Alternate arts are visible, and separable only by
  scraping the image path.
- **Art:** `https://www.dbs-cardgame.com/fw/images/cards/card/en/FB06-002.webp` -
  87,838 bytes, **no ACAO**; dimensions read from the container header
  (`57 45 42 50 | 56 50 38 58 | 10 00 00 00 | 57 02 00 | 45 03 00`) = **600x838**,
  the same size as Bandai's One Piece art.
- **Prices:** **none.** **Terms:** **not measured.**

### C4b. JustTCG - rank 2

- **Base:** `https://api.justtcg.com/v1/cards`. **Key: yes.** Measured:
  `{"error":"API key is required","code":"MISSING_API_KEY"}`, 401, ACAO `*`.
  It advertises Fusion World support on its blog. Counts, prices and terms:
  **not measured** (no key).

### C4c. apitcg.com - rank 3

Same shape as C1c: key required, refusal body measured, everything else
**not measured**.

### C4d. A community backend, not a source

`https://github.com/teoisnotdead/api-dbscg-fw` describes itself as *"the backend
service for the Dragon Ball Super Card Game Fusion World application"* with
"Installation" and "Configuration" sections - it is software to run, not a
hosted API. **Not a candidate**, and I did not find a hosted instance.

---

## Which game to move next, and from where

**Move Star Wars: Unlimited, and take it from the official FFG/Asmodee card
API at `https://admin.starwarsunlimited.com/api/`.**

The reason, in one line: it is the publisher's own English card database, it
needs no key, and it is the only source in this survey where **both the JSON and
the card pictures are readable by a browser with no relay of ours in between**.

The measurement that decides it is the pair of CORS headers, taken together:

- `GET https://admin.starwarsunlimited.com/api/card-list?locale=en&pagination[pageSize]=250`
  -> 200, 3,451,707 bytes, `Access-Control-Allow-Origin: https://arcanum.example`
  (echoing whatever Origin is sent - confirmed with a second Origin,
  `https://example.org`), and
- `GET https://cdn.starwarsunlimited.com/SWH_01_229_Cell_Block_Guard_a62b77b8b4.png`
  -> 200, 64,390 bytes, 300x418, `Access-Control-Allow-Origin: *`.

Every other candidate is refused on at least one of the two: swu-db's JSON sends
no ACAO on any GET (its preflight does, which is a trap, not a fix); every art
host found for One Piece, Digimon and Fusion World - the fan ones *and Bandai's
own* - sends none. So this move is the first one that does not grow
`CardArt._relayed` and does not need the relay redeployed; and the same API
answers `?filters[title][$containsi]=luke` with **65 of 9,979** records, which is
the "search across the game" the web build does not have today. The alternative
for this game, swu-db, is refused by the browser for both its JSON and its art -
i.e. it re-creates exactly the tcgcsv situation this work exists to end, even
though it is the one source that carries prices (`MarketPrice`, `LowPrice`,
`FoilPrice`, `LowFoilPrice` and `tcgplayerId`).

### What it costs (state these before starting)

- **No price of any kind.** A 250-record page contains no key matching
  `/price/i`, and no TCGplayer product id. `replace_prices` must not be
  called, `catalog_prices` holds no SWU row, and `extras` must carry no
  `tcgplayerId` - the same three consequences the Gundam move accepted. SWU
  prices would keep coming from the tcgcsv client.
- **138 MB per full walk, in 40 requests** (3,451,707 bytes per 250-record page
  x 40 pages). There is no per-set endpoint, so the first import is all-or-
  nothing and a nightly refresh re-walks the catalogue - the checksum skip makes
  the *writes* cheap, not the download. (The heavier `/api/cards` projection is
  13,679,160 bytes per 250 records - do not use it.)
- **An undocumented internal API.** No public docs, no version segment; the
  paths were found in the site's own bundle. It may change or start requiring
  the `X-Asmo-Token` its own client already knows how to send, without notice.
- **Terms.** The ToU forbids transmitting "bots, scrapers, or any like or related
  programming" to the site and grants access "for personal use and/or limited
  commercial use as expressly permitted herein"; it says nothing about
  redistributing the card database. This is the same open question as
  `catalogue-server-side.md` section 9.3 and it belongs to a person.

### The things the live data will most likely force

**1. `cardUid` must be the id, and the printed number will look unique enough
to tempt someone.** One 250-record page carries 250 distinct `cardUid` and
241 distinct `cardNumber`. Number 1 of that page is five different products -
Director Krennic, the "Experience" token, Luke Skywalker with
`hyperspace: true`, "Takedown", and Darth Vader's alt art - two of them the
same collector's card in two arts. An id derived from the number stores, looks
unique, and silently collapses two holdings into one row; the row's id must be
`cardUid` verbatim, and the parity test should assert it over a sample that
holds several numbers with two or more records.

**2. There is no set endpoint, and the obvious count field is not the set
size.** `/api/expansions` and `/api/sets` both 404 and the site's own bundle
contains no expansion path, so the set list has to be folded out of the card
walk (each record's `expansion` carries `code`, `name` and `publishedAt`).
`cardCount` looks like the answer and is not: on one SOR page it reads 252,
20, 4 and 2, because it is the denominator of the printed "005/252". A set's
count is the number of records grouped under it, computed by the importer, and
the importer has to treat a token or promo sub-group as part of the set it is
filed in rather than as a set.

**3. Every record is heavy and nested, and the same alternate art arrives
twice.** 3.4 MB buys 250 records because each one embeds its expansion, both
art objects with six size variants each, localizations, and rules HTML; and
`/api/cards` records additionally embed a `variants` array that lists the same
hyperspace/showcase printings that also come back as records of their own. The
importer must flatten the expansion once, drop the nested objects and the
`variants` list, or the catalogue will be far larger than 9,979 rows' worth of
cards and the same printing will be counted twice in set completion.

---

## What I could not measure

- **How many sets SWU has.** There is no set endpoint and the walk is 40 pages
  (~138 MB); I read pages 1 and 40 only, which showed SOR-first and HMW/CST-last
  ordering. The set count is derivable, not measured.
- **Whether the SWU API has other filters** (rules text, aspect, set). One
  filter form, `filters[title][$containsi]`, worked; there is no documentation,
  so the rest of the grammar is unknown to me. Its rate limits are also
  unmeasured - no `X-RateLimit-*` headers appeared, and none are stated.
- **WebP dimensions through a decoder.** System.Drawing cannot read WebP; the
  430x600 (Heroicc) and 600x838 (Fusion World) figures come from reading the
  RIFF/VP8 container bytes by hand and are quoted with those bytes above.
- **digimoncard.io's image host** - the API carries no image field, so there was
  no URL to test; and whether its dataset contains parallel printings under a
  field I did not look at (the payload has no parallel key, and a search for a
  card with four parallels returns one record).
- **apitcg.com and JustTCG contents, counts, prices and terms.** Both refuse
  without an API key; only the refusal and the CORS header were measured, and I
  did not register for an account.
- **Bandai's terms of use** for the One Piece, Digimon and Fusion World sites
  (not read), and the licence terms of swu-db.com (none stated on its own
  documentation page).
- **Whether optcgapi's per-set path covers promos, DON!! cards and starter decks
  consistently**; I counted the aggregate endpoints (`/allSetCards/` 3,654,
  `/allSTCards/` 626, `/allPromos/` 1,082, `/allDonCards/` 187) and one set
  (`/sets/OP-01/`, 154).
- **Whether the official Bandai Digimon and Fusion World lists can be
  enumerated exhaustively.** Fusion World ignores `page` (pages 1-6 byte-
  identical), and Digimon's `index.php?search=true` returns the search form
  with no cards unless a category is supplied; I did not walk every category.
- **The exact size of a full SWU import.** 138 MB is 40 x the measured page,
  not a measured total.
