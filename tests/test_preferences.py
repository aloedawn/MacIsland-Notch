"""Exercise the preference bridge in isolated native containers."""

import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "install.sh"
MODULAR_SOURCE = (ROOT / "src/installer/preferences.js").read_text(encoding="utf-8")
EMBEDDED_SOURCE = SCRIPT.read_text(encoding="utf-8").split("<<'MACISLAND_PREFERENCES_JS'\n", 1)[1].split(
    "\nMACISLAND_PREFERENCES_JS", 1
)[0]


def replace_exact(source: str, old: str, new: str) -> str:
    count = source.count(old)
    if count != 1:
        raise AssertionError(f"Expected 1 occurrence of {old!r}, found {count}")
    return source.replace(old, new, 1)


@unittest.skipUnless(sys.platform == "darwin", "Requires macOS Foundation and JXA")
class PreferenceTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        root = Path(self.scratch.name)
        self.home = root / "home"
        self.group = self.home / "Library/Group Containers/com.apple.MenuBar"
        self.campo = root / "campo"
        self.domain = str(self.group / "Library/Preferences/com.apple.MenuBar")
        self.plist = Path(self.domain + ".plist")
        self.plist.parent.mkdir(parents=True)
        self.plist.write_bytes(plistlib.dumps({"UnrelatedValue": "preserve me"}))
        # Redirect both native preference stores; never change the user's HOME
        # or open their real app group or campo preferences during these tests.
        source = replace_exact(
            MODULAR_SOURCE,
            "$.NSHomeDirectory().stringByAppendingPathComponent('Library/Preferences/com.apple.campo.plist')",
            f"$({json.dumps(str(self.campo / 'Library/Preferences/com.apple.campo.plist'))})",
        )
        source = replace_exact(
            source,
            "$.NSHomeDirectory()",
            f"$({json.dumps(str(self.home))})",
        )
        source = replace_exact(
            source,
            "defaults = $.NSUserDefaults.alloc.initWithSuiteName(domain);",
            "defaults = $.NSUserDefaults.alloc._initWithSuiteNameContainer(domain, "
            f"$.NSURL.fileURLWithPathIsDirectory($({json.dumps(str(self.campo))}), true));",
        )
        self.assertNotIn(str(Path.home()), source)
        self.helper = root / "preferences.js"
        self.helper.write_text(source, encoding="utf-8")

    def invoke(self, domain, key, saved=None, *, required=True):
        args = ["/usr/bin/osascript", "-l", "JavaScript", str(self.helper), domain, key]
        if saved is not None:
            args.append(json.dumps(saved))
        result = subprocess.run(args, capture_output=True, text=True)
        if required:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0)
        return result.stderr

    def test_embedded_preferences_matches_modular_source(self):
        self.assertEqual(MODULAR_SOURCE.rstrip("\n"), EMBEDDED_SOURCE.rstrip("\n"))

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

    def test_fresh_profile_without_preferences_directory_reads_absent_and_creates_on_write(self):
        self.plist.unlink()
        self.plist.parent.rmdir()
        (self.group / "Library").rmdir()
        self.group.rmdir()
        key = "EmulateCenterHUD"
        self.assertEqual(self.invoke(self.domain, key), {"present": False})
        saved = {"present": True, "value": True}
        self.assertEqual(self.invoke(self.domain, key, saved), saved)
        self.assertEqual(self.invoke(self.domain, key), saved)
        self.assertEqual(self.invoke(self.domain, key, {"present": False}), {"present": False})

    def test_unreadable_ancestor_directory_fails_instead_of_reporting_absent(self):
        self.plist.unlink()
        self.plist.parent.rmdir()
        self.group.chmod(0o000)
        self.addCleanup(lambda: self.group.chmod(0o700))
        stderr = self.invoke(self.domain, "EmulateCenterHUD", required=False)
        self.assertIn("Cannot access the preference directory", stderr)

    def test_existing_non_json_target_value_fails_cleanly(self):
        fixture = b'''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>EmulateCenterHUD</key><date>2026-01-01T00:00:00Z</date>
</dict></plist>'''
        self.plist.write_bytes(fixture)
        stderr = self.invoke(self.domain, "EmulateCenterHUD", required=False)
        self.assertIn("Unsupported existing preference type", stderr)

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

    def test_missing_and_unreadable_group_plists_are_distinct(self):
        key = "EmulateCenterHUD"
        self.plist.unlink()
        self.assertEqual(self.invoke(self.domain, key), {"present": False})
        self.plist.write_text("invalid plist", encoding="utf-8")
        self.invoke(self.domain, key, required=False)

    def test_registered_fallback_is_not_backed_up_or_restored(self):
        source = self.helper.read_text(encoding="utf-8")
        self.helper.write_text(
            replace_exact(
                source,
                "    if (args.length === 3) {",
                """    var fallback = $.NSMutableDictionary.dictionary;
    fallback.setObjectForKey($("registered"), key);
    defaults.registerDefaults(fallback);
    if (args.length === 3) {""",
            ),
            encoding="utf-8",
        )
        key = "EmulateCenterHUD"
        missing = {"present": False}
        stored = {"present": True, "value": True}
        self.assertEqual(self.invoke(self.domain, key), missing)
        self.assertEqual(self.invoke(self.domain, key, stored), stored)
        self.assertEqual(self.invoke(self.domain, key, missing), missing)
        self.assertEqual(self.invoke(self.domain, key), missing)

    def test_invalid_saved_values_do_not_overwrite_the_existing_value(self):
        key = "ShowSoftwareNotch"
        saved = {"present": True, "value": False}
        self.invoke(self.domain, key, saved)
        for invalid in (
            {"present": "yes", "value": True},
            {"present": True, "value": []},
            {"present": True, "value": None},
            ["not", "a", "dict"],
        ):
            with self.subTest(invalid=invalid):
                self.invoke(self.domain, key, invalid, required=False)
                self.assertEqual(self.invoke(self.domain, key), saved)


if __name__ == "__main__":
    unittest.main()
