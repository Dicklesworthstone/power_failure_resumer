#!/usr/bin/env python3
"""Unit tests: confidence rubric (locked) + plan build/save/load roundtrip."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))

import confidence  # noqa: E402
from confidence import HIGH, LOW, MEDIUM, score_confidence  # noqa: E402

PLAN_PY = ROOT / "lib" / "plan.py"
GOLDEN_DIR = ROOT / "tests" / "fixtures" / "plans"

BOOT = 1785700000.0


def score(mode, n, mtimes, *, boot=BOOT, anchor=None, window=180.0,
          lookback=900.0, running=0):
    if anchor is None:
        anchor = max(mtimes) if mtimes else None
    level, reasons = score_confidence(
        mode=mode, boot_time=boot, anchor_mtime=anchor,
        window_seconds=window, pre_boot_lookback=lookback,
        session_count=n, skipped_running=running, session_mtimes=mtimes,
    )
    return level, reasons


class ConfidenceRubricTest(unittest.TestCase):
    def test_high_tight_pre_boot(self):
        level, reasons = score("pre_boot", 3, [BOOT - 40, BOOT - 30, BOOT - 20])
        self.assertEqual(level, HIGH)
        self.assertIn("pre_boot_tight_pocket", reasons)

    def test_running_sessions_count_toward_cluster_size(self):
        # 2 offered + 1 already-running = 3 → still HIGH
        level, _ = score("pre_boot", 2, [BOOT - 40, BOOT - 20], running=1)
        self.assertEqual(level, HIGH)

    def test_small_pre_boot_is_medium(self):
        level, reasons = score("pre_boot", 1, [BOOT - 30])
        self.assertEqual(level, MEDIUM)
        self.assertIn("small_pre_boot_cluster", reasons)

    def test_loose_pre_boot_pocket_is_medium(self):
        level, reasons = score("pre_boot", 3, [BOOT - 500, BOOT - 250, BOOT - 20],
                               window=180.0, lookback=900.0)
        self.assertEqual(level, MEDIUM)
        self.assertIn("loose_pocket", reasons)

    def test_density_never_high(self):
        # Huge, perfectly tight pocket near boot — still capped at MEDIUM
        mtimes = [BOOT - 30 + i for i in range(20)]
        level, _ = score("density", 20, mtimes)
        self.assertEqual(level, MEDIUM)

    def test_density_far_from_boot_is_low(self):
        # Busy-afternoon trap: dense pocket 6h after boot
        mtimes = [BOOT + 21600 + i for i in range(10)]
        level, reasons = score("density", 10, mtimes)
        self.assertEqual(level, LOW)
        self.assertIn("dense_pocket_far_from_boot", reasons)

    def test_small_density_is_low(self):
        level, _ = score("density", 3, [BOOT - 30, BOOT - 25, BOOT - 20])
        self.assertEqual(level, LOW)

    def test_recent_mode_is_low(self):
        level, _ = score("recent", 8, [BOOT + 100 + i for i in range(8)])
        self.assertEqual(level, LOW)

    def test_no_boot_time_cannot_be_high(self):
        level, _ = score("pre_boot", 5, [BOOT - 30] * 5, boot=None)
        self.assertEqual(level, LOW)


def fake_discovery() -> dict:
    return {
        "boot_time": BOOT,
        "boot_time_human": "2026-08-01 10:00:00",
        "mode": "pre_boot",
        "anchor_mtime": BOOT - 20,
        "window_seconds": 180.0,
        "pre_boot_lookback": 900.0,
        "total_candidates_scanned": 8,
        "skipped_running": 1,
        "sessions": [
            {
                "provider": "codex",
                "session_id": "019f0000-0000-7000-8000-00000000c001",
                "cwd": "/tmp",
                "mtime": BOOT - 40,
                "path": "/x/rollout.jsonl",
                "resume_cmd": "cod resume 019f0000-0000-7000-8000-00000000c001",
                "title": "projA",
                "is_subagent": False,
                "is_running": False,
            },
            {
                "provider": "claude",
                "session_id": "aaaa0000-0000-4000-8000-00000000a001",
                "cwd": "/tmp",
                "mtime": BOOT - 20,
                "path": "/x/a.jsonl",
                "resume_cmd": "cc --resume aaaa0000-0000-4000-8000-00000000a001",
                "title": "projA",
                "is_subagent": False,
                "is_running": False,
            },
        ],
    }


class PlanBuildTest(unittest.TestCase):
    def test_build_plan_shape_matches_golden(self):
        plan = confidence.build_plan(fake_discovery(), created_at="2026-08-01T10:05:00-04:00")
        golden_path = GOLDEN_DIR / "plan-high.json"
        golden = json.loads(golden_path.read_text(encoding="utf-8"))
        self.assertEqual(plan, golden)

    def test_schema_fields_present(self):
        plan = confidence.build_plan(fake_discovery(), created_at="2026-08-01T10:05:00-04:00")
        for field in ("schema_version", "created_at", "boot_time", "mode",
                      "window_seconds", "pre_boot_lookback", "anchor_mtime",
                      "confidence", "confidence_reasons",
                      "total_candidates_scanned", "skipped_running", "sessions"):
            self.assertIn(field, plan)
        self.assertEqual(plan["schema_version"], 1)
        self.assertEqual(plan["confidence"], HIGH)


class PlanCliRoundtripTest(unittest.TestCase):
    def run_plan(self, argv, stdin_text=None, env=None):
        import os
        full_env = dict(os.environ)
        if env:
            full_env.update(env)
        return subprocess.run(
            [sys.executable, str(PLAN_PY), *argv],
            input=stdin_text, capture_output=True, text=True, env=full_env,
        )

    def test_save_then_load_roundtrip(self):
        with tempfile.TemporaryDirectory() as td:
            r = self.run_plan(["save", "--state-dir", td],
                              stdin_text=json.dumps(fake_discovery()))
            self.assertEqual(r.returncode, 0, r.stderr)
            info = json.loads(r.stdout)
            self.assertEqual(info["confidence"], HIGH)
            self.assertEqual(info["session_count"], 2)

            last = Path(td) / "last-plan.json"
            self.assertTrue(last.exists())
            self.assertEqual(last.stat().st_mode & 0o777, 0o600)

            r = self.run_plan(["load", "--path", str(last), "--fake-boot", str(BOOT)])
            self.assertEqual(r.returncode, 0, r.stderr)
            out = json.loads(r.stdout)
            self.assertEqual(out["session_count"], 2)
            self.assertEqual(out["confidence"], HIGH)
            self.assertEqual(
                {s["session_id"] for s in out["sessions"]},
                {s["session_id"] for s in fake_discovery()["sessions"]},
            )

    def test_load_refuses_other_boot(self):
        with tempfile.TemporaryDirectory() as td:
            self.run_plan(["save", "--state-dir", td],
                          stdin_text=json.dumps(fake_discovery()))
            last = Path(td) / "last-plan.json"
            r = self.run_plan(["load", "--path", str(last),
                               "--fake-boot", str(BOOT + 9999)])
            self.assertEqual(r.returncode, 3)
            self.assertIn("rebooted since", r.stderr)
            r = self.run_plan(["load", "--path", str(last), "--force",
                               "--fake-boot", str(BOOT + 9999)])
            self.assertEqual(r.returncode, 0, r.stderr)

    def test_load_rejects_wrong_schema(self):
        with tempfile.TemporaryDirectory() as td:
            bad = Path(td) / "bad.json"
            bad.write_text(json.dumps({"schema_version": 99, "sessions": []}))
            r = self.run_plan(["load", "--path", str(bad)])
            self.assertEqual(r.returncode, 2)
            self.assertIn("schema_version", r.stderr)

    def test_archive_pruned(self):
        with tempfile.TemporaryDirectory() as td:
            plans = Path(td) / "plans"
            plans.mkdir()
            for i in range(25):
                (plans / f"plan-2026-01-01T00-00-{i:02d}.json").write_text("{}")
            self.run_plan(["save", "--state-dir", td],
                          stdin_text=json.dumps(fake_discovery()))
            self.assertLessEqual(len(list(plans.glob("plan-*.json"))), 21)


if __name__ == "__main__":
    unittest.main(verbosity=2)
