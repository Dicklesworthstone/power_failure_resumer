#!/usr/bin/env bash
# Installer: safe option parsing, offline archive validation, full-tree upgrade
# detection, required-file installation, and collision refusal.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK="$(new_state_dir pfr-install)"
ARCHIVE_ROOT="$WORK/archive"
PACKAGE="$ARCHIVE_ROOT/pfr-source"
TEST_HOME="$WORK/home"
PREFIX="$TEST_HOME/share/pfr"
BIN_ONE="$TEST_HOME/bin-one"
BIN_TWO="$TEST_HOME/bin-two"
BIN_THREE="$TEST_HOME/bin-three"
mkdir -p "$PACKAGE" "$TEST_HOME" "$BIN_ONE" "$BIN_TWO" "$BIN_THREE"
cp -R "$PFR_ROOT/power_failure_resumer.sh" "$PFR_ROOT/lib" "$PACKAGE/"
cp -R "$PFR_ROOT/docs" "$PACKAGE/"
[[ -d "$PFR_ROOT/skills" ]] && cp -R "$PFR_ROOT/skills" "$PACKAGE/"
tar -czf "$WORK/pfr-one.tar.gz" -C "$ARCHIVE_ROOT" pfr-source

help_out="$(bash "$PFR_ROOT/install.sh" --help 2>&1)" || fail "installer --help failed"
assert_contains "$help_out" "Usage: install.sh" "pipe-safe help text"

if bash "$PFR_ROOT/install.sh" --prefix >"$WORK/missing-value.log" 2>&1; then
  fail "missing --prefix value must fail"
fi
assert_contains "$(<"$WORK/missing-value.log")" "--prefix requires a value" "missing value error"

install_out="$(
  HOME="$TEST_HOME" PFR_INSTALLER_KEEP_TEMPS=1 \
  PFR_INSTALL_LOCK_DIR="$WORK/lock-first" \
  bash "$PFR_ROOT/install.sh" --offline "$WORK/pfr-one.tar.gz" \
    --prefix "$PREFIX" --bin-dir "$BIN_ONE" --no-gum 2>&1
)" || fail "offline install failed: $install_out"
[[ -x "$PREFIX/power_failure_resumer.sh" ]] || fail "CLI was not installed"
[[ -f "$PREFIX/lib/open_sessions.applescript" ]] || fail "AppleScript driver was not installed"
[[ -f "$PREFIX/lib/verify.py" ]] || fail "verification library was not installed"
[[ -L "$BIN_ONE/pfr" ]] || fail "pfr launcher is not a symlink"
assert_eq "$(readlink "$BIN_ONE/pfr")" "$PREFIX/power_failure_resumer.sh" "launcher target"

same_out="$(
  HOME="$TEST_HOME" PFR_INSTALLER_KEEP_TEMPS=1 \
  PFR_INSTALL_LOCK_DIR="$WORK/lock-same" \
  bash "$PFR_ROOT/install.sh" --offline "$WORK/pfr-one.tar.gz" \
    --prefix "$PREFIX" --bin-dir "$BIN_ONE" --no-gum 2>&1
)" || fail "idempotent reinstall failed: $same_out"
assert_contains "$same_out" "already up to date" "unchanged tree short-circuit"

# Gum output path: every other test runs --no-gum or without a tty, which is
# exactly how the "-> text parsed as a gum flag" regression shipped. Force the
# styled path (no tty needed) whenever gum is installed.
if command -v gum >/dev/null 2>&1; then
  GUM_HOME="$WORK/gum-home"
  mkdir -p "$GUM_HOME"
  gum_out="$(
    HOME="$GUM_HOME" PFR_INSTALLER_KEEP_TEMPS=1 PFR_INSTALLER_FORCE_GUM=1 \
    PFR_INSTALL_LOCK_DIR="$WORK/lock-gum" \
    bash "$PFR_ROOT/install.sh" --offline "$WORK/pfr-one.tar.gz" \
      --prefix "$GUM_HOME/share/pfr" --bin-dir "$GUM_HOME/bin" 2>&1
  )" || fail "gum-path install failed: $gum_out"
  assert_not_contains "$gum_out" "unknown flag" "gum text terminated with --"
  [[ -x "$GUM_HOME/share/pfr/power_failure_resumer.sh" ]] || fail "gum-path install incomplete"
fi

