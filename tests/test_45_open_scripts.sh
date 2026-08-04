#!/usr/bin/env bash
# Structural AppleScript contracts: compile both drivers and lock the
# command-launch design — surfaces RUN their command via the surface
# configuration `command` property; nothing is typed into a prompt (typed
# `input text` was pasted via bracketed paste and never submitted).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

API="$PFR_ROOT/lib/open_sessions.applescript"
UI="$PFR_ROOT/lib/open_sessions_ui.applescript"

if [[ "$(uname -s)" == "Darwin" ]]; then
  osacompile -o /dev/null "$API" || fail "open_sessions.applescript must compile"
  osacompile -o /dev/null "$UI" || fail "open_sessions_ui.applescript must compile"
fi

# Parse executable lines instead of grepping raw source, so comments cannot
# satisfy an invariant.
python3 - "$API" "$UI" "$PFR" <<'PY' || fail "open script contract regression"
from pathlib import Path
import sys


def executable_lines(path: str) -> list[str]:
    return [
        line.strip()
        for line in Path(path).read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("--") and not line.lstrip().startswith("#")
    ]


def require(lines: list[str], statement: str, label: str) -> None:
    assert statement in lines, f"{label}: missing executable statement {statement!r}"


def require_prefix(lines: list[str], statement: str, label: str) -> None:
    assert any(line.startswith(statement) for line in lines), (
        f"{label}: missing executable statement prefix {statement!r}"
    )


api, ui, cli = map(executable_lines, sys.argv[1:])

# Shared batch argv contract + command-launch core, behaviorally aligned.
core = (
    "set openMode to item 1 of argv as text",
    "set delaySecs to (item 3 of argv as real)",
    "set shellPath to item 4 of argv as text",
    'set keepAlive to payload & "; exec " & shellPath & " -il"',
    'return shellPath & " -il -c " & my shellQuote(keepAlive)',
    "set command of cfg to my launchCommand(shellPath, cmdText)",
    "set initial working directory of cfg to workDir",
    "set wait after command of cfg to true",
    "set pairIndex to pairIndex + 2",
)
for name, source in (("API", api), ("UI", ui)):
    for statement in core:
        require(source, statement, f"{name} batch/command contract")
    # The typing path is the regression this design replaces: a driver must
    # never deliver the resume line as terminal input.
    assert not any(line.startswith("input text") for line in source), (
        f"{name} must not type/paste into the terminal on the native path"
    )
    # One failed surface must not abort the rest of the batch.
    assert any('"fail ' in line for line in source), (
        f"{name} must report per-surface failures instead of erroring out"
    )

require(ui, "set settleSecs to (item 2 of argv as real)", "UI settle argv contract")

# CLI invokes each driver once with the full batch argv.
require_prefix(cli, 'local -a args=("$OPEN_MODE" "$SETTLE_SECONDS" "$DELAY_SECONDS"', "CLI batch argv contract")
require_prefix(cli, 'ui)      open_batch_osascript "$OPEN_UI_AS"', "CLI UI driver dispatch")
require_prefix(cli, 'api)     open_batch_osascript "$OPEN_API_AS"', "CLI API driver dispatch")

# UI fallback: keystroke surface creation lives only in the fallback handler,
# pastes with its own cd (fallback surfaces cannot set a working directory),
# and preserves the clipboard around the batch.
assert "on fallbackOneSurface(workDir, cmdText, openMode, settleSecs)" in ui, (
    "UI missing fallback handler"
)
fallback_start = ui.index("on fallbackOneSurface(workDir, cmdText, openMode, settleSecs)")
fallback_end = ui.index("end fallbackOneSurface")
fallback_body = ui[fallback_start:fallback_end]
for key in ('keystroke "t" using command down', 'keystroke "n" using command down'):
    assert key in fallback_body, f"UI fallback missing {key!r}"
    assert ui.count(key) == 1, f"{key!r} must exist only in the fallback handler"
require(fallback_body, 'set lineToType to "cd " & my shellQuote(workDir) & " && " & cmdText', "UI fallback cd contract")
require(fallback_body, "delay settleSecs", "UI fallback settle")
require(fallback_body, "keystroke return", "UI fallback must submit with Return")
require(ui, "set oldClip to the clipboard", "fallback saves clipboard")
require(ui, "set the clipboard to oldClip", "fallback restores clipboard")

# API driver stays fallback-free (no keystroke simulation at all).
assert not any("keystroke" in line for line in api), "API must not simulate keystrokes"
PY

echo "open script invariants OK"
