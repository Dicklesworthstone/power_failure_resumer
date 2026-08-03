#!/usr/bin/env python3
"""Unit tests for lib/discover.py clustering + filtering logic.

Runs against pure functions where possible and against the generated fixtures
(tests/fixtures/generated) for end-to-end discovery behavior.
"""

from __future__ import annotations

import io
import json
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))

import discover  # noqa: E402
from discover import Session, densest_cluster, dedupe_sessions, pre_boot_cluster  # noqa: E402

FIX = ROOT / "tests" / "fixtures" / "generated"
META = json.loads((ROOT / "tests" / "fixtures" / "meta.json").read_text())
BOOT = float(META["fake_boot"])
IDS = json.loads((FIX / "ids.json").read_text())


def S(mtime: float, sid: str = "", provider: str = "codex") -> Session:
    return Session(
        provider=provider,
        session_id=sid or f"id-{mtime}",
        cwd="/tmp",
        mtime=float(mtime),
        path=f"/x/{sid or mtime}",
        title="t",
        resume_cmd="r",
        is_subagent=False,
    )


def run_discover(*extra: str) -> dict:
    argv = [
        "--codex-root", str(FIX / "codex"),
        "--claude-root", str(FIX / "claude"),
        "--fake-boot", str(BOOT),
        "--lookback-hours", "8760000",
        "--ps-file", str(FIX / "ps.txt"),
        *extra,
    ]
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = discover.main(argv)
    if rc != 0:
        raise AssertionError(f"discover.main rc={rc} argv={argv}")
    return json.loads(buf.getvalue())


class DensestClusterTest(unittest.TestCase):
    def test_prefers_higher_count(self):
        c, anchor = densest_cluster([S(0), S(1), S(2), S(100), S(101)], 10)
        self.assertEqual(sorted(s.mtime for s in c), [0, 1, 2])
        self.assertEqual(anchor, 2)

    def test_tie_prefers_newer_window(self):
        c, anchor = densest_cluster([S(0), S(1), S(100), S(101)], 10)
        self.assertEqual(sorted(s.mtime for s in c), [100, 101])
        self.assertEqual(anchor, 101)

    def test_empty_and_zero_window(self):
        self.assertEqual(densest_cluster([], 10), ([], 0.0))
        c, _ = densest_cluster([S(5), S(5), S(9)], 0)
        self.assertEqual(sorted(s.mtime for s in c), [5, 5])

    def test_pre_boot_outlier_dropped(self):
        # Early outlier 13 min before boot + tight pocket right at boot.
        sessions = [S(BOOT - 780), S(BOOT - 30), S(BOOT - 25), S(BOOT - 20)]
        pb = pre_boot_cluster(sessions, BOOT, 900, 60)
        self.assertEqual(len(pb), 4)  # all inside the pre-boot lookback…
        tight, _ = densest_cluster(pb, 180)
        self.assertEqual(sorted(s.mtime for s in tight),
                         [BOOT - 30, BOOT - 25, BOOT - 20])  # …outlier dropped

    def test_running_mark_does_not_move_pocket(self):
        # Regression: marking most of the crash pocket as running must not
        # change which pocket densest_cluster selects (filter AFTER cluster).
        pocket = [S(BOOT - 30, "a"), S(BOOT - 25, "b"), S(BOOT - 20, "c")]
        stray = [S(BOOT - 700, "x"), S(BOOT - 695, "y")]
        for s in pocket[:2]:
            s.is_running = True
        tight, _ = densest_cluster(pocket + stray, 180)
        self.assertEqual({s.session_id for s in tight}, {"a", "b", "c"})

    def test_exact_window_does_not_absorb_adjacent_session(self):
        # Three equal low endpoints make [0, 180] the unique densest window.
        # The old ±0.5 reconstruction incorrectly absorbed 180.4 as a fifth item.
        c, anchor = densest_cluster([S(0), S(0), S(0), S(180), S(180.4)], 180)
        self.assertEqual(sorted(s.mtime for s in c), [0, 0, 0, 180])
        self.assertEqual(anchor, 180)
        self.assertLessEqual(max(s.mtime for s in c) - min(s.mtime for s in c), 180)


class DedupeTest(unittest.TestCase):
    def test_keeps_newest_per_provider_and_id(self):
        old, new = S(10, "same"), S(20, "same")
        other_provider = S(15, "same", provider="claude")
        best = dedupe_sessions([old, new, other_provider])
        self.assertEqual(len(best), 2)
        codex = next(s for s in best if s.provider == "codex")
        self.assertEqual(codex.mtime, 20)


