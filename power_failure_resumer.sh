#!/usr/bin/env bash
# power_failure_resumer.sh — reopen local Codex/Claude agent sessions in Ghostty
# after an unexpected power loss / hard reboot.
#
# Typical flow:
#   ./power_failure_resumer.sh              # discover + interactive confirm
#   ./power_failure_resumer.sh --dry-run    # only list
#   ./power_failure_resumer.sh -y           # open all without prompt
#   ./power_failure_resumer.sh --pick       # interactive multi-select
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISCOVER_PY="${ROOT}/lib/discover.py"
OPEN_API_AS="${ROOT}/lib/open_sessions.applescript"
OPEN_UI_AS="${ROOT}/lib/open_sessions_ui.applescript"

WINDOW_SECONDS="${PFR_WINDOW:-180}"
LOOKBACK_HOURS="${PFR_LOOKBACK_HOURS:-48}"
PRE_BOOT_LOOKBACK="${PFR_PRE_BOOT_LOOKBACK:-900}"
PROVIDERS="${PFR_PROVIDERS:-codex,claude}"
OPEN_MODE="${PFR_OPEN_MODE:-tab}"       # tab | window
PLATFORM="$(uname -s)"                  # Darwin | Linux
DRIVER="${PFR_DRIVER:-}"                # ui | api (macOS) | ghostty (Linux); default per-platform
DELAY_SECONDS="${PFR_DELAY:-}"          # empty → pick sensible default per driver
SETTLE_SECONDS="${PFR_SETTLE:-0.55}"    # wait after creating a surface for shell
MAX_OPEN="${PFR_MAX_OPEN:-40}"
CODEX_ROOT="${PFR_CODEX_ROOT:-}"        # override discover.py --codex-root (tests)
CLAUDE_ROOT="${PFR_CLAUDE_ROOT:-}"      # override discover.py --claude-root (tests)
FAKE_BOOT="${PFR_FAKE_BOOT:-}"          # override boot epoch (tests)
STATE_DIR="${PFR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/pfr}"
PLAN_PATH=""                            # --plan / --last-plan: open from a saved plan
SAVE_PLAN_PATH=""                       # --save-plan: extra explicit plan copy
NO_SAVE_PLAN=0
FORCE_STALE_PLAN=0
PLAN_SAVED_TO=""
PROJECTS_ONLY=0
INCLUDE_SUBAGENTS=0
FORCE_REOPEN=0
DRY_RUN=0
YES=0
PICK=0
JSON_OUT=0
MODE="auto"
LIMIT=0
# Set when ensure_ghostty() had to open a fresh Ghostty instance (informational)
# shellcheck disable=SC2034
GHOSTTY_FRESH_LAUNCH=0
OPEN_FAILS=0
OPEN_OKS=0

