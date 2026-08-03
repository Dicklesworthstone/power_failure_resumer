#!/usr/bin/env python3
"""Generate session-file fixtures under tests/fixtures/generated/.

Scenario (all times relative to meta.json fake_boot):

  crash cluster (dense pocket just before boot):
    codex  C1  boot-40   normal
    codex  C2  boot-30   normal
    codex  C3  boot-25   subagent (filtered by default)
    claude A1  boot-25   cwd embedded in JSONL
    claude A2  boot-20   NO cwd line; project dir "-tmp" decodes to /tmp
    codex  C4  boot-22   normal, but listed in ps.txt as already resumed

  noise:
    codex  IDLE_FAR   boot-7200  outside pre-boot lookback (900s)
    codex  IDLE_NEAR  boot-600   inside lookback, outside dense 180s pocket
    claude LIVE       boot+600   started after reboot

Regenerated fresh on every run — mtimes are the whole point and git can't
store them.
"""

from __future__ import annotations

import json
import os
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
GEN = HERE / "generated"

C1 = "019f0000-0000-7000-8000-00000000c001"
C2 = "019f0000-0000-7000-8000-00000000c002"
C3 = "019f0000-0000-7000-8000-00000000c003"  # subagent
C4 = "019f0000-0000-7000-8000-00000000c004"  # already running
IDLE_FAR = "019f0000-0000-7000-8000-00000000c005"
IDLE_NEAR = "019f0000-0000-7000-8000-00000000c006"
A1 = "aaaa0000-0000-4000-8000-00000000a001"
A2 = "aaaa0000-0000-4000-8000-00000000a002"
LIVE = "aaaa0000-0000-4000-8000-00000000a003"


def write_codex(root: Path, sid: str, mtime: float, *, subagent: bool = False) -> None:
    d = root / "codex" / "2026" / "08" / "01"
    d.mkdir(parents=True, exist_ok=True)
    p = d / f"rollout-2026-08-01T10-00-00-{sid}.jsonl"
    payload = {"id": sid, "cwd": "/tmp", "timestamp": "2026-08-01T10:00:00Z"}
    payload["thread_source"] = "subagent" if subagent else "user"
    lines = [
        {"type": "session_meta", "timestamp": "t", "payload": payload},
        {"type": "response_item", "timestamp": "t", "payload": {"kind": "message"}},
    ]
    p.write_text("\n".join(json.dumps(x) for x in lines) + "\n", encoding="utf-8")
    os.utime(p, (mtime, mtime))


def write_claude(
    root: Path, project_key: str, sid: str, mtime: float, *, with_cwd: bool = True
) -> None:
    d = root / "claude" / project_key
    d.mkdir(parents=True, exist_ok=True)
    p = d / f"{sid}.jsonl"
    line: dict = {"type": "user", "sessionId": sid, "message": {"role": "user", "content": "hi"}}
    if with_cwd:
        line["cwd"] = "/tmp"
    p.write_text(json.dumps(line) + "\n", encoding="utf-8")
    os.utime(p, (mtime, mtime))


def main() -> int:
    meta = json.loads((HERE / "meta.json").read_text(encoding="utf-8"))
    boot = float(meta["fake_boot"])

    if GEN.exists():
        shutil.rmtree(GEN)
    GEN.mkdir(parents=True)

    write_codex(GEN, C1, boot - 40)
    write_codex(GEN, C2, boot - 30)
    write_codex(GEN, C3, boot - 25, subagent=True)
    write_codex(GEN, C4, boot - 22)
    write_codex(GEN, IDLE_FAR, boot - 7200)
    write_codex(GEN, IDLE_NEAR, boot - 600)
    write_claude(GEN, "-tmp-projA", A1, boot - 25, with_cwd=True)
    write_claude(GEN, "-tmp", A2, boot - 20, with_cwd=False)
    write_claude(GEN, "-tmp-projB", LIVE, boot + 600, with_cwd=True)

    (GEN / "ps.txt").write_text(
        "/bin/zsh -il\n"
        f"node /opt/cc/cli.js cod resume {C4}\n"
        "grep unrelated-text somefile\n",
        encoding="utf-8",
    )

    ids = {
        "C1": C1, "C2": C2, "C3_subagent": C3, "C4_running": C4,
        "IDLE_FAR": IDLE_FAR, "IDLE_NEAR": IDLE_NEAR,
        "A1": A1, "A2_decode": A2, "LIVE": LIVE,
    }
    (GEN / "ids.json").write_text(json.dumps(ids, indent=2) + "\n", encoding="utf-8")
    print(f"fixtures generated under {GEN}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
