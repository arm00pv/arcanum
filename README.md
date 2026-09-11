# Arcanum — Trading Card Collection Vault

A precision collection tracker for Android covering **Magic: The Gathering** and
the **Pokémon Trading Card Game**, with an on-device quantitative price engine.
Built for a Pixel 7 Pro on Android 17.

> Arcanum is unofficial. It is not affiliated with Wizards of the Coast or The
> Pokémon Company.

## Two games, two collections

The game switcher sits at the top of every screen. It is **not a filter**: it
swaps the catalogue, the collection, the portfolio and every price series over
to the other game, and tints the whole app with that game's signature colour
(violet for Magic, gold for Pokémon).

Nothing is ever merged. A row is scoped by game in SQLite, every repository is
constructed per game, and the analytics are keyed by game — so a Pokémon holding
can never be valued against a Magic price list. `sets` and
`portfolio_snapshots` carry composite `(game, …)` primary keys, which means the
same set code can legitimately exist in both games at once.

| | Magic: The Gathering | Pokémon TCG |
|---|---|---|
| Catalogue | Scryfall — 1,049 sets, since 1993 | TCGdex — 218 sets, since 1999 |
| Set iconography | monochrome SVG set symbols | full-colour set logos |
| Finishes | non-foil, foil, etched | normal, holofoil, reverse holo, 1st Edition, 1st Ed. holo |
| Conditions | M / NM / EX / GD / LP / PL / PO | NM / LP / MP / HP / DMG |
| Grouping | mana colour identity | energy type |
| Price history | MTGStocks (2012→), MTGJSON backfill, own snapshots | TCGdex archive (→Sep 2024), JustTCG, own snapshots |

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

**Analysis** — A real quantitative engine, computed entirely on the phone.

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
  core/theme/        mana.dart (WUBRG + rarity), app_theme.dart (M3 + ArcanumColors)
  core/utils/        formatters.dart, app_settings.dart
  data/api/          scryfall_client.dart, scryfall_models.dart   (rate-limited, retrying)
  data/db/           app_database.dart (schema), catalog/collection/history DAOs
  data/history/      price_history_source.dart (3 providers), price_history_service.dart
  data/repositories/ catalog_repository.dart, collection_repository.dart
  domain/quant/      models, indicators, kalman, analytics   (pure Dart, no Flutter)
  domain/models/     collection_entry.dart
  features/          dashboard, sets, set_detail, collection, card, search, settings, shell
  widgets/           glass, sparkline, delta_chip, mana_pips, card_thumbnail, trend_gauge, ...
tool/
  slice_prices.py    MTGJSON -> compact SQLite price history
  sync_server.py     read-only HTTP service the app fetches from
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
flutter test        # 98 tests: quant engine, widgets, Scryfall client (live)
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