usage() {
  cat <<'EOF'
power_failure_resumer — resume Ghostty agent tabs after a power failure

USAGE:
  power_failure_resumer.sh [options]

DISCOVERY:
  --window SECS         Cluster window for simultaneous death (default: 180)
  --lookback-hours H    Only scan sessions modified in last H hours (default: 48)
  --pre-boot-lookback S Seconds before boot treated as crash window (default: 900)
  --mode MODE           auto | pre_boot | density | recent (default: auto)
  --providers LIST      codex,claude (default: both)
  --projects-only       Only sessions whose cwd is under ~/projects
  --include-subagents   Include Codex subagent threads (noisy)
  --force-reopen        Offer sessions even if a live process already resumed them
  --limit N             Cap listed/opened sessions (keeps newest)
  --json                Print discovery JSON and exit

ISOLATION (tests / non-standard setups):
  --codex-root PATH     Codex sessions dir (default: \$CODEX_HOME/sessions)
  --claude-root PATH    Claude projects dir (default: \$CLAUDE_HOME/projects)
  --fake-boot EPOCH     Pretend the system booted at this epoch time
  --state-dir PATH      Where plans/reports are written (default: ~/.local/state/pfr)

PLANS (discover once, open later):
  Every discovery saves <state-dir>/last-plan.json (unless --no-save-plan).
  --plan PATH           Open/list from a saved plan; skip rediscovery
  --last-plan           Shorthand for --plan <state-dir>/last-plan.json
  --save-plan PATH      Also write the plan to an explicit path
  --no-save-plan        Do not write last-plan.json for this run
  --force-stale-plan    Use a plan even if the machine rebooted since / plan >24h old

LAUNCH:
  --dry-run, -n         List only; do not open Ghostty
  -y, --yes             Open all discovered sessions without prompt
  --pick                Interactively pick a subset (fzf if available)
  --tabs                Open as Ghostty tabs (default)
  --windows             Open each as a new Ghostty window
  --driver MODE         How to open Ghostty (default: ui on macOS, ghostty on Linux)
                          ui      — macOS: native new-tab + input text (fallback: keystrokes)
                          api     — macOS: same native surface API (no keystroke fallback)
                          ghostty — Linux: one window per session via the ghostty CLI
  --ui                  Shortcut for --driver ui
  --api                 Shortcut for --driver api
  --delay SECS          Pause between sessions (ui default 0.8, api default 0.35)
  --settle SECS         Wait after new surface for shell (default: 0.55)
  --max N               Safety cap on opens (default: 40)

ENVIRONMENT:
  PFR_WINDOW, PFR_LOOKBACK_HOURS, PFR_PRE_BOOT_LOOKBACK, PFR_PROVIDERS,
  PFR_OPEN_MODE, PFR_DRIVER, PFR_DELAY, PFR_SETTLE, PFR_MAX_OPEN

EXAMPLES:
  ./power_failure_resumer.sh --dry-run
  ./power_failure_resumer.sh -y
  ./power_failure_resumer.sh -y --api
  ./power_failure_resumer.sh --providers codex --projects-only --pick
EOF
}

