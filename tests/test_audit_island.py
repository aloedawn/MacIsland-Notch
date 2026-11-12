"""Unit tests for scripts/audit_island.py."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("audit_island", ROOT / "scripts/audit_island.py")
assert SPEC and SPEC.loader
audit_island = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit_island)


class AuditIslandTests(unittest.TestCase):
    def test_enable_disable_and_clear_lifecycle(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            self.assertEqual(audit_island.main(["--dir", str(base), "enable"]), 0)
            self.assertTrue((base / "scene-audit.enabled").is_file())
            log = base / "scene-audit.jsonl"
            log.write_text('{"event":"short_host","adjusted":true}\n', encoding="utf-8")
            summary = audit_island.summarize_audit_log(log)
            self.assertEqual(summary["total_records"], 1)
            self.assertEqual(len(summary["short_host_events"]), 1)
            self.assertEqual(audit_island.main(["--dir", str(base), "disable"]), 0)
            self.assertFalse((base / "scene-audit.enabled").exists())
            self.assertEqual(audit_island.main(["--dir", str(base), "clear"]), 0)
            self.assertFalse(log.exists())

    def test_analyze_scene_record_flags_wing_starvation_on_wide_notch(self):
        # 220x38 notch with 360pt minimum width -> (360 - 222)/2 - 12 - 12 = 45pt (< 52pt target)
        starved = {
            "event": "scene_settings",
            "family": "elementView",
            "client": "com.apple.Sharing.AirDropUI",
            "elementKind": "airdrop",
            "layoutMode": "expanded",
            "notch": {"w": 220.0, "h": 38.0},
            "viewport": {"w": 360.0, "h": 140.0},
            "native": {"min": {"w": 260.0, "h": 80.0}, "max": {"w": 380.0, "h": 220.0}},
            "policy": {"extendsBelow": True, "intersects": True, "shortHeight": 0.0},
            "patched": {
                "min": {"w": 360.0, "h": 114.0},
                "max": {"w": 480.0, "h": 254.0},
                "margins": {"top": 46.0, "leading": 12.0, "bottom": 12.0, "trailing": 12.0},
                "canonicalObstructionRect": {"x": 69.0, "y": 0.0, "w": 222.0, "h": 40.0},
            },
        }
        analyzed = audit_island.analyze_scene_record(starved)
        self.assertEqual(analyzed["minUsableWing"], 45.0)
        self.assertIn("MIN_WING_STARVED", analyzed["flags"])
        self.assertIn("VIEWPORT_WING_STARVED", analyzed["flags"])

        # Universal elementView floor: 384pt -> (384 - 222)/2 - 12 - 12 = 57pt (>= 52pt)
        healthy = json.loads(json.dumps(starved))
        healthy["viewport"]["w"] = 384.0
        healthy["patched"]["min"]["w"] = 384.0
        analyzed_ok = audit_island.analyze_scene_record(healthy)
        self.assertEqual(analyzed_ok["minUsableWing"], 57.0)
        self.assertEqual(analyzed_ok["flags"], ["OK"])

        # ClockAngel B안 wing width: 522pt -> (522 - 222)/2 - 12 - 12 = 126pt (>= 52pt)
        clock_b = json.loads(json.dumps(healthy))
        clock_b["viewport"]["w"] = 522.0
        analyzed_clock = audit_island.analyze_scene_record(clock_b)
        self.assertEqual(analyzed_clock["viewportUsableWing"], 126.0)
        self.assertEqual(analyzed_clock["flags"], ["OK"])

        # General Live Activity (WidgetRenderer_Activities): unpatched 374pt @ 0.80 around 277.5pt
        # leaves only ((374 - 277.5)/2 - 20) * 0.80 = 22.6pt -> ACTIVITY_METRICS_STARVED;
        # rewritten 470pt @ 1.0 around 222pt gives (470 - 222)/2 - 20 = 104pt -> OK.
        la_starved = json.loads(json.dumps(healthy))
        la_starved["client"] = "com.apple.chrono.WidgetRenderer-Activities"
        la_starved["patched"]["activityMetrics"] = {
            "applied": False,
            "obstructionSize": {"w": 277.5, "h": 50.0},
            "expandedMinWidth": 374.0,
            "expandedMaxWidth": 374.0,
            "expandedScale": 0.8,
            "expandedCornerRadius": 32.0,
        }
        analyzed_la_starved = audit_island.analyze_scene_record(la_starved)
        self.assertEqual(analyzed_la_starved["activityUsableWing"], 22.6)
        self.assertIn("ACTIVITY_METRICS_STARVED", analyzed_la_starved["flags"])

        la_fixed = json.loads(json.dumps(healthy))
        la_fixed["client"] = "com.apple.chrono.WidgetRenderer-Activities"
        la_fixed["viewport"]["w"] = 470.0
        la_fixed["patched"]["min"]["w"] = 470.0
        la_fixed["patched"]["activityMetrics"] = {
            "applied": True,
            "obstructionSize": {"w": 222.0, "h": 40.0},
            "expandedMinWidth": 470.0,
            "expandedMaxWidth": 470.0,
            "expandedScale": 1.0,
            "expandedCornerRadius": 25.6,
        }
        analyzed_la_fixed = audit_island.analyze_scene_record(la_fixed)
        self.assertEqual(analyzed_la_fixed["activityUsableWing"], 104.0)
        self.assertEqual(analyzed_la_fixed["flags"], ["OK"])

    def test_analyze_scene_record_flags_detached_minimal_and_compact_jitter(self):
        detached_minimal = {
            "event": "scene_settings",
            "family": "elementView",
            "client": "mediaremoteagen",
            "layoutMode": "compact",
            "obstructionLocation": {"noObstruction": {}},
            "notch": {"w": 220.0, "h": 38.0},
            "viewport": {"w": 45.0, "h": 38.0},
            "native": {
                "margins": {"top": 3, "leading": 3, "bottom": 3, "trailing": 3},
                "min": {"w": 0.0, "h": 38.0},
                "max": {"w": 45.0, "h": 38.0},
                "obstructionSpace": None,
            },
            "policy": {"extendsBelow": False, "intersects": True, "shortHeight": 0.0},
            "patched": {
                "applied": True,
                "min": {"w": 18.0, "h": 38.0},
                "max": {"w": 63.0, "h": 38.0},
                "margins": {"top": 3, "leading": 12, "bottom": 3, "trailing": 12},
            },
        }
        analyzed = audit_island.analyze_scene_record(detached_minimal)
        self.assertEqual(analyzed["role"], "minimal_detached")
        self.assertIn("DETACHED_NO_OBSTRUCTION_PATCHED", analyzed["flags"])

        compact_jitter = {
            "event": "scene_settings",
            "family": "elementView",
            "client": "mediaremoteagen",
            "layoutMode": "compact",
            "obstructionLocation": {"midXMinY": {}},
            "notch": {"w": 220.0, "h": 38.0},
            "viewport": {"w": 112.0, "h": 38.0},
            "native": {
                "margins": {"top": 3, "leading": 3, "bottom": 3, "trailing": 0},
                "min": {"w": 0.0, "h": 38.0},
                "max": {"w": 112.0, "h": 38.0},
                "obstructionSpace": None,
            },
            "policy": {"extendsBelow": False, "intersects": True, "shortHeight": 0.0},
            "patched": {
                "applied": True,
                "min": {"w": 21.0, "h": 38.0},
                "max": {"w": 133.0, "h": 38.0},
                "margins": {"top": 3, "leading": 12, "bottom": 3, "trailing": 12},
            },
        }
        analyzed_jitter = audit_island.analyze_scene_record(compact_jitter)
        self.assertEqual(analyzed_jitter["role"], "compact_leading")
        self.assertIn("COMPACT_TRANSITION_MARGIN_JITTER", analyzed_jitter["flags"])


if __name__ == "__main__":
    unittest.main()
