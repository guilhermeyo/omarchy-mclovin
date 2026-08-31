#!/usr/bin/env python3

import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
HOST_FILE = ROOT / "browser-companion" / "native" / "mclovin-native-host"
# Import the executable for unit tests without leaving Python cache artifacts
# inside the directory Chromium loads as an extension.
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("mclovin_native_host", str(HOST_FILE))
spec = importlib.util.spec_from_loader(loader.name, loader)
host = importlib.util.module_from_spec(spec)
loader.exec_module(host)


class NativeHostTest(unittest.TestCase):
    def test_accepts_only_numbered_zoom_meetings(self):
        self.assertTrue(host.zoom_meeting_url("https://zoom.us/j/123456789?pwd=secret"))
        self.assertTrue(host.zoom_meeting_url("https://app.zoom.us/wc/join/123-456-789"))
        self.assertFalse(host.zoom_meeting_url("https://zoom.us/my/room"))
        self.assertFalse(host.zoom_meeting_url("https://zoom.us.evil.test/j/123456789"))
        self.assertFalse(host.zoom_meeting_url("http://zoom.us/j/123456789"))

    def test_reads_and_writes_native_frames(self):
        request = json.dumps({"url": "https://zoom.us/j/123456789"}).encode()
        incoming = io.BytesIO(struct.pack("=I", len(request)) + request)
        self.assertEqual(host.read_message(incoming)["url"], "https://zoom.us/j/123456789")

        outgoing = io.BytesIO()
        host.write_message(outgoing, {"ok": True})
        outgoing.seek(0)
        self.assertEqual(host.read_message(outgoing), {"ok": True})

    def test_routes_only_ordinary_web_links(self):
        self.assertTrue(host.routable_url("https://wa.me/5511999999999?text=hi"))
        self.assertTrue(host.routable_url("http://example.test/page"))
        self.assertFalse(host.routable_url("mailto:someone@example.test"))
        self.assertFalse(host.routable_url("javascript:alert(1)"))
        self.assertFalse(host.routable_url("file:///etc/passwd"))
        self.assertFalse(host.routable_url("zoommtg://zoom.us/join?confno=1"))
        self.assertFalse(host.routable_url("https:///no-host"))
        self.assertFalse(host.routable_url("https://example.test/" + "a" * 9000))
        self.assertFalse(host.routable_url(None))

    def test_serves_only_rules_that_leave_the_browser(self):
        config = {
            "rules": [
                {"when": "contains", "terms": ["whatsapp.com", "wa.me"], "webapp": "WhatsApp"},
                {"when": "regex", "terms": ["^https://zoom\\.us/j/[0-9]+"], "action": "zoom"},
                {"when": "contains", "terms": ["spotify.com"], "command": "spotify {url}"},
                {"when": "contains", "terms": ["github.com"], "browser": "brave-browser"},
                {"when": "host", "terms": ["no-target.test"]},
                # Router migrates an absent matcher to `contains`, so this rule
                # routes and the host has to watch it.
                {"when": "", "terms": ["migrates.test"], "webapp": "X"},
                # The pre-form shapes. config.json on disk is whatever was last
                # written there, and nothing rewrites it until a rule is edited
                # through the form -- so a config older than the form still
                # carries these, and Router still reads them.
                {"match": ["legacy-plain.test"], "webapp": "X"},
                # Both spellings of the native-app action. Router reads each,
                # so a rule this file skips is one the panel says it is watching
                # and the extension is not -- which is what renaming the action
                # to `native` caused until this test existed.
                {"matchRegex": "^https://legacy-regex", "action": "zoom"},
                {"when": "host", "terms": ["native-action.test"], "action": "native"},
                # No terms at all: Router drops it, so the host must too.
                {"when": "host", "terms": [], "webapp": "X"},
                # An action Router does not define. It drops the rule entirely,
                # so watching for it would cancel clicks for a rule that is not
                # there.
                {"when": "host", "terms": ["unknown-action.test"], "action": "teleport"},
                "not a rule",
            ]
        }
        with tempfile.TemporaryDirectory() as config_home:
            destination = Path(config_home) / "omarchy-mclovin"
            destination.mkdir(parents=True)
            (destination / "config.json").write_text(json.dumps(config), encoding="utf-8")
            with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": config_home}):
                served = host.interceptable_rules()

        # Every rule Router would route by, in the same shape Router gives it.
        self.assertEqual(served[0], {"when": "contains", "terms": ["whatsapp.com", "wa.me"]})
        for rule in served:
            self.assertEqual(set(rule), {"when", "terms"})

        by_terms = {tuple(r["terms"]): r["when"] for r in served}
        self.assertEqual(by_terms[("migrates.test",)], "contains")
        self.assertEqual(by_terms[("legacy-plain.test",)], "contains")
        self.assertEqual(by_terms[("^https://legacy-regex",)], "regex")
        self.assertEqual(by_terms[("native-action.test",)], "host")
        self.assertNotIn(("unknown-action.test",), by_terms)
        self.assertEqual(len(served), 7)

        # A browser destination is never watched: clicking a link that is already
        # going to the browser you are reading in should navigate the tab.
        self.assertNotIn("github.com", [t for rule in served for t in rule["terms"]])

    def test_a_scalar_terms_value_is_one_term(self):
        # Router.termList treats a bare string as a single term. Iterating it
        # here would serve one matcher per character, and a one-character
        # `contains` matches nearly every URL on every page.
        matcher = host.normalized_matcher({"when": "contains", "terms": "whatsapp.com"})
        self.assertEqual(matcher, {"when": "contains", "terms": ["whatsapp.com"]})

    def test_missing_or_broken_config_watches_nothing(self):
        with tempfile.TemporaryDirectory() as config_home:
            with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": config_home}):
                self.assertEqual(host.interceptable_rules(), [])
                destination = Path(config_home) / "omarchy-mclovin"
                destination.mkdir(parents=True)
                (destination / "config.json").write_text("{ not json", encoding="utf-8")
                self.assertEqual(host.interceptable_rules(), [])

    def test_refuses_what_it_does_not_understand(self):
        with self.assertRaises(ValueError):
            host.handle_request({"type": "somethingElse"})
        with self.assertRaises(ValueError):
            host.handle_request({"type": "openUrl", "url": "javascript:alert(1)"})
        with self.assertRaises(ValueError):
            host.handle_request({"type": "openZoomDirectly", "url": "https://zoom.us/my/room"})
        with self.assertRaises(ValueError):
            host.handle_request("not an object")

    def test_status_handshake_records_only_local_connection_metadata(self):
        with tempfile.TemporaryDirectory() as state_home:
            with mock.patch.dict(os.environ, {"XDG_STATE_HOME": state_home}):
                response = host.handle_request({"type": "status", "version": "0.1.0"})
                self.assertTrue(response["ok"])
                state = json.loads(host.state_path().read_text(encoding="utf-8"))

        self.assertEqual(state["extensionId"], host.EXTENSION_ID)
        self.assertEqual(state["extensionVersion"], "0.1.0")
        self.assertNotIn("url", state)


if __name__ == "__main__":
    unittest.main()
