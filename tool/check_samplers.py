#!/usr/bin/env python3
"""Self-check for the Lorcana and Yu-Gi-Oh! samplers and the sync service.

This is the check that would have caught a sampler writing points under ids the
app never asks for, which is silent: the day is sampled, the database grows, and
every chart stays empty. It runs entirely against local files and a loopback
server, so it needs no API key and no patience.

What it does:

  1. builds a small temporary history database for each of the two samplers,
     writing known points through each sampler's own insert path;
  2. starts sync_server.py against those two databases - plus a Magic and a
     Pokemon one, to prove the existing routes still answer - on an ephemeral
     port;
  3. asks it for an id of each game, for an id nobody holds, and for /v1/health,
     and checks the bodies against the shape the app parses.

One line is printed per check and the exit status is non-zero if any of them
fails. The temporary directory is removed on success and kept - with its path
printed - on failure.

Usage:
    python check_samplers.py [--keep] [--verbose]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import poll_lorcana_prices as lorcana  # noqa: E402
import poll_yugioh_prices as yugioh  # noqa: E402

SERVER = os.path.join(HERE, "sync_server.py")

# ---------------------------------------------------------------------------
# The known points, and the ids they belong under
# ---------------------------------------------------------------------------

# A real Lorcast id, in the shape the app stores: crd_ plus 32 hex digits.
LORCANA_ID = "crd_a9407e39c2ee47869d7a634aa46a7f04"

# The id lib/data/catalog/ygo_catalog.dart builds for Blue-Eyes White Dragon's
# Legend of Blue Eyes White Dragon printing (passcode 89631139, LOB-EN001, Ultra
# Rare), written out literally here so the sampler's own construction is checked
# against the app rather than against itself.
YUGIOH_ID = "89631139:lob:lob-en001:ultra-rare"

# A second Yu-Gi-Oh! printing, to show two ids of one card stay distinct.
YUGIOH_ID_2 = "89631139:ct13:ct13-en008:ultra-rare"

MAGIC_ID = "0f3f5c0a-1111-4222-8333-444455556666"
POKEMON_ID = "base1-4"

TODAY = datetime.now(timezone.utc).date()
YESTERDAY = TODAY - timedelta(days=1)


def timestamp(day):
    """Unix seconds at midnight UTC, which is what the service sends."""
    return int(datetime(day.year, day.month, day.day, tzinfo=timezone.utc).timestamp())


# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

RESULTS = []


def check(name, fn):
    """Runs one check, printing one line, and never letting it raise."""
    try:
        detail = fn()
    except Exception as exc:  # noqa: BLE001 - a check failing is data, not a crash
        RESULTS.append((name, False, str(exc)))
        print(f"FAIL  {name}: {exc.__class__.__name__}: {exc}", flush=True)
        if VERBOSE:
            import traceback
            traceback.print_exc()
        return False
    note = f"  ({detail})" if detail else ""
    RESULTS.append((name, True, ""))
    print(f"ok    {name}{note}", flush=True)
    return True


def expect(condition, message):
    if not condition:
        raise AssertionError(message)


def free_port():
    """One port the OS just handed back, for the server to bind ephemerally."""
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def http_get(url, timeout=10):
    """Returns (status, decoded body), reading an error body rather than raising."""
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8")
        try:
            return exc.code, json.loads(raw)
        except ValueError:
            return exc.code, raw


def parse_like_app(payload, finish="nonfoil"):
    """Re-implements parseHistoryPack from price_history_source.dart.

    The app accepts a two-element list of (unix seconds, price) and drops
    anything whose price is not a positive number, so a body only counts as
    correct if it survives exactly these rules.
    """
    if not isinstance(payload, dict):
        return []
    series = payload.get("series")
    if not isinstance(series, dict):
        return []
    raw = series.get(finish) or series.get("foil") or series.get("nonfoil")
    if not isinstance(raw, list):
        return []
    points = []
    for item in raw:
        expect(isinstance(item, list), f"series entry is not a list: {item!r}")
        expect(len(item) >= 2, f"series entry is not a pair: {item!r}")
        stamp, price = item[0], item[1]
        expect(isinstance(stamp, (int, float)) and not isinstance(stamp, bool),
               f"timestamp is not a number: {stamp!r}")
        expect(isinstance(price, (int, float)) and not isinstance(price, bool),
               f"price is not a number: {price!r}")
        expect(price > 0, f"price is not positive: {price!r}")
        points.append((datetime.fromtimestamp(stamp, timezone.utc).date().isoformat(), float(price)))
    points.sort()
    return points


def make_reference_db(path, id_column, rows):
    """A Magic or Pokemon shaped database, built the way those tools build it."""
    con = sqlite3.connect(path)
    con.execute(
        f"""
        CREATE TABLE history (
            {id_column} TEXT NOT NULL,
            finish      TEXT NOT NULL,
            date        TEXT NOT NULL,
            price       REAL NOT NULL,
            PRIMARY KEY ({id_column}, finish, date)
        ) WITHOUT ROWID
        """
    )
    con.executemany("INSERT INTO history VALUES (?,?,?,?)", rows)
    con.commit()
    con.close()


# ---------------------------------------------------------------------------
# Pure checks: the parsers and the id builder, no server involved
# ---------------------------------------------------------------------------


def check_lorcana_price_parsing():
    """A missing or unparseable price is skipped, never stored as zero."""
    cases = [
        ("1032.77", 1032.77),
        (" 0.25 ", 0.25),
        ("0", None),
        ("0.00", None),
        ("", None),
        ("n/a", None),
        (None, None),
        (True, None),
    ]
    for raw, want in cases:
        got = lorcana.money(raw)
        expect(got == want, f"money({raw!r}) == {got!r}, wanted {want!r}")

    # A card Lorcast quotes nothing for contributes no point at all.
    expect(lorcana.prices_of({"prices": {"usd": "0", "usd_foil": "1.50"}}) == {"foil": 1.5},
           "a zero non-foil price leaked into the output")
    expect(lorcana.prices_of({"prices": {}}) == {}, "an empty price block produced a point")
    expect(lorcana.prices_of({}) == {}, "a card with no price block produced a point")
    return f"{len(cases)} price strings"


def check_lorcana_rejects_unknown_set():
    """A set Lorcast does not answer for is a failure, not an empty set.

    Set codes are case-sensitive, so a wrong-case request is exactly the 404
    this guards: reading it as "this set has no cards" would drop a whole set
    from the day's sample without a word in the log.
    """
    original = lorcana.get_json
    lorcana.get_json = lambda *a, **k: None
    try:
        try:
            lorcana.cards_for_set("p1")
        except ValueError as exc:
            expect("case-sensitive" in str(exc), f"unexpected message: {exc}")
        else:
            raise AssertionError("a 404 set was read as an empty set")
    finally:
        lorcana.get_json = original
    return "a missing set raises instead of reporting zero cards"


def check_yugioh_id_shape():
    """The sampler builds the id the app's catalogue builds, field for field."""
    got = yugioh.printing_id(89631139, "lob", "LOB-EN001", "Ultra Rare")
    expect(got == YUGIOH_ID, f"got {got!r}, wanted {YUGIOH_ID!r}")
    got2 = yugioh.printing_id(89631139, "ct13", "CT13-EN008", "Ultra Rare")
    expect(got2 == YUGIOH_ID_2, f"got {got2!r}, wanted {YUGIOH_ID_2!r}")
    # The degenerate field values the Dart code substitutes.
    expect(yugioh.printing_id(12345, "lob", "", "") == "12345:lob:unplaced:unknown",
           "an empty printing code did not become 'unplaced'/'unknown'")
    expect(yugioh.printing_id(12345, "", "", "") == "12345",
           "a card with no set and no printing code did not collapse to its passcode")
    # Slugging, including the punctuation a rarity is full of.
    expect(yugioh.slug("Quarter Century Secret Rare") == "quarter-century-secret-rare",
           "rarity slugging changed")
    expect(yugioh.slug("LOB-EN001") == "lob-en001", "collector code slugging changed")
    return YUGIOH_ID


