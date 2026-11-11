import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

MODE, SOURCE = sys.argv[1], Path(sys.argv[2])
ROOT = Path.home() / 'Library/MacIsland'
AGENT = Path.home() / 'Library/LaunchAgents/com.macisland.loader.plist'
BACKUP = ROOT / 'notch-backup'
STATE = BACKUP / 'state.plist'
DOMAIN = f'gui/{os.getuid()}'
MENU_SERVICE = f'{DOMAIN}/com.apple.MenuBarAgent'
PREFERENCES = [
    (str(Path.home() / 'Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar'), 'ShowSoftwareNotch', False),
    (str(Path.home() / 'Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar'), 'EmulateCenterHUD', True),
    ('com.apple.campo', 'SupportsIslandMitosis', True),
]
FILES = {'island.dylib': ROOT / 'island.dylib', 'loader.py': ROOT / 'loader.py', 'agent.plist': AGENT}
MUSIC = ROOT / 'notch-music.dylib'
FILES[MUSIC.name] = MUSIC
AUXILIARY = [ROOT / name for name in ('loader.lock', 'loader.log', 'loader-error.log',
                                      'loader-state.json', 'loader-state.json.next')]
# Login and periodic check: patch only service instances that are not yet patched.
CHECK_INTERVAL = 30


def run(*args, required=True):
    try:
        return subprocess.run(args, check=required, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as error:
        details = (error.stderr or error.stdout or b'').decode('utf-8', 'replace').strip()
        if details:
            print(details, file=sys.stderr)
        raise


def preference(domain, key):
    saved = json.loads(run('/usr/bin/osascript', '-l', 'JavaScript', str(SOURCE / 'preferences.js'), domain, key).stdout)
    if saved['present'] and type(saved['value']) not in (bool, int, str):
        raise RuntimeError(f'Unsupported existing preference type: {key}; no settings changed')
    return saved


def write_preference(domain, key, saved):
    run('/usr/bin/osascript', '-l', 'JavaScript', str(SOURCE / 'preferences.js'), domain, key, json.dumps(saved))


def path_entry_exists(path):
    return path.is_symlink() or path.is_file()


def copy_entry(source, destination):
    destination.unlink(missing_ok=True)
    if source.is_symlink():
        destination.symlink_to(os.readlink(source))
    else:
        shutil.copy2(source, destination)


def replace_file(source, destination, mode):
    destination.parent.mkdir(parents=True, exist_ok=True)
    staged = destination.with_name(destination.name + '.notch-next')
    staged.unlink(missing_ok=True)
    try:
        if source.is_symlink():
            staged.symlink_to(os.readlink(source))
        else:
            shutil.copyfile(source, staged)
            staged.chmod(mode)
        staged.replace(destination)
    finally:
        staged.unlink(missing_ok=True)


def save_original():
    if STATE.is_file():
        state = plistlib.loads(STATE.read_bytes())
        if MUSIC.name not in state['files']:
            if path_entry_exists(MUSIC):
                raise RuntimeError(f'Unmanaged music library exists: {MUSIC}')
            state['files'][MUSIC.name] = {'existed': False, 'mode': 0o755}
            temporary = BACKUP / 'state.next'
            temporary.write_bytes(plistlib.dumps(state))
            temporary.chmod(0o600)
            temporary.replace(STATE)
        return state
    if path_entry_exists(MUSIC):
        raise RuntimeError(f'Unmanaged music library exists: {MUSIC}')
    if BACKUP.exists():
        raise RuntimeError(f'Incomplete backup exists: {BACKUP}; refusing to overwrite it')
    state = {'version': 1, 'files': {}, 'preferences': [],
             'auxiliary_existed': {p.name: p.exists() for p in AUXILIARY}}
    # Read every setting before creating or modifying installation state.
    for domain, key, _ in PREFERENCES:
        state['preferences'].append({'domain': domain, 'key': key, **preference(domain, key)})
    BACKUP.mkdir(parents=True, mode=0o700)
    try:
        for name, path in FILES.items():
            exists = path_entry_exists(path)
            mode = 0o644 if not exists or path.is_symlink() else (path.stat().st_mode & 0o777)
            state['files'][name] = {'existed': exists, 'mode': mode}
            if exists:
                copy_entry(path, BACKUP / name)
        temporary = BACKUP / 'state.next'
        temporary.write_bytes(plistlib.dumps(state))
        temporary.chmod(0o600)
        temporary.replace(STATE)
    except BaseException:
        # Only files created by this attempt, before any live state was changed.
        for name in [*FILES, 'state.next', 'state.plist']:
            (BACKUP / name).unlink(missing_ok=True)
        BACKUP.rmdir()
        raise
    return state


def preferred_loader_script():
    staged = SOURCE / 'loader.py'
    return staged if staged.is_file() else (ROOT / 'loader.py')


def stop_installed_music(state, *, required=True):
    if MUSIC.name in state['files'] and MUSIC.is_file():
        script = preferred_loader_script()
        if script.is_file():
            result = run('/usr/bin/python3', str(script), '--stop-music', required=required)
            return result.returncode == 0 and b'Stopped patched Spotlight' in result.stdout.splitlines()
    return False


def restore_original(state, stopped_spotlight=False):
    for name, details in state['files'].items():
        if details['existed'] and not path_entry_exists(BACKUP / name):
            raise RuntimeError(f'Missing backup: {BACKUP / name}; restoration stopped')
    # Stop the periodic check first, so it cannot reapply what is being removed.
    run('/bin/launchctl', 'bootout', DOMAIN, str(AGENT), required=False)
    stopped_spotlight = stop_installed_music(state, required=False) or stopped_spotlight
    for name, details in state['files'].items():
        path = FILES[name]
        if details['existed']:
            replace_file(BACKUP / name, path, details['mode'])
        else:
            path.unlink(missing_ok=True)
    for saved in state['preferences']:
        write_preference(saved['domain'], saved['key'], saved)
    if state['files']['agent.plist']['existed']:
        run('/bin/launchctl', 'bootstrap', DOMAIN, str(AGENT))
    else:
        run('/bin/launchctl', 'kickstart', '-k', MENU_SERVICE)
    if stopped_spotlight:
        reload_running_spotlight(stopped=True, ensure=False)
    for name in FILES:
        (BACKUP / name).unlink(missing_ok=True)
    STATE.unlink()
    BACKUP.rmdir()
    for path in AUXILIARY:
        # States written by earlier versions do not list newer auxiliary files.
        if not state['auxiliary_existed'].get(path.name, False):
            path.unlink(missing_ok=True)


def snapshot_current():
    """Copy the currently installed files, so a failed upgrade can return to them."""
    folder = SOURCE / 'previous'
    folder.mkdir()
    snapshot = {}
    for name, path in FILES.items():
        exists = path_entry_exists(path)
        mode = 0o644 if not exists or path.is_symlink() else (path.stat().st_mode & 0o777)
        snapshot[name] = {'existed': exists, 'mode': mode}
        if exists:
            copy_entry(path, folder / name)
    preferences = [
        (domain, key, preference(domain, key)) for domain, key, _ in PREFERENCES
    ]
    return snapshot, preferences


def restore_previous(previous, stopped_spotlight=False):
    """Return to the installation that was working before this upgrade."""
    snapshot, preferences = previous
    folder = SOURCE / 'previous'
    run('/bin/launchctl', 'bootout', DOMAIN, str(AGENT), required=False)
    if MUSIC.is_file():
        script = preferred_loader_script()
        if script.is_file():
            result = run('/usr/bin/python3', str(script), '--stop-music', required=False)
            stopped_spotlight |= result.returncode == 0 and b'Stopped patched Spotlight' in result.stdout.splitlines()
    for name, details in snapshot.items():
        path = FILES[name]
        if details['existed']:
            replace_file(folder / name, path, details['mode'])
        else:
            path.unlink(missing_ok=True)
    for domain, key, saved in preferences:
        write_preference(domain, key, saved)
    # Clear state recorded by the failed upgrade and synchronously restore the
    # previous loader before enabling its periodic LaunchAgent.
    (ROOT / 'loader-state.json').unlink(missing_ok=True)
    (ROOT / 'loader-state.json.next').unlink(missing_ok=True)
    if snapshot['island.dylib']['existed'] and snapshot['loader.py']['existed']:
        subprocess.run(['/usr/bin/python3', str(ROOT / 'loader.py')], check=False)
    if snapshot['agent.plist']['existed']:
        run('/bin/launchctl', 'bootstrap', DOMAIN, str(AGENT), required=False)
    else:
        run('/bin/launchctl', 'kickstart', '-k', MENU_SERVICE, required=False)
    if stopped_spotlight:
        reload_running_spotlight(stopped=True, ensure=False)


def agent_definition():
    return {
        'Label': 'com.macisland.loader',
        'ProgramArguments': ['/usr/bin/python3', str(ROOT / 'loader.py'), '--ensure'],
        'RunAtLoad': True,
        'StartInterval': CHECK_INTERVAL,
        'ProcessType': 'Background',
        'StandardOutPath': str(ROOT / 'loader.log'),
        'StandardErrorPath': str(ROOT / 'loader-error.log'),
    }


def reload_running_spotlight(*, stopped=False, ensure=True):
    """Refresh the native cutout client after MenuBarAgent is ready."""
    service = f'{DOMAIN}/com.apple.campo'
    try:
        if not stopped:
            state = run('/bin/launchctl', 'print', service, required=False)
            if state.returncode or not re.search(rb'^\s*pid = [1-9]\d*\s*$', state.stdout, re.MULTILINE):
                return
        run('/bin/launchctl', 'kickstart', '-k', service)
        if ensure:
            run('/usr/bin/python3', str(ROOT / 'loader.py'), '--ensure', '--wait')
    except (OSError, subprocess.CalledProcessError) as error:
        # The island is installed even if this optional consumer cannot reload.
        print(f'Could not reload Spotlight: {error}. If it stays detached, run: '
              f'launchctl kickstart -k {service}', file=sys.stderr)


def install():
    upgrading = STATE.is_file()
    state = save_original()
    previous = snapshot_current() if upgrading else None
    stopped_spotlight = False
    try:
        # Stop the previous periodic check before replacing what it loads.
        run('/bin/launchctl', 'bootout', DOMAIN, str(AGENT), required=False)
        stopped_spotlight = stop_installed_music(state, required=False)
        replace_file(SOURCE / 'island.dylib', ROOT / 'island.dylib', 0o755)
        replace_file(SOURCE / 'loader.py', ROOT / 'loader.py', 0o644)
        replace_file(SOURCE / MUSIC.name, MUSIC, 0o755)
        for domain, key, value in PREFERENCES:
            write_preference(domain, key, {'present': True, 'value': value})
        # Apply synchronously first; the island must load. Provider layouts
        # are optional and only reported if they cannot be applied.
        subprocess.run(['/usr/bin/python3', str(ROOT / 'loader.py')], check=True)
        (SOURCE / 'agent.plist').write_bytes(plistlib.dumps(agent_definition()))
        replace_file(SOURCE / 'agent.plist', AGENT, 0o644)
        # Its first run finds the instances just patched and leaves them alone.
        run('/bin/launchctl', 'bootstrap', DOMAIN, str(AGENT))
    except BaseException:
        if previous is not None:
            print('Upgrade failed; restoring the previously installed version.', file=sys.stderr)
            restore_previous(previous, stopped_spotlight)
        else:
            print('Installation failed; restoring the saved pre-install state.', file=sys.stderr)
            restore_original(state, stopped_spotlight)
        raise
    reload_running_spotlight(stopped=stopped_spotlight)
    print('Installed MacIsland Notch. Login injection and automatic reapplication are enabled.')
    print(f'Original files and preferences: {BACKUP}')


def main():
    ROOT.mkdir(parents=True, exist_ok=True)
    lock_path = ROOT / 'installer.lock'
    # Keep this inode stable, including after removal, for concurrent waiters.
    with lock_path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if MODE == '--uninstall':
            if not STATE.is_file():
                raise RuntimeError('No MacIsland Notch backup found; existing MacIsland files were left untouched')
            restore_original(plistlib.loads(STATE.read_bytes()))
            print('Removed MacIsland Notch; restored the saved pre-install files and preferences.')
        else:
            install()


if __name__ == '__main__':
    main()
