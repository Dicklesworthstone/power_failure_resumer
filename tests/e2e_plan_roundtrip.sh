#!/usr/bin/env bash
# E2E: dry-run saves a plan → --last-plan dry-run reopens the SAME session set.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SD="$(new_state_dir pfr-e2e-plan)"

ids_of() { grep -oE '(cod resume|cc --resume) [0-9a-f-]+' <<<"$1" | awk '{print $NF}' | sort; }

out1="$("$PFR" --dry-run "${FIX_ARGS[@]}" --state-dir "$SD" 2>&1)" || fail "discovery dry-run failed"
[[ -f "$SD/last-plan.json" ]] || fail "last-plan.json not written"

out2="$("$PFR" --dry-run --last-plan --state-dir "$SD" --fake-boot "$FAKE_BOOT" 2>&1)" \
  || fail "plan dry-run failed: $out2"

ids1="$(ids_of "$out1")"
ids2="$(ids_of "$out2")"
[[ -n "$ids1" ]] || fail "no session ids in discovery output"
assert_eq "$ids2" "$ids1" "plan reopens identical session set"

# Full resume COMMANDS must survive the roundtrip too (pfr-model-plan
# regression: the plan field whitelist dropped model/effort, so plan-loaded
# resumes silently lost their -m / --model pinning).
cmds_of() { grep -oE '(cod resume|cc --resume) [^(»]*' <<<"$1" | sed 's/[[:space:]]*$//' | sort; }
assert_eq "$(cmds_of "$out2")" "$(cmds_of "$out1")" "plan preserves full resume commands"

# Different boot ⇒ stale plan must refuse without --force-stale-plan
if "$PFR" --dry-run --last-plan --state-dir "$SD" --fake-boot "$((${FAKE_BOOT%.*} + 9999))" >/dev/null 2>&1; then
  fail "stale plan (different boot) was not refused"
fi
out3="$("$PFR" --dry-run --last-plan --state-dir "$SD" \
        --fake-boot "$((${FAKE_BOOT%.*} + 9999))" --force-stale-plan 2>&1)" \
  || fail "--force-stale-plan did not override"
assert_eq "$(ids_of "$out3")" "$ids1" "forced stale plan still reopens same set"

# --no-save-plan must not write
SD2="$(new_state_dir pfr-e2e-nosave)"
"$PFR" --dry-run "${FIX_ARGS[@]}" --state-dir "$SD2" --no-save-plan >/dev/null 2>&1 \
  || fail "--no-save-plan run failed"
[[ ! -e "$SD2/last-plan.json" ]] || fail "--no-save-plan still wrote a plan"

echo "e2e_plan_roundtrip OK"
