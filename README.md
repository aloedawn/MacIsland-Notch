# MacIsland Notch

Enable Apple’s native Dynamic Island and adapt its background to a MacBook’s physical notch. This is the working native MenuBarAgent patch, including notch geometry, shared layout margins, outward-rounded shoulders, animated vector corners, and the one-pixel shrink-back correction. It does not add a separate island app or overlay.

## Requirements

- Apple Silicon MacBook with a notch.
- **macOS 27.3 beta, build `26C5035r`**. Other builds are rejected.
- Apple developer tools with an arm64e Swift compiler and the macOS 27.2 SDK or later, plus an active desktop login.
- SIP already disabled. The broad `amfi_get_out_of_my_way=0x1` boot argument is **not required**. SIP being disabled still reduces macOS protections; the installer does not change SIP or boot arguments.

## Install

Run as your normal user, **without sudo**:

```bash
curl -fsSL https://raw.githubusercontent.com/aloedawn/MacIsland-Notch/main/install.sh | bash
```

The installer contains all source, builds and signs the patch locally, saves existing MacIsland files and the three affected preferences, then reloads MenuBarAgent. It installs to `~/Library/MacIsland` and reuses `com.macisland.loader` for login injection. Existing MacIsland installations are supported; the original backup is retained across reinstalls. If an upgrade of an existing MacIsland Notch installation fails, the previously installed version is put back; only a failed first installation returns to the original pre-install state.

With the AMFI-disable flag absent, the loader requests a suspended MenuBarAgent launch, briefly attaches the system LLDB, and detaches to resume it. It verifies that `island.dylib` is mapped in the new process; a running PID alone is not treated as success. The launch environment is restored immediately after spawning the process. On debugger or load failure, the loader terminates the suspended instance and requests a normal restart. It refuses to restart MenuBarAgent while another debugger is attached.

Existing boots with `amfi_get_out_of_my_way=1` or `=0x1` retain the legacy loading path. That flag can prevent Karabiner's DriverKit extension from loading; this installer does not remove it or reboot the Mac. If removing it separately, preserve any unrelated boot arguments and restart before testing.

The loader also attaches briefly to Apple’s MediaRemoteUIService, installs the expanded music layout and checks its readiness before restarting MenuBarAgent. The music layout is optional: if it cannot be applied (for example, while the provider is still busy at login), the failure is logged and the island itself is still loaded. Both components check the OS build first and leave services unchanged on any other build. No debugger remains running after injection. Logs are `~/Library/MacIsland/loader.log` and `loader-error.log`.

`com.macisland.loader` runs at login and then every 30 seconds with `--ensure`. Each run compares the current MenuBarAgent and MediaRemoteUIService instances (PID and start time) with the ones last patched, and does nothing if they match. A MenuBarAgent that macOS restarted unpatched is patched again, and a restarted music provider gets its layout back without restarting MenuBarAgent. To stop a crash loop, each component gets at most 3 automatic attempts per 15 minutes; after that, automatic reapplication pauses and the pause is logged. Running the loader manually resets the budget.

Inspect the current boot, selected strategy and patch state without reloading anything:

```bash
/usr/bin/python3 ~/Library/MacIsland/loader.py --status
```

Reapply only the music layout, without restarting MenuBarAgent:

```bash
/usr/bin/python3 ~/Library/MacIsland/loader.py --music-only
```

Build without installing or changing preferences:

```bash
curl -fsSL https://raw.githubusercontent.com/aloedawn/MacIsland-Notch/main/install.sh | bash -s -- --check
```

## Remove

```bash
curl -fsSL https://raw.githubusercontent.com/aloedawn/MacIsland-Notch/main/install.sh | bash -s -- --uninstall
```

Restores the files and preference values saved before the first install, including an existing MacIsland installation. It preserves unrelated files and settings. A small `~/Library/MacIsland/installer.lock` file remains so concurrent installer runs keep sharing the same lock. Keep `~/Library/MacIsland/notch-backup` until removal. Removal stops the periodic check first, also works after an OS update, and does not re-enable SIP or AMFI.

