"""Run the Siri AI patch against the real CampoUIInternal in an isolated test process."""

import platform
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from helpers import SUPPORTED_BUILDS, current_build, macosx_sdk_path, write_supported_builds_header

ROOT = HERE.parent
PROVIDERS = ROOT / "src/providers"
MODULAR_SPOTLIGHT = PROVIDERS / "spotlight.m"


class SpotlightSourceParityTests(unittest.TestCase):
    def test_embedded_spotlight_matches_modular_source(self):
        text = (ROOT / "install.sh").read_text(encoding="utf-8")
        embedded = text.split("<<'MACISLAND_SPOTLIGHT_M'\n", 1)[1].split("\nMACISLAND_SPOTLIGHT_M", 1)[0]
        self.assertEqual(MODULAR_SPOTLIGHT.read_text(encoding="utf-8").rstrip("\n"), embedded.rstrip("\n"))


@unittest.skipUnless(
    sys.platform == "darwin" and platform.machine() == "arm64"
    and current_build() in SUPPORTED_BUILDS,
    f"requires macOS 27.3 beta {' or '.join(SUPPORTED_BUILDS)}",
)
class SpotlightSupportTests(unittest.TestCase):
    def test_patch_selects_the_hardware_cutout_path_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temp:
            tmp = Path(temp)
            write_supported_builds_header(tmp)
            sdk = macosx_sdk_path()
            executable = tmp / "test-support"
            subprocess.run(
                [
                    "/usr/bin/xcrun", "clang", "-target", "arm64e-apple-macos27.2",
                    "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                    "-I", str(tmp),
                    "-I", str(PROVIDERS),
                    "-L", f"{sdk}/usr/lib/swift",
                    "-lswiftCore",
                    "-framework", "Foundation",
                    str(PROVIDERS / "provider-abi.c"),
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
