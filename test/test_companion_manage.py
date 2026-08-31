#!/usr/bin/env python3

import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
MANAGE_FILE = ROOT / "browser-companion" / "native" / "manage"
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("mclovin_companion_manage", str(MANAGE_FILE))
spec = importlib.util.spec_from_loader(loader.name, loader)
manage = importlib.util.module_from_spec(spec)
loader.exec_module(manage)


class CompanionManageTest(unittest.TestCase):
    def test_install_status_handshake_and_uninstall(self):
        with tempfile.TemporaryDirectory() as temporary:
            config_home = Path(temporary) / "config"
            state_home = Path(temporary) / "state"
            (config_home / "chromium").mkdir(parents=True)

            environment = {
                "XDG_CONFIG_HOME": str(config_home),
                "XDG_STATE_HOME": str(state_home),
            }
            with mock.patch.dict(os.environ, environment):
                self.assertEqual(manage.install([]), ["chromium"])
                installed = manage.status()
                self.assertEqual(installed["registeredBrowsers"], ["chromium"])
                self.assertFalse(installed["connected"])

                state = {
                    "version": 1,
                    "extensionId": manage.EXTENSION_ID,
                    "extensionVersion": "0.1.0",
                    "lastSeen": "2026-08-27T12:00:00Z",
                }
                manage.write_json(manage.state_path(), state)
                self.assertTrue(manage.status()["connected"])

                self.assertEqual(manage.uninstall([]), ["chromium"])
                removed = manage.status()
                self.assertEqual(removed["registeredBrowsers"], [])
                self.assertFalse(removed["connected"])
                self.assertFalse(manage.state_path().exists())

    def test_manifest_allows_only_the_stable_extension_origin(self):
        manifest = manage.host_manifest()
        self.assertEqual(
            manifest["allowed_origins"],
            [f"chrome-extension://{manage.EXTENSION_ID}/"],
        )
        self.assertTrue(Path(manifest["path"]).is_absolute())



class LoadExtensionTest(unittest.TestCase):
    """The --load-extension list belongs to the user, and Omarchy is on it too."""

    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        self.config = Path(self.home.name) / ".config"
        (self.config / "BraveSoftware" / "Brave-Browser").mkdir(parents=True)
        self.flags = self.config / "brave-flags.conf"
        self.env = mock.patch.dict(os.environ, {
            "HOME": self.home.name,
            "XDG_CONFIG_HOME": str(self.config),
        })
        self.env.start()
        self.addCleanup(self.env.stop)
        self.extension = str(manage.extension_path())

    def test_appends_without_disturbing_other_extensions(self):
        self.flags.write_text(
            "--ozone-platform=wayland\n"
            "--load-extension=/opt/omarchy/copy-url,/opt/omarchy/yt-dlp\n"
            "--password-store=gnome-libsecret\n",
            encoding="utf-8",
        )
        self.assertTrue(manage.load_extension("brave"))
        line = [l for l in self.flags.read_text().splitlines()
                if l.startswith("--load-extension=")][0]
        self.assertEqual(
            line.split("=", 1)[1].split(","),
            ["/opt/omarchy/copy-url", "/opt/omarchy/yt-dlp", self.extension],
        )
        # Every other flag survives, in place.
        self.assertIn("--ozone-platform=wayland", self.flags.read_text())
        self.assertIn("--password-store=gnome-libsecret", self.flags.read_text())

    def test_is_idempotent(self):
        self.flags.write_text("--load-extension=/opt/omarchy/yt-dlp\n", encoding="utf-8")
        self.assertTrue(manage.load_extension("brave"))
        self.assertFalse(manage.load_extension("brave"), "a second install must change nothing")
        self.assertEqual(self.flags.read_text().count(self.extension), 1)

    def test_creates_the_line_when_there_is_none(self):
        self.flags.write_text("--ozone-platform=wayland\n", encoding="utf-8")
        manage.load_extension("brave")
        self.assertIn("--load-extension=" + self.extension, self.flags.read_text())

    def test_removes_only_our_own_path(self):
        self.flags.write_text(
            "--load-extension=/opt/omarchy/copy-url," + self.extension + ",/opt/omarchy/yt-dlp\n",
            encoding="utf-8",
        )
        self.assertTrue(manage.unload_extension("brave"))
        line = [l for l in self.flags.read_text().splitlines()
                if l.startswith("--load-extension=")][0]
        self.assertEqual(
            line.split("=", 1)[1].split(","),
            ["/opt/omarchy/copy-url", "/opt/omarchy/yt-dlp"],
        )
        self.assertFalse(manage.unload_extension("brave"), "removing twice must be a no-op")

    def test_drops_the_line_rather_than_leaving_it_empty(self):
        # A browser given `--load-extension=` with nothing after it refuses to start.
        self.flags.write_text("--load-extension=" + self.extension + "\n", encoding="utf-8")
        manage.unload_extension("brave")
        self.assertNotIn("--load-extension", self.flags.read_text())

    def test_a_missing_flags_file_is_not_an_error(self):
        self.assertFalse(manage.extension_loaded("brave"))
        self.assertFalse(manage.unload_extension("brave"))
        self.assertTrue(manage.load_extension("brave"))
        self.assertTrue(manage.extension_loaded("brave"))


if __name__ == "__main__":
    unittest.main()
