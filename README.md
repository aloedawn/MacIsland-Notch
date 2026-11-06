# MacIsland Notch

Enable Apple’s native Dynamic Island and adapt its background to a MacBook’s physical notch. This is the working native MenuBarAgent patch, including notch geometry, shared layout margins, outward-rounded shoulders, animated vector corners, and the one-pixel shrink-back correction. It does not add a separate island app or overlay.

## Requirements

- Apple Silicon MacBook with a notch.
- **macOS 27.3 beta, build `26C5035r`**. Other builds are rejected.
- Xcode Command Line Tools and an active desktop login.
- SIP already disabled. The broad `amfi_get_out_of_my_way=0x1` boot argument is **not required**. SIP being disabled still reduces macOS protections; the installer does not change SIP or boot arguments.

## Install

Run as your normal user, **without sudo**:

```bash
curl -fsSL https://raw.githubusercontent.com/aloedawn/MacIsland-Notch/main/install.sh | bash
```

The installer contains all source, builds and signs the patch locally, saves existing MacIsland files and the three affected preferences, then reloads MenuBarAgent. It installs to `~/Library/MacIsland` and reuses `com.macisland.loader` for login injection. Existing MacIsland installations are supported; the original backup is retained across reinstalls.

With the AMFI-disable flag absent, the loader requests a suspended MenuBarAgent launch, briefly attaches the system LLDB, and detaches to resume it. It verifies that `island.dylib` is mapped in the new process; a running PID alone is not treated as success. The launch environment is restored immediately after spawning the process. On debugger or load failure, the loader terminates the suspended instance and requests a normal restart. It refuses to restart MenuBarAgent while another debugger is attached.

Existing boots with `amfi_get_out_of_my_way=1` or `=0x1` retain the legacy loading path. That flag can prevent Karabiner's DriverKit extension from loading; this installer does not remove it or reboot the Mac. If removing it separately, preserve any unrelated boot arguments and restart before testing.

The loader runs once at login; it does not continuously restart a crashing process. No debugger remains running after injection. Logs are `~/Library/MacIsland/loader.log` and `loader-error.log`. Inspect the current boot and selected strategy without reloading MenuBarAgent:

```bash
/usr/bin/python3 ~/Library/MacIsland/loader.py --status
```

Build without installing or changing preferences:

```bash
curl -fsSL https://raw.githubusercontent.com/aloedawn/MacIsland-Notch/main/install.sh | bash -s -- --check
```

## Remove

```bash
curl -fsSL https://raw.githubusercontent.com/aloedawn/MacIsland-Notch/main/install.sh | bash -s -- --uninstall
```

Restores the files and preference values saved before the first install, including an existing MacIsland installation. It preserves unrelated files and settings. A small `~/Library/MacIsland/installer.lock` file remains so concurrent installer runs keep sharing the same lock. Keep `~/Library/MacIsland/notch-backup` until removal. Removal also works after an OS update and does not re-enable SIP or AMFI.

## Scope and validation

The native implementation changes NSScreen’s CenterHUD geometry, both shared FBS scene-layout families, and the existing native background masks. Vector paths update within native presentation-modifier transactions; no independent enlargement animation, black filler, extra visual sibling, or system-binary replacement is added.

Tested on a notched MacBook running `26C5035r`, with music visible and user confirmation of the hover/shrink-back outline correction. The separate hosted-obstruction transport is also corrected; the user confirmed normal text and imagery in the AirPods automatic-switching notification. A real reboot with empty boot arguments and SIP still disabled verified automatic patch loading, healthy Karabiner virtual HID readiness, and user-confirmed Dynamic Island display. This establishes coexistence on the tested machine; it does not prove that debugger attachment is necessary on every startup. Local native regression checks covered modifier capacity, vector curves, pixel alignment, repeat-safe layout updates, and restoration. Full provider coverage is not established: some expanded AirDrop artwork/icons may still enter the physical notch; a complete provider-root safe-area remap remains unfinished. Other Macs, OS builds, and all transient UI states are unverified.

The embedded loader has regression checks for AMFI-enabled strategy selection, preserving the prior launch environment, refusing an already-debugged process, verifying the actual library mapping, and recovering from debugger/load failure:

```bash
python3 -m unittest discover -s tests
```

## Credits

Based on [MakrSas/MacIsland](https://github.com/MakrSas/MacIsland/tree/a54047f69eceb4eaabd4f80034166fe23c8a0e7e), commit `a54047f69eceb4eaabd4f80034166fe23c8a0e7e`. Native feature discovery credited upstream to [@itspdfu](https://x.com/itspdfu). The interposer, loader, and notch adaptations are included as readable source in `install.sh`. The pinned upstream revision has no license file; no additional upstream license is asserted here. Not affiliated with Apple.
