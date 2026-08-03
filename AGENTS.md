# AGENTS.md — power_failure_resumer

> Guidelines for AI coding agents working in this Bash, Python, and AppleScript codebase.

---

## RULE 0: THE USER OVERRIDES THIS FILE

If the user gives an explicit instruction that conflicts with this file, follow
the user's instruction. The user is in charge.

---

## RULE 1: NO FILE DELETION

**Never delete a file or directory without clear, written permission from the
user in the current session.** This includes files you created yourself, test
artifacts, logs, caches, generated fixtures, and temporary directories.

Do not run `rm`, `rmdir`, `unlink`, cleanup scripts, or commands with equivalent
effects unless the user has approved the exact deletion. Prefer retaining
artifacts, moving them to an archive, or asking for permission.

## Irreversible Git and Filesystem Actions

1. Never run `git reset --hard`, `git clean -fd`, `git checkout --`,
   `git restore`, `rm -rf`, or another command that can discard work unless the
   user provides the exact command and explicitly accepts its effects.
2. Do not guess whether a destructive command is safe. Resolve exact targets
   with read-only inspection first.
3. Never stash, revert, overwrite, or otherwise disturb another agent's work.
4. If deletion is explicitly authorized, restate the exact command and targets
   before running it, then report what was removed.

---

## Branch and Shared-Tree Discipline

- Work on `main`. Do not create or use a `master` branch.
- This is a live shared worktree. Other agents can edit and commit at any time.
- Re-read a file immediately before editing it.
- Treat unfamiliar changes as valid peer work. Do not pause merely because the
  working tree is dirty.
- Stage and commit only the files or hunks owned by your task.
- Check `git status`, `git diff`, and recent history before committing.
- Never amend, force-push, or rewrite shared history.

---

## Toolchain

This project has no compilation step. It uses:

| Component | Role |
|-----------|------|
| `power_failure_resumer.sh` | Main CLI, prompts, ordering, and launch orchestration |
| Python 3 standard library | Discovery, confidence, plan persistence, verification |
| AppleScript | Ghostty automation on macOS |
| Bash | Installer and shell test suites |

Compatibility targets:

- Bash 3.2+ for the installed CLI and installer (the macOS system Bash matters)
- Python 3 with no third-party runtime packages
- macOS and Linux, with platform-specific Ghostty launch drivers
- Offline deterministic tests; no live session roots or Ghostty required

### Shell Discipline

- Use `#!/usr/bin/env bash`.
- Quote path and user-controlled expansions.
- Prefer arrays for command arguments; do not build commands for `eval`.
- Validate numeric input before arithmetic or `sleep`.
- Keep resume identifiers restricted to complete UUIDs.
- Preserve interactive-shell execution for `cod` and `cc` aliases.
- Human-readable diagnostics may use stderr; JSON modes must keep stdout valid
  JSON with no decorative output.
- Bound external process calls with timeouts where practical.
- ShellCheck warnings at severity `warning` or higher must be resolved or
  narrowly documented.

### Python Discipline

- Standard library only unless the user explicitly approves a dependency.
- Treat session JSONL, saved plans, process tables, and offline archives as
  untrusted input.
- Validate complete types and values at persistence and execution boundaries.
- Use bounded reads for large transcripts and process output.
- Keep authority-bearing commands reconstructed from validated provider, UUID,
  and absolute cwd fields; never execute a serialized `resume_cmd` blindly.
- Use atomic writes and restrictive permissions for state files.
- Do not claim process health from mere file presence or a static fixture.

### AppleScript Discipline

- Keep the scripting-only and UI-fallback drivers behaviorally aligned.
- A partial success must never create a duplicate Ghostty tab.
- Preserve and restore clipboard content in keystroke fallback paths.
- Compile both scripts with `osacompile` after changes when running on macOS.

---

## Code Editing Discipline

### Manual, Scoped Changes

Do not run broad regex rewrite scripts over source or documentation. Make
changes manually with a patch, using enough surrounding context to avoid
overwriting concurrent edits.

Do not create variants such as:

- `power_failure_resumer_v2.sh`
- `discover_new.py`
- `install_fixed.sh`

Revise existing files in place. New files are appropriate only for genuinely
new modules, fixtures, or tests that do not belong in an existing file.

### Root-Cause Standard

- Reproduce or trace a defect before changing behavior.
- Fix the earliest violated invariant, not only the visible symptom.
- Add a regression test when the failure can be represented offline.
- Distinguish static hygiene from runtime proof.
- Do not turn best-effort evidence into a success claim.

---

## power_failure_resumer Architecture

The tool reconstructs agent sessions that likely stopped together during a
power failure, saves an inspectable plan, reopens selected sessions in Ghostty,
and verifies that resume commands appear in the process table.

### Execution Flow

1. `power_failure_resumer.sh` parses flags and validates launch settings.
2. `lib/discover.py` scans Codex and Claude JSONL files within the lookback.
3. Discovery removes subagents by default, deduplicates sessions, identifies a
   dense mtime pocket, then filters already-running resume processes.
4. `lib/confidence.py` scores the full selected pocket.
5. `lib/plan.py` writes or validates schema-v1 plans.
6. The shell CLI orders status, agent-mail, hub, and ordinary session tabs.
7. macOS uses `lib/open_sessions_ui.applescript` or
   `lib/open_sessions.applescript`; Linux uses the Ghostty CLI.
