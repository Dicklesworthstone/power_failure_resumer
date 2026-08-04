#!/usr/bin/env python3
"""NTM attribution + recorded-model resume: discovery must exclude sessions
whose first user message matches an ntm send-history prompt (unless
--include-ntm), and must pin each session's recorded model/effort in the
reconstructed resume command."""

import io
import json
import os
import sys
import tempfile
import time
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
import discover  # noqa: E402

NTM_PROMPT = (
    "PANE 2 OWNERSHIP: exact axisymmetric geometry. Claim Bead fs-b8.2 with br "
    "and read its full body before writing any code. Coordinate with panes 3-5 "
    "through agent mail and never touch files reserved by another pane."
)
HUMAN_PROMPT = (
    "First read ALL of the AGENTS.md file and README.md file super carefully "
    "and understand ALL of both!"
)

CODEX_UUID_NTM = "019fc925-a15e-7961-9a9c-7e62ef6c0001"
CODEX_UUID_TOP = "019fc925-a15e-7961-9a9c-7e62ef6c0002"
CLAUDE_UUID_NTM = "ba9de0d5-51bb-40f8-9029-8ea3bcfc0003"
CLAUDE_UUID_TOP = "ba9de0d5-51bb-40f8-9029-8ea3bcfc0004"


def write_codex(root: Path, uuid: str, first_user: str, model: str, effort: str) -> Path:
    day = root / "2026" / "08" / "03"
    day.mkdir(parents=True, exist_ok=True)
    path = day / f"rollout-2026-08-03T16-00-00-{uuid}.jsonl"
    lines = [
        {"type": "session_meta", "timestamp": "t", "payload": {
            "id": uuid, "cwd": "/tmp", "timestamp": "t", "thread_source": "user"}},
        {"type": "turn_context", "timestamp": "t", "payload": {
            "model": model, "effort": effort, "cwd": "/tmp"}},
        {"type": "response_item", "timestamp": "t", "payload": {
            "type": "message", "role": "user",
            "content": [{"type": "input_text", "text": first_user}]}},
    ]
    path.write_text("\n".join(json.dumps(x) for x in lines) + "\n")
    return path


def write_claude(root: Path, uuid: str, first_user: str, model: str) -> Path:
    proj = root / "-tmp"
    proj.mkdir(parents=True, exist_ok=True)
    path = proj / f"{uuid}.jsonl"
    lines = [
        {"type": "user", "cwd": "/tmp", "sessionId": uuid,
         "message": {"role": "user", "content": first_user}},
        {"type": "assistant", "cwd": "/tmp",
         "message": {"role": "assistant", "model": model,
                     "content": [{"type": "text", "text": "on it"}]}},
    ]
    path.write_text("\n".join(json.dumps(x) for x in lines) + "\n")
    return path


def run_discovery(codex_root, claude_root, history, ntm_data=None, extra=()):
    argv = [
        "--codex-root", str(codex_root),
        "--claude-root", str(claude_root),
        "--ntm-history", str(history),
        "--ntm-data", str(ntm_data if ntm_data is not None else history.parent / "absent-data"),
        "--mode", "recent",
        "--window", "3600",
        "--lookback-hours", "8760000",
        *extra,
    ]
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = discover.main(argv)
    assert rc == 0, f"discovery failed rc={rc}"
    return json.loads(buf.getvalue())


