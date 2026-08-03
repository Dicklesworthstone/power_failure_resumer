#!/usr/bin/env bash
# Structural AppleScript contracts: compile both drivers and protect the UI
# fallback from creating a second Ghostty surface after native creation.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

API="$PFR_ROOT/lib/open_sessions.applescript"
UI="$PFR_ROOT/lib/open_sessions_ui.applescript"

osacompile -o /dev/null "$API" || fail "open_sessions.applescript must compile"
osacompile -o /dev/null "$UI" || fail "open_sessions_ui.applescript must compile"

api_source="$(<"$API")"
ui_source="$(<"$UI")"
cli_source="$(<"$PFR")"

# Both drivers accept the same semantic core: cwd, command, mode, and an
# optional settle delay. The UI driver retains its ignored fourth is_first
# compatibility slot, so its settle delay intentionally occupies argv 5.
for source in "$api_source" "$ui_source"; do
  assert_contains "$source" "set workDir to item 1 of argv as text" "driver reads cwd from argv[1]"
  assert_contains "$source" "set resumeCmd to item 2 of argv as text" "driver reads resume command from argv[2]"
  assert_contains "$source" "if (count of argv) ≥ 3 then set openMode to item 3 of argv as text" "driver reads mode from argv[3]"
  assert_contains "$source" "set lineToType to \"cd \" & my shellQuote(workDir) & \" && \" & resumeCmd" "driver builds cwd plus command"
  assert_contains "$source" "input text lineToType & linefeed" "driver submits the reconstructed command"
done
assert_contains "$api_source" "item 4 of argv as real" "API driver reads settle from argv[4]"
assert_contains "$ui_source" "argv 4 (is_first) ignored" "UI driver documents compatibility slot"
assert_contains "$ui_source" "item 5 of argv as real" "UI driver reads settle from argv[5]"
assert_contains "$cli_source" 'osascript "$OPEN_API_AS" "$cwd" "$resume_cmd" "$OPEN_MODE" "$SETTLE_SECONDS"' "CLI passes API argv contract"
assert_contains "$cli_source" 'osascript "$OPEN_UI_AS" "$cwd" "$resume_cmd" "$OPEN_MODE" "0" "$SETTLE_SECONDS"' "CLI passes UI argv contract"

# The only new-surface keystrokes in the fallback must be textually inside the
# createdSurface=false guard. A native-created surface that later rejects input
# must receive pasted input without a second Cmd+T/Cmd+N.
python3 - "$UI" <<'PY' || fail "fallback may open a duplicate surface"
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
guard = "if createdSurface is false then"
start = source.find(guard)
assert start >= 0, "missing createdSurface guard"
end = source.find("\n\t\t\t\tend if", start)
assert end >= 0, "createdSurface guard has no closing end if"
guarded = source[start:end]
for key in ('keystroke "n" using command down', 'keystroke "t" using command down'):
    assert source.count(key) == 1, f"expected exactly one {key!r}"
    assert key in guarded, f"{key!r} is not protected by createdSurface=false"
PY

# The UI fallback can replace the clipboard only if it preserves and restores
# the original native value on both the normal and error paths.
assert_contains "$ui_source" "set oldClip to the clipboard" "fallback saves clipboard"
assert_contains "$ui_source" "set the clipboard to lineToType" "fallback stages command in clipboard"
restore_count="$(grep -Fc 'set the clipboard to oldClip' "$UI")"
[[ "$restore_count" -ge 2 ]] || fail "fallback must restore clipboard on normal and error paths"

echo "open script invariants OK"
