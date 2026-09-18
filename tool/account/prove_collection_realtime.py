#!/usr/bin/env python3
"""Prove that the account announces a change, and that nothing else moved.

The claim this file tests is not that a migration ran. It is that the account
can speak first, and that being able to speak first cost the collection table
nothing: no column, no constraint, no policy, no grant and no index changed,
because enabling Realtime is membership of a publication and not a table
change.

Three kinds of check, and none implies another:

  * against the live schema, as the owner, reading pg_catalog. This is where
    "one publication change and nothing else" is a measurement rather than a
    promise: the constraints, the policy, the grants and the indexes are
    compared with the fingerprints taken from this project by the previous
    account migration, and the publication's own shape is read back - whether
    it is a table list at all, and which tables are in it. This is also the only
    place the publication membership itself is read rather than inferred.

  * against the live Realtime service, as an unauthenticated client. Two things
    are learned here and one of them is a warning about the other. A
    postgres_changes subscription is accepted optimistically at the join - the
    channel replies "ok" and echoes the binding back, for any table, whether it
    is streamed or not - and the real verdict arrives a moment later on a
    system event. That verdict is a refusal for the publishable key with no
    session, on this table and on every other, so it says nothing about the
    publication. Both facts are asserted rather than assumed, because a proof
    that read the join as a proof of streaming would report the migration as
    working on a database where nothing had been changed at all.

  * against the live service with a real session, when one can be made: a probe
    account is created confirmed, signed in, subscribed as that account, and
    then written to through PostgREST, and the events are waited for. This is
    the only live proof of the whole chain - publication, row level security,
    the account filter, and the shape of what arrives - and it is the section
    that a server holding SUPABASE_SECRET_KEY should be run for.

Credentials come from the environment, or from a KEY=VALUE file named with
--env-file. They are never printed, and nothing in this file holds a secret.

  SUPABASE_URL               required
  SUPABASE_PUBLISHABLE_KEY   required - the public key, the client's key
  SUPABASE_SECRET_KEY        optional - enables the delivery check
  SUPABASE_DB_URL_POOLED     optional - enables the SQL checks

Usage:
  set -a; . /home/zixen/arcanum/supabase.env; set +a
  python3 tool/account/prove_collection_realtime.py

  # On the server, where the credentials are, insist on the SQL half:
  python3 tool/account/prove_collection_realtime.py --require-sql

Exit status is 0 only if nothing failed.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import shutil
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit

# The schema fingerprints, read from the live project before the tombstone
# migration and left unchanged by it. Asserting them again here is what makes
# "this migration only touched the publication" a check: a step that also
# rewrote a policy or dropped an index would pass anything that only looked for
# the publication.
#
# The row count and the row's own fingerprint are deliberately NOT asserted.
# Those were 1 and one md5 on the day they were taken, and the collector whose
# holding they describe has been using the app since - a check that failed
# because somebody added a card would be a check nobody trusts.
SCHEMA = {
    "cons_md5": "284bcd1a43d57a11c87fbca9ad33bdc0",
    "pol_md5": "f46c5cf8da5eeead8007200ee17bc04b",
    "idx_md5": "93cc4a3c404f1628eb1c84805de50006",
    "grant_md5": "a77de29eee559c34252bb8df508e30ad",
}

# The client's filter, spelled the way AccountChanges spells it: the row's
# owner, equal to the signed-in account.
FILTER = "user_id=eq.{user_id}"

PUBLICATION = "supabase_realtime"
TABLE = "collection_entries"

# A table that does not exist, for the control below. Deliberately not another
# real table: a real one might be streamed or not, and the point of the control
# is what the server says about a request that could never be satisfied.
NOWHERE = "zz_probe_no_such_table"

RESULTS = []


def record(status, name, detail):
    RESULTS.append((status, name, detail))
    print(f"{status:<4}  {name}")
    for line in detail.splitlines():
        print(f"        {line}")


def ok(name, detail):
    record("PASS", name, detail)


def bad(name, detail):
    record("FAIL", name, detail)


def skip(name, detail):
    record("SKIP", name, detail)


def psql(db_url, sql):
    proc = subprocess.run(
        ["psql", db_url, "-X", "-q", "-A", "-t", "-F", "|",
         "-v", "ON_ERROR_STOP=1", "-f", "-"],
        input=sql, capture_output=True, text=True, timeout=120,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"psql: {proc.stderr.strip()[:600]}")
    return [line.split("|") for line in proc.stdout.splitlines() if line != ""]


def values(rows):
    out = {}
    for row in rows:
        for field in row:
            name, sep, value = field.partition("=")
            if sep:
                out[name] = value
    return out


# ---------------------------------------------------------------------------
# The socket, by hand
# ---------------------------------------------------------------------------


class Websocket:
    """Enough of RFC 6455 to join a Realtime channel and read the verdict.

    Hand-rolled over the standard library because this file has to run where
    the credentials are - a machine somebody else set up, weeks from now - and
    a proof that needs a package installed first is a proof that gets run later
    or not at all. What is needed is small: a masked text frame out, unmasked
    frames in, and a pong for a ping.
    """

    def __init__(self, url, headers, timeout):
        parts = urlsplit(url)
        host = parts.hostname
        port = parts.port or (443 if parts.scheme == "wss" else 80)
        sock = socket.create_connection((host, port), timeout=timeout)
        if parts.scheme == "wss":
            sock = ssl.create_default_context().wrap_socket(
                sock, server_hostname=host)
        self.sock = sock
        self.buffer = b""

        path = parts.path or "/"
        if parts.query:
            path += "?" + parts.query
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            f"GET {path} HTTP/1.1\r\nHost: {host}\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
        )
        for name, value in headers.items():
            request += f"{name}: {value}\r\n"
        sock.sendall((request + "\r\n").encode())

        head = self._until(b"\r\n\r\n")
        status = head.split(b"\r\n")[0].decode(errors="replace")
        if "101" not in status:
            raise RuntimeError(f"the socket was refused: {status}")

    def _take(self, count):
        while len(self.buffer) < count:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("the socket closed")
            self.buffer += chunk
        taken, self.buffer = self.buffer[:count], self.buffer[count:]
        return taken

    def _until(self, marker):
        while marker not in self.buffer:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("the socket closed during the handshake")
            self.buffer += chunk
        head, _, self.buffer = self.buffer.partition(marker)
        return head

    def send(self, text, opcode=0x1):
        data = text.encode() if isinstance(text, str) else text
        mask = os.urandom(4)
        frame = bytearray([0x80 | opcode])
        length = len(data)
        if length < 126:
            frame.append(0x80 | length)
        elif length < 65536:
            frame.append(0x80 | 126)
            frame += length.to_bytes(2, "big")
        else:
            frame.append(0x80 | 127)
            frame += length.to_bytes(8, "big")
        frame += mask
        frame += bytes(byte ^ mask[i % 4] for i, byte in enumerate(data))
        self.sock.sendall(bytes(frame))

    def frame(self, deadline):
        self.sock.settimeout(max(0.5, deadline - time.time()))
        head = self._take(2)
        opcode = head[0] & 0x0F
        masked = bool(head[1] & 0x80)
        length = head[1] & 0x7F
        if length == 126:
            length = int.from_bytes(self._take(2), "big")
        elif length == 127:
            length = int.from_bytes(self._take(8), "big")
        mask = self._take(4) if masked else b""
        data = self._take(length) if length else b""
        if masked:
            data = bytes(byte ^ mask[i % 4] for i, byte in enumerate(data))
        return opcode, data

    def next_message(self, timeout):
        """The next text message, as a dict, or None when the wait runs out."""
        deadline = time.time() + timeout
        while True:
            try:
                opcode, data = self.frame(deadline)
            except TimeoutError:
                return None
            if opcode == 0x1:
                return json.loads(data.decode())
            if opcode == 0x8:
                raise RuntimeError("the server closed the subscription")
            if opcode == 0x9:
                self.send(data, opcode=0xA)
            # Continuations and pongs are ignored: every message this file reads
            # or writes is one small frame, and a reassembly buffer would be
            # code nothing here exercises.

    def close(self):
        try:
            self.send(b"", opcode=0x8)
        except OSError:
            pass
        self.sock.close()


def realtime_url(base):
    parts = urlsplit(base)
    scheme = "wss" if parts.scheme == "https" else "ws"
    return f"{scheme}://{parts.netloc}/realtime/v1/websocket?vsn=1.0.0"


def binding(table, user_id="00000000-0000-0000-0000-000000000000"):
    return {
        "event": "*",
        "schema": "public",
        "table": table,
        "filter": FILTER.format(user_id=user_id),
    }


def join_channel(url, publishable, channel, bindings, token=None, timeout=15.0):
    """Join one channel the way the Dart client joins it, and read both answers.

    There are two, and they are not the same answer. The reply to the join says
    the channel exists and echoes the binding back - the Dart client checks that
    echo against what it asked for and refuses to trust the channel if they
    disagree. Whether this client may be told about this table arrives
    afterwards, on a system event, and that second answer is the one that
    decides whether anything will ever arrive.

    Returns (reply_payload, system_payload_or_None).
    """
    conn = Websocket(
        f"{realtime_url(url)}&apikey={publishable}",
        {"apikey": publishable},
        timeout,
    )
    payload = {
        "config": {
            "broadcast": {"ack": False, "self": False},
            "presence": {"key": ""},
            "postgres_changes": bindings,
            "private": False,
        },
    }
    if token:
        payload["access_token"] = token
    conn.send(json.dumps({
        "topic": f"realtime:{channel}",
        "event": "phx_join",
        "payload": payload,
        "ref": "1",
    }))

    reply = None
    verdict = None
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            message = conn.next_message(max(1.0, deadline - time.time()))
        except (TimeoutError, RuntimeError):
            break
        if message is None:
            break
        if message.get("ref") == "1" and message.get("event") == "phx_reply":
            reply = message.get("payload", {})
        elif message.get("event") == "system" and \
                message.get("topic") == f"realtime:{channel}":
            verdict = message.get("payload", {})
            break
    return conn, reply, verdict


def wait_for_change(conn, kind, card_id, timeout=20.0):
    """The next postgres_changes message of one kind for one card, or None.

    The wire shape is the one the Dart client unpacks:
    payload.data carries type, table, record, old_record and the column list.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            message = conn.next_message(max(1.0, deadline - time.time()))
        except (TimeoutError, RuntimeError):
            return None
        if message is None:
            return None
        if message.get("event") != "postgres_changes":
            continue
        data = (message.get("payload") or {}).get("data") or {}
        if data.get("type") != kind:
            continue
        record = data.get("record") or {}
        if record.get("card_id") == card_id:
            return data
    return None