class InputBoundaryTest(unittest.TestCase):
    def test_running_detection_ignores_other_resume_flags_and_searches(self):
        ps_text = "\n".join([
            "/opt/codex --search resume 11111111-1111-1111-1111-111111111111",
            "/Users/me/.local/bin/claude --resume=22222222-2222-2222-2222-222222222222",
            "python worker.py --resume 33333333-3333-3333-3333-333333333333",
            'rg "cod resume 44444444-4444-4444-4444-444444444444" README.md',
            "/opt/codex --model o4 resume 55555555-5555-5555-5555-555555555555",
        ])
        self.assertEqual(
            discover.running_session_ids(ps_text),
            {
                "22222222-2222-2222-2222-222222222222",
                "55555555-5555-5555-5555-555555555555",
            },
        )

    def test_resume_id_must_be_exact_uuid(self):
        good = "11111111-1111-1111-1111-111111111111"
        self.assertEqual(discover.validated_uuid(good), good)
        self.assertIsNone(discover.validated_uuid(good + "; touch /tmp/pwned"))
        self.assertIsNone(discover.validated_uuid(123))

    def test_nonfinite_and_negative_cli_values_are_rejected(self):
        for argv in (["--window", "nan"], ["--limit", "-1"], ["--min-cluster", "0"]):
            with self.subTest(argv=argv):
                with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
                    discover.main(argv)
                self.assertEqual(raised.exception.code, 2)


class FixtureDiscoveryTest(unittest.TestCase):
    def test_default_pre_boot_cluster(self):
        d = run_discover()
        self.assertEqual(d["mode"], "pre_boot")
        got = {s["session_id"] for s in d["sessions"]}
        want = {IDS["C1"], IDS["C2"], IDS["A1"], IDS["A2_decode"]}
        self.assertEqual(got, want)
        self.assertEqual(d["skipped_running"], 1)  # C4 dropped
        self.assertEqual(d["boot_time"], BOOT)

    def test_force_reopen_keeps_running(self):
        d = run_discover("--force-reopen")
        got = {s["session_id"] for s in d["sessions"]}
        self.assertIn(IDS["C4_running"], got)
        self.assertEqual(d["skipped_running"], 0)
        c4 = next(s for s in d["sessions"] if s["session_id"] == IDS["C4_running"])
        self.assertTrue(c4["is_running"])

    def test_subagents_flag(self):
        d = run_discover()
        self.assertNotIn(IDS["C3_subagent"], {s["session_id"] for s in d["sessions"]})
        d = run_discover("--include-subagents")
        self.assertIn(IDS["C3_subagent"], {s["session_id"] for s in d["sessions"]})

    def test_claude_decode_fallback(self):
        # A2 has no cwd line; its project dir "-tmp" must decode to /tmp
        d = run_discover()
        a2 = next(s for s in d["sessions"] if s["session_id"] == IDS["A2_decode"])
        self.assertEqual(a2["cwd"], "/tmp")

    def test_codex_resume_id_is_filename_uuid(self):
        d = run_discover()
        c1 = next(s for s in d["sessions"] if s["session_id"] == IDS["C1"])
        self.assertIn(IDS["C1"], c1["resume_cmd"])
        self.assertIn(IDS["C1"], c1["path"])  # id came from this filename

    def test_recent_mode_finds_post_boot_session(self):
        d = run_discover("--mode", "recent")
        got = {s["session_id"] for s in d["sessions"]}
        self.assertEqual(got, {IDS["LIVE"]})

    def test_limit_keeps_newest(self):
        d = run_discover("--limit", "2")
        self.assertEqual(d["session_count"], 2)
        mts = [s["mtime"] for s in d["sessions"]]
        self.assertEqual(mts, sorted(mts, reverse=True))

    def test_min_cluster_rejects_small_pocket(self):
        d = run_discover("--min-cluster", "10")
        self.assertEqual(d["session_count"], 0)

    def test_idle_sessions_excluded(self):
        d = run_discover()
        got = {s["session_id"] for s in d["sessions"]}
        self.assertNotIn(IDS["IDLE_FAR"], got)
        self.assertNotIn(IDS["IDLE_NEAR"], got)


if __name__ == "__main__":
    unittest.main(verbosity=2)
