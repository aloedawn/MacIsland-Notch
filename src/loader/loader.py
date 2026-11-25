"""Inject the Dynamic Island interposer into MenuBarAgent and keep it applied."""

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import json
import os
from pathlib import Path
import re
import select
import signal
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any, Dict, List, Optional, Tuple


LAUNCHCTL = "/bin/launchctl"
SERVICE = f"gui/{os.getuid()}/com.apple.MenuBarAgent"
ENVIRONMENT_KEY = "DYLD_INSERT_LIBRARIES"
LIBRARY = str(Path.home() / "Library/MacIsland/island.dylib")
ALLOW_UNVERIFIED_ENV = "MACISLAND_ALLOW_UNVERIFIED_BUILD"
# Single source of truth for verified OS builds. Every native hook resolves
# symbols and verifies layouts at runtime; this list gates checked builds.
SUPPORTED_BUILDS = ("26C5035r", "26C5047e")
SUPPORTED_BUILD = SUPPORTED_BUILDS[0]
MUSIC_EXE = "/System/Library/CoreServices/MediaRemoteUIService.app/Contents/MacOS/MediaRemoteUIService"
CLOCK_EXE = "/System/Library/CoreServices/ClockAngel.app/Contents/MacOS/ClockAngel"
SPOTLIGHT_EXE = "/System/Applications/Siri AI.app/Contents/MacOS/Siri AI"
CONTROLCENTER_EXE = "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"
# Readiness is read through a fresh debugger attachment. Wait progressively,
# rather than attaching repeatedly while the provider's main queue is busy.
PROVIDER_READY_DELAYS = (0.15, 0.35, 0.75, 1.5, 2.5)
MUSIC_READY_DELAYS = PROVIDER_READY_DELAYS
# Automatic reapplication budget per component. A patch that makes a service
# crash repeatedly must not turn into an endless restart loop.
REAPPLY_LIMIT = 3
REAPPLY_WINDOW = 15 * 60
WATCH_LOG_PREDICATE = (
    'process == "MenuBarAgent" AND subsystem == "com.apple.FrontBoard" '
    'AND eventMessage CONTAINS "Client process connected"'
)
WATCH_FALLBACK_INTERVAL = 30.0
WATCH_DEBOUNCE = 0.2


@dataclass(frozen=True)
class ProviderSpec:
    name: str
    executable: str
    bundle: str
    pid_getter_name: str
    launch_on_install: bool = False
    restart_on_stop: bool = False
    stop_notice: Optional[str] = None


PROVIDERS = (
    ProviderSpec(
        "music", MUSIC_EXE, "com.apple.MediaRemoteUIService", "music_pid",
        launch_on_install=True,
    ),
    ProviderSpec(
        "clock", CLOCK_EXE, "com.apple.ClockAngel", "clock_pid",
        restart_on_stop=True,
    ),
    ProviderSpec(
        "spotlight", SPOTLIGHT_EXE, "com.apple.campo", "spotlight_pid",
        stop_notice="Stopped patched Spotlight",
    ),
    ProviderSpec(
        "banner", CONTROLCENTER_EXE, "com.apple.controlcenter", "banner_pid",
    ),
)
MANAGED_COMPONENTS = ("menubar", *(spec.name for spec in PROVIDERS))
PROVIDER_LOG_TOKENS = (
    ("MediaRemoteUIService", "music"),
    ("ClockAngel", "clock"),
    ("com.apple.campo", "spotlight"),
    ("Siri AI", "spotlight"),
    ("com.apple.controlcenter", "banner"),
)


def log(message, *, error=False):
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{stamp}] {message}", file=sys.stderr if error else sys.stdout, flush=True)


def state_path():
    return Path(LIBRARY).with_name("loader-state.json")


def load_state():
    try:
        value = json.loads(state_path().read_text())
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def save_state(state):
    path = state_path()
    temporary = path.with_name(path.name + ".next")
    temporary.write_text(json.dumps(state, sort_keys=True))
    temporary.replace(path)


def current_build():
    return subprocess.check_output(["/usr/bin/sw_vers", "-buildVersion"], text=True).strip()


def allow_unverified_build(env=None):
    source = os.environ if env is None else env
    return source.get(ALLOW_UNVERIFIED_ENV, "").strip().lower() in ("1", "true", "yes")


def is_supported_build(build=None):
    return (current_build() if build is None else build) in SUPPORTED_BUILDS


def format_supported_builds_header():
    builds = ", ".join(json.dumps(build) for build in SUPPORTED_BUILDS)
    return f"#pragma once\n#define MACISLAND_SUPPORTED_BUILDS_LIST {builds}\n"


def require_supported_build():
    build = current_build()
    if is_supported_build(build):
        return build
    if allow_unverified_build():
        log(f"OS build {build} is unverified; continuing because {ALLOW_UNVERIFIED_ENV} is enabled",
            error=True)
        return build
    raise RuntimeError(
        f"Unsupported OS build {build} (supported: {', '.join(SUPPORTED_BUILDS)}); "
        f"services left unchanged (set {ALLOW_UNVERIFIED_ENV}=1 to try an unverified build)")