# ---------------------------------------------------------------------------
# The SQL half
# ---------------------------------------------------------------------------


def check_publication(db_url):
    rows = psql(db_url, f"""
      select 'puballtables=' || puballtables::text || ' pubinsert=' || pubinsert::text
             || ' pubupdate=' || pubupdate::text || ' pubdelete=' || pubdelete::text
             || ' pubtruncate=' || pubtruncate::text
        from pg_publication where pubname = '{PUBLICATION}';
      select 'member=' || count(*)::text
        from pg_publication_tables
       where pubname = '{PUBLICATION}' and schemaname = 'public'
         and tablename = '{TABLE}';
      select 'streamed=' || coalesce(string_agg(schemaname || '.' || tablename, ',' order by tablename), 'none')
        from pg_publication_tables where pubname = '{PUBLICATION}';
      select 'cons_md5=' || md5(string_agg(conname || ':' || pg_get_constraintdef(o.oid), ',' order by conname))
        from pg_constraint o where conrelid = 'public.{TABLE}'::regclass;
      select 'pol_md5=' || coalesce(md5(string_agg(policyname || '|' || cmd || '|' ||
             array_to_string(roles, ',') || '|' || coalesce(qual, '-') || '|' ||
             coalesce(with_check, '-'), ',' order by policyname)), 'none')
        from pg_policies where schemaname = 'public' and tablename = '{TABLE}';
      select 'idx_md5=' || coalesce(md5(string_agg(indexdef, ',' order by indexname)), 'none')
        from pg_indexes where schemaname = 'public' and tablename = '{TABLE}';
      select 'grant_md5=' || md5(string_agg(grantee || '|' || privs, ',' order by grantee))
        from (select grantee, string_agg(distinct privilege_type, ',' order by privilege_type) as privs
                from information_schema.role_table_grants
               where table_schema = 'public' and table_name = '{TABLE}'
               group by grantee) g;
      select 'n_cols=' || count(*)::text from information_schema.columns
       where table_schema = 'public' and table_name = '{TABLE}';
      select 'n_rows=' || count(*)::text from public.{TABLE};
      select 'rls=' || relrowsecurity::text || ' force=' || relforcerowsecurity::text
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = '{TABLE}';
    """)
    return values(rows)


