#!/usr/bin/env python3
"""Pure crash-confidence scoring + resume-plan (schema v1) construction.

No I/O, no Ghostty, no clock reads — everything comes in via arguments so the
rubric can be locked in unit tests.

Rubric (normative):
  HIGH   — only ``mode == "pre_boot"`` with a real boot time, cluster size >= 3,
           anchor within ``window_seconds`` of boot, and a tight pocket
           (mtime span <= window). Never HIGH for density-only mode.
  MEDIUM — any other genuine pre_boot cluster (small or loose), or a density
           cluster of >= 5 whose anchor lies within ``pre_boot_lookback`` of
           boot.
  LOW    — everything else, notably dense pockets far from boot (the "busy
           afternoon" trap) and recent/manual modes.

Cluster size counts sessions *offered plus already-running ones*: a session
that is already resumed still died in the crash and still evidences it.
"""

from __future__ import annotations

from typing import Dict, List, Optional, Sequence, Tuple

HIGH = "high"
MEDIUM = "medium"
LOW = "low"

PLAN_SCHEMA_VERSION = 1


def score_confidence(
    mode: str,
    boot_time: Optional[float],
    anchor_mtime: Optional[float],
    window_seconds: float,
    pre_boot_lookback: float,
    session_count: int,
    skipped_running: int,
    session_mtimes: Sequence[float],
) -> Tuple[str, List[str]]:
    """Return (confidence, reasons). Pure function of its inputs."""
    n = session_count + skipped_running
    reasons: List[str] = [f"mode={mode}", f"cluster_size={n}"]
    if skipped_running:
        reasons.append(f"already_running={skipped_running}")

    span = (max(session_mtimes) - min(session_mtimes)) if session_mtimes else 0.0

    if mode == "pre_boot" and boot_time is not None and anchor_mtime is not None and n >= 1:
        gap = boot_time - anchor_mtime  # seconds the cluster died before boot
        tight = span <= window_seconds
        reasons.append(f"anchor_gap_to_boot={round(gap, 1)}s")
        reasons.append(f"pocket_span={round(span, 1)}s")
        if n >= 3 and abs(gap) <= window_seconds and tight:
            reasons.append("pre_boot_tight_pocket")
            return HIGH, reasons
        if n < 3:
            reasons.append("small_pre_boot_cluster")
        if abs(gap) > window_seconds:
            reasons.append("anchor_far_from_boot")
        if not tight:
            reasons.append("loose_pocket")
        return MEDIUM, reasons

    if mode == "density" and n >= 5 and boot_time is not None and anchor_mtime is not None:
        if abs(boot_time - anchor_mtime) <= pre_boot_lookback:
            reasons.append("dense_pocket_near_boot")
            return MEDIUM, reasons
        reasons.append("dense_pocket_far_from_boot")

    if mode == "density":
        reasons.append("density_only_never_high")
    return LOW, reasons


def score_discovery(discovery: Dict) -> Tuple[str, List[str]]:
    """Score a discover.py result dict."""
    sessions = discovery.get("sessions") or []
    return score_confidence(
        mode=str(discovery.get("mode") or ""),
        boot_time=discovery.get("boot_time"),
        anchor_mtime=discovery.get("anchor_mtime"),
        window_seconds=float(discovery.get("window_seconds") or 0.0),
        pre_boot_lookback=float(discovery.get("pre_boot_lookback") or 0.0),
        session_count=len(sessions),
        skipped_running=int(discovery.get("skipped_running") or 0),
        session_mtimes=[s["mtime"] for s in sessions if "mtime" in s],
    )


_SESSION_FIELDS = (
    "provider", "session_id", "cwd", "mtime", "path",
    "resume_cmd", "title", "preview", "is_subagent", "is_running",
    "model", "effort", "is_ntm",
)


def build_plan(discovery: Dict, created_at: str) -> Dict:
    """Build a schema-v1 resume plan from a discover.py result dict.

    ``created_at`` is injected (ISO-8601) so plan construction stays pure.

    Prefer confidence fields already set by discover.py (scored on the full crash
    pocket before --limit truncation). Re-scoring the truncated session list would
    falsely demote HIGH → MEDIUM when the user passed --limit.
    """
    if discovery.get("confidence") is not None and "confidence_reasons" in discovery:
        conf = str(discovery["confidence"])
        reasons = list(discovery.get("confidence_reasons") or [])
    else:
        conf, reasons = score_discovery(discovery)
    sessions = []
    for s in discovery.get("sessions") or []:
        entry = {k: s.get(k) for k in _SESSION_FIELDS if k in s}
        entry.setdefault("preview", "")
        sessions.append(entry)
    return {
        "schema_version": PLAN_SCHEMA_VERSION,
        "created_at": created_at,
        "boot_time": discovery.get("boot_time"),
        "boot_time_human": discovery.get("boot_time_human"),
        "mode": discovery.get("mode"),
        "window_seconds": discovery.get("window_seconds"),
        "pre_boot_lookback": discovery.get("pre_boot_lookback"),
        "anchor_mtime": discovery.get("anchor_mtime"),
        "confidence": conf,
        "confidence_reasons": reasons,
        "total_candidates_scanned": discovery.get("total_candidates_scanned"),
        "skipped_running": discovery.get("skipped_running"),
        "sessions": sessions,
    }
