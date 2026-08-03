#!/usr/bin/env bash
# Smoke: syntax checks, --help paths, fixtures present.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

bash -n "$PFR" || fail "bash -n power_failure_resumer.sh"
python3 - "$DISCOVER" <<'PY' || fail "compile discover.py"
from pathlib import Path
import sys

path = Path(sys.argv[1])
compile(path.read_text(encoding="utf-8"), str(path), "exec")
PY

out="$("$PFR" --help)" || fail "--help exit code"
assert_contains "$out" "USAGE" "--help output"
assert_contains "$out" "--codex-root" "--help lists isolation flags"

out="$(python3 "$DISCOVER" --help)" || fail "discover --help"
assert_contains "$out" "--fake-boot" "discover --help lists --fake-boot"

[[ -d "$FIX/codex" ]] || fail "generated codex fixtures missing"
[[ -d "$FIX/claude" ]] || fail "generated claude fixtures missing"
[[ -f "$FIX/ps.txt" ]] || fail "generated ps.txt missing"

# Unknown argument must fail fast
if "$PFR" --definitely-not-a-flag >/dev/null 2>&1; then
  fail "unknown flag should exit non-zero"
fi

echo "smoke OK"
