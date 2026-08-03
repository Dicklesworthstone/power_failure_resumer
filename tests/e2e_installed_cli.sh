#!/usr/bin/env bash
# E2E (no mocks): install with the REAL installer via a stdin pipe (the
# curl|bash entry path), then drive the INSTALLED product exactly as a user
# does — bare `pfr` on PATH, through the launcher symlink, from an unrelated
# cwd, in an isolated HOME. This is the suite that would have caught pfr-s9e,
# where the checkout script worked but every installed copy was dead on
# arrival because ROOT resolved to the symlink's directory.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK="$(new_state_dir pfr-e2e-installed)"
E2E_HOME="$WORK/home"
PREFIX="$E2E_HOME/.local/share/pfr"
BIN="$E2E_HOME/.local/bin"
SD="$WORK/state"
ELSEWHERE="$WORK/elsewhere"
mkdir -p "$E2E_HOME" "$ELSEWHERE" "$SD"

log_phase() {
  printf '{"suite":"e2e_installed_cli","event":"phase","phase":"%s","ts":%s}\n' \
    "$1" "$(date +%s)" >&2
}

# ── production-safety guard ─────────────────────────────────────────────────
# Nothing in this suite may touch the real HOME or a real state dir. Fail
# closed before installing anything if the isolation assumptions ever break.
case "$WORK" in
  "$PFR_ROOT"/tests/logs/*) ;;
  *) fail "guard: work dir escaped tests/logs: $WORK" ;;
esac
[[ "$E2E_HOME" != "$HOME" && "$E2E_HOME" == "$WORK"/* ]] \
  || fail "guard: refusing to run against real HOME"
[[ "$SD" == "$WORK"/* ]] || fail "guard: state dir outside isolated tree"

# ── provision: package the working tree like a release archive ──────────────
log_phase provision
ARCHIVE_ROOT="$WORK/archive"
PACKAGE="$ARCHIVE_ROOT/pfr-source"
mkdir -p "$PACKAGE"
cp -R "$PFR_ROOT/power_failure_resumer.sh" "$PFR_ROOT/lib" "$PFR_ROOT/docs" "$PACKAGE/"
[[ -d "$PFR_ROOT/skills" ]] && cp -R "$PFR_ROOT/skills" "$PACKAGE/"
tar -czf "$WORK/pfr.tar.gz" -C "$ARCHIVE_ROOT" pfr-source

# ── install: the script arrives on stdin, exactly like curl|bash ────────────
log_phase install
install_out="$(
  HOME="$E2E_HOME" PFR_INSTALLER_KEEP_TEMPS=1 \
  PFR_INSTALL_LOCK_DIR="$WORK/lock-install" \
  bash -s -- --offline "$WORK/pfr.tar.gz" --prefix "$PREFIX" --bin-dir "$BIN" \
    --no-gum --no-install-skill < "$PFR_ROOT/install.sh" 2>&1
)" || fail "stdin-piped install failed: $install_out"
[[ -L "$BIN/pfr" ]] || fail "launcher symlink missing after install"

# All product invocations below go through the launcher as a bare command on
# PATH, from a directory unrelated to both the checkout and the install.
run_pfr() {
  ( cd "$ELSEWHERE" && \
    HOME="$E2E_HOME" PATH="$BIN:$PATH" pfr "$@" )
}

# ── doctor through the installed launcher ───────────────────────────────────
log_phase doctor
out="$(run_pfr --doctor --state-dir "$SD" 2>&1)" \
  || fail "installed pfr --doctor unhealthy: $out"
assert_contains "$out" "doctor: healthy" "installed doctor healthy"
assert_contains "$out" "lib_files" "doctor checked libs of the installed tree"

json="$(run_pfr --doctor --json --state-dir "$SD" 2>/dev/null)" \
  || fail "installed pfr --doctor --json failed"
healthy="$(printf '%s' "$json" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["healthy"])')" \
  || fail "installed doctor --json invalid: $json"
assert_eq "$healthy" "True" "installed doctor --json healthy"

# ── discovery through the installed launcher ────────────────────────────────
log_phase discovery
out="$(run_pfr --dry-run "${FIX_ARGS[@]}" --state-dir "$SD" 2>&1)" \
  || fail "installed dry-run failed: $out"
assert_contains "$out" "cluster mode:  pre_boot" "installed dry-run mode"
assert_contains "$out" "matched:       5 session(s)" "installed dry-run count"
assert_contains "$out" "confidence:    high" "installed dry-run confidence"
[[ -f "$SD/last-plan.json" ]] || fail "installed dry-run did not save a plan"

json="$(run_pfr --json "${FIX_ARGS[@]}" --state-dir "$SD" --no-save-plan 2>/dev/null)" \
  || fail "installed --json failed"
mode="$(printf '%s' "$json" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["mode"])')" \
  || fail "installed --json output invalid: $json"
assert_eq "$mode" "pre_boot" "installed --json mode"

# ── plan roundtrip through the installed launcher ───────────────────────────
log_phase plan_roundtrip
ids_of() { grep -oE '(cod resume|cc --resume) [0-9a-f-]+' <<<"$1" | awk '{print $NF}' | sort; }
out1="$(run_pfr --dry-run "${FIX_ARGS[@]}" --state-dir "$SD" 2>&1)" \
  || fail "installed discovery for plan failed"
out2="$(run_pfr --dry-run --last-plan --state-dir "$SD" --fake-boot "$FAKE_BOOT" 2>&1)" \
  || fail "installed --last-plan failed: $out2"
ids1="$(ids_of "$out1")"
[[ -n "$ids1" ]] || fail "no session ids from installed discovery"
assert_eq "$(ids_of "$out2")" "$ids1" "installed plan reopens identical set"

# ── upgrade: new tree must be live through the same launcher ────────────────
log_phase upgrade
ARCHIVE_TWO="$WORK/archive-two"
PACKAGE_TWO="$ARCHIVE_TWO/pfr-source"
mkdir -p "$PACKAGE_TWO"
cp -R "$PACKAGE"/. "$PACKAGE_TWO/"
printf '\n# installed-cli e2e upgrade marker\n' >> "$PACKAGE_TWO/lib/confidence.py"
tar -czf "$WORK/pfr-two.tar.gz" -C "$ARCHIVE_TWO" pfr-source
upgrade_out="$(
  HOME="$E2E_HOME" PFR_INSTALLER_KEEP_TEMPS=1 \
  PFR_INSTALL_LOCK_DIR="$WORK/lock-upgrade" \
  bash -s -- --offline "$WORK/pfr-two.tar.gz" --prefix "$PREFIX" --bin-dir "$BIN" \
    --no-gum --no-install-skill < "$PFR_ROOT/install.sh" 2>&1
)" || fail "upgrade install failed: $upgrade_out"
assert_contains "$upgrade_out" "updated" "upgrade detected changed tree"
assert_contains "$(<"$PREFIX/lib/confidence.py")" "upgrade marker" "new tree activated"
out="$(run_pfr --dry-run "${FIX_ARGS[@]}" --state-dir "$SD" 2>&1)" \
  || fail "installed dry-run broken after upgrade: $out"
assert_contains "$out" "matched:       5 session(s)" "post-upgrade dry-run"

log_phase "done"
echo "e2e_installed_cli OK"