def report_publication(got):
    flags = got.get("puballtables", "")
    if "puballtables=false" in flags and "pubinsert=true" in flags \
            and "pubupdate=true" in flags and "pubdelete=true" in flags:
        ok("sql_publication_streams_edits",
           f"{PUBLICATION} is a table list rather than FOR ALL TABLES, and it "
           "streams inserts, updates and deletes - which is what makes adding a "
           "table to it possible at all, and what makes a removal, which is an "
           "update, arrive")
    else:
        bad("sql_publication_streams_edits", flags or "missing")

    if got.get("member") == "1":
        ok("sql_collection_entries_is_in_the_publication",
           f"public.{TABLE} is streamed. The tables in {PUBLICATION} are "
           f"{got.get('streamed', 'missing')}. This is the one reading that "
           "settles it; nothing else in this file can, and the section below "
           "says why")
    else:
        bad("sql_collection_entries_is_in_the_publication",
            f"public.{TABLE} is NOT in {PUBLICATION}. The tables in it are "
            f"{got.get('streamed', 'missing')} - so the client can subscribe, "
            "will be told the subscription is fine, and will never be sent "
            "anything")

    failures = [f"{name}: {got.get(name, 'missing')} != {want}"
                for name, want in SCHEMA.items() if got.get(name) != want]
    if failures:
        bad("sql_nothing_but_the_publication_changed", "\n".join(failures))
    else:
        ok("sql_nothing_but_the_publication_changed",
           "the constraints, the policy, the grants and the indexes are "
           "byte-for-byte what the tombstone migration left behind: this "
           "migration added no column, dropped no index and touched no grant")

    if got.get("n_cols") == "16" and got.get("rls") == "true force=false":
        ok("sql_the_table_is_the_one_the_client_knows",
           f"16 columns, row level security on and not forced, and "
           f"{got.get('n_rows')} holding(s) in it - the shape the client's own "
           "payload and the policy Realtime applies both expect")
    else:
        bad("sql_the_table_is_the_one_the_client_knows",
            f"n_cols={got.get('n_cols')} rls={got.get('rls')}")


