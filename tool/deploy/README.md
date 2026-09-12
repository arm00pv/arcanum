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
      rebuild_mtg_history.sh          download + slice + swap, in one step
      watch_slice_and_restart.sh      restart the service after a manual rebuild
      patch_caddy.py                  adds the public route (idempotent)
      data/prices.db                  Magic, ~1.8 GB
      data/pokemon_prices.db          Pokemon, sampled daily
      data/mtgjson/                   the two MTGJSON artifacts, ~380 MB
      logs/                           one log per unit

## Pieces

| Unit | What it does | When |
| --- | --- | --- |
| `arcanum-sync.service` | serves the two databases on 172.19.0.1:8787 | always |
| `arcanum-pokemon-poll.timer` | samples TCGdex into the Pokemon database | daily, 04:20 UTC |
| `arcanum-mtg-rebuild.timer` | re-slices the Magic history from MTGJSON | Mondays, 05:30 UTC |

The listening address is the docker bridge gateway on purpose. The host has a
public address and no host firewall, so binding every interface would publish
the database to the internet in cleartext; bound this way only the Caddy
container can reach it, and everything public arrives over TLS.

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
