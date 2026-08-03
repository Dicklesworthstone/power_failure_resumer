---
name: pfr
description: Safely resumes local Codex and Claude sessions in Ghostty with pfr. Use when restoring agent tabs after a reboot or power loss, reviewing saved plans, or diagnosing resume verification.
---

# PFR

Use `pfr` as a recovery pipeline: discover local session logs, review the likely pre-boot cluster, open a frozen plan in Ghostty, then verify the exact resume UUIDs in running processes.

## Default recovery loop

```bash
pfr --doctor
pfr --dry-run
pfr --last-plan --pick
python3 -m json.tool ~/.local/state/pfr/last-report.json
```

Run `./power_failure_resumer.sh` instead of `pfr` from an uninstalled checkout.

1. Run `--doctor` when setup, shell commands, Ghostty permissions, or platform support may be wrong. Treat critical failures as launch blockers.
2. Run `--dry-run` and inspect the mode, confidence, reasons, working directory, title, and preview. This deliberately saves the reviewed set as `last-plan.json`.
3. Open that exact plan with `--last-plan --pick`. Use `--last-plan -y` only when every listed session is intended.
4. Treat a nonzero exit or an unverified entry in `last-report.json` as a failed recovery. Process verification proves only that the exact UUID appears in process arguments—not that the agent or model is healthy.

For machine-readable inspection without changing saved-plan state:

```bash
pfr --json --no-save-plan
```

## Choose safely

| Situation | Action |
|---|---|
| Correct `pre_boot` cluster with HIGH confidence | Open the saved plan; still review the list first |
| MEDIUM, LOW, `density`, or `recent` result | Narrow the set or use `--pick`; confidence is not crash proof |
| Too many sessions | Add `--providers codex` or `--providers claude`, `--projects-only`, or a smaller `--window` |
| No plausible cluster | Inspect a manual fallback with `pfr --mode recent --lookback-hours 6 --window 3600 --pick` |
| Partial launch or verification failure | Inspect the report and tabs, then run fresh discovery with `pfr --pick`; increase `--settle` if shells are not ready |
| Everything is already running | Accept the default skip behavior; use `--force-reopen` only to create intentional duplicates |

Fresh discovery is important after a partial launch: it skips exact UUIDs that are now running. Loading `--last-plan` freezes the old set and does not repeat live-session filtering, so never reopen an old plan wholesale as a retry.

## Guardrails

- Never make `pfr -y` the first recovery command. Review before opening.
- Never treat density-only or recent-mode results as authoritative; only pre-boot evidence can score HIGH.
- Avoid `--force-stale-plan`; prefer rediscovery. Use it only after confirming the boot identity and every session in the plan.
- Avoid `--force-reopen` unless duplicate sessions are explicitly desired.
- Never execute a serialized plan's `resume_cmd`. PFR treats it as informational and reconstructs commands from the provider, UUID, and absolute working directory.
- Keep recovery local. PFR restores local Codex and Claude sessions; it does not infer remote SSH, tmux, Cursor, or model health.

## Diagnose failures

- Bare shell or missing command: run `zsh -lic 'type cod; type cc'`, inspect the Ghostty shell startup files, and retry fresh discovery with a larger `--settle`.
- macOS launch failure: check Automation permission first; Accessibility is needed only for the keystroke fallback. Use `--driver api` to disable that fallback.
- Linux tab request: expect Ghostty CLI windows; it cannot target existing tabs, so `--tabs` is coerced to windows.
- Unwanted helper tabs: set `PFR_STATUS_TAB=0 PFR_AM=0` for the launch.
- Verification must be bypassed only as an explicit degraded mode with `PFR_VERIFY=0`; report that proof is unavailable.

When changing PFR itself, validate with:

```bash
./scripts/run_tests.sh
```

The offline suite checks discovery, clustering, confidence, plans, drivers, verification, installer behavior, and end-to-end recovery fixtures. It does not prove live Ghostty behavior.
