# Sharing Arcanum

Status: measured, 2026-09-22, on the deployed build at
https://marquezhv.com/arcanumweb/ and the live project
(`wqycllzbwbhqiqlmbwcu`). One thing blocks the front door, one thing is a
deliberate way in, and both were walked through rather than reasoned about.

If this file and the project disagree, the project is what a collector meets.

## What a collector needs

One URL: **https://marquezhv.com/arcanumweb/**. Nothing to install, nothing to
buy. On a phone it can be added to the home screen, which is what makes it behave
like an app rather than a page - `docs/web-on-ios.md` is that half, and the icon
that lands there is Arcanum's own.

Behind the URL there is an account, and that is where sharing stops being a
technical question: **an account is a vault**, row level security keeps it
readable by its owner and by nobody else, and the catalogue behind every screen is
shared by everybody. A second collector does not see the first one's cards - not
because the client filters them, but because Postgres will not hand them over.

## The front door is broken, and why

The sign-up screen asks Supabase Auth to create an account and send a
confirmation email. This project has **no mail path configured**, so GoTrue
refuses the whole request:

~~~
POST https://wqycllzbwbhqiqlmbwcu.supabase.co/auth/v1/signup  ->  500
{"code":"unexpected_failure","message":"Error sending confirmation email"}
~~~

Measured in a browser on the deployed build, on 2026-09-22: the screen fills in,
"Create account" is pressed, and nothing is created. Arcanum's own handling of
that answer is as good as it can be - the form stays, the fields keep their
values, and it says

> The confirmation email could not be sent. Check the address is spelled
> correctly, and try again in a few minutes.

which is the right sentence for a broken address and the wrong one for a project
with no mailer: nobody can get in, however carefully they spell their address.

### Two ways to fix it, both a dashboard setting

**1. Give Auth a mailer (the proper fix).** The host already holds a **Resend**
API key - `/home/zixen/arcanum/resend.token` - and already sends the price
alerts through it. Resend reports **`marquezhv.com` verified** (read-only check,
2026-09-22: `GET https://api.resend.com/domains` -> 200, one domain,
`status=verified`, region `us-east-1`), so Arcanum can send from its own domain
to anybody, which Resend's shared `onboarding@resend.dev` sender cannot - that
one only delivers to the account's own address, which is why the alerts work and
sign-up would not.

In the Supabase dashboard, **Authentication -> Emails -> SMTP settings**, with:

| Setting | Value |
| --- | --- |
| Host | `smtp.resend.com` |
| Port | `465` (SSL) or `587` (STARTTLS) |
| Username | `resend` |
| Password | the Resend API key - the one in `/home/zixen/arcanum/resend.token` |
| Sender email | `arcanum@marquezhv.com` (the domain is verified; the mailbox need not exist) |
| Sender name | `Arcanum` |

"Confirm email" stays on, addresses stay verified, and the front door opens: the
sign-up screen starts working with no change to the app at all. Nothing here was
applied - it is a dashboard action for the owner, and it is the one change that
turns "not shareable" into "shareable" without an invite.

**2. Or stop asking for a confirmation email.** Authentication -> Sign In /
Providers -> **Confirm email** off. Sign-up then returns a session immediately and
the front door opens in the same minute. The cost is that an address is never
proven - anybody can claim any address - which for a vault whose rows are private
anyway is a smaller loss than it sounds, and a larger one for password resets.

## The way in that works today: an invite

`tool/account/create_account.py`, run by the owner on the host, which holds the
admin key:

~~~sh
cd /home/zixen/arcanum && set -a && . ./supabase.env && set +a
python3 create_account.py --email someone@example.com
~~~

It creates the account already confirmed, generates a password, and prints the
handover - the URL, the address and the password - once. The password is stored
nowhere. On an address that already exists it rotates that account's password
instead, which is what an owner can do for somebody locked out; `--list` says who
is on the vault; `--delete` removes an account and every row it owns.

`tool/account/prove_account_creation.py` walks the whole journey, and ran on
2026-09-22 against the live project:

~~~
PASS  the_tool_makes_an_account
      created zz-invite-probe-...@example.com (...), confirmed without a
      confirmation email - which is the point, because this project has no mail path
PASS  the_new_account_can_sign_in
      POST /auth/v1/token?grant_type=password answered 200 with a session
PASS  the_new_account_starts_empty
      all three tables answered an empty array to a brand-new account
PASS  the_new_account_cannot_read_another_collectors_rows
      asking each table for every row without a filter answered an empty array,
      while the tables hold 7 collection_entries, 0 deck_cards, 0 decks for other
      accounts - the policy is what stands between two collectors, not the client
PASS  the_tool_lists_the_account
PASS  the_tool_rotates_a_password
      the new password signs in (200) and the old one is refused (400)
PASS  the_tool_deletes_the_account
PASS  nothing_is_left_behind
8 passed, 0 failed, 0 skipped
~~~

That last check is the one worth reading twice: a brand-new account asked each
table for **every row in it** and was handed nothing, while those tables hold the
owner's seven holdings. Isolation here is a policy, not a UI convention.

## What is still untested about sharing

- **Somebody else's device.** Every run above is a desktop Chrome with a phone
  viewport. A real iPhone has never opened it - no hardware yet - and that is the
  one claim `docs/web-on-ios.md` makes that is still unmeasured.
- **The mail path**, because there isn't one. The moment SMTP is configured, the
  sign-up screen should start working; the way to check it is to make an account
  through the UI with an address you can read, and see whether the confirmation
  arrives. `tool/account/prove_account_creation.py` is not that check and does not
  replace it - it proves the invite path, which is the one that exists.
- **Two collectors at once.** Isolation is proven; what has not been watched is two
  real people editing their own vaults in the same minute, which is a realtime and
  load question rather than a policy one. `docs/collection-realtime.md` proves the
  delivery half of it with two accounts of its own.

## Files

- `tool/account/create_account.py` - the invite tool above.
- `tool/account/prove_account_creation.py` - the proof above.
- `tool/account/backup_accounts.py`, `tool/account/restore_accounts.py` - the copy
  of every account, and the way back from it: `docs/account-backup.md`.
- `docs/catalogue-schema.md` - the policies and grants that make one collector's
  rows invisible to another.
- `docs/web-on-ios.md` - handing the app over as a home screen web app.