# ---------------------------------------------------------------------------
# The Realtime half
# ---------------------------------------------------------------------------


def check_anonymous_verdict(url, publishable):
    """What the join says, what the server says afterwards, and why the first
    one is not a proof of anything.

    Run against the real table and against one that does not exist, because the
    point is the difference between them - or, as it turns out on this project,
    the absence of one.
    """
    channel = f"prove-{TABLE}"
    try:
        conn, reply, verdict = join_channel(
            url, publishable, channel, [binding(TABLE)])
    except (OSError, RuntimeError) as error:
        bad("realtime_the_join_is_accepted_whatever_the_table", str(error))
        return
    try:
        echoed = (reply or {}).get("response", {}).get("postgres_changes")
        status = (reply or {}).get("status")
        if status == "ok" and echoed:
            ok("realtime_the_join_is_accepted_whatever_the_table",
               "the join answered ok and echoed the binding back - event "
               f"{echoed[0].get('event')}, table {echoed[0].get('table')}, "
               f"filter {echoed[0].get('filter')} - which is what a subscribed "
               "channel looks like from the client, and is also what a channel "
               "that will never deliver anything looks like")
        else:
            bad("realtime_the_join_is_accepted_whatever_the_table",
                f"status={status} reply={json.dumps(reply)[:300]}")
    finally:
        conn.close()

    control_channel = f"prove-control-{NOWHERE}"
    try:
        conn, _, control = join_channel(
            url, publishable, control_channel, [binding(NOWHERE)])
    except (OSError, RuntimeError) as error:
        bad("realtime_the_verdict_does_not_name_the_publication", str(error))
        return
    try:
        message = (control or {}).get("message", "")
        if (control or {}).get("status") == "error" and "Realtime is enabled" in message:
            ok("realtime_the_verdict_does_not_name_the_publication",
               "a table that does not exist is refused with the same words as "
               "one that does - 'check Realtime is enabled for the given "
               "connect parameters' - so that message cannot be read as "
               "'this table is not streamed', and the publication claim rests "
               "on the SQL reading and on the delivery check below")
        else:
            bad("realtime_the_verdict_does_not_name_the_publication",
                f"the control was answered differently: {json.dumps(control)[:300]}")

        real = verdict or {}
        if real.get("status") == "error":
            skip("realtime_a_subscription_without_a_session_is_refused",
                 "the publishable key alone cannot subscribe to this table, so "
                 "no unauthenticated run can prove that a change travels: "
                 f"{str(real.get('message'))[:200]}. Realtime checks the "
                 "subscription as the client's role, and with no session there "
                 "is no account for the row policy to match, so this is "
                 "expected rather than a fault - and it is why the delivery "
                 "check needs a session")
        else:
            ok("realtime_a_subscription_without_a_session_is_refused",
               "the subscription was accepted even without a session, which is "
               "worth knowing: it means an anonymous listener can hold a "
               "channel open on this table and will still be sent nothing, "
               "because the policy decides what is delivered")
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Delivery, with a session
# ---------------------------------------------------------------------------


