# Arcanum — Trading Card Collection Vault

A precision collection tracker for Android covering **Magic: The Gathering**, the
**Pokémon Trading Card Game**, **Yu-Gi-Oh!** and **Disney Lorcana**, with an
on-device quantitative price engine. Built for a Pixel 7 Pro on Android 17.

> Arcanum is unofficial and non-commercial. It is not affiliated with, endorsed
> by or approved by Wizards of the Coast, The Pokémon Company, Konami, or
> Ravensburger and The Walt Disney Company.

## Four games, four collections

The game switcher sits at the top of every screen. It is **not a filter**: it
swaps the catalogue, the collection, the portfolio and every price series over
to the other game, and tints the whole app with that game's signature colour
(violet for Magic, gold for Pokémon, brown-gold for Yu-Gi-Oh!, cyan for
Lorcana).

Nothing is ever merged. A row is scoped by game in SQLite, every repository is
constructed per game, and the analytics are keyed by game — so a Pokémon holding
can never be valued against a Magic price list. `sets` and
`portfolio_snapshots` carry composite `(game, …)` primary keys, which means the
same set code can legitimately exist in two games at once.

| | Magic | Pokémon | Yu-Gi-Oh! | Lorcana |
|---|---|---|---|---|
| Catalogue | Scryfall — 1,049 sets, since 1993 | TCGdex — 218 sets, since 1999 | YGOPRODeck, since 2002 | Lorcast — 23 sets, since 2023 |
| Finishes | non-foil, foil, etched | normal, holofoil, reverse holo, 1st Edition, 1st Ed. holo | normal, foil | normal, cold foil |
| Conditions | M / NM / EX / GD / LP / PL / PO | NM / LP / MP / HP / DMG | NM / LP / MP / HP / DMG | NM / LP / MP / HP / DMG |
| Grouping | mana colour identity | energy type | monster attribute | ink |
| Price history | MTGStocks (2012→), MTGJSON backfill, own snapshots | TCGdex archive (→Sep 2024), JustTCG, own snapshots | own snapshots only | own snapshots only |

Two of the four games have **no price history anywhere**, free or paid:

- **Yu-Gi-Oh!** — YGOPRODeck's API has no history endpoint and no archive of its
  prices exists.
- **Lorcana** — Lorcast publishes today's price and nothing else. TCGplayer's
  daily CSV dump (TCGCSV) carries category 71 for Lorcana but holds only current
  prices, not an archive.

Arcanum records its own daily snapshot for every card you own in every game, so
those two build a trend from the day a card is added and say so plainly in
Settings and on the card screen rather than showing an empty chart.

### An honest note on Pokémon price history

**No free, live, per-card Pokémon price-history API exists.** TCGdex gives live
*current* prices but keeps no history. The community TCGdex price archive on
GitHub is free, keyless and roughly two years deep — but **the scrape stopped in
September 2024**, so it is a historical archive rather than a live feed. Arcanum
says exactly this in Settings and on the card screen, uses the archive for
backfill, and layers the user's own daily snapshots (plus JustTCG when a key is
supplied) on top for current data.

The older `pokemontcg.io` API was rejected: it is deprecated (keys die
2027-03-01, no new registrations) and returned **500s on 60–70% of requests**
during testing.

---

## What it does

**Catalogue** — Every set ever printed (1,049 sets, back to *Limited Edition
Alpha*, 5 Aug 1993), each with its real set symbol. Every card is listed in
**collector-number order**, the order the cards physically sit in a binder. Card
data is downloaded once per set and then served from SQLite forever, so browsing
stays fast and works offline.

**Collection** — Add any number of copies of a printing, in non-foil, foil or
etched, with condition, language, binder location and what you paid. Identical
physical stacks merge into one entry with a blended cost basis.

**Valuation** — Every holding is priced from live TCGplayer/Cardmarket market
data, adjusted for finish and (optionally) condition. The Vault shows total
value, cost basis, unrealised P/L, allocation by colour/rarity/set, and a
Herfindahl concentration index.

**Decks** — Build a deck for any of the four games, in any of that game's
formats, and see as you build whether it is legal, what it is worth and what you
still have to buy. Formats are data rather than code: size, copy limit,
singleton, sideboard, colour identity and a ban-list query are a line each, so a
new format is a line rather than a subclass. Legality says "not checked" rather
than showing a green tick it has not earned — Yu-Gi-Oh!'s Forbidden list and the
single ACE SPEC a Pokémon deck may hold are named as unchecked in the app.

**Deck intelligence** — The app reads a deck, not just stores it. Lands come from
the type line, the mana curve from the mana value, and the deck's *roles* — ramp,
card draw, removal, board wipes, counterspells, protection, tutors — from the
words the cards actually print. Nothing is looked up in a hand-written list of
card names, so nothing goes stale with the next set. The reading is also a
reading: where a game's wording is unknown, or too little of the deck has rules
text, the panel says so instead of drawing a shape out of the cards it happened
to understand.

