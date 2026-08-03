# power_failure_resumer

## Install

```bash
curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/power_failure_resumer/main/install.sh?$(date +%s)" | bash
```

Adds `pfr` to `~/.local/bin` (pass `-s -- --easy-mode` to also wire up your PATH). Then: `pfr --doctor`, `pfr --dry-run`, `pfr -y`.

When this Mac hard-powers off mid-swarm, Ghostty dies and every local `cod` / `cc` agent goes with it. Session files on disk often share nearly the same mtime just before reboot. This tool finds that simultaneous-stop cluster and reopens each session in its own Ghostty tab.

## What it does

1. **Discover** session files (honors `$CODEX_HOME` / `$CLAUDE_HOME` if set):
   - Codex: `~/.codex/sessions/**/rollout-*.jsonl`
   - Claude Code: `~/.claude/projects/**/<uuid>.jsonl` (skips `subagents/`)
2. **Cluster** sessions that stopped together, score crash **confidence** (`high` / `medium` / `low`), skip ones that already look live in `ps`.
3. **Save a plan** to `~/.local/state/pfr/last-plan.json` so you can inspect once and open later without rediscovering.
4. **Open** Ghostty surfaces and run `cd <cwd> && cod resume <id>` or `cc --resume <id>` (your interactive shell aliases apply).
5. **Verify** resumes against `ps` and write `last-report.json`.
6. Optional **agent-mail** tab first (`am` if installed), then hub cwds (`~/projects`, `/data/projects`, `/dp`), then the rest.

## Quick start

```bash
cd ~/projects/power_failure_resumer

# After a blackout: inspect first
./power_failure_resumer.sh --dry-run

# Open the crash cluster
./power_failure_resumer.sh -y

# Or open from the plan you just saved
./power_failure_resumer.sh --last-plan -y

# Environment health
./power_failure_resumer.sh --doctor
./power_failure_resumer.sh --doctor --json
```

Optional install:

```bash
ln -sf ~/projects/power_failure_resumer/power_failure_resumer.sh ~/.local/bin/pfr
pfr --dry-run
```

Tests:

```bash
./scripts/run_tests.sh
```

## Workflow

```
blackout → boot → pfr --dry-run  → review list + confidence
                 → pfr -y          → open + verify
                 → pfr --last-plan → reopen same set later without rediscover
```

Dry-run prints where the plan was saved and suggests:

```text
next: pfr --last-plan -y   or   pfr --last-plan --pick
```

## Flags

### Discovery

| Flag | Purpose |
|------|---------|
| `--window SECS` | Simultaneous-death window (default 180) |
| `--lookback-hours H` | Only sessions modified in last H hours (default 48) |
| `--pre-boot-lookback S` | Seconds before boot to search (default 900) |
| `--mode auto\|pre_boot\|density\|recent` | Clustering strategy |
| `--providers LIST` | `codex`, `claude`, or both |
| `--projects-only` | Restrict to `~/projects/...` |
| `--include-subagents` | Keep Codex subagent threads |
| `--force-reopen` | Include sessions that already look live |
| `--limit N` | Cap listed/opened sessions (newest first; confidence still uses full pocket) |
| `--json` | Print discovery JSON and exit |

### Plans

| Flag | Purpose |
|------|---------|
| (default) | Write `<state-dir>/last-plan.json` after discovery |
| `--last-plan` | Load that plan; skip rediscovery |
| `--plan PATH` | Load a specific plan file |
| `--save-plan PATH` | Also write a copy to PATH |
| `--no-save-plan` | Do not write last-plan.json |
| `--force-stale-plan` | Allow plan if machine rebooted since / plan older than 24h |

### Isolation (tests / odd layouts)

| Flag | Purpose |
|------|---------|
| `--codex-root PATH` | Codex sessions dir |
| `--claude-root PATH` | Claude projects dir |
| `--fake-boot EPOCH` | Pretend boot time (or `PFR_FAKE_BOOT`) |
| `--ps-file PATH` | Canned process table instead of live `ps` |
| `--state-dir PATH` | Plans and reports (default `~/.local/state/pfr`) |

### Health

| Flag | Purpose |
|------|---------|
| `--doctor` | Check python, libs, state dir, Ghostty, osascript/ghostty CLI |
| `--doctor --json` | Same checks as machine-readable JSON |

### Launch

| Flag | Purpose |
|------|---------|
| `--dry-run` / `-n` | List only |
| `-y` / `--yes` | Open all matches |
| `--pick` | Multi-select (fzf if present) |
| `--tabs` / `--windows` | Surface mode |
| `--driver ui\|api\|ghostty` | Open strategy (macOS default `ui`, Linux default `ghostty`) |
| `--ui` / `--api` | Shortcuts for driver |
| `--delay SECS` | Pause between opens |
| `--settle SECS` | Wait after creating a surface for the shell |
| `--max N` | Safety cap on opens (default 40) |

### Environment knobs