log()  { printf '› %s\n' "$*" >&2; }
warn() { printf '⚠ %s\n' "$*" >&2; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

# Require a non-empty next argv for options that take a value.
need_arg() {
  local opt="$1"
  if [[ $# -lt 2 || -z "${2:-}" || "$2" == -* ]]; then
    die "option $opt requires a value"
  fi
}

require_uint() {
  local name="$1" val="$2"
  if [[ ! "$val" =~ ^[0-9]+$ ]]; then
    die "$name must be a non-negative integer (got: $val)"
  fi
}

require_number() {
  local name="$1" val="$2"
  if [[ ! "$val" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    die "$name must be a non-negative number (got: $val)"
  fi
}

tmpfile() {
  # Portable: macOS `mktemp -t prefix` does NOT expand XXXXXX the way GNU does.
  mktemp "${TMPDIR:-/tmp}/pfr.XXXXXX"
}

# macOS reports the full binary path as the process name, so `pgrep -x Ghostty`
# never matches. Prefer System Events (process name "Ghostty"), then path match.
ghostty_is_running() {
  local r
  r="$(osascript -e 'tell application "System Events" to return (exists process "Ghostty")' 2>/dev/null || true)"
  if [[ "$r" == "true" ]]; then
    return 0
  fi
  # Binary path match; avoid matching arbitrary commands that merely mention Ghostty.
  pgrep -f '/Ghostty\.app/Contents/MacOS/ghostty$' >/dev/null 2>&1
}

ensure_ghostty() {
  if ghostty_is_running; then
    GHOSTTY_FRESH_LAUNCH=0
    osascript -e 'tell application "Ghostty" to activate' >/dev/null 2>&1 || true
    return 0
  fi
  log "launching Ghostty (defaults)…"
  # shellcheck disable=SC2034
  GHOSTTY_FRESH_LAUNCH=1
  open -a Ghostty
  local i
  for i in {1..24}; do
    if ghostty_is_running; then
      # Give the first default shell time to finish rc files
      sleep 0.8
      return 0
    fi
    sleep 0.25
  done
  die "Ghostty did not become ready"
}

open_one_api() {
  local cwd="$1"
  local resume_cmd="$2"
  osascript "$OPEN_API_AS" "$cwd" "$resume_cmd" "$OPEN_MODE" "$SETTLE_SECONDS" >/dev/null
}

open_one_ghostty() {
  local cwd="$1"
  local resume_cmd="$2"
  # Linux: no scripting API — spawn one window per session via the ghostty CLI.
  # Interactive shell (-i) so cod/cc aliases from rc files resolve.
  nohup ghostty --working-directory="$cwd" \
    -e "${SHELL:-/bin/sh}" -ic "$resume_cmd" >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

open_one_ui() {
  local cwd="$1"
  local resume_cmd="$2"
  # Always open a dedicated tab/window (is_first=0). Reusing the default tab on a
  # "fresh" launch was unsafe when Ghostty restores windows or already had content.
  # is_first arg kept for AppleScript compatibility (ignored for creation).
  osascript "$OPEN_UI_AS" "$cwd" "$resume_cmd" "$OPEN_MODE" "0" "$SETTLE_SECONDS" >/dev/null
}

open_one() {
  local cwd="$1"
  local resume_cmd="$2"

  if [[ ! -d "$cwd" ]]; then
    warn "cwd missing, falling back to ~/projects: $cwd"
    cwd="${HOME}/projects"
    if [[ ! -d "$cwd" ]]; then
      cwd="${HOME}"
      warn "\$HOME/projects also missing; using \$HOME"
    fi
  fi

  if (( DRY_RUN )); then
    printf '  DRY  cd %q && %s\n' "$cwd" "$resume_cmd"
    return 0
  fi

  case "$DRIVER" in
    ui)      open_one_ui      "$cwd" "$resume_cmd" ;;
    api)     open_one_api     "$cwd" "$resume_cmd" ;;
    ghostty) open_one_ghostty "$cwd" "$resume_cmd" ;;
    *)       die "unknown driver: $DRIVER (use ui, api, or ghostty)" ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --window) need_arg "$@"; WINDOW_SECONDS="$2"; shift 2 ;;
    --lookback-hours) need_arg "$@"; LOOKBACK_HOURS="$2"; shift 2 ;;
    --pre-boot-lookback) need_arg "$@"; PRE_BOOT_LOOKBACK="$2"; shift 2 ;;
    --mode) need_arg "$@"; MODE="$2"; shift 2 ;;
    --providers) need_arg "$@"; PROVIDERS="$2"; shift 2 ;;
    --projects-only) PROJECTS_ONLY=1; shift ;;
    --include-subagents) INCLUDE_SUBAGENTS=1; shift ;;
    --force-reopen) FORCE_REOPEN=1; shift ;;
    --codex-root) need_arg "$@"; CODEX_ROOT="$2"; shift 2 ;;
    --claude-root) need_arg "$@"; CLAUDE_ROOT="$2"; shift 2 ;;
    --fake-boot) need_arg "$@"; FAKE_BOOT="$2"; shift 2 ;;
    --state-dir) need_arg "$@"; STATE_DIR="$2"; shift 2 ;;
    --plan) need_arg "$@"; PLAN_PATH="$2"; shift 2 ;;
    --last-plan) PLAN_PATH="__LAST__"; shift ;;
    --save-plan) need_arg "$@"; SAVE_PLAN_PATH="$2"; shift 2 ;;
    --no-save-plan) NO_SAVE_PLAN=1; shift ;;
    --force-stale-plan) FORCE_STALE_PLAN=1; shift ;;
    --limit) need_arg "$@"; LIMIT="$2"; shift 2 ;;
    --json) JSON_OUT=1; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -y|--yes) YES=1; shift ;;
    --pick) PICK=1; shift ;;
    --tabs) OPEN_MODE="tab"; shift ;;
    --windows) OPEN_MODE="window"; shift ;;
    --driver) need_arg "$@"; DRIVER="$2"; shift 2 ;;
    --ui) DRIVER="ui"; shift ;;
    --api) DRIVER="api"; shift ;;
    --delay) need_arg "$@"; DELAY_SECONDS="$2"; shift 2 ;;
    --settle) need_arg "$@"; SETTLE_SECONDS="$2"; shift 2 ;;
    --max) need_arg "$@"; MAX_OPEN="$2"; shift 2 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

# Default driver per platform; validate driver ↔ platform pairing.
if [[ -z "$DRIVER" ]]; then
  if [[ "$PLATFORM" == "Darwin" ]]; then DRIVER="ui"; else DRIVER="ghostty"; fi