def check_yugioh_set_codes():
    """The app's set-code assignment is reproduced, collisions included.

    cardsets.php publishes YS15 three times; ygo_catalog.dart keeps the first as
    "ys15" and appends a bare counter to the rest, and the set code is the second
    field of every id, so this has to match exactly.
    """
    raw = [
        {"set_name": "Super Starter: V for Victory", "set_code": "YS14", "tcg_date": "2013-06-28"},
        {"set_name": "Dark Legion Starter Deck", "set_code": "YS15", "tcg_date": "2015-01-01"},
        {"set_name": "Saber Force Starter Deck", "set_code": "YS15", "tcg_date": "2015-06-01"},
        {"set_name": "Yuya & Declan", "set_code": "YS15", "tcg_date": "2015-05-28"},
        {"set_name": "No Code At All", "set_code": "", "tcg_date": ""},
    ]
    index = yugioh.set_index(raw)
    expect(index["dark legion starter deck"] == "ys15",
           f"first of a colliding group got {index['dark legion starter deck']!r}")
    expect(index["yuya & declan"] == "ys152",
           f"the second of a colliding group got {index['yuya & declan']!r}")
    expect(index["saber force starter deck"] == "ys153",
           f"the third of a colliding group got {index['saber force starter deck']!r}")
    # A set the provider left uncoded is keyed by its own lower-cased name,
    # which is the fallback _YgoSet.fromJson uses.
    expect(index["no code at all"] == "no code at all",
           f"a codless set got {index['no code at all']!r}")
    expect(len({index[k] for k in index}) == len(index),
           "two sets were assigned the same code")
    return ", ".join(f"{k}={v}" for k, v in sorted(index.items()))


