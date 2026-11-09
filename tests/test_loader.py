"""Exercise the embedded loader and installer without restarting any desktop service."""

from contextlib import nullcontext
import io
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "install.sh"
TEXT = SCRIPT.read_text()
START = '  cat > "$SCRATCH/loader.py" <<\'MACISLAND_LOADER_PY\'\n'
SOURCE = TEXT.split(START, 1)[1].split("\nMACISLAND_LOADER_PY", 1)[0]
MANAGER = TEXT.split("<<'MACISLAND_MANAGER'\n", 1)[1].split("\nMACISLAND_MANAGER", 1)[0]
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


class MusicProviderTests(unittest.TestCase):
    def test_unrelated_mapping_does_not_stop_the_provider(self):
        with patch.object(loader, "music_pid", return_value="123"), \
             patch.object(loader.subprocess, "check_output", return_value="__TEXT /other/notch-music.dylib"), \
             patch.object(loader.os, "kill") as kill:
            loader.stop_managed_music(Path("/managed/notch-music.dylib"))
        kill.assert_not_called()

    def prepare(self, statuses):
        statuses = iter(statuses)

        def execute(argv, **kwargs):
            status = next(statuses) if "mi_music_status" in " ".join(argv) else "0"
            return subprocess.CompletedProcess(argv, 0, f"(int) $0 = {status}\n", "")

        with tempfile.TemporaryDirectory() as tmp:
            library = Path(tmp) / "notch-music.dylib"
            library.touch()
            with patch.object(loader, "music_pid", return_value="123"), \
                 patch.object(loader, "available_music_pid"), \
                 patch.object(loader.subprocess, "check_output", return_value=loader.SUPPORTED_BUILD), \
                 patch.object(loader.subprocess, "run", side_effect=execute), \
                 patch.object(loader.time, "sleep"), \
                 patch("sys.stdout", new=io.StringIO()):
                return loader.prepare_music(library, "/test/lldb")

    def test_failed_witness_install_is_not_reported_as_ready(self):
        with self.assertRaisesRegex(RuntimeError, "state -6"):
            self.prepare(["-6"])

    def test_slow_provider_main_queue_is_awaited(self):
        self.assertEqual(self.prepare(["0", "0", "0", "1"]), "123")

    def test_provider_that_never_becomes_ready_fails(self):
        with self.assertRaisesRegex(RuntimeError, "state 0"):
            self.prepare(["0"] * len(loader.MUSIC_READY_DELAYS))

    def test_unsupported_build_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            library = Path(tmp) / "notch-music.dylib"
            library.touch()
            with patch.object(loader.subprocess, "check_output", return_value="99A999"), \
                 self.assertRaisesRegex(RuntimeError, "Unsupported OS build"):
                loader.prepare_music(library, "/test/lldb")

    def test_redirected_music_library_is_rejected_before_contacting_the_provider(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "other.dylib"
            target.touch()
            library = Path(tmp) / "notch-music.dylib"
            library.symlink_to(target)
            with patch.object(loader, "require_supported_build"), \
                 patch.object(loader, "music_pid") as provider, \
                 self.assertRaisesRegex(RuntimeError, "symbolic link"):
                loader.prepare_music(library, "/test/lldb")
            provider.assert_not_called()


class StrategyTests(unittest.TestCase):
    def test_no_amfi_flag_uses_debugger_strategy(self):
        self.check_strategy("", traced=False, expected="debugger")

    def test_existing_amfi_disabled_boot_keeps_legacy_strategy(self):
        self.check_strategy("other=1 amfi_get_out_of_my_way=0x1", traced=False, expected="legacy")

    def test_existing_debugger_prevents_a_restart(self):
        self.check_strategy("", traced=True, expected="blocked")

    def test_unsupported_build_leaves_service_unchanged(self):
        self.check_strategy("", traced=False, expected="unsupported", build="99A999")

    def test_music_failure_does_not_block_the_island(self):
        self.check_strategy("", traced=False, expected="debugger", music_error=True)

    def test_music_only_does_not_restart_menu_bar_agent(self):
        self.check_strategy("", traced=False, expected="music", argv=["--music-only"])

    def test_shared_writable_install_is_rejected_before_loading_either_patch(self):
        with tempfile.TemporaryDirectory() as scratch:
            directory = Path(scratch)
            library = directory / "island.dylib"
            library.touch()
            for writable in (directory, library):
                with self.subTest(writable=writable):
                    mode = writable.stat().st_mode & 0o777
                    writable.chmod(mode | 0o020)
                    try:
                        with patch.object(loader, "LIBRARY", str(library)), \
                             patch.object(loader, "require_supported_build"), \
                             patch.object(loader, "amfi_globally_disabled") as boot_args, \
                             self.assertRaisesRegex(RuntimeError, "group- or world-writable"):
                            loader.inject({})
                        boot_args.assert_not_called()
                    finally:
                        writable.chmod(mode)

    def check_strategy(self, boot_arguments, *, traced, expected, build=None,
                       music_error=False, argv=()):
        build = build or loader.SUPPORTED_BUILD

        def output(argv, **kwargs):
            if argv[0] == "/usr/bin/sw_vers":
                return build + "\n"
            if argv[0] == "/usr/bin/xcrun":
                return "/test/lldb\n"
            if argv[0] == "/usr/bin/csrutil":
                return "System Integrity Protection status: disabled.\n"
            if argv[0] == "/bin/ps":
                return "00000800\n" if traced else "00000000\n"
            raise AssertionError(argv)

        def music(*args, **kwargs):
            if music_error:
                raise RuntimeError("provider busy")
            return "77"

        with tempfile.TemporaryDirectory() as scratch:
            library = Path(scratch) / "island.dylib"
            library.touch()
            with patch("sys.argv", ["loader.py", *argv]), \
                 patch.object(loader, "LIBRARY", str(library)), \
                 patch.object(loader, "current_boot_arguments", return_value=boot_arguments), \
                 patch.object(loader.subprocess, "check_output", side_effect=output), \
                 patch.object(loader, "menu_bar_agent_pid", return_value=123), \
                 patch.object(loader, "process_identity", side_effect=lambda pid: pid and f"{pid}@t"), \
                 patch.object(loader, "prepare_music", side_effect=music) as prepare, \
                 patch.object(loader, "debugger_load", return_value=456) as debugger, \
                 patch.object(loader, "legacy_main", return_value=456) as legacy, \
                 patch("sys.stderr", new=io.StringIO()):
                if expected in ("blocked", "unsupported"):
                    pattern = "being debugged" if expected == "blocked" else "Unsupported OS build"
                    with self.assertRaisesRegex(RuntimeError, pattern):
                        loader.main()
                else:
                    loader.main()
                state = loader.load_state()
        self.assertEqual(debugger.call_count, int(expected == "debugger"))
        self.assertEqual(legacy.call_count, int(expected == "legacy"))
        if expected in ("debugger", "legacy"):
            self.assertEqual(state["menubar"], "456@t")
            self.assertEqual(state["music"], None if music_error else "77@t")
        if expected == "music":
            prepare.assert_called_once()
            self.assertEqual(state["music"], "77@t")


class EnsureTests(unittest.TestCase):
    def run_ensure(self, state, *, menubar="10@a", music=None, build=None, music_library=False):
        with tempfile.TemporaryDirectory() as scratch:
            library = Path(scratch) / "island.dylib"
            library.touch()
            if music_library:
                library.with_name("notch-music.dylib").touch()
            with patch.object(loader, "LIBRARY", str(library)):
                loader.save_state(state)
                with patch.object(loader, "current_build", return_value=build or loader.SUPPORTED_BUILD), \
                     patch.object(loader, "menu_bar_agent_pid", return_value=1), \
                     patch.object(loader, "music_pid", return_value="2"), \
                     patch.object(loader, "process_identity",
                                  side_effect=lambda pid: {1: menubar, "2": music}.get(pid)), \
                     patch.object(loader, "find_lldb", return_value="/test/lldb"), \
                     patch.object(loader, "inject") as inject, \
                     patch.object(loader, "prepare_music_safely", return_value="2") as prepare, \
                     patch("sys.stdout", new=io.StringIO()), patch("sys.stderr", new=io.StringIO()):
                    loader.ensure()
                return loader.load_state(), inject, prepare

    def test_patched_instance_is_left_alone(self):
        _, inject, prepare = self.run_ensure({"menubar": "10@a"})
        inject.assert_not_called()
        prepare.assert_not_called()

    def test_restarted_menu_bar_agent_is_patched_again(self):
        state, inject, _ = self.run_ensure({"menubar": "9@old"})
        inject.assert_called_once()
        self.assertEqual(len(state["menubar_attempts"]), 1)

    def test_restart_loop_is_paused(self):
        now = loader.time.time()
        state, inject, _ = self.run_ensure({"menubar": "9@old", "menubar_attempts": [now - 1] * 3})
        inject.assert_not_called()
        self.assertTrue(state["menubar_paused"])

    def test_old_attempts_expire(self):
        old = loader.time.time() - loader.REAPPLY_WINDOW - 1
        _, inject, _ = self.run_ensure({"menubar": "9@old", "menubar_attempts": [old] * 3})
        inject.assert_called_once()

    def test_restarted_music_provider_is_patched_without_menu_bar_restart(self):
        state, inject, prepare = self.run_ensure({"menubar": "10@a", "music": "1@old"},
                                                 music="2@b", music_library=True)
        inject.assert_not_called()
        prepare.assert_called_once()
        self.assertEqual(prepare.call_args.kwargs, {"launch": False})

    def test_unsupported_build_pauses_quietly(self):
        state, inject, _ = self.run_ensure({"menubar": "9@old"}, build="99A999")
        inject.assert_not_called()
        self.assertEqual(state["unsupported_build"], "99A999")

    def test_busy_lock_skips_the_check(self):
        with tempfile.TemporaryDirectory() as scratch:
            library = Path(scratch) / "island.dylib"
            library.touch()
            with patch.object(loader, "LIBRARY", str(library)), \
                 (library.parent / "loader.lock").open("a") as held:
                loader.fcntl.flock(held, loader.fcntl.LOCK_EX)
                with patch.object(loader, "ensure_locked") as locked:
                    loader.ensure()
                locked.assert_not_called()


class ManagerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name) / "home"
        self.source = Path(self.tmp.name) / "source"
        self.source.mkdir()
        for name in ("island.dylib", "loader.py", "notch-music.dylib"):
            (self.source / name).write_text("new")
        with patch.dict(os.environ, {"HOME": str(self.home)}), \
             patch("sys.argv", ["manager", "install", str(self.source)]):
            self.manager = types.ModuleType("embedded_manager")
            exec(compile(MANAGER, "embedded_manager.py", "exec"), self.manager.__dict__)
        self.calls = []
        self.manager.run = lambda *args, required=True: self.calls.append(args)
        self.saved_preferences = {
            (domain, key): {"present": False} for domain, key, _ in self.manager.PREFERENCES
        }
        self.manager.preference = lambda domain, key: self.saved_preferences[domain, key]
        def write_preference(domain, key, saved):
            self.saved_preferences[domain, key] = saved
        self.manager.write_preference = write_preference

    def tearDown(self):
        self.tmp.cleanup()

    def existing_install(self):
        m = self.manager
        m.ROOT.mkdir(parents=True)
        m.AGENT.parent.mkdir(parents=True)
        for path in (m.ROOT / "island.dylib", m.ROOT / "loader.py", m.MUSIC, m.AGENT):
            path.write_text("old")
        m.BACKUP.mkdir()
        state = {"version": 1, "preferences": [], "auxiliary_existed": {},
                 "files": {name: {"existed": False, "mode": 0o644} for name in m.FILES}}
        m.STATE.write_bytes(plistlib.dumps(state))

    def test_failed_upgrade_returns_to_the_working_version(self):
        self.existing_install()
        m = self.manager
        original_preferences = dict(self.saved_preferences)
        failure = subprocess.CalledProcessError(1, ["loader"])
        with patch.object(m.subprocess, "run", side_effect=failure), \
             patch("sys.stderr", new=io.StringIO()), \
             self.assertRaises(subprocess.CalledProcessError):
            m.install()
        self.assertEqual((m.ROOT / "island.dylib").read_text(), "old")
        self.assertEqual(m.AGENT.read_text(), "old")
        self.assertEqual(self.saved_preferences, original_preferences)
        self.assertTrue(m.STATE.is_file(), "the original backup must survive a failed upgrade")
        self.assertIn(("/bin/launchctl", "bootstrap", m.DOMAIN, str(m.AGENT)), self.calls)

    def test_successful_install_enables_the_periodic_check(self):
        self.existing_install()
        m = self.manager
        with patch.object(m.subprocess, "run") as run, patch("sys.stdout", new=io.StringIO()):
            m.install()
        run.assert_called_once()
        agent = plistlib.loads(m.AGENT.read_bytes())
        self.assertEqual(agent["ProgramArguments"][-1], "--ensure")
        self.assertTrue(agent["RunAtLoad"])
        self.assertEqual(agent["StartInterval"], m.CHECK_INTERVAL)
        self.assertEqual((m.ROOT / "island.dylib").read_text(), "new")
        # The periodic job is loaded only after the synchronous patch succeeded.
        self.assertEqual(self.calls[-1], ("/bin/launchctl", "bootstrap", m.DOMAIN, str(m.AGENT)))

    def test_removal_stops_the_periodic_check_before_the_music_layout(self):
        self.existing_install()
        m = self.manager
        state = plistlib.loads(m.STATE.read_bytes())
        m.restore_original(state)
        self.assertEqual(self.calls[0], ("/bin/launchctl", "bootout", m.DOMAIN, str(m.AGENT)))
        self.assertEqual(self.calls[1][-1], "--stop-music")
        self.assertFalse(m.BACKUP.exists())


if __name__ == "__main__":
    unittest.main()
