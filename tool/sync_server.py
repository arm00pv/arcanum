#!/usr/bin/env python3
"""Arcanum Sync - a tiny price-history and backup service for the Arcanum app.

Scryfall exposes only *current* card prices, so real trend analysis needs a
history provider. This service reads the compact SQLite databases the tools in
this directory produce - one per game: Magic from slice_prices.py, and Pokemon,
Lorcana and Yu-Gi-Oh! from the daily pollers - and answers one small JSON
document per printing.

Endpoints:

  GET /v1/health
      {"ok": true, "printings": N, "points": M, "days": D,
       "games": {"mtg": {..}, "pokemon": {..}, "lorcana": {..}, "yugioh": {..}}}
  GET /v1/history/<cardId>.json
      {"id": ..., "updated": ..., "series": {"nonfoil": [[ts, price], ...]}, "game": ...}
      Dates are unix seconds. Missing printings return 404 with a JSON body.
  GET /v1/sealed?game=mtg&set=BLB
      {"set": "BLB", "setName": "Bloomburrow", "updated": ...,
       "products": [{"productId":..., "name":..., "market":..., "low":..., "mid":...}]}
      Sealed product and what it sells for, read from TCGplayer's own product
      dumps through tcgcsv.com and cached here for half a day. Cards are filtered
      out structurally - a single carries a rarity and a collector number, a box
      carries neither - so nothing has to guess from a name alone. A set this
      server cannot resolve answers 404 and the app falls back to typing it in.

The four games address a printing differently - Scryfall UUIDs, TCGdex ids,
Lorcast's crd_ ids and Yu-Gi-Oh!'s compound ids - and those id spaces do not
overlap, so the id alone decides which database answers.

Backups, for the collector whose collection exists only on the phone:

  POST /v1/backup      body: the archive bytes (the app sends gzip)
      {"ok": true, "saved": "arcanum-backup-...json.gz", "bytes": N, "kept": K}
  GET  /v1/backup/latest[?not_device=LABEL]
      the newest archive as application/gzip, or 404 when there is none.
      With not_device, the newest archive that no device named LABEL wrote,
      which is what a second phone merges: a copy of its own is no news to it.
      The reply carries X-Arcanum-Device and X-Arcanum-Written, so the app can
      name the phone the copy came from without decoding the archive.
  GET  /v1/backup/status
      {"ok": true, "enabled": true, "backups": N, "latest": "<ISO8601 or null>", "bytes": N, "devices": [...]}

Every backup route demands an X-Arcanum-Token header matching a credential this
server accepts, read on each request so it can be rotated or revoked without a
restart. The routes above answer to anyone, as they always have; these three
must not, because a stranger who found the URL could otherwise read a
collection - what the collector owns and what they paid for it - or overwrite
the only backup of it. With no credential installed there is no write path at
all: every backup route answers 503 and stores nothing. The newest 14 archives
are kept, so an upload adds history rather than replacing it.

Identity, for the phone that has never been here:

  POST /v1/auth/start    body: {"email": "..."}
      {"ok": true, "sent": true, "expires": <unix>} and a six-digit code by
      email, or {"ok": true, "sent": false} and nothing at all. An address that
      is not invited gets the same answer as one that is, unless the caller
      already holds a credential - the answer to "is this address allowed here"
      is not a question a stranger should be able to ask.
  POST /v1/auth/verify   body: {"email": "...", "code": "123456", "device": "label"}
      {"ok": true, "token": "...", "device": "label"}. The token is returned
      once and stored only as a digest, and the code is spent by the answering
      of it.
  GET  /v1/auth/devices
      {"ok": true, "owner": ..., "invited": [...], "devices": [{label, created,
       last_seen, current}], "email": true|false}
  POST /v1/auth/revoke   body: {"device": "label"}
      {"ok": true, "removed": true}. The root token is not a device and cannot
      be revoked this way, so a server can never be locked out of itself.

Email, once a credential is held:

  GET  /v1/email/vault   ... POST, body: {"to": "..."} (defaults to the owner)
      mails a link that opens the vault page, backed by a device of its own
      named "vault-link" with a week to live.
  POST /v1/email/backup
      mails the newest archive as an attachment, exactly as it was uploaded.

A vault link is a device token, and a device token opens everything the root
token opens - the vault page included. One mechanism, one list to revoke from.

Setting the server up:

    python sync_server.py --set-owner you@example.com
    python sync_server.py --invite someone@example.com
    python sync_server.py --devices

Run:
    python sync_server.py --port 8787 --db tool/prices/prices.db \
        --public-url https://example.com/arcanum --mail-from "Arcanum <arcanum@example.com>"
"""

from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import socket
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

DB_PATH = ""
POKEMON_DB_PATH = ""
LORCANA_DB_PATH = ""
YUGIOH_DB_PATH = ""
BACKUP_TOKEN_PATH = ""
BACKUPS_DIR = ""
IDENTITY_PATH = ""
RESEND_KEY_PATH = ""
MAIL_FROM = "Arcanum <onboarding@resend.dev>"
PUBLIC_URL = ""
_LOCK = threading.Lock()
_CONNS = {}

# Backups. The archive is the collector's whole collection, so the write path
# is deliberately narrow: one token, one directory, one shape of filename.
BACKUP_PREFIX = "arcanum-backup-"
BACKUP_SUFFIX = ".json.gz"
BACKUP_STAMP = "%Y-%m-%dT%H%M%SZ"
BACKUP_STAMP_WIDTH = len("YYYY-MM-DDTHHMMSSZ")
INCOMING_PREFIX = ".incoming-"
KEEP_BACKUPS = 14
MAX_BACKUP_BYTES = 64 * 1024 * 1024
DRAIN_LIMIT = 64 * 1024
DRAIN_TIMEOUT = 0.5

# Identity and email. The app has no password and no account, and this is what
# stands in for both: a six-digit code mailed to an address the server already
# knows, traded once for a token of the device's own.
IDENTITY_VERSION = 1
CODE_TTL = 10 * 60           # a code is good for ten minutes
CODE_TRIES = 5               # and for five guesses
CODE_COOLDOWN = 60           # one email a minute
CODE_PER_HOUR = 5            # and five an hour
LINK_TTL = 7 * 24 * 3600     # an emailed vault link lasts a week
MAX_JSON_BYTES = 64 * 1024
MAX_ATTACH_BYTES = 12 * 1024 * 1024
MAIL_TIMEOUT = 20
RESEND_ENDPOINT = "https://api.resend.com/emails"
# Resend answers through Cloudflare, which refuses a request that looks like a
# script: the default urllib agent is banned outright (error code 1010) and the
# refusal arrives as one line of text rather than as JSON. Naming ourselves is
# the whole fix, and it is also what lets Resend tell us apart from a stranger.
MAIL_AGENT = "Arcanum-companion/1.0 (+https://github.com/arm00pv/arcanum)"
_SENT = {}                   # address -> [unix seconds], deliberately in memory


def conn(path=None):
    """Returns a shared connection for a database path."""
    key = path or DB_PATH
    if key not in _CONNS:
        c = sqlite3.connect(key, check_same_thread=False)
        c.row_factory = sqlite3.Row
        _CONNS[key] = c
    return _CONNS[key]


def sources():
    """(path, id column, game) for every database, Magic first.

    The game name is the app's own CardGame id, so it is the same word in a
    history payload and in the health counters. A path is empty when that game's
    database is not configured or does not exist yet.
    """
    return (
        (DB_PATH, "scryfall_id", "mtg"),
        (POKEMON_DB_PATH, "card_id", "pokemon"),
        (LORCANA_DB_PATH, "card_id", "lorcana"),
        (YUGIOH_DB_PATH, "card_id", "yugioh"),
    )


def databases():
    """Every database this server can answer from, Arcanum first."""
    return [path for path, _column, _game in sources() if path]


def to_unix(date_str):
    try:
        d = datetime.strptime(date_str, "%Y-%m-%d").replace(tzinfo=timezone.utc)
        return int(d.timestamp())
    except ValueError:
        return None


def _series_from(path, column, card_id):
    """Reads one card's series out of a database, or None when absent."""
    with _LOCK:
        try:
            rows = conn(path).execute(
                f"SELECT finish, date, price FROM history WHERE {column} = ? ORDER BY date ASC",
                (card_id,),
            ).fetchall()
        except sqlite3.Error:
            return None
    if not rows:
        return None
    series = {}
    for r in rows:
        ts = to_unix(r["date"])
        if ts is None:
            continue
        series.setdefault(r["finish"], []).append([ts, round(float(r["price"]), 4)])
    return series or None


def history_for(card_id):
    """Looks a card up in every configured database.

    The games key a printing differently - Magic by Scryfall id, Pokemon by
    TCGdex id, Lorcana by Lorcast's crd_ id, Yu-Gi-Oh! by its compound
    passcode:set:code:rarity id - so rather than make the client say which game
    it is asking about, the server tries each database in turn; the id spaces do
    not overlap in practice. The reply names the database that answered.
    """
    for path, column, game in sources():
        if not path:
            continue
        series = _series_from(path, column, card_id)
        if series:
            return {
                "id": card_id,
                "updated": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
                "series": series,
                "game": game,
            }
    return None