# Agent skill: never installed by default; --install-skill copies it into
# detected agent dirs only; unrelated destination paths are refused.
if [[ -f "$PREFIX/skills/pfr/SKILL.md" ]]; then
  mkdir -p "$TEST_HOME/.claude" "$TEST_HOME/.codex/skills/pfr"
  printf 'not a skill\n' > "$TEST_HOME/.codex/skills/pfr/occupied.txt"
  [[ ! -e "$TEST_HOME/.claude/skills/pfr" ]] || fail "skill installed without --install-skill"
  skill_out="$(
    HOME="$TEST_HOME" PFR_INSTALLER_KEEP_TEMPS=1 \
    PFR_INSTALL_LOCK_DIR="$WORK/lock-skill" \
    bash "$PFR_ROOT/install.sh" --offline "$WORK/pfr-one.tar.gz" \
      --prefix "$PREFIX" --bin-dir "$BIN_ONE" --no-gum --install-skill 2>&1
  )" || fail "--install-skill run failed: $skill_out"
  [[ -f "$TEST_HOME/.claude/skills/pfr/SKILL.md" ]] || fail "skill missing from ~/.claude"
  assert_contains "$skill_out" "refusing to replace unrelated path" "unrelated skill dir refused"
  assert_eq "$(<"$TEST_HOME/.codex/skills/pfr/occupied.txt")" "not a skill" "unrelated dir untouched"
fi

repair_out="$(
  HOME="$TEST_HOME" PFR_INSTALLER_KEEP_TEMPS=1 \
  PFR_INSTALL_LOCK_DIR="$WORK/lock-repair" \
  bash "$PFR_ROOT/install.sh" --offline "$WORK/pfr-one.tar.gz" \
    --prefix "$PREFIX" --bin-dir "$BIN_THREE" --no-gum 2>&1
)" || fail "launcher repair failed: $repair_out"
assert_contains "$repair_out" "already up to date" "repair kept no-op tree"
[[ -L "$BIN_THREE/pfr" ]] || fail "unchanged install did not repair launcher"

# Change only a library file. A CLI-only hash would miss this upgrade.
ARCHIVE_ROOT_TWO="$WORK/archive-two"
PACKAGE_TWO="$ARCHIVE_ROOT_TWO/pfr-source"
mkdir -p "$PACKAGE_TWO"
cp -R "$PFR_ROOT/power_failure_resumer.sh" "$PFR_ROOT/lib" "$PACKAGE_TWO/"
cp -R "$PFR_ROOT/docs" "$PACKAGE_TWO/"
printf '\n# installer full-tree hash regression marker\n' >> "$PACKAGE_TWO/lib/confidence.py"
tar -czf "$WORK/pfr-two.tar.gz" -C "$ARCHIVE_ROOT_TWO" pfr-source
changed_out="$(
  HOME="$TEST_HOME" PFR_INSTALLER_KEEP_TEMPS=1 \
  PFR_INSTALL_LOCK_DIR="$WORK/lock-changed" \
  bash "$PFR_ROOT/install.sh" --offline "$WORK/pfr-two.tar.gz" \
    --prefix "$PREFIX" --bin-dir "$BIN_TWO" --no-gum 2>&1
)" || fail "library-only upgrade failed: $changed_out"
assert_contains "$changed_out" "updated" "library-only change detected"
assert_contains "$(<"$PREFIX/lib/confidence.py")" "full-tree hash regression marker" "new library activated"

# Runtime bytecode caches in a used install (lib/__pycache__/*.pyc) must not
# defeat the up-to-date check by perturbing the tree hash.
mkdir -p "$PREFIX/lib/__pycache__"
printf 'bytecode junk\n' > "$PREFIX/lib/__pycache__/regression.cpython-999.pyc"
pyc_out="$(
  HOME="$TEST_HOME" PFR_INSTALLER_KEEP_TEMPS=1 \
  PFR_INSTALL_LOCK_DIR="$WORK/lock-pyc" \
  bash "$PFR_ROOT/install.sh" --offline "$WORK/pfr-two.tar.gz" \
    --prefix "$PREFIX" --bin-dir "$BIN_TWO" --no-gum 2>&1
)" || fail "pycache-noop install failed: $pyc_out"
assert_contains "$pyc_out" "already up to date" "bytecode caches ignored by tree hash"

