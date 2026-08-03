# power_failure_resumer

When this Mac loses power mid-swarm, Ghostty dies and every local `cod` / `cc` agent with it. Session files on disk usually share nearly identical mtimes right before reboot. This tool finds that death-cluster and reopens each session in its own Ghostty tab.

## What it does

1. Scans (honoring `$CODEX_HOME` / `$CLAUDE_HOME` if set):
   - Codex: `~/.codex/sessions/**/rollout-*.jsonl`
   - Claude Code: `~/.claude/projects/**/<uuid>.jsonl` (skips `subagents/`)
2. Clusters sessions that stopped together:
   - **auto** (default): prefer files modified in the minutes *before system boot* (classic power-loss signature); else densest simultaneous-mtime cluster
   - **pre_boot** / **density** / **recent** overrides available
3. For each survivor, opens a Ghostty **tab** and resumes:
   - `cd <cwd> && cod resume <id>` or `cd <cwd> && cc --resume <id>`
   - Default **UI driver**: Ghostty native `new tab` + `input text` (keystroke
     fallback only if scripting fails)
   - Optional **API driver**: same native surface API, no keystroke fallback

## Quick start

```bash
cd ~/projects/power_failure_resumer

# Inspect only (recommended first run after a blackout)
./power_failure_resumer.sh --dry-run

# Open everything in the crash cluster (UI automation — default)
./power_failure_resumer.sh -y

# Same, but via Ghostty AppleScript surface config (no keystrokes)
./power_failure_resumer.sh -y --api

# Interactive multi-select (uses fzf when present)
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
| `--tabs` / `--windows` | Ghostty surface mode |
| `--driver ui\|api` / `--ui` / `--api` | Open strategy (default: **ui**) |
| `--settle SECS` | UI: wait after `⌘T` for the shell (default 0.55) |
| `--providers codex` | Codex only (or `claude`) |
| `--projects-only` | Restrict to `~/projects/...` |
| `--window 180` | Simultaneous-death window (seconds) |
| `--pre-boot-lookback 900` | How far before boot to search |
| `--mode auto\|pre_boot\|density\|recent` | Clustering strategy |
| `--include-subagents` | Keep Codex subagent threads (usually noise) |
| `--force-reopen` | Offer sessions even if a live process already resumed them |
| `--max 40` | Safety cap on opens |
| `--json` | Machine-readable discovery output |

## How clustering works

After a hard power cut, every process that was mid-write loses its buffer at roughly the same wall-clock time. On the next boot you typically see many session files with mtimes within a few seconds of each other, all just before `kern.boottime`.

`lib/discover.py`:

1. Collects top-level sessions modified in the last `--lookback-hours` (default 48h).
2. Drops Codex `thread_source=subagent` (and similar) unless `--include-subagents`.
3. Dedupes by `(provider, session_id)` keeping the newest file.
4. **auto mode**: collect sessions in `[boot - lookback, boot + slack]`, then take the **densest** pocket of size `--window` inside that set (so a session idle 10 minutes before the crash is dropped). If the pre-boot set is empty, fall back to a global densest window.

## Resume commands

Matches your normal workflow:

```bash
cd ~/projects/frankensim
cod resume 019fa4a7-3665-7aa3-8633-2a47c42c1d78

cc --resume ba9de0d5-51bb-40f8-9029-8ea3bcfc3481
```

## Ghostty open drivers

### `ui` (default) — Ghostty native open (+ keystroke fallback)

1. `open -a Ghostty` if needed (normal config / shell)
2. For each session (preferred path on tip Ghostty):
   - always open a **dedicated** tab (never reuses the default/restored tab)
   - `new tab in front window` with working directory set
   - `input text` of `cd '<cwd>' && cod resume …` / `cc --resume …` (one retry on race)
3. If native scripting fails: System Events fallback (`⌘T` / paste / Return).  
   If a tab was created but input failed, fallback pastes into the front tab only (no second ⌘T).

Native path needs Automation for Ghostty. Keystroke fallback also needs Accessibility.  
Don’t type in Ghostty while the run is in progress.

### `api` — Ghostty scripting only

Same native surface API (`new tab` / `new window` + cwd + delayed `input text`).  
No keystroke fallback. Needs Automation permission for AppleScript → Ghostty.

## Layout

```
power_failure_resumer/
├── power_failure_resumer.sh   # CLI entrypoint
├── lib/
│   ├── discover.py                 # scan + cluster → JSON
│   ├── open_sessions_ui.applescript  # UI automation (default)
│   └── open_sessions.applescript     # API surface-config driver
├── docs/
│   └── session-formats.md         # on-disk session format notes (agent reference)
└── README.md
```

## Notes / limits

- **Already-running sessions are skipped.** Discovery scans `ps` for session UUIDs sitting directly after a `resume` / `--resume` flag, so re-running the tool doesn't double-open sessions you already brought back. Override with `--force-reopen`. (Sessions started fresh — never via `resume` — carry no UUID in their argv and can't be detected this way.)
- **Subagents are skipped by default.** Parent TUI sessions are what you had as Ghostty tabs; resuming every subagent would open a wall of noise.
- **Many true top-level tabs can share a project** (swarms). That is intentional — all of them are offered.
- **Claude path encoding** turns *every* non-alphanumeric character into `-` (not just `/`), so reverse-decoding the directory name is lossy; we prefer the `cwd` field inside the JSONL and only trust a decode that resolves to an existing directory. Details: `docs/session-formats.md`.
- Does not resume remote SSH agent panes, NTM/tmux swarms on other machines, or Cursor/VS Code sessions — only local Codex + Claude Code session files.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Empty cluster | `--mode recent --lookback-hours 6 --window 3600` or widen `--pre-boot-lookback` |
| Too many sessions | `--projects-only`, `--providers codex`, or `--pick` |
| UI keystrokes go nowhere / wrong app | Grant Accessibility; don’t touch keyboard mid-run; try larger `--settle` / `--delay` |
| First tab overwrote an existing Ghostty tab | Fixed: never reuses the default tab; always opens a dedicated surface. Also fixed Ghostty process detection (not `pgrep -x Ghostty`). |
| Tab opens bare shell | Press Up or re-run with larger `--settle`; API retries input text once |
| `cod` / `cc` not found in tab | Confirm they work in a normal Ghostty tab (aliases live in `.zshrc`) |
| AppleScript errors (api) | Automation allowed for the controlling app → Ghostty |
| Wrong model flags on codex | Script uses `cod` / `cc` so **your** shell aliases win |
