"""Exercise the loader and installer without restarting any desktop service."""

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


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "install.sh"
TEXT = SCRIPT.read_text(encoding="utf-8")
MODULAR_LOADER = (ROOT / "src/loader/loader.py").read_text(encoding="utf-8")
MODULAR_MANAGER = (ROOT / "src/installer/manager.py").read_text(encoding="utf-8")
EMBEDDED_LOADER = TEXT.split("<<'MACISLAND_LOADER_PY'\n", 1)[1].split("\nMACISLAND_LOADER_PY", 1)[0]
EMBEDDED_MANAGER = TEXT.split("<<'MACISLAND_MANAGER'\n", 1)[1].split("\nMACISLAND_MANAGER", 1)[0]

loader = types.ModuleType("embedded_loader")
exec(compile(MODULAR_LOADER, str(ROOT / "src/loader/loader.py"), "exec"), loader.__dict__)


class SourceParityTests(unittest.TestCase):
    def test_embedded_loader_and_manager_match_modular_sources(self):
        self.assertEqual(MODULAR_LOADER.rstrip("\n"), EMBEDDED_LOADER.rstrip("\n"))
        self.assertEqual(MODULAR_MANAGER.rstrip("\n"), EMBEDDED_MANAGER.rstrip("\n"))


class LaunchEnvironmentTests(unittest.TestCase):
    def test_prior_value_is_restored_after_launch_failure(self):
        domain = "\tenvironment = {\n\t\tDYLD_INSERT_LIBRARIES => /old.dylib\n\t}\n"
        with patch.object(loader.subprocess, "check_output", return_value=domain), \
             patch.object(loader.subprocess, "run") as run, \
             patch("sys.stdout", new=io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "launch failed"):
                with loader.temporary_launch_environment(Path("/new.dylib")):
                    raise RuntimeError("launch failed")
        self.assertEqual(run.call_args_list[-1].args[0],
                         [loader.LAUNCHCTL, "setenv", loader.ENVIRONMENT_KEY, "/old.dylib"])

    def test_duplicate_library_entry_is_not_appended_twice(self):
        domain = "\tenvironment = {\n\t\tDYLD_INSERT_LIBRARIES => /a.dylib:/new.dylib\n\t}\n"
        with patch.object(loader.subprocess, "check_output", return_value=domain), \
             patch.object(loader.subprocess, "run") as run, \
             patch("sys.stdout", new=io.StringIO()):
            with loader.temporary_launch_environment(Path("/new.dylib")):
                pass
        self.assertEqual(run.call_args_list[0].args[0],
                         [loader.LAUNCHCTL, "setenv", loader.ENVIRONMENT_KEY, "/a.dylib:/new.dylib"])

    def test_absent_variable_is_unset_after_success(self):
        with patch.object(loader.subprocess, "check_output",
                          return_value="\tenvironment = {\n\t}\n"), \
             patch.object(loader.subprocess, "run") as run, \
             patch("sys.stdout", new=io.StringIO()):
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

    def test_exiting_provider_during_pgrep_ps_race_returns_none(self):
        def run_cmd(argv, **kwargs):
            if argv[0] == "/usr/bin/pgrep":
                return subprocess.CompletedProcess(argv, 0, "444\n555\n", "")
            if argv[0] == "/bin/ps" and "444" in argv:
                return subprocess.CompletedProcess(argv, 1, "", "")
            if argv[0] == "/bin/ps" and "555" in argv:
                return subprocess.CompletedProcess(argv, 0, loader.MUSIC_EXE + "\n", "")
            raise AssertionError(argv)

        with patch.object(loader.subprocess, "run", side_effect=run_cmd):
            self.assertEqual(loader.music_pid(), "555")

    def test_is_traced_returns_false_when_process_exited(self):
        with patch.object(
            loader.subprocess,
            "check_output",
            side_effect=subprocess.CalledProcessError(1, ["/bin/ps"]),
        ):
            self.assertFalse(loader.is_traced(999))

    def prepare(self, statuses, *, enable_rc="0"):
        statuses = iter(statuses)

        def execute(argv, **kwargs):
            joined = " ".join(argv)
            value = next(statuses) if "mi_music_status" in joined else enable_rc
            return subprocess.CompletedProcess(argv, 0, f"(int) $0 = {value}\n", "")

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

    def test_dlopen_failure_and_missing_symbol_have_distinct_diagnostics(self):
        with self.assertRaisesRegex(RuntimeError, "Could not load notch-music.dylib"):
            self.prepare([], enable_rc="-101")
        with self.assertRaisesRegex(RuntimeError, "Symbol mi_music_enable is missing"):
            self.prepare([], enable_rc="-100")
        with self.assertRaisesRegex(RuntimeError, "rejected the build or bundle"):
            self.prepare([], enable_rc="-1")

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

    def test_music_only_and_providers_only_do_not_restart_menu_bar_agent(self):
        self.check_strategy("", traced=False, expected="music", argv=["--music-only"])
        self.check_strategy("", traced=False, expected="music", argv=["--providers-only"])

    def test_only_unpatched_providers_skips_already_patched_instances(self):
        with tempfile.TemporaryDirectory() as scratch:
            library = Path(scratch) / "island.dylib"
            library.touch()
            state = {"music": "77@t", "clock": "88@t", "spotlight": None}
            with patch.object(loader, "LIBRARY", str(library)), \
                 patch.object(loader, "require_supported_build"), \
                 patch.object(loader, "amfi_globally_disabled", return_value=False), \
                 patch.object(loader, "find_lldb", return_value="/test/lldb"), \
                 patch.object(loader.subprocess, "check_output", return_value="status: disabled"), \
                 patch.object(loader, "menu_bar_agent_pid", return_value=123), \
                 patch.object(loader, "is_traced", return_value=False), \
                 patch.object(loader, "music_pid", return_value="77"), \
                 patch.object(loader, "clock_pid", return_value="88"), \
                 patch.object(loader, "spotlight_pid", return_value=None), \
                 patch.object(loader, "process_identity", side_effect=lambda pid: pid and f"{pid}@t"), \
                 patch.object(loader, "prepare_music_safely") as prep_music, \
                 patch.object(loader, "prepare_background_safely", return_value=None) as prep_bg, \
                 patch.object(loader, "debugger_load", return_value=456):
                loader.inject(state, only_unpatched_providers=True, launch_music=False)
            prep_music.assert_not_called()
            self.assertEqual([call.args[2] for call in prep_bg.call_args_list], ["spotlight"])
            self.assertEqual(state["menubar"], "456@t")
            self.assertEqual(state["music"], "77@t")
            self.assertEqual(state["clock"], "88@t")

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
                 patch.object(loader, "clock_pid", return_value=None), \
                 patch.object(loader, "spotlight_pid", return_value=None), \
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
    def run_ensure(self, state, *, menubar="10@a", music=None, spotlight=None, build=None, music_library=False):
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
                     patch.object(loader, "clock_pid", return_value=None), \
                     patch.object(loader, "spotlight_pid", return_value="3"), \
                     patch.object(loader, "process_identity",
                                  side_effect=lambda pid: {1: menubar, "2": music, "3": spotlight}.get(pid)), \
                     patch.object(loader, "find_lldb", return_value="/test/lldb"), \
                     patch.object(loader, "inject") as inject, \
                     patch.object(loader, "prepare_music_safely", return_value="2") as prepare, \
                     patch.object(loader, "prepare_background_safely", return_value="3") as background, \
                     patch("sys.stdout", new=io.StringIO()), patch("sys.stderr", new=io.StringIO()):
                    loader.ensure()
                self.background = background
                return loader.load_state(), inject, prepare

    def test_patched_instance_is_left_alone(self):
        _, inject, prepare = self.run_ensure({"menubar": "10@a"})
        inject.assert_not_called()
        prepare.assert_not_called()

    def test_restarted_menu_bar_agent_is_patched_without_reattaching_patched_providers(self):
        state, inject, _ = self.run_ensure({"menubar": "9@old"})
        inject.assert_called_once_with(state, only_unpatched_providers=True, launch_music=False)
        self.assertEqual(len(state["menubar_attempts"]), 1)

    def test_restart_loop_is_paused(self):
        now = loader.time.time()
        state, inject, _ = self.run_ensure({"menubar": "9@old", "menubar_attempts": [now - 1] * 3})
        inject.assert_not_called()
        self.assertTrue(state["menubar_paused"])

    def test_old_attempts_and_idle_provider_pause_flags_expire(self):
        old = loader.time.time() - loader.REAPPLY_WINDOW - 1
        state, inject, _ = self.run_ensure({
            "menubar": "9@old",
            "menubar_attempts": [old] * 3,
            "music_attempts": [old] * 3,
            "music_paused": True,
        })
        inject.assert_called_once()
        self.assertNotIn("music_paused", state)
        self.assertNotIn("music_attempts", state)

    def test_restarted_music_provider_is_patched_without_menu_bar_restart(self):
        state, inject, prepare = self.run_ensure({"menubar": "10@a", "music": "1@old"},
                                                 music="2@b", music_library=True)
        inject.assert_not_called()
        prepare.assert_called_once()
        self.assertEqual(prepare.call_args.kwargs, {"launch": False})

    def test_new_spotlight_process_is_patched_once_without_restarting_the_menu_bar(self):
        state, inject, _ = self.run_ensure(
            {"menubar": "10@a", "spotlight": "3@old"}, spotlight="3@new", music_library=True)
        self.assertEqual(state["spotlight"], "3@new")
        self.background.assert_called_once()
        self.assertEqual(self.background.call_args.args[2], "spotlight")
        inject.assert_not_called()
        self.run_ensure(state, spotlight="3@new", music_library=True)
        self.background.assert_not_called()

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
            (self.source / name).write_text("new", encoding="utf-8")
        with patch.dict(os.environ, {"HOME": str(self.home)}), \
             patch("sys.argv", ["manager", "install", str(self.source)]):
            self.manager = types.ModuleType("embedded_manager")
            exec(compile(MODULAR_MANAGER, str(ROOT / "src/installer/manager.py"), "exec"),
                 self.manager.__dict__)
        self.calls = []
        self.spotlight_pid = None

        def run(*args, required=True):
            self.calls.append(args)
            if args[:2] == ("/bin/launchctl", "print"):
                output = f"\tpid = {self.spotlight_pid}\n".encode() if self.spotlight_pid else b""
                return subprocess.CompletedProcess(args, int(self.spotlight_pid is None), output, b"")
            return subprocess.CompletedProcess(args, 0, b"", b"")

        self.manager.run = run
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
            path.write_text("old", encoding="utf-8")
        m.BACKUP.mkdir()
        state = {"version": 1, "preferences": [], "auxiliary_existed": {},
                 "files": {name: {"existed": False, "mode": 0o644} for name in m.FILES}}
        m.STATE.write_bytes(plistlib.dumps(state))

    def test_failed_upgrade_returns_to_the_working_version_and_reruns_previous_loader(self):
        self.existing_install()
        m = self.manager
        (m.ROOT / "loader-state.json").write_text('{"menubar": "new"}', encoding="utf-8")
        original_preferences = dict(self.saved_preferences)
        sub_calls = []

        def fake_subprocess_run(argv, **kwargs):
            sub_calls.append((argv, kwargs.get("check")))
            if kwargs.get("check"):
                raise subprocess.CalledProcessError(1, argv)
            return subprocess.CompletedProcess(argv, 0, "", "")

        with patch.object(m.subprocess, "run", side_effect=fake_subprocess_run), \
             patch("sys.stderr", new=io.StringIO()), \
             self.assertRaises(subprocess.CalledProcessError):
            m.install()
        self.assertEqual((m.ROOT / "island.dylib").read_text(encoding="utf-8"), "old")
        self.assertEqual(m.AGENT.read_text(encoding="utf-8"), "old")
        self.assertFalse((m.ROOT / "loader-state.json").exists())
        self.assertEqual(sub_calls[-1], (["/usr/bin/python3", str(m.ROOT / "loader.py")], False))
        self.assertEqual(self.saved_preferences, original_preferences)
        self.assertTrue(m.STATE.is_file(), "the original backup must survive a failed upgrade")
        self.assertIn(("/bin/launchctl", "bootstrap", m.DOMAIN, str(m.AGENT)), self.calls)
        self.assertFalse(any(args[-1].endswith("/com.apple.campo") for args in self.calls))

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
        self.assertEqual((m.ROOT / "island.dylib").read_text(encoding="utf-8"), "new")
        # The periodic job is loaded only after the synchronous patch succeeded.
        self.assertEqual(self.calls[-2], ("/bin/launchctl", "bootstrap", m.DOMAIN, str(m.AGENT)))
        self.assertEqual(self.calls[-1], ("/bin/launchctl", "print", f"{m.DOMAIN}/com.apple.campo"))

    def test_successful_install_reloads_running_spotlight_after_menu_bar_setup(self):
        self.existing_install()
        self.spotlight_pid = 4321
        m = self.manager
        with patch.object(m.subprocess, "run"), patch("sys.stdout", new=io.StringIO()):
            m.install()
        service = f"{m.DOMAIN}/com.apple.campo"
        self.assertEqual(self.calls[-4:], [
            ("/bin/launchctl", "bootstrap", m.DOMAIN, str(m.AGENT)),
            ("/bin/launchctl", "print", service),
            ("/bin/launchctl", "kickstart", "-k", service),
            ("/usr/bin/python3", str(m.ROOT / "loader.py"), "--ensure", "--wait"),
        ])

    def test_loaded_but_stopped_spotlight_is_not_started(self):
        m = self.manager
        state = subprocess.CompletedProcess([], 0, b"state = not running\n", b"")
        with patch.object(m, "run", return_value=state) as run:
            m.reload_running_spotlight()
        run.assert_called_once_with("/bin/launchctl", "print",
                                    f"{m.DOMAIN}/com.apple.campo", required=False)

    def test_failed_agent_setup_does_not_reload_spotlight(self):
        self.existing_install()
        self.spotlight_pid = 4321
        m = self.manager
        original_run = m.run

        def fail_bootstrap(*args, **kwargs):
            result = original_run(*args, **kwargs)
            if args[:2] == ("/bin/launchctl", "bootstrap") and kwargs.get("required", True):
                raise subprocess.CalledProcessError(1, args)
            return result

        with patch.object(m, "run", side_effect=fail_bootstrap), \
             patch.object(m.subprocess, "run"), patch("sys.stderr", new=io.StringIO()), \
             self.assertRaises(subprocess.CalledProcessError):
            m.install()
        self.assertEqual((m.ROOT / "island.dylib").read_text(encoding="utf-8"), "old")
        self.assertFalse(any(args[-1].endswith("/com.apple.campo") for args in self.calls))

    def test_spotlight_reload_failure_does_not_roll_back_a_successful_install(self):
        self.existing_install()
        self.spotlight_pid = 4321
        m = self.manager
        original_run = m.run

        def fail_reload(*args, **kwargs):
            result = original_run(*args, **kwargs)
            if args[:3] == ("/bin/launchctl", "kickstart", "-k"):
                raise subprocess.CalledProcessError(1, args)
            return result

        with patch.object(m, "run", side_effect=fail_reload), \
             patch.object(m.subprocess, "run"), patch("sys.stdout", new=io.StringIO()), \
             patch("sys.stderr", new=io.StringIO()) as stderr:
            m.install()
        self.assertIn("Could not reload Spotlight", stderr.getvalue())
        self.assertEqual((m.ROOT / "island.dylib").read_text(encoding="utf-8"), "new")
        self.assertTrue(m.AGENT.is_file())
        self.assertTrue(m.STATE.is_file())

    def test_removal_stops_periodic_check_prefers_staged_loader_and_survives_stop_failure(self):
        self.existing_install()
        m = self.manager
        original_run = m.run

        def fail_stop_music(*args, **kwargs):
            self.calls.append(args)
            if args[-1] == "--stop-music":
                self.assertFalse(kwargs.get("required", True))
                return subprocess.CompletedProcess(args, 1, b"", b"stop failed")
            return original_run(*args, **kwargs)

        with patch.object(m, "run", side_effect=fail_stop_music):
            state = plistlib.loads(m.STATE.read_bytes())
            m.restore_original(state)
        self.assertEqual(self.calls[0], ("/bin/launchctl", "bootout", m.DOMAIN, str(m.AGENT)))
        self.assertIn(("/usr/bin/python3", str(self.source / "loader.py"), "--stop-music"), self.calls)
        self.assertFalse(m.BACKUP.exists())

    def test_backup_and_restore_preserve_preexisting_symlinks(self):
        m = self.manager
        m.ROOT.mkdir(parents=True)
        m.AGENT.parent.mkdir(parents=True)
        external_target = Path(self.tmp.name) / "external-island.dylib"
        external_target.write_text("external", encoding="utf-8")
        external_target.chmod(0o600)
        (m.ROOT / "island.dylib").symlink_to(external_target)
        state = m.save_original()
        self.assertTrue((m.BACKUP / "island.dylib").is_symlink())
        m.replace_file(self.source / "island.dylib", m.ROOT / "island.dylib", 0o755)
        self.assertFalse((m.ROOT / "island.dylib").is_symlink())
        self.assertEqual(external_target.read_text(encoding="utf-8"), "external")
        m.restore_original(state)
        self.assertTrue((m.ROOT / "island.dylib").is_symlink())
        self.assertEqual(os.readlink(m.ROOT / "island.dylib"), str(external_target))
        self.assertEqual(external_target.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
