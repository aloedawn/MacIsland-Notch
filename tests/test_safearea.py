"""Verify scene-settings notch policy across FBSMutableSceneSettings copy/mutableCopy."""

import json
import os
import platform
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
ISLAND_DIR = ROOT / "src/island"


@unittest.skipUnless(sys.platform == "darwin" and platform.machine() == "arm64", "requires Apple Silicon macOS")
class SafeAreaSettingsTests(unittest.TestCase):
    def test_scene_settings_preserve_and_restore_native_payloads_across_mutable_copy(self):
        with tempfile.TemporaryDirectory() as temp:
            executable = Path(temp) / "safearea-probe"
            subprocess.run(
                [
                    "/usr/bin/xcrun", "clang", "-target", "arm64e-apple-macos27.2",
                    "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                    "-DMACISLAND_TESTING",
                    "-I", str(ISLAND_DIR),
                    str(ISLAND_DIR / "safearea.m"),
                    str(HERE / "safearea-probe.m"),
                    "-framework", "AppKit",
                    "-o", str(executable),
                ],
                check=True,
            )
            result = subprocess.run([str(executable)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("safearea=ok", result.stdout)
            self.assertIn("activity_expanded=430@1.0x", result.stdout)
            self.assertIn("max_content_220=540", result.stdout)
            self.assertIn("restored_corners=nil", result.stdout)

            audit_log = Path(temp) / "scene-audit.jsonl"
            env = dict(os.environ, MACISLAND_AUDIT_LOG=str(audit_log))
            audited = subprocess.run([str(executable)], env=env, capture_output=True, text=True)
            self.assertEqual(audited.returncode, 0, audited.stdout + audited.stderr)
            records = [json.loads(line) for line in audit_log.read_text(encoding="utf-8").splitlines() if line.strip()]
            self.assertTrue(any(
                r.get("client") == "com.apple.ClockAngel"
                and r.get("elementKind") == "timer"
                and r.get("layoutMode") == "expanded"
                and r.get("patched", {}).get("applied") is True
                and (r.get("policy") or {}).get("shortHeight") == 0
                for r in records
            ))
            self.assertTrue(any(
                r.get("client") == "com.apple.chrono.WidgetRenderer-Activities"
                and r.get("layoutMode") == "expanded"
                and ((r.get("patched") or {}).get("activityMetrics") or {}).get("applied") is True
                and ((r.get("patched") or {}).get("activityMetrics") or {}).get("expandedMaxWidth") == 430
                and ((r.get("patched") or {}).get("activityMetrics") or {}).get("expandedScale") == 1
                for r in records
            ))
            self.assertTrue(any(
                r.get("client") == "com.apple.MediaRemoteUIService"
                and ((r.get("native") or {}).get("max") or {}).get("w") == "inf"
                for r in records
            ))
            self.assertTrue(any(
                r.get("client") == "com.apple.MediaRemoteUIService"
                and r.get("layoutMode") == "minimal"
                and r.get("patched", {}).get("applied") is False
                for r in records
            ))


if __name__ == "__main__":
    unittest.main()
