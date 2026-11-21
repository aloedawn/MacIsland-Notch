"""Verify top-edge click-gap underlays, filter stripping, and event forwarding."""

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
class TopHitTests(unittest.TestCase):
    def test_top_edge_underlay_strips_and_event_forwarding(self):
        with tempfile.TemporaryDirectory() as temp:
            executable = Path(temp) / "top-hit-probe"
            subprocess.run(
                [
                    "/usr/bin/xcrun", "clang", "-target", "arm64e-apple-macos27.2",
                    "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                    "-DMACISLAND_TESTING",
                    "-I", str(ISLAND_DIR),
                    str(ISLAND_DIR / "mask-geometry.m"),
                    str(ISLAND_DIR / "mask-modifiers.m"),
                    str(ISLAND_DIR / "mask.m"),
                    str(ISLAND_DIR / "top-hit.m"),
                    str(HERE / "top-hit-probe.m"),
                    "-framework", "AppKit",
                    "-framework", "QuartzCore",
                    "-o", str(executable),
                ],
                check=True,
            )
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("top_hit=ok", result.stdout)
            self.assertIn("redirects=3", result.stdout)


if __name__ == "__main__":
    unittest.main()