# Counting 13M rows takes tens of seconds, so the health figures are computed
# once per process and then served from memory.
#
# A count that fails is never cached. The database is rewritten in place by the
# weekly slice, and reading it mid-swap used to raise "database is locked" -
# which the old code reported as a confident "0 printings" for the life of the
# process. Zeros now mean the cache is cold, not that the archive is empty.
#
# A database that is simply not there yet is the other case, and it is not a
# failure: it holds nothing, and (0, 0, 0) says exactly that. Those figures are
# cached like any other, so a game whose poller has not run yet cannot make
# /v1/health re-count the 13M Magic rows on every request.
_STATS = None


def _counts(path, column):
    """(printings, points, days) for one database, or None when the read failed."""
    if not path or not os.path.exists(path):
        return (0, 0, 0)
    with _LOCK:
        try:
            c = conn(path)
            printings = c.execute(
                f"SELECT COUNT(DISTINCT {column}) FROM history"
            ).fetchone()[0]
            points = c.execute("SELECT COUNT(*) FROM history").fetchone()[0]
            days = c.execute("SELECT COUNT(DISTINCT date) FROM history").fetchone()[0]
        except sqlite3.Error:
            return None
    return (printings, points, days)


def _empty():
    return {"printings": 0, "points": 0, "days": 0}


def _game(counts):
    """One game's counters, zeros when its database is missing or unreadable."""
    if not counts:
        return _empty()
    return {"printings": counts[0], "points": counts[1], "days": counts[2]}


def stats():
    global _STATS
    if _STATS is not None:
        return _STATS
    counts = {}
    for path, column, game in sources():
        counts[game] = _counts(path, column)
    mtg = counts["mtg"] or (0, 0, 0)
    payload = {
        "ok": True,
        # The top-level figures have always meant Magic, and still do.
        "printings": mtg[0],
        "points": mtg[1],
        "days": mtg[2],
        "games": {game: _game(value) for game, value in counts.items()},
    }
    if all(counts.values()):
        _STATS = payload
    return payload


# ---------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------
#
# The app's collection lives in SQLite on the phone and is the only copy of it
# that exists, so the server keeps a short history of the archives the app
# uploads. Everything below is written for a URL strangers can find: a token
# file decides whether there is a write path at all, the token is read on every
# request so it can be rotated, and nothing an unauthenticated caller can send
# changes what is stored.


def installed_token():
    """The token a backup request must carry, or None when there is none.

    Read on every request rather than once at startup: a token can then be
    rotated - or deleted, which closes the write path again - without a
    restart. A file that is missing, unreadable or empty means no write path
    at all, which is the safe way round for a service that is otherwise
    read-only.
    """
    try:
        with open(BACKUP_TOKEN_PATH, "r", encoding="utf-8") as fh:
            token = fh.read().strip()
    except OSError:
        return None
    return token or None


def token_matches(supplied, expected):
    """Compares two tokens in constant time, so a guess cannot be timed.

    hmac.compare_digest is the only comparison a token is ever put through:
    == stops at the first byte that differs, and over enough requests that
    difference in timing is a way to learn a token without ever seeing it.
    """
    return hmac.compare_digest(supplied.encode("utf-8"), expected.encode("utf-8"))


# Identity: who may use this server, and how a phone that has never been here
# gets a token of its own.
#
# Arcanum has no account and no password, and this is what it has instead. The
# collector types the address that owns this server into a new phone, the server
# mails a six-digit code, and the app trades that code for a device token. No
# secret crosses the wire in a form worth stealing: the code is short-lived and
# single-use, the token is returned exactly once and stored only as a digest,
# and the address is the only identity Arcanum ever holds.
#
# An address that is not invited gets no code - and, from a caller who holds no
# credential, not even the news that it is not invited. That second half matters
# because this server answers on a URL strangers can find: "is this address
# allowed here" is not a question they should be able to ask, while the
# collector debugging their own server is told the truth.
#
# One small document holds all of it - the owner, the invited addresses, the
# device tokens and the outstanding codes - because one document written
# atomically is easier to reason about than four files that can disagree.


def token_digest(token):
    """What is stored for a token: the digest, never the token itself.

    A copy of the identity file is then not a copy of everyone's credentials,
    and neither is a backup of it.
    """
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def new_token():
    """A fresh device token: the same shape as the root token, from the same CSPRNG."""
    return secrets.token_urlsafe(32)


def empty_identity():
    """An identity document with nobody in it."""
    return {"version": IDENTITY_VERSION, "owner": "", "invited": [],
            "devices": [], "codes": []}


def identity():
    """Reads the identity document, or an empty one when there is none.

    Unreadable counts as empty rather than as an error: a server whose identity
    file has been deleted is one the root token still opens, which is the safe
    way round to fail.
    """
    if not IDENTITY_PATH:
        return empty_identity()
    try:
        with open(IDENTITY_PATH, "r", encoding="utf-8") as handle:
            raw = json.load(handle)
    except (OSError, ValueError):
        return empty_identity()
    if not isinstance(raw, dict):
        return empty_identity()
    doc = empty_identity()
    doc["owner"] = str(raw.get("owner") or "").strip().lower()
    doc["invited"] = [str(address).strip().lower()
                      for address in (raw.get("invited") or [])
                      if str(address).strip()]
    doc["devices"] = [entry for entry in (raw.get("devices") or [])
                      if isinstance(entry, dict)]
    doc["codes"] = [entry for entry in (raw.get("codes") or [])
                    if isinstance(entry, dict)]
    return doc


def save_identity(doc):
    """Writes the identity document whole and atomically, or leaves it alone.

    A half-written identity file would be a server that has forgotten who may
    use it, so the new copy is flushed to a temporary name and moved into place
    in one step.
    """
    if not IDENTITY_PATH:
        return False
    folder = os.path.dirname(IDENTITY_PATH)
    try:
        if folder:
            os.makedirs(folder, exist_ok=True)
        tmp = IDENTITY_PATH + ".new"
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(doc, handle, indent=1, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, IDENTITY_PATH)
    except OSError:
        return False
    return True


def invited_addresses(doc):
    """Every address this server will send a code to, the owner first."""
    found = []
    if doc.get("owner"):
        found.append(doc["owner"])
    for address in doc.get("invited") or []:
        if address not in found:
            found.append(address)
    return found


def is_invited(doc, address):
    """Whether an address may ask for a code."""
    return address.strip().lower() in invited_addresses(doc)


def devices_of(doc):
    """The devices holding a token, in the order they were added."""
    return list(doc.get("devices") or [])


def authorized(supplied):
    """Whether a request carries a credential this server accepts.

    Two kinds count, and both are read on every request. The root token in the
    token file is the credential typed into the app by hand, and it keeps
    working - it is what makes a deleted identity file a working server rather
    than a locked one. A device token is the other kind: minted from an emailed
    code, stored only as a digest, and revocable one device at a time.
    """
    if not supplied:
        return False
    root = installed_token()
    if root is not None and token_matches(supplied, root):
        return True
    digest = token_digest(supplied)
    now = int(time.time())
    for device in devices_of(identity()):
        stored = str(device.get("hash") or "")
        if not stored or not hmac.compare_digest(digest, stored):
            continue
        expires = int(device.get("expires") or 0)
        # A device with no expiry is one somebody signed in on; a device with
        # one is a link that was mailed, and a link that has run out is not a
        # credential any more than one that was revoked.
        return expires == 0 or expires > now
    return False


def touch_device(supplied):
    """Notes that a device token was used, so the list can say when it last was.

    Written at most once every five minutes per token: a note that is only ever
    read by a person is not worth a file write on every request.
    """
    digest = token_digest(supplied)
    doc = identity()
    now = int(time.time())
    changed = False
    for device in doc["devices"]:
        if hmac.compare_digest(digest, str(device.get("hash") or "")):
            if now - int(device.get("last_seen") or 0) > 300:
                device["last_seen"] = now
                changed = True
            break
    if changed:
        save_identity(doc)


def add_device(label, ttl=0):
    """Mints a device token and returns it, exactly once.

    The label is the phone's own name, so the server's list of credentials reads
    as a list of devices. Minting again under a label that already exists
    replaces it, which is what makes "sign in again on the same phone" leave one
    row behind rather than two.
    """
    token = new_token()
    now = int(time.time())
    doc = identity()
    doc["devices"] = [entry for entry in doc["devices"]
                      if str(entry.get("label") or "") != label]
    doc["devices"].append({"label": label, "hash": token_digest(token),
                           "created": now, "last_seen": now,
                           "expires": (now + ttl) if ttl else 0})
    save_identity(doc)
    return token


def drop_device(label):
    """Removes one device's token. Returns whether there was one to remove."""
    doc = identity()
    before = len(doc["devices"])
    doc["devices"] = [entry for entry in doc["devices"]
                      if str(entry.get("label") or "") != label]
    if len(doc["devices"]) == before:
        return False
    save_identity(doc)
    return True


def mail_allowed(address):
    """Whether another code may go to this address right now, and how long to wait.

    Two limits, because they stop different things: a minute between codes stops
    somebody tapping the button ten times, and five an hour stops a stranger
    using this server to post mail at an address that never asked for it.
    """
    now = time.time()
    with _LOCK:
        sent = [stamp for stamp in _SENT.get(address, []) if now - stamp < 3600]
        _SENT[address] = sent
        if sent and now - sent[-1] < CODE_COOLDOWN:
            return False, int(CODE_COOLDOWN - (now - sent[-1])) + 1
        if len(sent) >= CODE_PER_HOUR:
            return False, int(3600 - (now - sent[0])) + 1
        return True, 0


