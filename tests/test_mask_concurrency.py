"""Verify mask.m never deadlocks or throws KVO exceptions under concurrent CA commits and DisplayLink group flushes."""

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
class MaskConcurrencyTests(unittest.TestCase):
    def test_concurrent_main_commits_and_background_modifier_flushes_do_not_deadlock(self):
        with tempfile.TemporaryDirectory() as temp:
            executable = Path(temp) / "mask-concurrency-probe"
            subprocess.run(
                [
                    "/usr/bin/xcrun", "clang", "-target", "arm64e-apple-macos27.2",
                    "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                    "-DMACISLAND_TESTING",
                    "-I", str(ISLAND_DIR),
                    str(ISLAND_DIR / "mask.m"),
                    str(HERE / "mask-concurrency-probe.m"),
                    "-framework", "AppKit",
                    "-framework", "QuartzCore",
                    "-o", str(executable),
                ],
                check=True,
            )
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("mask_concurrency=ok", result.stdout)


if __name__ == "__main__":
    unittest.main()
