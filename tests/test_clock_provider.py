"""Verify ClockAngel witness patching and IntegratedObstruction_V1 host sizing."""

import platform
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
PROVIDERS = ROOT / "src/providers"
CLOCK_EXE = "/System/Library/CoreServices/ClockAngel.app/Contents/MacOS/ClockAngel"


def current_build():
    return subprocess.run(
        ["/usr/sbin/sysctl", "-n", "kern.osversion"],
        capture_output=True,
        text=True,
    ).stdout.strip()


@unittest.skipUnless(
    sys.platform == "darwin"
    and platform.machine() == "arm64"
    and current_build() == "26C5035r",
    "requires macOS 27.3 beta 26C5035r",
)
class ClockProviderTests(unittest.TestCase):
    def test_clock_host_widens_from_integrated_obstruction_v1_when_legacy_rect_is_zero(self):
        with tempfile.TemporaryDirectory() as temp:
            tmp = Path(temp)
            abi_o = tmp / "provider-abi.o"
            body_o = tmp / "provider-body.o"
            dylib = tmp / "clock-test.dylib"
            runner = tmp / "clock-runner.c"
            exe = tmp / "clock-runner"

            subprocess.run(
                [
                    "/usr/bin/xcrun", "clang", "-target", "arm64e-apple-macos27.2",
                    "-Wall", "-Wextra", "-Werror", "-DMACISLAND_TESTING",
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
                    "-module-name", "MacIslandClockTest",
                    "-module-cache-path", str(tmp / "swift-modules"),
                    "-DMACISLAND_TESTING", "-O", "-emit-library",
                    str(PROVIDERS / "witness.swift"),
                    str(PROVIDERS / "music.swift"),
                    str(PROVIDERS / "music-layout.swift"),
                    str(PROVIDERS / "clock.swift"),
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
    if (!dlopen("{CLOCK_EXE}", RTLD_LAZY)) {{
        fprintf(stderr, "dlopen ClockAngel failed: %s\\n", dlerror());
        return 1;
    }}
    void *h = dlopen("{dylib.as_posix()}", RTLD_NOW);
    if (!h) {{
        fprintf(stderr, "dlopen clock-test.dylib failed: %s\\n", dlerror());
        return 1;
    }}
    int (*self_test)(void) = (int (*)(void))dlsym(h, "mi_clock_self_test");
    if (!self_test) {{
        fprintf(stderr, "missing mi_clock_self_test\\n");
        return 1;
    }}
    int rc = self_test();
    printf("clock_self_test=%d\\n", rc);
    return rc > 0 ? 0 : 1;
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
            self.assertRegex(result.stdout, r"clock_self_test=[12]\b")


if __name__ == "__main__":
    unittest.main()
