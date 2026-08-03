#!/usr/bin/env bash
# Run the pfr test suite: tests/test_*.sh and tests/test_*.py in name order.
# Emits NDJSON events to tests/logs/run-<stamp>.ndjson; per-test output under
# tests/logs/out-<stamp>/. On failure, the last 50 output lines are dumped.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="$ROOT/tests"
LOG_DIR="$TESTS_DIR/logs"
STAMP="$(date +%Y%m%d_%H%M%S)"
NDJSON="$LOG_DIR/run-${STAMP}.ndjson"
OUT_DIR="$LOG_DIR/out-${STAMP}"
mkdir -p "$OUT_DIR"

log_event() {
  # log_event key=value ...  → one JSON object per line (values parsed as JSON
  # when possible, else kept as strings)
  python3 - "$@" <<'PY' >> "$NDJSON"
import json, sys, time
obj = {"ts": round(time.time(), 3)}
for kv in sys.argv[1:]:
    k, _, v = kv.partition("=")
    try:
        obj[k] = json.loads(v)
    except Exception:
        obj[k] = v
print(json.dumps(obj))
PY
}

echo "› regenerating fixtures…"
if ! python3 "$TESTS_DIR/fixtures/make_fixtures.py" > "$OUT_DIR/fixtures.log" 2>&1; then
  echo "✗ fixture generation failed:"
  tail -50 "$OUT_DIR/fixtures.log" | sed 's/^/  | /'
  exit 1
fi
log_event event=fixtures status=ok

pass=0
fail=0
found=0
failed_names=""
for t in "$TESTS_DIR"/test_*.sh "$TESTS_DIR"/test_*.py; do
  [[ -e "$t" ]] || continue
  found=$((found + 1))
  name="$(basename "$t")"
  out="$OUT_DIR/${name}.log"
  start="$(date +%s)"
  log_event event=start "test=$name"
  if [[ "$t" == *.py ]]; then
    python3 "$t" > "$out" 2>&1
    rc=$?
  else
    bash "$t" > "$out" 2>&1
    rc=$?
  fi
  dur=$(( $(date +%s) - start ))
  if (( rc == 0 )); then
    pass=$((pass + 1))
    log_event event=result "test=$name" status=pass "duration_s=$dur"
    echo "PASS ${name} (${dur}s)"
  else
    fail=$((fail + 1))
    failed_names="${failed_names} ${name}"
    log_event event=result "test=$name" status=fail "duration_s=$dur" "rc=$rc"
    echo "FAIL ${name} (rc=${rc}) — last 50 lines:"
    tail -50 "$out" | sed 's/^/  | /'
  fi
done

log_event event=summary "pass=$pass" "fail=$fail" "total=$found"
echo
if (( found == 0 )); then
  echo "summary: no tests found (tests/test_*.sh|py)"
  exit 1
fi
echo "summary: ${pass} passed, ${fail} failed of ${found}  (ndjson: ${NDJSON})"
if (( fail > 0 )); then
  echo "failed:${failed_names}"
  exit 1
fi
