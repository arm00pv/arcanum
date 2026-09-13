#!/usr/bin/env python3
"""Self-check for the sync service's backup routes.

The backup routes are the only part of this service that writes anything, and
the only part that has to say no: an archive is the collector's whole
collection, holding what they own and what they paid for it, and the copy kept
on the server is the only backup of it. These checks run against a real server
on an ephemeral port, over real HTTP, and are mostly about who is allowed to do
what.

What it does:

  1. starts sync_server.py on the loopback with a temporary backups directory
     and a --backup-token path that does not exist yet, and checks that every
     backup route answers 503 and that nothing at all is written;
  2. installs a token without restarting the server, and checks that an upload
     with no token, or with the wrong one, is refused and still writes nothing;
  3. uploads archives with the right token and checks that the bytes come back
     from /v1/backup/latest unchanged, that a second upload is kept beside the
     first, and that only the newest 14 survive more of them than that;
  4. checks that a body longer than the cap is refused without disturbing what
     is already stored, and that a body which stops halfway leaves no archive
     behind - neither a new one nor a mark on the old one;
  5. rewrites the token file and checks that the new token works while the old
     one stops working, and that deleting the file closes the write path again;
  6. checks that the read-only routes still answer exactly as they did.

One line is printed per check and the exit status is non-zero if any of them
fails. The temporary directory is removed on success and kept - with its path
printed - on failure.

Usage:
    python check_backups.py [--keep] [--verbose]
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
import re
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

# The limits the checks are written against are the server's own, so a change
# to either of them is followed rather than quietly disagreed with.
import sync_server  # noqa: E402

SERVER = os.path.join(HERE, "sync_server.py")

# A Magic shaped fixture database, the same one check_samplers.py builds.
MAGIC_ID = "0f3f5c0a-1111-4222-8333-444455556666"
FIXTURE_DATE = "2024-05-05"
FIXTURE_PRICE = 3.21
UNKNOWN_ID = "crd_00000000000000000000000000000000"

# The tokens are long enough not to be mistaken for anything else, and neither
# is ever a prefix of the other, so a comparison that stopped early would show.
TOKEN = "collector-token-0123456789abcdef"
ROTATED_TOKEN = "rotated-token-fedcba9876543210"

ARCHIVE = gzip.compress(b'{"collection":"fixture","cards":42}')
ARCHIVE_2 = gzip.compress(b'{"collection":"fixture","cards":43,"note":"second"}')

# arcanum-backup-YYYY-MM-DDTHHMMSSZ[-device][.n].json.gz, which is the shape
# the app is told to expect back in Content-Disposition.
ARCHIVE_NAME = re.compile(
    r"^arcanum-backup-\d{4}-\d{2}-\d{2}T\d{6}Z(-[A-Za-z0-9._-]+)?(\.\d+)?\.json\.gz$"
)


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


def decode(raw, parse):
    if not parse:
        return raw
    try:
        return json.loads(raw.decode("utf-8"))
    except ValueError:
        return raw.decode("utf-8", "replace")


def http_call(url, method="GET", body=None, headers=None, parse=True, timeout=30):
    """Returns (status, body, headers), reading an error body rather than raising.

    body is decoded JSON unless parse is False, when it is the raw bytes:
    /v1/backup/latest answers gzip, not JSON.
    """
    request = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as resp:
            return resp.status, decode(resp.read(), parse), resp.headers
    except urllib.error.HTTPError as exc:
        return exc.code, decode(exc.read(), parse), exc.headers


def raw_post(port, headers, body=b"", half_close=False, timeout=30):
    """Sends one POST by hand and returns (status, body bytes).

    Two of the requests below cannot be made with urllib: a body longer than
    the cap is refused on its declared Content-Length before any of it is read,
    so the client has to be able to declare a length it never sends, and a body
    that stops halfway has to close its own write side to say so.
    """
    lines = ["POST /v1/backup HTTP/1.1", "Host: 127.0.0.1:%d" % port]
    lines += ["%s: %s" % (key, value) for key, value in sorted(headers.items())]
    request = ("\r\n".join(lines) + "\r\n\r\n").encode("utf-8") + body
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as sock:
        sock.sendall(request)
        if half_close:
            sock.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            try:
                chunk = sock.recv(65536)
            except (ConnectionResetError, socket.timeout):
                break
            if not chunk:
                break
            chunks.append(chunk)
    head, _sep, payload = b"".join(chunks).partition(b"\r\n\r\n")
    parts = head.split(b" ")
    status = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
    return status, payload


def timestamp(date_str):
    """Unix seconds at midnight UTC, which is what the service sends."""
    day = datetime.strptime(date_str, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    return int(day.timestamp())


def make_reference_db(path, id_column, rows):
    """A Magic shaped database, built the way the price tools build theirs."""
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


def start_server(port, db, backups, token_path, log_path):
    """Starts sync_server.py on the loopback with a temporary backup setup."""
    log = open(log_path, "w", encoding="utf-8")
    # The three optional game databases point at files that do not exist, so
    # the health counters are three zeros rather than a count of real data
    # somebody left in the checkout.
    proc = subprocess.Popen(
        [sys.executable, SERVER,
         "--host", "127.0.0.1", "--port", str(port), "--db", db,
         "--pokemon-db", os.path.join(backups, "none-pokemon.db"),
         "--lorcana-db", os.path.join(backups, "none-lorcana.db"),
         "--yugioh-db", os.path.join(backups, "none-yugioh.db"),
         "--backups-dir", backups, "--backup-token", token_path],
        cwd=HERE, stdout=log, stderr=subprocess.STDOUT,
    )
    log.close()
    url = f"http://127.0.0.1:{port}/v1/health"
    for _ in range(120):
        if proc.poll() is not None:
            raise RuntimeError("sync_server exited early:" + read_log(log_path))
        try:
            status, _body, _headers = http_call(url, timeout=2)
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
    ap.add_argument("--keep", action="store_true", help="keep the temporary directory")
    ap.add_argument("--verbose", action="store_true", help="print a traceback per failure")
    args = ap.parse_args()

    global TMP, VERBOSE
    VERBOSE = args.verbose
    TMP = tempfile.mkdtemp(prefix="arcanum_backups_")
    print(f"temporary directory {TMP}", flush=True)

    backups = os.path.join(TMP, "backups")
    token_path = os.path.join(TMP, "backup.token")
    db = os.path.join(TMP, "prices.db")
    make_reference_db(db, "scryfall_id",
                      [(MAGIC_ID, "nonfoil", FIXTURE_DATE, FIXTURE_PRICE)])

    port = free_port()
    log_path = os.path.join(TMP, "sync_server.log")
    proc = None
    try:
        proc = start_server(port, db, backups, token_path, log_path)
        base = f"http://127.0.0.1:{port}"
        print(f"sync_server listening on {base}", flush=True)
        print(f"backups directory {backups} (no token at {token_path} yet)", flush=True)
        print("", flush=True)

        def stored():
            """The archives on disk right now, oldest name first."""
            if not os.path.isdir(backups):
                return []
            names = [n for n in os.listdir(backups)
                     if n.startswith(sync_server.BACKUP_PREFIX)
                     and n.endswith(sync_server.BACKUP_SUFFIX)]
            return sorted(names)

        def snapshot():
            """Every archive and its bytes, for asking whether anything moved."""
            return {name: open(os.path.join(backups, name), "rb").read()
                    for name in stored()}

        def write_token(value):
            with open(token_path, "w", encoding="utf-8") as fh:
                fh.write(value)

        def upload(payload, token=None, device=None):
            headers = {}
            if token is not None:
                headers["X-Arcanum-Token"] = token
            if device is not None:
                headers["X-Arcanum-Device"] = device
            return http_call(base + "/v1/backup", method="POST", body=payload,
                             headers=headers)

        def status(token=None):
            headers = {"X-Arcanum-Token": token} if token else {}
            return http_call(base + "/v1/backup/status", headers=headers)

        # ---- no token file: there is no write path at all
        def check_no_token_file_is_503():
            """A server with no token installed must not have a write path."""
            for path in ("/v1/backup/status", "/v1/backup/latest"):
                code, body, _headers = http_call(base + path)
                expect(code == 503, f"GET {path} answered {code}, wanted 503")
                expect(isinstance(body, dict) and body.get("ok") is False,
                       f"GET {path} did not report ok false: {body!r}")
            code, _body, _headers = upload(ARCHIVE)
            expect(code == 503, f"an upload with no token header answered {code}, wanted 503")
            code, _body, _headers = upload(ARCHIVE, token="any-guess-at-all")
            expect(code == 503, f"an upload that guessed a token answered {code}, wanted 503")
            expect(stored() == [], f"an archive was written with no token file: {stored()}")
            expect(not os.path.isdir(backups),
                   "the backups directory was created with no token file")
            return "every backup route refuses, nothing on disk"

        # ---- 401s, once a token exists
        def check_token_appears_without_restart():
            """The token file is read per request, so installing one needs no restart."""
            write_token(TOKEN)
            code, _body, _headers = status()
            expect(code == 401, f"with a token installed and none sent, status answered {code}")
            code, body, _headers = status(TOKEN)
            expect(code == 200, f"with the installed token, status answered {code}: {body!r}")
            return "installed on a running server"

        def check_missing_and_wrong_token_are_401():
            """A refusal says only that it refused, and stores nothing."""
            code, body, _headers = upload(ARCHIVE)
            expect(code == 401, f"an upload with no token answered {code}, wanted 401")
            expect(body == {"ok": False, "error": "unauthorized"},
                   f"the 401 body names something it should not: {body!r}")
            wrong_code, wrong_body, _headers = upload(ARCHIVE, token="not-the-token")
            expect(wrong_code == 401, f"an upload with a wrong token answered {wrong_code}")
            expect(wrong_body == body,
                   "a wrong token got a different answer from no token at all")
            for path in ("/v1/backup/status", "/v1/backup/latest"):
                code, _body, _headers = http_call(base + path,
                                                  headers={"X-Arcanum-Token": "not-the-token"})
                expect(code == 401, f"GET {path} with a wrong token answered {code}")
            expect(stored() == [], f"a refused upload wrote {stored()}")
            return "401 for both, and the same 401"

        # ---- the write path itself
        def check_upload_round_trips():
            """What comes back out of /v1/backup/latest is what went in."""
            code, body, _headers = upload(ARCHIVE, token=TOKEN, device="iPhone-15")
            expect(code == 200, f"the upload answered {code}: {body!r}")
            expect(body.get("ok") is True, f"ok is not true: {body!r}")
            saved = body.get("saved") or ""
            expect(ARCHIVE_NAME.match(saved), f"the stored name is not the agreed shape: {saved!r}")
            expect("iPhone-15" in saved, f"the device header is not in the name: {saved!r}")
            expect(body.get("bytes") == len(ARCHIVE),
                   f"bytes is {body.get('bytes')}, sent {len(ARCHIVE)}")
            expect(body.get("kept") == 1, f"kept is {body.get('kept')}, wanted 1")
            expect(stored() == [saved], f"the directory holds {stored()}")

            code, got, headers = http_call(base + "/v1/backup/latest",
                                           headers={"X-Arcanum-Token": TOKEN}, parse=False)
            expect(code == 200, f"/v1/backup/latest answered {code}")
            expect(got == ARCHIVE, "the archive that came back is not the one that was sent")
            expect(headers.get("Content-Type") == "application/gzip",
                   f"Content-Type is {headers.get('Content-Type')!r}")
            disposition = headers.get("Content-Disposition") or ""
            expect(f'filename="{saved}"' in disposition,
                   f"Content-Disposition is {disposition!r}, wanted {saved!r}")
            return f"{saved}, {len(ARCHIVE)} bytes, unchanged"

        def check_second_upload_is_kept():
            """An upload adds to the history; it does not replace it."""
            code, body, _headers = upload(ARCHIVE_2, token=TOKEN)
            expect(code == 200, f"the second upload answered {code}: {body!r}")
            names = stored()
            expect(len(names) == 2, f"{len(names)} archives after two uploads: {names}")
            expect(len(set(names)) == 2, f"the two uploads share a name: {names}")
            code, body, _headers = status(TOKEN)
            expect(code == 200, f"status answered {code}: {body!r}")
            expect(body.get("backups") == 2, f"status counts {body.get('backups')}, wanted 2")
            expect(body.get("enabled") is True, f"status says enabled is {body.get('enabled')!r}")
            expect(body.get("bytes") == len(ARCHIVE_2),
                   f"status bytes is {body.get('bytes')}, the newest archive is {len(ARCHIVE_2)}")
            latest = body.get("latest")
            expect(isinstance(latest, str), f"latest is {latest!r}, wanted an ISO8601 time")
            when = datetime.fromisoformat(latest)
            expect(when.tzinfo is not None, f"latest is not timezone aware: {latest!r}")
            code, got, _headers = http_call(base + "/v1/backup/latest",
                                           headers={"X-Arcanum-Token": TOKEN}, parse=False)
            expect(got == ARCHIVE_2, "latest is not the archive that was uploaded last")
            return f"{len(names)} archives, status agrees"

        def check_retention_keeps_the_newest():
            """One more upload than the limit leaves the newest ones, not the first."""
            for name in stored():
                os.remove(os.path.join(backups, name))
            marker = b"arcanum-retention-fixture-"
            for count in range(1, sync_server.KEEP_BACKUPS + 2):
                payload = gzip.compress(marker + b"%02d" % count)
                code, body, _headers = upload(payload, token=TOKEN, device="dev%02d" % count)
                expect(code == 200, f"upload {count} answered {code}: {body!r}")
            names = stored()
            expect(len(names) == sync_server.KEEP_BACKUPS,
                   f"{len(names)} archives remain after {sync_server.KEEP_BACKUPS + 1} "
                   f"uploads, wanted {sync_server.KEEP_BACKUPS}")
            held = sorted(gzip.decompress(open(os.path.join(backups, name), "rb").read())
                          for name in names)
            expect(held[0] == marker + b"02" and held[-1] == marker + b"15",
                   "the archives kept are not the newest ones: "
                   + ", ".join(item.decode("utf-8", "replace") for item in held))
            code, body, _headers = status(TOKEN)
            expect(body.get("backups") == sync_server.KEEP_BACKUPS,
                   f"status counts {body.get('backups')} after retention")
            return f"{len(names)} kept, the oldest upload is gone"

        # ---- bodies that must not become archives
        def check_oversize_body_is_refused():
            """A body over the cap is refused before it is read, and changes nothing."""
            before = snapshot()
            code, body = raw_post(port, {"X-Arcanum-Token": TOKEN,
                                         "Content-Length": str(sync_server.MAX_BACKUP_BYTES + 1)})
            expect(code == 413, f"an over-long body answered {code}, wanted 413")
            expect(b"too large" in body, f"the 413 body is {body!r}")
            expect(snapshot() == before, "the refused upload changed what is stored")
            return f"{sync_server.MAX_BACKUP_BYTES + 1} declared, nothing read or written"

        def check_half_a_body_leaves_no_archive():
            """A body that stops halfway leaves no archive and no temporary file."""
            before = snapshot()
            partial = gzip.compress(b"arcanum-truncated-fixture")[:200]
            sent = len(partial)
            code, body = raw_post(port, {"X-Arcanum-Token": TOKEN,
                                         "Content-Length": str(sent + 100)},
                                  body=partial, half_close=True)
            expect(code == 400, f"a body that stopped early answered {code}, wanted 400")
            expect(b"incomplete" in body, f"the 400 body is {body!r}")
            expect(snapshot() == before, "a truncated upload disturbed what is stored")
            leftovers = [n for n in os.listdir(backups) if n not in stored()]
            expect(leftovers == [], f"a half-written file was left behind: {leftovers}")
            return f"{sent} of {sent + 100} bytes sent, nothing kept"

        def check_empty_body_is_refused():
            """An empty body is not an archive, and must not become the latest one."""
            before = snapshot()
            code, body, _headers = upload(b"", token=TOKEN)
            expect(code == 400, f"an empty upload answered {code}, wanted 400")
            expect(snapshot() == before, "an empty upload changed what is stored")
            return "400, nothing written"

        # ---- rotation
        def check_token_rotates():
            """The old token stops working the moment the file is rewritten."""
            write_token(ROTATED_TOKEN)
            code, _body, _headers = upload(ARCHIVE, token=TOKEN)
            expect(code == 401, f"the old token still worked after rotation: {code}")
            code, body, _headers = upload(ARCHIVE, token=ROTATED_TOKEN)
            expect(code == 200, f"the new token was refused: {code}: {body!r}")
            expect(ARCHIVE_NAME.match(body.get("saved") or ""),
                   f"the rotated upload stored {body.get('saved')!r}")
            return "the new token works, the old one does not"

        def check_removing_token_disables():
            """Deleting the token file closes the write path again, still live."""
            before = stored()
            os.remove(token_path)
            code, _body, _headers = upload(ARCHIVE, token=ROTATED_TOKEN)
            expect(code == 503, f"an upload with the token file gone answered {code}, wanted 503")
            expect(stored() == before, "an upload with the token file gone wrote an archive")
            write_token(ROTATED_TOKEN)
            code, _body, _headers = upload(ARCHIVE_2, token=ROTATED_TOKEN)
            expect(code == 200, f"restoring the token did not re-enable the write path: {code}")
            return "gone is gone, and back is back"

        # ---- the routes that were already there
        def check_health_is_unchanged():
            """The price service answers, to anyone, with the keys it always had."""
            code, body, _headers = http_call(base + "/v1/health")
            expect(code == 200, f"/v1/health answered {code}")
            expect(set(body) == {"ok", "printings", "points", "days", "games"},
                   f"/v1/health keys changed: {sorted(body)}")
            expect(set(body["games"]) == {"mtg", "pokemon", "lorcana", "yugioh"},
                   f"games are {sorted(body['games'])}")
            expect((body["printings"], body["points"], body["days"]) == (1, 1, 1),
                   "the Magic totals are "
                   f"{body['printings']}/{body['points']}/{body['days']}, wanted 1/1/1")
            return "the existing keys and their Magic totals"

        def check_history_routes_unchanged():
            """A known id still answers, and an unknown one still 404s the same way."""
            code, body, _headers = http_call(f"{base}/v1/history/{MAGIC_ID}.json")
            expect(code == 200, f"a known id answered {code}: {body!r}")
            expect(body.get("game") == "mtg", f"game is {body.get('game')!r}")
            expect(body.get("series") == {"nonfoil": [[timestamp(FIXTURE_DATE), FIXTURE_PRICE]]},
                   f"the series changed: {body.get('series')!r}")
            code, body, _headers = http_call(f"{base}/v1/history/{UNKNOWN_ID}.json")
            expect(code == 404, f"an unknown id answered {code}, wanted 404")
            expect(body == {"error": "no history", "id": UNKNOWN_ID},
                   f"the 404 body changed: {body!r}")
            return "the price routes are untouched"

        check("backups: with no token file every route is 503 and nothing is written",
              check_no_token_file_is_503)
        check("backups: installing a token needs no restart",
              check_token_appears_without_restart)
        check("backups: an absent or wrong token is 401, and writes nothing",
              check_missing_and_wrong_token_are_401)
        check("backups: the right token round-trips the archive unchanged",
              check_upload_round_trips)
        check("backups: a second upload is kept beside the first",
              check_second_upload_is_kept)
        check("backups: only the newest 14 archives are kept",
              check_retention_keeps_the_newest)
        check("backups: a body over the cap is refused and changes nothing",
              check_oversize_body_is_refused)
        check("backups: a body that stops halfway leaves no archive",
              check_half_a_body_leaves_no_archive)
        check("backups: an empty body is not an archive", check_empty_body_is_refused)
        check("backups: the token rotates without a restart", check_token_rotates)
        check("backups: deleting the token closes the write path again",
              check_removing_token_disables)
        check("read-only: /v1/health still answers with its existing keys",
              check_health_is_unchanged)
        check("read-only: an unknown history id still 404s with its existing body",
              check_history_routes_unchanged)
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
        print(f"temporary directory kept in {TMP}", flush=True)
        return 1
    if args.keep:
        print(f"temporary directory kept in {TMP}", flush=True)
    else:
        shutil.rmtree(TMP, ignore_errors=True)
    return 0


TMP = ""
VERBOSE = False

if __name__ == "__main__":
    raise SystemExit(main())
