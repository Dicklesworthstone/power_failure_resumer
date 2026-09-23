#!/usr/bin/env bash
# Agent launchers: resume commands use canonical `codex` / `claude` unless the
# login shell defines `cod` / `cc` as an alias or function; a plain `cc`
# executable (the C compiler) never counts. PFR_CODEX_CMD / PFR_CLAUDE_CMD
# override the choice and skip the shell probe; unsafe values are refused.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SD="$(new_state_dir pfr-launchers)"

dry_lines() { grep -E '^  DRY  cd ' <<<"$1" || true; }

# ── no aliases; `cc` resolves to an executable ─────────────────────────────
FAKEBIN="$SD/bin"
mkdir -p "$FAKEBIN"
printf '#!/bin/sh\necho "fake C compiler"\n' > "$FAKEBIN/cc"
chmod +x "$FAKEBIN/cc"
out="$(PATH="$FAKEBIN:$PATH" "$PFR" --dry-run "${FIX_ARGS[@]}" --state-dir "$SD" --no-save-plan 2>&1)" \
  || fail "dry-run without aliases failed: $out"
lines="$(dry_lines "$out")"
[[ -n "$lines" ]] || fail "no DRY lines: $out"
assert_contains "$lines" "&& codex resume " "canonical codex without a cod alias"
assert_contains "$lines" "&& claude --resume " "canonical claude when cc is only an executable"
assert_not_contains "$lines" "&& cod " "no cod without an alias"
assert_not_contains "$lines" "&& cc " "an executable cc is never used as claude"

doc="$(PATH="$FAKEBIN:$PATH" "$PFR" --doctor --state-dir "$SD" 2>&1 || true)"
assert_contains "$doc" "codex: codex (" "doctor reports canonical codex"
assert_contains "$doc" "claude: claude (" "doctor reports canonical claude"

# ── aliases / functions in the login shell are honored ─────────────────────
RC="$SD/rc.bash"
cat > "$RC" <<'EOF'
alias cod='codex --some-flag'
cc() { claude --other-flag "$@"; }
EOF
out="$(PFR_TEST_SHELL_RC="$RC" "$PFR" --dry-run "${FIX_ARGS[@]}" --state-dir "$SD" 2>&1)" \
  || fail "dry-run with aliases failed: $out"
lines="$(dry_lines "$out")"
assert_contains "$lines" "&& cod resume " "cod alias honored"
assert_contains "$lines" "&& cc --resume " "cc function honored"
assert_not_contains "$lines" "&& codex resume" "alias wins over canonical codex"
assert_not_contains "$lines" "&& claude --resume" "function wins over canonical claude"

json="$(PFR_TEST_SHELL_RC="$RC" "$PFR" --json "${FIX_ARGS[@]}" --state-dir "$SD" --no-save-plan 2>/dev/null)" \
  || fail "--json with aliases failed"
words="$(printf '%s' "$json" | python3 -c '
import json, sys
print(" ".join(sorted({s["provider"] + "=" + s["resume_cmd"].split()[0] for s in json.load(sys.stdin)["sessions"]})))')"
assert_eq "$words" "claude=cc codex=cod" "--json resume commands follow the shell"

# A plan saved by the alias run, loaded in a shell without aliases, is rebuilt
# with canonical commands (commands are never replayed from the plan file).
out="$("$PFR" --dry-run --last-plan --state-dir "$SD" --fake-boot "$FAKE_BOOT" 2>&1)" \
  || fail "plan load failed: $out"
lines="$(dry_lines "$out")"
assert_contains "$lines" "&& codex resume " "plan load rebuilds with the current launcher"
assert_not_contains "$lines" "&& cod " "plan load does not replay saved alias commands"

doc="$(PFR_TEST_SHELL_RC="$RC" "$PFR" --doctor --state-dir "$SD" 2>&1 || true)"
assert_contains "$doc" "codex: cod (alias)" "doctor reports the cod alias"
assert_contains "$doc" "claude: cc (function)" "doctor reports the cc function"

# ── explicit overrides skip the probe (a hung shell must not matter) ───────
HANG="$SD/hang.sh"
printf '#!/bin/sh\nsleep 60\n' > "$HANG"
chmod +x "$HANG"
start_ts="$(date +%s)"
out="$(SHELL="$HANG" PFR_CODEX_CMD=/opt/agents/bin/codex PFR_CLAUDE_CMD=claude-beta \
        "$PFR" --dry-run "${FIX_ARGS[@]}" --state-dir "$SD" --no-save-plan 2>&1)" \
  || fail "dry-run with overrides failed: $out"
dur=$(( $(date +%s) - start_ts ))
[[ "$dur" -lt 6 ]] || fail "explicit overrides still probed the login shell (${dur}s)"
lines="$(dry_lines "$out")"
assert_contains "$lines" "&& /opt/agents/bin/codex resume " "PFR_CODEX_CMD path override"
assert_contains "$lines" "&& claude-beta --resume " "PFR_CLAUDE_CMD name override"

# ── unusable shells fall back to canonical commands ────────────────────────
out="$(SHELL="$SD/no-such-shell" "$PFR" --dry-run "${FIX_ARGS[@]}" --state-dir "$SD" --no-save-plan 2>&1)" \
  || fail "dry-run with a missing shell failed: $out"
lines="$(dry_lines "$out")"
assert_contains "$lines" "&& codex resume " "missing shell → canonical codex"
assert_contains "$lines" "&& claude --resume " "missing shell → canonical claude"

# ── unsafe overrides are refused before anything is listed or opened ───────
# shellcheck disable=SC2088,SC2016  # literal, unexpanded values are the point
for bad in 'cod; touch /tmp/pfr-pwned' 'claude --yolo' '$(id)' '~/bin/cc' 'rel/cc'; do
  if out="$(PFR_CLAUDE_CMD="$bad" "$PFR" --dry-run "${FIX_ARGS[@]}" --state-dir "$SD" --no-save-plan 2>&1)"; then
    fail "unsafe PFR_CLAUDE_CMD accepted: $bad"
  fi
  assert_contains "$out" "PFR_CLAUDE_CMD must be a plain command name or absolute path" "refusal message for $bad"
  assert_not_contains "$out" "DRY  cd" "nothing listed for $bad"
done

echo "agent launchers OK"
