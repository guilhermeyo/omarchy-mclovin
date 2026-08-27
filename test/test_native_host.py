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
