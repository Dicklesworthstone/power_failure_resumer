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

echo "installer OK"
