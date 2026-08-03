<div align="center">

# ⚡ power_failure_resumer

**Your Mac lost power mid-swarm. Twenty agent sessions died with it. Get them all back in one command.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue)]()
[![Made with Bash + Python](https://img.shields.io/badge/made%20with-bash%20%2B%20python-green)]()
[![Tests](https://img.shields.io/badge/tests-10%20suites%20offline-brightgreen)]()

```bash
curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/power_failure_resumer/main/install.sh?$(date +%s)" | bash
```

</div>

---

## TL;DR

### The Problem

You run big fleets of local coding agents — Codex CLI (`cod`) and Claude Code (`cc`) — in Ghostty tabs. A power failure (or hard reboot) kills the terminal and every session in it. The transcripts survive on disk, but reconstructing *which twenty sessions were live at the moment of death*, in which project directories, with which resume ids, is miserable manual archaeology — exactly when you're least in the mood for it.

### The Solution

`pfr` exploits the forensic signature of a power cut: every process that was mid-write stops touching its session file at nearly the same wall-clock moment, just before `kern.boottime`. It scans Codex and Claude Code session files, finds that simultaneous-death cluster, scores how confident it is that this was a real crash, and reopens every victim in its own Ghostty tab — `cd <cwd> && cod resume <id>` typed into a real interactive shell so your aliases apply.

### Why use pfr?

| Feature | What you get |
|---------|--------------|
| **Crash-cluster detection** | Pre-boot mtime clustering with densest-pocket isolation — idle sessions from earlier don't sneak in |
| **Confidence scoring** | `high` / `medium` / `low` with reasons; a busy afternoon's dense pocket never masquerades as a crash |
| **Already-running skip** | Sessions you resumed by hand are detected in `ps` and not double-opened |
| **Plans** | Discovery writes `last-plan.json` — inspect once, open later, even from another terminal |
| **Post-open verification** | Polls `ps` for resume evidence, writes `last-report.json`, exits non-zero on silent failures |
| **Sensible tab order** | Live status-log tab first, agent-mail (`am`) tab next, hub projects, then the rest |
| **Titles + previews** | Each session shows its Claude ai-title / first user message so you know what you're resuming |
| **Doctor** | `pfr --doctor` catches missing Automation permission and friends before they waste a recovery |
| **Offline test suite** | 10 suites against generated fixtures — no Ghostty, no network, no live agents required |

## Quick example

```console
$ pfr --dry-run
› boot time:     2026-08-03 16:22:58
› cluster mode:  pre_boot
› anchor mtime:  2026-08-03 16:22:49
› matched:       16 session(s)  (from 30 recent candidates)
› confidence:    high  (mode=pre_boot, cluster_size=16, anchor_gap_to_boot=8.9s, pre_boot_tight_pocket)

──── sessions to resume ────
 1. codex   16:22:49     ~/projects/frankensim
      cod resume 019fc925-a15e-7961-9a9c-7e62ef6cea2f
 2. claude  16:22:49     ~/projects/frankenterm
      cc --resume ba9de0d5-51bb-40f8-9029-8ea3bcfc3481
      (Review project for bugs and improvements)
      » study this project and look for bugs or obvious ways to improve it…
 ...
› plan saved: ~/.local/state/pfr/last-plan.json  (confidence=high, 16 sessions)
› next: pfr --last-plan -y   or   pfr --last-plan --pick

$ pfr --last-plan -y        # open all 16, verify against ps, report
$ pfr --doctor              # if anything misbehaves
```

## Design philosophy

1. **mtime is the death signal.** Content timestamps say what a session talked about; the file mtime says when its process stopped writing. Clustering runs on mtime alone.
2. **Discover once, open later.** Rediscovery drifts — sessions age, you resume some by hand, new work starts. Plans freeze the decision so opening is repeatable.
3. **Cluster first, filter second.** Already-running sessions are dropped *after* the crash pocket is chosen, so filtering can't shift the cluster onto an unrelated burst of activity.
4. **Never lie about success.** Every open is verified against `ps`; a tab that silently shows a bare shell is a reported failure, not a shrug.
5. **Your shell, your aliases.** Resume commands are typed into a real interactive shell. If `cod` carries your model flags, they apply.

## How it compares

| | pfr | Ghostty window restore | tmux-resurrect | Manual archaeology |
|---|---|---|---|---|
| Restores the *agent conversation* | ✅ `cod resume` / `cc --resume` | ❌ empty shells | ❌ empty panes | ✅ eventually |
| Knows which sessions died in the crash | ✅ pre-boot clustering | ❌ | ❌ | 😰 you, with `ls -lt` |
| Skips ones you already brought back | ✅ via `ps` | ❌ | ❌ | 😰 memory |
| Confidence it was a real power cut | ✅ scored + reasons | — | — | — |
| Works after *hard* power loss | ✅ that's the point | partial | only if saved | ✅ |

## Installation

**One-liner (recommended):**

```bash
curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/power_failure_resumer/main/install.sh?$(date +%s)" | bash
```

Installs to `~/.local/share/pfr`, symlinks `pfr` into `~/.local/bin`. Installer flags (append after `bash -s --`): `--easy-mode` (wire PATH into rc files), `--prefix DIR`, `--bin-dir DIR`, `--ref REF`, `--offline TARBALL`, `--force`, `--verify` (run doctor after), `--quiet`, `--no-gum`.

**From a checkout:**

```bash
git clone https://github.com/Dicklesworthstone/power_failure_resumer
cd power_failure_resumer
ln -sf "$PWD/power_failure_resumer.sh" ~/.local/bin/pfr
```

**Requirements:** bash 3.2+, python3, and on macOS `osascript` + [Ghostty](https://ghostty.org) (Automation permission; Accessibility only for the keystroke fallback). On Linux, the `ghostty` CLI. `gum` and `fzf` are optional polish.

## Quick start

```bash
# 1. After a blackout: inspect first
pfr --dry-run

# 2. Open the whole crash cluster
pfr -y

# 3. …or cherry-pick (fzf if installed)
pfr --pick

# 4. …or reopen later from the saved plan
pfr --last-plan -y

# 5. Health check when something misbehaves
pfr --doctor
```

The full pipeline each run: **discover** session files (honoring `$CODEX_HOME` / `$CLAUDE_HOME`) → **cluster** the simultaneous-death pocket and score confidence → **skip** sessions already live in `ps` → **save the plan** → **open** tabs in order (status log, `am`, hubs, rest) → **verify** against `ps` and write the report.

```
blackout → boot → pfr --dry-run   → review list + confidence
                → pfr -y           → open + verify + report
                → pfr --last-plan  → same set later, no rediscover
```

## Command reference

### Discovery

| Flag | Purpose |
|------|---------|
| `--window SECS` | Simultaneous-death window (default 180) |
| `--lookback-hours H` | Only sessions modified in last H hours (default 48) |
| `--pre-boot-lookback S` | Seconds before boot to search (default 900) |
| `--mode auto\|pre_boot\|density\|recent` | Clustering strategy (default auto) |
| `--providers LIST` | `codex`, `claude`, or both |
| `--projects-only` | Restrict to `~/projects/...` |
| `--include-subagents` | Keep Codex subagent threads (noisy) |
| `--force-reopen` | Include sessions that already look live in `ps` |
| `--limit N` | Cap listed/opened sessions (confidence still scores the full pocket) |
| `--json` | Machine-readable discovery output |

### Plans

| Flag | Purpose |
|------|---------|
| (default) | Every discovery writes `<state-dir>/last-plan.json` |
| `--last-plan` | Load that plan; skip rediscovery |
| `--plan PATH` | Load a specific plan file |
| `--save-plan PATH` | Also write a copy to PATH |
| `--no-save-plan` | Don't write last-plan.json this run |
| `--force-stale-plan` | Allow a plan from a different boot / older than 24h |

### Launch

| Flag | Purpose |
|------|---------|
| `--dry-run` / `-n` | List only |
| `-y` / `--yes` | Open all matches without prompting |
| `--pick` | Multi-select (fzf when present) |
| `--tabs` / `--windows` | Ghostty surface mode |
| `--driver ui\|api\|ghostty` | macOS default `ui`; Linux default `ghostty` |
| `--delay SECS` / `--settle SECS` | Pacing between opens / shell-readiness wait |
| `--max N` | Safety cap on opens (default 40) |

### Health & isolation

| Flag | Purpose |
|------|---------|
| `--doctor` (+ `--json`) | Environment health checks; exit 0 when healthy |
| `--codex-root` / `--claude-root` | Alternate session roots (tests, odd layouts) |
| `--fake-boot EPOCH` / `--ps-file PATH` | Deterministic boot time / process table |
| `--state-dir PATH` | Plans + reports location (default `~/.local/state/pfr`) |

## Configuration

Everything is flag-or-environment; no config file required.

| Variable | Purpose |
|----------|---------|
| `PFR_WINDOW`, `PFR_LOOKBACK_HOURS`, `PFR_PRE_BOOT_LOOKBACK`, `PFR_PROVIDERS` | Discovery defaults |
| `PFR_OPEN_MODE`, `PFR_DRIVER`, `PFR_DELAY`, `PFR_SETTLE`, `PFR_MAX_OPEN` | Launch defaults |
| `CODEX_HOME`, `CLAUDE_HOME` | Relocated agent state dirs (honored automatically) |
| `PFR_STATE_DIR` / `XDG_STATE_HOME` | Plan/report/log location |
| `PFR_VERIFY=0`, `PFR_VERIFY_TIMEOUT` | Skip / tune post-open verification (default 15s) |
| `PFR_STATUS_TAB=0` | Don't open the live run-log tab |
| `PFR_AM=0`, `PFR_AM_BIN` | Skip / override the agent-mail tab |
| `PFR_CODEX_ROOT`, `PFR_CLAUDE_ROOT`, `PFR_PS_FILE`, `PFR_FAKE_BOOT` | Test isolation |

## Architecture

```
                 ┌──────────────────────────────────────────────────┐
                 │              power_failure_resumer.sh            │
                 │        (CLI, prompts, tab order, drivers)        │
                 └───┬──────────┬──────────┬──────────┬─────────────┘
                     │          │          │          │
             discover.py    plan.py   confidence.py  verify.py
             scan+cluster  save/load   score plan    poll ps,
             mark running  staleness   HIGH/MED/LOW  last-report
                     │          │
   ~/.codex/sessions/**  ~/.local/state/pfr/{last-plan,plans/,last-report,last-run.log}
   ~/.claude/projects/**
                     │
        ┌────────────┴───────────────┐
        │ macOS: open_sessions_ui /  │   Linux: ghostty CLI,
        │ open_sessions .applescript │   one window per session
        └────────────────────────────┘

Tab order when opening:  ① live status log  ② agent-mail (am)  ③ hub cwds
(~/projects, /data/projects, /dp)  ④ everything else, newest first
```

## How clustering works

On a hard power cut, processes mid-write tend to stop updating files at about the same wall-clock time. After reboot you often see many session files with mtimes within a few seconds of each other, all just before `kern.boottime`.

`lib/discover.py`:

1. Collect top-level sessions modified in the last `--lookback-hours`.
2. Drop Codex subagent threads unless `--include-subagents`.
3. Dedupe by `(provider, session_id)`, keep newest file.
4. Mark live resumes from `ps` (UUID right after a `resume` flag). **Cluster first, then drop live ones** so the crash pocket does not shift.
5. **auto mode:** sessions in `[boot − lookback, boot + slack]`, then densest pocket of size `--window` inside that set — a session idle ten minutes before the crash falls out. If the pre-boot set is empty, fall back to a global densest window.

Confidence is scored on the full pocket (including already-running members) before any `--limit` truncation. Density-only mode never gets `high`. See `lib/confidence.py` for the locked rubric.

## Resume commands

Same as your usual interactive workflow:

```bash
cd ~/projects/frankensim
cod resume 019fa4a7-3665-7aa3-8633-2a47c42c1d78

cc --resume ba9de0d5-51bb-40f8-9029-8ea3bcfc3481
```

The script types those into a real interactive shell so your `cod` / `cc` aliases (and their model flags) apply.

## Ghostty open drivers

### `ui` (macOS default)

1. Launch Ghostty if needed (`open -a Ghostty`).
2. For each session: open a **new** dedicated tab (never reuses the default/restored tab), set working directory, `input text` of the resume line — with one retry if the shell is still starting.
3. If scripting fails: System Events fallback (`⌘T` / paste / Return). If a tab was already created and only input failed, the fallback pastes into the front tab only (no second `⌘T`, no double-open).

Needs Automation for Ghostty. Keystroke fallback also needs Accessibility. Leave the keyboard alone while a run is in progress.

### `api` (macOS)

Same surface API (`new tab` / `new window` + cwd + delayed `input text`) without the keystroke fallback. Automation permission required.

### `ghostty` (Linux)

One `ghostty` CLI window per session with `--working-directory` and an interactive shell running the resume command. (`--tabs` silently becomes `--windows`: the CLI cannot address an existing window's tabs.)

## Tab order

When opening for real:

1. **Status tab** — tails the gum-formatted run log (`<state-dir>/last-run.log`) so you can watch the whole resume live. Disable with `PFR_STATUS_TAB=0`.
2. **Agent-mail** — `am`, if installed and `PFR_AM` is not `0`.
3. **Hub sessions** whose cwd is exactly `~/projects`, `/data/projects`, or `/dp`.
4. Remaining sessions, newest first within each group.

## Plans and reports

| Path | Contents |
|------|----------|
| `<state-dir>/last-plan.json` | Latest discovery plan (mode 0600, dir 0700, atomic writes) |
| `<state-dir>/plans/plan-*.json` | Archived plans (newest 20 kept) |
| `<state-dir>/last-report.json` | Post-open verification summary |
| `<state-dir>/last-run.log` | Formatted live log for the status tab |

Plan load refuses a different boot time or plans older than 24h unless `--force-stale-plan`, and rejects any `schema_version` other than 1.

## Doctor

`pfr --doctor` checks python3, core libs, writable state dir, session roots, and the platform's Ghostty hooks (Ghostty.app + osascript + Automation probe on macOS; `ghostty` CLI on Linux), plus optional niceties (`fzf`, `am`). Exit 0 when healthy; `--json` for automation; `PFR_DOCTOR_SIM_MISSING=ghostty` simulates failures in tests.

## Testing

```bash
./scripts/run_tests.sh
```

Regenerates mtime-bearing fixtures (git can't store mtimes), then runs `tests/test_*.sh`, `tests/test_*.py`, and `tests/e2e_*.sh` in name order, writing NDJSON events and per-test output under `tests/logs/` (last 50 lines dumped on failure). The default run is fully offline: fixture roots, `--fake-boot`, and canned `--ps-file` tables — no live Ghostty, no network, no writes to the real `~/.codex` / `~/.claude`.

Current suites: smoke, clustering (densest-window ties, pre-boot outliers, dedupe, running-mark regression), titles/previews, plan + confidence rubric (with golden fixture), doctor contracts, tab order, verification, and e2e dry-run / plan-roundtrip / skip-running.

## Layout

```
power_failure_resumer/
├── power_failure_resumer.sh        # CLI: prompts, tab order, drivers
├── install.sh                      # curl|bash installer (gum + ANSI)
├── lib/
│   ├── discover.py                 # scan + cluster + running-skip → JSON
│   ├── confidence.py               # pure HIGH/MEDIUM/LOW rubric + plan build
│   ├── plan.py                     # save/load plans, staleness, validation
│   ├── verify.py                   # post-open ps polling + last-report.json
│   ├── open_sessions_ui.applescript   # macOS ui driver (default)
│   └── open_sessions.applescript      # macOS api driver
├── scripts/run_tests.sh            # NDJSON-logging offline test runner
├── tests/                          # fixtures (generated), unit + e2e suites
├── docs/session-formats.md         # Codex/Claude on-disk format notes
├── CHANGELOG.md
└── README.md
```

Session-file format details (envelope shapes, title priority, encoding rules, mtime-vs-activity): [`docs/session-formats.md`](docs/session-formats.md).

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Empty cluster | `--mode recent --lookback-hours 6 --window 3600`, or widen `--pre-boot-lookback` |
| All sessions already live | Expected if you already resumed them; `--force-reopen` to reopen anyway |
| Too many sessions | `--projects-only`, `--providers codex`, or `--pick` |
| LOW confidence warning | The dense pocket may not be a crash — review before opening |
| Keystrokes go nowhere (macOS) | Grant Accessibility; don't type mid-run; larger `--settle` / `--delay` |
| Tab opens a bare shell | Press ↑, or re-run with a larger `--settle` |
| Verify failed / not in `ps` | The resume likely never executed in that tab; larger `--settle` |
| `cod` / `cc` not found in tab | Confirm the aliases work in a normal Ghostty tab (`.zshrc`) |
| AppleScript errors | System Settings → Privacy → Automation: allow your terminal → Ghostty |
| Stale plan refused | Rediscover, or `--force-stale-plan` if you know it's right |

## Limitations

- **Scope is local Codex CLI + Claude Code.** No remote SSH panes, NTM/tmux swarms on other machines, Cursor, or VS Code sessions.
- **Already-running detection needs `resume` in argv.** A session originally started *without* `resume` carries no UUID in its process args and can't be skip-detected (post-open verification has the same blind spot in reverse — it proves the command ran, not that the agent is healthy).
- **Claude's directory encoding is lossy** (every non-alphanumeric → `-`); pfr prefers the `cwd` embedded in the JSONL and only trusts a decoded path that exists.
- **macOS automation needs permissions.** First run will prompt for Automation (and Accessibility if the fallback fires); `pfr --doctor` tells you what's missing.
- **A normal shutdown looks nothing like a crash** — and pfr says so (`low` confidence) rather than pretending.

## FAQ

**Q: Will it double-open sessions I already resumed by hand?**
No — discovery scans `ps` for UUIDs sitting right after a `resume` flag and skips those (override with `--force-reopen`).

**Q: What if I ran pfr twice?**
Same mechanism: the first run's sessions are now live in `ps`, so the second run skips them.

**Q: My machine reboots nightly — will pfr hallucinate a crash?**
Density pockets far from boot score `low`, and only a tight pre-boot pocket of ≥3 sessions earns `high`. The summary prints the reasons either way.

**Q: Why does the first tab just show a log?**
That's the live run log (tab ①) so you can watch the resume happen; agent-mail (`am`) is tab ② when installed. Disable with `PFR_STATUS_TAB=0` / `PFR_AM=0`.

**Q: Does it work on Linux?**
Yes: discovery/plans/verification are identical; opening uses the `ghostty` CLI (one window per session) since there's no AppleScript.

**Q: Why not just re-run `cod resume` from history?**
For one session, sure. For a 20-tab swarm across 6 projects, the cluster + plan + verify loop is the difference between one command and half an hour.

**Q: Where does my data go?**
Nowhere. Everything is local: reads session files, writes plans/reports under `~/.local/state/pfr`.

## About Contributions

*About Contributions:* Please don't take this the wrong way, but I do not accept outside contributions for any of my projects. I simply don't have the mental bandwidth to review anything, and it's my name on the thing, so I'm responsible for any problems it causes; thus, the risk-reward is highly asymmetric from my perspective. I'd also have to worry about other "stakeholders," which seems unwise for tools I mostly make for myself for free. Feel free to submit issues, and even PRs if you want to illustrate a proposed fix, but know I won't merge them directly. Instead, I'll have Claude or Codex review submissions via `gh` and independently decide whether and how to address them. Bug reports in particular are welcome. Sorry if this offends, but I want to avoid wasted time and hurt feelings. I understand this isn't in sync with the prevailing open-source ethos that seeks community contributions, but it's the only way I can move at this velocity and keep my sanity.

## License

MIT — see [LICENSE](LICENSE).