def require_trusted_library(library):
    """Refuse to inject code from a shared-writable or redirected install path."""
    for path, expected in ((library.parent, stat.S_ISDIR), (library, stat.S_ISREG)):
        info = path.lstat()
        if not expected(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise RuntimeError(
                f"{path} must be owned by the current user, not be a symbolic link, "
                "and not be group- or world-writable")


def find_lldb(*, required=True):
    try:
        return subprocess.check_output(["/usr/bin/xcrun", "--find", "lldb"], text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        if required:
            raise RuntimeError("LLDB was not found in the selected developer tools")
        return None


def parse_sip_status(raw_output=None):
    # type: (Optional[str]) -> Dict[str, Any]
    if raw_output is None:
        try:
            raw_output = subprocess.check_output(
                ["/usr/bin/csrutil", "status"], text=True, stderr=subprocess.STDOUT
            )
        except (OSError, subprocess.CalledProcessError) as error:
            raw_output = (error.output or "").strip() if hasattr(error, "output") else ""
            if not raw_output:
                return {
                    "mode": "unknown",
                    "allows_debugging": False,
                    "filesystem_protected": True,
                    "raw": "",
                }
    text = raw_output.strip()
    if re.search(r"status:\s*disabled", text, re.IGNORECASE):
        return {
            "mode": "disabled",
            "allows_debugging": True,
            "filesystem_protected": False,
            "raw": text,
        }
    if re.search(r"Debugging Restrictions:\s*disabled", text, re.IGNORECASE):
        fs_disabled = bool(re.search(r"Filesystem Protections:\s*disabled", text, re.IGNORECASE))
        return {
            "mode": "partial_debug",
            "allows_debugging": True,
            "filesystem_protected": not fs_disabled,
            "raw": text,
        }
    return {
        "mode": "enabled",
        "allows_debugging": False,
        "filesystem_protected": True,
        "raw": text,
    }


def sip_allows_debugging(raw_output=None):
    # type: (Optional[str]) -> bool
    return bool(parse_sip_status(raw_output)["allows_debugging"])


def check_debug_access():
    # type: () -> Dict[str, Any]
    dev_enabled = False
    in_group = False
    dev_raw = ""
    groups_raw = ""
    try:
        dev = subprocess.run(
            ["/usr/sbin/DevToolsSecurity", "-status"],
            capture_output=True, text=True, timeout=5,
        )
        dev_raw = (dev.stdout or "").strip()
        dev_enabled = "currently enabled" in dev_raw
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        grp = subprocess.run(["/usr/bin/id", "-Gn"], capture_output=True, text=True, timeout=5)
        groups_raw = (grp.stdout or "").strip()
        in_group = "_developer" in groups_raw.split()
    except (OSError, subprocess.SubprocessError):
        pass
    return {
        "dev_tools_enabled": dev_enabled,
        "developer_group": in_group,
        "ready": dev_enabled and in_group,
        "dev_tools_status": dev_raw,
    }


def probe_lldb_attach(lldb, *, timeout=15):
    # type: (str, int) -> Tuple[bool, str]
    target = subprocess.Popen(
        ["/bin/sleep", "60"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        try:
            with tempfile.TemporaryDirectory(prefix="macisland-lldb-probe-") as scratch:
                probe = subprocess.run(
                    [
                        lldb, "--no-lldbinit", "--batch",
                        "--attach-pid", str(target.pid),
                        "-O", f"settings set symbols.clang-modules-cache-path {scratch}/modules",
                        "--one-line", "process detach",
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    timeout=timeout,
                )
        except subprocess.TimeoutExpired:
            return (
                False,
                "LLDB timed out attaching to a test process; approve the Developer Tools Access "
                "prompt or enable password-free debugging (`sudo DevToolsSecurity -enable` and "
                "`_developer` group membership).",
            )
        output = probe.stdout or ""
        if probe.returncode == 0 and "detached" in output:
            return (True, "ok")
        if probe.returncode < 0:
            return (
                False,
                f"LLDB terminated with signal {-probe.returncode}; update Xcode or Command Line "
                "Tools to match macOS 27.",
            )
        lines = [line.strip() for line in output.splitlines() if line.strip()]
        detail = lines[-1] if lines else f"lldb exited with status {probe.returncode}"
        return (False, detail)
    finally:
        try:
            target.kill()
        except OSError:
            pass
        try:
            target.wait(timeout=5)
        except (OSError, subprocess.SubprocessError):
            pass


def detect_displays():
    # type: () -> List[Dict[str, Any]]
    if sys.platform != "darwin":
        return []
    script = """
ObjC.import('AppKit');
ObjC.import('CoreGraphics');
var out = [];
var screens = $.NSScreen.screens;
for (var i = 0; i < screens.count; i++) {
    var s = screens.objectAtIndex(i);
    var num = ObjC.unwrap(s.deviceDescription.objectForKey('NSScreenNumber'));
    var id = Number(num || 0);
    var f = s.frame;
    var top = Number(s.safeAreaInsets.top);
    var notch = null;
    if (top > 0 && s.respondsToSelector('auxiliaryTopLeftArea') && s.respondsToSelector('auxiliaryTopRightArea')) {
        var l = s.auxiliaryTopLeftArea;
        var r = s.auxiliaryTopRightArea;
        var w = Number(r.origin.x) - (Number(l.origin.x) + Number(l.size.width));
        if (w > 0) notch = [Math.round(w * 100) / 100, Math.round(top * 100) / 100];
    }
    out.push({
        id: id,
        builtin: Boolean($.CGDisplayIsBuiltin(id)),
        width: Number(f.size.width),
        height: Number(f.size.height),
        scale: Number(s.backingScaleFactor),
        notch: notch
    });
}
JSON.stringify(out);
"""
    try:
        res = subprocess.run(
            ["/usr/bin/osascript", "-l", "JavaScript", "-e", script],
            capture_output=True, text=True, timeout=10, check=True,
        )
        parsed = json.loads(res.stdout or "[]")
        return parsed if isinstance(parsed, list) else []
    except (OSError, subprocess.SubprocessError, ValueError):
        return []


def process_identity(pid):
    """PID plus start time, so a reused PID is never mistaken for a patched one."""
    if not pid:
        return None
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart="],
                            capture_output=True, text=True)
    start = result.stdout.strip()
    return f"{pid}@{start}" if result.returncode == 0 and start else None


def is_traced(pid):
    try:
        flags = subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "flags="], text=True).strip()
    except subprocess.CalledProcessError:
        return False
    return bool(flags) and bool(int(flags, 16) & 0x800)  # Darwin P_TRACED


def has_library_mapping(vmmap_output, library):
    candidates = {str(library), os.path.realpath(library)}
    for line in vmmap_output.splitlines():
        stripped = line.rstrip()
        if any(stripped.endswith(" " + target) for target in candidates):
            return True
    return False


def menu_bar_agent_pid():
    """Return the current MenuBarAgent PID, or None while it is restarting."""
    try:
        output = subprocess.check_output([LAUNCHCTL, "print", SERVICE], text=True)
    except subprocess.CalledProcessError:
        return None
    match = re.search(r"^\s*pid = (\d+)", output, re.MULTILINE)
    return int(match.group(1)) if match else None


@contextmanager
def temporary_launch_environment(library_path):
    domain = subprocess.check_output(
        [LAUNCHCTL, "print", f"gui/{os.getuid()}"], text=True
    )
    environment = re.search(
        r"^\tenvironment = \{\n(.*?)^\t\}", domain, re.MULTILINE | re.DOTALL
    )
    if environment is None:
        raise RuntimeError("Cannot establish prior launch environment")
    prior = re.search(
        rf"^\t\t{re.escape(ENVIRONMENT_KEY)} => (.*)$",
        environment.group(1), re.MULTILINE,
    )
    old_value = prior.group(1) if prior else None
    library_str = str(library_path)
    if old_value:
        entries = old_value.split(":")
        value = old_value if library_str in entries else f"{old_value}:{library_str}"
    else:
        value = library_str
    try:
        subprocess.run([LAUNCHCTL, "setenv", ENVIRONMENT_KEY, value], check=True)
        yield
    finally:
        restore = (["unsetenv", ENVIRONMENT_KEY] if old_value is None else
                   ["setenv", ENVIRONMENT_KEY, old_value])
        subprocess.run([LAUNCHCTL, *restore], check=True)
        print("Prior launch environment restored", flush=True)


def legacy_main(library_path):
    """Restart through the launch environment. The caller holds loader.lock."""
    previous_pid = menu_bar_agent_pid()
    with temporary_launch_environment(library_path.as_posix()):
        subprocess.run([LAUNCHCTL, "kickstart", "-k", SERVICE], check=True)
    for _ in range(100):
        current_pid = menu_bar_agent_pid()
        if current_pid and current_pid != previous_pid:
            mapped = subprocess.run(
                ["/usr/bin/vmmap", "-w", str(current_pid)],
                capture_output=True, text=True, timeout=20,
            )
            if mapped.returncode == 0 and has_library_mapping(mapped.stdout, library_path):
                print(f"MenuBarAgent started: {current_pid}", flush=True)
                return current_pid
        time.sleep(0.1)
    raise RuntimeError("MenuBarAgent did not report a verified patched PID")


def current_boot_arguments():
    # NVRAM describes the next boot; kern.bootargs describes this process's OS.
    return subprocess.check_output(
        ["/usr/sbin/sysctl", "-n", "kern.bootargs"], text=True
    ).strip()


def amfi_globally_disabled():
    return any(
        token.startswith("amfi_get_out_of_my_way=")
        and token.split("=", 1)[1] in ("1", "0x1")
        for token in current_boot_arguments().split()
    )


def debugger_load(service, library_path, lldb, *, timeout=30):
    """Request a suspended launch, attach briefly, and verify the loaded library."""
    if any(c in str(library_path) for c in "\n\r\0"):
        raise ValueError("Invalid library path")
    launched = False
    try:
        # Like the installed loader, stage the variable only until launchd has
        # spawned the target. Restore it before waiting for debugger attachment.
        # kickstart -s works as the service owner; launchctl debug needs root.
        with temporary_launch_environment(library_path):
            result = subprocess.run(
                [LAUNCHCTL, "kickstart", "-k", "-p", "-s", service], check=True,
                capture_output=True, text=True, timeout=timeout,
            )
            launched = True
        pid = int(result.stdout.strip())
        with tempfile.TemporaryDirectory(prefix="macisland-debugger-") as scratch:
            # Attach to the requested suspended launch and detach to resume it.
            # Startup timing can vary; verify the mapping rather than assume
            # attachment occurred before dyld. No debugger remains running.
            result = subprocess.run(
                [lldb, "--no-lldbinit", "--batch", "--attach-pid", str(pid),
                 "--one-line-before-file",
                 f"settings set symbols.clang-modules-cache-path {scratch}/modules",
                 "--one-line", "process detach"],
                check=True, capture_output=True, text=True, timeout=timeout,
            )
            print(result.stdout, end="", flush=True)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            mapped = subprocess.run(
                ["/usr/bin/vmmap", "-w", str(pid)], capture_output=True,
                text=True, timeout=timeout,
            )
            if mapped.returncode == 0 and has_library_mapping(mapped.stdout, library_path):
                print(f"Verified injected library in PID {pid}", flush=True)
                return pid
            time.sleep(0.2)
        raise RuntimeError("Process started but injected library was not verified")
    except BaseException:
        if launched:
            # No persistent launch overrides exist. Restart normally if attach
            # or loading failed, rather than leave a suspended system service.
            subprocess.run(
                [LAUNCHCTL, "kill", "SIGKILL", service],
                capture_output=True, timeout=timeout,
            )
            subprocess.run(
                [LAUNCHCTL, "kickstart", service],
                capture_output=True, timeout=timeout,
            )
        raise


def provider_pid(executable):
    result = subprocess.run(
        ["/usr/bin/pgrep", "-u", str(os.getuid()), "-x", Path(executable).name],
        capture_output=True, text=True,
    )
    if result.returncode == 1:
        return None
    result.check_returncode()
    candidates = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if not candidates or not all(pid.isdecimal() for pid in candidates):
        raise RuntimeError(f"Could not identify the current user's {Path(executable).name} provider")
    verified = []
    for pid in candidates:
        ps = subprocess.run(["/bin/ps", "-p", pid, "-o", "comm="], capture_output=True, text=True)
        if ps.returncode != 0:
            # On-demand providers can exit between pgrep and ps inspection.
            continue
        if ps.stdout.strip() == executable:
            verified.append(pid)
    if not verified:
        return None
    if len(verified) > 1:
        raise RuntimeError(f"Multiple {Path(executable).name} instances are active: {', '.join(verified)}")
    return verified[0]


def music_pid():
    return provider_pid(MUSIC_EXE)


def clock_pid():
    return provider_pid(CLOCK_EXE)


def spotlight_pid():
    return provider_pid(SPOTLIGHT_EXE)


def banner_pid():
    return provider_pid(CONTROLCENTER_EXE)


def provider_pid_getter(spec):
    return globals()[spec.pid_getter_name]


def available_provider_pid(pid, get_pid):
    if get_pid() != pid:
        raise RuntimeError("The UI provider restarted")
    if is_traced(pid):
        raise RuntimeError("The UI provider is already being debugged")


def available_music_pid(pid):
    available_provider_pid(pid, music_pid)


def stop_managed_provider(library, get_pid):
    """Unmap our old provider code before replacing it or restoring a backup."""
    pid = get_pid()
    if pid is None:
        return False
    try:
        mapped = subprocess.check_output(["/usr/bin/vmmap", "-w", pid], text=True, timeout=20)
    except subprocess.CalledProcessError:
        if get_pid() != pid:
            return False
        raise
    if not has_library_mapping(mapped, library):
        return False
    available_provider_pid(pid, get_pid)
    try:
        os.kill(int(pid), 15)
    except ProcessLookupError:
        return True
    for _ in range(50):
        if get_pid() != pid:
            return True
        time.sleep(0.1)
    raise RuntimeError("The old UI provider is still running")


def stop_managed_music(library):
    return stop_managed_provider(library, music_pid)


def stop_all_providers(library):
    stopped = []
    for spec in PROVIDERS:
        get_pid = provider_pid_getter(spec)
        was_stopped = (stop_managed_music(library) if spec.name == "music"
                       else stop_managed_provider(library, get_pid))
        if was_stopped:
            stopped.append(spec.name)
            if spec.restart_on_stop:
                subprocess.run(["/usr/bin/open", "-gj", "-b", spec.bundle],
                               check=False, timeout=15)
    return stopped


def prepare_provider(library, lldb, get_pid, check_pid, bundle, name, *, launch):
    """Install an optional native layout and verify its witness hook."""
    if not library.is_file():
        return None
    require_supported_build()
    require_trusted_library(library)
    pid = get_pid()
    if pid is None and launch:
        subprocess.run(["/usr/bin/open", "-gj", "-b", bundle],
                       check=True, timeout=15)
        for _ in range(50):
            pid = get_pid()
            if pid:
                break
            time.sleep(0.1)
        if pid is None:
            raise RuntimeError(f"The native {name} UI provider did not start")
    if pid is None:
        return None
    if not lldb:
        raise RuntimeError(f"LLDB is required for the native {name} layout")

    allow_unverified = allow_unverified_build()
    # Encode the filesystem bytes, including spaces and quotes, as a C literal.
    path = '"' + ''.join(f'\\x{byte:02x}' for byte in os.fsencode(library)) + '"'
    # Numeric Darwin dlopen flags (RTLD_NOW=0x2, RTLD_LOCAL=0x4, RTLD_NOLOAD=0x10)
    # with explicit LLDB call-result casts avoid compiling @import Darwin against
    # a cold Clang module cache and stay valid inside LLDB's wrapper function body.
    with tempfile.TemporaryDirectory(prefix=f"macisland-{name}-") as scratch:
        def invoke(symbol, load):
            check_pid(pid)
            expr = f'void *h = (void *)dlopen({path}, 0x12); bool resident = h != 0; '
            if load:
                expr += f'if (!h) h = (void *)dlopen({path}, 0x6); '
                if allow_unverified:
                    expr += (
                        'void (*allow_fn)(int) = h ? (void(*)(int))(void *)dlsym(h, "mi_set_allow_unverified_build") : 0; '
                        'if (allow_fn) allow_fn(1); '
                    )
            expr += (f'int (*fn)(void) = h ? (int(*)(void))(void *)dlsym(h, "{symbol}") : 0; '
                     'int rc = !h ? -101 : (fn ? fn() : -100); if (resident) (int)dlclose(h); (int)rc')
            result = subprocess.run(
                [lldb, "--no-lldbinit", "--batch", "--attach-pid", pid,
                 "-O", f"settings set symbols.clang-modules-cache-path {scratch}/modules",
                 "-o", "expr -a true -t 10000000 -l objc++ -- " + expr,
                 "-o", "process detach"], capture_output=True, text=True, timeout=40,
            )
            match = re.search(r"^\(int\) \$\d+ = (-?\d+)$", result.stdout, re.MULTILINE)
            if result.returncode or not match:
                err_text = result.stderr.strip()
                if not err_text:
                    err_lines = [line.strip() for line in result.stdout.splitlines() if "error:" in line]
                    err_text = "; ".join(err_lines) if err_lines else (
                        result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""
                    )
                raise RuntimeError(f"Could not verify {symbol} in the {name} UI provider: {err_text}")
            return int(match.group(1))

        enable_symbol = f"mi_{name}_enable"
        rc = invoke(enable_symbol, True)
        if rc == -101:
            raise RuntimeError(f"Could not load {library.name} into the {name} UI provider")
        if rc == -100:
            raise RuntimeError(
                f"Symbol {enable_symbol} is missing in the {name} UI provider "
                "(an older library may still be mapped)")
        if rc != 0:
            raise RuntimeError(f"The {name} UI provider rejected the build or bundle")
        # Installation runs on the target's main queue after LLDB detaches.
        # At login that queue can be busy; 0 means it has not run yet.
        state = 0
        for delay in PROVIDER_READY_DELAYS:
            time.sleep(delay)
            state = invoke(f"mi_{name}_status", False)
            if state == 1:
                print(f"Verified native {name} layout in PID {pid}", flush=True)
                return pid
            if state < 0:
                break
        raise RuntimeError(f"The {name} provider did not accept its native layout (state {state})")


def prepare_music(library, lldb, *, launch=True):
    return prepare_provider(library, lldb, music_pid, available_music_pid,
                            "com.apple.MediaRemoteUIService", "music", launch=launch)


def background_providers():
    return tuple(
        (spec.name, provider_pid_getter(spec), spec.bundle)
        for spec in PROVIDERS if spec.name != "music"
    )


def prepare_background_safely(library, lldb, name, get_pid, bundle):
    try:
        return prepare_provider(library, lldb, get_pid,
                                lambda pid: available_provider_pid(pid, get_pid),
                                bundle, name, launch=False)
    except Exception as error:
        log(f"Native {name} setup skipped: {error}", error=True)
        return None


def prepare_music_safely(library, lldb, *, launch=True):
    """The optional music layout must never prevent the island from loading."""
    try:
        return prepare_music(library, lldb, launch=launch)
    except Exception as error:
        log(f"Native music layout skipped: {error}", error=True)
        return None


def _prepare_spec_safely(spec, provider_lib, lldb, *, launch):
    if spec.name == "music":
        return prepare_music_safely(provider_lib, lldb, launch=launch)
    return prepare_background_safely(
        provider_lib, lldb, spec.name, provider_pid_getter(spec), spec.bundle
    )


def inject(state, *, force_debugger=False, only_unpatched_providers=False, launch_music=True):
    """Apply the provider layouts (optional) and the island (required).

    The caller holds loader.lock. Records what was patched in ``state``.
    """
    require_supported_build()
    library_path = Path(LIBRARY)
    if not library_path.is_file():
        raise RuntimeError("Missing island.dylib; service unchanged")
    require_trusted_library(library_path)
    legacy = amfi_globally_disabled() and not force_debugger
    lldb = find_lldb(required=not legacy)
    if not legacy:
        if not sip_allows_debugging():
            raise RuntimeError(
                "This loader requires SIP debugging disabled "
                "(csrutil enable --without debug or csrutil disable)"
            )
    pid = menu_bar_agent_pid()
    if pid and is_traced(pid):
        raise RuntimeError("MenuBarAgent is being debugged; leave it unchanged")

    provider_lib = library_path.with_name("notch-music.dylib")
    for spec in PROVIDERS:
        get_pid = provider_pid_getter(spec)
        current_id = process_identity(get_pid()) if only_unpatched_providers else None
        if only_unpatched_providers and current_id and current_id == state.get(spec.name):
            state[spec.name] = current_id
        else:
            launch = launch_music if spec.launch_on_install else False
            patched = _prepare_spec_safely(spec, provider_lib, lldb, launch=launch)
            state[spec.name] = process_identity(patched)

    if legacy:
        new_pid = legacy_main(library_path)
    else:
        new_pid = debugger_load(SERVICE, library_path.resolve(), lldb)
    state["menubar"] = process_identity(new_pid)
    return new_pid


def prune_expired_attempts(state, name, now=None):
    now = time.time() if now is None else now
    key = f"{name}_attempts"
    recent = [t for t in state.get(key, []) if isinstance(t, (int, float)) and 0 <= now - t < REAPPLY_WINDOW]
    if recent:
        state[key] = recent
    else:
        state.pop(key, None)
    if len(recent) < REAPPLY_LIMIT:
        state.pop(f"{name}_paused", None)
    return recent


def take_attempt(state, name, now=None):
    """Allow at most REAPPLY_LIMIT automatic attempts per REAPPLY_WINDOW."""
    now = time.time() if now is None else now
    recent = prune_expired_attempts(state, name, now=now)
    if len(recent) >= REAPPLY_LIMIT:
        if not state.get(f"{name}_paused"):
            log(f"{name}: {REAPPLY_LIMIT} automatic attempts within {REAPPLY_WINDOW // 60} minutes; "
                "pausing to avoid a restart loop", error=True)
            state[f"{name}_paused"] = True
        return False
    recent.append(now)
    state[f"{name}_attempts"] = recent
    return True


def ensure(*, wait=False):
    """Periodic check: reapply only to service instances not yet patched."""
    library_path = Path(LIBRARY)
    if not library_path.is_file():
        return
    with (library_path.parent / "loader.lock").open("a") as lock:
        flags = fcntl.LOCK_EX if wait else (fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            fcntl.flock(lock, flags)
        except BlockingIOError:
            return  # An install, removal or another loader is running.
        state = load_state()
        before = json.dumps(state, sort_keys=True)
        try:
            ensure_locked(library_path, state)
        finally:
            if json.dumps(state, sort_keys=True) != before:
                save_state(state)


def ensure_locked(library_path, state):
    build = current_build()
    if not is_supported_build(build):
        if not allow_unverified_build():
            if state.get("unsupported_build") != build:
                log(f"Unsupported OS build {build}; automatic patching paused", error=True)
                state["unsupported_build"] = build
            return
        state.pop("unsupported_build", None)
        if state.get("unverified_build") != build:
            log(f"OS build {build} is unverified; continuing because {ALLOW_UNVERIFIED_ENV} is enabled",
                error=True)
            state["unverified_build"] = build
    else:
        state.pop("unsupported_build", None)
        state.pop("unverified_build", None)

    now = time.time()
    for component in MANAGED_COMPONENTS:
        prune_expired_attempts(state, component, now=now)
    menubar = process_identity(menu_bar_agent_pid())
    if menubar and menubar != state.get("menubar"):
        if take_attempt(state, "menubar", now=now):
            log(f"MenuBarAgent {menubar} is not patched; applying")
            try:
                inject(state, only_unpatched_providers=True, launch_music=False)
            except Exception as error:
                log(f"MenuBarAgent patch failed: {error}", error=True)
        return
    library = library_path.with_name("notch-music.dylib")
    if not library.is_file():
        return
    for spec in PROVIDERS:
        try:
            identity = process_identity(provider_pid_getter(spec)())
        except Exception:
            continue
        # Optional providers start on demand; do not launch them here.
        if not identity or identity == state.get(spec.name) or not take_attempt(state, spec.name, now=now):
            continue
        log(f"{spec.name.capitalize()} UI provider {identity} is not patched; applying")
        lldb = find_lldb(required=False)
        pid = _prepare_spec_safely(spec, library, lldb, launch=False)
        state[spec.name] = process_identity(pid)


def print_status(force_debugger):
    state = load_state()
    now = time.time()
    build = current_build()
    globally_disabled = amfi_globally_disabled()
    if is_supported_build(build):
        build_status = "supported"
    elif allow_unverified_build():
        build_status = f"unverified; allowed by {ALLOW_UNVERIFIED_ENV}"
    else:
        build_status = "unsupported"
    print(f"OS build: {build} ({build_status})")
    print(f"AMFI-disable boot flag active: {globally_disabled}")
    print(f"Selected loader: {'legacy' if globally_disabled and not force_debugger else 'debugger'}")
    print(f"Debugger: {find_lldb(required=False) or 'not found'}")
    menubar = process_identity(menu_bar_agent_pid())
    print(f"MenuBarAgent: {menubar or 'not running'}; matches last recorded instance: "
          f"{bool(menubar) and menubar == state.get('menubar')}")
    for spec in PROVIDERS:
        try:
            identity = process_identity(provider_pid_getter(spec)())
        except Exception:
            identity = None
        print(f"{spec.name.capitalize()} UI provider: {identity or 'not running'}; matches last recorded instance: "
              f"{bool(identity) and identity == state.get(spec.name)}")
    for name in MANAGED_COMPONENTS:
        recent = [t for t in state.get(f"{name}_attempts", [])
                  if isinstance(t, (int, float)) and 0 <= now - t < REAPPLY_WINDOW]
        if state.get(f"{name}_paused") and len(recent) >= REAPPLY_LIMIT:
            print(f"Automatic {name} reapplication paused after repeated attempts")


def parse_connected_provider(line):
    # type: (str) -> Optional[str]
    for token, name in PROVIDER_LOG_TOKENS:
        if token in line:
            return name
    return None


def watch(*, fallback_interval=WATCH_FALLBACK_INTERVAL, debounce=WATCH_DEBOUNCE, max_cycles=None):
    stop_requested = False
    previous_handlers = {}

    def handle_signal(signum, _frame):
        nonlocal stop_requested
        stop_requested = True

    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            previous_handlers[sig] = signal.signal(sig, handle_signal)
        except ValueError:
            pass

    def start_stream():
        try:
            return subprocess.Popen(
                ["/usr/bin/log", "stream", "--style", "compact", "--predicate", WATCH_LOG_PREDICATE],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1,
            )
        except OSError:
            return None

    stream = None
    try:
        ensure(wait=True)
        stream = start_stream()
        cycles = 0
        while not stop_requested and (max_cycles is None or cycles < max_cycles):
            cycles += 1
            if stream is None or stream.stdout is None:
                time.sleep(fallback_interval)
                ensure()
                if not stop_requested:
                    stream = start_stream()
                continue
            ready, _, _ = select.select([stream.stdout], [], [], fallback_interval)
            if stop_requested:
                break
            if not ready:
                ensure()
                continue
            line = stream.stdout.readline()
            if not line:
                try:
                    stream.terminate()
                    stream.wait(timeout=2)
                except (OSError, subprocess.SubprocessError):
                    pass
                stream = None
                time.sleep(min(1.0, fallback_interval))
                ensure()
                if not stop_requested:
                    stream = start_stream()
                continue
            matched = parse_connected_provider(line) is not None
            deadline = time.monotonic() + debounce
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                more, _, _ = select.select([stream.stdout], [], [], remaining)
                if not more:
                    break
                extra = stream.stdout.readline()
                if not extra:
                    break
                if parse_connected_provider(extra) is not None:
                    matched = True
            if matched:
                ensure()
    finally:
        if stream is not None:
            try:
                stream.terminate()
                stream.wait(timeout=5)
            except (OSError, subprocess.SubprocessError):
                try:
                    stream.kill()
                except OSError:
                    pass
        for sig, handler in previous_handlers.items():
            try:
                signal.signal(sig, handler)
            except ValueError:
                pass


def doctor_report(*, force_debugger=False, probe_lldb=True):
    # type: (bool, bool) -> Dict[str, Any]
    state = load_state()
    now = time.time()
    build = current_build()
    sip = parse_sip_status()
    globally_disabled = amfi_globally_disabled()
    debug_access = check_debug_access() if sys.platform == "darwin" else {
        "dev_tools_enabled": False,
        "developer_group": False,
        "ready": False,
        "dev_tools_status": "",
    }
    lldb = find_lldb(required=False)
    lldb_probe = None
    if probe_lldb and lldb and sip["allows_debugging"]:
        ok, detail = probe_lldb_attach(lldb)
        lldb_probe = {"ok": ok, "detail": detail}
    displays = detect_displays()
    menubar = process_identity(menu_bar_agent_pid())
    providers = {}
    for spec in PROVIDERS:
        try:
            identity = process_identity(provider_pid_getter(spec)())
        except Exception:
            identity = None
        providers[spec.name] = {
            "identity": identity,
            "matches_last_recorded": bool(identity) and identity == state.get(spec.name),
        }
    paused = []
    for name in MANAGED_COMPONENTS:
        recent = [t for t in state.get(f"{name}_attempts", [])
                  if isinstance(t, (int, float)) and 0 <= now - t < REAPPLY_WINDOW]
        if state.get(f"{name}_paused") and len(recent) >= REAPPLY_LIMIT:
            paused.append(name)
    return {
        "os_build": build,
        "build_supported": is_supported_build(build),
        "allow_unverified_build": allow_unverified_build(),
        "sip": sip,
        "amfi_globally_disabled": globally_disabled,
        "selected_loader": "legacy" if globally_disabled and not force_debugger else "debugger",
        "debugger": lldb,
        "debug_access": debug_access,
        "lldb_probe": lldb_probe,
        "displays": displays,
        "menubar": {
            "identity": menubar,
            "matches_last_recorded": bool(menubar) and menubar == state.get("menubar"),
        },
        "providers": providers,
        "paused_components": paused,
    }


def print_doctor(*, force_debugger=False, as_json=False, probe_lldb=True):
    report = doctor_report(force_debugger=force_debugger, probe_lldb=probe_lldb)
    if as_json:
        print(json.dumps(report, indent=2, sort_keys=True), flush=True)
        return
    if report["build_supported"]:
        build_note = "supported"
    elif report["allow_unverified_build"]:
        build_note = f"unverified; allowed by {ALLOW_UNVERIFIED_ENV}"
    else:
        build_note = "unsupported"
    sip = report["sip"]
    access = report["debug_access"]
    print(f"OS build: {report['os_build']} ({build_note})")
    print(
        f"SIP mode: {sip['mode']} (allows_debugging={sip['allows_debugging']}, "
        f"filesystem_protected={sip['filesystem_protected']})"
    )
    print(
        f"Debug access: DevToolsSecurity={access['dev_tools_enabled']}, "
        f"_developer={access['developer_group']}"
    )
    print(f"Debugger: {report['debugger'] or 'not found'}")
    if report["lldb_probe"] is not None:
        probe = report["lldb_probe"]
        print(f"LLDB attach probe: {'ok' if probe['ok'] else 'failed (' + probe['detail'] + ')'}")
    else:
        print("LLDB attach probe: skipped (debugging restricted or lldb unavailable)")
    for d in report["displays"]:
        notch = f"{d['notch'][0]:g}x{d['notch'][1]:g}pt" if d.get("notch") else "none"
        kind = "built-in" if d.get("builtin") else "external"
        print(
            f"Display {d['id']} ({kind}): {d['width']:g}x{d['height']:g}@{d['scale']:g}x, notch={notch}"
        )
    mb = report["menubar"]
    print(
        f"MenuBarAgent: {mb['identity'] or 'not running'}; "
        f"matches last recorded instance: {mb['matches_last_recorded']}"
    )
    for spec in PROVIDERS:
        info = report["providers"][spec.name]
        print(
            f"{spec.name.capitalize()} UI provider: {info['identity'] or 'not running'}; "
            f"matches last recorded instance: {info['matches_last_recorded']}"
        )
    for name in report["paused_components"]:
        print(f"Automatic {name} reapplication paused after repeated attempts")


def _debug_access_remediation_cmds(access):
    cmds = []
    if not access["dev_tools_enabled"]:
        cmds.append("sudo DevToolsSecurity -enable")
    if not access["developer_group"]:
        cmds.append('sudo dseditgroup -o edit -a "$USER" -t user _developer')
    return cmds


def check_install_env():
    sip = parse_sip_status()
    if not sip["allows_debugging"]:
        print(
            "SIP debugging restriction must be disabled before installing "
            "(recommended in Recovery: `csrutil enable --without debug`, or `csrutil disable`). "
            "No protection settings were changed.",
            file=sys.stderr,
        )
        raise SystemExit(1)
    try:
        lldb = find_lldb(required=True)
    except RuntimeError as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
    access = check_debug_access()
    if sip["mode"] == "partial_debug" and not access["ready"]:
        cmds = _debug_access_remediation_cmds(access)
        print(
            "Partial SIP requires password-free debugging for LLDB attach. Run:\n  "
            + "\n  ".join(cmds),
            file=sys.stderr,
        )
        raise SystemExit(1)
    ok, detail = probe_lldb_attach(lldb)
    if not ok:
        message = f"LLDB preflight attach probe failed: {detail}"
        if not access["ready"]:
            cmds = _debug_access_remediation_cmds(access)
            message += (
                "\nIf LLDB attach is blocked by developer debugging permissions, run:\n  "
                + "\n  ".join(cmds)
            )
        print(message, file=sys.stderr)
        raise SystemExit(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--status", action="store_true")
    group.add_argument("--doctor", action="store_true",
                       help="Run read-only diagnostics for OS build, SIP, LLDB, displays, and providers")
    group.add_argument("--check-install-env", action="store_true",
                       help="Verify SIP debugging, developer rights, and LLDB attach capability before installing")
    group.add_argument("--watch", action="store_true",
                       help="Watch FrontBoard provider connections and reapply immediately")
    group.add_argument("--ensure", action="store_true",
                       help="Reapply only when MenuBarAgent or a patched UI provider has restarted")
    group.add_argument("--music-only", "--providers-only", dest="music_only", action="store_true",
                       help="Reapply the native music layout without restarting MenuBarAgent")
    group.add_argument("--stop-music", "--stop-providers", dest="stop_music", action="store_true",
                       help="Detach the installed native provider layouts")
    group.add_argument("--check-build", action="store_true",
                       help="Verify the current OS build is supported or explicitly allowed")
    group.add_argument("--emit-builds-header", action="store_true",
                       help="Print a C preprocessor header defining MACISLAND_SUPPORTED_BUILDS_LIST")
    parser.add_argument("--wait", action="store_true",
                        help="Wait for loader.lock when used with --ensure")
    parser.add_argument("--debugger", action="store_true",
                        help="Force the process-scoped debugger loader")
    parser.add_argument("--json", action="store_true",
                        help="Emit machine-readable JSON output where supported")
    args = parser.parse_args()
    if args.emit_builds_header:
        sys.stdout.write(format_supported_builds_header())
        return
    if args.check_build:
        build = current_build()
        if is_supported_build(build):
            return
        if allow_unverified_build():
            print(
                f"Warning: OS build {build} is unverified; continuing because {ALLOW_UNVERIFIED_ENV} is enabled.",
                file=sys.stderr,
            )
            return
        print(
            f"Supported builds: {', '.join(SUPPORTED_BUILDS)} (current: {build}). "
            f"Set {ALLOW_UNVERIFIED_ENV}=1 to try an unverified build.",
            file=sys.stderr,
        )
        raise SystemExit(1)
    if args.check_install_env:
        check_install_env()
        return
    if args.doctor:
        print_doctor(force_debugger=args.debugger, as_json=args.json)
        return
    if args.status:
        print_status(args.debugger)
        return
    if args.watch:
        watch()
        return
    if args.ensure:
        ensure(wait=args.wait)
        return
    library_path = Path(LIBRARY)
    with (library_path.parent / "loader.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = load_state()
        try:
            if args.stop_music:
                library = library_path.with_name("notch-music.dylib")
                stopped = stop_all_providers(library)
                for spec in PROVIDERS:
                    state.pop(spec.name, None)
                if args.json:
                    print(json.dumps({"stopped": stopped}), flush=True)
                else:
                    for spec in PROVIDERS:
                        if spec.stop_notice and spec.name in stopped:
                            print(spec.stop_notice, flush=True)
            elif args.music_only:
                provider_lib = library_path.with_name("notch-music.dylib")
                lldb = find_lldb()
                for spec in PROVIDERS:
                    if spec.name == "music":
                        pid = prepare_music(provider_lib, lldb)
                    else:
                        pid = prepare_background_safely(
                            provider_lib, lldb, spec.name, provider_pid_getter(spec), spec.bundle
                        )
                    state[spec.name] = process_identity(pid)
            else:
                inject(state, force_debugger=args.debugger)
                for name in MANAGED_COMPONENTS:
                    state.pop(f"{name}_attempts", None)
                    state.pop(f"{name}_paused", None)
        finally:
            save_state(state)


if __name__ == "__main__":
    main()
