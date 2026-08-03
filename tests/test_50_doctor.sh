#!/usr/bin/env bash
# Doctor: healthy env exits 0; simulated missing Ghostty fails; --json parses.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SD="$(new_state_dir pfr-doctor)"

out="$("$PFR" --doctor --state-dir "$SD" 2>&1)" || fail "doctor should be healthy here: $out"
assert_contains "$out" "doctor: healthy" "healthy summary"

if PFR_DOCTOR_SIM_MISSING=ghostty "$PFR" --doctor --state-dir "$SD" >/dev/null 2>&1; then
  fail "doctor must fail when Ghostty is missing (simulated)"
fi

json="$(PFR_DOCTOR_SIM_MISSING=ghostty "$PFR" --doctor --json --state-dir "$SD" 2>/dev/null || true)"
healthy="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["healthy"])')" \
  || fail "doctor --json did not emit valid JSON: $json"
assert_eq "$healthy" "False" "healthy=false when ghostty simulated missing"

n_checks="$(printf '%s' "$json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["checks"]))')"
[[ "$n_checks" -ge 6 ]] || fail "expected >=6 checks, got $n_checks"

echo "doctor OK"
