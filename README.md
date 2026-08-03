# power_failure_resumer

When this Mac hard-powers off mid-swarm, Ghostty dies and every local `cod` / `cc` agent goes with it. Session files on disk often share nearly the same mtime just before reboot. This tool finds that simultaneous-stop cluster and reopens each session in its own Ghostty tab.

```bash
curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/power_failure_resumer/main/install.sh?$(date +%s)" | bash
```

Symlinks `pfr` into `~/.local/bin` (install root: `~/.local/share/pfr`). Then: `pfr --doctor`, `pfr --dry-run`, `pfr -y`.

## What it does

1. **Discover** session files (honors `$CODEX_HOME` / `$CLAUDE_HOME` if set):
   - Codex: `~/.codex/sessions/**/rollout-*.jsonl`
   - Claude Code: `~/.claude/projects/**/<uuid>.jsonl` (skips `subagents/`)
2. **Cluster** sessions that stopped together; score crash **confidence** (`high` / `medium` / `low`); skip ones that already look live in `ps`.
3. **Save a plan** to `~/.local/state/pfr/last-plan.json` so you can inspect once and open later without rediscovering.
4. **Open** Ghostty surfaces and run `cd <cwd> && cod resume <id>` or `cc --resume <id>` (interactive shell so your aliases apply).
5. **Verify** resumes against `ps` and write `last-report.json`.
6. **Tab order:** live run-log status tab, then agent-mail (`am` if installed), then hub cwds (`~/projects`, `/data/projects`, `/dp`), then the rest. List lines show titles/previews when present.

## Install

**One-liner** (above), or flags after `bash -s --`:

| Flag | Purpose |
|------|---------|
| `--easy-mode` | Add `~/.local/bin` to PATH in shell rc files |
| `--prefix DIR` | Install root (default `~/.local/share/pfr`) |
| `--bin-dir DIR` | Symlink dir for `pfr` (default `~/.local/bin`) |
| `--ref REF` | Git ref/branch/tag (default `main`) |
| `--offline TARBALL` | Install from a local tarball |
| `--force` | Reinstall even if the same version is present |
| `--verify` | Run `pfr --doctor` after install |
| `--quiet` / `--no-gum` | Quieter or plain ANSI output |

**From a checkout:**

```bash
git clone https://github.com/Dicklesworthstone/power_failure_resumer
cd power_failure_resumer
ln -sf "$PWD/power_failure_resumer.sh" ~/.local/bin/pfr
```

**Needs:** bash 3.2+, python3; on macOS, `osascript` and Ghostty (Automation; Accessibility only for keystroke fallback). On Linux, the `ghostty` CLI. `gum` and `fzf` optional.

## Quick start

```bash
pfr --dry-run          # after a blackout: inspect first
pfr -y                 # open the crash cluster
pfr --pick             # cherry-pick (fzf if installed)
pfr --last-plan -y     # open the saved plan later
pfr --doctor           # health check
pfr --doctor --json
```

From a checkout without installing: `./power_failure_resumer.sh …` and `./scripts/run_tests.sh`.

## Workflow

```
blackout → boot → pfr --dry-run  → review list + confidence
                 → pfr -y          → open + verify
                 → pfr --last-plan → same set without rediscover
```

Dry-run prints the plan path and:

```text
next: pfr --last-plan -y   or   pfr --last-plan --pick
```

## Example

