"""Run the embedded Siri AI patch against the real CampoUIInternal in a test process."""
import platform
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def current_build():
    return subprocess.run(["/usr/sbin/sysctl", "-n", "kern.osversion"],
                          capture_output=True, text=True).stdout.strip()


@unittest.skipUnless(sys.platform == "darwin" and platform.machine() == "arm64"
                     and current_build() == "26C5035r", "requires macOS 27.3 beta 26C5035r")
class SpotlightSupportTests(unittest.TestCase):
    def test_patch_selects_the_hardware_cutout_path_only_where_requested(self):
        text = (HERE.parent / "install.sh").read_text()
        source = text.split("<<'MACISLAND_SPOTLIGHT_M'\n", 1)[1].split("\nMACISLAND_SPOTLIGHT_M", 1)[0]
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            (directory / "spotlight.m").write_text(source)
            executable = directory / "test-support"
            subprocess.run(["/usr/bin/xcrun", "clang", "-arch", "arm64e", "-fobjc-arc", "-Wall", "-Wextra",
                            "-Werror", "-I", temp, "-framework", "Foundation", str(HERE / "spotlight-support.m"),
                            "-o", str(executable)], check=True)
            result = subprocess.run([str(executable)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("patch=1 after=1", result.stdout)