# Existing unrelated launcher paths and unsafe archives must fail closed.
COLLISION_HOME="$WORK/collision-home"
mkdir -p "$COLLISION_HOME/bin"
printf 'owned by somebody else\n' > "$COLLISION_HOME/bin/pfr"
if HOME="$COLLISION_HOME" PFR_INSTALLER_KEEP_TEMPS=1 \
   PFR_INSTALL_LOCK_DIR="$WORK/lock-collision" \
   bash "$PFR_ROOT/install.sh" --offline "$WORK/pfr-one.tar.gz" \
     --prefix "$COLLISION_HOME/share/pfr" --bin-dir "$COLLISION_HOME/bin" \
     --no-gum >"$WORK/collision.log" 2>&1; then
  fail "installer replaced an unrelated launcher"
fi
assert_eq "$(<"$COLLISION_HOME/bin/pfr")" "owned by somebody else" "collision preserved"

MARKER_HOME="$WORK/marker-home"
mkdir -p "$MARKER_HOME/share/pfr" "$MARKER_HOME/bin"
printf 'another/project\n' > "$MARKER_HOME/share/pfr/.pfr-install"
if HOME="$MARKER_HOME" PFR_INSTALLER_KEEP_TEMPS=1 \
   PFR_INSTALL_LOCK_DIR="$WORK/lock-marker" \
   bash "$PFR_ROOT/install.sh" --offline "$WORK/pfr-one.tar.gz" \
     --prefix "$MARKER_HOME/share/pfr" --bin-dir "$MARKER_HOME/bin" \
     --no-gum >"$WORK/marker.log" 2>&1; then
  fail "installer trusted an unrelated ownership marker"
fi
assert_contains "$(<"$WORK/marker.log")" "unrecognized ownership marker" "marker identity"

python3 - "$WORK/unsafe.tar.gz" <<'PY'
import io
import tarfile
import sys

with tarfile.open(sys.argv[1], "w:gz") as archive:
    member = tarfile.TarInfo("../escape")
    payload = b"unsafe\n"
    member.size = len(payload)
    archive.addfile(member, io.BytesIO(payload))
PY
if HOME="$TEST_HOME" PFR_INSTALLER_KEEP_TEMPS=1 \
   PFR_INSTALL_LOCK_DIR="$WORK/lock-unsafe" \
   bash "$PFR_ROOT/install.sh" --offline "$WORK/unsafe.tar.gz" \
     --prefix "$WORK/unsafe-prefix" --bin-dir "$WORK/unsafe-bin" \
     --no-gum >"$WORK/unsafe.log" 2>&1; then
  fail "unsafe archive member was accepted"
fi
assert_contains "$(<"$WORK/unsafe.log")" "archive validation or extraction failed" "unsafe archive rejection"

VERIFY_ROOT="$WORK/verify-archive"
VERIFY_PACKAGE="$VERIFY_ROOT/pfr-source"
VERIFY_HOME="$WORK/verify-home"
mkdir -p "$VERIFY_PACKAGE" "$VERIFY_HOME/bin"
cp -R "$PFR_ROOT/lib" "$VERIFY_PACKAGE/"
cp -R "$PFR_ROOT/docs" "$VERIFY_PACKAGE/"
printf '%s\n' '#!/usr/bin/env bash' '[[ "${1:-}" == "--doctor" ]] && exit 7' \
  'exit 0' > "$VERIFY_PACKAGE/power_failure_resumer.sh"
tar -czf "$WORK/verify.tar.gz" -C "$VERIFY_ROOT" pfr-source
if HOME="$VERIFY_HOME" PFR_INSTALLER_KEEP_TEMPS=1 \
   PFR_INSTALL_LOCK_DIR="$WORK/lock-verify" \
   bash "$PFR_ROOT/install.sh" --offline "$WORK/verify.tar.gz" \
     --prefix "$VERIFY_HOME/share/pfr" --bin-dir "$VERIFY_HOME/bin" \
     --verify --no-gum >"$WORK/verify.log" 2>&1; then
  fail "--verify succeeded after doctor failure"
fi
assert_contains "$(<"$WORK/verify.log")" "post-install doctor failed" "strict verification"

# ── legacy launcher migration (issue #1) ────────────────────────────────────
# An older install left a *copy* of the launcher at $BIN_DIR/pfr instead of the
# managed symlink. Build that shape by hand (no installer run, so nothing has to
# be deleted) and prove the reinstall migrates it, keeps the previous file, and
# still fails closed for everything that is not provably ours.

