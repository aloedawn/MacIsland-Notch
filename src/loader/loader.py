"""Inject the Dynamic Island interposer into MenuBarAgent and keep it applied."""

import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time


LAUNCHCTL = "/bin/launchctl"
SERVICE = f"gui/{os.getuid()}/com.apple.MenuBarAgent"
ENVIRONMENT_KEY = "DYLD_INSERT_LIBRARIES"
LIBRARY = str(Path.home() / "Library/MacIsland/island.dylib")
SUPPORTED_BUILD = "26C5035r"
MUSIC_EXE = "/System/Library/CoreServices/MediaRemoteUIService.app/Contents/MacOS/MediaRemoteUIService"
CLOCK_EXE = "/System/Library/CoreServices/ClockAngel.app/Contents/MacOS/ClockAngel"
SPOTLIGHT_EXE = "/System/Applications/Siri AI.app/Contents/MacOS/Siri AI"
# Readiness is read through a fresh debugger attachment. Wait progressively,
# rather than attaching repeatedly while the provider's main queue is busy.
PROVIDER_READY_DELAYS = (0.15, 0.35, 0.75, 1.5, 2.5)
MUSIC_READY_DELAYS = PROVIDER_READY_DELAYS
# Automatic reapplication budget per component. A patch that makes a service
# crash repeatedly must not turn into an endless restart loop.
REAPPLY_LIMIT = 3
REAPPLY_WINDOW = 15 * 60
MANAGED_COMPONENTS = ("menubar", "music", "clock", "spotlight")


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


def require_supported_build():
    build = current_build()
    if build != SUPPORTED_BUILD:
        raise RuntimeError(
            f"Unsupported OS build {build} (supported: {SUPPORTED_BUILD}); services left unchanged")
    return build


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

    # Encode the filesystem bytes, including spaces and quotes, as a C literal.
    path = '"' + ''.join(f'\\x{byte:02x}' for byte in os.fsencode(library)) + '"'
    with tempfile.TemporaryDirectory(prefix=f"macisland-{name}-") as scratch:
        def invoke(symbol, load):
            check_pid(pid)
            expr = f'void *h = dlopen({path}, RTLD_NOLOAD | RTLD_NOW); bool resident = h != 0; '
            if load:
                expr += f'if (!h) h = dlopen({path}, RTLD_NOW | RTLD_LOCAL); '
            expr += (f'int (*fn)(void) = h ? (int(*)(void))dlsym(h, "{symbol}") : 0; '
                     'int rc = !h ? -101 : (fn ? fn() : -100); if (resident) dlclose(h); (int)rc')
            result = subprocess.run(
                [lldb, "--no-lldbinit", "--batch", "--attach-pid", pid,
                 "-O", f"settings set symbols.clang-modules-cache-path {scratch}/modules",
                 "-o", "expr -l objc++ -- @import Darwin",
                 "-o", "expr -a true -t 3000000 -l objc++ -- " + expr,
                 "-o", "process detach"], capture_output=True, text=True, timeout=40,
            )
            match = re.search(r"^\(int\) \$\d+ = (-?\d+)$", result.stdout, re.MULTILINE)
            if result.returncode or not match:
                raise RuntimeError(f"Could not verify {symbol} in the {name} UI provider: {result.stderr.strip()}")
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
    return (("clock", clock_pid, "com.apple.ClockAngel"),
            ("spotlight", spotlight_pid, "com.apple.campo"))


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
        sip = subprocess.check_output(["/usr/bin/csrutil", "status"], text=True)
        if "status: disabled" not in sip:
            raise RuntimeError("This loader requires existing disabled SIP")
    pid = menu_bar_agent_pid()
    if pid and is_traced(pid):
        raise RuntimeError("MenuBarAgent is being debugged; leave it unchanged")

    provider_lib = library_path.with_name("notch-music.dylib")
    current_music = process_identity(music_pid()) if only_unpatched_providers else None
    if only_unpatched_providers and current_music and current_music == state.get("music"):
        state["music"] = current_music
    else:
        music = prepare_music_safely(provider_lib, lldb, launch=launch_music)
        state["music"] = process_identity(music)

    for name, get_pid, bundle in background_providers():
        current_id = process_identity(get_pid()) if only_unpatched_providers else None
        if only_unpatched_providers and current_id and current_id == state.get(name):
            state[name] = current_id
        else:
            patched = prepare_background_safely(provider_lib, lldb, name, get_pid, bundle)
            state[name] = process_identity(patched)

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
    if build != SUPPORTED_BUILD:
        if state.get("unsupported_build") != build:
            log(f"Unsupported OS build {build}; automatic patching paused", error=True)
            state["unsupported_build"] = build
        return
    state.pop("unsupported_build", None)
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
    for name, get_pid, bundle in (("music", music_pid, None), *background_providers()):
        try:
            identity = process_identity(get_pid())
        except Exception:
            continue
        # Optional providers start on demand; do not launch them here.
        if not identity or identity == state.get(name) or not take_attempt(state, name, now=now):
            continue
        log(f"{name.capitalize()} UI provider {identity} is not patched; applying")
        lldb = find_lldb(required=False)
        pid = (prepare_music_safely(library, lldb, launch=False) if name == "music"
               else prepare_background_safely(library, lldb, name, get_pid, bundle))
        state[name] = process_identity(pid)


