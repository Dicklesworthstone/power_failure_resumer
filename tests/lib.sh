# Shared helpers for pfr shell tests. Source from tests/test_*.sh.
# shellcheck disable=SC2034  # shared variables are consumed by sourcing suites
set -uo pipefail

PFR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PFR="$PFR_ROOT/power_failure_resumer.sh"
DISCOVER="$PFR_ROOT/lib/discover.py"
FIX="$PFR_ROOT/tests/fixtures/generated"
FAKE_BOOT="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['fake_boot'])" "$PFR_ROOT/tests/fixtures/meta.json")"

# Standard discovery args pointing at fixtures (huge lookback: fixture epoch is fixed)
FIX_ARGS=(--codex-root "$FIX/codex" --claude-root "$FIX/claude"
          --fake-boot "$FAKE_BOOT" --lookback-hours 8760000)

# Deterministic runs: no agent-mail or status tab unless a test opts in.
export PFR_AM=0
export PFR_STATUS_TAB=0
export PFR_KEEP_TEMPS=1
# Never let the user's real ntm records influence fixture discovery.
export PFR_NTM_HISTORY="${TMPDIR:-/tmp}/pfr-absent-ntm-history.jsonl"
export PFR_NTM_DATA="${TMPDIR:-/tmp}/pfr-absent-ntm-data"
PFR_TEST_TMP="$PFR_ROOT/tests/logs/tmp/run-$(date +%Y%m%d_%H%M%S)-$$-${RANDOM}"
mkdir -p "$PFR_TEST_TMP"
export TMPDIR="$PFR_TEST_TMP"

fail() { echo "ASSERT FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-}: expected '$2', got '$1'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "${3:-}: missing '$2' in: $1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "${3:-}: unexpected '$2' in: $1"; }

# Tests keep their isolated state under ignored logs instead of deleting temp
# trees. This follows the machine-wide no-delete contract and preserves failure
# evidence for inspection.
new_state_dir() {
  local label="${1:-pfr-test}" path
  path="$PFR_ROOT/tests/logs/state/${label}-$(date +%Y%m%d_%H%M%S)-$$-${RANDOM}"
  mkdir -p "$path"
  printf '%s\n' "$path"
}