make_legacy_install() {
  # make_legacy_install <home> [launcher-source]
  local home="$1" launcher_src="${2:-$PFR_ROOT/power_failure_resumer.sh}"
  mkdir -p "$home/share/pfr" "$home/bin"
  cp -R "$PFR_ROOT/lib" "$home/share/pfr/"
  cp "$launcher_src" "$home/share/pfr/power_failure_resumer.sh"
  chmod 0755 "$home/share/pfr/power_failure_resumer.sh"
  printf 'Dicklesworthstone/power_failure_resumer\n' > "$home/share/pfr/.pfr-install"
  # The legacy layout: a regular file, byte-identical to the canonical launcher.
  cp "$home/share/pfr/power_failure_resumer.sh" "$home/bin/pfr"
  chmod 0755 "$home/bin/pfr"
}

sha_of() { python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

LEGACY_HOME="$WORK/legacy-home"
make_legacy_install "$LEGACY_HOME"
LEGACY_SHA="$(sha_of "$LEGACY_HOME/bin/pfr")"
assert_eq "$LEGACY_SHA" "$(sha_of "$LEGACY_HOME/share/pfr/power_failure_resumer.sh")" "legacy fixture is byte-identical"
[[ ! -L "$LEGACY_HOME/bin/pfr" ]] || fail "legacy fixture must be a regular file"

legacy_out="$(
  HOME="$LEGACY_HOME" PFR_INSTALLER_KEEP_TEMPS=1 \
  PFR_INSTALL_LOCK_DIR="$WORK/lock-legacy" \
  bash "$PFR_ROOT/install.sh" --offline "$WORK/pfr-two.tar.gz" \
    --prefix "$LEGACY_HOME/share/pfr" --bin-dir "$LEGACY_HOME/bin" --no-gum 2>&1
)" || fail "legacy launcher migration failed: $legacy_out"
assert_contains "$legacy_out" "byte-identical copy" "migration announced at preflight"
assert_contains "$legacy_out" "migrated legacy launcher copy" "migration reported"
[[ -L "$LEGACY_HOME/bin/pfr" ]] || fail "legacy launcher was not replaced by a symlink"
assert_eq "$(readlink "$LEGACY_HOME/bin/pfr")" "$LEGACY_HOME/share/pfr/power_failure_resumer.sh" "migrated launcher target"

LEGACY_BACKUPS=("$LEGACY_HOME"/bin/pfr.pfr-legacy.*)
[[ -f "${LEGACY_BACKUPS[0]}" ]] || fail "legacy launcher backup was not preserved"
assert_eq "${#LEGACY_BACKUPS[@]}" "1" "exactly one legacy backup"
assert_eq "$(sha_of "${LEGACY_BACKUPS[0]}")" "$LEGACY_SHA" "backup is byte-identical to the migrated file"
assert_contains "$legacy_out" "${LEGACY_BACKUPS[0]}" "backup path reported to the operator"

# Migration happens once: the managed symlink is already correct on the next run.
legacy_again="$(
  HOME="$LEGACY_HOME" PFR_INSTALLER_KEEP_TEMPS=1 \
  PFR_INSTALL_LOCK_DIR="$WORK/lock-legacy-again" \
  bash "$PFR_ROOT/install.sh" --offline "$WORK/pfr-two.tar.gz" \
    --prefix "$LEGACY_HOME/share/pfr" --bin-dir "$LEGACY_HOME/bin" --no-gum 2>&1
)" || fail "post-migration reinstall failed: $legacy_again"
assert_not_contains "$legacy_again" "migrated legacy launcher copy" "migration is not repeated"
LEGACY_BACKUPS_AFTER=("$LEGACY_HOME"/bin/pfr.pfr-legacy.*)
assert_eq "${#LEGACY_BACKUPS_AFTER[@]}" "1" "no second backup created"

