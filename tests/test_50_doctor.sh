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

# A hung login shell (slow/blocking rc files) must not hang the doctor: the
# probe is time-bounded and downgrades to a warning.
HANG="$SD/hang.sh"
printf '#!/bin/sh\nsleep 60\n' > "$HANG"
chmod +x "$HANG"
start_ts="$(date +%s)"
out="$(SHELL="$HANG" "$PFR" --doctor --state-dir "$SD" 2>&1)" \
  || fail "doctor must stay healthy when the shell probe times out: $out"
dur=$(( $(date +%s) - start_ts ))
[[ "$dur" -lt 25 ]] || fail "doctor blocked on a hung login shell (${dur}s)"
assert_contains "$out" "timed out" "bounded login-shell probe"

# Regression (pfr-s9e): the installed launcher is a symlink in another
# directory; ROOT must resolve to the real script's directory so lib/ is found.
LAUNCHER_DIR="$SD/bin"
mkdir -p "$LAUNCHER_DIR"
ln -s "$PFR" "$LAUNCHER_DIR/pfr"
out="$("$LAUNCHER_DIR/pfr" --doctor --state-dir "$SD" 2>&1)" \
  || fail "doctor via symlinked launcher should be healthy: $out"
assert_contains "$out" "doctor: healthy" "healthy via symlinked launcher"

# Relative symlink chain (link -> link -> script) must also resolve.
ln -s "pfr" "$LAUNCHER_DIR/pfr2"
out="$("$LAUNCHER_DIR/pfr2" --dry-run "${FIX_ARGS[@]}" --state-dir "$SD" --json 2>/dev/null)" \
  || fail "dry-run via chained relative symlink failed"
printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' \
  || fail "dry-run --json via symlink did not emit valid JSON"

echo "doctor OK"