def note_mail(address):
    """Records that a code actually went out."""
    with _LOCK:
        _SENT.setdefault(address, []).append(time.time())


def mint_code(address):
    """Stores a fresh code for an address and returns the code itself.

    Only the digest is stored, so a copy of the identity file is not a copy of
    everybody's sign-in code. Any code still outstanding for the same address is
    dropped: two live codes would be one more than the collector can hold in
    their head.
    """
    code = "%06d" % secrets.randbelow(1000000)
    now = int(time.time())
    doc = identity()
    doc["codes"] = [entry for entry in doc["codes"]
                    if str(entry.get("email") or "") != address
                    or int(entry.get("expires") or 0) <= now]
    doc["codes"].append({"email": address, "hash": token_digest(code),
                         "expires": now + CODE_TTL, "tries": 0, "at": now})
    save_identity(doc)
    return code


def redeem_code(address, code):
    """Trades a code for the right to mint a token. Returns (ok, reason).

    The code is spent the moment it is answered correctly - one that stayed
    valid after use would be a password with extra steps - and it dies after a
    handful of wrong guesses rather than being guessed at until it opens.
    """
    now = int(time.time())
    doc = identity()
    kept = []
    found = None
    for entry in doc["codes"]:
        if str(entry.get("email") or "") != address:
            kept.append(entry)
            continue
        if int(entry.get("expires") or 0) <= now:
            continue
        if int(entry.get("tries") or 0) >= CODE_TRIES:
            continue
        found = entry
    if found is None:
        doc["codes"] = kept
        save_identity(doc)
        return False, "that code has expired - ask for a new one"
    if not hmac.compare_digest(token_digest(code), str(found.get("hash") or "")):
        found["tries"] = int(found.get("tries") or 0) + 1
        kept.append(found)
        doc["codes"] = kept
        save_identity(doc)
        if found["tries"] >= CODE_TRIES:
            return False, "too many wrong codes - ask for a new one"
        return False, "that code is not right"
    doc["codes"] = kept
    save_identity(doc)
    return True, ""


def resend_key():
    """The Resend API key, read on every send so it can be rotated."""
    if not RESEND_KEY_PATH:
        return ""
    try:
        with open(RESEND_KEY_PATH, "r", encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def send_mail(to, subject, text, attachments=None):
    """Sends one email through Resend, and says what happened.

    Returns {"ok": True, "id": ...} or {"ok": False, "error": ...}. Resend's own
    words are passed through rather than summarised, because the two failures a
    collector actually meets - a sending domain that is not verified, and a
    From address that domain does not cover - are only actionable as the
    sentence Resend wrote about them.
    """
    key = resend_key()
    if not key:
        return {"ok": False, "error": "no mail key is installed on this server"}
    payload = {"from": MAIL_FROM, "to": [to], "subject": subject, "text": text}
    if attachments:
        payload["attachments"] = attachments
    request = urllib.request.Request(
        RESEND_ENDPOINT,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Authorization": "Bearer " + key,
                 "Content-Type": "application/json",
                 "Accept": "application/json",
                 "User-Agent": MAIL_AGENT},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=MAIL_TIMEOUT) as response:
            body = json.loads(response.read().decode("utf-8") or "{}")
        return {"ok": True, "id": str(body.get("id") or "")}
    except urllib.error.HTTPError as exc:
        body = ""
        try:
            body = exc.read().decode("utf-8", "replace")[:300]
        except Exception:
            body = ""
        detail = ""
        try:
            detail = str(json.loads(body).get("message") or "")
        except Exception:
            detail = ""
        # Anything at all is passed on rather than swallowed: a refusal that is
        # not JSON is still the sentence that says what went wrong, and an empty
        # answer would send the collector looking in the wrong place.
        return {"ok": False, "status": exc.code,
                "error": detail or body.strip() or ("Resend answered %d" % exc.code)}
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


# The one seam a test needs: everything above sends by calling this name, so a
# test can replace it and then read the mail this server thinks it sent.
MAIL_SENDER = send_mail


def sign_in_mail(code):
    """The body of the sign-in code."""
    return ("Arcanum sign-in code\n"
            "\n"
            "    %s\n"
            "\n"
            "Type it into Arcanum on the new phone, under Settings, Backup, "
            "Account. It works for ten minutes, and once.\n"
            "\n"
            "If you did not ask for this, nothing has happened: the code cannot "
            "be used without being read, and no phone was added.\n" % code)


def vault_link_mail(link, days):
    """The body of the emailed vault link."""
    return ("Arcanum: your vault, in a browser\n"
            "\n"
            "%s\n"
            "\n"
            "That link opens the newest copy of your collection as a page: what "
            "you own, what it is worth at the last prices this phone recorded, "
            "and the sealed shelf. It reads the copy on the server and cannot "
            "change anything.\n"
            "\n"
            "It is a credential, and it lasts %d days. If it leaks, open "
            "Settings, Backup, Account in the app and revoke the device called "
            "\"vault-link\".\n" % (link, days))


def backup_mail(name, counts):
    """The body of an emailed archive."""
    return ("Arcanum: a copy of your collection\n"
            "\n"
            "Attached is %s - the archive the app uploaded, exactly as it "
            "uploaded it: holdings, purchase prices, binders, wants, alerts and "
            "the price snapshots this phone recorded.\n"
            "\n"
            "%s\n"
            "\n"
            "It can be restored from Settings, Backup, Restore on any phone "
            "running Arcanum.\n" % (name, counts))


def code_expiry():
    """When a code minted now stops working."""
    return int(time.time()) + CODE_TTL


def public_url():
    """Where this server is reachable from outside, for links that go in email."""
    return PUBLIC_URL.rstrip("/")


def device_slug(raw):
    """The uploader's own name for the phone, reduced to a safe filename tail.

    X-Arcanum-Device is client-supplied, so it is allowed to decide nothing but
    the text before the extension: everything outside [A-Za-z0-9._-] is
    dropped, which is also what keeps a path separator, or the quote that would
    end the Content-Disposition filename, out of a stored name.
    """
    kept = [c for c in (raw or "") if c.isascii() and (c.isalnum() or c in "._-")]
    return "".join(kept)[:32].strip(".")


def backup_name(stamp, device="", attempt=1):
    """The name one archive is stored under.

    arcanum-backup-YYYY-MM-DDTHHMMSSZ[-device].json.gz, with ".2", ".3" ...
    in front of the extension when two uploads land in the same second, so the
    second one is kept beside the first rather than replacing it.
    """
    tail = "-" + device if device else ""
    again = "" if attempt == 1 else ".%d" % attempt
    return "%s%s%s%s%s" % (BACKUP_PREFIX, stamp, tail, again, BACKUP_SUFFIX)


def archive_time(name):
    """The moment an archive records in its name, or None when it is not ours."""
    stamp = name[len(BACKUP_PREFIX):len(BACKUP_PREFIX) + BACKUP_STAMP_WIDTH]
    try:
        return datetime.strptime(stamp, BACKUP_STAMP).replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def backup_files():
    """Every stored archive, newest last.

    Names sort chronologically because the timestamp in them is fixed width,
    which is what lets retention work on names alone. Two archives uploaded
    inside the same second carry names that cannot say which came first, so
    those - and only those - are ordered by the time they were written.
    """
    try:
        names = os.listdir(BACKUPS_DIR)
    except OSError:
        return []
    names = [n for n in names
             if n.startswith(BACKUP_PREFIX) and n.endswith(BACKUP_SUFFIX)]

    def order(name):
        try:
            written = os.path.getmtime(os.path.join(BACKUPS_DIR, name))
        except OSError:
            written = 0.0
        return (name[:len(BACKUP_PREFIX) + BACKUP_STAMP_WIDTH], written, name)

    return sorted(names, key=order)


def prune_backups(keep=KEEP_BACKUPS):
    """Deletes all but the newest `keep` archives and returns how many remain.

    Run after a successful upload, so uploading grows a short history of the
    collection instead of replacing the one copy of it. An archive that cannot
    be deleted is left where it is: it is a backup, and a stubborn one is not a
    reason to report the upload that just succeeded as a failure.
    """
    names = backup_files()
    for name in names[:max(0, len(names) - keep)]:
        try:
            os.remove(os.path.join(BACKUPS_DIR, name))
        except OSError:
            pass
    return len(backup_files())


def discard(path):
    """Removes an upload that never became an archive; failure is not news."""
    try:
        os.remove(path)
    except OSError:
        pass


def device_of(name):
    """The device an archive came from, read out of its name.

    Empty when the upload carried no device label - an older build, or a client
    that did not say - which is its own honest answer: the archive exists and
    the server cannot say which phone wrote it.
    """
    body = name[len(BACKUP_PREFIX):-len(BACKUP_SUFFIX)]
    stamp_end = BACKUP_STAMP_WIDTH
    if len(body) <= stamp_end:
        return ""
    tail = body[stamp_end:]
    if tail.startswith("-"):
        tail = tail[1:]
    if tail[:1].isdigit() or tail.startswith("."):
        # Only ",2" and similar: no device label was sent.
        return ""
    parts = tail.split(".")
    return parts[0] if parts else ""


