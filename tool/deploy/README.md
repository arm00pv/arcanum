# Deploying the Arcanum companion

Arcanum Sync is a read-only price-history service: the app asks it for one
printed card at a time and it answers with that printing's series. It is small,
needs no database server, and is the only part of Arcanum that is not on the
phone.

This directory is the deployment as it actually runs, so the setup can be
rebuilt rather than remembered.

## Where it runs

On the watchtower host (`zapp.sytes.net`), alongside the n8n/Caddy compose
stack that already serves the other public names. The gateway is the **Caddy
container** in `~/n8n-docker-caddy`, not the host's own `/etc/caddy/Caddyfile`
— the container is what holds ports 80 and 443.

Paths on the host:

    /home/zixen/arcanum/
      sync_server.py                  the service
      slice_prices.py                 builds the Magic database from MTGJSON
      poll_pokemon_prices.py          samples Pokemon prices once a day
  check_catalog_freshness.py      reports a stale shared catalogue, to the same
                                  notify path the price alerts use
      rebuild_mtg_history.sh          download + slice + swap, in one step
      watch_slice_and_restart.sh      restart the service after a manual rebuild
      patch_caddy.py                  adds the public route (idempotent)
      data/prices.db                  Magic, ~1.8 GB
      data/pokemon_prices.db          Pokemon, sampled daily
      data/mtgjson/                   the two MTGJSON artifacts, ~380 MB
      identity.json                   who may use this server: the owner address,
                                      invited addresses, device tokens (hashed)
                                      and the codes outstanding
      resend.token                    the Resend API key sign-in codes are sent
                                      with, mode 600
      logs/                           one log per unit

## Pieces

| Unit | What it does | When |
| --- | --- | --- |
| `arcanum-sync.service` | serves all four databases on 172.19.0.1:8787 | always |
| `arcanum-pokemon-poll.timer` | samples TCGdex into the Pokemon database | daily, 04:20 UTC |
| `arcanum-lorcana-poll.timer` | samples Lorcast into the Lorcana database, and refreshes the shared Lorcana catalogue in Postgres | daily, 04:40 UTC |
| `arcanum-yugioh-poll.timer` | samples YGOPRODeck into the Yu-Gi-Oh! database | daily, 04:55 UTC |
| `arcanum-mtg-rebuild.timer` | re-slices the Magic history from MTGJSON | Mondays, 05:30 UTC |
| `arcanum-catalog-watch.timer` | reports a shared catalogue that has stopped being refreshed | daily, 06:30 UTC |

The listening address is the docker bridge gateway on purpose. The host has a
public address and no host firewall, so binding every interface would publish
the database to the internet in cleartext; bound this way only the Caddy
container can reach it, and everything public arrives over TLS.

## The shared catalogue

The browser build reads the card catalogue from the project's Supabase Postgres
rather than from the providers, and the Lorcana half of it is filled by the same
nightly sweep that samples Lorcana prices: the 24 Lorcast responses the sampler
already downloads are the 24 responses the catalogue rows are built from, so the
second job costs no extra traffic and about sixteen seconds of `psql` round
trips. The credentials come from `supabase.env`, read by systemd through
`EnvironmentFile` so the importer is handed them as environment variables
rather than as arguments of its own.

Importing is not the same as keeping current, and the run at 04:40 happens with
nobody watching, so `arcanum-catalog-watch.timer` asks three questions every
morning at 06:30 and posts to ntfy - the notify path `notify.json` and
`check_alerts.py` already use - when the answer is wrong: whether the last
import recorded itself as successful, whether one has finished since the night's
window, and whether the counts it recorded still match what a client can read.
It reads the catalogue over PostgREST with the publishable key, so it needs no
database password and it also fails on the night the read path is what broke.

The schedule, the measurement behind it and the failure modes are in
`docs/catalogue-refresh.md`.

## Signing in without a password