def main() -> None:
    tmp = Path(tempfile.mkdtemp(prefix="pfr-ntm-", dir=str(Path(__file__).parent / "logs")))
    codex_root = tmp / "codex"
    claude_root = tmp / "claude"

    paths = [
        write_codex(codex_root, CODEX_UUID_NTM, NTM_PROMPT, "gpt-5.6-terra", "high"),
        write_codex(codex_root, CODEX_UUID_TOP, HUMAN_PROMPT, "gpt-5.6-sol", "ultra"),
        write_claude(claude_root, CLAUDE_UUID_NTM, NTM_PROMPT, "claude-fable-5"),
        write_claude(claude_root, CLAUDE_UUID_TOP, HUMAN_PROMPT, "claude-fable-5"),
    ]
    now = time.time()
    for p in paths:
        os.utime(p, (now, now))

    history = tmp / "history.jsonl"
    history.write_text(
        json.dumps({"prompt": NTM_PROMPT, "session": "fs", "targets": ["2"]}) + "\n"
        + json.dumps({"prompt": "short"}) + "\n"
    )

    # Default: ntm-matching sessions excluded from the cluster.
    data = run_discovery(codex_root, claude_root, history)
    ids = {s["session_id"] for s in data["sessions"]}
    assert CODEX_UUID_NTM not in ids, "ntm codex session must be excluded"
    assert CLAUDE_UUID_NTM not in ids, "ntm claude session must be excluded"
    assert CODEX_UUID_TOP in ids and CLAUDE_UUID_TOP in ids, f"top-level sessions missing: {ids}"
    assert data["skipped_ntm"] == 2, f"skipped_ntm={data['skipped_ntm']}"

    # Recorded model/effort pinned into the resume command.
    by_id = {s["session_id"]: s for s in data["sessions"]}
    cod = by_id[CODEX_UUID_TOP]
    assert cod["model"] == "gpt-5.6-sol" and cod["effort"] == "ultra", cod
    assert cod["resume_cmd"] == (
        f"cod resume {CODEX_UUID_TOP} -m gpt-5.6-sol -c model_reasoning_effort=ultra"
    ), cod["resume_cmd"]
    cc = by_id[CLAUDE_UUID_TOP]
    assert cc["model"] == "claude-fable-5", cc
    assert cc["resume_cmd"] == (
        f"cc --resume {CLAUDE_UUID_TOP} --model claude-fable-5"
    ), cc["resume_cmd"]

    # --include-ntm restores the ntm sessions.
    data = run_discovery(codex_root, claude_root, history, extra=("--include-ntm",))
    ids = {s["session_id"] for s in data["sessions"]}
    assert CODEX_UUID_NTM in ids and CLAUDE_UUID_NTM in ids, f"--include-ntm ignored: {ids}"
    assert data["skipped_ntm"] == 0

    # Missing history file: nothing excluded, no crash.
    data = run_discovery(codex_root, claude_root, tmp / "absent.jsonl")
    assert len(data["sessions"]) == 4 and data["skipped_ntm"] == 0

    # Prefix tolerance: transcript records the ntm prompt with appended text.
    long_variant = NTM_PROMPT + " Additional appended boilerplate from the send wrapper."
    p = write_codex(codex_root, "019fc925-a15e-7961-9a9c-7e62ef6c0005", long_variant,
                    "gpt-5.6-terra", "high")
    os.utime(p, (now, now))
    data = run_discovery(codex_root, claude_root, history)
    ids = {s["session_id"] for s in data["sessions"]}
    assert "019fc925-a15e-7961-9a9c-7e62ef6c0005" not in ids, "prefix variant must be excluded"

    # Habitual-opener regression: users reuse the same short opening line in
    # hand-typed sessions AND inside longer ntm prompts. A top-level session
    # whose entire first message merely prefixes a recorded ntm prompt must
    # NOT be excluded (the shared text is below the prefix-evidence bar).
    history_habit = tmp / "history-habit.jsonl"
    history_habit.write_text(json.dumps({
        "prompt": HUMAN_PROMPT + " Then use your code investigation agent mode "
        "to fully understand the architecture before touching anything.",
    }) + "\n")
    habit_uuid = "019fc925-a15e-7961-9a9c-7e62ef6c0008"
    p = write_codex(codex_root, habit_uuid, HUMAN_PROMPT, "gpt-5.6-sol", "ultra")
    os.utime(p, (now, now))
    data = run_discovery(codex_root, claude_root, history_habit)
    ids = {s["session_id"] for s in data["sessions"]}
    assert habit_uuid in ids, "habitual opener prefixing an ntm prompt must NOT be excluded"

    # Manifest layer: a pane spawned with an explicit model in a project dir
    # attributes matching sessions even when no send is in the history (ntm
    # swarms can be driven by mechanisms that bypass history.jsonl).
    ntm_data = tmp / "ntm-data"
    (ntm_data / "manifests").mkdir(parents=True)
    (ntm_data / "manifests" / "swarm.json").write_text(json.dumps({
        "session": "swarm", "project_dir": "/tmp",
        "agents": [{"pane_id": "%1", "type": "cod",
                    "command": "codex --flag -m gpt-5.6-terra -c x=y"}],
    }))
    manifest_uuid = "019fc925-a15e-7961-9a9c-7e62ef6c0006"
    p = write_codex(codex_root, manifest_uuid,
                    "A prompt ntm never recorded anywhere.", "gpt-5.6-terra", "high")
    os.utime(p, (now, now))
    data = run_discovery(codex_root, claude_root, tmp / "absent.jsonl", ntm_data=ntm_data)
    ids = {s["session_id"] for s in data["sessions"]}
    assert manifest_uuid not in ids, "manifest (cwd+provider+model) match must be excluded"
    # Different model in the same dir stays (that's the human session shape).
    assert CODEX_UUID_TOP in ids, "non-matching model must not be excluded by manifest"

    # Checkpoint layer: persisted provider session UUIDs are definitive.
    ckpt = ntm_data / "checkpoints" / "swarm" / "20260803-auto"
    ckpt.mkdir(parents=True)
    (ckpt / "session.json").write_text(json.dumps({
        "panes": [{"index": 1, "session_id": CLAUDE_UUID_TOP}]}))
    data = run_discovery(codex_root, claude_root, tmp / "absent.jsonl", ntm_data=ntm_data)
    ids = {s["session_id"] for s in data["sessions"]}
    assert CLAUDE_UUID_TOP not in ids, "checkpoint session_id match must be excluded"

    # Last-message layer: human-looking first message, ntm send later.
    late_uuid = "019fc925-a15e-7961-9a9c-7e62ef6c0007"
    day = codex_root / "2026" / "08" / "03"
    path = day / f"rollout-2026-08-03T16-30-00-{late_uuid}.jsonl"
    lines = [
        {"type": "session_meta", "timestamp": "t", "payload": {
            "id": late_uuid, "cwd": "/tmp", "thread_source": "user"}},
        {"type": "response_item", "timestamp": "t", "payload": {
            "type": "message", "role": "user",
            "content": [{"type": "input_text", "text": HUMAN_PROMPT}]}},
        {"type": "response_item", "timestamp": "t", "payload": {
            "type": "message", "role": "user",
            "content": [{"type": "input_text", "text": NTM_PROMPT}]}},
    ]
    path.write_text("\n".join(json.dumps(x) for x in lines) + "\n")
    os.utime(path, (now, now))
    data = run_discovery(codex_root, claude_root, history)
    ids = {s["session_id"] for s in data["sessions"]}
    assert late_uuid not in ids, "ntm send as LAST user message must be excluded"

    # Phrasing heuristic: a swarm that left no ntm record (no history entry,
    # no manifest, no checkpoint) is still caught by unmistakable
    # addressed-as-a-pane phrasing — while lowercase mentions of the ntm TOOL
    # (working in its repo) never trigger it.
    wave_uuid = "019fc925-a15e-7961-9a9c-7e62ef6c0009"
    p = write_codex(codex_root, wave_uuid,
                    "You are the Wave 1 independent reviewer in a six-pane NTM "
                    "campaign. Work directly in this pane; do not spawn agents.",
                    "gpt-5.6-terra", "high")
    os.utime(p, (now, now))
    tool_uuid = "019fc925-a15e-7961-9a9c-7e62ef6c000a"
    p = write_codex(codex_root, tool_uuid,
                    "Please fix the bug in ntm where robot sends are not "
                    "recorded in history.jsonl and add a regression test.",
                    "gpt-5.6-sol", "ultra")
    os.utime(p, (now, now))
    data = run_discovery(codex_root, claude_root, history)
    ids = {s["session_id"] for s in data["sessions"]}
    assert wave_uuid not in ids, "pane-addressed phrasing must be excluded"
    assert tool_uuid in ids, "mentioning the ntm tool must NOT be excluded"

    # The phrasing fallback must also fire when ntm exists but recorded
    # nothing (observed: swarm with no history entry, no manifest, empty
    # state.db). An existing-but-empty ntm data dir is enough presence.
    empty_ntm = tmp / "ntm-empty"
    empty_ntm.mkdir()
    data = run_discovery(codex_root, claude_root, tmp / "absent.jsonl", ntm_data=empty_ntm)
    ids = {s["session_id"] for s in data["sessions"]}
    assert wave_uuid not in ids, "phrasing must work with zero ntm records"
    # And a machine without ntm at all attributes nothing.
    data = run_discovery(codex_root, claude_root, tmp / "absent.jsonl")
    ids = {s["session_id"] for s in data["sessions"]}
    assert wave_uuid in ids, "no ntm on the machine → no ntm attribution"

    print("ntm + model OK")


if __name__ == "__main__":
    main()
