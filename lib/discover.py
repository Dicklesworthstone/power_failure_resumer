#!/usr/bin/env python3
"""Discover Codex + Claude Code sessions that likely died together in a power failure.

Prints JSON to stdout:
{
  "boot_time": <epoch|null>,
  "mode": "pre_boot" | "density" | "manual_anchor" | "recent",
  "anchor_mtime": <epoch>,
  "window_seconds": <float>,
  "skipped_running": <int>,
  "sessions": [ { provider, session_id, cwd, mtime, path, title, resume_cmd,
                  is_subagent, is_running }, ... ]
}
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple


UUID_RE = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
    re.I,
)


@dataclass
class Session:
    provider: str  # "codex" | "claude"
    session_id: str
    cwd: str
    mtime: float
    path: str
    title: str
    resume_cmd: str
    is_subagent: bool
    started_hint: str = ""
    is_running: bool = False


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr)


def get_boot_time() -> Optional[float]:
    """Return system boot time as epoch seconds (macOS/Linux best-effort)."""
    try:
        out = subprocess.check_output(["sysctl", "-n", "kern.boottime"], text=True)
        m = re.search(r"sec\s*=\s*(\d+)", out)
        if m:
            return float(m.group(1))
    except Exception:
        pass
    try:
        for line in Path("/proc/stat").read_text().splitlines():
            if line.startswith("btime "):
                return float(line.split()[1])
    except Exception:
        pass
    return None


# UUID immediately after a resume flag: `resume UUID`, `--resume UUID`, `--resume=UUID`
_RESUME_UUID_RE = re.compile(
    # Quotes/escapes may sit before the UUID: `sh -c "cc --resume 'id'"` (or
    # nested \"id\") argv strings keep their inner quoting in ps output.
    r"(?:^|[\s\"'])(?:--)?resume(?:\s+|=)[\"'\\]*(" + UUID_RE.pattern + r")",
    re.I,
)


def running_session_ids(ps_text: Optional[str] = None) -> set:
    """Session UUIDs from live process args that look like an active resume.

    Catches `cod resume <id>` / `cc|claude --resume <id>` style invocations so a
    second pfr run does not re-open sessions already brought back. Fresh (never
    resumed) sessions carry no UUID in argv and cannot be detected this way.

    Matching is tight: the UUID must sit right after a resume flag, not merely
    share a command line that happens to mention both words (avoids false
    positives from editors/logs).

    `ps_text` lets tests inject a canned process table.
    """
    if ps_text is None:
        try:
            # BSD no-dash syntax: valid on both macOS ps and Linux procps.
            ps_text = subprocess.check_output(
                ["ps", "axo", "args="], text=True, stderr=subprocess.DEVNULL
            )
        except Exception:
            return set()
    ids: set = set()
    for line in ps_text.splitlines():
        for m in _RESUME_UUID_RE.finditer(line):
            ids.add(m.group(1).lower())
    return ids


def as_dict_payload(obj: object) -> Dict:
    if isinstance(obj, dict):
        return obj
    return {}


def read_first_json_object(path: Path, max_lines: int = 5) -> Optional[dict]:
    """Return first JSON object; prefer session_meta if seen within max_lines."""
    first_any: Optional[dict] = None
    try:
        with path.open("r", encoding="utf-8", errors="replace") as fh:
            for _ in range(max_lines):
                line = fh.readline()
                if not line:
                    break
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(obj, dict):
                    continue
                if obj.get("type") == "session_meta":
                    return obj
                if first_any is None:
                    first_any = obj
    except OSError:
        return None
    return first_any


def scan_jsonl_for_cwd(path: Path, max_lines: int = 80) -> Optional[str]:
    try:
        with path.open("r", encoding="utf-8", errors="replace") as fh:
            for i, line in enumerate(fh):
                if i >= max_lines:
                    break
                if '"cwd"' not in line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                cwd = obj.get("cwd")
                if isinstance(cwd, str) and cwd.startswith("/"):
                    return cwd
    except OSError:
        return None
    return None


def extract_uuid_from_name(name: str) -> Optional[str]:
    m = UUID_RE.search(name)
    return m.group(0) if m else None


def is_codex_subagent(meta_payload: dict) -> bool:
    if meta_payload.get("thread_source") == "subagent":
        return True
    src = meta_payload.get("source")
    if isinstance(src, dict) and "subagent" in src:
        return True
    # Nested agent with nickname + parent, unless explicitly a user/cli top-level thread
    if meta_payload.get("agent_nickname") and meta_payload.get("parent_thread_id"):
        if meta_payload.get("thread_source") not in (None, "user", "cli"):
            return True
    return False


def discover_codex(sessions_root: Path, since_mtime: float) -> List[Session]:
    out: List[Session] = []
    if not sessions_root.is_dir():
        return out

    for path in sessions_root.rglob("rollout-*.jsonl"):
        try:
            st = path.stat()
        except OSError:
            continue
        if st.st_mtime < since_mtime:
            continue

        # session_meta can sit past early housekeeping lines; casr scans ~64 too.
        first = read_first_json_object(path, max_lines=64)
        payload: dict = {}
        if first:
            if first.get("type") == "session_meta":
                payload = as_dict_payload(first.get("payload"))
            elif "payload" in first:
                payload = as_dict_payload(first.get("payload"))

        file_id = extract_uuid_from_name(path.name)
        # Resume id must match what `cod resume` accepts: rollout id (filename / payload.id).
        # Prefer the filename UUID: always present and correct even when the first JSON
        # object is not session_meta (payload.id could then be an event id, not the rollout).
        # Do not prefer parent session_id — that can point at a different thread.
        resume_id = file_id or payload.get("id") or payload.get("session_id")
        if not resume_id:
            continue
        resume_id = str(resume_id)

        cwd = payload.get("cwd")
        if not isinstance(cwd, str) or not cwd:
            cwd = str(Path.home() / "projects")

        sub = is_codex_subagent(payload) if payload else False

        title_bits = []
        if payload.get("agent_nickname"):
            title_bits.append(str(payload["agent_nickname"]))
        title_bits.append(Path(cwd).name or cwd)
        title = " · ".join(title_bits)

        out.append(
            Session(
                provider="codex",
                session_id=resume_id,
                cwd=cwd,
                mtime=st.st_mtime,
                path=str(path),
                title=title,
                resume_cmd=f"cod resume {resume_id}",
                is_subagent=sub,
                started_hint=str(payload.get("timestamp") or ""),
            )
        )
    return out


def discover_claude(projects_root: Path, since_mtime: float) -> List[Session]:
    """Top-level Claude sessions: <projects_root>/<project-dir>/<uuid>.jsonl only."""
    out: List[Session] = []
    if not projects_root.is_dir():
        return out

    try:
        project_dirs = [p for p in projects_root.iterdir() if p.is_dir()]
    except OSError:
        return out

    for project_dir in project_dirs:
        try:
            entries = list(project_dir.iterdir())
        except OSError:
            continue
        for path in entries:
            if not path.is_file() or path.suffix != ".jsonl":
                continue
            sid = path.stem
            if not UUID_RE.fullmatch(sid):
                continue
            try:
                st = path.stat()
            except OSError:
                continue
            if st.st_mtime < since_mtime:
                continue

            cwd = scan_jsonl_for_cwd(path) or ""
            if not cwd:
                # Claude encodes project dirs as ANY non-alphanumeric char → "-"
                # (not just "/"), so this reverse-decode is doubly lossy. Only
                # trust it when the decoded directory actually exists.
                enc = project_dir.name
                decoded = ""
                if enc.startswith("-"):
                    decoded = "/" + enc[1:].replace("-", "/")
                if decoded and Path(decoded).is_dir():
                    cwd = decoded
                else:
                    cwd = str(Path.home() / "projects")

            out.append(
                Session(
                    provider="claude",
                    session_id=sid,
                    cwd=cwd,
                    mtime=st.st_mtime,
                    path=str(path),
                    title=Path(cwd).name or cwd,
                    resume_cmd=f"cc --resume {sid}",
                    is_subagent=False,
                )
            )
    return out


def dedupe_sessions(sessions: Sequence[Session]) -> List[Session]:
    """Keep the newest file per (provider, session_id)."""
    best: Dict[Tuple[str, str], Session] = {}
    for s in sessions:
        key = (s.provider, s.session_id)
        prev = best.get(key)
        if prev is None or s.mtime > prev.mtime:
            best[key] = s
    return sorted(best.values(), key=lambda s: s.mtime, reverse=True)


def densest_cluster(
    sessions: Sequence[Session], window: float
) -> Tuple[List[Session], float]:
    """Return sessions in the densest mtime window of size `window`, and anchor mtime.

    On ties (same session count), prefer the *newest* window (rightmost).
    """
    if not sessions:
        return [], 0.0
    if window < 0:
        window = 0.0

    ordered = sorted(sessions, key=lambda s: s.mtime)
    times = [s.mtime for s in ordered]
    best_count = 0
    best_lo = times[0]
    best_hi = times[0]
    j = 0
    for i, t in enumerate(times):
        while j < len(times) and times[j] - t <= window:
            j += 1
        count = j - i
        hi = times[j - 1]
        # Prefer denser; on tie, prefer the newer window (higher hi)
        if count > best_count or (count == best_count and hi >= best_hi):
            best_count = count
            best_lo = t
            best_hi = hi

    anchor = best_hi
    # Inclusive window with tiny float slack
    cluster = [s for s in sessions if best_lo - 0.5 <= s.mtime <= best_hi + 0.5]
    if not cluster:
        cluster = [s for s in sessions if abs(s.mtime - anchor) <= window]
    cluster.sort(key=lambda s: s.mtime, reverse=True)
    return cluster, anchor


def pre_boot_cluster(
    sessions: Sequence[Session], boot: float, lookback: float, slack: float
) -> List[Session]:
    lo = boot - lookback
    hi = boot + slack
    return sorted(
        [s for s in sessions if lo <= s.mtime <= hi],
        key=lambda s: s.mtime,
        reverse=True,
    )


def fmt_ts(epoch: Optional[float]) -> Optional[str]:
    if epoch is None:
        return None
    return datetime.fromtimestamp(epoch).strftime("%Y-%m-%d %H:%M:%S")


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    # Both CLIs support relocating their state dir; honor that here.
    codex_home = os.environ.get("CODEX_HOME") or str(Path.home() / ".codex")
    claude_home = os.environ.get("CLAUDE_HOME") or str(Path.home() / ".claude")
    ap.add_argument(
        "--codex-root",
        default=str(Path(codex_home) / "sessions"),
        help="Codex sessions directory (default: $CODEX_HOME/sessions)",
    )
    ap.add_argument(
        "--claude-root",
        default=str(Path(claude_home) / "projects"),
        help="Claude Code projects directory (default: $CLAUDE_HOME/projects)",
    )
    ap.add_argument(
        "--window",
        type=float,
        default=180.0,
        help="Cluster window in seconds (default: 180)",
    )
    ap.add_argument(
        "--lookback-hours",
        type=float,
        default=48.0,
        help="Only consider sessions modified within this many hours (default: 48)",
    )
    ap.add_argument(
        "--pre-boot-lookback",
        type=float,
        default=900.0,
        help="Seconds before boot to search for crash victims (default: 900)",
    )
    ap.add_argument(
        "--pre-boot-slack",
        type=float,
        default=60.0,
        help="Seconds after boot still accepted (default: 60)",
    )
    ap.add_argument(
        "--include-subagents",
        action="store_true",
        help="Include Codex subagent threads (usually noise)",
    )
    ap.add_argument(
        "--providers",
        default="codex,claude",
        help="Comma list: codex,claude",
    )
    ap.add_argument(
        "--projects-only",
        action="store_true",
        help="Only keep sessions whose cwd is under ~/projects",
    )
    ap.add_argument(
        "--min-cluster",
        type=int,
        default=1,
        help="Minimum sessions required to accept a cluster",
    )
    ap.add_argument(
        "--anchor",
        type=float,
        default=None,
        help="Force cluster anchor mtime (epoch seconds)",
    )
    ap.add_argument(
        "--force-reopen",
        action="store_true",
        help="Offer sessions even if a live process is already resuming them",
    )
    ap.add_argument(
        "--ps-file",
        default=None,
        help="Read process args from this file instead of ps (for tests)",
    )
    ap.add_argument(
        "--fake-boot",
        type=float,
        default=None,
        help="Override detected boot time with this epoch (tests; or PFR_FAKE_BOOT)",
    )
    ap.add_argument(
        "--mode",
        choices=("auto", "pre_boot", "density", "recent"),
        default="auto",
        help="Clustering strategy (default: auto)",
    )
    ap.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Max sessions to return (0 = unlimited); keeps newest by mtime",
    )
    args = ap.parse_args(argv)

    now = time.time()
    since = now - args.lookback_hours * 3600.0
    providers = {p.strip().lower() for p in args.providers.split(",") if p.strip()}
    known = {"codex", "claude"}
    unknown = sorted(providers - known)
    if unknown:
        eprint(f"warning: ignoring unknown providers: {', '.join(unknown)}")
    providers &= known
    if not providers:
        eprint("error: no valid providers (use codex and/or claude)")
        return 2

    sessions: List[Session] = []
    if "codex" in providers:
        sessions.extend(discover_codex(Path(args.codex_root), since))
    if "claude" in providers:
        sessions.extend(discover_claude(Path(args.claude_root), since))

    if not args.include_subagents:
        sessions = [s for s in sessions if not s.is_subagent]

    sessions = dedupe_sessions(sessions)

    if args.projects_only:
        proj = str(Path.home() / "projects")
        sessions = [
            s
            for s in sessions
            if s.cwd == proj or s.cwd.startswith(proj + os.sep)
        ]

    # Mark live resumes for later filtering — but do NOT drop them before clustering.
    # Filtering first would shrink the crash pocket and can make densest_cluster pick
    # an unrelated simultaneous group (e.g. a later work burst).
    ps_text = None
    if args.ps_file:
        try:
            ps_text = Path(args.ps_file).read_text(encoding="utf-8", errors="replace")
        except OSError as e:
            eprint(f"error: cannot read --ps-file: {e}")
            return 2
    running = running_session_ids(ps_text)
    for s in sessions:
        s.is_running = s.session_id.lower() in running

    total_candidates = len(sessions)

    fake_boot = args.fake_boot
    if fake_boot is None and os.environ.get("PFR_FAKE_BOOT"):
        try:
            fake_boot = float(os.environ["PFR_FAKE_BOOT"])
        except ValueError:
            eprint("warning: ignoring non-numeric PFR_FAKE_BOOT")
    boot = fake_boot if fake_boot is not None else get_boot_time()
    mode = args.mode
    anchor: Optional[float] = args.anchor
    cluster: List[Session] = []

    if mode == "auto":
        # Prefer sessions modified around boot, then take the densest simultaneous-death
        # pocket inside that pre-boot set (drops idle sessions from minutes earlier).
        if boot is not None:
            pb = pre_boot_cluster(
                sessions, boot, args.pre_boot_lookback, args.pre_boot_slack
            )
            if pb:
                tight, tight_anchor = densest_cluster(pb, args.window)
                if len(tight) >= args.min_cluster:
                    cluster = tight
                    mode = "pre_boot"
                    anchor = tight_anchor
        if not cluster:
            cluster, dens_anchor = densest_cluster(sessions, args.window)
            mode = "density"
            anchor = dens_anchor
            if args.min_cluster > 1 and len(cluster) < args.min_cluster:
                cluster = []
    elif mode == "pre_boot":
        if boot is None:
            eprint("error: boot time unavailable; cannot use pre_boot mode")
            return 2
        pb = pre_boot_cluster(
            sessions, boot, args.pre_boot_lookback, args.pre_boot_slack
        )
        if pb:
            cluster, dens_anchor = densest_cluster(pb, args.window)
            anchor = dens_anchor
            if args.min_cluster > 1 and len(cluster) < args.min_cluster:
                cluster = []
        else:
            cluster = []
            anchor = boot
    elif mode == "density":
        cluster, dens_anchor = densest_cluster(sessions, args.window)
        anchor = dens_anchor
        if args.min_cluster > 1 and len(cluster) < args.min_cluster:
            cluster = []
    elif mode == "recent":
        if sessions:
            anchor = sessions[0].mtime
            cluster = [s for s in sessions if abs(s.mtime - anchor) <= args.window]
        else:
            anchor = now
            cluster = []

    if args.anchor is not None:
        anchor = args.anchor
        cluster = [s for s in sessions if abs(s.mtime - anchor) <= args.window]
        mode = "manual_anchor"

    # Drop already-running members of the *chosen* cluster (unless forced).
    skipped_running = 0
    if not args.force_reopen:
        still_running = [s for s in cluster if s.is_running]
        skipped_running = len(still_running)
        cluster = [s for s in cluster if not s.is_running]

    # Display order: newest first (provider is secondary only for ties)
    cluster.sort(key=lambda s: (-s.mtime, s.provider, s.session_id))

    # Score confidence on the FULL cluster before any display limit truncates it.
    conf_level: Optional[str] = None
    conf_reasons: List[str] = []
    try:
        import confidence as _confidence

        conf_level, conf_reasons = _confidence.score_confidence(
            mode=mode,
            boot_time=boot,
            anchor_mtime=anchor,
            window_seconds=args.window,
            pre_boot_lookback=args.pre_boot_lookback,
            session_count=len(cluster),
            skipped_running=skipped_running,
            session_mtimes=[s.mtime for s in cluster],
        )
    except ImportError:
        pass

    # Limit keeps the newest N (already sorted by -mtime)
    if args.limit and len(cluster) > args.limit:
        cluster = cluster[: args.limit]

    result = {
        "boot_time": boot,
        "boot_time_human": fmt_ts(boot),
        "mode": mode,
        "anchor_mtime": anchor,
        "anchor_mtime_human": fmt_ts(anchor),
        "window_seconds": args.window,
        "pre_boot_lookback": args.pre_boot_lookback,
        "lookback_hours": args.lookback_hours,
        "total_candidates_scanned": total_candidates,
        "skipped_running": skipped_running,
        "sessions": [asdict(s) for s in cluster],
        "session_count": len(cluster),
    }
    if conf_level is not None:
        result["confidence"] = conf_level
        result["confidence_reasons"] = conf_reasons
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