def check_schema_matches_reference():
    """Both sampler databases carry the history table sync_server reads."""
    for module, label in ((lorcana, "lorcana"), (yugioh, "yugioh")):
        path = os.path.join(TMP, f"schema_{label}.db")
        con = module.connect(path)
        cols = [(row[1], row[2]) for row in con.execute("PRAGMA table_info(history)")]
        con.close()
        expect(cols == [("card_id", "TEXT"), ("finish", "TEXT"), ("date", "TEXT"), ("price", "REAL")],
               f"{label} history columns are {cols}")
    return "card_id, finish, date, price"


def check_write_is_idempotent():
    """Sampling the same day twice leaves one row per card and finish."""
    for module, label, row in ((lorcana, "lorcana", (LORCANA_ID, "nonfoil", str(TODAY), 1.5)),
                               (yugioh, "yugioh", (YUGIOH_ID, "nonfoil", str(TODAY), 74.49))):
        path = os.path.join(TMP, f"idem_{label}.db")
        con = module.connect(path)
        module.write_points(con, [row])
        module.write_points(con, [row, (row[0], "foil", str(TODAY), 2.5)])
        module.write_points(con, [row])
        count = con.execute("SELECT COUNT(*) FROM history").fetchone()[0]
        price = con.execute(
            "SELECT price FROM history WHERE card_id=? AND finish=?", (row[0], row[1])
        ).fetchone()[0]
        con.close()
        expect(count == 2, f"{label} held {count} rows after three writes, wanted 2")
        expect(price == row[3], f"{label} lost the original price")
    return "one row per (card, finish, date)"


