# Changelog

**Scope:** full project history, from inception (2026-08-03) to HEAD.
**Methodology:** reconstructed from the git commit history and the checked-in
beads tracker (`.beads/issues.jsonl` — 16 closed workstreams, ~31 still open).
The project began as an untracked working directory; pre-git work (the original
discovery script, AppleScript drivers, and a hardening review pass) landed in
the initial import commit. No tags or GitHub Releases exist yet.

## Version timeline

| Version | Date | Status | Summary |
|---------|------|--------|---------|
| Unreleased (`main`) | 2026-08-03 | in development | Initial public form: discovery + clustering, confidence-scored plans, verified opens, doctor, installer, offline test suite, Linux support |

## Capability waves

### 1. Crash-cluster discovery and Ghostty resume (initial import)

The core idea landed first: after a hard power cut, every mid-write session
file stops updating at nearly the same moment, just before `kern.boottime`.
`lib/discover.py` scans Codex (`rollout-*.jsonl`) and Claude Code
(`<uuid>.jsonl`) session files, isolates that pre-boot mtime pocket
(densest-window with tie-break toward newest), and the shell CLI reopens each
victim in Ghostty — macOS AppleScript drivers (`ui` with keystroke fallback,
scripting-only `api`) or, added in the same wave, a Linux `ghostty` CLI driver
with per-platform defaults and portable `ps` syntax. This import also carried
the pre-git hardening review: tight `resume <uuid>` adjacency matching for
already-running detection (workstream `pfr-skip-running-aen`), filename-UUID
resume ids that survive torn first lines, subagent filtering, and the lossy
Claude directory-decode fallback that only trusts paths that exist.

- Delivered: discovery, clustering, three open drivers, already-running skip, title extraction groundwork
- Closed workstreams: `pfr-skip-running-aen`
- Representative commits: `14ed7f0` (initial import), `9e63161` (fixture-isolation flags)

### 2. Test infrastructure (fixtures with real mtimes)

Because clustering is a pure function of file mtimes — which git cannot store —
fixtures are *generated* on every run from a fake boot epoch
(`tests/fixtures/make_fixtures.py`), covering a crash pocket, a subagent, an
already-resumed session, idle outliers, and a post-boot session. A
NDJSON-logging runner (`scripts/run_tests.sh`) executes shell, python, and e2e
suites fully offline; `--codex-root/--claude-root/--fake-boot/--ps-file/
--state-dir` isolate everything from the live `~/.codex` / `~/.claude`.

- Delivered: run_tests.sh runner, generated fixtures, 15-case clustering suite, e2e dry-run/plan/skip scripts
- Closed workstreams: `pfr-test-scaffold-jfl`, `pfr-test-cluster-lhm`, `pfr-test-e2e-dry-zfi`, `pfr-discover-cli-roots-2k6`, `pfr-test-verify-7hr`, `pfr-test-doctor-6kv`
- Representative commits: `442d1f0`, `9dd09e6`, `3ec904d`

### 3. Plans + crash confidence (discover once, open later)

Discovery now freezes its decision into a schema-v1 plan
(`~/.local/state/pfr/last-plan.json`, atomic 0600 writes with directory fsync,
archived and pruned). A pure scoring module (`lib/confidence.py`) grades the
cluster `high`/`medium`/`low` with explicit reasons — only a tight pre-boot
pocket of ≥3 sessions earns `high`; density-only pockets never do, so a busy
afternoon can't impersonate a blackout. Loading a plan from a different boot or
older than 24h is refused unless `--force-stale-plan`. Confidence is scored on
the full pocket before `--limit` truncation (a bug caught and fixed in-wave).

- Delivered: `--plan` / `--last-plan` / `--save-plan` / `--no-save-plan`, staleness refusal, structural plan validation, golden-fixture rubric tests
- Closed workstreams: `pfr-plan-schema-l81`, `pfr-plan-cli-7pj`, `pfr-plan-tests-n79`, `pfr-plan-confidence-w62`
- Representative commits: `5c080dd`, `26befae`

### 4. Verified opens, doctor, and tab choreography

Opening became observable and honest. Every resume attempt is recorded and then
verified: `lib/verify.py` polls `ps` for the session UUID next to a resume flag
and writes `last-report.json`; unverified or failed opens exit non-zero.
`pfr --doctor` (human + `--json`) checks python, libs, state dir, Ghostty, and
per-platform scripting hooks, with `PFR_DOCTOR_SIM_MISSING` for tests. Tab
order gained intent: a live status tab tailing the gum-styled run log opens
first, the agent-mail (`am`) tab second, hub-directory sessions (`~/projects`,
`/data/projects`, `/dp`) next, everything else newest-first.

- Delivered: post-open verification + report, doctor subcommand, status/am/hub tab ordering, per-session titles and first-user-message previews in listings and plans
- Closed workstreams: `pfr-open-verify-3dd`, `pfr-verify-opens-6ld`, `pfr-doctor-cmd-on2`, `pfr-extract-titles-akt`
- Representative commits: `4c9f9e8`, `cb6c4f4`, `96d175d`

### 5. Distribution

A curl-pipe installer in the installer-workmanship style: gum+ANSI output
stack, preflight checks, proxy support, mkdir-based locking with stale-PID
cleanup, offline tarball mode, content-hash up-to-date short-circuit, staged
atomic tree swap into `~/.local/share/pfr`, `--easy-mode` PATH setup, and a
`--verify` hook that runs the doctor. README rebuilt around the install
one-liner; MIT license added.

- Delivered: `install.sh`, README/LICENSE/CHANGELOG, `docs/session-formats.md` (Codex/Claude on-disk format notes, casr-derived, dependency-free)
- Closed workstreams: `pfr-install-script-9b6`
- Representative commits: `234e3b5`

## Notes for agents

- The tracker of record is `.beads/issues.jsonl` (beads/`br`); ~31 workstreams
  remain open (batching, adaptive settle, audit trail, config file, post-boot
  notify/LaunchAgent, list UX, perf, live-Ghostty smoke tests, docs).
- Invariants that must not regress are encoded in the offline suite
  (`./scripts/run_tests.sh`): cluster-then-filter-running order, filename-UUID
  resume ids, never-HIGH-for-density, full-pocket confidence before `--limit`,
  resume-flag-adjacent `ps` matching, and plan staleness refusal.
- Commit hashes above are local-history references; the repo had no remote
  before first publication, so no live commit URLs predate it.
