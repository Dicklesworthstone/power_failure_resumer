# power_failure_resumer

When this Mac hard-powers off mid-swarm, Ghostty dies and every local `cod` / `cc` agent goes with it. Session files on disk often share nearly the same mtime just before reboot. This tool finds that simultaneous-stop cluster and reopens each session in its own Ghostty tab.

## What it does

1. Scans session files (honors `$CODEX_HOME` / `$CLAUDE_HOME` if set):
   - Codex: `~/.codex/sessions/**/rollout-*.jsonl`
   - Claude Code: `~/.claude/projects/**/<uuid>.jsonl` (skips `subagents/`)
2. Clusters sessions that stopped together:
   - **auto** (default): prefer files modified shortly before system boot; otherwise the densest simultaneous-mtime pocket
   - Overrides: `pre_boot`, `density`, `recent`
3. Opens a Ghostty surface per session and runs:
   - `cd <cwd> && cod resume <id>` or `cd <cwd> && cc --resume <id>`
   - Default driver **ui**: Ghostty AppleScript `new tab` + `input text` (keystroke fallback if scripting fails)
   - **api**: same scripting path without keystroke fallback
   - **ghostty** (Linux): one CLI window per session

Discovery also writes a plan under `~/.local/state/pfr/last-plan.json` so you can inspect once and open later with `--last-plan`.

## Quick start

```bash
cd ~/projects/power_failure_resumer

# List what would be restored (do this first after a blackout)
./power_failure_resumer.sh --dry-run

# Open the whole crash cluster
./power_failure_resumer.sh -y

# Same, AppleScript-only open path
./power_failure_resumer.sh -y --api

# Multi-select (fzf if installed)
./power_failure_resumer.sh --pick
```

Optional install:

```bash
ln -sf ~/projects/power_failure_resumer/power_failure_resumer.sh ~/.local/bin/pfr
pfr --dry-run
```

## Useful flags

| Flag | Purpose |
|------|---------|
| `--dry-run` / `-n` | List only |
| `-y` / `--yes` | Open all matches |
| `--pick` | Choose a subset |
| `--last-plan` / `--plan PATH` | Open from a saved plan instead of rediscovering |
| `--tabs` / `--windows` | Ghostty surface mode |
| `--driver ui\|api\|ghostty` | Open strategy (macOS defaults to `ui`) |
| `--settle SECS` | Wait after creating a surface for the shell (default 0.55) |
| `--providers codex` | Codex only (or `claude`) |
| `--projects-only` | Restrict to `~/projects/...` |
| `--window 180` | Simultaneous-death window (seconds) |
| `--pre-boot-lookback 900` | How far before boot to search |
| `--mode auto\|pre_boot\|density\|recent` | Clustering strategy |
| `--include-subagents` | Keep Codex subagent threads (noisy) |
| `--force-reopen` | Include sessions that already look live in `ps` |
| `--max 40` | Safety cap on opens |
| `--json` | Machine-readable discovery output |
| `--codex-root` / `--claude-root` / `--fake-boot` / `--state-dir` | Isolation for tests and nonstandard layouts |

## How clustering works

On a hard power cut, processes that were mid-write tend to stop updating files at about the same wall-clock time. After reboot you often see a pile of session files with mtimes within a few seconds of each other, all just before `kern.boottime`.

`lib/discover.py`:

1. Collects top-level sessions modified in the last `--lookback-hours` (default 48h).
2. Drops Codex `thread_source=subagent` (and similar) unless `--include-subagents`.
3. Dedupes by `(provider, session_id)`, keeping the newest file.
4. Marks already-running resumes from `ps` (see below), but **clusters first**, then drops live ones so the crash pocket does not shift.
5. **auto mode**: take sessions in `[boot - lookback, boot + slack]`, then the densest pocket of size `--window` inside that set. Idle sessions from ten minutes earlier fall out. If the pre-boot set is empty, fall back to a global densest window.

Confidence (`high` / `medium` / `low`) is scored on the full pocket. Density-only mode never gets `high`.

## Resume commands

Same as your usual interactive workflow:

```bash
cd ~/projects/frankensim
cod resume 019fa4a7-3665-7aa3-8633-2a47c42c1d78

cc --resume ba9de0d5-51bb-40f8-9029-8ea3bcfc3481
```

The script types those into a real interactive shell so your `cod` / `cc` aliases apply.

## Ghostty open drivers

### `ui` (macOS default)

1. `open -a Ghostty` if needed.
2. For each session: open a **new** tab (never reuses the default/restored tab), set working directory, `input text` of `cd '…' && cod resume …` / `cc --resume …` (one retry if the shell is still starting).
3. If scripting fails: System Events fallback (`⌘T` / paste / Return). If a tab was already created and only input failed, fallback pastes into the front tab only (no second `⌘T`).

Native path needs Automation for Ghostty. Keystroke fallback also needs Accessibility. Do not type in Ghostty while a run is in progress.

### `api` (macOS)

Same surface API (`new tab` / `new window` + cwd + delayed `input text`). No keystroke fallback. Needs Automation for AppleScript → Ghostty.

### `ghostty` (Linux)

Spawns one `ghostty` CLI window per session with `--working-directory` and an interactive shell running the resume command.

## Layout

```
power_failure_resumer/
├── power_failure_resumer.sh
├── lib/
│   ├── discover.py
│   ├── confidence.py
│   ├── plan.py
│   ├── open_sessions_ui.applescript
│   └── open_sessions.applescript
├── scripts/run_tests.sh
├── tests/
├── docs/session-formats.md
└── README.md
```

## Notes / limits

- **Already-running sessions are skipped.** Discovery looks in `ps` for a session UUID sitting right after `resume` / `--resume` / `--resume=`. Re-running should not double-open sessions you already brought back. Override with `--force-reopen`. Fresh sessions that never used `resume` have no UUID in argv and cannot be detected this way.
- **Subagents are skipped by default.** The Ghostty tabs you typed into are parent TUI sessions; dumping every subagent thread is noise.
- **Swarm tabs can share a project.** Several true top-level sessions in one cwd is normal and all of them are offered.
- **Claude project dirs** replace every non-alphanumeric character with `-`, so reverse-decoding the folder name is lossy. Prefer the `cwd` field in the JSONL; a decoded path is used only if it exists. See `docs/session-formats.md`.
- **Scope:** local Codex + Claude Code only. No remote SSH panes, NTM/tmux on other machines, or Cursor/VS Code sessions.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Empty cluster | `--mode recent --lookback-hours 6 --window 3600`, or widen `--pre-boot-lookback` |
| Too many sessions | `--projects-only`, `--providers codex`, or `--pick` |
| LOW confidence | Review carefully; density pocket may not be a crash |
| UI keystrokes go nowhere | Grant Accessibility; leave the keyboard alone mid-run; try larger `--settle` / `--delay` |
| Tab overwrote existing work | Fixed: always opens a dedicated surface; process detection no longer uses `pgrep -x Ghostty` |
| Tab opens bare shell | Press Up, or re-run with a larger `--settle` |
| `cod` / `cc` not found | Confirm they work in a normal Ghostty tab (aliases from `.zshrc`) |
| AppleScript errors | Allow Automation for the controlling app → Ghostty |
| Wrong model flags on Codex | Script invokes `cod` / `cc` so your aliases win |
| Stale plan refused | Re-run discovery, or pass `--force-stale-plan` |
