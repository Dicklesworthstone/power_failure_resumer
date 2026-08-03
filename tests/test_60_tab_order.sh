#!/usr/bin/env bash
# Tab order: agent-mail (am) tab first, hub-cwd sessions (~/projects,
# /data/projects, /dp) next, everything else after.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SD="$(mktemp -d "${TMPDIR:-/tmp}/pfr-ord.XXXXXX")"
trap 'rm -rf "$SD"' EXIT

# Private fixture set: one hub session (/data/projects) and one normal (/tmp),
# both in the same pre-boot pocket; hub is OLDER so plain newest-first order
# would put it second — the hub rule must still hoist it.
FR="$SD/roots"
mkdir -p "$FR/codex/2026/08/01"
python3 - "$FR" "$FAKE_BOOT" <<'PY'
import json, os, sys
root, boot = sys.argv[1], float(sys.argv[2])
def codex(sid, mtime, cwd):
    p = os.path.join(root, "codex/2026/08/01", f"rollout-2026-08-01T09-00-00-{sid}.jsonl")
    payload = {"id": sid, "cwd": cwd, "thread_source": "user"}
    with open(p, "w") as f:
        f.write(json.dumps({"type": "session_meta", "timestamp": "t", "payload": payload}) + "\n")
    os.utime(p, (mtime, mtime))
codex("019f0000-0000-7000-8000-00000000d001", boot - 40, "/data/projects")  # hub, older
codex("019f0000-0000-7000-8000-00000000d002", boot - 20, "/tmp")            # normal, newer
PY

out="$(PFR_AM=1 PFR_AM_BIN=sh "$PFR" --dry-run \
        --codex-root "$FR/codex" --claude-root "$FR/claude-none" \
        --fake-boot "$FAKE_BOOT" --lookback-hours 8760000 --state-dir "$SD" 2>&1)" \
  || fail "dry-run failed: $out"

plan_lines="$(grep -E '^  DRY  ' <<<"$out")"
line1="$(sed -n '1p' <<<"$plan_lines")"
line2="$(sed -n '2p' <<<"$plan_lines")"
line3="$(sed -n '3p' <<<"$plan_lines")"

assert_contains "$line1" "&& sh" "agent-mail tab (PFR_AM_BIN=sh) comes first"
assert_contains "$line2" "00000000d001" "hub session (/data/projects) second"
assert_contains "$line3" "00000000d002" "normal session third"

# With PFR_AM=0 no am line appears
out="$(PFR_AM=0 "$PFR" --dry-run \
        --codex-root "$FR/codex" --claude-root "$FR/claude-none" \
        --fake-boot "$FAKE_BOOT" --lookback-hours 8760000 --state-dir "$SD" 2>&1)" \
  || fail "PFR_AM=0 dry-run failed"
assert_not_contains "$(grep -E '^  DRY  ' <<<"$out" | sed -n '1p')" "&& sh" "no am tab when disabled"

echo "tab order OK"