def newest_from_other(names, mine):
    """The newest archive that a device other than `mine` wrote, or None.

    This is the whole point of a second phone: this phone's own newest copy is
    inside its own database already, so comparing against it says nothing. An
    archive with no device label is a candidate - the server cannot say it came
    from this phone, and saying so would hide a copy that might be the only one
    holding something.
    """
    if not mine:
        return names[-1] if names else None
    for name in reversed(names):
        if device_of(name) != mine:
            return name
    return None


def device_summary(names):
    """One row per device that has written to this server, newest first.

    This is what makes two phones possible: the app can see that a second device
    has uploaded something newer than its own last upload, and say so, without
    any of the two devices ever talking to each other.
    """
    seen = {}
    for name in names:
        label = device_of(name) or "unnamed"
        when = archive_time(name)
        try:
            size = os.path.getsize(os.path.join(BACKUPS_DIR, name))
        except OSError:
            size = 0
        row = seen.get(label)
        if row is None:
            seen[label] = {"device": label, "backups": 1, "bytes": size,
                           "latest": when.isoformat() if when else None}
            continue
        row["backups"] += 1
        row["bytes"] = size
        if when is not None:
            row["latest"] = when.isoformat()
    rows = list(seen.values())
    rows.sort(key=lambda r: r.get("latest") or "", reverse=True)
    return rows


def backup_status():
    """What the app shows about the backups it has made.

    "bytes" is the size of the newest archive - the same figure an upload
    reports for what it just stored - and "latest" is when it was uploaded,
    read back out of its name. "devices" lists every device that has written
    here, which is how the app learns that another phone has something newer.
    """
    names = backup_files()
    if not names:
        return {"ok": True, "enabled": True, "backups": 0, "latest": None,
                "bytes": 0, "devices": []}
    newest = names[-1]
    try:
        size = os.path.getsize(os.path.join(BACKUPS_DIR, newest))
    except OSError:
        size = 0
    when = archive_time(newest)
    return {
        "ok": True,
        "enabled": True,
        "backups": len(names),
        "latest": when.isoformat() if when else None,
        "bytes": size,
        "devices": device_summary(names),
    }


def drain_body(sock, rfile, length):
    """Reads and discards a refused request's body, up to DRAIN_LIMIT bytes.

    A refusal that leaves the body unread in the socket can be answered with a
    reset instead of the 401 just written, so the client sees a broken pipe
    rather than being told why it was refused. What has already arrived is read
    off the wire, which leaves the connection usable for the next request;
    anything past DRAIN_LIMIT is left alone, which is the body the cap exists to
    avoid reading. The wait for more is short and never a wait for the whole
    declared body: a client that is being refused has usually stopped sending,
    and a client that has not must not be able to hold a thread by going quiet.
    True means every declared byte was read and the next request will line up.
    """
    if length <= 0:
        return length == 0
    was = sock.gettimeout()
    read = 0
    try:
        sock.settimeout(DRAIN_TIMEOUT)
        while read < length and read < DRAIN_LIMIT:
            try:
                chunk = rfile.read(min(length - read, 8192))
            except OSError:
                break
            if not chunk:
                return False
            read += len(chunk)
    finally:
        sock.settimeout(was)
    return read == length



# --------------------------------------------------------------- sealed product

# TCGplayer's own product lists, mirrored as plain JSON and CSV by tcgcsv.com.
# Arcanum reads them through this server rather than from the phone: one cache,
# one rate limit, one place to change when the shape moves.
TCGCSV_ROOT = "https://tcgcsv.com/tcgplayer"
SEALED_DIR = ""
SEALED_TTL = 12 * 3600
GROUPS_TTL = 7 * 24 * 3600
SEALED_TIMEOUT = 25

# The app's game ids to TCGplayer's category ids. A game missing here has no
# sealed product this server can price, and says so rather than guessing.
TCGCSV_CATEGORIES = {
    "mtg": 1,
    "yugioh": 2,
    "pokemon": 3,
    "lorcana": 71,
    "onepiece": 68,
    "swu": 79,
    "digimon": 63,
}

# Product names that are sealed product even when the list is vague about it.
SEALED_WORDS = (
    "booster box", "booster pack", "booster bundle", "display", "bundle",
    "elite trainer box", "trainer box", "tin", "commander deck", "starter deck",
    "structure deck", "theme deck", "precon", "deck box", "gift box",
    "collector box", "illumineer", "trove", "case", "pack", "box", "deck",
)


def _sealed_cache_path(kind, key):
    return os.path.join(SEALED_DIR, "%s-%s.json" % (kind, key))


def _read_cache(path, ttl):
    """A cached JSON document, when it is younger than ttl seconds."""
    try:
        age = time.time() - os.path.getmtime(path)
        if age > ttl:
            return None
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def _write_cache(path, payload):
    """Stores a document for next time; a cache that cannot be written is fine."""
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(payload, handle)
        os.replace(tmp, path)
    except OSError:
        pass


def _fetch_json(url):
    """One small JSON document, or None when the price list cannot be reached."""
    request = urllib.request.Request(
        url, headers={"User-Agent": "ArcanumSync/1.0 (+personal collection app)"}
    )
    try:
        with urllib.request.urlopen(request, timeout=SEALED_TIMEOUT) as response:
            return json.loads(response.read().decode("utf-8"))
    except Exception:
        return None


def _tcgsv_groups(category):
    """Every group (set) in a category, cached for a week."""
    path = _sealed_cache_path("groups", category)
    cached = _read_cache(path, GROUPS_TTL)
    if cached is not None:
        return cached
    payload = _fetch_json("%s/%d/groups" % (TCGCSV_ROOT, category))
    if not payload:
        return []
    groups = payload.get("results") or []
    _write_cache(path, groups)
    return groups


def _code_key(text):
    """A set code with everything that is not a letter or a digit taken out.

    TCGplayer spells a set "BT-26" where the card prints "BT26-052", and the app
    stores the second. Both sides are normalised here so the two are the same
    string, which is what the app's own catalogue does with the same value.
    """
    return re.sub(r"[^a-z0-9]+", "", str(text or "").strip().lower())


def _group_for(category, set_code):
    """The TCGplayer group id for a set code, or None."""
    wanted = _code_key(set_code)
    if not wanted:
        return None
    for group in _tcgsv_groups(category):
        if _code_key(group.get("abbreviation")) == wanted:
            return group
    # Some sets are only named, not abbreviated; a name that matches exactly is
    # still an answer, and anything looser would attach a box to the wrong set.
    for group in _tcgsv_groups(category):
        if str(group.get("name") or "").strip().lower() == str(
            set_code or ""
        ).strip().lower():
            return group
    return None


def _is_sealed(product):
    """Whether a listed product is sealed product rather than a single card.

    Decided structurally first: a single card carries a rarity and a collector
    number, and a box carries neither. The name is used only to confirm, because
    no keyword list survives contact with a game that prints "Illumineer's Trove".
    """
    fields = {}
    for entry in product.get("extendedData") or []:
        name = str(entry.get("name") or "").lower()
        fields[name] = entry.get("value")
    if fields.get("rarity") or fields.get("number") or fields.get("cardnumber"):
        return False
    name = str(product.get("name") or "").lower()
    return any(word in name for word in SEALED_WORDS)


def sealed_for(game, set_code):
    """Sealed product and its prices for one set, or None when unknown.

    Returns {"set": ..., "group": ..., "updated": ..., "products": [...]}, where
    each product carries market, low and mid. Prices come from the same dump
    TCGplayer publishes for its own site, so a box is priced on the same basis as
    the cards inside it.
    """
    category = TCGCSV_CATEGORIES.get((game or "").strip().lower())
    if category is None:
        return None
    group = _group_for(category, set_code)
    if group is None:
        return None
    group_id = group.get("groupId")
    products_path = _sealed_cache_path("products", "%d-%s" % (category, group_id))
    prices_path = _sealed_cache_path("prices", "%d-%s" % (category, group_id))
    products = _read_cache(products_path, SEALED_TTL)
    prices = _read_cache(prices_path, SEALED_TTL)
    if not products or not prices:
        fetched_products = _fetch_json(
            "%s/%d/%s/products" % (TCGCSV_ROOT, category, group_id)
        )
        fetched_prices = _fetch_json(
            "%s/%d/%s/prices" % (TCGCSV_ROOT, category, group_id)
        )
        if not fetched_products or not fetched_prices:
            return None
        products = fetched_products.get("results") or []
        prices = fetched_prices.get("results") or []
        _write_cache(products_path, products)
        _write_cache(prices_path, prices)

    by_id = {}
    for price in prices:
        by_id[str(price.get("productId"))] = price

    out = []
    for product in products:
        if not _is_sealed(product):
            continue
        price = by_id.get(str(product.get("productId"))) or {}
        out.append({
            "productId": product.get("productId"),
            "name": product.get("cleanName") or product.get("name"),
            "market": price.get("marketPrice"),
            "low": price.get("lowPrice"),
            "mid": price.get("midPrice"),
            "url": product.get("url"),
        })
    out.sort(key=lambda p: p.get("market") or 0, reverse=True)
    return {
        "set": group.get("abbreviation") or set_code,
        "setName": group.get("name"),
        "group": group_id,
        "updated": int(time.time()),
        "products": out,
    }



