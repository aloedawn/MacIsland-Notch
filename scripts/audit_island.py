#!/usr/bin/env python3
"""MacIsland Notch Step 1 inspector: static stock-provider census and live scene-audit analyzer."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
from typing import Any

DEFAULT_INSTALL_DIR = (
    Path.home() / "Library/Containers/com.apple.MenuBarAgent/Data/Library/MacIsland"
)
AUDIT_FLAG_NAME = "scene-audit.enabled"
AUDIT_LOG_NAME = "scene-audit.jsonl"

# Wing clearance from camera housing edge used when evaluating B안 usable wing width.
DEFAULT_NOTCH_CLEARANCE = 12.0
# Minimum single-wing content capacity in Expanded B안 (standard 52pt artwork/icon;
# wider dual-button providers such as ClockAngel negotiate their own 522pt width).
TARGET_EXPANDED_WING_CONTENT = 52.0
AIRDROP_CARD_WIDTH = 274.0
AIRDROP_SHOULDER_SPAN = 54.0
AIRDROP_OBSTRUCTION_CLEARANCE = 16.0

STOCK_TARGETS: tuple[dict[str, str], ...] = (
    {
        "name": "MenuBarAgent",
        "channel": "Compositor (CenterHUD)",
        "binary": "/System/Library/CoreServices/MenuBarAgent.app/Contents/MacOS/MenuBarAgent",
        "bundle_id": "com.apple.MenuBarAgent",
    },
    {
        "name": "NowPlayingUI (Music)",
        "channel": "ElementRegistry (family 0)",
        "binary": "/System/Library/CoreServices/MediaRemoteUIService.app/Contents/MacOS/MediaRemoteUIService",
        "bundle_id": "com.apple.MediaRemoteUIService",
    },
    {
        "name": "ClockAngel (Timer/Stopwatch/Alarm)",
        "channel": "ElementRegistry (family 0)",
        "binary": "/System/Library/CoreServices/ClockAngel.app/Contents/MacOS/ClockAngel",
        "bundle_id": "com.apple.ClockAngel",
    },
    {
        "name": "AirDropUI",
        "channel": "ElementRegistry (family 0)",
        "binary": "/System/Library/CoreServices/AirDropUI.app/Contents/MacOS/AirDropUI",
        "bundle_id": "com.apple.Sharing.AirDropUI",
    },
    {
        "name": "VoiceMemos",
        "channel": "ElementRegistry (family 0)",
        "binary": "/System/Applications/VoiceMemos.app/Contents/MacOS/VoiceMemos",
        "bundle_id": "com.apple.VoiceMemos",
    },
    {
        "name": "MusicRecognitionMac (Shazam)",
        "channel": "ElementRegistry (family 0)",
        "binary": "/System/Library/CoreServices/MusicRecognitionMac.app/Contents/MacOS/MusicRecognitionMac",
        "bundle_id": "com.apple.musicrecognition.mac",
    },
    {
        "name": "screencaptureui (Screen Recording)",
        "channel": "ElementRegistry (family 0)",
        "binary": "/System/Library/CoreServices/screencaptureui.app/Contents/MacOS/screencaptureui",
        "bundle_id": "com.apple.screencaptureui",
    },
    {
        "name": "WidgetRenderer_Activities (Live Activities)",
        "channel": "ElementRegistry / ActivityKit",
        "binary": "/System/Library/CoreServices/WidgetRenderer_Activities.app/Contents/MacOS/WidgetRenderer_Activities",
        "bundle_id": "com.apple.chrono.WidgetRenderer-Activities",
    },
    {
        "name": "ControlCenter (9 System Banners + AVModule)",
        "channel": "MenuBarClient (family 1) + ElementRegistry",
        "binary": "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
        "bundle_id": "com.apple.controlcenter",
    },
    {
        "name": "Siri AI (Campo / Spotlight)",
        "channel": "Campo Zone",
        "binary": "/System/Applications/Siri AI.app/Contents/MacOS/Siri AI",
        "bundle_id": "com.apple.Siri",
    },
    {
        "name": "NotificationCenter",
        "channel": "MenuBarClient",
        "binary": "/System/Library/CoreServices/NotificationCenter.app/Contents/MacOS/NotificationCenter",
        "bundle_id": "com.apple.notificationcenterui",
    },
    {
        "name": "PreloginSystemBannerRenderer",
        "channel": "MenuBarClient (family 1)",
        "binary": "/System/Library/CoreServices/PreloginSystemBannerRenderer.app/Contents/MacOS/PreloginSystemBannerRenderer",
        "bundle_id": "com.apple.PreloginSystemBannerRenderer",
    },
    {
        "name": "SidecarDisplayAgent",
        "channel": "MenuBarClient (family 1)",
        "binary": "/usr/libexec/SidecarDisplayAgent",
        "bundle_id": "com.apple.SidecarDisplayAgent",
    },
    {
        "name": "assessmentagent",
        "channel": "MenuBarClient (family 1)",
        "binary": "/usr/libexec/assessmentagent",
        "bundle_id": "com.apple.assessmentagent",
    },
)

HUD_FRAMEWORKS = (
    "ElementRegistry",
    "ElementRegistryClient",
    "ElementRegistryFoundation",
    "MenuBarClient",
    "ActivityUIServices",
    "CampoUIInternal",
    "ChronoUIServices",
    "WidgetRenderer",
    "NowPlayingUI",
)


def _read_cstring(buf: bytes, offset: int) -> str:
    if offset < 0 or offset >= len(buf):
        return ""
    end = buf.find(b"\x00", offset)
    if end < 0:
        end = min(len(buf), offset + 256)
    return buf[offset:end].decode("utf-8", errors="replace")


def extract_arm64_slice(data: bytes) -> bytes:
    if len(data) < 32:
        return data
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic == 0xCAFEBABE:
        nfat = struct.unpack_from(">I", data, 4)[0]
        for idx in range(nfat):
            cputype, _, offset, size, _ = struct.unpack_from(">IIIII", data, 8 + idx * 20)
            if cputype == 0x0100000C:  # CPU_TYPE_ARM64
                return data[offset : offset + size]
    return data


def parse_swift_obstruction_fields(binary_path: Path) -> list[str]:
    """Read __swift5_fieldmd from an arm64 Mach-O binary and return HUD/obstruction field names."""
    if not binary_path.is_file():
        return []
    raw = extract_arm64_slice(binary_path.read_bytes())
    if len(raw) < 32 or struct.unpack_from("<I", raw, 0)[0] != 0xFEEDFACF:
        return []
    _, _, _, _, ncmds, _, _, _ = struct.unpack_from("<IIIIIIII", raw, 0)
    sections: dict[str, tuple[int, int, int]] = {}
    pos = 32
    for _ in range(ncmds):
        if pos + 8 > len(raw):
            break
        cmd, cmdsize = struct.unpack_from("<II", raw, pos)
        if cmd == 0x19:  # LC_SEGMENT_64
            nsects = struct.unpack_from("<I", raw, pos + 64)[0]
            spos = pos + 72
            for _ in range(nsects):
                sectname = raw[spos : spos + 16].split(b"\x00", 1)[0].decode("ascii", errors="ignore")
                addr, size, offset = struct.unpack_from("<QQI", raw, spos + 32)
                sections[sectname] = (addr, size, offset)
                spos += 80
        pos += cmdsize

    if "__swift5_fieldmd" not in sections or "__swift5_reflstr" not in sections:
        return []
    _, f_size, f_off = sections["__swift5_fieldmd"]
    _, _, r_off = sections["__swift5_reflstr"]
    if r_off == 0 or f_off == 0:
        return []

    keywords = (
        "obstruction",
        "jindo",
        "cutout",
        "inertpill",
        "sensorframe",
        "compactleading",
        "compacttrailing",
        "expanded",
        "systembanner",
    )
    hits: set[str] = set()
    p = f_off
    end = min(len(raw), f_off + f_size)
    while p + 16 <= end:
        _, _, _, field_size, num_fields = struct.unpack_from("<iiHHI", raw, p)
        rec = p + 16
        if field_size == 0 or rec + num_fields * field_size > end:
            break
        for i in range(num_fields):
            fp = rec + i * field_size
            name_rel = struct.unpack_from("<i", raw, fp + 8)[0]
            if name_rel != 0:
                fname = _read_cstring(raw, fp + 8 + name_rel)
                if any(k in fname.lower() for k in keywords):
                    hits.add(fname)
        p = rec + num_fields * field_size
    return sorted(hits)


def linked_hud_frameworks(binary_path: Path) -> list[str]:
    if not binary_path.is_file():
        return []
    try:
        out = subprocess.check_output(
            ["/usr/bin/otool", "-L", str(binary_path)],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return []
    found = [fw for fw in HUD_FRAMEWORKS if f"/{fw}.framework/" in out]
    return sorted(set(found))


def collect_census() -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for item in STOCK_TARGETS:
        path = Path(item["binary"])
        rows.append(
            {
                "name": item["name"],
                "bundle_id": item["bundle_id"],
                "channel": item["channel"],
                "binary": str(path),
                "present": path.is_file(),
                "frameworks": linked_hud_frameworks(path),
                "hud_fields": parse_swift_obstruction_fields(path),
            }
        )
    return rows


def _as_float(value: Any) -> float | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    return None


def _is_airdrop_record(record: dict[str, Any]) -> bool:
    for field in ("client", "elementKind", "persistence"):
        raw = record.get(field)
        if raw is not None and "airdrop" in str(raw).lower():
            return True
    return False


def classify_scene_role(record: dict[str, Any]) -> str:
    if record.get("family") == "hosted":
        return "hosted_banner"
    obs_loc = record.get("obstructionLocation")
    native = record.get("native") or {}
    n_margins = native.get("margins") or {}
    n_max = native.get("max") or {}
    max_h = _as_float(n_max.get("h"))
    max_w = _as_float(n_max.get("w"))
    lead = _as_float(n_margins.get("leading"))
    trail = _as_float(n_margins.get("trailing"))
    if isinstance(obs_loc, dict) and "noObstruction" in obs_loc and max_h is not None and max_h <= 42:
        if max_w is not None and max_w <= 60:
            return "minimal_detached"
    if max_h is not None and max_h <= 42:
        if lead is not None and trail is not None:
            if lead > 0 and trail == 0:
                return "compact_leading"
            if lead == 0 and trail > 0:
                return "compact_trailing"
        if max_w is not None and max_w <= 60:
            return "minimal_detached"
        return "compact_wing"
    return "expanded_platter"


def analyze_scene_record(record: dict[str, Any]) -> dict[str, Any]:
    notch = record.get("notch") or {}
    native = record.get("native") or {}
    patched = record.get("patched") or {}
    policy = record.get("policy") or {}
    viewport = record.get("viewport") or {}

    role = classify_scene_role(record)
    obs_loc = record.get("obstructionLocation")
    has_no_obstruction_loc = isinstance(obs_loc, dict) and "noObstruction" in obs_loc

    notch_w = _as_float(notch.get("w"))
    notch_h = _as_float(notch.get("h"))
    vp_w = _as_float(viewport.get("w"))
    vp_h = _as_float(viewport.get("h"))

    p_min = patched.get("min") or {}
    p_max = patched.get("max") or {}
    p_margins = patched.get("margins") or {}
    canon_obs = patched.get("canonicalObstructionRect") or {}
    pub_obs = patched.get("publishedObstructionRect") or {}
    is_airdrop = _is_airdrop_record(record)

    min_w = _as_float(p_min.get("w"))
    max_w = _as_float(p_max.get("w"))
    proposal_w = vp_w if (vp_w and vp_w > 0) else min_w
    obs_w = _as_float(canon_obs.get("w")) or (notch_w + 2.0 if notch_w else None)
    pub_obs_h = _as_float(pub_obs.get("h"))
    lead = _as_float(p_margins.get("leading")) or 0.0
    trail = _as_float(p_margins.get("trailing")) or 0.0
    top = _as_float(p_margins.get("top")) or 0.0
    short_h = _as_float(policy.get("shortHeight")) or 0.0
    extends_below = bool(policy.get("extendsBelow"))
    intersects = bool(policy.get("intersects"))

    usable_wing: float | None = None
    if proposal_w is not None and obs_w is not None and proposal_w >= obs_w:
        usable_wing = round((proposal_w - obs_w) / 2.0 - max(lead, trail) - DEFAULT_NOTCH_CLEARANCE, 2)

    min_usable_wing: float | None = None
    if min_w is not None and obs_w is not None and min_w >= obs_w:
        min_usable_wing = round((min_w - obs_w) / 2.0 - max(lead, trail) - DEFAULT_NOTCH_CLEARANCE, 2)

    p_act = patched.get("activityMetrics")
    activity_usable_wing: float | None = None
    if isinstance(p_act, dict):
        act_max_w = _as_float(p_act.get("expandedMaxWidth"))
        act_scale = _as_float(p_act.get("expandedScale")) or 1.0
        act_obs = p_act.get("obstructionSize") or {}
        act_obs_w = _as_float(act_obs.get("w"))
        if act_max_w is not None and act_obs_w is not None and act_max_w >= act_obs_w:
            # Jindo SystemAperture expanded layout applies 20pt horizontal edgeInsets in unscaled space.
            activity_usable_wing = round(((act_max_w - act_obs_w) / 2.0 - 20.0) * act_scale, 2)

    flags: list[str] = []
    family = record.get("family")
    mode = record.get("layoutMode")
    if role == "minimal_detached" and has_no_obstruction_loc and patched.get("applied"):
        flags.append("DETACHED_NO_OBSTRUCTION_PATCHED")
    if role in {"compact_leading", "compact_trailing"} and native.get("obstructionSpace") is None and intersects:
        flags.append("COMPACT_TRANSITION_MARGIN_JITTER")
    if short_h > 0:
        flags.append("DROPPED_BELOW_NOTCH")
    if intersects and extends_below and short_h == 0 and notch_h is not None and top < notch_h:
        flags.append("TOP_MARGIN_COLLISION")
    if (
        family == "elementView"
        and role == "expanded_platter"
        and (mode == "expanded" or extends_below)
        and short_h == 0
        and activity_usable_wing is not None
        and activity_usable_wing < TARGET_EXPANDED_WING_CONTENT
    ):
        flags.append("ACTIVITY_METRICS_STARVED")
    if (
        is_airdrop
        and family == "elementView"
        and role == "expanded_platter"
        and (mode == "expanded" or extends_below)
        and short_h == 0
    ):
        airdrop_floor = max(AIRDROP_CARD_WIDTH, (notch_w or 0.0) + AIRDROP_SHOULDER_SPAN)
        if min_w is not None and min_w > airdrop_floor + 16.0:
            flags.append("AIRDROP_DEAD_WINGS")
        if notch_h is not None and (pub_obs_h is None or pub_obs_h < notch_h + AIRDROP_OBSTRUCTION_CLEARANCE):
            flags.append("AIRDROP_NOTCH_CLIP")
    if (
        not is_airdrop
        and family == "elementView"
        and role == "expanded_platter"
        and (mode == "expanded" or extends_below)
        and short_h == 0
        and min_usable_wing is not None
        and min_usable_wing < TARGET_EXPANDED_WING_CONTENT
    ):
        flags.append("MIN_WING_STARVED")
    if (
        not is_airdrop
        and family == "elementView"
        and role == "expanded_platter"
        and mode in {None, "expanded"}
        and extends_below
        and short_h == 0
        and usable_wing is not None
        and usable_wing < TARGET_EXPANDED_WING_CONTENT
    ):
        flags.append("VIEWPORT_WING_STARVED")
    if not flags:
        flags.append("OK")

    return {
        "client": record.get("client"),
        "elementKind": record.get("elementKind"),
        "role": role,
        "layoutMode": mode,
        "family": family,
        "notch": {"w": notch_w, "h": notch_h},
        "viewport": {"w": vp_w, "h": vp_h},
        "nativeMin": native.get("min"),
        "nativeMax": native.get("max"),
        "nativeMargins": native.get("margins"),
        "nativeActivityMetrics": native.get("activityMetrics"),
        "patchedMin": p_min,
        "patchedMax": p_max,
        "patchedMargins": p_margins,
        "patchedActivityMetrics": p_act,
        "shortHeight": short_h,
        "minUsableWing": min_usable_wing,
        "viewportUsableWing": usable_wing,
        "activityUsableWing": activity_usable_wing,
        "flags": flags,
    }


def summarize_audit_log(log_path: Path) -> dict[str, Any]:
    if not log_path.is_file():
        return {"scene_groups": [], "short_host_events": [], "total_records": 0}
    grouped: dict[str, dict[str, Any]] = {}
    jitter_roles: set[str] = set()
    short_events: list[dict[str, Any]] = []
    total = 0
    for raw_line in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        total += 1
        event = rec.get("event")
        if event == "scene_settings":
            analyzed = analyze_scene_record(rec)
            key = json.dumps(
                [rec.get("client"), rec.get("elementKind"), analyzed["role"], rec.get("layoutMode"), rec.get("family")],
                sort_keys=True,
            )
            if "COMPACT_TRANSITION_MARGIN_JITTER" in analyzed["flags"]:
                jitter_roles.add(key)
            if key in jitter_roles and "COMPACT_TRANSITION_MARGIN_JITTER" not in analyzed["flags"]:
                analyzed["flags"] = [f for f in analyzed["flags"] if f != "OK"] + ["COMPACT_TRANSITION_MARGIN_JITTER"]
            grouped[key] = analyzed
        elif event == "short_host":
            short_events.append(rec)
    return {
        "total_records": total,
        "scene_groups": list(grouped.values()),
        "short_host_events": short_events,
    }


def set_audit_enabled(install_dir: Path, enabled: bool) -> Path:
    install_dir.mkdir(parents=True, exist_ok=True)
    flag = install_dir / AUDIT_FLAG_NAME
    if enabled:
        fd = os.open(str(flag), os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        os.close(fd)
    else:
        flag.unlink(missing_ok=True)
    return flag


def format_markdown_report(summary: dict[str, Any]) -> str:
    lines = [
        f"# MacIsland Scene Audit Summary ({summary['total_records']} records)",
        "",
        "| Client | Role | Mode | Family | Native Min..Max | Patched Min..Max | Viewport | Min Wing | Flags |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for g in summary["scene_groups"]:
        nmin = g.get("nativeMin") or {}
        nmax = g.get("nativeMax") or {}
        pmin = g.get("patchedMin") or {}
        pmax = g.get("patchedMax") or {}
        vp = g.get("viewport") or {}
        lines.append(
            f"| `{g.get('client')}` | `{g.get('role')}` | `{g.get('layoutMode')}` | `{g.get('family')}` "
            f"| `{nmin.get('w')}x{nmin.get('h')} .. {nmax.get('w')}x{nmax.get('h')}` "
            f"| `{pmin.get('w')}x{pmin.get('h')} .. {pmax.get('w')}x{pmax.get('h')}` "
            f"| `{vp.get('w')}x{vp.get('h')}` | `{g.get('minUsableWing')}` "
            f"| `{', '.join(g.get('flags', []))}` |"
        )
    if summary["short_host_events"]:
        lines.extend(["", f"Short-host adjustments recorded: `{len(summary['short_host_events'])}`"])
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dir",
        type=Path,
        default=DEFAULT_INSTALL_DIR,
        help="MacIsland runtime directory (default: ~/Library/MacIsland)",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("enable", help="enable live scene-audit.jsonl telemetry immediately")
    sub.add_parser("disable", help="disable live scene-audit.jsonl telemetry immediately")
    sub.add_parser("clear", help="delete existing scene-audit.jsonl")
    sub.add_parser("status", help="print audit status and record count")

    p_census = sub.add_parser("census", help="inspect stock macOS 27.3 CenterHUD binaries")
    p_census.add_argument("--json", action="store_true", help="output JSON")

    p_report = sub.add_parser("report", help="analyze scene-audit.jsonl for B안 wing/clearance issues")
    p_report.add_argument("--log", type=Path, help="override path to scene-audit.jsonl")
    p_report.add_argument("--json", action="store_true", help="output JSON")

    args = parser.parse_args(argv)
    install_dir: Path = args.dir
    flag = install_dir / AUDIT_FLAG_NAME
    log_path = install_dir / AUDIT_LOG_NAME

    if args.cmd == "enable":
        set_audit_enabled(install_dir, True)
        print(f"Enabled scene audit: {flag}")
        return 0
    if args.cmd == "disable":
        set_audit_enabled(install_dir, False)
        print(f"Disabled scene audit: {flag}")
        return 0
    if args.cmd == "clear":
        log_path.unlink(missing_ok=True)
        print(f"Cleared audit log: {log_path}")
        return 0
    if args.cmd == "status":
        summary = summarize_audit_log(log_path)
        print(
            json.dumps(
                {
                    "enabled": flag.is_file(),
                    "log_exists": log_path.is_file(),
                    "total_records": summary["total_records"],
                    "distinct_scene_groups": len(summary["scene_groups"]),
                },
                indent=2,
            )
        )
        return 0
    if args.cmd == "census":
        rows = collect_census()
        if args.json:
            print(json.dumps(rows, indent=2, ensure_ascii=False))
        else:
            print("| Binary | Channel | Present | HUD Frameworks | Obstruction/HUD Fields |")
            print("|---|---|---|---|---|")
            for r in rows:
                fws = ", ".join(r["frameworks"]) or "-"
                flds = ", ".join(r["hud_fields"][:6]) + (" ..." if len(r["hud_fields"]) > 6 else "")
                print(f"| `{r['name']}` | {r['channel']} | `{r['present']}` | {fws} | `{flds or '-'}` |")
        return 0
    if args.cmd == "report":
        target_log = args.log or log_path
        summary = summarize_audit_log(target_log)
        if args.json:
            print(json.dumps(summary, indent=2, ensure_ascii=False))
        else:
            print(format_markdown_report(summary))
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