```console
$ pfr --dry-run
› boot time:     2026-08-03 16:22:58
› cluster mode:  pre_boot
› anchor mtime:  2026-08-03 16:22:49
› matched:       16 session(s)  (from 30 recent candidates)
› confidence:    high  (mode=pre_boot, cluster_size=16, …)

──── sessions to resume ────
 1. codex   16:22:49     ~/projects/frankensim
      cod resume 019fc925-a15e-7961-9a9c-7e62ef6cea2f
 2. claude  16:22:49     ~/projects/frankenterm
      cc --resume ba9de0d5-51bb-40f8-9029-8ea3bcfc3481
      (Review project for bugs and improvements)
      » study this project and look for bugs…
› plan saved: ~/.local/state/pfr/last-plan.json
› next: pfr --last-plan -y   or   pfr --last-plan --pick
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
| `--limit N` | Cap listed/opened sessions (confidence still uses full pocket) |
| `--json` | Machine-readable discovery output |

### Plans

| Flag | Purpose |
|------|---------|
| (default) | Write `<state-dir>/last-plan.json` after discovery |
| `--last-plan` | Load that plan; skip rediscovery |
| `--plan PATH` | Load a specific plan file |
| `--save-plan PATH` | Also write a copy to PATH |
| `--no-save-plan` | Do not write last-plan.json |
| `--force-stale-plan` | Allow plan if machine rebooted since / plan older than 24h |

### Isolation

| Flag | Purpose |
|------|---------|
| `--codex-root PATH` | Codex sessions dir |
| `--claude-root PATH` | Claude projects dir |
| `--fake-boot EPOCH` | Pretend boot time (or `PFR_FAKE_BOOT`) |
| `--ps-file PATH` | Canned process table instead of live `ps` |
| `--state-dir PATH` | Plans, reports, run logs (default `~/.local/state/pfr`) |

### Health

| Flag | Purpose |
|------|---------|
| `--doctor` | Check python, libs, state dir, Ghostty hooks |
| `--doctor --json` | Same as JSON |

### Launch

| Flag | Purpose |
|------|---------|
| `--dry-run` / `-n` | List only |
| `-y` / `--yes` | Open all matches |
| `--pick` | Multi-select (fzf if present) |
| `--tabs` / `--windows` | Surface mode |
| `--driver ui\|api\|ghostty` | macOS default `ui`; Linux default `ghostty` |
| `--ui` / `--api` | Driver shortcuts |
| `--delay SECS` | Pause between opens |
| `--settle SECS` | Wait after creating a surface for the shell |
| `--max N` | Safety cap on opens (default 40) |

## Environment

| Variable | Purpose |
|----------|---------|
| `PFR_WINDOW`, `PFR_LOOKBACK_HOURS`, `PFR_PRE_BOOT_LOOKBACK`, `PFR_PROVIDERS` | Discovery defaults |
| `PFR_OPEN_MODE`, `PFR_DRIVER`, `PFR_DELAY`, `PFR_SETTLE`, `PFR_MAX_OPEN` | Launch defaults |
| `CODEX_HOME`, `CLAUDE_HOME` | Relocated agent state dirs |
| `PFR_STATE_DIR` / `XDG_STATE_HOME` | Plan/report/run-log location |
| `PFR_CODEX_ROOT`, `PFR_CLAUDE_ROOT`, `PFR_PS_FILE`, `PFR_FAKE_BOOT` | Same as isolation flags |
| `PFR_VERIFY=0` | Skip post-open verification |
| `PFR_VERIFY_TIMEOUT` | Verify poll seconds (default 15) |
| `PFR_STATUS_TAB=0` | Do not open the live run-log tab |
| `PFR_AM=0`, `PFR_AM_BIN` | Skip / override agent-mail tab |
| `PFR_KEEP_TEMPS=1` | Keep temp files (debug) |
| `PFR_DOCTOR_SIM_MISSING` | Comma list of doctor checks to force-fail (tests) |

No config file required; flags and env only.

## Clustering and confidence

On a hard power cut, mid-write processes tend to stop updating files at about the same wall-clock time. After reboot, many session files share mtimes within a few seconds of each other, just before `kern.boottime`.

`lib/discover.py`:

1. Collect top-level sessions modified in the last `--lookback-hours`.
2. Drop Codex subagents unless `--include-subagents`.
3. Dedupe by `(provider, session_id)`, keep newest.
4. Mark live resumes from `ps` (UUID right after a `resume` flag). **Cluster first**, then drop live ones so the crash pocket does not shift.
5. **auto mode:** sessions in `[boot - lookback, boot + slack]`, then densest pocket of size `--window`. If empty, global densest window.

Confidence is scored on the full pocket (including already-running members). Density-only mode never gets `high`. See `lib/confidence.py`.

Titles/previews: Claude prefers `custom-title` then `ai-title` then first user text; Codex uses nickname + project and first user snippet. Format notes: `docs/session-formats.md`.

## Resume commands

```bash
cd ~/projects/frankensim
cod resume 019fa4a7-3665-7aa3-8633-2a47c42c1d78

