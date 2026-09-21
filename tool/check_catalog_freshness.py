#!/usr/bin/env python3
"""Tell somebody when the shared catalogue stops keeping itself current.

Since migration step 1 the Lorcana catalogue is refreshed by the same nightly
sweep that samples its prices - one download, two jobs - and that sweep runs at
04:40 UTC on a host with nobody watching. The importer already writes down what
happened to it: `catalog_meta.last_import_ok` and `last_import_note` are
written on the failure path as well as the happy one, because design rule 5 in
docs/catalogue-server-side.md section 3 asks for a broken importer to be a fact
a client can read rather than an empty Sets tab it has to interpret. This script
is what reads that fact, and it reports it through the notify path this
deployment already has - `notify.json` and check_alerts.py's `publish` - rather
than through a second mechanism invented for the catalogue.

Three things are asked of every game that has a catalogue:

  * **Is the last run recorded as successful?** `last_import_ok` is false when
    a set failed to download or failed to write, and the importer is explicit
    that a set it could not import is a failure rather than a set to skip.
  * **Has a run finished since tonight's window?** A run that is killed at set
    twelve never reaches the code that writes the record, so `last_import_ok`
    keeps saying whatever it said yesterday and `sets_updated_at` does not
    move. Freshness is the fact that catches that, and it is also what catches
    a disabled timer, a unit that is no longer installed, and a host that was
    off all night.
  * **Do the recorded counts still describe the rows a client can read?** A
    provider answering with a plausible but short card list is obeyed by the
    importer - the guard refuses an empty set and nothing refuses a smaller one
    - so a count that falls between two readings is worth a person looking. It
    is a notification and not a refusal: a card genuinely can leave a set, and
    retiring a card rather than deleting it is a schema change this script
    cannot make.

Why the catalogue is asked for over PostgREST, as the publishable key, rather
than over psql as the owner:

  * The question worth asking every night is whether a *client* can see a
    current catalogue. A check that connects as `postgres` answers yes while a
    dropped policy leaves every browser with an empty Sets tab.
  * It has to keep working on the night the database is the broken thing, which
    rules out borrowing the importer's own connection.
  * The key it uses is public by construction - it ships inside the web bundle -
    so this script holds no secret and the unit that runs it needs no password.

The exit status is non-zero when anything was reported, so `systemctl status`
carries the same answer as the notification.

Usage:
    set -a; . /home/zixen/arcanum/supabase.env; set +a
    python3 check_catalog_freshness.py --dry-run

    # Prove the alert without waiting for a bad night: judge the catalogue as
    # though it were two days from now, and send the notification to a stand-in
    # rather than to the phone.
    python3 check_catalog_freshness.py --now 2026-09-21T06:30:00Z \
        --server http://127.0.0.1:8099
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

# The notify path, imported rather than reimplemented. check_alerts.py already
# derives the ntfy topic from a secret this deployment has, respects notify.json
# and prints what it could not send; a second implementation of that would be a
# second thing to keep honest.
import check_alerts  # noqa: E402

# The UTC time by which each game's catalogue import is expected to have run,
# which is when the timer that runs it fires - a unit cannot finish before it is
# started. One line per game that has a catalogue, and each names the unit:
#
#   pokemon  04:20  arcanum-pokemon-poll.timer      (--catalog, inside the sweep)
#   lorcana  04:40  arcanum-lorcana-poll.timer      (--catalog, inside the sweep)
#   gundam   05:10  arcanum-gundam-import.timer     (the import is the whole unit)
#   swu      05:45  arcanum-swu-import.timer        (the longest of the night, ~12m)
#
# A game that has a catalogue but no window here is reported rather than
# silently unwatched: the failure this script exists to prevent is a catalogue
# nobody is looking at, and the way to produce one is to start importing a game
# (migration steps 3 and 5) without telling anything when to expect it. That is
# not a hypothetical: the 2026-09-21 06:31 reading is the morning Pokemon's
# catalogue landed with this table still holding Lorcana alone, and the night's
# notification was this table's own gap rather than anything about the
# catalogue. Both halves of a new import are the same job - the timer that runs
# it, and the hour the watcher expects it by - and pokemon is written here
# beside gundam because the second one is what made the first impossible to
# miss.
WINDOWS = {
    "pokemon": "04:20",
    "lorcana": "04:40",
    "gundam": "05:10",
    "swu": "05:45",
}

# How close to a window the watcher is willing to ask its question. The timers
# that run the import carry RandomizedDelaySec, so a run may start minutes after
# its window and a watcher standing in the middle of that would be reading a
# record that is still being written. This timer runs an hour and a half after
# the window; the grace is what keeps the judgement honest if it is ever moved.
GRACE = timedelta(minutes=30)

GAMES_URL = "/rest/v1/catalog_meta?select=game,sets_revision,set_count,card_count," \
            "last_import_ok,last_import_note,sets_updated_at,source&order=game"


class Reading(RuntimeError):
    """The catalogue could not be read at all."""


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    # These four are named and defaulted exactly as check_alerts.py names them,
    # because they are handed to its load_config unchanged: one notify path, one
    # set of options, one notify.json.
    ap.add_argument("--config", default=os.path.expanduser("~/arcanum/notify.json"))
    ap.add_argument("--token-file", default=os.path.expanduser("~/arcanum/backup.token"))
    ap.add_argument("--server", default=None)
    ap.add_argument("--topic", default=None)
    ap.add_argument("--state", default=os.path.expanduser("~/arcanum/catalog.state.json"),
                    help="what the last reading saw, so a fall can be noticed")
    ap.add_argument("--url", default=None, help="catalogue base URL; default $SUPABASE_URL")
    ap.add_argument("--key", default=None,
                    help="publishable key; default $SUPABASE_PUBLISHABLE_KEY")
    ap.add_argument("--timeout", type=float, default=30.0)
    ap.add_argument("--now", default=None,
                    help="judge the catalogue as if it were this UTC time, for proving "
                         "the alert without waiting for a bad night")
    ap.add_argument("--no-count", action="store_true",
                    help="skip the row counts, and ask only what catalog_meta says")
    ap.add_argument("--dry-run", action="store_true",
                    help="print what would be sent, and send nothing")
    return ap.parse_args(argv)


def parse_instant(text):
    """A timestamp from PostgREST or from --now, as an aware UTC datetime."""
    if not text:
        return None
    value = str(text).strip().replace("Z", "+00:00")
    try:
        when = datetime.fromisoformat(value)
    except ValueError:
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    return when.astimezone(timezone.utc)


def stamp(when):
    return "never" if when is None else when.strftime("%Y-%m-%d %H:%M UTC")


def api_get(url, key, path, timeout, count=False):
    """One PostgREST GET as a client, returning (status, headers, body).

    An HTTP error is read rather than raised: PostgREST answers a missing table
    or a refused policy with a body that says which, and that sentence is worth
    more in a notification than a status code.
    """
    request = urllib.request.Request(url.rstrip("/") + path)
    request.add_header("apikey", key)
    request.add_header("Authorization", "Bearer " + key)
    request.add_header("Accept", "application/json")
    if count:
        request.add_header("Prefer", "count=exact")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.headers, response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.headers, exc.read()
    except Exception as exc:  # noqa: BLE001 - an unreachable catalogue is data too
        raise Reading(f"{path} could not be asked: {exc}")


def fetch_meta(url, key, timeout):
    """Every catalog_meta row a browser can read, or a refusal."""
    status, _headers, body = api_get(url, key, GAMES_URL, timeout)
    if status != 200:
        detail = body.decode("utf-8", "replace").strip()[:300]
        raise Reading(f"catalog_meta answered {status}: {detail or 'no body'}")
    try:
        rows = json.loads(body.decode("utf-8"))
    except ValueError as exc:
        raise Reading(f"catalog_meta did not answer with JSON: {exc}")
    if not isinstance(rows, list) or not rows:
        raise Reading("catalog_meta answered with no rows, so no game can be checked")
    return rows


def count_rows(url, key, game, timeout, retired=False):
    """How many rows of one table a client can read.

    Asked with a one-row page and `Prefer: count=exact`, so the answer is the
    number in Content-Range rather than the whole table, and it is asked as the
    publishable key so a policy that hides the rows is caught here rather than in
    somebody's browser.
    """
    table = "catalog_sets" if retired else "catalog_cards"
    query = f"game=eq.{game}"
    if retired:
        query += "&retired_at=is.null"
    status, headers, _body = api_get(
        url, key, f"/rest/v1/{table}?select=id&{query}&limit=1", timeout, count=True)
    if status not in (200, 206):
        raise Reading(f"{table} answered {status}")
    content_range = headers.get("Content-Range") or ""
    total = content_range.rsplit("/", 1)[-1]
    if not total.isdigit():
        raise Reading(f"{table} answered without a row count ({content_range!r})")
    return int(total)


def expected_after(now, window):
    """The instant a catalogue refreshed tonight has to be newer than.

    The window is when the import's timer fires, so the earliest a run of it can
    have finished is the window itself; anything at or after it is tonight's
    run. The grace period is what stops the question being asked while the
    answer is still being written: inside the grace, the bar falls back to the
    previous night's window and the run is given its time.
    """
    hour, minute = (int(part) for part in window.split(":"))
    today = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    return today if today + GRACE <= now else today - timedelta(days=1)


def load_state(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data.get("games") if isinstance(data, dict) and isinstance(data.get("games"), dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(path, games):
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"games": games}, fh, indent=1, sort_keys=True)
        os.replace(tmp, path)
    except OSError as exc:
        # Not fatal: the next run records a fresh baseline and loses only the
        # ability to compare against this one.
        print(f"state not written ({exc})")


def inspect(row, url, key, args, now, before):
    """Every reason one game's catalogue is not something to leave alone.

    Returns (problems, reading). The reading is what the next night compares
    against, and it comes from the record rather than from a request that did
    not answer: a night whose count query failed still knows how many cards the
    last import wrote, and writing that down is better than forgetting it.
    """
    game = row.get("game") or "?"
    recorded_cards = int(row.get("card_count") or 0)
    recorded_sets = int(row.get("set_count") or 0)
    updated = parse_instant(row.get("sets_updated_at"))
    problems = []

    window = WINDOWS.get(game)
    if window is None:
        problems.append(
            f"{game}: a catalogue is imported but this watcher has no window for it, "
            "so nothing knows when the next import is due - add it to WINDOWS here "
            "and to the timer that runs its importer")
    else:
        deadline = expected_after(now, window)
        if updated is None:
            problems.append(f"{game}: no import has ever finished (window {window} UTC)")
        elif updated < deadline:
            problems.append(
                f"{game}: no import has finished since {stamp(deadline)}; the last one "
                f"was {stamp(updated)}, so the shared catalogue is frozen and a new set "
                "will not be in it")

    if row.get("last_import_ok") is False and window is not None:
        note = row.get("last_import_note") or "the run left no note"
        problems.append(f"{game}: the last import reported a problem - {note}")

    reading = {"set_count": recorded_sets, "card_count": recorded_cards,
               "sets_updated_at": row.get("sets_updated_at")}

    if not args.no_count:
        try:
            cards = count_rows(url, key, game, args.timeout)
            sets = count_rows(url, key, game, args.timeout, retired=True)
        except Reading as exc:
            problems.append(f"{game}: the catalogue could not be counted - {exc}")
        else:
            reading["sets_readable"] = sets
            reading["cards_readable"] = cards
            if cards != recorded_cards:
                problems.append(
                    f"{game}: catalog_meta says {recorded_cards} cards and a client can "
                    f"read {cards}; the record and the rows disagree")
            if sets != recorded_sets:
                problems.append(
                    f"{game}: catalog_meta says {recorded_sets} sets and a client can "
                    f"read {sets}")

    if before:
        held = int(before.get("card_count") or 0)
        if recorded_cards < held:
            problems.append(
                f"{game}: the catalogue holds {recorded_cards} cards where the last "
                f"reading saw {held} - {held - recorded_cards} rows left the table, "
                "which the checksum skip cannot explain")
        held = int(before.get("set_count") or 0)
        if recorded_sets < held:
            problems.append(
                f"{game}: the catalogue holds {recorded_sets} sets where the last "
                f"reading saw {held}; a set may have been retired upstream, which is "
                "worth one look and is undone by the next good run")

    return problems, reading


def notify(args, problems):
    """Sends one notification for the run, through the path that already exists."""
    config, _ = check_alerts.load_config(args)
    if not config.get("topic"):
        print("no notify topic configured and none derivable: nothing was sent")
        return
    title = "Arcanum catalogue needs attention"
    message = "\n".join(problems)
    if args.dry_run:
        print(f"dry run, would notify:\n  {title}\n  " + message.replace("\n", "\n  "))
        return
    if check_alerts.publish(config, title, message, ["warning"]):
        print(f"notified: {title}")
    else:
        print("the notification could not be sent")


def main():
    args = parse_args()
    now = parse_instant(args.now) or datetime.now(timezone.utc)
    url = args.url or os.environ.get("SUPABASE_URL", "")
    key = args.key or os.environ.get("SUPABASE_PUBLISHABLE_KEY", "")
    if not url or not key:
        print("no catalogue to read: set SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY, or "
              "point --url and --key at one")
        return 2

    print(f"reading {url.rstrip('/')}/rest/v1/catalog_meta as a client, judged at "
          f"{stamp(now)}")
    problems = []
    try:
        metas = fetch_meta(url, key, args.timeout)
    except Reading as exc:
        print(f"the catalogue could not be read: {exc}")
        problems.append(f"the shared catalogue could not be read at all: {exc}")
        metas = []

    state = load_state(args.state)
    games = {}
    for row in metas:
        game = row.get("game") or "?"
        if not (row.get("source") or row.get("sets_updated_at")):
            # catalog_meta seeds nine rows and eight of them have never been
            # imported. A game with no catalogue cannot have a stale one, and
            # an expectation invented for it here would fail every night until
            # migration step 3 ships.
            continue
        found, reading = inspect(row, url, key, args, now, state.get(game))
        games[game] = reading
        counted = ", client reads %d sets / %d cards" % (
            reading["sets_readable"], reading["cards_readable"]) \
            if "sets_readable" in reading else ", and a client could not be asked for the rows"
        print(f"{game}: {reading['set_count']} sets, {reading['card_count']} cards, "
              f"last import {stamp(parse_instant(row.get('sets_updated_at')))}, "
              f"recorded ok={bool(row.get('last_import_ok'))}{counted if not args.no_count else ''}")
        for line in found:
            print(f"  - {line}")
        problems.extend(found)

    if games:
        save_state(args.state, games)

    if not problems:
        print("nothing to report")
        return 0
    print(f"{len(problems)} problem(s)")
    notify(args, problems)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
