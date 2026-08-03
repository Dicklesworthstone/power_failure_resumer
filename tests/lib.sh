# Shared helpers for pfr shell tests. Source from tests/test_*.sh.
set -uo pipefail

PFR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PFR="$PFR_ROOT/power_failure_resumer.sh"
DISCOVER="$PFR_ROOT/lib/discover.py"
FIX="$PFR_ROOT/tests/fixtures/generated"
FAKE_BOOT="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['fake_boot'])" "$PFR_ROOT/tests/fixtures/meta.json")"

# Standard discovery args pointing at fixtures (huge lookback: fixture epoch is fixed)
FIX_ARGS=(--codex-root "$FIX/codex" --claude-root "$FIX/claude"
          --fake-boot "$FAKE_BOOT" --lookback-hours 8760000)

fail() { echo "ASSERT FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-}: expected '$2', got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "${3:-}: missing '$2' in: $1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "${3:-}: unexpected '$2' in: $1"; }