def print_status(force_debugger):
    state = load_state()
    now = time.time()
    build = current_build()
    globally_disabled = amfi_globally_disabled()
    print(f"OS build: {build} ({'supported' if build == SUPPORTED_BUILD else 'unsupported'})")
    print(f"AMFI-disable boot flag active: {globally_disabled}")
    print(f"Selected loader: {'legacy' if globally_disabled and not force_debugger else 'debugger'}")
    print(f"Debugger: {find_lldb(required=False) or 'not found'}")
    menubar = process_identity(menu_bar_agent_pid())
    print(f"MenuBarAgent: {menubar or 'not running'}; matches last recorded instance: "
          f"{bool(menubar) and menubar == state.get('menubar')}")
    for name, get_pid, _ in (("music", music_pid, None), *background_providers()):
        try:
            identity = process_identity(get_pid())
        except Exception:
            identity = None
        print(f"{name.capitalize()} UI provider: {identity or 'not running'}; matches last recorded instance: "
              f"{bool(identity) and identity == state.get(name)}")
    for name in MANAGED_COMPONENTS:
        recent = [t for t in state.get(f"{name}_attempts", [])
                  if isinstance(t, (int, float)) and 0 <= now - t < REAPPLY_WINDOW]
        if state.get(f"{name}_paused") and len(recent) >= REAPPLY_LIMIT:
            print(f"Automatic {name} reapplication paused after repeated attempts")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--status", action="store_true")
    group.add_argument("--ensure", action="store_true",
                       help="Reapply only when MenuBarAgent or a patched UI provider has restarted")
    group.add_argument("--music-only", "--providers-only", dest="music_only", action="store_true",
                       help="Reapply the native music layout without restarting MenuBarAgent")
    group.add_argument("--stop-music", "--stop-providers", dest="stop_music", action="store_true",
                       help="Detach the installed native provider layouts")
    parser.add_argument("--wait", action="store_true",
                        help="Wait for loader.lock when used with --ensure")
    parser.add_argument("--debugger", action="store_true",
                        help="Force the process-scoped debugger loader")
    args = parser.parse_args()
    if args.status:
        print_status(args.debugger)
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
                stop_managed_music(library)
                if stop_managed_provider(library, clock_pid):
                    subprocess.run(["/usr/bin/open", "-gj", "-b", "com.apple.ClockAngel"],
                                   check=False, timeout=15)
                if stop_managed_provider(library, spotlight_pid):
                    print("Stopped patched Spotlight", flush=True)
                for name in ("music", "clock", "spotlight"):
                    state.pop(name, None)
            elif args.music_only:
                provider_lib = library_path.with_name("notch-music.dylib")
                lldb = find_lldb()
                pid = prepare_music(provider_lib, lldb)
                state["music"] = process_identity(pid)
                for name, get_pid, bundle in background_providers():
                    patched = prepare_background_safely(provider_lib, lldb, name, get_pid, bundle)
                    state[name] = process_identity(patched)
            else:
                inject(state, force_debugger=args.debugger)
                for name in MANAGED_COMPONENTS:
                    state.pop(f"{name}_attempts", None)
                    state.pop(f"{name}_paused", None)
        finally:
            save_state(state)


if __name__ == "__main__":
    main()