The app has no account and no password, and it does not need one: the companion
holds exactly one collection, so "who are you" is a question with a short answer.
A new phone asks for a code, the server mails it, and the code buys a token for
that device.

    python sync_server.py --set-owner info@marquezhv.com     # the one address that counts
    python sync_server.py --invite someone@example.com       # anyone else allowed in
    python sync_server.py --devices                          # what holds a token now

The root token in `backup.token` keeps working and is not a device: it cannot be
revoked through the app, which is what stops a server being locked out of itself.
A device token opens everything the root token opens, the vault page included,
which is why an emailed vault link is just another device with a week to live.

Email goes out through Resend. **The sending domain is not verified yet**, so
codes can only reach `info@marquezhv.com` — the address that owns the Resend
account. To mail any address, add these three records to the `marquezhv.com`
zone (its nameservers are `ns1/ns2.hosting.businessidentity.llc`, which is not
where this repository lives), then press Verify in the Resend dashboard:

| Type | Name | Value |
| --- | --- | --- |
| TXT | `resend._domainkey` | the `p=MIGfMA0...` key from the Resend domain page |
| MX  | `send` | `feedback-smtp.us-east-1.amazonses.com` (priority 10) |
| TXT | `send` | `v=spf1 include:amazonses.com ~all` |

Until that happens the service runs with Resend's shared test sender. Once the
domain verifies, uncommenting the `ARCANUM_MAIL_FROM` line in
`arcanum-sync.service` and restarting is the whole change.

Two things about Resend are worth knowing before debugging it: it answers through
Cloudflare, which refuses requests that look like a script (so the companion
names itself, and a bare `urllib` gets `error code: 1010`), and the refusal that
matters — an unverified domain — arrives as JSON with a `message` that says so.

## Why three of the four games are sampled rather than backfilled

Magic is rebuilt from MTGJSON weekly, which is a real archive: 89 days and
thirteen million points, and it can be rebuilt from scratch at any time.

Pokemon, Lorcana and Yu-Gi-Oh! have nothing to backfill from. TCGdex gives live
Pokemon prices but its community archive stopped in September 2024; Lorcast and
YGOPRODeck publish today's price and no history at all, and no free archive of
either exists anywhere. For those three the sampler **is** the history: a day
that is not sampled is a day permanently missing from every future trend, which
is why their timers carry `Persistent=true` and why they run before the weekly
Magic rebuild rather than after it.

Sampling cost is small: Lorcana is 23 requests for all 3,198 cards, Yu-Gi-Oh!
is one 21 MB response for all 14,549, and Pokemon is the heaviest at one
request per card. A full day's sweep of all three is a few minutes of quiet
work.

## Public route

`patch_caddy.py` rewrites the `zapp.sytes.net` block in the container's
Caddyfile to carve out `/arcanum/*` before the Open WebUI catch-all, and adds
`8n8.sytes.net` for n8n. It backs the file up first and is safe to re-run.

    python3 ~/arcanum/patch_caddy.py
    sudo docker exec n8n-docker-caddy-caddy-1 caddy reload \
        --config /etc/caddy/Caddyfile --adapter caddyfile

Then `https://zapp.sytes.net/arcanum/v1/health` answers with the counters, and
the app's default endpoint is that URL. Because it is HTTPS, the app needs no
cleartext exception for it.

### Routes

| Route | What it answers | Who may ask |
| --- | --- | --- |
| `/v1/health` | printings, points, days, per game | anyone |
| `/v1/history/<cardId>.json` | one printing's price series | anyone |
| `/v1/sealed?game=&set=` | sealed product and prices for one set | anyone |
| `/v1/backup` (POST) | stores an archive | the token |
| `/v1/backup/latest` | newest archive, as gzip; `?not_device=LABEL` for the newest one another device wrote, and `X-Arcanum-Device` names the writer | the token |
| `/v1/backup/status` | counts, and which device wrote what | the token |
| `/vault` | the vault as a read-only HTML page | the token |