8. `lib/verify.py` polls process arguments and writes `last-report.json`.

### Core Invariants

- Cluster before filtering already-running sessions.
- Score confidence before `--limit` truncation.
- A density-only pocket never earns `high` confidence.
- The densest-window result contains only members inside the requested window.
- Resume IDs are exact UUIDs derived from canonical session metadata or names.
- Plan loading validates schema, boot identity, age, provider, cwd, and UUID.
- Plan `resume_cmd` text is informational; execution reconstructs the command.
- State directories are mode 0700 and sensitive files are mode 0600.
- Failed or unverifiable opens remain failures.

### Repository Layout

```text
power_failure_resumer/
├── power_failure_resumer.sh
├── install.sh
├── lib/
│   ├── discover.py
│   ├── confidence.py
│   ├── plan.py
│   ├── verify.py
│   ├── open_sessions_ui.applescript
│   └── open_sessions.applescript
├── scripts/run_tests.sh
├── tests/
├── docs/session-formats.md
├── .beads/
└── AGENTS.md
```

---

## Testing and Quality Gates

After substantive changes, run the checks relevant to the changed surface.
Before closing a code task, run the full suite when practical.

```bash
# Shell syntax
bash -n power_failure_resumer.sh install.sh scripts/run_tests.sh
for f in tests/*.sh tests/e2e_*.sh; do bash -n "$f"; done

# Shell lint
shellcheck -s bash -S warning power_failure_resumer.sh install.sh \
  scripts/run_tests.sh tests/*.sh tests/e2e_*.sh

# Python syntax without writing pyc files
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
from pathlib import Path
for path in sorted(Path("lib").glob("*.py")) + sorted(Path("tests").glob("*.py")):
    compile(path.read_text(encoding="utf-8"), str(path), "exec")
PY

# AppleScript syntax on macOS
osacompile -o /dev/null lib/open_sessions.applescript
osacompile -o /dev/null lib/open_sessions_ui.applescript

# Full offline suite
./scripts/run_tests.sh
```

Tests write retained evidence under `tests/logs/`. Do not point tests at the
user's real `$CODEX_HOME`, `$CLAUDE_HOME`, or state directory. Use fixture roots,
`--fake-boot`, `--ps-file`, and an isolated `--state-dir`.

### Bug Scanner

Run UBS on changed files before commit when available:

```bash
ubs $(git diff --name-only --diff-filter=ACMR)
ubs .
```

Read each finding in context. Fix command injection, unsafe path handling,
unquoted expansion, path traversal, silent overwrites, resource leaks, and
unhandled failures. Triage style-only or false-positive findings explicitly.

---

## Installer Rules

`install.sh` is a curl-pipe entrypoint and must be reviewed as a security
boundary.

- `--help` must work both from a file and through `curl | bash`.
- Missing option values must produce usage and exit 2, never an unbound-variable
  crash.
- Validate archives before extraction; reject traversal, links, devices,
  multiple roots, and unreasonable sizes.
- Refuse to overwrite unrelated install roots or launcher paths.
- Stage a complete tree before activation and preserve the prior tree until the
  launcher update succeeds.
- Up-to-date checks cover the complete installed tree, not only the main script.
- Do not test against the user's real home directory.
- Do not execute installer cleanup paths when the session's no-deletion rule is
  active; retain isolated test artifacts instead.

---

## Beads Workflow

This repository uses `br` (`beads_rust`). Issue data lives in `.beads/` and is
tracked in Git. `br` does not run Git commands.

```bash
br ready --json
br list --status=in_progress --json
br show <id> --json
br update <id> --status=in_progress
br close <id> --reason "Completed"
br sync --flush-only
```

Workflow:

1. Read the bead body before working; it is the task contract.
2. Mark the bead `in_progress` before editing.
3. Keep work scoped to the bead and shared-tree ownership.
4. Add evidence or a concise comment when useful.
5. Close only after implementation and relevant proof are complete.
6. Run `br sync --flush-only` before staging `.beads/issues.jsonl`.
7. Commit issue state with the corresponding code change.

Do not mark work complete from static inspection when runtime evidence is part
of the acceptance criteria.

---

## Multi-Agent Coordination

When Agent Mail is available:

1. Register for the absolute repository path.
2. Reserve exact files or narrow globs before editing.
3. Use the Beads ID as the mail thread and reservation reason.
4. Announce material ownership conflicts promptly.
5. Release reservations after the work is committed.

If Agent Mail is unavailable, use Beads assignee/status evidence and careful
path inspection. Do not remain blocked on coordination when exact ownership can
be established safely.

---

## Landing the Plane

Before ending a code session:

1. Inspect `git status` and the complete diff.
2. Run syntax checks, linters, tests, and scanners appropriate to the changes.
3. File Beads follow-up issues for genuine remaining work.
4. Close completed beads and run `br sync --flush-only`.
5. Stage only owned files and hunks.
6. Commit the completed task with the Beads ID when applicable.
7. Push only when a remote is configured and the user has not prohibited it.
8. Report exact proof, residual limitations, commit hash, and push state.

Never report a pass that the captured evidence does not establish.
