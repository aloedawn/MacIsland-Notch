"""Exercise the embedded loader without restarting any desktop service."""

from contextlib import nullcontext
import io
from pathlib import Path
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "install.sh"
START = '  cat > "$SCRATCH/loader.py" <<\'MACISLAND_LOADER_PY\'\n'
SOURCE = SCRIPT.read_text().split(START, 1)[1].split("\nMACISLAND_LOADER_PY", 1)[0]
loader = types.ModuleType("embedded_loader")
exec(compile(SOURCE, "embedded_loader.py", "exec"), loader.__dict__)


class LaunchEnvironmentTests(unittest.TestCase):
    def test_prior_value_is_restored_after_launch_failure(self):
        domain = "\tenvironment = {\n\t\tDYLD_INSERT_LIBRARIES => /old.dylib\n\t}\n"
        with patch.object(loader.subprocess, "check_output", return_value=domain), \
             patch.object(loader.subprocess, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "launch failed"):
                with loader.temporary_launch_environment(Path("/new.dylib")):
                    raise RuntimeError("launch failed")
        self.assertEqual(run.call_args_list[-1].args[0],
                         [loader.LAUNCHCTL, "setenv", loader.ENVIRONMENT_KEY, "/old.dylib"])

    def test_absent_variable_is_unset_after_success(self):
        with patch.object(loader.subprocess, "check_output",
                          return_value="\tenvironment = {\n\t}\n"), \
             patch.object(loader.subprocess, "run") as run:
            with loader.temporary_launch_environment(Path("/new.dylib")):
                pass
        self.assertEqual(run.call_args_list[-1].args[0],
                         [loader.LAUNCHCTL, "unsetenv", loader.ENVIRONMENT_KEY])

    def test_unreadable_prior_environment_does_not_change_it(self):
        with patch.object(loader.subprocess, "check_output", return_value="unexpected format"), \
             patch.object(loader.subprocess, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "prior launch environment"):
                with loader.temporary_launch_environment(Path("/new.dylib")):
                    self.fail("An unverified environment must not be changed")
        run.assert_not_called()


class DebuggerLoadingTests(unittest.TestCase):
    def run_candidate(self, command):
        with patch.object(loader, "temporary_launch_environment", return_value=nullcontext()), \
             patch.object(loader.subprocess, "run", side_effect=command) as run, \
             patch("sys.stdout", new=io.StringIO()):
            result = loader.debugger_load("gui/502/test.service", Path("/patch.dylib"), "/test/lldb")
        return result, run

    def test_success_requires_the_expected_library_mapping(self):
        def command(argv, **kwargs):
            if "-p" in argv:
                return subprocess.CompletedProcess(argv, 0, "123\n", "")
            if argv[0] == "/usr/bin/vmmap":
                return subprocess.CompletedProcess(argv, 0, "__TEXT /patch.dylib\n", "")
            return subprocess.CompletedProcess(argv, 0, "", "")

        pid, run = self.run_candidate(command)
        self.assertEqual(pid, 123)
        self.assertTrue(any(c.args[0][0] == "/usr/bin/vmmap" for c in run.call_args_list))
        self.assertFalse(any("SIGKILL" in c.args[0] for c in run.call_args_list))

    def test_debugger_failure_kills_suspended_process_and_restarts_normally(self):
        calls = []

        def command(argv, **kwargs):
            calls.append(argv)
            if "-p" in argv:
                return subprocess.CompletedProcess(argv, 0, "123\n", "")
            if argv[0] == "/test/lldb":
                raise subprocess.CalledProcessError(1, argv, stderr="attach denied")
            return subprocess.CompletedProcess(argv, 0, "", "")

        with self.assertRaises(subprocess.CalledProcessError):
            self.run_candidate(command)
        self.assertEqual(calls[-2:], [
            [loader.LAUNCHCTL, "kill", "SIGKILL", "gui/502/test.service"],
            [loader.LAUNCHCTL, "kickstart", "gui/502/test.service"],
        ])

    def test_running_pid_without_library_mapping_is_failure(self):
        calls = []

        def command(argv, **kwargs):
            calls.append(argv)
            output = "123\n" if "-p" in argv else ""
            return subprocess.CompletedProcess(argv, 0, output, "")

        with patch.object(loader.time, "monotonic", side_effect=[0, 0, 31]), \
             patch.object(loader.time, "sleep"), \
             self.assertRaisesRegex(RuntimeError, "not verified"):
            self.run_candidate(command)
        self.assertEqual(calls[-1], [loader.LAUNCHCTL, "kickstart", "gui/502/test.service"])


class StrategyTests(unittest.TestCase):
    def test_no_amfi_flag_uses_debugger_strategy(self):
        self.check_strategy("", traced=False, expected="debugger")

    def test_existing_amfi_disabled_boot_keeps_legacy_strategy(self):
        self.check_strategy("other=1 amfi_get_out_of_my_way=0x1", traced=False, expected="legacy")

    def test_existing_debugger_prevents_a_restart(self):
        self.check_strategy("", traced=True, expected="blocked")

    def check_strategy(self, boot_arguments, *, traced, expected):
        def output(argv, **kwargs):
            if argv[0] == "/usr/bin/xcrun":
                return "/test/lldb\n"
            if argv[0] == "/usr/bin/csrutil":
                return "System Integrity Protection status: disabled.\n"
            if argv[0] == "/bin/ps":
                return "00000800\n" if traced else "00000000\n"
            raise AssertionError(argv)

        with tempfile.TemporaryDirectory() as scratch:
            library = Path(scratch) / "island.dylib"
            library.touch()
            with patch("sys.argv", ["loader.py"]), \
                 patch.object(loader, "LIBRARY", str(library)), \
                 patch.object(loader, "current_boot_arguments", return_value=boot_arguments), \
                 patch.object(loader.subprocess, "check_output", side_effect=output), \
                 patch.object(loader, "menu_bar_agent_pid", return_value=123), \
                 patch.object(loader, "debugger_load") as debugger, \
                 patch.object(loader, "legacy_main") as legacy:
                if expected == "blocked":
                    with self.assertRaisesRegex(RuntimeError, "being debugged"):
                        loader.main()
                else:
                    loader.main()
        self.assertEqual(debugger.call_count, int(expected == "debugger"))
        self.assertEqual(legacy.call_count, int(expected == "legacy"))


if __name__ == "__main__":
    unittest.main()
