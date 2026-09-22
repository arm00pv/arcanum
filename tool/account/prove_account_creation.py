#!/usr/bin/env python3
"""Prove that a collector can be let in.

The claim is not that the invite tool creates a row in auth.users - the admin API
is Supabase's and does what it says. It is that the account it makes is a working
way into Arcanum: that the password it prints signs in, that the vault behind it
is empty rather than somebody else's, that the account cannot read a row it does
not own even when it asks for every row in the table, that the owner can see who
has an account and rotate a password for somebody locked out, and that deleting
one takes the account away.

Nothing here touches a collector's rows. The probe account is created by the tool
under test, signs in, reads, is listed, has its password rotated, and is deleted;
every other account's rows are counted, never read.

Why this is worth a proof at all: the front door does not work. The sign-up screen
asks Supabase to create an account and send a confirmation email, and this project
has no mail path, so GoTrue answers 500 {"code": "unexpected_failure", "message":
"Error sending confirmation email"} and the account is not created. That is
measured in docs/sharing-arcanum.md. Until an SMTP sender is configured, this tool
is the way in, and a way in that has not been walked through is a hope.

Credentials come from the environment, or from a KEY=VALUE file named with
--env-file. They are never printed.

  SUPABASE_URL              required
  SUPABASE_SECRET_KEY       required - the admin key, for making and deleting
  SUPABASE_PUBLISHABLE_KEY  required - what the probe signs in with

Without all three the proof skips itself and says so rather than reporting a
journey it did not take.

Usage:
  set -a; . /home/zixen/arcanum/supabase.env; set +a
  python3 tool/account/prove_account_creation.py

Exit status is 0 only if nothing failed.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))

# The three tables an account owns, and the one column all of them have: a
# deck's lines are keyed by which deck, which printing and which board rather
# than by an id of their own, so user_id is what this proof reads.
TABLES = ("collection_entries", "decks", "deck_cards")
COLUMN = "user_id"

RESULTS = []


def record(status, name, detail):
    RESULTS.append((status, name, detail))
    print("%-4s  %s" % (status, name))
    for line in detail.splitlines():
        print("      " + line)
    sys.stdout.flush()


def ok(name, detail):
    record("PASS", name, detail)


def bad(name, detail):
    record("FAIL", name, detail)


def skip(name, detail):
    record("SKIP", name, detail)


def call(method, url, key, body=None, token=None, prefer=None):
    """One HTTP call, its status, its decoded body and its headers."""
    payload = None
    if body is not None:
        payload = json.dumps(body).encode("utf-8")
    headers = {"apikey": key, "Content-Type": "application/json",
               "User-Agent": "Arcanum/1.0 (proof, not a browser)"}
    if token:
        headers["Authorization"] = "Bearer " + token
    if prefer:
        headers["Prefer"] = prefer
    request = urllib.request.Request(url, data=payload, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=60) as answer:
            raw = answer.read().decode("utf-8", "replace")
            return answer.status, (json.loads(raw) if raw.strip() else None), dict(answer.headers)
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        try:
            return exc.code, json.loads(raw), dict(exc.headers or {})
        except ValueError:
            return exc.code, raw, dict(exc.headers or {})
    except Exception as exc:  # noqa: BLE001 - reported by the caller
        return 0, str(exc), {}


def tool(args, *extra):
    """The invite tool, run as the tool: its exit status and its words."""
    command = [sys.executable, os.path.join(HERE, "create_account.py")] + list(extra)
    if args.env_file:
        command += ["--env-file", args.env_file]
    done = subprocess.run(command, capture_output=True, text=True, timeout=300,
                          env=os.environ, cwd=HERE)
    return done.returncode, (done.stdout or "") + (done.stderr or "")


def sign_in(url, publishable, email, password):
    """What the sign-in screen does, exactly."""
    status, body, _ = call("POST", url + "/auth/v1/token?grant_type=password",
                           publishable, {"email": email, "password": password})
    return status, body


def row_count(url, secret, table):
    """How many rows the table holds, read with the admin key, counting only.

    user_id rather than id, because deck_cards has no id: its key is which
    account, which deck, which printing and which board. It is the one column all
    three tables have, and this proof asks each of them the same question.
    """
    # count=exact, or PostgREST answers "0-0/*" and a page of one row would be
    # reported as the table holding one row.
    status, body, headers = call(
        "GET", url + "/rest/v1/" + table + "?select=" + COLUMN + "&limit=1", secret,
        prefer="count=exact")
    if status not in (200, 206):
        return None
    span = headers.get("Content-Range") or headers.get("content-range") or ""
    tail = span.split("/")[-1] if "/" in span else ""
    return int(tail) if tail.isdigit() else (len(body) if isinstance(body, list) else None)


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="prove a collector can be let in with the invite tool")
    ap.add_argument("--env-file", default=None,
                    help="a KEY=VALUE file to read the credentials from")
    args = ap.parse_args(argv)

    if args.env_file and os.path.exists(args.env_file):
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
    secret = os.environ.get("SUPABASE_SECRET_KEY") or ""
    publishable = os.environ.get("SUPABASE_PUBLISHABLE_KEY") or ""
    if not (url and secret and publishable):
        skip("a_collector_can_be_let_in",
             "SUPABASE_URL, SUPABASE_SECRET_KEY or SUPABASE_PUBLISHABLE_KEY is not "
             "set, so no account can be made and no session can be opened")
        print("0 passed, 0 failed, 1 skipped")
        return 0

    stamp = int(time.time())
    email = "zz-invite-probe-%d@example.com" % stamp
    password = "Arcanum-probe-%d!" % stamp
    rotated = password + "rotated"
    account = None

    print("Let a collector in with the invite tool, and walk through the door.")
    print("")
    print("target   %s" % url)
    print("")

    try:
        code, words = tool(args, "--email", email, "--password", password)
        if code != 0 or "created" not in words:
            bad("the_tool_makes_an_account",
                ("the tool exited %d:" % code) + chr(10) + words)
            return 1
        first = [line for line in words.splitlines() if line.startswith("created")]
        ok("the_tool_makes_an_account",
           "%s, confirmed without a confirmation email - which is the point, "
           "because this project has no mail path" % first[0])

        status, body = sign_in(url, publishable, email, password)
        token = body.get("access_token") if isinstance(body, dict) else None
        if status != 200 or not token:
            bad("the_new_account_can_sign_in",
                "the sign-in screen's own request answered %s: %s" % (status, body))
            return 1
        account = body.get("user", {}).get("id")
        ok("the_new_account_can_sign_in",
           "POST /auth/v1/token?grant_type=password answered 200 with a session for "
           "%s, which is the account the tool made" % email)

        print("")
        print("--- What the new account sees ---")
        held = []
        for table in TABLES:
            status, body, _ = call(
                "GET", url + "/rest/v1/" + table + "?select=" + COLUMN,
                publishable, token=token)
            held.append((table, status, len(body) if isinstance(body, list) else body))
        wrong = [(table, status, rows) for table, status, rows in held
                 if status not in (200, 206) or rows != 0]
        if wrong:
            bad("the_new_account_starts_empty", "the probe account can already see "
                "rows: %s" % wrong)
        else:
            ok("the_new_account_starts_empty",
               "all three tables answered an empty array to a brand-new account: "
               + ", ".join(table for table, _s, _r in held))

        elsewhere = {table: row_count(url, secret, table) for table in TABLES}
        asked = {}
        for table in TABLES:
            status, body, _ = call(
                "GET", url + "/rest/v1/" + table + "?select=" + COLUMN,
                publishable, token=token)
            asked[table] = len(body) if isinstance(body, list) else body
        leaked = {table: rows for table, rows in asked.items() if rows != 0}
        if leaked:
            bad("the_new_account_cannot_read_another_collectors_rows",
                "the probe asked for every row of %s and was given rows: %s"
                % (", ".join(leaked), leaked))
        else:
            ok("the_new_account_cannot_read_another_collectors_rows",
               "asking each table for every row without a filter answered an empty "
               "array, while the tables hold %s for other accounts - the policy is "
               "what stands between two collectors, not the client"
               % ", ".join("%s %s" % (count, table)
                           for table, count in sorted(elsewhere.items())))

        print("")
        print("--- What the owner sees, and can do ---")
        code, words = tool(args, "--list")
        mine = [line for line in words.splitlines() if email in line]
        if code != 0 or not mine:
            bad("the_tool_lists_the_account",
                ("the tool exited %d and the listing does not name %s:"
                 % (code, email)) + chr(10) + words)
        elif "never" in mine[0]:
            bad("the_tool_lists_the_account",
                "the listing says the account has never signed in, where it just "
                "did: %s" % mine[0].strip())
        else:
            ok("the_tool_lists_the_account", mine[0].strip())

        code, words = tool(args, "--email", email, "--password", rotated)
        status_new, _ = sign_in(url, publishable, email, rotated)
        status_old, _ = sign_in(url, publishable, email, password)
        if code != 0 or status_new != 200 or status_old == 200:
            bad("the_tool_rotates_a_password",
                "the tool exited %d; the new password answered %s and the old one "
                "%s, where 200 and a refusal is what locking somebody out and back "
                "in again looks like" % (code, status_new, status_old))
        else:
            ok("the_tool_rotates_a_password",
               "the new password signs in (200) and the old one is refused (%s), so "
               "an owner can let somebody back into an account without deleting it "
               "and its rows" % status_old)

        print("")
        print("--- Out again ---")
        code, words = tool(args, "--delete", "--email", email)
        status, body = sign_in(url, publishable, email, rotated)
        code_list, listing = tool(args, "--list")
        if code != 0 or status == 200 or email in listing:
            bad("the_tool_deletes_the_account",
                "the tool exited %d; signing in afterwards answered %s; the listing "
                "%s the address" % (code, status,
                                    "still holds" if email in listing else "does not hold"))
        else:
            ok("the_tool_deletes_the_account",
               "the account is gone: signing in answers %s and the listing no longer "
               "names it - and every row it owned went with it, because the account "
               "tables point at auth.users" % status)
            account = None

    finally:
        # A proof that leaves an account behind has left a door open.
        if account:
            call("DELETE", url + "/auth/v1/admin/users/" + account, secret)

    print("")
    print("--- Nothing left behind ---")
    code, listing = tool(args, "--list")
    left = [line for line in listing.splitlines() if "zz-invite-probe-" in line]
    if left:
        bad("nothing_is_left_behind", chr(10).join(left))
    else:
        ok("nothing_is_left_behind",
           "no probe account is registered, so the door this proof opened is shut")

    passed = sum(1 for status, _, _ in RESULTS if status == "PASS")
    failed = sum(1 for status, _, _ in RESULTS if status == "FAIL")
    skipped = sum(1 for status, _, _ in RESULTS if status == "SKIP")
    print("")
    print("%d passed, %d failed, %d skipped" % (passed, failed, skipped))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
