#!/usr/bin/env bash
# Structural AppleScript contracts: compile both drivers and protect the UI
# fallback from creating a second Ghostty surface after native creation.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

API="$PFR_ROOT/lib/open_sessions.applescript"
UI="$PFR_ROOT/lib/open_sessions_ui.applescript"

if [[ "$(uname -s)" == "Darwin" ]]; then
  osacompile -o /dev/null "$API" || fail "open_sessions.applescript must compile"
  osacompile -o /dev/null "$UI" || fail "open_sessions_ui.applescript must compile"
fi

# Parse executable lines instead of grepping raw source, so comments cannot
# satisfy an invariant. The block matcher also verifies that Cmd+T/Cmd+N stay
# nested under the actual createdSurface=false branch.
python3 - "$API" "$UI" "$PFR" <<'PY' || fail "open script contract regression"
from pathlib import Path
import re
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
core = (
    "set workDir to item 1 of argv as text",
    "set resumeCmd to item 2 of argv as text",
    "if (count of argv) ≥ 3 then set openMode to item 3 of argv as text",
    'set lineToType to "cd " & my shellQuote(workDir) & " && " & resumeCmd',
)
for name, source, input_line in (
    ("API", api, "input text lineToType & linefeed to term"),
    ("UI", ui, "input text lineToType & linefeed to termObj"),
):
    for statement in core:
        require(source, statement, f"{name} argv/command contract")
    assert source.count(input_line) == 2, f"{name} must retry native input exactly once"

require(api, "set settleSecs to (item 4 of argv as real)", "API settle argv contract")
require(ui, "set settleSecs to (item 5 of argv as real)", "UI settle argv contract")
require_prefix(cli, 'osascript "$OPEN_API_AS" "$cwd" "$resume_cmd" "$OPEN_MODE" "$SETTLE_SECONDS"', "CLI API argv contract")
require_prefix(cli, 'osascript "$OPEN_UI_AS" "$cwd" "$resume_cmd" "$OPEN_MODE" "0" "$SETTLE_SECONDS"', "CLI UI argv contract")

native_create = re.compile(r"set new(?:Tab|Window) to new (?:tab(?: in win)?|window) with configuration cfg")
for index, line in enumerate(ui):
    if native_create.fullmatch(line):
        assert ui[index + 1:index + 2] == ["set createdSurface to true"], (
            f"native creation at line {index + 1} does not mark createdSurface"
        )

guard = "if createdSurface is false then"
stack: list[str] = []
keys = ('keystroke "n" using command down', 'keystroke "t" using command down')
seen = {key: 0 for key in keys}
inside_guard: list[str] = []
for line in ui:
    if line.startswith("if ") and line.endswith(" then"):
        stack.append(line)
        continue
    if line == "end if":
        assert stack, "unbalanced AppleScript end if"
        stack.pop()
        continue
    if guard in stack:
        inside_guard.append(line)
    if line in seen:
        seen[line] += 1
        assert guard in stack, f"{line!r} is not guarded by createdSurface=false"
assert not stack, "unbalanced AppleScript if block"
assert all(count == 1 for count in seen.values()), "expected one Cmd+N and one Cmd+T creation path"
assert "my waitForShellPrompt(missing value, settleSecs)" not in inside_guard, (
    "fallback must not probe an unbound front window after Cmd+T/Cmd+N"
)
assert "delay settleSecs" in inside_guard, "fallback must retain its fixed post-open settle"

require(ui, "set oldClip to the clipboard", "fallback saves clipboard")
require(ui, "set the clipboard to lineToType", "fallback stages command")
assert ui.count("set the clipboard to oldClip") >= 2, "fallback must restore clipboard on error and success"
PY

echo "open script invariants OK"
