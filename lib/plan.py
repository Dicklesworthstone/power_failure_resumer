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
import math
import os
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import Dict, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

import confidence  # noqa: E402
from discover import UUID_RE, fmt_ts, get_boot_time  # noqa: E402

ARCHIVE_KEEP = 20
STALE_AGE_SECONDS = 24 * 3600.0
BOOT_MATCH_SLACK = 5.0
FUTURE_TIME_SLACK = 5 * 60.0
VALID_MODES = frozenset({"pre_boot", "density", "recent", "manual_anchor"})
VALID_CONFIDENCE = frozenset({confidence.HIGH, confidence.MEDIUM, confidence.LOW})


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
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
        # Persist the directory entry too; otherwise a sudden power loss can
        # retain the file contents but lose the atomic rename.
        try:
            dir_fd = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        except OSError:
            # Some filesystems do not support directory fsync. The file itself
            # is still synced and atomically replaced.
            pass
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def archives_to_prune(paths, keep: int = ARCHIVE_KEEP) -> list[Path]:
    """Select oldest archive paths; deletion remains an explicit caller action."""
    ordered = sorted(Path(path) for path in paths)
    if keep <= 0:
        return ordered
    return ordered[:-keep]


def cmd_save(args: argparse.Namespace) -> int:
    try:
        discovery = json.load(sys.stdin)
    except Exception as e:
        eprint(f"error: invalid discovery JSON on stdin: {e}")
        return 2

    created_at = datetime.now().astimezone().isoformat(timespec="microseconds")
    plan = confidence.build_plan(discovery, created_at=created_at)

    if args.extra_only and not args.extra_path:
        eprint("error: --extra-only requires --extra-path")
        return 2

    last: Optional[Path] = None
    if not args.extra_only:
        state_dir = Path(args.state_dir) if args.state_dir else default_state_dir()
        state_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(state_dir, 0o700)

        last = state_dir / "last-plan.json"
        atomic_write_json(last, plan)

        archive_dir = state_dir / "plans"
        stamp = created_at.replace(":", "-").replace("+", "p")
        atomic_write_json(archive_dir / f"plan-{stamp}.json", plan)
        for old in archives_to_prune(archive_dir.glob("plan-*.json")):
            try:
                old.unlink()
            except OSError:
                pass

    if args.extra_path:
        atomic_write_json(Path(args.extra_path), plan)

    saved_path = Path(args.extra_path) if args.extra_only else last
    print(json.dumps({
        "saved": str(saved_path),
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


def validate_plan(plan: object) -> list[str]:
    """Return schema-v1 structural errors before staleness or execution."""
    if not isinstance(plan, dict):
        return ["top-level value must be an object"]

    errors: list[str] = []
    created = plan.get("created_at")
    if not isinstance(created, str) or not created:
        errors.append("created_at must be a non-empty ISO-8601 string")
    else:
        try:
            parsed = datetime.fromisoformat(created)
            if parsed.tzinfo is None:
                errors.append("created_at must include a timezone")
        except ValueError:
            errors.append("created_at must be valid ISO-8601")

    def finite_number(name: str, *, nullable: bool = False, nonnegative: bool = False) -> None:
        value = plan.get(name)
        if nullable and value is None:
            return
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            errors.append(f"{name} must be a number" + (" or null" if nullable else ""))
            return
        if not math.isfinite(float(value)) or (nonnegative and value < 0):
            qualifier = "finite non-negative" if nonnegative else "finite"
            errors.append(f"{name} must be {qualifier}")

    finite_number("boot_time", nullable=True)
    finite_number("anchor_mtime", nullable=True)
    finite_number("window_seconds", nonnegative=True)
    finite_number("pre_boot_lookback", nonnegative=True)

    if plan.get("mode") not in VALID_MODES:
        errors.append(f"mode must be one of {sorted(VALID_MODES)}")
    if plan.get("confidence") not in VALID_CONFIDENCE:
        errors.append(f"confidence must be one of {sorted(VALID_CONFIDENCE)}")
    reasons = plan.get("confidence_reasons")
    if not isinstance(reasons, list) or any(not isinstance(item, str) for item in reasons):
        errors.append("confidence_reasons must be a list of strings")

    for name in ("total_candidates_scanned", "skipped_running"):
        value = plan.get(name)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            errors.append(f"{name} must be a non-negative integer")

    sessions = plan.get("sessions")
    if not isinstance(sessions, list):
        errors.append("sessions must be a list")
        return errors

    for index, session in enumerate(sessions):
        prefix = f"sessions[{index}]"
        if not isinstance(session, dict):
            errors.append(f"{prefix} must be an object")
            continue
        provider = session.get("provider")
        sid = session.get("session_id")
        cwd = session.get("cwd")
        if provider not in ("codex", "claude"):
            errors.append(f"{prefix}.provider must be codex or claude")
        if not isinstance(sid, str) or not UUID_RE.fullmatch(sid):
            errors.append(f"{prefix}.session_id must be an exact UUID")
        if not isinstance(cwd, str) or not Path(cwd).is_absolute():
            errors.append(f"{prefix}.cwd must be an absolute path")
        mtime = session.get("mtime")
        if (
            isinstance(mtime, bool)
            or not isinstance(mtime, (int, float))
            or not math.isfinite(float(mtime))
        ):
            errors.append(f"{prefix}.mtime must be finite")
        for name in ("path", "title"):
            if not isinstance(session.get(name), str):
                errors.append(f"{prefix}.{name} must be a string")
        for name in ("is_subagent", "is_running"):
            if not isinstance(session.get(name), bool):
                errors.append(f"{prefix}.{name} must be boolean")
    return errors


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
            elif age < -FUTURE_TIME_SLACK:
                problems.append(f"plan created_at is {-age / 60.0:.1f}m in the future")
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

    validation_errors = validate_plan(plan)
    if validation_errors:
        for problem in validation_errors:
            eprint(f"error: invalid plan: {problem}")
        return 2

    current_boot = args.fake_boot
    if current_boot is not None and not math.isfinite(current_boot):
        eprint("error: --fake-boot must be finite")
        return 2
    if current_boot is None and os.environ.get("PFR_FAKE_BOOT"):
        try:
            current_boot = float(os.environ["PFR_FAKE_BOOT"])
            if not math.isfinite(current_boot):
                raise ValueError
        except ValueError:
            eprint("warning: ignoring non-finite or non-numeric PFR_FAKE_BOOT")
            current_boot = None
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
    out["sessions"] = []
    for session in plan["sessions"]:
        entry = dict(session)
        sid = entry["session_id"]
        entry["resume_cmd"] = (
            f"cod resume {sid}"
            if entry["provider"] == "codex"
            else f"cc --resume {sid}"
        )
        out["sessions"].append(entry)
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
    sp.add_argument(
        "--extra-only",
        action="store_true",
        help="write only --extra-path; do not update last-plan or archives",
    )

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
