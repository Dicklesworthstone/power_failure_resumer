#!/usr/bin/env bash
# E2E: dry-run discovery against fixtures — assert mode/count/confidence.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SD="$(new_state_dir pfr-e2e-dry)"

out="$("$PFR" --dry-run "${FIX_ARGS[@]}" --state-dir "$SD" 2>&1)" || fail "dry-run exit code: $out"

assert_contains "$out" "cluster mode:  pre_boot" "mode"
assert_contains "$out" "matched:       5 session(s)" "session count"
assert_contains "$out" "confidence:    high" "confidence"
assert_contains "$out" "plan saved:" "plan persisted"
assert_contains "$out" "DRY  cd /tmp && cod resume" "codex resume line"
assert_contains "$out" "DRY  cd /tmp && cc --resume" "claude resume line"
assert_not_contains "$out" "00000000c003" "subagent excluded"
assert_not_contains "$out" "00000000c005" "far-idle excluded"
assert_not_contains "$out" "00000000c006" "near-idle excluded"
assert_not_contains "$out" "00000000a003" "post-boot session excluded"

json="$("$PFR" --json "${FIX_ARGS[@]}" --state-dir "$SD" --no-save-plan)" || fail "--json exit code"
mode="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["mode"])')"
assert_eq "$mode" "pre_boot" "--json mode"

echo "e2e_dry_run OK"
