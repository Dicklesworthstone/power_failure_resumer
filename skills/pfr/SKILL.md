---
name: pfr
description: >-
  Safely resumes local Codex and Claude sessions in Ghostty with pfr. Use when
  restoring agent tabs after a reboot or power loss, reviewing saved plans,
  excluding ntm panes, or diagnosing verification.
---

# PFR

Use `pfr` as a recovery pipeline: discover local session logs, review the likely pre-boot cluster, open a frozen plan in Ghostty, then verify the exact resume UUIDs in running processes. All tabs open in one batch; each tab runs its resume command directly in an interactive login shell, with the model and reasoning effort recorded in the session's transcript pinned on the command.

## Default recovery loop

```bash
pfr --doctor
pfr --dry-run
pfr --last-plan --pick
python3 -m json.tool ~/.local/state/pfr/last-report.json
```

Run `./power_failure_resumer.sh` instead of `pfr` from an uninstalled checkout.

1. Run `--doctor` when setup, shell commands, Ghostty permissions, or platform support may be wrong. Treat critical failures as launch blockers. An `ntm_history` line means ntm records were found and ntm-spawned sessions will be excluded from discovery.
2. Run `--dry-run` and inspect the mode, confidence, reasons, working directory, title, and preview. Also read the `skipped:` lines: already-running sessions and ntm-spawned sessions are dropped with printed counts. This deliberately saves the reviewed set as `last-plan.json`.
3. Open that exact plan with `--last-plan --pick`. Use `--last-plan -y` only when every listed session is intended.
4. Treat a nonzero exit or an unverified entry in `last-report.json` as a failed recovery. Process verification proves only that the exact UUID appears in process arguments, not that the agent or model is healthy.

For machine-readable inspection without changing saved-plan state:

```bash
pfr --json --no-save-plan
```

## ntm swarm sessions

Sessions spawned by ntm tmux swarms are excluded by default; ntm owns their recovery, and reopening them as loose Ghostty tabs strands the swarm. Attribution layers ntm's own records (send-history prompts matched against first and last user messages, manifest pane specs, checkpoint session-id bindings) plus a narrow addressed-as-a-pane phrasing check for swarms that left no record.

| Situation | Action |
|---|---|
| Swarm panes need recovery | Use ntm's own recovery, not pfr |
| A genuine session was excluded as ntm | Re-run with `--include-ntm` and select it with `--pick`, or point `--ntm-history` / `--ntm-data` at the right records |
| Deliberately reopening swarm panes as tabs | `--include-ntm` plus `--pick`; never `-y` |

## Choose safely

| Situation | Action |
|---|---|
| Correct `pre_boot` cluster with HIGH confidence | Open the saved plan; still review the list first |
| MEDIUM, LOW, `density`, or `recent` result | Narrow the set or use `--pick`; confidence is not crash proof |
| Too many sessions | Add `--providers codex` or `--providers claude`, `--projects-only`, or a smaller `--window` |
| No plausible cluster | Inspect a manual fallback with `pfr --mode recent --lookback-hours 6 --window 3600 --pick` |
| Partial launch or verification failure | Inspect the per-tab failure reasons and the report, then run fresh discovery with `pfr --pick` |
| Everything is already running | Accept the default skip behavior; use `--force-reopen` only to create intentional duplicates |

Fresh discovery is important after a partial launch: it skips exact UUIDs that are now running. Loading `--last-plan` freezes the old set and does not repeat live-session filtering, so never reopen an old plan wholesale as a retry.

## Guardrails

- Never make `pfr -y` the first recovery command. Review before opening.
- Never treat density-only or recent-mode results as authoritative; only pre-boot evidence can score HIGH.
- Avoid `--force-stale-plan`; prefer rediscovery. Use it only after confirming the boot identity and every session in the plan.
- Avoid `--force-reopen` unless duplicate sessions are explicitly desired.
- Never execute a serialized plan's `resume_cmd`. PFR treats it as informational and reconstructs commands from validated fields (provider, UUID, absolute cwd, model, effort). Do not hand-edit model or effort in a plan; validation rejects malformed values.
- Keep recovery local. PFR restores local Codex and Claude sessions; it does not infer remote SSH, tmux, Cursor, or model health.

## Diagnose failures

- Tab shows a bare shell: the native command launch failed and the keystroke fallback did not deliver. Check Automation (and Accessibility for the fallback) in System Settings, read the per-tab failure reason printed at open time, then retry fresh discovery.
- `cod` / `cc` missing in tabs: run `zsh -lic 'type cod; type cc'` and inspect the shell startup files. Resume commands run in `$SHELL -il -c`, so anything broken in login-shell init breaks resumes.
- Codex warns about a model mismatch on resume: the plan predates model pinning or the transcript had no recorded model. Re-run discovery so the resume command pins the recorded model and effort.
- macOS launch failure: check Automation permission first; Accessibility is needed only for the keystroke fallback. Use `--driver api` to disable that fallback.
- Linux tab request: expect Ghostty CLI windows; it cannot target existing tabs, so `--tabs` is coerced to windows.
- Unwanted helper tabs: set `PFR_STATUS_TAB=0 PFR_AM=0` for the launch.
- Verification must be bypassed only as an explicit degraded mode with `PFR_VERIFY=0`; report that proof is unavailable.

When changing PFR itself, validate with:

```bash
./scripts/run_tests.sh
```

The offline suite checks discovery, clustering, ntm attribution, model pinning, confidence, plans, driver contracts, verification, installer behavior, and an install-then-run e2e through the real launcher. It does not prove live Ghostty behavior; `PFR_LIVE=1 ./scripts/run_tests.sh` adds a real-tab smoke test.