**Building from what you own** — the card picker has an *Only mine* filter that
turns it from a catalogue search into your own boxes, and **Suggest** ranks the
cards you already hold for the deck in front of you. Every suggestion carries the
numbers behind it: *"Removal — this deck reads as 2 of about 8"*, *"Goblin — 14
cards here share the type"*, *"EDHREC rank #412"*. What the deck is short of
outranks what is merely popular, because the deck in front of you is better
evidence than the average deck of the same colours. Cards its format forbids,
cards outside the commander's colour identity, and copies you have already
committed are never offered.

**Interoperability** — Import and export the collection as CSV. Export writes a
file shaped for **Moxfield**, **Archidekt**, a plain spreadsheet, or Arcanum's own
lossless format, which additionally carries cost basis, purchase date, finish,
condition, language, binder and notes. Import reads any of those back, and every
row is matched to a *real printing* before anything is written: by card id, then
by set code plus collector number, then by name. The screen shows what it intends
to do first — how many cards, how many new stacks, how many merge into stacks you
already own, the cost basis the file supplied, and every row it could not match.
It never guesses silently. A row whose printing had to be inferred from the name
alone is flagged for review, and a row that matches nothing is reported rather
than filed against the wrong card.

**Analysis** — A real quantitative engine, computed entirely on the phone.

---

## Your data, and where it lives

Local first, and honest about it. The SQLite database on the phone is the source
of truth; there is no hosted account and nothing is uploaded anywhere you have
not named. A backup is one gzipped JSON document written to **your own
companion** — every game, every holding, your wants, your binders, your alerts
and the price snapshots the app recorded itself. The catalogue is left out (it is
re-downloadable, and carrying it would make the file mostly cache) and so are
credentials, because a backup that quietly carries your tokens turns every copy
of that file into a copy of them.

**Automatic backup** — Off, daily, every three days or weekly. Arcanum asks
Android's WorkManager to run it with the app closed *and* runs a catch-up backup
the first time you open the app after a gap, because Android defers background
work under Doze and battery saver without telling anybody. The app reports what
actually happened rather than what was requested: when the last run was, whether
it went through, and — if it did not — whether the server refused it or could not
be reached, which are different problems with different answers.

**Alerts while the app is closed** — Arcanum evaluates its own price alerts
whenever it is open, which is exactly when a price alert is least useful. So the
companion closes the gap from the other end: `tool/check_alerts.py` reads the
alerts out of the newest backup, prices them against the history it already
serves, and pushes the ones that fired to a notification service, driven by
`arcanum-alerts.timer` every half hour.

The rules are the app's own rules — the same four kinds, the same strict
comparisons, the same baseline semantics — because two engines disagreeing about
the same alert would be worse than one. The topic is derived from the backup
token, so there is one secret rather than two and no way for the phone and the
server to drift apart; the app shows the exact string to subscribe to. Set
`"enabled": false` in `~/arcanum/notify.json` to stop delivery, or point
`server` at your own ntfy to keep the notifications off a public relay.

---

## The price engine

Scryfall publishes only *current* prices — it has no price history at all. Real
trend analysis therefore needs history from somewhere else. Arcanum layers three
providers and merges them day by day, preferring whichever is most consistent
with the price shown on screen:

| Source | Depth | Notes |
|---|---|---|
| **Arcanum Sync** (this repo's companion) | 89 days, ~98k printings | TCGplayer market prices sliced from MTGJSON. Same series Scryfall's `usd` reports. |
| **MTGStocks** | back to 2012 | Free, no API key, fetched directly by the phone. |
| **Daily snapshots** | from first launch | The app records prices itself every day it is opened. Always works. |

### Indicators (all computed on-device, pure Dart)

SMA, EMA, MACD (12/26/9), Wilder RSI(14), Bollinger Bands (20, 2 sigma, population
sigma), OLS regression on log price with R-squared and a t-statistic, Holt's
linear trend with a grid-searched (alpha, beta), annualised volatility,
risk-adjusted momentum, maximum drawdown, momentum over 7/30/90 days, and a
**Kalman filter** (local linear trend with RTS smoothing) whose filtered slope is
the headline trend.

The eight components are combined into a 0-100 **trend score** via tanh-normalised
z-scores, and shrunk toward 50 by a confidence term built from R-squared, data
coverage and volatility — so a thin series can never produce a confident-looking
score.

### Honest by construction

- The forecast is drawn as a **statistical range**, never a bare line. The card
  detail screen says so in words.
- Price anomalies use a robust modified z-score (0.6745 * (r - median) / MAD), so
  a handful of wild days show up as *"Price dropped 34.1% in one day (robust
  z-score -9.4)"* rather than being smoothed away.