fi
case "$DRIVER" in
  ui|api)
    if [[ "$PLATFORM" != "Darwin" ]]; then
      die "driver '$DRIVER' needs macOS AppleScript; on Linux use --driver ghostty"
    fi
    ;;
  ghostty) ;;
  *) die "invalid --driver '$DRIVER' (use ui, api, or ghostty)" ;;
esac
if [[ "$DRIVER" == "ghostty" && "$OPEN_MODE" == "tab" ]]; then
  # The ghostty CLI cannot address an existing window's tabs.
  OPEN_MODE="window"
fi

case "$OPEN_MODE" in
  tab|window) ;;
  *) die "invalid open mode '$OPEN_MODE' (use --tabs or --windows)" ;;
esac

case "$MODE" in
  auto|pre_boot|density|recent) ;;
  *) die "invalid --mode '$MODE'" ;;
esac

require_number "--window/PFR_WINDOW" "$WINDOW_SECONDS"
require_number "--lookback-hours" "$LOOKBACK_HOURS"
require_number "--pre-boot-lookback" "$PRE_BOOT_LOOKBACK"
require_number "--settle" "$SETTLE_SECONDS"
require_uint "--limit" "$LIMIT"
require_uint "--max" "$MAX_OPEN"

# Per-driver default inter-session delay if user did not set one
if [[ -z "$DELAY_SECONDS" ]]; then
  if [[ "$DRIVER" == "ui" ]]; then
    DELAY_SECONDS="0.80"
  else
    DELAY_SECONDS="0.35"
  fi
fi
require_number "--delay" "$DELAY_SECONDS"

need_cmd python3
[[ -f "$DISCOVER_PY" ]] || die "missing $DISCOVER_PY"
case "$DRIVER" in
  ui|api)
    need_cmd osascript
    [[ -f "$OPEN_API_AS" ]] || die "missing $OPEN_API_AS"
    [[ -f "$OPEN_UI_AS" ]] || die "missing $OPEN_UI_AS"
    ;;
  ghostty)
    (( DRY_RUN )) || need_cmd ghostty
    ;;
esac

discover_args=(
  --window "$WINDOW_SECONDS"
  --lookback-hours "$LOOKBACK_HOURS"
  --pre-boot-lookback "$PRE_BOOT_LOOKBACK"
  --providers "$PROVIDERS"
  --mode "$MODE"
)
if (( PROJECTS_ONLY )); then
  discover_args+=(--projects-only)
fi
if (( INCLUDE_SUBAGENTS )); then
  discover_args+=(--include-subagents)
fi
if (( FORCE_REOPEN )); then
  discover_args+=(--force-reopen)
fi
if (( LIMIT > 0 )); then
  discover_args+=(--limit "$LIMIT")
fi
if [[ -n "$CODEX_ROOT" ]]; then
  discover_args+=(--codex-root "$CODEX_ROOT")
fi
if [[ -n "$CLAUDE_ROOT" ]]; then
  discover_args+=(--claude-root "$CLAUDE_ROOT")
fi
if [[ -n "$FAKE_BOOT" ]]; then
  require_number "--fake-boot" "$FAKE_BOOT"
  discover_args+=(--fake-boot "$FAKE_BOOT")
fi

# Empty provider list is a silent footgun (spaces/commas only)
if [[ -z "${PROVIDERS//[ ,]}" ]]; then
  die "--providers is empty"
fi

PLAN_PY="${ROOT}/lib/plan.py"
[[ "$PLAN_PATH" == "__LAST__" ]] && PLAN_PATH="${STATE_DIR}/last-plan.json"

if [[ -n "$PLAN_PATH" ]]; then
  log "loading plan: ${PLAN_PATH}"
  plan_load_args=(load --path "$PLAN_PATH")
  (( FORCE_STALE_PLAN )) && plan_load_args+=(--force)
  [[ -n "$FAKE_BOOT" ]] && plan_load_args+=(--fake-boot "$FAKE_BOOT")
  if ! JSON="$(python3 "$PLAN_PY" "${plan_load_args[@]}")"; then
    die "plan load failed (see message above)"
  fi