def http(method, url, headers, body=None, timeout=30):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(url, data=data, method=method)
    for name, value in headers.items():
        request.add_header(name, value)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as answer:
            text = answer.read().decode()
            return answer.status, (json.loads(text) if text else None)
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()[:300]


def check_delivery(url, publishable, secret):
    """Two changes written for a real account, and the events they produce.

    The only live proof of the whole chain at once. The row is written through
    PostgREST as its owner, so row level security lets it in; the subscription
    carries that account's token, so the policy lets the change out; and what
    arrives is checked for the columns the merge reads. The second write is a
    removal - the row with deleted_at stamped on it - because that is the case
    the whole feature is judged on, and the reason the payload has to be the
    new record rather than the old one: under row level security the old record
    is reduced to the primary key, so the tombstone is only ever in the new one.

    Written through the API rather than in SQL, because SQL could not do it: a
    probe row inside a transaction that is rolled back is a change logical
    replication never sees, and a probe row committed for somebody else's
    account would be a row in a real collector's collection.
    """
    email = f"zz-realtime-probe-{int(time.time())}@example.com"
    password = base64.b64encode(os.urandom(24)).decode().replace("/", "x")
    created = None

    try:
        status, body = http(
            "POST", f"{url}/auth/v1/admin/users",
            {"apikey": secret, "Authorization": f"Bearer {secret}",
             "Content-Type": "application/json"},
            {"email": email, "password": password, "email_confirm": True},
        )
        if status not in (200, 201) or not isinstance(body, dict):
            bad("realtime_a_change_reaches_a_signed_in_browser",
                f"the probe account could not be created: {status} {body}")
            return
        created = body
        user_id = created["id"]

        status, body = http(
            "POST", f"{url}/auth/v1/token?grant_type=password",
            {"apikey": publishable, "Content-Type": "application/json"},
            {"email": email, "password": password},
        )
        if status != 200 or not isinstance(body, dict):
            bad("realtime_a_change_reaches_a_signed_in_browser",
                f"the probe account could not sign in: {status} {body}")
            return
        token = body["access_token"]

        conn, reply, verdict = join_channel(
            url, publishable, f"prove-live-{user_id}",
            [binding(TABLE, user_id)], token=token,
        )
        try:
            if (verdict or {}).get("status") == "error":
                bad("realtime_a_change_reaches_a_signed_in_browser",
                    "a signed-in account was refused a subscription to this "
                    "table, which is what a table outside the publication looks "
                    "like from a client: "
                    f"{str(verdict.get('message'))[:300]}")
                return
            if (reply or {}).get("status") != "ok":
                bad("realtime_a_change_reaches_a_signed_in_browser",
                    f"the join was refused: {json.dumps(reply)[:300]}")
                return

            status, body = http(
                "POST", f"{url}/rest/v1/{TABLE}",
                {"apikey": publishable, "Authorization": f"Bearer {token}",
                 "Content-Type": "application/json", "Prefer": "return=minimal"},
                {"game": "zz-probe", "card_id": "zz-probe", "finish": "nonfoil",
                 "condition": "near_mint", "language": "en", "binder": "",
                 "quantity": 1},
            )
            if status not in (200, 201, 204):
                bad("realtime_a_change_reaches_a_signed_in_browser",
                    f"the probe holding could not be written: {status} {body}")
                return

            added = wait_for_change(conn, "INSERT", "zz-probe")
            if added is None:
                bad("realtime_a_change_reaches_a_signed_in_browser",
                    "nothing arrived within twenty seconds of the write: the "
                    "subscription is live and the row is committed, so the "
                    "table is not being streamed")
                return
            missing = [column for column in
                       ("game", "card_id", "finish", "condition", "language",
                        "binder", "quantity", "deleted_at", "created_at",
                        "updated_at")
                       if column not in (added.get("record") or {})]
            if missing:
                bad("realtime_a_change_reaches_a_signed_in_browser",
                    f"the row arrived without {missing}, which the merge reads")
                return

            # The removal, as the other device performs it: the same row with a
            # deletion stamped on it and a later updated_at.
            status, body = http(
                "PATCH", f"{url}/rest/v1/{TABLE}?game=eq.zz-probe",
                {"apikey": publishable, "Authorization": f"Bearer {token}",
                 "Content-Type": "application/json", "Prefer": "return=minimal"},
                {"deleted_at": "now()", "updated_at": "now()"},
            )
            if status not in (200, 204):
                bad("realtime_a_change_reaches_a_signed_in_browser",
                    f"the probe removal was refused: {status} {body}")
                return

            removed = wait_for_change(conn, "UPDATE", "zz-probe")
            if removed is None or (removed.get("record") or {}).get("deleted_at") is None:
                bad("realtime_a_change_reaches_a_signed_in_browser",
                    "the removal did not arrive as an edit carrying deleted_at, "
                    "which is what hides the card on the other device")
                return

            ok("realtime_a_change_reaches_a_signed_in_browser",
               "a holding written for a signed-in account arrived on that "
               "account's subscription whole, and so did the removal made a "
               "moment later - with deleted_at on it, in the new record, which "
               "is the only record a policy-protected table sends")
        finally:
            conn.close()
    except (OSError, RuntimeError, KeyError) as error:
        bad("realtime_a_change_reaches_a_signed_in_browser", f"{error}")
    finally:
        # The test must not be the thing that leaves a mess behind: the holding
        # goes first, and the account with it.
        if created:
            http("DELETE", f"{url}/rest/v1/{TABLE}?game=eq.zz-probe",
                 {"apikey": secret, "Authorization": f"Bearer {secret}"})
            status, _ = http(
                "DELETE", f"{url}/auth/v1/admin/users/{created['id']}",
                {"apikey": secret, "Authorization": f"Bearer {secret}"})
            print(f"probe account deleted ({status})")