cc --resume ba9de0d5-51bb-40f8-9029-8ea3bcfc3481
```

## Ghostty open drivers

### `ui` (macOS default)

1. Launch Ghostty if needed.
2. Each session gets a **new** tab (never reuses the default/restored tab); `input text` of the resume line (one retry if the shell is still starting).
3. If scripting fails: System Events (`⌘T` / paste / Return). If a tab was created and only input failed, paste into the front tab only (no second `⌘T`).

Needs Automation for Ghostty. Keystroke fallback also needs Accessibility. Do not type in Ghostty while a run is in progress.

### `api` (macOS)

Same surface API without keystroke fallback.

### `ghostty` (Linux)

One `ghostty` CLI window per session with `--working-directory` and an interactive shell.

## Tab order

When opening for real:

1. Live status tab: `tail -f` of this run’s log under `<state-dir>/run-*.log` (disable with `PFR_STATUS_TAB=0`).
2. Agent-mail (`am`) if installed and `PFR_AM` is not `0`.
3. Hub sessions (`~/projects`, `/data/projects`, `/dp`).
4. Remaining sessions, newest first within each group.

## Plans and reports

| Path | Contents |
|------|----------|
| `<state-dir>/last-plan.json` | Latest discovery plan (0600; dir 0700) |
| `<state-dir>/plans/plan-*.json` | Archives (newest 20 kept) |
| `<state-dir>/last-report.json` | Post-open verification summary |
| `<state-dir>/run-*.log` | Live run log for the status tab |

Plan load refuses a different boot or plans older than 24h unless `--force-stale-plan`.

## Doctor

`pfr --doctor` checks python3, core libs, writable state dir, session roots, and platform Ghostty hooks. Exit 0 when healthy. `--json` for automation.

## Tests

```bash
./scripts/run_tests.sh
```

Regenerates fixtures (mtimes cannot live in git), runs offline suites (smoke, cluster, titles, plan, doctor, tab order, verify, e2e dry/plan/skip). Uses fixture roots, `--fake-boot`, and canned `--ps-file`. NDJSON under `tests/logs/`. No live Ghostty required for the default suite.

## Layout

```
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
├── AGENTS.md
├── CHANGELOG.md
└── README.md
```

## Notes / limits

- **Already-running skip:** UUID must sit right after `resume` / `--resume` / `--resume=` in process args. Fresh sessions never launched with `resume` cannot be skip-detected the same way.
- **Subagents** skipped by default.
- **Shared project cwds** (swarms) are normal; all top-level tabs are offered.
- **Claude project dirs** map every non-alphanumeric character to `-`. Prefer JSONL `cwd`; decoded paths only if they exist.
- **Scope:** local Codex + Claude Code. Not remote SSH panes, NTM/tmux on other hosts, Cursor, or VS Code.
- **macOS** needs Automation (and Accessibility if the keystroke fallback fires). `pfr --doctor` reports what is missing.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Empty cluster | `--mode recent --lookback-hours 6 --window 3600`, or widen `--pre-boot-lookback` |
| All sessions already live | Expected if you already resumed them; `--force-reopen` to open again |
| Too many sessions | `--projects-only`, `--providers codex`, or `--pick` |
| LOW confidence | Review carefully; density pocket may not be a crash |
| UI keystrokes go nowhere | Accessibility; do not type mid-run; larger `--settle` / `--delay` |
| Tab opens bare shell | Press Up, or larger `--settle` |
| Verify failed / not in `ps` | Check the tab; resume may not have run; larger `--settle` |
| `cod` / `cc` not found | Confirm aliases in a normal Ghostty tab (`.zshrc`) |
| AppleScript errors | Automation: controlling app → Ghostty |
| Stale plan refused | Rediscover, or `--force-stale-plan` |
| Skip status / agent-mail tab | `PFR_STATUS_TAB=0` / `PFR_AM=0` |
| Skip verification | `PFR_VERIFY=0` |

## FAQ

**Will it double-open sessions I already resumed?**  
No, if those processes still show `resume <uuid>` in `ps`. Use `--force-reopen` to override.

**I rebooted cleanly; will it invent a crash?**  
Density pockets far from boot score `low`. Only a tight pre-boot pocket of enough sessions scores `high`. Reasons print either way.

**Why is the first tab a log tail?**  
Live run log so you can watch the open loop. Disable with `PFR_STATUS_TAB=0`.

**Linux?**  
Discovery, plans, and verify are the same. Opening uses the `ghostty` CLI (one window per session).

**Where does data go?**  
Local only: reads session files; writes under `~/.local/state/pfr` (or `--state-dir`).

## About Contributions

*About Contributions:* Please don't take this the wrong way, but I do not accept outside contributions for any of my projects. I simply don't have the mental bandwidth to review anything, and it's my name on the thing, so I'm responsible for any problems it causes; thus, the risk-reward is highly asymmetric from my perspective. I'd also have to worry about other "stakeholders," which seems unwise for tools I mostly make for myself for free. Feel free to submit issues, and even PRs if you want to illustrate a proposed fix, but know I won't merge them directly. Instead, I'll have Claude or Codex review submissions via `gh` and independently decide whether and how to address them. Bug reports in particular are welcome. Sorry if this offends, but I want to avoid wasted time and hurt feelings. I understand this isn't in sync with the prevailing open-source ethos that seeks community contributions, but it's the only way I can move at this velocity and keep my sanity.

## License

MIT. See [LICENSE](LICENSE).