else
  log "scanning sessions (providers=${PROVIDERS}, mode=${MODE}, window=${WINDOW_SECONDS}s)…"
  # discover.py: JSON on stdout, diagnostics on stderr — keep them separate.
  DISCOVER_ERR="$(tmpfile)"
  if ! JSON="$(python3 "$DISCOVER_PY" "${discover_args[@]}" 2>"$DISCOVER_ERR")"; then
    [[ -s "$DISCOVER_ERR" ]] && cat "$DISCOVER_ERR" >&2
    rm -f "$DISCOVER_ERR"
    die "discovery failed"
  fi
  [[ -s "$DISCOVER_ERR" ]] && cat "$DISCOVER_ERR" >&2
  rm -f "$DISCOVER_ERR"

  # Persist the plan (discover once, open later) unless opted out.
  if (( ! NO_SAVE_PLAN )) || [[ -n "$SAVE_PLAN_PATH" ]]; then
    plan_save_args=(save --state-dir "$STATE_DIR")
    [[ -n "$SAVE_PLAN_PATH" ]] && plan_save_args+=(--extra-path "$SAVE_PLAN_PATH")
    if PLAN_INFO="$(printf '%s' "$JSON" | python3 "$PLAN_PY" "${plan_save_args[@]}")"; then
      PLAN_SAVED_TO="$(printf '%s' "$PLAN_INFO" | python3 -c 'import json,sys; print(json.load(sys.stdin)["saved"])' 2>/dev/null || true)"
    else
      warn "could not save plan (continuing)"
      PLAN_SAVED_TO=""
    fi
  else
    PLAN_SAVED_TO=""
  fi
fi

if (( JSON_OUT )); then
  printf '%s\n' "$JSON"
  exit 0
fi

SESS_FILE="$(tmpfile)"
SELECTED_FILE="$(tmpfile)"
MAP_FILE=""
# DISCOVER_ERR already removed on the happy path; include it so early die still cleans up.
trap 'rm -f "$SESS_FILE" "$SELECTED_FILE" ${MAP_FILE:+"$MAP_FILE"} ${DISCOVER_ERR:+"$DISCOVER_ERR"}' EXIT

# Write TSV + print meta lines for the shell.
# JSON is passed via env to avoid ARG_MAX issues with large discovery payloads.
META="$(
  PFR_JSON="$JSON" PFR_SESS_OUT="$SESS_FILE" python3 <<'PY'
import json, os, sys
from datetime import date, datetime

try:
    data = json.loads(os.environ["PFR_JSON"])
except Exception as e:
    print(f"failed to parse discovery JSON: {e}", file=sys.stderr)
    sys.exit(1)

out_path = os.environ["PFR_SESS_OUT"]
lines = []
today = date.today()
for s in data.get("sessions") or []:
    dt = datetime.fromtimestamp(s["mtime"])
    # Lookback spans days; an undated time would make a stale cluster look current.
    mt = dt.strftime("%H:%M:%S") if dt.date() == today else dt.strftime("%m-%d %H:%M")

    def clean(x: object) -> str:
        return str(x).replace("\t", " ").replace("\n", " ")

    lines.append(
        "\t".join(
            [
                clean(s["provider"]),
                clean(s["session_id"]),
                clean(s["cwd"]),
                clean(mt),
                clean(s["resume_cmd"]),
                clean(s.get("title") or ""),
            ]
        )
    )
with open(out_path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines))
    if lines:
        fh.write("\n")

print(data.get("boot_time_human") or "unknown")
print(data.get("mode") or "")
print(data.get("anchor_mtime_human") or "")
print(len(lines))
print(data.get("total_candidates_scanned") or 0)
print(data.get("skipped_running") or 0)
print(data.get("confidence") or "unknown")
print(", ".join(data.get("confidence_reasons") or []))
PY
)"

