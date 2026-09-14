#!/usr/bin/env python3
"""Tests for the Arcanum companion: identity, email, and what guards them.

The server is started for real, on a port the kernel picks, against a temporary
directory, with the mailer replaced by a list. Nothing here reaches the network:
what is being tested is this server's own rules - who gets a code, what a code
buys, what a token opens, and what a stranger is allowed to learn.

Run:
    python tool/test_sync_server.py
"""

import base64
import gzip
import json
import os
import re
import shutil
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sync_server  # noqa: E402

ROOT_TOKEN = "root-token-for-tests"
OWNER = "owner@example.com"
STRANGER = "stranger@example.com"
CODE = re.compile(r"\b(\d{6})\b")


class Quiet(sync_server.Handler):
    """The handler, with the request log turned off."""

    def log_message(self, fmt, *args):
        pass


class CompanionTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="arcanum-test-")
        self.backups = os.path.join(self.dir, "backups")
        os.makedirs(self.backups)
        self.token_path = os.path.join(self.dir, "backup.token")
        with open(self.token_path, "w", encoding="utf-8") as handle:
            handle.write(ROOT_TOKEN + "\n")
        self.mail_key = os.path.join(self.dir, "resend.token")
        with open(self.mail_key, "w", encoding="utf-8") as handle:
            handle.write("re_test_key\n")

        sync_server.BACKUP_TOKEN_PATH = self.token_path
        sync_server.BACKUPS_DIR = self.backups
        sync_server.IDENTITY_PATH = os.path.join(self.dir, "identity.json")
        sync_server.RESEND_KEY_PATH = self.mail_key
        sync_server.PUBLIC_URL = "https://example.com/arcanum"
        sync_server.MAIL_FROM = "Arcanum <onboarding@resend.dev>"
        sync_server.SEALED_DIR = os.path.join(self.dir, "sealed")
        sync_server.RESEND_ENDPOINT = "https://api.resend.com/emails"
        sync_server._SENT.clear()
        doc = sync_server.empty_identity()
        doc["owner"] = OWNER
        sync_server.save_identity(doc)

        self.sent = []
        sync_server.MAIL_SENDER = self._fake_mail
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Quiet)
        self.base = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        shutil.rmtree(self.dir, ignore_errors=True)

    # -- helpers ----------------------------------------------------------

    def _fake_mail(self, to, subject, text, attachments=None):
        self.sent.append({"to": to, "subject": subject, "text": text,
                          "attachments": attachments or []})
        return {"ok": True, "id": "mail-%d" % len(self.sent)}

    def call(self, method, path, body=None, token=None, raw=False):
        data = None
        headers = {}
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if token:
            headers["X-Arcanum-Token"] = token
        request = urllib.request.Request(self.base + path, data=data,
                                         headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                payload = response.read()
                if raw:
                    return response.status, payload.decode("utf-8", "replace")
                return response.status, json.loads(payload.decode("utf-8") or "{}")
        except urllib.error.HTTPError as exc:
            with exc:
                payload = exc.read()
            if raw:
                return exc.code, payload.decode("utf-8", "replace")
            return exc.code, json.loads(payload.decode("utf-8") or "{}")

    def code_from_mail(self):
        return CODE.search(self.sent[-1]["text"]).group(1)

    def sign_in(self, address=OWNER, label="pixel-7-pro"):
        status, body = self.call("POST", "/v1/auth/start", {"email": address})
        self.assertEqual(status, 200, body)
        self.assertTrue(body.get("sent"), body)
        status, body = self.call("POST", "/v1/auth/verify",
                                 {"email": address, "code": self.code_from_mail(),
                                  "device": label})
        self.assertEqual(status, 200, body)
        return body["token"]

    # -- the code ---------------------------------------------------------

    def test_owner_gets_a_code_by_email(self):
        status, body = self.call("POST", "/v1/auth/start", {"email": OWNER})
        self.assertEqual(status, 200)
        self.assertTrue(body["sent"])
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.sent[0]["to"], OWNER)
        self.assertTrue(re.fullmatch(r"\d{6}", self.code_from_mail()))

    def test_the_code_is_stored_as_a_digest_not_as_itself(self):
        self.call("POST", "/v1/auth/start", {"email": OWNER})
        code = self.code_from_mail()
        with open(sync_server.IDENTITY_PATH, "r", encoding="utf-8") as handle:
            raw = handle.read()
        self.assertNotIn(code, raw)
        self.assertIn(sync_server.token_digest(code), raw)

    def test_a_stranger_is_told_nothing(self):
        status, body = self.call("POST", "/v1/auth/start", {"email": STRANGER})
        self.assertEqual(status, 200)
        self.assertFalse(body["sent"])
        self.assertEqual(self.sent, [])
        self.assertNotIn("invited", body)
        self.assertNotIn("error", body)

    def test_but_the_collector_is_told_the_truth(self):
        status, body = self.call("POST", "/v1/auth/start", {"email": STRANGER},
                                 token=ROOT_TOKEN)
        self.assertEqual(status, 200)
        self.assertFalse(body["sent"])
        self.assertEqual(body["invited"], [OWNER])

    def test_a_second_code_inside_a_minute_is_not_sent(self):
        self.call("POST", "/v1/auth/start", {"email": OWNER})
        status, body = self.call("POST", "/v1/auth/start", {"email": OWNER})
        self.assertEqual(status, 200)
        self.assertFalse(body["sent"])
        self.assertGreater(body["retry_in"], 0)
        self.assertEqual(len(self.sent), 1)

    def test_sign_in_is_503_without_a_mail_key(self):
        sync_server.RESEND_KEY_PATH = os.path.join(self.dir, "missing.token")
        status, body = self.call("POST", "/v1/auth/start", {"email": OWNER})
        self.assertEqual(status, 503)
        self.assertEqual(self.sent, [])

    def test_a_mailer_that_refuses_is_reported_not_swallowed(self):
        sync_server.MAIL_SENDER = lambda *args, **kwargs: {
            "ok": False, "status": 403,
            "error": "You can only send testing emails to your own email address",
        }
        status, body = self.call("POST", "/v1/auth/start", {"email": OWNER})
        self.assertEqual(status, 200)
        self.assertFalse(body["sent"])
        self.assertIn("your own email address", body["error"])

    def _blocked_server(self, status, body):
        """A stand-in for Resend that answers however the test wants it to."""
        captured = {}

        class Stub(BaseHTTPRequestHandler):
            def do_POST(self):
                captured["user_agent"] = self.headers.get("User-Agent") or ""
                captured["authorization"] = self.headers.get("Authorization") or ""
                captured["body"] = self.rfile.read(
                    int(self.headers.get("Content-Length") or 0))
                payload = body if isinstance(body, bytes) else body.encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, fmt, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Stub)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        sync_server.RESEND_ENDPOINT = "http://127.0.0.1:%d/emails" % server.server_address[1]
        return captured

    def test_a_mail_is_sent_named_not_as_a_bare_script(self):
        """Cloudflare bans urllib's own agent, so the name we send is the fix."""
        captured = self._blocked_server(200, '{"id": "abc"}')
        result = sync_server.send_mail(OWNER, "subject", "text")
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["id"], "abc")
        self.assertEqual(captured["user_agent"], sync_server.MAIL_AGENT)
        self.assertTrue(captured["authorization"].startswith("Bearer "))

    def test_a_refusal_that_is_not_json_is_still_reported(self):
        """A 1010 from Cloudflare is one line of text, and that line is the answer."""
        self._blocked_server(403, "error code: 1010\n")
        result = sync_server.send_mail(OWNER, "subject", "text")
        self.assertFalse(result["ok"])
        self.assertIn("1010", result["error"])

    def test_a_json_refusal_is_reported_in_resends_own_words(self):
        self._blocked_server(403, '{"statusCode":403,"message":"domain is not verified"}')
        result = sync_server.send_mail(OWNER, "subject", "text")
        self.assertEqual(result["status"], 403)
        self.assertEqual(result["error"], "domain is not verified")

    # -- the token --------------------------------------------------------

    def test_a_code_buys_a_token_that_opens_the_backups(self):
        token = self.sign_in()
        status, body = self.call("GET", "/v1/backup/status", token=token)
        self.assertEqual(status, 200, body)
        self.assertTrue(body["ok"])

    def test_a_device_token_opens_the_vault_page(self):
        token = self.sign_in()
        status, page = self.call("GET", "/vault?token=" + token, raw=True)
        self.assertIn(status, (200, 404))  # 404 only when there is no archive
        self.assertNotIn("unauthorized", page)

    def test_the_token_is_not_stored_as_itself(self):
        token = self.sign_in()
        with open(sync_server.IDENTITY_PATH, "r", encoding="utf-8") as handle:
            raw = handle.read()
        self.assertNotIn(token, raw)
        self.assertIn(sync_server.token_digest(token), raw)

    def test_a_wrong_code_is_refused(self):
        self.call("POST", "/v1/auth/start", {"email": OWNER})
        status, body = self.call("POST", "/v1/auth/verify",
                                 {"email": OWNER, "code": "000000",
                                  "device": "pixel"})
        self.assertIn(status, (401,))
        self.assertEqual(body["ok"], False)

    def test_a_code_dies_after_five_wrong_guesses(self):
        self.call("POST", "/v1/auth/start", {"email": OWNER})
        right = self.code_from_mail()
        for _ in range(sync_server.CODE_TRIES):
            self.call("POST", "/v1/auth/verify",
                      {"email": OWNER, "code": "111111", "device": "pixel"})
        status, body = self.call("POST", "/v1/auth/verify",
                                 {"email": OWNER, "code": "111111",
                                  "device": "pixel"})
        self.assertEqual(status, 401)
        self.assertIn("expired", body["error"])
        status, body = self.call("POST", "/v1/auth/verify",
                                 {"email": OWNER, "code": right,
                                  "device": "pixel"})
        self.assertEqual(status, 401, "a burned code must not come back to life")

    def test_a_code_works_once(self):
        token = self.sign_in()
        status, body = self.call("POST", "/v1/auth/verify",
                                 {"email": OWNER, "code": self.code_from_mail(),
                                  "device": "another"})
        self.assertEqual(status, 401)
        self.assertTrue(token)

    def test_an_expired_code_is_refused(self):
        self.call("POST", "/v1/auth/start", {"email": OWNER})
        code = self.code_from_mail()
        doc = sync_server.identity()
        for entry in doc["codes"]:
            entry["expires"] = 1
        sync_server.save_identity(doc)
        status, body = self.call("POST", "/v1/auth/verify",
                                 {"email": OWNER, "code": code, "device": "pixel"})
        self.assertEqual(status, 401)
        self.assertIn("expired", body["error"])

    # -- devices ----------------------------------------------------------

    def test_devices_are_listed_and_the_current_one_is_marked(self):
        token = self.sign_in(label="pixel-7-pro")
        status, body = self.call("GET", "/v1/auth/devices", token=token)
        self.assertEqual(status, 200)
        labels = [entry["label"] for entry in body["devices"]]
        self.assertEqual(labels, ["pixel-7-pro"])
        self.assertTrue(body["devices"][0]["current"])
        self.assertTrue(body["email"])

    def test_signing_in_again_replaces_that_device_rather_than_adding_one(self):
        self.sign_in(label="pixel-7-pro")
        sync_server._SENT.clear()          # as if the minute had passed
        self.sign_in(label="pixel-7-pro")
        self.assertEqual(len(sync_server.devices_of(sync_server.identity())), 1)

    def test_revoking_a_device_takes_its_token_away(self):
        token = self.sign_in(label="pixel-7-pro")
        status, body = self.call("POST", "/v1/auth/revoke",
                                 {"device": "pixel-7-pro"}, token=ROOT_TOKEN)
        self.assertEqual(status, 200)
        self.assertTrue(body["removed"])
        status, _ = self.call("GET", "/v1/backup/status", token=token)
        self.assertEqual(status, 401, "a revoked token must stop working")

    def test_the_root_token_survives_every_revocation(self):
        self.sign_in(label="pixel-7-pro")
        self.call("POST", "/v1/auth/revoke", {"device": "pixel-7-pro"},
                  token=ROOT_TOKEN)
        status, _ = self.call("GET", "/v1/backup/status", token=ROOT_TOKEN)
        self.assertEqual(status, 200, "a server must not be lockable out of itself")

    def test_revoking_needs_a_credential(self):
        self.sign_in(label="pixel-7-pro")
        status, _ = self.call("POST", "/v1/auth/revoke", {"device": "pixel-7-pro"})
        self.assertEqual(status, 401)
        self.assertEqual(len(sync_server.devices_of(sync_server.identity())), 1)

    # -- email ------------------------------------------------------------

    def test_the_vault_link_mints_a_credential_that_opens_the_vault(self):
        status, body = self.call("POST", "/v1/email/vault", {}, token=ROOT_TOKEN)
        self.assertEqual(status, 200, body)
        self.assertEqual(len(self.sent), 1)
        link = re.search(r"https://\S+/vault\?token=\S+", self.sent[0]["text"])
        self.assertIsNotNone(link, self.sent[0]["text"])
        minted = link.group(0).split("token=")[1]
        self.assertTrue(sync_server.authorized(minted))
        status, page = self.call("GET", "/vault?token=" + minted, raw=True)
        self.assertNotIn("unauthorized", page)

    def test_a_vault_link_stops_working_when_it_expires(self):
        self.call("POST", "/v1/email/vault", {}, token=ROOT_TOKEN)
        link = re.search(r"token=(\S+)", self.sent[0]["text"])
        self.assertIsNotNone(link)
        minted = link.group(1)
        self.assertTrue(sync_server.authorized(minted), "it works to begin with")
        doc = sync_server.identity()
        for entry in doc["devices"]:
            entry["expires"] = 1
        sync_server.save_identity(doc)
        self.assertFalse(sync_server.authorized(minted),
                         "and a week later it is not a credential any more")
        status, _ = self.call("GET", "/v1/backup/status", token=minted)
        self.assertEqual(status, 401)

    def test_a_backup_can_be_emailed_and_arrives_intact(self):
        payload = gzip.compress(json.dumps({"format": "arcanum-backup",
                                            "version": 1,
                                            "tables": {"collection_entries": []}
                                            }).encode("utf-8"))
        name = "arcanum-backup-2026-09-14T120000Z-pixel.json.gz"
        with open(os.path.join(self.backups, name), "wb") as handle:
            handle.write(payload)
        status, body = self.call("POST", "/v1/email/backup", {}, token=ROOT_TOKEN)
        self.assertEqual(status, 200, body)
        attachment = self.sent[0]["attachments"][0]
        self.assertEqual(attachment["filename"], name)
        self.assertEqual(base64.b64decode(attachment["content"]), payload)

    def test_emailing_needs_a_credential(self):
        status, _ = self.call("POST", "/v1/email/backup", {})
        self.assertEqual(status, 401)
        self.assertEqual(self.sent, [])

    def test_emailing_an_uninvited_address_is_refused(self):
        status, body = self.call("POST", "/v1/email/backup", {"to": STRANGER},
                                 token=ROOT_TOKEN)
        self.assertEqual(status, 400)
        self.assertEqual(body["invited"], [OWNER])
        self.assertEqual(self.sent, [])

    def test_without_a_public_url_no_link_is_promised(self):
        sync_server.PUBLIC_URL = ""
        status, body = self.call("POST", "/v1/email/vault", {}, token=ROOT_TOKEN)
        self.assertEqual(status, 503)
        self.assertEqual(self.sent, [])
        self.assertEqual(len(sync_server.devices_of(sync_server.identity())), 0,
                         "a link that cannot be built must not mint a credential")

    # -- the gates themselves ---------------------------------------------

    def test_with_no_credential_anywhere_the_server_says_so(self):
        os.remove(self.token_path)
        sync_server.save_identity(sync_server.empty_identity())
        status, body = self.call("GET", "/v1/backup/status")
        self.assertEqual(status, 503)
        self.assertFalse(body["enabled"])

    def test_a_device_token_alone_is_enough_to_be_open_for_business(self):
        token = self.sign_in()
        os.remove(self.token_path)
        status, body = self.call("GET", "/v1/backup/status", token=token)
        self.assertEqual(status, 200, body)

    def test_a_guess_is_not_a_credential(self):
        self.sign_in()
        status, _ = self.call("GET", "/v1/backup/status", token="not-the-token")
        self.assertEqual(status, 401)

    # -- sealed product, and the set codes it is keyed by ------------------

    def test_every_game_the_app_tracks_has_a_price_category(self):
        # A game missing here has no sealed product this server can price, and
        # the app is told so rather than sold a box from another game.
        for game in ("mtg", "pokemon", "lorcana", "yugioh", "onepiece", "swu",
                     "digimon"):
            self.assertIn(game, sync_server.TCGCSV_CATEGORIES)
            self.assertIn(game, sync_server.GAME_LABELS)

    def test_a_set_code_is_matched_the_way_the_card_prints_it(self):
        # TCGplayer spells a Digimon set "BT-26" and the card prints "BT26-052";
        # the app stores the second, so the two have to be the same string here.
        self.assertEqual(sync_server._code_key("BT-26"), "bt26")
        self.assertEqual(sync_server._code_key("BT26"), "bt26")
        self.assertEqual(sync_server._code_key("OP18 RE"), "op18re")
        self.assertEqual(sync_server._code_key(""), "")
        self.assertEqual(sync_server._code_key(None), "")

        groups = [
            {"groupId": 24623, "abbreviation": "BT-26", "name": "Timeless Bonds"},
            {"groupId": 3188, "abbreviation": "OP01", "name": "Romance Dawn"},
            {"groupId": 9999, "abbreviation": "", "name": "Only A Name"},
        ]
        original = sync_server._tcgsv_groups
        sync_server._tcgsv_groups = lambda category: groups
        try:
            self.assertEqual(
                sync_server._group_for(63, "bt26")["groupId"], 24623
            )
            self.assertEqual(
                sync_server._group_for(68, "op01")["groupId"], 3188
            )
            # Some sets are only named, and a name still has to match exactly.
            self.assertEqual(
                sync_server._group_for(63, "Only A Name")["groupId"], 9999
            )
            self.assertIsNone(sync_server._group_for(63, "nothing"))
        finally:
            sync_server._tcgsv_groups = original

    def test_an_unknown_game_has_no_sealed_product(self):
        # The answer to a game this server does not price is None, not a guess.
        self.assertIsNone(sync_server.sealed_for("checkers", "op01"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