# The same migration must work on the unchanged-tree path, which reaches
# ensure_launcher without ever swapping the install root.
UPTODATE_HOME="$WORK/legacy-uptodate-home"
make_legacy_install "$UPTODATE_HOME" "$PACKAGE/power_failure_resumer.sh"
cp -R "$PACKAGE/docs" "$UPTODATE_HOME/share/pfr/" 2>/dev/null || true
[[ -d "$PACKAGE/skills" ]] && cp -R "$PACKAGE/skills" "$UPTODATE_HOME/share/pfr/"
uptodate_out="$(
  HOME="$UPTODATE_HOME" PFR_INSTALLER_KEEP_TEMPS=1 \
  PFR_INSTALL_LOCK_DIR="$WORK/lock-legacy-uptodate" \
  bash "$PFR_ROOT/install.sh" --offline "$WORK/pfr-one.tar.gz" \
    --prefix "$UPTODATE_HOME/share/pfr" --bin-dir "$UPTODATE_HOME/bin" \
    --no-gum --no-install-skill 2>&1
)" || fail "unchanged-tree legacy migration failed: $uptodate_out"
assert_contains "$uptodate_out" "already up to date" "unchanged tree short-circuit kept"
[[ -L "$UPTODATE_HOME/bin/pfr" ]] || fail "unchanged-tree run did not migrate the legacy launcher"

# Fail closed: a regular file that is NOT byte-identical is still unrelated.
DRIFT_HOME="$WORK/legacy-drift-home"
make_legacy_install "$DRIFT_HOME"
printf '\n# local edit\n' >> "$DRIFT_HOME/bin/pfr"
DRIFT_SHA="$(sha_of "$DRIFT_HOME/bin/pfr")"
if HOME="$DRIFT_HOME" PFR_INSTALLER_KEEP_TEMPS=1 \
   PFR_INSTALL_LOCK_DIR="$WORK/lock-legacy-drift" \
   bash "$PFR_ROOT/install.sh" --offline "$WORK/pfr-two.tar.gz" \
     --prefix "$DRIFT_HOME/share/pfr" --bin-dir "$DRIFT_HOME/bin" \
     --no-gum >"$WORK/legacy-drift.log" 2>&1; then
  fail "installer migrated a launcher that was not byte-identical"
fi
assert_contains "$(<"$WORK/legacy-drift.log")" "refusing to replace unrelated path" "drifted launcher refused"
assert_eq "$(sha_of "$DRIFT_HOME/bin/pfr")" "$DRIFT_SHA" "drifted launcher untouched"

# Fail closed: a directory at the launcher path is never the legacy shape.
DIR_HOME="$WORK/legacy-dir-home"
make_legacy_install "$DIR_HOME"
mv "$DIR_HOME/bin/pfr" "$DIR_HOME/bin/pfr-copy"
mkdir -p "$DIR_HOME/bin/pfr"
if HOME="$DIR_HOME" PFR_INSTALLER_KEEP_TEMPS=1 \
   PFR_INSTALL_LOCK_DIR="$WORK/lock-legacy-dir" \
   bash "$PFR_ROOT/install.sh" --offline "$WORK/pfr-two.tar.gz" \
     --prefix "$DIR_HOME/share/pfr" --bin-dir "$DIR_HOME/bin" \
     --no-gum >"$WORK/legacy-dir.log" 2>&1; then
  fail "installer replaced a directory at the launcher path"
fi
assert_contains "$(<"$WORK/legacy-dir.log")" "refusing to replace unrelated path" "launcher directory refused"
[[ -d "$DIR_HOME/bin/pfr" ]] || fail "launcher directory was disturbed"

# Escape hatch: migration can be turned off, and then the old refusal stands.
OPTOUT_HOME="$WORK/legacy-optout-home"
make_legacy_install "$OPTOUT_HOME"
OPTOUT_SHA="$(sha_of "$OPTOUT_HOME/bin/pfr")"
if HOME="$OPTOUT_HOME" PFR_INSTALLER_KEEP_TEMPS=1 \
   PFR_INSTALLER_NO_LEGACY_MIGRATION=1 \
   PFR_INSTALL_LOCK_DIR="$WORK/lock-legacy-optout" \
   bash "$PFR_ROOT/install.sh" --offline "$WORK/pfr-two.tar.gz" \
     --prefix "$OPTOUT_HOME/share/pfr" --bin-dir "$OPTOUT_HOME/bin" \
     --no-gum >"$WORK/legacy-optout.log" 2>&1; then
  fail "PFR_INSTALLER_NO_LEGACY_MIGRATION did not disable migration"
fi
assert_contains "$(<"$WORK/legacy-optout.log")" "refusing to replace unrelated path" "opt-out refusal"
assert_eq "$(sha_of "$OPTOUT_HOME/bin/pfr")" "$OPTOUT_SHA" "opt-out left the legacy launcher in place"

echo "installer OK"