BOOT="$(printf '%s\n' "$META" | sed -n '1p')"
MODE_USED="$(printf '%s\n' "$META" | sed -n '2p')"
ANCHOR="$(printf '%s\n' "$META" | sed -n '3p')"
COUNT="$(printf '%s\n' "$META" | sed -n '4p')"
SCANNED="$(printf '%s\n' "$META" | sed -n '5p')"
SKIPPED_RUNNING="$(printf '%s\n' "$META" | sed -n '6p')"
CONFIDENCE="$(printf '%s\n' "$META" | sed -n '7p')"
CONF_REASONS="$(printf '%s\n' "$META" | sed -n '8p')"

echo
log "boot time:     ${BOOT}"
log "cluster mode:  ${MODE_USED}"
log "anchor mtime:  ${ANCHOR}"
log "matched:       ${COUNT} session(s)  (from ${SCANNED} recent candidates)"
log "confidence:    ${CONFIDENCE}  (${CONF_REASONS})"
if [[ "$CONFIDENCE" == "low" ]]; then
  warn "LOW confidence this is a real power-failure cluster — review before opening."
fi
if [[ "${SKIPPED_RUNNING:-0}" != "0" ]]; then
  log "skipped:       ${SKIPPED_RUNNING} already-running session(s)  (--force-reopen to include)"
fi
echo

if [[ "${MODE}" == "auto" && "${MODE_USED}" == "density" ]]; then
  warn "no clear pre-boot crash cluster — using densest recent simultaneous-mtime pocket."
  warn "If you did not just recover from a power failure, review carefully before opening."
fi

if [[ "${COUNT}" -eq 0 ]]; then
  if [[ "${SKIPPED_RUNNING:-0}" != "0" ]]; then
    warn "crash cluster found, but all ${SKIPPED_RUNNING} session(s) already look live."
    warn "nothing to open — use --force-reopen to launch them again anyway."
    exit 0
  fi
  warn "no sessions found in the crash/density cluster."
  warn "try: --mode recent --lookback-hours 6 --window 3600"
  exit 0
fi

printf '%s\n' "──── sessions to resume ────"
n=0
while IFS=$'\t' read -r provider sid cwd mt resume_cmd title || [[ -n "${provider:-}" ]]; do
  [[ -z "${provider:-}" ]] && continue
  n=$((n + 1))
  short_cwd="${cwd/#$HOME/~}"
  printf '%2d. %-6s  %-11s  %s\n' "$n" "$provider" "$mt" "$short_cwd"
  printf '      %s\n' "$resume_cmd"
  base="$(basename "$cwd")"
  if [[ -n "$title" && "$title" != "$base" ]]; then
    printf '      (%s)\n' "$title"
  fi
done < "$SESS_FILE"
echo

select_all() { cp "$SESS_FILE" "$SELECTED_FILE"; }

select_pick() {
  if command -v fzf >/dev/null 2>&1; then
    local map picked num
    MAP_FILE="$(tmpfile)"
    map="$MAP_FILE"
    # Numbered TSV for stable selection even when cwd/cmd contain spaces
    nl -ba -w1 -s$'\t' "$SESS_FILE" > "$map"
    picked="$(
      # fields after nl: 1=num 2=provider 3=sid 4=cwd 5=mtime 6=cmd 7=title
      awk -F'\t' 'BEGIN{OFS="\t"} {print $1, $2, $5, $4, $6}' "$map" \
        | fzf --multi \
            --header="tab = multi-select, enter = confirm" \
            --delimiter=$'\t' \
            --with-nth=1,2,3,4,5 \
        | cut -f1
    )" || true
    : > "$SELECTED_FILE"
    if [[ -n "${picked:-}" ]]; then
      while IFS= read -r num || [[ -n "${num:-}" ]]; do
        num="${num// /}"
        [[ -z "$num" ]] && continue
        if [[ ! "$num" =~ ^[0-9]+$ ]]; then
          warn "skipping non-numeric fzf selection: $num"
          continue
        fi
        num=$((10#$num))
        (( num >= 1 )) || continue
        sed -n "${num}p" "$SESS_FILE" >> "$SELECTED_FILE"
      done <<< "$picked"
    fi
    rm -f "$map"
  else
    log "fzf not found — enter comma-separated numbers (e.g. 1,3,5) or 'all':"
    local choice num
    read -r -p "> " choice || true
    if [[ "$choice" == "all" || "$choice" == "a" ]]; then
      select_all
      return
    fi
    : > "$SELECTED_FILE"
    local old_ifs="$IFS"
    IFS=','
    set -f
    # shellcheck disable=SC2086
    set -- $choice
    set +f
    IFS="$old_ifs"
    for num in "$@"; do
      num="${num// /}"
      [[ -z "$num" ]] && continue
      if [[ ! "$num" =~ ^[0-9]+$ ]]; then
        warn "skipping non-numeric selection: $num"
        continue
      fi
      num=$((10#$num))
      (( num >= 1 )) || continue
      sed -n "${num}p" "$SESS_FILE" >> "$SELECTED_FILE"
    done
  fi
}

if (( PICK )); then
  select_pick
elif (( YES || DRY_RUN )); then
  select_all
else
  read -r -p "Open these in Ghostty (${OPEN_MODE}s, driver=${DRIVER})? [y/N/pick] " ans || ans=""
  case "$ans" in
    y|Y|yes|YES) select_all ;;
    p|P|pick|Pick)
      select_pick
      ;;
    *)
      log "aborted."
      exit 0
      ;;
  esac
