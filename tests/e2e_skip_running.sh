#!/usr/bin/env bash
# E2E: ps-file marks part of the cluster as already running → skipped +
# removed from the offered list; --force-reopen restores them.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SD="$(mktemp -d "${TMPDIR:-/tmp}/pfr-e2e.XXXXXX")"
trap 'rm -rf "$SD"' EXIT

C1="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['C1'])" "$FIX/ids.json")"
C4="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['C4_running'])" "$FIX/ids.json")"

# Half the codex cluster already resumed: C1 and C4 live
PSF="$SD/ps.txt"
printf 'zsh -il\ncod resume %s\nnode /x/cc --resume %s\n' "$C1" "$C4" > "$PSF"

out="$("$PFR" --dry-run "${FIX_ARGS[@]}" --state-dir "$SD" --ps-file "$PSF" 2>&1)" \
  || fail "dry-run failed: $out"

assert_contains "$out" "matched:       3 session(s)" "3 remain offered"
assert_contains "$out" "skipped:       2 already-running" "2 skipped"
assert_not_contains "$out" "$C1" "running C1 not offered"
assert_not_contains "$out" "$C4" "running C4 not offered"

out="$("$PFR" --dry-run "${FIX_ARGS[@]}" --state-dir "$SD" --ps-file "$PSF" --force-reopen 2>&1)" \
  || fail "force-reopen dry-run failed"
assert_contains "$out" "matched:       5 session(s)" "force-reopen restores all 5"
assert_contains "$out" "$C1" "C1 offered under force-reopen"

echo "e2e_skip_running OK"
