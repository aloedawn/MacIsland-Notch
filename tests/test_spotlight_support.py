"""Run the Siri AI patch against the real CampoUIInternal in an isolated test process."""

import platform
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
MODULAR_SPOTLIGHT = ROOT / "src/providers/spotlight.m"


def current_build():
    return subprocess.run(["/usr/sbin/sysctl", "-n", "kern.osversion"],
                          capture_output=True, text=True).stdout.strip()


class SpotlightSourceParityTests(unittest.TestCase):
    def test_embedded_spotlight_matches_modular_source(self):
        text = (ROOT / "install.sh").read_text(encoding="utf-8")
        embedded = text.split("<<'MACISLAND_SPOTLIGHT_M'\n", 1)[1].split("\nMACISLAND_SPOTLIGHT_M", 1)[0]
        self.assertEqual(MODULAR_SPOTLIGHT.read_text(encoding="utf-8").rstrip("\n"), embedded.rstrip("\n"))


@unittest.skipUnless(sys.platform == "darwin" and platform.machine() == "arm64"
                     and current_build() == "26C5035r", "requires macOS 27.3 beta 26C5035r")
class SpotlightSupportTests(unittest.TestCase):
    def test_patch_selects_the_hardware_cutout_path_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temp:
            executable = Path(temp) / "test-support"
            subprocess.run(
                [
                    "/usr/bin/xcrun", "clang", "-target", "arm64e-apple-macos27.2",
                    "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                    "-I", str(MODULAR_SPOTLIGHT.parent),
                    "-framework", "Foundation",
                    str(HERE / "spotlight-support.m"),
                    "-o", str(executable),
                ],
                check=True,
            )
            result = subprocess.run([str(executable)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("patch=1 repeat=1 after=1", result.stdout)


if __name__ == "__main__":
    unittest.main()
