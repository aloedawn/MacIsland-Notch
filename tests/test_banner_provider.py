"""Verify ControlCenter CenterHUDBannerContainer hook and battery banner width logic."""

import platform
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from helpers import SUPPORTED_BUILDS, current_build, write_supported_builds_header

ROOT = HERE.parent
PROVIDERS = ROOT / "src/providers"
BANNER_FW = "/System/Library/PrivateFrameworks/SystemBannerUI.framework/SystemBannerUI"


@unittest.skipUnless(
    sys.platform == "darwin"
    and platform.machine() == "arm64"
    and current_build() in SUPPORTED_BUILDS,
    f"requires macOS 27.3 beta {' or '.join(SUPPORTED_BUILDS)}",
)
class BannerProviderTests(unittest.TestCase):
    def test_banner_hook_and_frame_widening_walker(self):
        with tempfile.TemporaryDirectory() as temp:
            tmp = Path(temp)
            write_supported_builds_header(tmp)
            abi_o = tmp / "provider-abi.o"
            body_o = tmp / "provider-body.o"
            dylib = tmp / "banner-test.dylib"
            runner = tmp / "banner-runner.c"
            exe = tmp / "banner-runner"

            subprocess.run(
                [
                    "/usr/bin/xcrun", "clang", "-target", "arm64e-apple-macos27.2",
                    "-Wall", "-Wextra", "-Werror", "-DMACISLAND_TESTING",
                    "-I", str(tmp),
                    "-c", str(PROVIDERS / "provider-abi.c"), "-o", str(abi_o),
                ],
                check=True,
            )
            subprocess.run(
                [
                    "/usr/bin/xcrun", "clang", "-target", "arm64e-apple-macos27.2",
                    "-c", str(PROVIDERS / "provider-body.S"), "-o", str(body_o),
                ],
                check=True,
            )
            subprocess.run(
                [
                    "/usr/bin/xcrun", "swiftc", "-target", "arm64e-apple-macos27.2",
                    "-module-name", "MacIslandBannerTest",
                    "-module-cache-path", str(tmp / "swift-modules"),
                    "-DMACISLAND_TESTING", "-O", "-emit-library",
                    str(PROVIDERS / "witness.swift"),
                    str(PROVIDERS / "music.swift"),
                    str(PROVIDERS / "music-layout.swift"),
                    str(PROVIDERS / "clock.swift"),
                    str(PROVIDERS / "banner.swift"),
                    str(abi_o), str(body_o),
                    "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup",
                    "-o", str(dylib),
                ],
                check=True,
            )

            runner.write_text(
                f"""#include <dlfcn.h>
#include <stdio.h>
int main(void) {{
    if (!dlopen("{BANNER_FW}", RTLD_LAZY)) {{
        fprintf(stderr, "dlopen SystemBannerUI failed: %s\\n", dlerror());
        return 1;
    }}
    void *h = dlopen("{dylib.as_posix()}", RTLD_NOW);
    if (!h) {{
        fprintf(stderr, "dlopen banner-test.dylib failed: %s\\n", dlerror());
        return 1;
    }}
    int (*self_test)(void) = (int (*)(void))dlsym(h, "mi_banner_self_test");
    if (!self_test) {{
        fprintf(stderr, "missing mi_banner_self_test\\n");
        return 1;
    }}
    int rc = self_test();
    printf("banner_self_test=%d\\n", rc);
    return rc == 1 ? 0 : 1;
}}
""",
                encoding="utf-8",
            )
            subprocess.run(
                [
                    "/usr/bin/xcrun", "clang", "-target", "arm64e-apple-macos27.2",
                    "-Wall", "-Wextra", "-Werror",
                    str(runner), "-o", str(exe),
                ],
                check=True,
            )
            result = subprocess.run([str(exe)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("banner_self_test=1", result.stdout)


if __name__ == "__main__":
    unittest.main()
