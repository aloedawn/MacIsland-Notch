"""Verify that root install.sh stays synchronized with modular sources under src/."""

import importlib.util
from pathlib import Path
import shutil
import subprocess
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
BUILDER_PATH = ROOT / "scripts/build_installer.py"
INSTALLER_PATH = ROOT / "install.sh"


def load_builder():
    spec = importlib.util.spec_from_file_location("build_installer", BUILDER_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class BundleTests(unittest.TestCase):
    def test_generated_installer_is_in_sync_with_modular_sources(self):
        builder = load_builder()
        self.assertEqual(builder.main(["--check"]), 0)

    def test_unembedded_source_file_is_rejected(self):
        builder = load_builder()
        extra = (ROOT / "src/island/unreferenced-extra.c").resolve()
        discovered = builder.discover_source_files() | {extra}
        with patch.object(builder, "discover_source_files", return_value=discovered):
            with self.assertRaisesRegex(RuntimeError, "Unembedded files under src/"):
                builder.render_installer()

    def test_bash_syntax_is_valid(self):
        result = subprocess.run(
            ["/bin/bash", "-n", str(INSTALLER_PATH)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(shutil.which("shellcheck"), "shellcheck is not installed")
    def test_shellcheck_passes_when_installed(self):
        result = subprocess.run(
            ["shellcheck", str(INSTALLER_PATH)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
