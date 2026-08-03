#!/usr/bin/env python3
"""Unit tests for lib/verify.py post-open verification."""

from __future__ import annotations

import json
import subprocess
import sys
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERIFY = ROOT / "lib" / "verify.py"
STATE_ROOT = ROOT / "tests" / "logs" / "state"

SID_OK = "11111111-1111-4111-8111-111111111111"
SID_MISSING = "22222222-2222-4222-8222-222222222222"
SID_FAILED_OPEN = "33333333-3333-4333-8333-333333333333"


def run_verify(attempts_tsv: str, ps_lines: str, state_dir: str):
    ps = Path(state_dir) / "ps.txt"
    ps.write_text(ps_lines, encoding="utf-8")
    return subprocess.run(
        [sys.executable, str(VERIFY), "--ps-file", str(ps),
         "--state-dir", state_dir, "--driver", "test", "--open-mode", "tab"],
        input=attempts_tsv, capture_output=True, text=True,
    )


class VerifyTest(unittest.TestCase):
    def new_state_dir(self, label):
        path = STATE_ROOT / f"verify-{label}-{uuid.uuid4().hex}"
        path.mkdir(parents=True)
        return path

    def test_all_verified_exit_zero(self):
        td = self.new_state_dir("all")
        r = run_verify(
            f"codex\t{SID_OK}\t/tmp\t1\n",
            f"node /x/codex resume {SID_OK}\n",
            str(td),
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        out = json.loads(r.stdout)
        self.assertEqual(out["verified"], 1)
        self.assertEqual(out["unverified"], [])
        report = json.loads((td / "last-report.json").read_text())
        self.assertEqual(report["requested"], 1)
        self.assertTrue(report["sessions"][0]["verified"])

    def test_unverified_and_failed_open_exit_one(self):
        td = self.new_state_dir("partial")
        attempts = (
            f"codex\t{SID_OK}\t/tmp\t1\n"
            f"claude\t{SID_MISSING}\t/tmp\t1\n"
            f"codex\t{SID_FAILED_OPEN}\t/tmp\t0\n"
        )
        r = run_verify(attempts, f"cc --resume {SID_OK}\n", str(td))
        self.assertEqual(r.returncode, 1)
        out = json.loads(r.stdout)
        self.assertEqual(out["verified"], 1)
        self.assertEqual(out["unverified"], [SID_MISSING])
        self.assertEqual(out["open_fail"], 1)
        report = json.loads((td / "last-report.json").read_text())
        self.assertEqual(report["open_fail"], 1)
        self.assertEqual(report["unverified"], [SID_MISSING])

    def test_empty_attempts_ok(self):
        td = self.new_state_dir("empty")
        r = run_verify("", "whatever\n", str(td))
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_malformed_attempt_is_rejected(self):
        td = self.new_state_dir("malformed")
        r = run_verify("codex\tnot-a-uuid\t/tmp\t1\n", "", str(td))
        self.assertEqual(r.returncode, 2)
        self.assertIn("invalid session UUID", r.stderr)

    def test_nonfinite_timeout_is_rejected(self):
        td = self.new_state_dir("nan")
        ps = td / "ps.txt"
        ps.write_text("", encoding="utf-8")
        r = subprocess.run(
            [sys.executable, str(VERIFY), "--ps-file", str(ps),
             "--state-dir", str(td), "--timeout", "nan"],
            input="", capture_output=True, text=True,
        )
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
