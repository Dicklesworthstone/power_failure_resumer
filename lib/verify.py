#!/usr/bin/env python3
"""Post-open verification: poll `ps` for resumed-session evidence, write a report.

stdin: one TSV line per attempted session: provider<TAB>session_id<TAB>cwd<TAB>open_ok(0|1)

Polls until every successfully-opened session's UUID shows up next to a resume
flag in process args (the same tight matching discovery uses to skip
already-running sessions), or the timeout elapses. With --ps-file the table is
read once and no waiting happens — deterministic for tests.

Writes <state-dir>/last-report.json (atomic) and prints a JSON summary.
Exit 0 when everything attempted was opened AND verified; 1 otherwise.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from discover import running_session_ids  # noqa: E402
from plan import atomic_write_json, default_state_dir  # noqa: E402


def read_attempts(stream) -> list:
    attempts = []
    for line in stream:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        provider, sid, cwd, ok = parts[0], parts[1], parts[2], parts[3]
        attempts.append({
            "provider": provider,
            "session_id": sid,
            "cwd": cwd,
            "open_ok": ok == "1",
            "verified": False,
        })
    return attempts


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--timeout", type=float, default=15.0)
    ap.add_argument("--interval", type=float, default=1.5)
    ap.add_argument("--ps-file", default=None, help="single-pass canned table (tests)")
    ap.add_argument("--state-dir", default=None)
    ap.add_argument("--driver", default="")
    ap.add_argument("--open-mode", default="")
    args = ap.parse_args(argv)

    attempts = read_attempts(sys.stdin)
    to_verify = [a for a in attempts if a["open_ok"]]

    deadline = time.monotonic() + max(args.timeout, 0.0)
    while True:
        if args.ps_file:
            ps_text = Path(args.ps_file).read_text(encoding="utf-8", errors="replace")
            running = running_session_ids(ps_text)
        else:
            running = running_session_ids()
        for a in to_verify:
            if not a["verified"] and a["session_id"].lower() in running:
                a["verified"] = True
        if all(a["verified"] for a in to_verify):
            break
        if args.ps_file or time.monotonic() >= deadline:
            break
        time.sleep(max(args.interval, 0.1))

    verified = sum(1 for a in attempts if a["verified"])
    open_fail = sum(1 for a in attempts if not a["open_ok"])
    unverified = [a["session_id"] for a in attempts if a["open_ok"] and not a["verified"]]

    state_dir = Path(args.state_dir) if args.state_dir else default_state_dir()
    report = {
        "created_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "driver": args.driver,
        "open_mode": args.open_mode,
        "requested": len(attempts),
        "open_ok": len(attempts) - open_fail,
        "open_fail": open_fail,
        "verified": verified,
        "unverified": unverified,
        "sessions": attempts,
    }
    report_path = state_dir / "last-report.json"
    atomic_write_json(report_path, report)

    print(json.dumps({
        "report": str(report_path),
        "requested": len(attempts),
        "verified": verified,
        "open_fail": open_fail,
        "unverified": unverified,
    }))
    return 0 if (open_fail == 0 and not unverified) else 1


if __name__ == "__main__":
    raise SystemExit(main())
