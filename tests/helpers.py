"""Shared test helpers for build gates, loader loading, and SDK discovery."""

from pathlib import Path
import subprocess
import sys
import types


ROOT = Path(__file__).resolve().parents[1]
LOADER_PATH = ROOT / "src/loader/loader.py"


def load_loader_module():
    module = types.ModuleType("embedded_loader")
    source = LOADER_PATH.read_text(encoding="utf-8")
    exec(compile(source, str(LOADER_PATH), "exec"), module.__dict__)
    return module


SUPPORTED_BUILDS = load_loader_module().SUPPORTED_BUILDS


def current_build() -> str:
    if sys.platform != "darwin":
        return ""
    return subprocess.run(
        ["/usr/sbin/sysctl", "-n", "kern.osversion"],
        capture_output=True,
        text=True,
    ).stdout.strip()


def write_supported_builds_header(directory: Path) -> Path:
    loader = load_loader_module()
    header = directory / "supported-builds.h"
    header.write_text(loader.format_supported_builds_header(), encoding="utf-8")
    return header


def macosx_sdk_path() -> str:
    return subprocess.check_output(
        ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"],
        text=True,
    ).strip()
