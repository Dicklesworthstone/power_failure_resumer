# AGENTS.md — power_failure_resumer

## README stays current (mandatory)

When you implement or ship a **user-facing** change (CLI flag, env knob, default behavior, layout file, install path, test entrypoint):

1. **Update `README.md` in the same session** so it matches `./power_failure_resumer.sh --help` and the real tree.
2. **De-slopify** the README after editing (same pass). Follow `de-slopify`:
   - No em dashes; use commas, semicolons, or two sentences.
   - No “Here’s why”, “It’s not X, it’s Y”, “Let’s dive in”, or landing-page filler.
   - Operator-note voice: plain, accurate, short.
3. Prefer expanding existing sections over inventing new marketing headers.
4. If a feature is only half-wired, do not document it as if users can run it yet.

This is ongoing work: beads keep landing, so README drift is expected unless you update it on every close.

## Concurrent agents

Other agents (e.g. Fable) may edit this tree at the same time. Do not stash, revert, or overwrite their work. Re-read files before editing.

## Quality

- Run `./scripts/run_tests.sh` after behavior changes when practical.
- Do not delete files without explicit user permission in this session (see machine-level Agents.md).