fi

SEL_COUNT=0
if [[ -s "$SELECTED_FILE" ]]; then
  SEL_COUNT="$(grep -cve '^[[:space:]]*$' "$SELECTED_FILE" || true)"
fi
SEL_COUNT="${SEL_COUNT:-0}"

if [[ "${SEL_COUNT}" -eq 0 ]]; then
  warn "nothing selected."
  exit 0
fi

if [[ "${SEL_COUNT}" -gt "${MAX_OPEN}" ]]; then
  die "refusing to open ${SEL_COUNT} sessions (cap is ${MAX_OPEN}). Re-run with --max ${SEL_COUNT} if intentional."
fi

if (( ! DRY_RUN )) && [[ "$DRIVER" != "ghostty" ]]; then
  ensure_ghostty   # ghostty CLI driver spawns its own windows; no pre-launch needed
fi

if (( DRY_RUN )); then
  log "dry-run plan (${SEL_COUNT} ${OPEN_MODE}(s), driver=${DRIVER}):"
else
  log "opening ${SEL_COUNT} Ghostty ${OPEN_MODE}(s) via driver=${DRIVER}…"
  if [[ "$DRIVER" == "ui" ]]; then
    log "Prefer native Ghostty scripting; keystroke fallback needs Accessibility."
    log "Do not type in Ghostty until this finishes."
  fi
fi

i=0
while IFS=$'\t' read -r provider sid cwd mt resume_cmd title || [[ -n "${provider:-}" ]]; do
  [[ -z "${provider:-}" ]] && continue
  i=$((i + 1))
  short_cwd="${cwd/#$HOME/~}"
  printf '  [%d/%d] %s  %s\n' "$i" "$SEL_COUNT" "$provider" "$short_cwd"
  if open_one "$cwd" "$resume_cmd"; then
    OPEN_OKS=$((OPEN_OKS + 1))
  else
    OPEN_FAILS=$((OPEN_FAILS + 1))
    warn "failed to open: $provider $sid ($short_cwd)"
  fi
  if (( ! DRY_RUN )) && [[ "$i" -lt "$SEL_COUNT" ]]; then
    sleep "$DELAY_SECONDS"
  fi
done < "$SELECTED_FILE"

echo
if (( DRY_RUN )); then
  log "dry-run complete — re-run with -y (or answer y) to open."
  if [[ -n "$PLAN_SAVED_TO" ]]; then
    log "plan saved: ${PLAN_SAVED_TO}  (confidence=${CONFIDENCE}, ${SEL_COUNT} sessions)"
    log "next: pfr --last-plan -y   or   pfr --last-plan --pick"
  fi
else
  log "done: ${OPEN_OKS} opened, ${OPEN_FAILS} failed (of ${SEL_COUNT})."
  if (( OPEN_FAILS > 0 )); then
    warn "partial resume — re-run with --pick for the failures."
    exit 1
  fi
  log "tip: if a tab only shows a shell, press Up or re-run with a larger --settle."
fi
