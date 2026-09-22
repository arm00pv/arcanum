#!/usr/bin/env python3
"""Make an account for somebody, because Arcanum cannot make one for itself.

Why this exists. A vault is worth sharing and this one cannot yet be joined from
the front door: the sign-up screen asks Supabase Auth to create the account and
send a confirmation email, and this project has no mail path configured, so GoTrue
answers the request with

    {"code": "unexpected_failure", "message": "Error sending confirmation email"}

and the account is not created at all. Nothing in the app is wrong - it sends the
request Auth asks for and says what came back - but a friend given the link cannot
get in, which makes the app unshareable for a reason that is nowhere in its code.
docs/sharing-arcanum.md is the measurement and the two ways to fix it properly
(an SMTP sender Auth can use, or turning confirmation off).

Until one of those is done, this is how somebody joins: the owner runs this on the
host, which holds the admin key, and hands over an address and a password. It is
an invite, which is what this app is anyway - a vault whose rows are readable by
their owner and by nobody else.

What it does:

    python3 create_account.py --email someone@example.com
        makes the account, with email_confirm already set so no confirmation mail
        is needed, and prints a password for it. The password is printed once and
        stored nowhere: this file keeps no record of anybody's credentials.

    python3 create_account.py --email someone@example.com --password 'a chosen one'
        the same, with a password chosen rather than generated. On an address that
        already exists this rotates that account's password instead, which is the
        one thing an owner can do for somebody who is locked out.

    python3 create_account.py --list
        who is on the vault: address, whether it is confirmed, when it was made and
        when it was last signed in to.

    python3 create_account.py --delete --email someone@example.com
        removes the account. Their rows go with it - the account tables point at
        auth.users - so this is the whole of somebody's vault, and the dump in
        backups/ is what it can be restored from.

    python3 create_account.py --email someone@example.com --dry-run
        says what would happen and makes no request.

Credentials come from the environment, or from a KEY=VALUE file named with
--env-file. They are never printed, and nothing in this file holds a secret. The
admin key is the key to every account in the project: this runs on the host and
never anywhere a browser could reach it.

  SUPABASE_URL         required - the project
  SUPABASE_SECRET_KEY  required - the admin key, which is what makes an account

Exit status is 0 unless an account could not be made, found or removed.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request

DEFAULT_ENV_FILE = "/home/zixen/arcanum/supabase.env"

# Where a collector opens the vault. Printed with every account so the line the
# owner pastes to somebody is a line they can act on.
DEFAULT_APP = "https://marquezhv.com/arcanumweb/"

# How long a generated password is, and what it is made of. base64 of 24 random
# bytes is 32 characters of a-z A-Z 0-9 and two symbols, which is more than a
# person has to remember because they are pasting it once.
PASSWORD_BYTES = 24


class Refusal(RuntimeError):
    """Something the caller should be told, in one sentence."""


def load_env_file(path):
    """Reads KEY=VALUE lines into the environment, without overwriting it."""
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            name, value = line.split("=", 1)
            name, value = name.strip(), value.strip().strip('"').strip("'")
            if name and name not in os.environ:
                os.environ[name] = value


def call(method, path, secret, body=None, url=None):
    """One call to the admin API, its status and its decoded body."""
    payload = None
    if body is not None:
        payload = json.dumps(body).encode("utf-8")
    request = urllib.request.Request(
        (url or required_url()) + path, data=payload, method=method,
        headers={"apikey": secret, "Authorization": "Bearer " + secret,
                 "Content-Type": "application/json",
                 "User-Agent": "Arcanum/1.0 (invite tool, not a browser)"})
    try:
        with urllib.request.urlopen(request, timeout=60) as answer:
            raw = answer.read().decode("utf-8", "replace")
            return answer.status, (json.loads(raw) if raw.strip() else None)
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        try:
            return exc.code, json.loads(raw)
        except ValueError:
            return exc.code, raw
    except Exception as exc:  # noqa: BLE001 - reported by the caller
        raise Refusal("the project could not be reached: %s" % exc)


def required_url():
    url = (os.environ.get("SUPABASE_URL") or "").rstrip("/")
    if not url:
        raise Refusal("SUPABASE_URL is not set. Put it in the environment or in "
                      "the file named by --env-file.")
    return url


def users(secret, url=None):
    """Every account in the project, as the admin API lists them.

    Paged, because the endpoint answers a page at a time and a vault that has
    grown past one page is a vault whose owner would otherwise be told there is
    nobody in it.
    """
    found = []
    page = 1
    while True:
        status, body = call("GET", "/auth/v1/admin/users?page=%d&per_page=200"
                            % page, secret, url=url)
        if status != 200:
            raise Refusal("the accounts could not be listed: %s %s" % (status, body))
        rows = body.get("users") if isinstance(body, dict) else body
        if not rows:
            break
        found.extend(rows)
        if len(rows) < 200:
            break
        page += 1
    return found


def find(secret, email, url=None):
    wanted = email.strip().lower()
    for account in users(secret, url):
        if str(account.get("email") or "").lower() == wanted:
            return account
    return None


def generate():
    return base64.b64encode(os.urandom(PASSWORD_BYTES)).decode().replace("/", "x")


def describe(account):
    """One line about one account, for --list and for a refusal."""
    confirmed = account.get("email_confirmed_at") or account.get("confirmed_at")
    return "%-40s %-10s made %-20s last signed in %s" % (
        account.get("email") or "-",
        "confirmed" if confirmed else "unconfirmed",
        (account.get("created_at") or "-")[:19],
        (account.get("last_sign_in_at") or "never")[:19])


def create(args, secret):
    """Makes one account, or rotates the password of one that exists."""
    email = args.email[0].strip()
    password = args.password or generate()
    existing = find(secret, email, args.url)
    if args.dry_run:
        if existing:
            print("dry run: %s already exists, so --password would rotate it and "
                  "nothing else would change" % email)
        else:
            print("dry run: %s would be created, confirmed, with a %d-character "
                  "password; no request was made"
                  % (email, len(password) if args.password else PASSWORD_BYTES * 4 // 3))
        return 0
    if existing:
        if not args.password:
            print("%s already exists (created %s, last signed in %s). Pass "
                  "--password to rotate its password, or --delete to remove it."
                  % (email, (existing.get("created_at") or "-")[:19],
                     (existing.get("last_sign_in_at") or "never")[:19]))
            return 0
        status, body = call("PUT", "/auth/v1/admin/users/" + existing["id"], secret,
                            {"password": password}, url=args.url)
        if status != 200:
            print("the password could not be rotated: %s %s" % (status, body),
                  file=sys.stderr)
            return 1
        print("rotated the password for %s" % email)
        print("")
        print_handover(args, email, password)
        return 0

    status, body = call("POST", "/auth/v1/admin/users", secret,
                        {"email": email, "password": password,
                         "email_confirm": True}, url=args.url)
    if status not in (200, 201):
        print("the account could not be created: %s %s" % (status, body),
              file=sys.stderr)
        return 1
    print("created %s (%s)" % (email, body.get("id")))
    print("")
    print_handover(args, email, password)
    return 0


def print_handover(args, email, password):
    """What the owner pastes to the person they are inviting."""
    print("hand this over - it is the only time the password is shown:")
    print("")
    print("  Arcanum:  %s" % args.app)
    print("  email:    %s" % email)
    print("  password: %s" % password)
    print("")
    print("Their vault is empty until they add a card, and nothing in it is "
          "readable by another collector.")


def remove(args, secret):
    email = args.email[0].strip()
    existing = find(secret, email, args.url)
    if existing is None:
        print("%s is not an account in this project" % email, file=sys.stderr)
        return 1
    if args.dry_run:
        print("dry run: %s (%s) would be deleted, and every row it owns with it"
              % (email, existing.get("id")))
        return 0
    status, body = call("DELETE", "/auth/v1/admin/users/" + existing["id"], secret,
                        url=args.url)
    if status not in (200, 204):
        print("the account could not be deleted: %s %s" % (status, body),
              file=sys.stderr)
        return 1
    print("deleted %s (%s), and with it every row it owned" % (email,
                                                               existing.get("id")))
    return 0


def parse_args(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--email", action="append", default=[],
                    help="the address to make; one at a time")
    ap.add_argument("--password", default="",
                    help="a password, rather than one generated here")
    ap.add_argument("--list", action="store_true",
                    help="every account in the project, and nothing else")
    ap.add_argument("--delete", action="store_true",
                    help="remove the account (and every row it owns)")
    ap.add_argument("--dry-run", action="store_true",
                    help="say what would happen and make no request")
    ap.add_argument("--url", default="",
                    help="the project URL; the environment's SUPABASE_URL by default")
    ap.add_argument("--app", default=DEFAULT_APP,
                    help="the address to hand over with the account")
    ap.add_argument("--env-file", default=DEFAULT_ENV_FILE,
                    help="a KEY=VALUE file to read the credentials from")
    return ap.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    if args.env_file and os.path.exists(args.env_file):
        load_env_file(args.env_file)

    secret = os.environ.get("SUPABASE_SECRET_KEY") or ""
    if not secret:
        print("this needs SUPABASE_SECRET_KEY - the admin key - in the environment "
              "or in the file named by --env-file. Without it no account can be "
              "made, which is the point of the key.", file=sys.stderr)
        return 2

    try:
        if args.list:
            accounts = users(secret, args.url)
            print("%d account(s) in this project:" % len(accounts))
            for account in sorted(accounts, key=lambda a: a.get("email") or ""):
                print("  " + describe(account))
            return 0
        if not args.email:
            print("say whose account: --email someone@example.com, or --list to "
                  "see who has one", file=sys.stderr)
            return 2
        if len(args.email) > 1:
            print("one address at a time: each one is a password to hand over, "
                  "and this prints them as it makes them", file=sys.stderr)
            return 2
        if args.password and args.delete:
            print("--password and --delete do not go together: a deleted account "
                  "has no password to set", file=sys.stderr)
            return 2
        if args.delete:
            return remove(args, secret)
        return create(args, secret)
    except Refusal as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