| Variable | Purpose |
|----------|---------|
| `PFR_WINDOW`, `PFR_LOOKBACK_HOURS`, `PFR_PRE_BOOT_LOOKBACK`, `PFR_PROVIDERS` | Discovery defaults |
| `PFR_OPEN_MODE`, `PFR_DRIVER`, `PFR_DELAY`, `PFR_SETTLE`, `PFR_MAX_OPEN` | Launch defaults |
| `PFR_STATE_DIR` / `XDG_STATE_HOME` | Plan/report location |
| `PFR_FAKE_BOOT` | Test boot override |
| `PFR_VERIFY=0` | Skip post-open verification |
| `PFR_VERIFY_TIMEOUT` | Verify poll seconds (default 15) |
| `PFR_AM=0` | Do not open an agent-mail tab first |
| `PFR_AM_BIN` | Override `am` binary (tests) |

## How clustering works

On a hard power cut, processes mid-write tend to stop updating files at about the same wall-clock time. After reboot you often see many session files with mtimes within a few seconds of each other, all just before `kern.boottime`.

`lib/discover.py`:

1. Collect top-level sessions modified in the last `--lookback-hours`.
2. Drop Codex subagent threads unless `--include-subagents`.
3. Dedupe by `(provider, session_id)`, keep newest file.
4. Mark live resumes from `ps` (UUID right after a `resume` flag). **Cluster first**, then drop live ones so the crash pocket does not shift.
5. **auto mode:** sessions in `[boot - lookback, boot + slack]`, then densest pocket of size `--window`. If that set is empty, global densest window.

Confidence is scored on the full pocket (including already-running members). Density-only mode never gets `high`. See `lib/confidence.py`.

## Resume commands

Same as your usual interactive workflow:

```bash
cd ~/projects/frankensim
cod resume 019fa4a7-3665-7aa3-8633-2a47c42c1d78

cc --resume ba9de0d5-51bb-40f8-9029-8ea3bcfc3481
```

## Ghostty open drivers

### `ui` (macOS default)

1. Launch Ghostty if needed (`open -a Ghostty`).
2. For each session: new dedicated tab (never reuses the default/restored tab), working directory set, `input text` of the resume line (one retry if the shell is still starting).
3. If scripting fails: System Events (`⌘T` / paste / Return). If a tab was created and only input failed, paste into the front tab only (no second `⌘T`).

Needs Automation for Ghostty. Keystroke fallback also needs Accessibility. Leave the keyboard alone while a run is in progress.

### `api` (macOS)

Same surface API without keystroke fallback. Automation required.

### `ghostty` (Linux)

One `ghostty` CLI window per session with `--working-directory` and an interactive shell running the resume command.

## Tab order

When opening for real:

1. Agent-mail (`am`) first, if installed and `PFR_AM` is not `0`.
2. Hub sessions whose cwd is exactly `~/projects`, `/data/projects`, or `/dp`.
3. Remaining sessions (newest first within each group).

## Plans and reports

| Path | Contents |
|------|----------|
| `<state-dir>/last-plan.json` | Latest discovery plan (mode 0600, dir 0700) |
| `<state-dir>/plans/plan-*.json` | Archived plans (newest 20 kept) |
| `<state-dir>/last-report.json` | Post-open verification summary |

Plan load refuses a different boot time or plans older than 24h unless `--force-stale-plan`.

## Doctor

`pfr --doctor` checks python3, core libs, writable state dir, session roots, and platform Ghostty hooks. Exit 0 when healthy. Use `--json` for automation.

## Tests

```bash
./scripts/run_tests.sh
```

Regenerates fixtures, runs `tests/test_*.sh` / `tests/test_*.py` and e2e scripts, writes NDJSON under `tests/logs/`. Offline: uses fixture roots, `--fake-boot`, and canned `--ps-file` data. No live Ghostty required for the default suite.

## Layout

```
power_failure_resumer/
├── power_failure_resumer.sh
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
└── README.md
```

## Notes / limits

- **Already-running skip:** UUID must sit right after `resume` / `--resume` / `--resume=` in process args. Fresh sessions never launched with `resume` are invisible to this check.
- **Subagents** skipped by default.
- **Shared project cwds** (swarms) are normal; all top-level tabs are offered.
- **Claude project dirs** map every non-alphanumeric character to `-`. Prefer JSONL `cwd`; decoded paths are used only if they exist. Details in `docs/session-formats.md`.
- **Scope:** local Codex + Claude Code. Not remote SSH panes, NTM/tmux on other hosts, or Cursor/VS Code.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Empty cluster | `--mode recent --lookback-hours 6 --window 3600`, or widen `--pre-boot-lookback` |
| All sessions “already live” | Expected if you already resumed them; `--force-reopen` to open again |
| Too many sessions | `--projects-only`, `--providers codex`, or `--pick` |
| LOW confidence | Review carefully; density pocket may not be a crash |
| UI keystrokes go nowhere | Accessibility; do not type mid-run; larger `--settle` / `--delay` |
| Tab opens bare shell | Press Up, or larger `--settle` |
| Verify failed / not in `ps` | Check the tab; resume may not have run; larger `--settle` |
| `cod` / `cc` not found | Confirm they work in a normal Ghostty tab (`.zshrc` aliases) |
| AppleScript errors | Automation for controlling app → Ghostty |
| Stale plan refused | Rediscover, or `--force-stale-plan` |
| Skip agent-mail tab | `PFR_AM=0` |
| Skip verification | `PFR_VERIFY=0` |
