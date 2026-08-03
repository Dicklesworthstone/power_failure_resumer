#!/usr/bin/env bash
# --notify: offline high/medium threshold checks, no output, and no tab opens.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SD="$(new_state_dir pfr-notify)"
NOTIFY_LOG="$SD/notify.log"
NOTIFY_CMD="$SD/capture-notify.sh"

cat > "$NOTIFY_CMD" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${PFR_NOTIFY_LOG:?}"
EOF
chmod +x "$NOTIFY_CMD"

run_notify() {
  PFR_NOTIFY_LOG="$NOTIFY_LOG" PFR_NOTIFY_CMD="$NOTIFY_CMD" "$PFR" --notify \
    "${FIX_ARGS[@]}" --ps-file "$FIX/ps.txt" --state-dir "$SD" "$@" 2>&1
}

# The standard fixture pocket is high confidence with four resumeable sessions.
out="$(run_notify)" || fail "high-confidence notify failed: $out"
assert_eq "$out" "" "--notify must stay quiet"
assert_eq "$(sed -n '1p' "$NOTIFY_LOG")" "pfr" "notification title"
assert_eq "$(sed -n '2p' "$NOTIFY_LOG")" \
  "4 session(s) ready — run: pfr --last-plan --pick" "high notification body"
[[ -f "$SD/last-plan.json" ]] || fail "qualifying notification must save last-plan"

# A narrow pre-boot pocket is medium confidence, but three sessions still notify.
out="$(run_notify --mode pre_boot --window 10)" \
  || fail "medium three-session notify failed: $out"
assert_eq "$out" "" "medium notification must stay quiet"
assert_eq "$(sed -n '3p' "$NOTIFY_LOG")" "pfr" "medium notification title"
assert_eq "$(sed -n '4p' "$NOTIFY_LOG")" \
  "3 session(s) ready — run: pfr --last-plan --pick" "medium notification body"

# Two offered sessions at medium confidence are below the notification threshold.
out="$(run_notify --mode pre_boot --window 5)" \
  || fail "non-qualifying notify failed: $out"
assert_eq "$out" "" "non-qualifying notify must stay silent"
assert_eq "$(wc -l < "$NOTIFY_LOG" | tr -d '[:space:]')" "4" \
  "medium two-session cluster must not notify"

# --notify exits before the launch path even if a caller accidentally supplies -y.
out="$(run_notify -y)" || fail "notify with -y failed: $out"
assert_eq "$out" "" "--notify -y must stay quiet and never open"
assert_eq "$(wc -l < "$NOTIFY_LOG" | tr -d '[:space:]')" "6" \
  "notify with -y must only send the notification"

# --notify exits before all Ghostty launch settings, status-tab, and agent-mail
# paths. Simulate Linux so a stale macOS driver would fail if it were consulted.
FAKE_BIN="$SD/fake-bin"
mkdir -p "$FAKE_BIN"
printf '%s\n' '#!/usr/bin/env bash' \
  '[[ "${1:-}" == "-s" ]] && { printf "Linux\\n"; exit 0; }' \
  'exec /usr/bin/uname "$@"' > "$FAKE_BIN/uname"
chmod 700 "$FAKE_BIN/uname"
out="$(PATH="$FAKE_BIN:$PATH" PFR_DRIVER=ui PFR_OPEN_MODE=invalid \
  PFR_SETTLE=invalid PFR_DELAY=invalid PFR_MAX=invalid \
  PFR_STATUS_TAB=1 PFR_AM=1 PFR_AM_BIN=definitely-not-am \
  PFR_NOTIFY_LOG="$NOTIFY_LOG" PFR_NOTIFY_CMD="$NOTIFY_CMD" "$PFR" --notify \
  "${FIX_ARGS[@]}" --ps-file "$FIX/ps.txt" --state-dir "$SD" 2>&1)" \
  || fail "notify must not evaluate launch settings: $out"
assert_eq "$out" "" "notify ignores launch-only configuration"
assert_eq "$(wc -l < "$NOTIFY_LOG" | tr -d '[:space:]')" "8" \
  "notify sent once without opening status or agent-mail tabs"

# A notification must never point at a stale/missing last plan when persistence
# fails. A regular file cannot serve as the requested state directory.
BAD_STATE="$SD/not-a-directory"
: > "$BAD_STATE"
if out="$(run_notify --state-dir "$BAD_STATE")"; then
  fail "notify must fail when the qualifying plan cannot be saved"
fi
assert_contains "$out" "could not save qualifying plan" \
  "plan-save failure must be actionable"
assert_eq "$(wc -l < "$NOTIFY_LOG" | tr -d '[:space:]')" "8" \
  "failed plan persistence must not notify"

echo "notify OK"
