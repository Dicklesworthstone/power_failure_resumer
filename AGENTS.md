# AGENTS.md — power_failure_resumer

## README stays current + de-slopify (mandatory)

Beads and features keep landing. Treat README drift as a defect.

When you implement or ship a **user-facing** change (CLI flag, env knob, default behavior, tab order, install path, plan/report path, test entrypoint):

1. **Update `README.md` in the same session** so it matches:
   - `./power_failure_resumer.sh --help`
   - Real env vars used in the shell (`PFR_*`)
   - The real tree under `lib/`, `tests/`, `scripts/`, `docs/`, `install.sh`
2. **De-slopify in the same pass** (skill: `de-slopify`):
   - No em dashes; use commas, semicolons, or two sentences.
   - No “Here’s why”, “It’s not X, it’s Y”, “Let’s dive in”, hero taglines, or badge theater.
   - No fake comparison tables full of emoji.
   - Operator-note voice: plain, accurate, short.
3. Prefer expanding existing sections over new marketing headers.
4. Do not document half-wired features as ready.
5. After a peer agent (e.g. Fable) ships something, re-read README vs `--help` before you leave the session.

Checklist when closing a user-facing bead:

```
[ ] Flag/env/default in README tables
[ ] Layout / tests / install paths if files moved
[ ] Troubleshooting row if failure mode is new
[ ] De-slopify pass on every prose line you touched
```

## Concurrent agents

Other agents may edit this tree at the same time. Do not stash, revert, or overwrite their work. Re-read files before editing.

## Quality

- Run `./scripts/run_tests.sh` after behavior changes when practical.
- Do not delete files without explicit user permission in this session (machine-level Agents.md).
