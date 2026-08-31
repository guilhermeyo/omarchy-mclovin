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


if __name__ == "__main__":
    unittest.main()