## Scope and validation

The native implementation changes NSScreen’s CenterHUD geometry, both shared FBS scene-layout families, and the existing native background masks. Vector paths update within native presentation-modifier transactions; no independent enlargement animation, black filler, extra visual sibling, or system-binary replacement is added.

Tested on a notched MacBook running `26C5035r`, with music visible and user confirmation of the hover/shrink-back outline correction. The click-dismiss/hover shrink-back top-gap regression was also user-confirmed resolved after pairing native background modifier publication with the vector-mask transaction, preserving target times. The separate hosted-obstruction transport is also corrected; the user confirmed normal text and imagery in the AirPods automatic-switching notification. A real reboot with empty boot arguments and SIP still disabled verified automatic patch loading, healthy Karabiner virtual HID readiness, and user-confirmed Dynamic Island display. This establishes coexistence on the tested machine; it does not prove that debugger attachment is necessary on every startup. That reboot predates the music layout and the periodic reapplication; a reboot with the current version has not yet been verified. Local native regression checks covered modifier capacity, vector curves, pixel alignment, repeat-safe layout updates, and restoration. Full provider coverage is not established: some expanded AirDrop artwork/icons may still enter the physical notch; a complete provider-root safe-area remap remains unfinished. Other Macs, OS builds, and all transient UI states are unverified.

The primary background and its detached circle publish their geometry through the native merge transaction at the original target time. Refreshing the primary mask preserves the spring velocity. Where Apple's existing opaque material can draw the outward shoulder, the filtered input supplies the body and the bridge to the circle. An offscreen Metal comparison and two live open/dismiss cycles exercised this path on the tested Mac.

Expanded activity scenes move their content below the notch through the top margin, keep a 360-point floor (notch width plus 140 points on the tested Mac), and retain the provider's ability to request more width; in live logs the music panel settled at 378 points and the timer at 360. Hosted system banners such as the volume and brightness HUD keep the width they request themselves (309 points for volume). The expanded music panel uses Apple’s original artwork, text, waveform, timeline, and controls. As on iPhone, the artwork shares the timeline's leading edge and the waveform its trailing edge; the panel is sized so the artwork sits in the left wing with a 12-point clearance from the camera housing, its bottom aligned with the artist line below the cutout, and the waveform centered vertically on the artwork. The outgoing panel retains this layout when its native mode changes to compact during dismissal. The native compact island allocates a trailing music slot when music is the sole activity. With two activities, the second activity occupies its own slot.

The scene-layout accessors (margins, minimum size, obstruction) only appear on `FBSSceneSettings` once FrontBoardServices registers their settings extensions, which Apple does lazily for the first expanded or hosted scene. The patch registers the known extensions itself and re-verifies its hooks after every extension registration, so a late first expansion still receives the notch layout instead of the native pill width.

In scaled display modes, points do not land on whole panel pixels: a 3024-pixel panel shown at 1800 points maps the 38-point safe area to 63.84 physical rows, while the camera housing covers 64. The island background extends by the remaining fraction (about 0.1 point there), computed from the display's native mode; at the default 1512-point mode no extension is added.

The embedded loader and installer have regression checks for AMFI-enabled strategy selection, the OS build gate, preserving the prior launch environment, refusing an already-debugged process, verifying the actual library mapping, recovering from debugger/load failure, loading the island when the music layout fails, waiting for a slow music provider, periodic reapplication and its restart-loop limit, and returning to the previous version after a failed upgrade:

```bash
python3 -m unittest discover -s tests
```

## Credits

Based on [MakrSas/MacIsland](https://github.com/MakrSas/MacIsland/tree/a54047f69eceb4eaabd4f80034166fe23c8a0e7e), commit `a54047f69eceb4eaabd4f80034166fe23c8a0e7e`. Native feature discovery credited upstream to [@itspdfu](https://x.com/itspdfu). The interposer, loader, and notch adaptations are included as readable source in `install.sh`. The pinned upstream revision has no license file; no additional upstream license is asserted here. Not affiliated with Apple.
