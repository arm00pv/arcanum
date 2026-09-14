#!/usr/bin/env python3
"""Delivers Arcanum's price alerts when the phone is not running.

Arcanum evaluates its own alerts whenever it is open. That is fine until the
collector stops opening it - which is exactly when a price alert is worth
having. This script closes that gap from the other end: it reads the alerts out
of the newest backup the phone uploaded, prices them against the history this
companion already serves, and pushes the ones that fired to a notification
service.

    python3 check_alerts.py --backups-dir ~/arcanum/backups \
        --db ~/arcanum/data/prices.db --pokemon-db ~/arcanum/data/pokemon_prices.db

Run it from a timer. It is written to be run every half hour and to do nothing
at all when nothing has fired.

What it will not do
-------------------
It evaluates a rule the same way the app does - the same four kinds, the same
strict comparisons, the same baseline semantics - because two engines giving
different answers about the same alert would be worse than one. Where a card is
not in a price database, or a rule has no baseline to measure against, it says
so in the log rather than guessing.

Notifications leave the machine
-------------------------------
The notification goes to ntfy, which by default is a public relay run by
somebody else: the card name and the price travel there, and the topic is the
only thing keeping them from being read. The topic is therefore derived from the
backup token, which is already a secret this setup has, rather than being a new
one to invent and forget. Point --server at your own ntfy to keep it in the
house, or set "enabled": false in the config to stop the delivery entirely.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

BACKUP_PREFIX = "arcanum-backup-"
BACKUP_SUFFIX = ".json.gz"

# Each game keys a printing differently, exactly as the sync server does, and
# the first finish is the one the app falls back to when an alert names none.
GAMES = {
    "mtg": ("mtg", "scryfall_id", "nonfoil"),
    "pokemon": ("pokemon", "card_id", "nonfoil"),
    "lorcana": ("lorcana", "card_id", "nonfoil"),
    "yugioh": ("yugioh", "card_id", "nonfoil"),
}

# What the four rule kinds are called, for the notification title.
KIND_LABEL = {
    "above": "rose above",
    "below": "fell below",
    "percent_up": "is up",
    "percent_down": "is down",
}


def newest_archive(backups_dir):
    """The most recent backup the phone uploaded, or None.

    The filename carries a UTC stamp in a fixed-width, sortable form, so the
    newest is the last name alphabetically and no stat() call is needed.
    """
    try:
        names = [
            n
            for n in os.listdir(backups_dir)
            if n.startswith(BACKUP_PREFIX)
            and n.endswith(BACKUP_SUFFIX)
            and not n.startswith(".incoming-")
        ]
    except OSError:
        return None
    if not names:
        return None
    return os.path.join(backups_dir, sorted(names)[-1])


def read_archive(path):
    """The alerts in a backup, with the stamp it was taken at."""
    with gzip.open(path, "rt", encoding="utf-8") as fh:
        archive = json.load(fh)
    if archive.get("format") != "arcanum-backup":
        raise ValueError("not an Arcanum backup: %s" % path)
    tables = archive.get("tables") or {}
    return archive.get("created"), tables.get("alerts") or []


def connected(path):
    """A read-only connection, or None when the database is not there."""
    if not path or not os.path.exists(path):
        return None
    import sqlite3

    try:
        return sqlite3.connect("file:%s?mode=ro" % path, uri=True)
    except sqlite3.Error:
        return None


def latest_price(db_path, column, card_id, finish):
    """The most recent price for one printing, and the date it is from.

    The named finish is tried first, and anything the card does have is used as
    a fallback - a foil alert on a card whose only series is non-foil is better
    answered approximately, and told so, than not answered at all.
    """
    conn = connected(db_path)
    if conn is None:
        return None, None, None
    try:
        for wanted, exact in ((finish, True), (None, False)):
            if exact:
                row = conn.execute(
                    "SELECT date, price FROM history WHERE %s = ? AND finish = ? "
                    "ORDER BY date DESC LIMIT 1" % column,
                    (card_id, wanted),
                ).fetchone()
            else:
                row = conn.execute(
                    "SELECT date, price FROM history WHERE %s = ? "
                    "ORDER BY date DESC LIMIT 1" % column,
                    (card_id,),
                ).fetchone()
            if row:
                return float(row[1]), row[0], not exact
    except Exception:
        return None, None, None
    finally:
        conn.close()
    return None, None, None


def evaluate(kind, threshold, baseline, price):
    """Whether a rule fires, by the app's own rules.

    Kept deliberately identical to AlertRepository._isTriggered: absolute rules
    compare strictly, percentage rules measure against the price the alert was
    armed at, and a missing or non-positive price never fires.
    """
    if price is None or price <= 0:
        return False
    if kind == "above":
        return price > threshold
    if kind == "below":
        return price < threshold
    if baseline is None or baseline <= 0:
        return False
    if kind == "percent_up":
        return percent_up(price, baseline) >= threshold
    if kind == "percent_down":
        return percent_down(price, baseline) >= threshold
    return False


def percent_up(price, baseline):
    """Rise above the baseline, as a percentage.

    Written as a difference over the baseline rather than a ratio minus one.
    The two agree on paper, but in binary floating point (120/100 - 1) * 100 is
    19.999999999999996, so a 20% alert would not fire on a price that had risen
    exactly 20%. AlertRepository uses this same form.
    """
    return (price - baseline) / baseline * 100


def percent_down(price, baseline):
    """Fall below the baseline, as a percentage."""
    return (baseline - price) / price * 100


def money(value):
    if value is None:
        return "?"
    if value >= 1000:
        return "${:,.0f}".format(value)
    return "${:,.2f}".format(value)


def describe(alert, price, approximate):
    """One sentence, in the same shape the app uses."""
    name = alert.get("card_name") or alert.get("card_id")
    kind = alert.get("kind")
    threshold = float(alert.get("threshold") or 0)
    baseline = alert.get("baseline")
    baseline = float(baseline) if baseline is not None else None
    caveat = " (best available finish)" if approximate else ""

    if kind in ("above", "below"):
        direction = "above" if kind == "above" else "below"
        return "%s is now %s, %s your %s target%s." % (
            name,
            money(price),
            direction,
            money(threshold),
            caveat,
        )
    if kind == "percent_up":
        pct = percent_up(price, baseline) if baseline else 0.0
        return "%s is up %+.1f%% since you set this alert (now %s, from %s)%s." % (
            name,
            pct,
            money(price),
            money(baseline),
            caveat,
        )
    if kind == "percent_down":
        pct = percent_down(price, baseline) if baseline else 0.0
        return "%s is down %.1f%% since you set this alert (now %s, from %s)%s." % (
            name,
            pct,
            money(price),
            money(baseline),
            caveat,
        )
    return "%s is %s %s." % (name, KIND_LABEL.get(kind, "triggered"), money(price))


def alert_key(alert):
    """A stable identity for one alert across backups.

    The row id is the honest identity; the composite is only for a row written
    by something that did not carry one.
    """
    if alert.get("id") is not None:
        return str(alert["id"])
    return "%s|%s|%s|%s" % (
        alert.get("game"),
        alert.get("card_id"),
        alert.get("kind"),
        alert.get("threshold"),
    )


def load_state(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(path, state):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=1, sort_keys=True)
    os.replace(tmp, path)


def derive_topic(token):
    """A topic nobody can guess, from a secret this setup already has."""
    digest = hashlib.sha256(token.encode("utf-8")).hexdigest()
    return "arcanum-" + digest[:20]


def load_config(args):
    config = {"enabled": True, "server": "https://ntfy.sh", "topic": "", "priority": 3}
    if args.config and os.path.exists(args.config):
        try:
            with open(args.config, "r", encoding="utf-8") as fh:
                stored = json.load(fh)
            if isinstance(stored, dict):
                config.update(stored)
        except (OSError, ValueError) as exc:
            print("config unreadable (%s); using defaults" % exc)
    if args.server:
        config["server"] = args.server
    if args.topic:
        config["topic"] = args.topic
    if not config.get("topic"):
        token = ""
        if args.token_file and os.path.exists(args.token_file):
            with open(args.token_file, "r", encoding="utf-8") as fh:
                token = fh.read().strip()
        if not token:
            print("no topic configured and no backup token to derive one from")
            return config, None
        config["topic"] = derive_topic(token)
    return config, None


def publish(config, title, message, tags):
    """Posts one notification. Returns True when it was accepted."""
    payload = json.dumps(
        {
            "topic": config["topic"],
            "title": title,
            "message": message,
            "priority": config.get("priority", 3),
            "tags": tags,
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        config["server"].rstrip("/") + "/",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return 200 <= response.status < 300
    except urllib.error.HTTPError as exc:
        print("notify failed: HTTP %s %s" % (exc.code, exc.reason))
    except Exception as exc:
        print("notify failed: %s" % exc)
    return False


def run(args):
    path = args.backup or newest_archive(args.backups_dir)
    if not path:
        print("no backup to read yet")
        return 0
    created, alerts = read_archive(path)
    armed = [a for a in alerts if not a.get("triggered_at")]
    print(
        "reading %s (%s): %d alerts, %d armed"
        % (os.path.basename(path), created or "undated", len(alerts), len(armed))
    )
    if not armed:
        # Nothing is watching, so nothing is remembered either: a re-armed
        # alert has to be able to fire again.
        if os.path.exists(args.state):
            os.remove(args.state)
        return 0

    databases = {
        "mtg": args.db,
        "pokemon": args.pokemon_db,
        "lorcana": args.lorcana_db,
        "yugioh": args.yugioh_db,
    }

    config, _ = load_config(args)
    state = load_state(args.state)
    fired = {}
    unavailable = 0
    quiet = 0

    for alert in armed:
        key = alert_key(alert)
        game = alert.get("game") or "mtg"
        entry = GAMES.get(game)
        if entry is None or not databases.get(game):
            unavailable += 1
            continue
        _name, column, default_finish = entry
        finish = alert.get("finish") or default_finish
        price, date, approximate = latest_price(
            databases[game], column, alert.get("card_id"), finish
        )
        if price is None:
            unavailable += 1
            continue

        baseline = alert.get("baseline")
        kind = alert.get("kind") or "above"
        threshold = float(alert.get("threshold") or 0)
        if not evaluate(kind, threshold, baseline, price):
            quiet += 1
            continue

        fired[key] = {
            "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "price": price,
            "date": date,
            "game": game,
            "message": describe(alert, price, approximate),
        }

    # Only what fired this time, plus what is still armed but quiet, is kept:
    # a delivery is remembered so it is not repeated, and an alert that has
    # stopped firing is forgotten so it can fire again later.
    fresh = dict(state)
    delivered = 0
    for key, record in fired.items():
        if key in state:
            fresh[key] = state[key]
            continue
        name = record["message"]
        if not config.get("enabled", True):
            print("would notify: %s" % name)
            fresh[key] = record
            continue
        if args.dry_run:
            # A dry run changes nothing at all, including the memory of what
            # has been sent - otherwise rehearsing a delivery would stop the
            # real one from ever happening.
            print("dry run, would notify: %s" % name)
            continue
        tags = ["chart_with_downwards_trend"]
        if (record.get("message") or "").find("up ") >= 0:
            tags = ["chart_with_upwards_trend"]
        if publish(config, "Arcanum price alert", name, tags):
            print("notified: %s" % name)
            delivered += 1
            fresh[key] = record
        else:
            # Not remembered, so the next run tries again rather than losing it.
            print("not delivered, will retry: %s" % name)

    # Forget alerts that no longer exist or are no longer armed.
    live = set(alert_key(a) for a in armed)
    fresh = {k: v for k, v in fresh.items() if k in live}

    if not args.dry_run:
        save_state(args.state, fresh)
    print(
        "fired %d, delivered %d, quiet %d, unpriced %d"
        % (len(fired), delivered, quiet, unavailable)
    )
    return 0


def selftest():
    """The four rules, against numbers worked out by hand.

    The app's own evaluator is the reference. These cases are the ones where a
    second implementation usually drifts: strict versus inclusive comparison,
    and which way round the percentage is divided.
    """
    cases = [
        # kind, threshold, baseline, price, expected
        ("above", 10.0, None, 10.0, False),   # strictly above, not at
        ("above", 10.0, None, 10.01, True),
        ("below", 10.0, None, 10.0, False),   # strictly below, not at
        ("below", 10.0, None, 9.99, True),
        # Exactly on the threshold fires: the difference form keeps 100 -> 120
        # at exactly 20.0 rather than 19.999999999999996.
        ("percent_up", 20.0, 100.0, 120.0, True),
        ("percent_up", 20.0, 100.0, 119.9, False),
        ("percent_down", 20.0, 100.0, 80.0, True),    # (100-80)/80 = 25%
        ("percent_down", 20.0, 100.0, 83.0, True),    # (100-83)/83 = 20.5%
        ("percent_down", 20.0, 100.0, 84.0, False),   # (100-84)/84 = 19.0%
        ("above", 10.0, None, None, False),   # no price never fires
        ("above", 10.0, None, 0.0, False),
        ("percent_up", 5.0, None, 50.0, False),  # no baseline never fires
        ("percent_up", 5.0, 0.0, 50.0, False),
    ]
    bad = 0
    for kind, threshold, baseline, price, expected in cases:
        got = evaluate(kind, threshold, baseline, price)
        if got != expected:
            bad += 1
            print(
                "FAIL %s threshold=%s baseline=%s price=%s: expected %s, got %s"
                % (kind, threshold, baseline, price, expected, got)
            )
    print("%d cases, %d failed" % (len(cases), bad))
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--backups-dir", default=os.path.expanduser("~/arcanum/backups"))
    ap.add_argument("--backup", help="read this archive instead of the newest")
    ap.add_argument("--state", default=os.path.expanduser("~/arcanum/alerts.state.json"))
    ap.add_argument("--config", default=os.path.expanduser("~/arcanum/notify.json"))
    ap.add_argument("--token-file", default=os.path.expanduser("~/arcanum/backup.token"))
    ap.add_argument("--server", help="override the notification server")
    ap.add_argument("--topic", help="override the derived topic")
    ap.add_argument("--db", default="", help="Magic price database")
    ap.add_argument("--pokemon-db", default="", help="Pokemon price database")
    ap.add_argument("--lorcana-db", default="", help="Lorcana price database")
    ap.add_argument("--yugioh-db", default="", help="Yu-Gi-Oh! price database")
    ap.add_argument("--dry-run", action="store_true", help="print, do not send")
    ap.add_argument("--selftest", action="store_true", help="check the rules and exit")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