# ------------------------------------------------------------------ vault page

GAME_LABELS = {
    "mtg": "Magic: The Gathering",
    "pokemon": "Pokemon",
    "lorcana": "Disney Lorcana",
    "yugioh": "Yu-Gi-Oh!",
    "onepiece": "One Piece Card Game",
    "swu": "Star Wars: Unlimited",
    "digimon": "Digimon Card Game",
}


def _escape(text):
    """Minimal HTML escaping: everything in this page came from a card name."""
    return (
        str(text if text is not None else "")
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def _money(value):
    try:
        return ("$" "{:,.2f}").format(float(value))
    except (TypeError, ValueError):
        return "--"


def _latest_archive():
    """The newest stored archive, decoded, or None."""
    names = backup_files()
    if not names:
        return None
    path = os.path.join(BACKUPS_DIR, names[-1])
    try:
        with gzip.open(path, "rb") as handle:
            return json.loads(handle.read().decode("utf-8")), names[-1]
    except (OSError, ValueError):
        return None


def _index_of(archive):
    """card id to (name, set code, number), however the archive stored it."""
    raw = archive.get("cards_index") or {}
    out = {}
    if isinstance(raw, dict):
        for card_id, value in raw.items():
            if isinstance(value, list) and value:
                out[str(card_id)] = tuple(value)
    return out


def _last_prices(rows):
    """(game, card id) to the newest price the app itself recorded."""
    out = {}
    for row in rows:
        key = (str(row.get("game") or "mtg"), str(row.get("card_id") or ""))
        date = str(row.get("date") or "")
        price = row.get("price")
        if not isinstance(price, (int, float)):
            continue
        if key not in out or date > out[key][0]:
            out[key] = (date, float(price))
    return out


def _sparkline(points, width=260, height=48):
    """A tiny inline SVG of the portfolio curve. No script, no library."""
    if len(points) < 2:
        return ""
    values = [value for _, value in points]
    low, high = min(values), max(values)
    span = (high - low) or 1.0
    step = width / (len(points) - 1)
    coords = []
    for i, value in enumerate(values):
        y = height - 4 - (value - low) / span * (height - 8)
        coords.append("%.1f,%.1f" % (i * step, y))
    return (
        '<svg class="spark" viewBox="0 0 %d %d" preserveAspectRatio="none">'
        '<polyline points="%s" fill="none" stroke="#8b7bf7" stroke-width="2"/>'
        "</svg>" % (width, height, " ".join(coords))
    )


def _rows_of(tables, name):
    rows = tables.get(name) or []
    return rows if isinstance(rows, list) else []


def vault_html(archive, name):
    """The whole page: one string, no template engine, no dependencies."""
    tables = archive.get("tables") or {}
    if not isinstance(tables, dict):
        tables = {}
    entries = _rows_of(tables, "collection_entries")
    sealed = _rows_of(tables, "sealed_products")
    snapshots = _rows_of(tables, "portfolio_snapshots")
    history = _rows_of(tables, "price_history")
    index = _index_of(archive)
    prices = _last_prices(history)

    games = {}
    for key, rows in (("entries", entries), ("sealed", sealed),
                      ("snapshots", snapshots)):
        for row in rows:
            if not isinstance(row, dict):
                continue
            game = str(row.get("game") or "mtg")
            bucket = games.setdefault(
                game, {"entries": [], "sealed": [], "snapshots": []})
            bucket[key].append(row)

    parts = []
    parts.append(
        '<!doctype html><html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        "<title>Arcanum vault</title><style>"
        ":root{color-scheme:dark}"
        "body{margin:0;padding:28px 20px 60px;background:#0b0b12;color:#e8e8f0;"
        "font:15px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif}"
        ".wrap{max-width:900px;margin:0 auto}"
        "h1{font-size:26px;margin:0 0 2px}h2{font-size:18px;margin:34px 0 10px}"
        ".quiet{color:#8f8fa3;font-size:13px}"
        ".card{background:#16161f;border:1px solid #26263a;border-radius:16px;"
        "padding:16px 18px;margin:14px 0}"
        ".row{display:flex;justify-content:space-between;gap:16px;padding:4px 0;"
        "border-bottom:1px solid #1e1e2c}.row:last-child{border-bottom:none}"
        ".big{font-size:24px;font-weight:600}"
        "table{width:100%;border-collapse:collapse;font-size:14px}"
        "th,td{text-align:left;padding:6px 4px;border-bottom:1px solid #1e1e2c}"
        "th{color:#8f8fa3;font-weight:500}td.n,th.n{text-align:right}"
        ".spark{width:100%;height:48px;display:block;margin-top:8px}"
        "</style></head><body><div class=\"wrap\">"
    )
    parts.append("<h1>Arcanum vault</h1>")
    parts.append(
        '<p class="quiet">A read-only view of the newest backup this server '
        "holds: <strong>%s</strong>, uploaded by Arcanum %s on %s. Nothing here "
        "is live - it is what the phone last sent.</p>"
        % (_escape(name), _escape(archive.get("app")),
           _escape(archive.get("created")))
    )

    if not games:
        parts.append('<div class="card">This backup holds no collection.</div>')

    for game in sorted(games):
        data = games[game]
        label = GAME_LABELS.get(game, game)
        parts.append("<h2>%s</h2>" % _escape(label))

        total_cards = sum(int(row.get("quantity") or 0) for row in data["entries"])
        unique = len({str(row.get("card_id")) for row in data["entries"]})
        value = 0.0
        priced = 0
        for row in data["entries"]:
            found = prices.get((game, str(row.get("card_id") or "")))
            if not found:
                continue
            value += found[1] * int(row.get("quantity") or 0)
            priced += 1

        sealed_items = sum(int(row.get("quantity") or 0) for row in data["sealed"])
        sealed_value = 0.0
        sealed_cost = 0.0
        for row in data["sealed"]:
            quantity = int(row.get("quantity") or 0)
            if isinstance(row.get("unit_value"), (int, float)):
                sealed_value += float(row["unit_value"]) * quantity
            if isinstance(row.get("unit_cost"), (int, float)):
                sealed_cost += float(row["unit_cost"]) * quantity

        points = []
        for row in sorted(data["snapshots"], key=lambda r: str(r.get("date") or "")):
            if isinstance(row.get("total_value"), (int, float)):
                points.append((str(row.get("date")), float(row["total_value"])))

        parts.append('<div class="card">')
        parts.append(
            '<div class="row"><span>Cards held</span><span class="big">%s</span>'
            "</div>" % "{:,}".format(total_cards)
        )
        parts.append(
            '<div class="row"><span>Distinct printings</span>'
            '<span class="big">%s</span></div>' % "{:,}".format(unique)
        )
        parts.append(
            '<div class="row"><span>Value at the last prices the app recorded'
            '</span><span class="big">%s</span></div>' % _money(value)
        )
        if priced < len(data["entries"]):
            parts.append(
                '<div class="row"><span class="quiet">Priced from %s of %s '
                "holdings</span><span></span></div>"
                % ("{:,}".format(priced), "{:,}".format(len(data["entries"])))
            )
        if data["sealed"]:
            parts.append(
                '<div class="row"><span>Sealed product</span>'
                '<span class="big">%s (%s items)</span></div>'
                % (_money(sealed_value), "{:,}".format(sealed_items))
            )
            if sealed_cost:
                parts.append(
                    '<div class="row"><span class="quiet">Sealed, what it cost'
                    '</span><span class="quiet">%s</span></div>'
                    % _money(sealed_cost)
                )
            parts.append(
                '<div class="row"><span>Cards and sealed together</span>'
                '<span class="big">%s</span></div>' % _money(value + sealed_value)
            )
        if points:
            parts.append(
                '<div class="row"><span class="quiet">Portfolio snapshots, %s to '
                '%s</span><span class="quiet">%s</span></div>'
                % (_escape(points[0][0]), _escape(points[-1][0]),
                   _money(points[-1][1]))
            )
            parts.append(_sparkline(points))
        parts.append("</div>")

        rows = []
        by_set = {}
        for row in data["entries"]:
            card = index.get(str(row.get("card_id") or ""))
            code = (card[1] if card and len(card) > 1 else "") or ""
            found = prices.get((game, str(row.get("card_id") or "")))
            unit = found[1] if found else None
            quantity = int(row.get("quantity") or 0)
            bucket = by_set.setdefault(
                code or "(unknown set)", {"cards": 0, "unique": set(), "value": 0.0})
            bucket["cards"] += quantity
            bucket["unique"].add(str(row.get("card_id")))
            if unit:
                bucket["value"] += unit * quantity
            rows.append({
                "name": (card[0] if card else str(row.get("card_id"))),
                "set": (card[1] if card and len(card) > 1 else ""),
                "number": (card[2] if card and len(card) > 2 else ""),
                "quantity": quantity,
                "finish": row.get("finish"),
                "condition": row.get("condition"),
                "binder": row.get("binder"),
                "unit": unit,
                "value": (unit * quantity) if unit else 0.0,
            })

        if data["entries"]:
            parts.append('<h2>By set</h2><div class="card"><table>')
            parts.append(
                "<tr><th>Set</th><th class=n>Cards</th><th class=n>Printings</th>"
                "<th class=n>Value</th></tr>"
            )
            for code, bucket in sorted(
                by_set.items(), key=lambda kv: kv[1]["value"], reverse=True
            ):
                shown = code if code == "(unknown set)" else code.upper()
                parts.append(
                    "<tr><td>%s</td><td class=n>%s</td><td class=n>%s</td>"
                    "<td class=n>%s</td></tr>"
                    % (_escape(shown), "{:,}".format(bucket["cards"]),
                       "{:,}".format(len(bucket["unique"])),
                       _money(bucket["value"]))
                )
            parts.append("</table></div>")

        rows.sort(key=lambda r: r["value"], reverse=True)
        if rows:
            parts.append('<h2>The dearest stacks</h2><div class="card"><table>')
            parts.append(
                "<tr><th>Card</th><th>Where</th><th class=n>Qty</th>"
                "<th class=n>Each</th><th class=n>Value</th></tr>"
            )
            for row in rows[:50]:
                where = " ".join(
                    part for part in
                    (row["set"], row["number"], row["binder"] or "") if part
                )
                detail = " ".join(
                    part for part in (row["finish"], row["condition"]) if part
                )
                parts.append(
                    "<tr><td>%s<div class=\"quiet\">%s</div></td><td>%s</td>"
                    "<td class=n>%s</td><td class=n>%s</td><td class=n>%s</td></tr>"
                    % (_escape(row["name"]), _escape(detail), _escape(where),
                       "{:,}".format(row["quantity"]),
                       _money(row["unit"]) if row["unit"] else "--",
                       _money(row["value"]) if row["unit"] else "--")
                )
            parts.append("</table>")
            if len(rows) > 50:
                parts.append(
                    '<p class="quiet">and %s more holdings.</p>'
                    % "{:,}".format(len(rows) - 50)
                )
            parts.append("</div>")

        if data["sealed"]:
            parts.append('<h2>Sealed product</h2><div class="card"><table>')
            parts.append(
                "<tr><th>Product</th><th>Where</th><th class=n>Qty</th>"
                "<th class=n>Each</th><th class=n>Value</th></tr>"
            )
            for row in sorted(
                data["sealed"],
                key=lambda r: (r.get("unit_value") or 0) * int(r.get("quantity") or 0),
                reverse=True,
            ):
                quantity = int(row.get("quantity") or 0)
                unit = row.get("unit_value")
                detail = " ".join(
                    part for part in
                    (row.get("set_name"), row.get("category")) if part
                )
                parts.append(
                    "<tr><td>%s<div class=\"quiet\">%s</div></td><td>%s</td>"
                    "<td class=n>%s</td><td class=n>%s</td><td class=n>%s</td></tr>"
                    % (_escape(row.get("name")), _escape(detail),
                       _escape(row.get("location") or ""),
                       "{:,}".format(quantity),
                       _money(unit) if unit else "--",
                       _money(unit * quantity) if unit else "--")
                )
            parts.append("</table></div>")

    parts.append(
        '<p class="quiet">Arcanum holds this collection on one phone and sends '
        "it nowhere except here. This page reads the copy on this server, needs "
        "no account, and cannot change anything.</p>"
    )
    parts.append("</div></body></html>")
    return "".join(parts)


class Handler(BaseHTTPRequestHandler):
    server_version = "ArcanumSync/1.0"
    protocol_version = "HTTP/1.1"

    def _send(self, code, payload, cache="public, max-age=3600", close=False):
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", cache)
        if close:
            # A body that was not read leaves the socket in the middle of a
            # request, so this connection cannot carry another one.
            self.close_connection = True
            self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = unquote(urlparse(self.path).path)
        try:
            if path in ("/v1/health", "/health", "/"):
                self._send(200, stats())
                return
            if path.startswith("/v1/history/"):
                sid = path[len("/v1/history/"):]
                if sid.endswith(".json"):
                    sid = sid[:-5]
                if not sid or "/" in sid:
                    self._send(400, {"error": "bad id"})
                    return
                data = history_for(sid)
                if data is None:
                    self._send(404, {"error": "no history", "id": sid})
                    return
                self._send(200, data)
                return
            if path in ("/vault", "/v1/vault"):
                # Read from the query string as well as the header: a browser
                # navigating to a URL cannot send a header, and the token is the
                # only lock this server has.
                if not self._vault_gate():
                    return
                found = _latest_archive()
                if found is None:
                    self._send(404, {"error": "no backup"}, cache="no-store")
                    return
                archive, name = found
                body = vault_html(archive, name).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)
                return
            if path == "/v1/sealed":
                query = parse_qs(urlparse(self.path).query)
                game = (query.get("game") or ["mtg"])[0]
                set_code = (query.get("set") or [""])[0]
                if not set_code:
                    self._send(400, {"error": "no set", "game": game})
                    return
                data = sealed_for(game, set_code)
                if data is None:
                    self._send(404, {"error": "no sealed product",
                                     "game": game, "set": set_code})
                    return
                self._send(200, data)
                return
            if path == "/v1/backup/status":
                if not self._backup_gate():
                    return
                self._send(200, backup_status(), cache="no-store")
                return
            if path == "/v1/auth/devices":
                if not self._backup_gate():
                    return
                supplied = self.headers.get("X-Arcanum-Token") or ""
                self._send(200, {"ok": True,
                                 "owner": identity().get("owner", ""),
                                 "invited": invited_addresses(identity()),
                                 "devices": self._devices_payload(supplied),
                                 "email": bool(resend_key())},
                           cache="no-store")
                return
            if path == "/v1/backup/latest":
                if not self._backup_gate():
                    return
                query = parse_qs(urlparse(self.path).query)
                mine = device_slug((query.get("not_device") or [""])[0])
                names = backup_files()
                if not names:
                    self._send(404, {"error": "no backup"}, cache="no-store")
                    return
                chosen = newest_from_other(names, mine)
                if chosen is None:
                    # Copies exist, but every one of them is this phone's own.
                    # Its own backup is already in its database, so there is
                    # nothing here to merge, and saying so is the honest answer.
                    self._send(404, {"error": "no other device",
                                     "device": mine,
                                     "backups": len(names)}, cache="no-store")
                    return
                if not self._send_archive(chosen):
                    self._send(404, {"error": "no backup"}, cache="no-store")
                return
            self._send(404, {"error": "not found", "path": path})
        except BrokenPipeError:
            pass
        except Exception as exc:
            try:
                self._send(500, {"error": str(exc)})
            except Exception:
                pass

    def _send_archive(self, name):
        """Streams one stored archive back exactly as it was uploaded."""
        path = os.path.join(BACKUPS_DIR, name)
        try:
            size = os.path.getsize(path)
            handle = open(path, "rb")
        except OSError:
            return False
        self.send_response(200)
        self.send_header("Content-Type", "application/gzip")
        self.send_header("Content-Length", str(size))
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % name)
        # Who wrote it, and when, without making the app open the archive to
        # find out. An older build sent no label, and an empty header is that
        # answer rather than a guess.
        self.send_header("X-Arcanum-Device", device_of(name))
        when = archive_time(name)
        self.send_header("X-Arcanum-Written",
                         when.isoformat() if when else "")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        with handle:
            shutil.copyfileobj(handle, self.wfile, 1 << 20)
        return True

    def _refuse(self, code, payload, length=0):
        """Answers a request whose body this server is not going to store."""
        self._send(code, payload, cache="no-store",
                   close=not drain_body(self.connection, self.rfile, length))

    def _vault_gate(self):
        """Refuses the vault page unless the request carries a credential.

        The page shows the whole collection - what is owned, what it cost, where
        it is kept - so it is behind the same credentials as the backups
        themselves, and a device token opens it exactly as the root token does:
        the emailed link mints one thing, and there is one way in. A credential
        may arrive as a query parameter because that is the only way a browser
        can carry one into a page; the trade is that it lands in the browser's
        history, which is why the page itself never prints it.
        """
        if not self._credentials_exist():
            self._send(503, {"ok": False, "enabled": False,
                             "error": "no token installed"}, cache="no-store")
            return False
        query = parse_qs(urlparse(self.path).query)
        supplied = (
            self.headers.get("X-Arcanum-Token")
            or (query.get("token") or [""])[0]
        )
        if not authorized(supplied):
            self._send(401, {"ok": False, "error": "unauthorized"},
                       cache="no-store")
            return False
        touch_device(supplied)
        return True

    def _credentials_exist(self):
        """Whether anything can open this server at all.

        The root token, typed into the app by hand, or a device token minted
        from an emailed code. With neither, there is no write path to protect
        and the honest answer is 503 rather than 401.
        """
        return installed_token() is not None or bool(devices_of(identity()))

    def _backup_gate(self, length=0):
        """Refuses a request unless it carries a credential this server accepts.

        The two refusals say the least they can: with no credential anywhere
        there is no write path to protect and the answer is 503, and a request
        that does not carry one is told only that - never whether a token file
        is there, what it holds, or how close a guess came.
        """
        if not self._credentials_exist():
            self._refuse(503, {"ok": False, "enabled": False,
                               "error": "backups disabled"}, length)
            return False
        supplied = self.headers.get("X-Arcanum-Token") or ""
        if not authorized(supplied):
            self._refuse(401, {"ok": False, "error": "unauthorized"}, length)
            return False
        touch_device(supplied)
        return True

    def _holds_credential(self):
        """Whether this request already carries a credential, without refusing it.

        Used to decide how much an answer may say. A stranger asking whether an
        address is invited learns nothing; the collector, who already holds a
        token, is told exactly what happened to their own request.
        """
        return authorized(self.headers.get("X-Arcanum-Token") or "")

    def _json_body(self, length):
        """Reads a small JSON object body, or None when it is not one."""
        if length <= 0 or length > MAX_JSON_BYTES:
            return None
        try:
            raw = self.rfile.read(length)
        except OSError:
            return None
        try:
            value = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return None
        return value if isinstance(value, dict) else None

    def _address_of(self, body):
        """The address a request is about: the one it names, or the owner's."""
        named = str(body.get("to") or body.get("email") or "").strip().lower()
        if named:
            return named
        known = invited_addresses(identity())
        return known[0] if known else ""

    def _devices_payload(self, supplied=""):
        """The devices holding a token, as the app draws them."""
        digest = token_digest(supplied) if supplied else ""
        out = []
        for entry in devices_of(identity()):
            stored = str(entry.get("hash") or "")
            out.append({
                "label": str(entry.get("label") or "phone"),
                "created": int(entry.get("created") or 0),
                "last_seen": int(entry.get("last_seen") or 0),
                "expires": int(entry.get("expires") or 0),
                "current": bool(digest) and hmac.compare_digest(digest, stored),
            })
        return out

    def _auth_start(self, length):
        """Mails a sign-in code, and tells a stranger nothing they can use.

        An address that is not invited gets the same 200 as one that is, and so
        does an address that asked a moment ago. Only a caller who already holds
        a credential - the collector, on the phone they are signed in on - is
        told which of those happened.
        """
        if resend_key() == "":
            self._refuse(503, {"ok": False,
                               "error": "email is not set up on this server"},
                         length)
            return
        body = self._json_body(length)
        if body is None:
            self._refuse(400, {"ok": False, "error": "expected a JSON body"},
                         length)
            return
        address = str(body.get("email") or "").strip().lower()
        known = self._holds_credential()
        if "@" not in address or "." not in address.split("@")[-1]:
            self._refuse(400, {"ok": False,
                               "error": "that is not an email address"}, length)
            return
        doc = identity()
        if not is_invited(doc, address):
            payload = {"ok": True, "sent": False}
            if known:
                payload["error"] = "that address is not invited to this server"
                payload["invited"] = invited_addresses(doc)
            self._send(200, payload, cache="no-store")
            return
        allowed, wait = mail_allowed(address)
        if not allowed:
            payload = {"ok": True, "sent": False, "retry_in": wait}
            if known:
                payload["error"] = "a code was sent a moment ago"
            self._send(200, payload, cache="no-store")
            return
        code = mint_code(address)
        result = MAIL_SENDER(address, "Arcanum: your sign-in code",
                             sign_in_mail(code))
        if not result.get("ok"):
            payload = {"ok": True, "sent": False,
                       "error": str(result.get("error") or "the mail could not be sent")}
            self._send(200, payload, cache="no-store")
            return
        note_mail(address)
        payload = {"ok": True, "sent": True, "expires": code_expiry(),
                   "to": address}
        if known:
            payload["id"] = result.get("id", "")
        self._send(200, payload, cache="no-store")

    def _auth_verify(self, length):
        """Trades a code for this device's own token, returned exactly once."""
        body = self._json_body(length)
        if body is None:
            self._refuse(400, {"ok": False, "error": "expected a JSON body"},
                         length)
            return
        address = str(body.get("email") or "").strip().lower()
        code = str(body.get("code") or "").strip().replace(" ", "")
        label = device_slug(body.get("device") or "") or "phone"
        if not code:
            self._refuse(400, {"ok": False, "error": "no code was sent"}, length)
            return
        ok, reason = redeem_code(address, code)
        if not ok:
            self._refuse(401, {"ok": False, "error": reason}, length)
            return
        token = add_device(label)
        self._send(200, {"ok": True, "token": token, "device": label,
                         "devices": self._devices_payload(token)},
                   cache="no-store")

    def _auth_revoke(self, length):
        """Takes one device's token away."""
        if not self._backup_gate(length):
            return
        body = self._json_body(length) or {}
        label = device_slug(body.get("device") or "")
        if not label:
            self._refuse(400, {"ok": False, "error": "no device named"}, length)
            return
        supplied = self.headers.get("X-Arcanum-Token") or ""
        removed = drop_device(label)
        self._send(200, {"ok": True, "removed": removed,
                         "devices": self._devices_payload(supplied)},
                   cache="no-store")

    def _email_route(self, path, length):
        """Emails the vault link, or the newest archive, to an invited address.

        Both are credentials or collections leaving the server by mail, so both
        demand a credential to ask for. The vault link mints a device of its own
        called "vault-link" with a week to live, which is what makes a link that
        leaks a button to press rather than a token to rotate by hand.
        """
        if not self._backup_gate(length):
            return
        if resend_key() == "":
            self._refuse(503, {"ok": False,
                               "error": "email is not set up on this server"},
                         length)
            return
        body = self._json_body(length) or {}
        address = self._address_of(body)
        doc = identity()
        if not address:
            self._refuse(400, {"ok": False, "error": "no address to send to"},
                         length)
            return
        if not is_invited(doc, address):
            # The caller holds a credential, so this is the collector asking
            # about their own server and the answer may name what is invited.
            self._refuse(400, {"ok": False,
                               "error": "that address is not invited",
                               "invited": invited_addresses(doc)}, length)
            return

        if path == "/v1/email/vault":
            base = public_url()
            if not base:
                self._refuse(503, {"ok": False,
                                   "error": "this server has no public URL "
                                            "configured, so it cannot build a link"},
                             length)
                return
            token = add_device("vault-link", ttl=LINK_TTL)
            result = MAIL_SENDER(address, "Arcanum: your vault link",
                                 vault_link_mail("%s/vault?token=%s" % (base, token),
                                                 LINK_TTL // 86400))
            self._send_mail_result(result, address, length)
            return

        found = _latest_archive()
        if found is None:
            self._refuse(404, {"ok": False, "error": "no backup to send"}, length)
            return
        _archive, name = found
        try:
            size = os.path.getsize(os.path.join(BACKUPS_DIR, name))
        except OSError:
            size = 0
        if size > MAX_ATTACH_BYTES:
            self._refuse(413, {"ok": False, "error": "that archive is too large "
                                                     "to attach", "bytes": size},
                         length)
            return
        try:
            with open(os.path.join(BACKUPS_DIR, name), "rb") as handle:
                encoded = base64.b64encode(handle.read()).decode("ascii")
        except OSError as exc:
            self._refuse(500, {"ok": False, "error": str(exc)}, length)
            return
        counts = ""
        try:
            found_archive, _n = found
            counts = "It holds %s rows across %d sections." % (
                "{:,}".format(sum(len(rows) for rows in found_archive.get("tables", {}).values())),
                len(found_archive.get("tables", {})))
        except Exception:
            counts = ""
        result = MAIL_SENDER(address, "Arcanum: your backup",
                             backup_mail(name, counts),
                             attachments=[{"filename": name, "content": encoded}])
        self._send_mail_result(result, address, length)

    def _send_mail_result(self, result, address, length):
        """Answers what the mailer said, in the mailer's own words."""
        if not result.get("ok"):
            self._refuse(502, {"ok": False, "to": address,
                               "error": str(result.get("error") or "not sent")},
                         length)
            return
        self._send(200, {"ok": True, "sent": True, "to": address,
                         "id": result.get("id", "")}, cache="no-store")

    def do_POST(self):
        path = unquote(urlparse(self.path).path)
        try:
            try:
                length = int(self.headers.get("Content-Length") or "")
            except ValueError:
                length = -1
            if path == "/v1/auth/start":
                self._auth_start(length)
                return
            if path == "/v1/auth/verify":
                self._auth_verify(length)
                return
            if path == "/v1/auth/revoke":
                self._auth_revoke(length)
                return
            if path in ("/v1/email/vault", "/v1/email/backup"):
                self._email_route(path, length)
                return
            if path != "/v1/backup":
                self._refuse(404, {"error": "not found", "path": path}, length)
                return
            if not self._backup_gate(length):
                return
            if length < 0:
                self._refuse(411, {"ok": False, "error": "length required"}, length)
                return
            if length == 0:
                self._refuse(400, {"ok": False, "error": "empty body"}, length)
                return
            if length > MAX_BACKUP_BYTES:
                # Refused on the declared length, before a byte of the body is
                # read: an archive that size is not a collection, and reading
                # it to find out is the denial of service the cap exists to
                # stop.
                self._refuse(413, {"ok": False, "error": "too large",
                                   "limit": MAX_BACKUP_BYTES}, length)
                return
            self._store_backup(length)
        except BrokenPipeError:
            pass
        except Exception as exc:
            try:
                self._send(500, {"error": str(exc)}, cache="no-store")
            except Exception:
                pass

    def _store_backup(self, length):
        """Stores one uploaded archive, or leaves what is stored untouched.

        The body is streamed to a temporary file beside the archives and moved
        into place only once every declared byte has arrived and been flushed,
        so an upload that stops halfway - the phone losing signal, the socket
        dying - can leave neither a half-written archive where the app expects
        a whole one, nor a mark on the backup that was already there.
        """
        try:
            os.makedirs(BACKUPS_DIR, exist_ok=True)
        except OSError as exc:
            self._refuse(500, {"ok": False, "error": str(exc)}, length)
            return
        stamp = datetime.now(timezone.utc).strftime(BACKUP_STAMP)
        device = device_slug(self.headers.get("X-Arcanum-Device"))
        name, tmp, handle = "", "", None
        for attempt in range(1, 1000):
            candidate = backup_name(stamp, device, attempt)
            if os.path.exists(os.path.join(BACKUPS_DIR, candidate)):
                continue
            tmp = os.path.join(BACKUPS_DIR, INCOMING_PREFIX + candidate)
            try:
                # O_EXCL, so two uploads landing in the same second cannot both
                # decide on one name and then lose an archive to each other.
                fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY
                             | getattr(os, "O_BINARY", 0))
            except FileExistsError:
                continue
            except OSError as exc:
                self._refuse(500, {"ok": False, "error": str(exc)}, length)
                return
            name, handle = candidate, os.fdopen(fd, "wb")
            break
        if handle is None:
            self._refuse(500, {"ok": False, "error": "no name for the archive"}, length)
            return
        written = 0
        try:
            with handle:
                while written < length:
                    chunk = self.rfile.read(min(length - written, 1 << 20))
                    if not chunk:
                        break
                    handle.write(chunk)
                    written += len(chunk)
                # Flushed onto the disk before the name is moved into place:
                # this file is a backup, and a rename that outruns the data it
                # names would report a backup that is not there.
                handle.flush()
                os.fsync(handle.fileno())
        except OSError as exc:
            discard(tmp)
            self._refuse(500, {"ok": False, "error": str(exc)}, length - written)
            return
        if written != length:
            discard(tmp)
            self._refuse(400, {"ok": False, "error": "incomplete body",
                               "got": written}, length - written)
            return
        try:
            os.replace(tmp, os.path.join(BACKUPS_DIR, name))
        except OSError as exc:
            discard(tmp)
            self._refuse(500, {"ok": False, "error": str(exc)}, length)
            return
        self._send(200, {"ok": True, "saved": name, "bytes": written,
                         "kept": prune_backups()}, cache="no-store")

    def log_message(self, fmt, *args):
        sys.stderr.write("  " + (fmt % args) + "\n")


def main():
    global DB_PATH, POKEMON_DB_PATH, LORCANA_DB_PATH, YUGIOH_DB_PATH
    global BACKUP_TOKEN_PATH, BACKUPS_DIR, SEALED_DIR, _STATS
    global IDENTITY_PATH, RESEND_KEY_PATH, MAIL_FROM, PUBLIC_URL
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    default_db = os.path.join(here, "prices", "prices.db")
    ap.add_argument("--db", default=default_db)
    ap.add_argument(
        "--pokemon-db",
        default=os.path.join(here, "prices", "pokemon_prices.db"),
        help="optional Pokemon price database written by poll_pokemon_prices.py",
    )
    ap.add_argument(
        "--lorcana-db",
        default=os.path.join(here, "data", "lorcana_prices.db"),
        help="optional Lorcana price database written by poll_lorcana_prices.py",
    )
    ap.add_argument(
        "--yugioh-db",
        default=os.path.join(here, "data", "yugioh_prices.db"),
        help="optional Yu-Gi-Oh! price database written by poll_yugioh_prices.py",
    )
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument(
        "--backups-dir",
        default=os.path.join(os.path.expanduser("~"), "arcanum", "backups"),
        help="where the archives uploaded by the app are kept",
    )
    ap.add_argument(
        "--backup-token",
        default=os.path.join(os.path.expanduser("~"), "arcanum", "backup.token"),
        help="file holding the token a backup request must send; while it is "
             "missing or empty the backup routes answer 503 and store nothing",
    )
    ap.add_argument(
        "--sealed-dir",
        default=os.path.join(os.path.expanduser("~"), "arcanum", "data", "sealed"),
        help="where set product lists and their prices are cached",
    )
    ap.add_argument(
        "--identity",
        default=os.path.join(os.path.expanduser("~"), "arcanum", "identity.json"),
        help="who may use this server: the owner address, invited addresses, "
             "the device tokens and the codes outstanding",
    )
    ap.add_argument(
        "--resend-key",
        default=os.path.join(os.path.expanduser("~"), "arcanum", "resend.token"),
        help="file holding the Resend API key that sign-in codes are sent with; "
             "while it is missing the sign-in routes answer 503",
    )
    ap.add_argument(
        "--mail-from",
        default=os.environ.get("ARCANUM_MAIL_FROM", "Arcanum <onboarding@resend.dev>"),
        help="the From line of every email this server sends; Resend only "
             "accepts a domain that is verified in its dashboard",
    )
    ap.add_argument(
        "--public-url",
        default=os.environ.get("ARCANUM_PUBLIC_URL", ""),
        help="where this server is reachable from outside, used to build the "
             "vault link that is emailed; without it that route answers 503",
    )
    ap.add_argument(
        "--set-owner",
        default="",
        help="store this address as the owner of the server and exit, which is "
             "the one address a sign-in code can be sent to at all",
    )
    ap.add_argument(
        "--invite",
        default="",
        help="add an address to the invited list and exit",
    )
    ap.add_argument(
        "--devices",
        action="store_true",
        help="list the devices holding a token and exit",
    )
    args = ap.parse_args()

    # Identity does not need a price database, so the commands that set it up
    # run before the database is looked for: a server is given an owner once,
    # long before it is asked to serve anything.
    IDENTITY_PATH = args.identity
    RESEND_KEY_PATH = args.resend_key

    # The administrative commands. They exist because the first thing a server
    # needs is an owner, and asking somebody to hand-write JSON to get one is
    # how a feature ends up unused.
    if args.set_owner or args.invite:
        doc = identity()
        if args.set_owner:
            doc["owner"] = args.set_owner.strip().lower()
        if args.invite and args.invite.strip().lower() not in doc["invited"]:
            doc["invited"].append(args.invite.strip().lower())
        if not save_identity(doc):
            print("could not write " + IDENTITY_PATH, file=sys.stderr)
            return 1
        print("owner:   " + (doc["owner"] or "(none)"))
        print("invited: " + (", ".join(doc["invited"]) or "(none)"))
        return 0
    if args.devices:
        doc = identity()
        print("owner:   " + (doc["owner"] or "(none)"))
        print("invited: " + (", ".join(doc["invited"]) or "(none)"))
        for entry in devices_of(doc):
            print("  {:<16} added {}  last seen {}".format(
                str(entry.get("label") or "phone"),
                datetime.fromtimestamp(int(entry.get("created") or 0),
                                       timezone.utc).isoformat(),
                datetime.fromtimestamp(int(entry.get("last_seen") or 0),
                                       timezone.utc).isoformat()))
        return 0

    if not os.path.exists(args.db):
        print("database not found: " + args.db, file=sys.stderr)
        print("run slice_prices.py first", file=sys.stderr)
        return 1
    DB_PATH = args.db
    # A game database that is not there yet is simply not served: each poller
    # creates its own on its first run.
    POKEMON_DB_PATH = args.pokemon_db if os.path.exists(args.pokemon_db) else ""
    LORCANA_DB_PATH = args.lorcana_db if os.path.exists(args.lorcana_db) else ""
    YUGIOH_DB_PATH = args.yugioh_db if os.path.exists(args.yugioh_db) else ""
    BACKUPS_DIR = args.backups_dir
    BACKUP_TOKEN_PATH = args.backup_token
    SEALED_DIR = args.sealed_dir
    IDENTITY_PATH = args.identity
    RESEND_KEY_PATH = args.resend_key
    MAIL_FROM = args.mail_from
    PUBLIC_URL = args.public_url
    _STATS = None

    s = stats()
    print("Arcanum Sync serving {:,} printings / {:,} points ({} days) on http://{}:{}".format(
        s["printings"], s["points"], s["days"], args.host, args.port))
    pollers = (("pokemon", "poll_pokemon_prices.py"),
               ("lorcana", "poll_lorcana_prices.py"),
               ("yugioh", "poll_yugioh_prices.py"))
    for game, poller in pollers:
        counts = s["games"].get(game, _empty())
        if counts["points"]:
            print("  + {}: {:,} printings / {:,} points ({} days)".format(
                game, counts["printings"], counts["points"], counts["days"]))
        else:
            print("  (no {} database yet - run {} to build one)".format(game, poller))
    print("  sealed product: cached in {} ({} categories)".format(
        args.sealed_dir, len(TCGCSV_CATEGORIES)))
    if installed_token() is None and not devices_of(identity()):
        print("  backups disabled: no token in {} (backup routes answer 503)".format(
            args.backup_token))
    else:
        print("  backups enabled: keeping the newest {} archives in {}".format(
            KEEP_BACKUPS, args.backups_dir))
    doc = identity()
    print("  identity: {} (owner {}, {} invited, {} devices)".format(
        args.identity, doc["owner"] or "unset", len(doc["invited"]),
        len(doc["devices"])))
    if not resend_key():
        print("  email disabled: no Resend key in {} (sign-in answers 503)".format(
            args.resend_key))
    else:
        print("  email enabled: sending as {} ({} vault links)".format(
            args.mail_from, "with a public URL" if public_url() else "no public URL set"))
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
