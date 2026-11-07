"""Exercise the embedded preference bridge in isolated native containers."""

import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "install.sh"
SOURCE = SCRIPT.read_text().split("<<'MACISLAND_PREFERENCES_JS'\n", 1)[1].split(
    "\nMACISLAND_PREFERENCES_JS", 1
)[0]


@unittest.skipUnless(sys.platform == "darwin", "Requires macOS Foundation and JXA")
class PreferenceTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        root = Path(self.scratch.name)
        home = root / "home"
        self.group = home / "Library/Group Containers/com.apple.MenuBar"
        self.campo = root / "campo"
        self.domain = str(self.group / "Library/Preferences/com.apple.MenuBar")
        self.plist = Path(self.domain + ".plist")
        self.plist.parent.mkdir(parents=True)
        self.plist.write_bytes(plistlib.dumps({"UnrelatedValue": "preserve me"}))
        # Redirect both native preference stores; never change the user's HOME
        # or open their real app group or campo preferences during these tests.
        source = SOURCE.replace("$.NSHomeDirectory()", f"$({json.dumps(str(home))})")
        source = source.replace(
            "$.NSUserDefaults.alloc.initWithSuiteName(domain)",
            "$.NSUserDefaults.alloc._initWithSuiteNameContainer(domain, "
            f"$.NSURL.fileURLWithPathIsDirectory($({json.dumps(str(self.campo))}), true))",
        )
        self.helper = root / "preferences.js"
        self.helper.write_text(source)

    def invoke(self, domain, key, saved=None, *, required=True):
        args = ["/usr/bin/osascript", "-l", "JavaScript", str(self.helper), domain, key]
        if saved is not None:
            args.append(json.dumps(saved))
        result = subprocess.run(args, capture_output=True, text=True)
        if required:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0)

    def test_group_roundtrip_preserves_types_false_absence_and_unrelated_keys(self):
        key = "EmulateCenterHUD"
        original = self.invoke(self.domain, key)
        self.assertEqual(original, {"present": False})
        for value in (True, False, 0, 42, 9223372036854775806, "", "restore me"):
            with self.subTest(value=value):
                saved = {"present": True, "value": value}
                self.assertEqual(self.invoke(self.domain, key, saved), saved)
                actual = self.invoke(self.domain, key)
                self.assertEqual(actual, saved)
                self.assertIs(type(actual["value"]), type(value))
        false_value = {"present": True, "value": False}
        self.invoke(self.domain, key, false_value)
        snapshot = self.invoke(self.domain, key)
        self.invoke(self.domain, key, {"present": True, "value": True})
        self.assertEqual(self.invoke(self.domain, key, snapshot), false_value)
        self.assertEqual(self.invoke(self.domain, key, original), original)
        self.assertEqual(plistlib.loads(self.plist.read_bytes()), {"UnrelatedValue": "preserve me"})

    def test_campo_reads_only_target_key_despite_unrelated_year_zero_date(self):
        preferences = self.campo / "Library/Preferences/com.apple.campo.plist"
        preferences.parent.mkdir(parents=True)
        fixture = b'''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>UnrelatedDate</key><date>0000-01-01T00:00:00Z</date>
<key>SupportsIslandMitosis</key><true/>
</dict></plist>'''
        preferences.write_bytes(fixture)
        with self.assertRaises(ValueError):
            plistlib.loads(fixture)
        self.assertEqual(
            self.invoke("com.apple.campo", "SupportsIslandMitosis"),
            {"present": True, "value": True},
        )

    def test_unrelated_domains_and_keys_are_refused(self):
        self.invoke(self.domain, "UnrelatedValue", required=False)
        self.invoke("com.apple.campo", "UnrelatedValue", required=False)
        self.invoke("unrelated.domain", "EmulateCenterHUD", required=False)
        self.assertEqual(plistlib.loads(self.plist.read_bytes()), {"UnrelatedValue": "preserve me"})

    def test_invalid_saved_values_do_not_overwrite_the_existing_value(self):
        key = "ShowSoftwareNotch"
        saved = {"present": True, "value": False}
        self.invoke(self.domain, key, saved)
        for invalid in (
            {"present": "yes", "value": True},
            {"present": True, "value": []},
            {"present": True, "value": None},
        ):
            with self.subTest(invalid=invalid):
                self.invoke(self.domain, key, invalid, required=False)
                self.assertEqual(self.invoke(self.domain, key), saved)


if __name__ == "__main__":
    unittest.main()
