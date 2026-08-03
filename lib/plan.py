#!/usr/bin/env python3
"""Save/load durable resume plans (schema v1).

Separating *discover/decide* from *open* keeps recovery stable under stress:
rediscovery drifts as sessions age, get resumed manually, or new work starts.

  plan.py save [--state-dir DIR] [--extra-path PATH]   < discovery.json
      Builds a plan from discover.py JSON on stdin, atomically writes
      <state-dir>/last-plan.json (0600, dir 0700), archives a copy under
      <state-dir>/plans/ (newest 20 kept), and prints a one-line JSON summary.

  plan.py load --path PATH [--force] [--fake-boot EPOCH]
      Validates schema_version, checks staleness (plan from a different boot,
      or older than 24h), and re-emits the plan as discovery-shaped JSON so
      the shell pipeline can consume it unchanged. Exit codes: 0 ok,
      2 invalid, 3 stale (use --force to override).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import Dict, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

import confidence  # noqa: E402
from discover import fmt_ts, get_boot_time  # noqa: E402

ARCHIVE_KEEP = 20
STALE_AGE_SECONDS = 24 * 3600.0
BOOT_MATCH_SLACK = 5.0


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr)


def default_state_dir() -> Path:
    if os.environ.get("PFR_STATE_DIR"):
        return Path(os.environ["PFR_STATE_DIR"])
    xdg = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(xdg) / "pfr"


def atomic_write_json(path: Path, obj: Dict, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".plan-tmp-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, indent=2)
            fh.write("\n")
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def cmd_save(args: argparse.Namespace) -> int:
    try:
        discovery = json.load(sys.stdin)
    except Exception as e:
        eprint(f"error: invalid discovery JSON on stdin: {e}")
        return 2

    created_at = datetime.now().astimezone().isoformat(timespec="seconds")
    plan = confidence.build_plan(discovery, created_at=created_at)

    state_dir = Path(args.state_dir) if args.state_dir else default_state_dir()
    state_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(state_dir, 0o700)

    last = state_dir / "last-plan.json"
    atomic_write_json(last, plan)

    archive_dir = state_dir / "plans"
    stamp = created_at.replace(":", "-").replace("+", "p")
    atomic_write_json(archive_dir / f"plan-{stamp}.json", plan)
    archived = sorted(archive_dir.glob("plan-*.json"))
    for old in archived[:-ARCHIVE_KEEP]:
        try:
            old.unlink()
        except OSError:
            pass

    if args.extra_path:
        atomic_write_json(Path(args.extra_path), plan)

    print(json.dumps({
        "saved": str(last),
        "extra": args.extra_path or None,
        "confidence": plan["confidence"],
        "session_count": len(plan["sessions"]),
    }))
    return 0


def load_plan(path: Path) -> Optional[Dict]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        eprint(f"error: plan not found: {path}")
    except Exception as e:
        eprint(f"error: cannot parse plan {path}: {e}")
    return None


def staleness(plan: Dict, now: float, current_boot: Optional[float]) -> list:
    """Return list of human-readable staleness reasons (empty = fresh)."""
    problems = []
    created = plan.get("created_at")
    if created:
        try:
            created_epoch = datetime.fromisoformat(created).timestamp()
            age = now - created_epoch
            if age > STALE_AGE_SECONDS:
                problems.append(f"plan is {age / 3600.0:.1f}h old (>24h)")
        except ValueError:
            problems.append(f"unparseable created_at: {created!r}")
    plan_boot = plan.get("boot_time")
    if plan_boot is not None and current_boot is not None:
        if abs(float(plan_boot) - current_boot) > BOOT_MATCH_SLACK:
            problems.append(
                f"plan was made for boot {fmt_ts(float(plan_boot))}, "
                f"current boot is {fmt_ts(current_boot)} — the machine rebooted since"
            )
    return problems


def cmd_load(args: argparse.Namespace) -> int:
    plan = load_plan(Path(args.path))
    if plan is None:
        return 2
    version = plan.get("schema_version")
    if version != confidence.PLAN_SCHEMA_VERSION:
        eprint(f"error: unsupported plan schema_version {version!r} (want "
               f"{confidence.PLAN_SCHEMA_VERSION}); re-run discovery instead")
        return 2

    current_boot = args.fake_boot
    if current_boot is None and os.environ.get("PFR_FAKE_BOOT"):
        try:
            current_boot = float(os.environ["PFR_FAKE_BOOT"])
        except ValueError:
            pass
    if current_boot is None:
        current_boot = get_boot_time()

    problems = staleness(plan, time.time(), current_boot)
    if problems and not args.force:
        for p in problems:
            eprint(f"stale plan: {p}")
        eprint("refusing to open a stale plan — re-run discovery, or pass --force-stale-plan")
        return 3
    if problems:
        for p in problems:
            eprint(f"warning (forced): {p}")

    out = dict(plan)
    out["anchor_mtime_human"] = fmt_ts(plan.get("anchor_mtime"))
    out["session_count"] = len(plan.get("sessions") or [])
    out["from_plan"] = args.path
    json.dump(out, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("save", help="build + persist plan from discovery JSON on stdin")
    sp.add_argument("--state-dir", default=None)
    sp.add_argument("--extra-path", default=None, help="also write plan to this path")

    lp = sub.add_parser("load", help="validate + re-emit a plan as discovery JSON")
    lp.add_argument("--path", required=True)
    lp.add_argument("--force", action="store_true", help="allow stale plans")
    lp.add_argument("--fake-boot", type=float, default=None)

    args = ap.parse_args(argv)
    if args.cmd == "save":
        return cmd_save(args)
    return cmd_load(args)


if __name__ == "__main__":
    raise SystemExit(main())