def check_nothing_left_behind(url, secret):
    status, body = http(
        "GET", f"{url}/rest/v1/{TABLE}?select=game&game=eq.zz-probe",
        {"apikey": secret, "Authorization": f"Bearer {secret}"},
    )
    if status == 200 and body == []:
        ok("probe_left_nothing_behind",
           "no zz-probe holding is left in the account, and the probe account "
           "was deleted with it")
    else:
        bad("probe_left_nothing_behind", f"{status} {body}")


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env-file", help="KEY=VALUE file to read the credentials from")
    parser.add_argument("--no-auth", action="store_true",
                        help="skip the sections that need a probe account")
    parser.add_argument("--require-sql", action="store_true",
                        help="treat a skipped SQL section as a failure")
    args = parser.parse_args()

    if args.env_file:
        with open(args.env_file, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                name, value = line.split("=", 1)
                name, value = name.strip(), value.strip().strip('"').strip("'")
                if name and name not in os.environ:
                    os.environ[name] = value

    url = (os.environ.get("SUPABASE_URL") or "").rstrip("/")
    publishable = os.environ.get("SUPABASE_PUBLISHABLE_KEY") or ""
    secret = os.environ.get("SUPABASE_SECRET_KEY") or ""
    db_url = (os.environ.get("SUPABASE_DB_URL_POOLED")
              or os.environ.get("SUPABASE_DB_URL") or "")
    if not url or not publishable:
        raise SystemExit("SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY are not set. "
                         "Put them in the environment or pass --env-file.")

    print(__doc__.split("Usage:")[0].strip().splitlines()[0])
    print()
    print(f"target        {url}")
    print("database      " + ("the session pooler in SUPABASE_DB_URL_POOLED"
                              if db_url and shutil.which("psql")
                              else "not available; the SQL checks will SKIP, and "
                                   "they are the only place membership is read"))
    print("session       " + ("a probe account can be made"
                              if secret and not args.no_auth
                              else "not available; the delivery check will SKIP, "
                                   "and it is the only place delivery is proven"))
    print()

    print("--- SQL, as the owner ---")
    if db_url and shutil.which("psql"):
        report_publication(check_publication(db_url))
    else:
        reason = ("SUPABASE_DB_URL_POOLED is not set, or psql is not on PATH, so "
                  "the publication cannot be read out of pg_catalog")
        for name in ("sql_publication_streams_edits",
                     "sql_collection_entries_is_in_the_publication",
                     "sql_nothing_but_the_publication_changed",
                     "sql_the_table_is_the_one_the_client_knows"):
            (bad if args.require_sql else skip)(name, reason)

    print()
    print("--- Realtime, without a session ---")
    check_anonymous_verdict(url, publishable)

    print()
    print("--- Realtime, with a session ---")
    if secret and not args.no_auth:
        check_delivery(url, publishable, secret)
        check_nothing_left_behind(url, secret)
    else:
        skip("realtime_a_change_reaches_a_signed_in_browser",
             "SUPABASE_SECRET_KEY is not set, so no probe account can be made. "
             "This is the check that proves a change actually reaches an open "
             "browser, and no subscription check above stands in for it")

    passed = sum(1 for status, _, _ in RESULTS if status == "PASS")
    failed = sum(1 for status, _, _ in RESULTS if status == "FAIL")
    skipped = sum(1 for status, _, _ in RESULTS if status == "SKIP")
    print()
    print(f"{passed} passed, {failed} failed, {skipped} skipped")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