- Missing days are handled with a Kalman predict-only step; indicators run on the
  RTS-smoothed path only when the series is genuinely irregular. **No day is ever
  fabricated.**
- Structural breaks (reprints, rotations, bans) trigger a diffuse state reset and
  are flagged instead of being interpolated across.
- **No neural network is used for forecasting.** One to three years of daily
  prices is ~400-1,100 samples with a signal-to-noise ratio near 0.01; an LSTM
  would memorise it and, on honest out-of-sample backtests, would not beat a
  random walk. Shipping one would be theatre. The engine ships closed-form
  statistics whose every number can be checked by hand — and it was tested
  against Wilder's own published RSI example.

---

## Android 17

- `compileSdk = 37`, `compileSdkMinor = 2` (the `android-37.2` platform)
- `targetSdk = 37`, `minSdk = 26`
- AGP 9.1.0, Gradle 9.3.1, Kotlin 2.4.0, Java 17
- Predictive back, Impeller (Vulkan), Material 3 Expressive
- Verified on **Pixel 7 Pro (`cheetah`), Android 17, API level 37, arm64-v8a**

---

## Architecture

```
lib/
  core/legal.dart    the WOTC and TPCi notices, shown verbatim
  core/theme/        mana.dart (WUBRG + finishes + conditions), app_theme.dart
  core/utils/        formatters.dart, app_settings.dart
  data/api/          scryfall_client.dart + scryfall_models.dart (rate-limited, retrying)
  data/catalog/      card_catalog.dart (the per-game interface), mtg_catalog, pokemon_catalog
  data/backup/       backup_archive.dart, backup_service.dart, backup_schedule.dart,
                     backup_scheduler.dart (WorkManager), backup_worker.dart, alert_topic.dart
  data/db/           app_database.dart (v9 schema), catalog/collection/history/alert DAOs
  data/history/      price_history_source.dart (5 providers), price_history_service.dart
  data/repositories/ catalog, collection, alert repositories
  data/transfer/     csv.dart (RFC 4180), collection_transfer.dart (dialects),
                     import_service.dart (printing resolution)
  domain/quant/      models, indicators, kalman, analytics   (pure Dart, no Flutter)
  domain/models/     tcg_card.dart, card_game.dart, collection_entry.dart, price_alert.dart
  features/          dashboard, sets, set_detail, collection, card, search, alerts,
                     transfer, settings, shell
  widgets/           glass, sparkline, delta_chip, mana_pips, card_thumbnail, trend_gauge, ...
tool/
  slice_prices.py    MTGJSON -> compact SQLite price history
  poll_pokemon_prices.py  daily TCGdex price poller
  sync_server.py     read-only HTTP service the app fetches from, plus the
                     token-gated backup routes
  check_alerts.py    reads alerts out of the newest backup and delivers the
                     ones that fired
  deploy/            the systemd units for all of the above
```

### Rate limiting

Scryfall's limits are **not uniform**: `/cards/search` and `/cards/collection`
allow 2 requests/second, everything else 10/second. The client serialises all
requests through one queue with a per-endpoint gap, honours `Retry-After` on 429
(capped at Scryfall's documented 30-second penalty), and retries 5xx/timeouts with
exponential backoff and jitter.

---

## Running the price-history service

The app works without this (MTGStocks and its own snapshots cover it), but it is
what gives instant 89-day TCGplayer history for nearly every printing.

```powershell
# 1. One-time: download MTGJSON and slice it (~15 min, 360 MB down, 1.8 GB db)
python tool/slice_prices.py --dir tool/prices

# 2. Serve it
python tool/sync_server.py --port 8787 --db tool/prices/prices.db
#    or simply: pwsh tool/start_sync.ps1
```

Then set the endpoint in **Settings -> Price history** (pre-filled with
`http://100.90.30.95:8787`, this machine's Tailscale address). Press **Test
connection** to confirm.

---

## Building

```powershell
flutter pub get
flutter build apk --release        # -> build/app/outputs/flutter-apk/app-release.apk
flutter install                    # or: adb install -r <apk>
```

Release signing uses `android/key.properties` + `android/arcanum-release.jks`.

## Tests

```powershell
flutter test        # 210 tests: quant engine, widgets, Scryfall client (live),
                    # CSV codec + dialects, import matching, transfer screen,
                    # YGOPRODeck parsing
```

---

## The device

Connected over Tailscale with Android wireless debugging:

```powershell
adb pair <tailscale-ip>:<pairing-port> <6-digit-code>
adb connect <tailscale-ip>:<connect-port>
```

Wireless-debugging ports are randomly assigned; `adb mdns services` is unreliable
across a Tailscale link, so setup scanned the phone's ephemeral port range to find
them.