Sealed prices come from TCGplayer's own product dumps, mirrored as JSON by
`tcgcsv.com`: the server fetches one set's product list and prices when the app
asks for that set, caches both for half a day, and filters singles out
structurally — a single carries a rarity and a collector number, a box carries
neither — rather than by guessing from a name. Cached under
`~/arcanum/data/sealed`.

The vault page reads the newest archive and prints it: totals, the portfolio
curve as inline SVG, a table per set, the dearest stacks and the sealed shelf.
It takes the token as a query parameter as well as a header, because a browser
navigating to a URL cannot send a header — which does put it in the browser's
history, so treat the URL as the secret it is.

## What a browser cannot fetch for itself

The web build asks Arcanum's own relay for two things, and asks a CDN for
nothing it is not allowed to read.

`tcgcsv_proxy.py` runs on the docker bridge at `172.19.0.1:8098`, reachable
only through Caddy, and answers two routes:

| Route | What it answers |
| --- | --- |
| `/arcanumweb-api/tcgcsv/...` | the catalogue for the five games TCGplayer publishes |
| `/arcanumweb-api/art/<host>/...` | one card's picture, from the CDN the catalogue points at |

The two routes exist for one reason twice over, which is that a browser reads an
image by fetching its bytes and decoding them itself and so holds a picture to
the same rule it holds JSON to. tcgcsv sends no CORS headers and asks callers to
name themselves, which a page can do neither of; YGOPRODeck's image host and
Lorcast's card store send no `Access-Control-Allow-Origin` at all, and the
shop's CDN sends a wildcard that is the shop's to withdraw. The relay fetches the
path with a real User-Agent and hands the answer back with the header the
browser is waiting for, from an allow-list of origins rather than a wildcard, so
a page on the internet cannot spend this host's address.

Art is handed over with `Cache-Control: public, max-age=31536000, immutable` -
a product's picture is never rewritten under the same name, so the browser keeps
it and the relay is asked for it once. A failure is `no-store` instead, so a CDN
having a bad minute cannot leave a picture that no reload will mend.

    python3 ~/arcanum/tool/deploy/patch_caddy_art.py
    sudo docker exec n8n-docker-caddy-caddy-1 caddy reload --config /etc/Caddyfile --adapter caddyfile
    pkill -f tcgcsv_proxy.py; nohup python3 ~/arcanum/tcgcsv_proxy.py >> ~/arcanum/logs/web-relay.log 2>&1 &

Nothing supervises the relay: it has been started by hand since it was written,
which is why the restart is written down here rather than assumed. The patcher
adds the art route to every site that already serves the browser build, and says
so when it finds one already there.

## Rebuilding by hand

    nohup ~/arcanum/rebuild_mtg_history.sh > ~/arcanum/logs/mtg_rebuild.log 2>&1 &

The slice takes tens of minutes on a shared host. The service holds the old
database open, so it has to be restarted to serve the new one — the timer's
unit does that itself, and `watch_slice_and_restart.sh` is the same step for a
rebuild started by hand.

Watch for the wait loop in that script matching its own command line: `pgrep -f
slice_prices.py` sees the bash that is running the loop, so the pattern is
written with a bracket (`[s]lice_prices.py`) and the loop can actually end.

## What the Magic database does and does not hold

MTGJSON's `AllPrices` carries roughly 100,000 printings — about four fifths of
the 123,000 entries in `AllIdentifiers` — and only for the providers it
publishes at the time. Coverage is uneven across sets, and recent sets are thin:
of 175 Bloomburrow printings sampled by Scryfall id, 8 answer from the
companion.

This is why the companion is the app's *first* Magic source and not its only
one. When it has nothing for a printing, Arcanum falls back to MTGStocks, which
carries multi-year daily series for essentially every printing (the same
Bloomburrow card answers with 789 daily points). Before treating a missing card
as a companion bug, check the printing against both.