def check_partial_failure_is_safe():
    """A batch that fails rolls back and leaves the committed days alone."""
    for module, label, row in ((lorcana, "lorcana", (LORCANA_ID, "nonfoil", str(TODAY), 1.5)),
                               (yugioh, "yugioh", (YUGIOH_ID, "nonfoil", str(TODAY), 74.49))):
        path = os.path.join(TMP, f"partial_{label}.db")
        con = module.connect(path)
        module.write_points(con, [row])
        raised = False
        try:
            # The second row is missing its price: the whole batch must fail.
            module.write_points(con, [(row[0], "foil", str(TODAY), 2.0), (row[0], "foil", str(TODAY))])
        except sqlite3.Error:
            raised = True
        expect(raised, f"{label} accepted a malformed batch")
        count = con.execute("SELECT COUNT(*) FROM history").fetchone()[0]
        held = con.execute("SELECT price FROM history WHERE card_id=?", (row[0],)).fetchone()
        con.close()
        expect(count == 1, f"{label} kept {count} rows after a failed batch, wanted 1")
        expect(held is not None and held[0] == row[3], f"{label} lost the committed point")
    return "committed batch survived the failed one"


# ---------------------------------------------------------------------------
# Server checks
# ---------------------------------------------------------------------------


def start_server(port, dbs, log_path):
    """Starts sync_server.py on the loopback with one database per game."""
    log = open(log_path, "w", encoding="utf-8")
    proc = subprocess.Popen(
        [sys.executable, SERVER,
         "--host", "127.0.0.1", "--port", str(port),
         "--db", dbs["mtg"], "--pokemon-db", dbs["pokemon"],
         "--lorcana-db", dbs["lorcana"], "--yugioh-db", dbs["yugioh"]],
        cwd=HERE, stdout=log, stderr=subprocess.STDOUT,
    )
    log.close()
    url = f"http://127.0.0.1:{port}/v1/health"
    for _ in range(120):
        if proc.poll() is not None:
            raise RuntimeError("sync_server exited early:" + read_log(log_path))
        try:
            status, _body = http_get(url, timeout=2)
            if status == 200:
                return proc
        except Exception:
            pass
        time.sleep(0.25)
    proc.kill()
    raise RuntimeError("sync_server never answered:" + read_log(log_path))


