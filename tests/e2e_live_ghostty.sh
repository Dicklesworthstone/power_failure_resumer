#!/usr/bin/env bash
# Opt-in macOS smoke: create one UI-driver tab and verify its fixture UUID in
# the real process table. The helper deliberately remains under tests/logs/ so
# its evidence is retained under the repository no-deletion rule.
if [[ "${PFR_LIVE:-}" != "1" ]]; then
  echo "skipped (PFR_LIVE!=1)"
  exit 0
fi

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ "$(uname -s)" == "Darwin" ]] || fail "PFR_LIVE=1 requires macOS Ghostty automation"
command -v osascript >/dev/null 2>&1 || fail "PFR_LIVE=1 requires osascript"

UI="$PFR_ROOT/lib/open_sessions_ui.applescript"
SID="$(python3 - "$FIX/ids.json" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["C1"])
PY
)" || fail "could not load fixture session UUID"
SD="$(new_state_dir pfr-live-ghostty)"
LIVE_COD="$SD/cod"

# Its basename is intentionally `cod`: verify.py accepts only resume evidence
# tied to an agent executable token, not arbitrary --resume arguments.
printf '#!/usr/bin/env bash\nsleep 30\n' > "$LIVE_COD"
chmod 700 "$LIVE_COD"

driver_out="$(osascript "$UI" "$SD" "exec \"$LIVE_COD\" resume $SID" tab 0 0.55)" \
  || fail "UI driver did not open fixture session"
case "$driver_out" in
  native|fallback) ;;
  *) fail "unexpected UI driver result: $driver_out" ;;
esac

# Verify the real `ps` table, rather than a canned --ps-file, and retain the
# resulting last-report.json in the isolated state directory.
verify_out="$(printf 'codex\t%s\t%s\t1\n' "$SID" "$SD" | \
  python3 "$PFR_ROOT/lib/verify.py" --timeout 8 --interval 0.2 \
    --state-dir "$SD" --driver ui --open-mode tab)" \
  || fail "fixture resume was not visible in the real process table"
verified="$(printf '%s' "$verify_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["verified"])')" \
  || fail "verify.py did not return JSON: $verify_out"
assert_eq "$verified" "1" "one UI-opened fixture session verified"
[[ -f "$SD/last-report.json" ]] || fail "verification report was not written"

echo "live Ghostty UI smoke OK ($driver_out)"
