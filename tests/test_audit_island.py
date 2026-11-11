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

        # ClockAngel B안 wing width: 494pt -> (494 - 222)/2 - 12 - 12 = 112pt (>= 52pt)
        clock_b = json.loads(json.dumps(healthy))
        clock_b["viewport"]["w"] = 494.0
        analyzed_clock = audit_island.analyze_scene_record(clock_b)
        self.assertEqual(analyzed_clock["viewportUsableWing"], 112.0)
        self.assertEqual(analyzed_clock["flags"], ["OK"])

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