def read_log(path, limit=2000):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return "\n" + fh.read()[-limit:]
    except OSError:
        return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", action="store_true", help="keep the temporary databases")
    ap.add_argument("--verbose", action="store_true", help="print a traceback per failure")
    args = ap.parse_args()

    global TMP, VERBOSE
    VERBOSE = args.verbose
    TMP = tempfile.mkdtemp(prefix="arcanum_samplers_")
    print(f"temporary databases in {TMP}", flush=True)

    # ---- what each sampler recorded today
    lorcana_rows = [
        (LORCANA_ID, "nonfoil", str(YESTERDAY), 1000.00),
        (LORCANA_ID, "foil", str(YESTERDAY), 1200.00),
        (LORCANA_ID, "nonfoil", str(TODAY), 1032.77),
        (LORCANA_ID, "foil", str(TODAY), 1234.56),
    ]
    yugioh_rows = [
        (YUGIOH_ID, "nonfoil", str(YESTERDAY), 70.00),
        (YUGIOH_ID, "nonfoil", str(TODAY), 74.49),
        (YUGIOH_ID_2, "nonfoil", str(TODAY), 74.49),
    ]

    dbs = {game: os.path.join(TMP, f"{game}.db") for game in ("mtg", "pokemon", "lorcana", "yugioh")}
    make_reference_db(dbs["mtg"], "scryfall_id", [(MAGIC_ID, "nonfoil", str(TODAY), 3.21)])
    make_reference_db(dbs["pokemon"], "card_id", [(POKEMON_ID, "nonfoil", str(TODAY), 412.50)])

    for module, game, rows in ((lorcana, "lorcana", lorcana_rows), (yugioh, "yugioh", yugioh_rows)):
        con = module.connect(dbs[game])
        module.write_points(con, rows)
        con.close()

    # ---- the checks that need no server
    print("", flush=True)
    check("lorcana: a missing or unparseable price is skipped, not zeroed", check_lorcana_price_parsing)
    check("lorcana: an unknown set fails loudly instead of reading as empty", check_lorcana_rejects_unknown_set)
    check("yugioh: printing ids match lib/data/catalog/ygo_catalog.dart", check_yugioh_id_shape)
    check("yugioh: set codes mirror the app's collision suffixes", check_yugioh_set_codes)
    check("both: the history table matches what sync_server reads", check_schema_matches_reference)
    check("both: writing the same day twice is idempotent", check_write_is_idempotent)
    check("both: a failed batch cannot corrupt what is stored", check_partial_failure_is_safe)

    # ---- the service
    print("", flush=True)
    port = free_port()
    log_path = os.path.join(TMP, "sync_server.log")
    proc = None
    try:
        proc = start_server(port, dbs, log_path)
        base = f"http://127.0.0.1:{port}"
        print(f"sync_server listening on {base}", flush=True)
        print("", flush=True)

        def health():
            return http_get(base + "/v1/health")

        def health_games():
            status, body = health()
            expect(status == 200, f"/v1/health answered {status}")
            expect(body.get("ok") is True, "ok is not true")
            games = body.get("games")
            expect(isinstance(games, dict), "games is missing")
            for game in ("mtg", "pokemon", "lorcana", "yugioh"):
                expect(game in games, f"games has no {game} entry")
            for game, counts in games.items():
                expect(set(counts) == {"printings", "points", "days"},
                       f"{game} counters are {sorted(counts)}")
                for key, value in counts.items():
                    expect(isinstance(value, int), f"{game}.{key} is not an integer")
            return body

        def check_health_keeps_magic_totals():
            body = health_games()
            expect(body["printings"] == 1, f"top-level printings is {body['printings']}, wanted 1")
            expect(body["points"] == 1, f"top-level points is {body['points']}, wanted 1")
            expect(body["days"] == 1, f"top-level days is {body['days']}, wanted 1")
            expect(body["games"]["mtg"]["points"] == 1, "the mtg counters disagree with the totals")
            return "printings/points/days still mean Magic"

        def check_health_counts_the_samplers():
            games = health_games()["games"]
            expect(games["lorcana"]["points"] == len(lorcana_rows),
                   f"lorcana points is {games['lorcana']['points']}, wanted {len(lorcana_rows)}")
            expect(games["lorcana"]["printings"] == 1, "lorcana printings is not 1")
            expect(games["lorcana"]["days"] == 2, "lorcana days is not 2")
            expect(games["yugioh"]["points"] == len(yugioh_rows),
                   f"yugioh points is {games['yugioh']['points']}, wanted {len(yugioh_rows)}")
            expect(games["yugioh"]["printings"] == 2, "yugioh printings is not 2")
            expect(games["pokemon"]["points"] == 1, "pokemon points is not 1")
            return "lorcana 4 points / yugioh 3 points / pokemon 1 point"

        def history(card_id):
            return http_get(f"{base}/v1/history/{card_id}.json")

        def check_lorcana_history():
            status, body = history(LORCANA_ID)
            expect(status == 200, f"answered {status}: {body!r}")
            expect(body.get("id") == LORCANA_ID, "id was not echoed")
            expect(body.get("game") == "lorcana", f"game is {body.get('game')!r}")
            expect(body.get("updated") == str(TODAY), f"updated is {body.get('updated')!r}")
            expect(set(body["series"]) == {"nonfoil", "foil"}, f"finishes are {sorted(body['series'])}")
            expect(body["series"]["nonfoil"] == [[timestamp(YESTERDAY), 1000.0], [timestamp(TODAY), 1032.77]],
                   f"nonfoil series is {body['series']['nonfoil']!r}")
            expect(body["series"]["foil"] == [[timestamp(YESTERDAY), 1200.0], [timestamp(TODAY), 1234.56]],
                   f"foil series is {body['series']['foil']!r}")
            return f"{LORCANA_ID} -> 2 finishes"

        def check_yugioh_history():
            status, body = history(YUGIOH_ID)
            expect(status == 200, f"answered {status}: {body!r}")
            expect(body.get("id") == YUGIOH_ID, "id was not echoed")
            expect(body.get("game") == "yugioh", f"game is {body.get('game')!r}")
            expect(set(body["series"]) == {"nonfoil"},
                   f"a finish the source cannot support was served: {sorted(body['series'])}")
            expect(body["series"]["nonfoil"] == [[timestamp(YESTERDAY), 70.0], [timestamp(TODAY), 74.49]],
                   f"series is {body['series']['nonfoil']!r}")
            expect(timestamp(TODAY) > timestamp(YESTERDAY), "the fixture itself is out of order")
            return f"{YUGIOH_ID} -> nonfoil only"

        def check_compound_id_resolves_per_printing():
            status, body = history(YUGIOH_ID_2)
            expect(status == 200, f"answered {status} for the second printing of one card")
            expect(body["id"] == YUGIOH_ID_2, "id was not echoed")
            return "two printings of one passcode stay apart"

        def check_existing_games_still_answer():
            status, body = history(MAGIC_ID)
            expect(status == 200, f"magic answered {status}")
            expect(body["game"] == "mtg", f"magic game is {body.get('game')!r}")
            status, body = history(POKEMON_ID)
            expect(status == 200, f"pokemon answered {status}")
            expect(body["game"] == "pokemon", f"pokemon game is {body.get('game')!r}")
            return "mtg and pokemon routes unchanged"

        def check_unknown_id_404s():
            status, body = history("crd_00000000000000000000000000000000")
            expect(status == 404, f"answered {status}, wanted 404")
            expect(body == {"error": "no history", "id": "crd_00000000000000000000000000000000"},
                   f"404 body changed: {body!r}")
            expect("game" not in body, "a miss named a database")
            return "the existing 404 body"

        def check_app_parses_the_body():
            _status, body = history(LORCANA_ID)
            points = parse_like_app(body, "nonfoil")
            expect(points == [(str(YESTERDAY), 1000.0), (str(TODAY), 1032.77)],
                   f"the app's parser read {points!r}")
            points = parse_like_app(body, "foil")
            expect(points == [(str(YESTERDAY), 1200.0), (str(TODAY), 1234.56)],
                   f"the app's parser read {points!r}")
            _status, ybody = history(YUGIOH_ID)
            ypoints = parse_like_app(ybody, "nonfoil")
            expect(ypoints == [(str(YESTERDAY), 70.0), (str(TODAY), 74.49)],
                   f"the app's parser read {ypoints!r}")
            return "series: {finish: [[unix_seconds, price]]}"

        def check_health_is_cached():
            first = health_games()["games"]
            second = health_games()["games"]
            expect(first == second, "two reads of /v1/health disagreed")
            return "counts are served from memory"

        check("health: still reports Magic at the top level", check_health_keeps_magic_totals)
        check("health: counts every game, including the two new ones", check_health_counts_the_samplers)
        check("history: a Lorcana id answers with its series", check_lorcana_history)
        check("history: a Yu-Gi-Oh! id answers with its series", check_yugioh_history)
        check("history: two printings of one passcode stay apart", check_compound_id_resolves_per_printing)
        check("history: the Magic and Pokemon routes are unchanged", check_existing_games_still_answer)
        check("history: an id nobody holds still 404s", check_unknown_id_404s)
        check("history: the payload is what the app parses", check_app_parses_the_body)
        check("health: repeated reads agree (counts are cached)", check_health_is_cached)
    finally:
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
        if proc is not None and proc.returncode not in (0, None) and VERBOSE:
            print(read_log(log_path), flush=True)

    failed = [name for name, ok, _detail in RESULTS if not ok]
    print("", flush=True)
    print(f"{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed", flush=True)
    if failed:
        for name in failed:
            print(f"  FAILED: {name}", flush=True)
        print(f"temporary databases kept in {TMP}", flush=True)
        return 1
    if args.keep:
        print(f"temporary databases kept in {TMP}", flush=True)
    else:
        shutil.rmtree(TMP, ignore_errors=True)
    return 0


TMP = ""
VERBOSE = False

if __name__ == "__main__":
    raise SystemExit(main())
