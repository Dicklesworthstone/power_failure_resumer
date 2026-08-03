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
PS_FILE="${PFR_PS_FILE:-}"              # canned process table (tests)
STATE_DIR="${PFR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/pfr}"
PLAN_PATH=""                            # --plan / --last-plan: open from a saved plan
SAVE_PLAN_PATH=""                       # --save-plan: extra explicit plan copy
NO_SAVE_PLAN=0
FORCE_STALE_PLAN=0
PLAN_SAVED_TO=""
DOCTOR=0
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
  --ps-file PATH        Read process args from a file instead of ps
  --state-dir PATH      Where plans/reports are written (default: ~/.local/state/pfr)

PLANS (discover once, open later):
  Every discovery saves <state-dir>/last-plan.json (unless --no-save-plan).
  --plan PATH           Open/list from a saved plan; skip rediscovery
  --last-plan           Shorthand for --plan <state-dir>/last-plan.json
  --save-plan PATH      Also write the plan to an explicit path
  --no-save-plan        Do not write last-plan.json for this run
  --force-stale-plan    Use a plan even if the machine rebooted since / plan >24h old

HEALTH:
  --doctor              Check environment health (Ghostty, scripting, dirs); exit 0 when healthy
                        Combine with --json for machine-readable results

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
  # Quote resume_cmd for -c so future non-UUID args cannot break the shell.
  local qcmd
  printf -v qcmd '%q' "$resume_cmd"
  nohup ghostty --working-directory="$cwd" \
    -e "${SHELL:-/bin/sh}" -ic "$qcmd" >/dev/null 2>&1 &
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
    --ps-file) need_arg "$@"; PS_FILE="$2"; shift 2 ;;
    --state-dir) need_arg "$@"; STATE_DIR="$2"; shift 2 ;;
    --plan) need_arg "$@"; PLAN_PATH="$2"; shift 2 ;;
    --last-plan) PLAN_PATH="__LAST__"; shift ;;
    --save-plan) need_arg "$@"; SAVE_PLAN_PATH="$2"; shift 2 ;;
    --no-save-plan) NO_SAVE_PLAN=1; shift ;;
    --force-stale-plan) FORCE_STALE_PLAN=1; shift ;;
    --doctor) DOCTOR=1; shift ;;
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

# ── doctor ──────────────────────────────────────────────────────────────────
# Environment health checks. PFR_DOCTOR_SIM_MISSING="ghostty,osascript" lets
# tests simulate absent dependencies.
doctor_sim_missing() { [[ ",${PFR_DOCTOR_SIM_MISSING:-}," == *",$1,"* ]]; }

doctor_run() {
  local -a c_name=() c_status=() c_detail=()
  add_check() { c_name+=("$1"); c_status+=("$2"); c_detail+=("$3"); }

  if ! doctor_sim_missing python3 && command -v python3 >/dev/null 2>&1; then
    add_check python3 ok "$(python3 -V 2>&1)"
  else
    add_check python3 fail "python3 not found in PATH"
  fi

  local f libs_missing=""
  for f in "$DISCOVER_PY" "${ROOT}/lib/plan.py" "${ROOT}/lib/confidence.py"; do
    [[ -f "$f" ]] || libs_missing="${libs_missing} $(basename "$f")"
  done
  if [[ -z "$libs_missing" ]]; then
    add_check lib_files ok "discover.py plan.py confidence.py present"
  else
    add_check lib_files fail "missing:${libs_missing}"
  fi

  if mkdir -p "$STATE_DIR" 2>/dev/null && : > "${STATE_DIR}/.doctor-probe" 2>/dev/null; then
    rm -f "${STATE_DIR}/.doctor-probe"
    add_check state_dir ok "$STATE_DIR writable"
  else
    add_check state_dir fail "$STATE_DIR not writable"
  fi

  if [[ "$PLATFORM" == "Darwin" ]]; then
    if ! doctor_sim_missing osascript && command -v osascript >/dev/null 2>&1; then
      add_check osascript ok "osascript present"
    else
      add_check osascript fail "osascript not found (required for ui/api drivers)"
    fi
    if [[ -f "$OPEN_UI_AS" && -f "$OPEN_API_AS" ]]; then
      add_check applescripts ok "driver scripts present"
    else
      add_check applescripts fail "driver .applescript files missing under lib/"
    fi
    if ! doctor_sim_missing ghostty && open -Ra Ghostty 2>/dev/null; then
      add_check ghostty_app ok "Ghostty.app installed"
    else
      add_check ghostty_app fail "Ghostty.app not found (install from https://ghostty.org)"
    fi
    # Automation probe: only meaningful when Ghostty is already running.
    if ghostty_is_running 2>/dev/null; then
      local probe
      if probe="$(osascript -e 'tell application "System Events" to return (exists process "Ghostty")' 2>&1)"; then
        add_check automation ok "System Events reachable (probe: ${probe})"
      else
        add_check automation warn "System Events probe failed — grant Automation (and Accessibility for keystroke fallback): ${probe}"
      fi
    else
      add_check automation ok "not probed (Ghostty not running)"
    fi
  else
    if ! doctor_sim_missing ghostty && command -v ghostty >/dev/null 2>&1; then
      add_check ghostty_cli ok "$(command -v ghostty)"
    else
      add_check ghostty_cli fail "ghostty not found in PATH (Linux driver needs it; dry-run still works)"
    fi
  fi

  local codex_dir claude_dir
  codex_dir="${CODEX_ROOT:-${CODEX_HOME:-$HOME/.codex}/sessions}"
  claude_dir="${CLAUDE_ROOT:-${CLAUDE_HOME:-$HOME/.claude}/projects}"
  [[ -d "$codex_dir" ]] && add_check codex_root ok "$codex_dir" \
    || add_check codex_root warn "$codex_dir missing (no codex sessions will be found)"
  [[ -d "$claude_dir" ]] && add_check claude_root ok "$claude_dir" \
    || add_check claude_root warn "$claude_dir missing (no claude sessions will be found)"

  command -v fzf >/dev/null 2>&1 \
    && add_check fzf ok "$(command -v fzf) (nicer --pick)" \
    || add_check fzf warn "fzf not found — --pick falls back to numeric prompt"
  command -v am >/dev/null 2>&1 \
    && add_check agent_mail ok "am found — will open an agent-mail tab first" \
    || add_check agent_mail warn "am not found — no agent-mail tab (optional)"

  local fails=0 i
  for i in "${!c_name[@]}"; do
    [[ "${c_status[$i]}" == "fail" ]] && fails=$((fails + 1))
  done

  if (( JSON_OUT )); then
    for i in "${!c_name[@]}"; do
      printf '%s\t%s\t%s\n' "${c_name[$i]}" "${c_status[$i]}" "${c_detail[$i]}"
    done | python3 -c '
import json, sys
checks = []
for line in sys.stdin:
    name, status, detail = line.rstrip("\n").split("\t", 2)
    checks.append({"name": name, "status": status, "detail": detail})
healthy = all(c["status"] != "fail" for c in checks)
print(json.dumps({"healthy": healthy, "checks": checks}, indent=2))'
  else
    local mark
    for i in "${!c_name[@]}"; do
      case "${c_status[$i]}" in
        ok)   mark="✓" ;;
        warn) mark="⚠" ;;
        *)    mark="✗" ;;
      esac
      printf '%s %-12s %s\n' "$mark" "${c_name[$i]}" "${c_detail[$i]}"
    done
    echo
    if (( fails == 0 )); then
      log "doctor: healthy"
    else
      warn "doctor: ${fails} failing check(s)"
    fi
  fi
  (( fails == 0 ))
}

if (( DOCTOR )); then
  doctor_run
  exit $?
fi

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
if (( ! DRY_RUN && ! JSON_OUT )); then
  case "$DRIVER" in
    ui|api)
      need_cmd osascript
      [[ -f "$OPEN_API_AS" ]] || die "missing $OPEN_API_AS"
      [[ -f "$OPEN_UI_AS" ]] || die "missing $OPEN_UI_AS"
      ;;
    ghostty) need_cmd ghostty ;;
  esac
fi

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
if [[ -n "$PS_FILE" ]]; then
  discover_args+=(--ps-file "$PS_FILE")
fi

# Empty provider list is a silent footgun (spaces/commas only)
if [[ -z "${PROVIDERS//[ ,]}" ]]; then
  die "--providers is empty"
fi

PLAN_PY="${ROOT}/lib/plan.py"
[[ -f "$PLAN_PY" ]] || die "missing $PLAN_PY"
[[ "$PLAN_PATH" == "__LAST__" ]] && PLAN_PATH="${STATE_DIR}/last-plan.json"

if [[ -n "$PLAN_PATH" ]]; then
  [[ -f "$PLAN_PY" ]] || die "missing $PLAN_PY (needed to load plans)"
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
    if [[ ! -f "$PLAN_PY" ]]; then
      warn "missing $PLAN_PY — plan not saved"
      PLAN_SAVED_TO=""
    else
      plan_save_args=(save --state-dir "$STATE_DIR")
      [[ -n "$SAVE_PLAN_PATH" ]] && plan_save_args+=(--extra-path "$SAVE_PLAN_PATH")
      if PLAN_INFO="$(printf '%s' "$JSON" | python3 "$PLAN_PY" "${plan_save_args[@]}")"; then
        PLAN_SAVED_TO="$(printf '%s' "$PLAN_INFO" | python3 -c 'import json,sys; print(json.load(sys.stdin)["saved"])' 2>/dev/null || true)"
      else
        warn "could not save plan (continuing)"
        PLAN_SAVED_TO=""
      fi
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
# Feed JSON over stdin. Environment variables share the execve ARG_MAX budget,
# so putting a large discovery payload in PFR_JSON can fail on wide clusters.
META="$(
  PFR_SESS_OUT="$SESS_FILE" python3 /dev/fd/3 <<<"$JSON" 3<<'PY'
import json, os, re, sys, unicodedata
from datetime import date, datetime

try:
    data = json.load(sys.stdin)
except Exception as e:
    print(f"failed to parse discovery JSON: {e}", file=sys.stderr)
    sys.exit(1)

uuid_re = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
    re.I,
)

def clean(x: object) -> str:
    # TSV is both a transport and terminal display boundary. Replace all
    # control characters so metadata cannot split records or emit escapes.
    return "".join(
        " " if unicodedata.category(ch) == "Cc" else ch for ch in str(x)
    )

out_path = os.environ["PFR_SESS_OUT"]
lines = []
today = date.today()
sessions = data.get("sessions") or []
if not isinstance(sessions, list):
    print("invalid discovery JSON: sessions must be a list", file=sys.stderr)
    sys.exit(1)
for index, s in enumerate(sessions):
    if not isinstance(s, dict):
        print(f"invalid discovery JSON: sessions[{index}] must be an object", file=sys.stderr)
        sys.exit(1)
    provider = s.get("provider")
    sid = s.get("session_id")
    cwd = s.get("cwd")
    if provider not in ("codex", "claude"):
        print(f"invalid session provider at index {index}: {provider!r}", file=sys.stderr)
        sys.exit(1)
    if not isinstance(sid, str) or not uuid_re.fullmatch(sid):
        print(f"invalid session UUID at index {index}: {sid!r}", file=sys.stderr)
        sys.exit(1)
    if not isinstance(cwd, str) or not cwd.startswith("/"):
        print(f"invalid session cwd at index {index}: {cwd!r}", file=sys.stderr)
        sys.exit(1)
    resume_cmd = f"cod resume {sid}" if provider == "codex" else f"cc --resume {sid}"
    try:
        dt = datetime.fromtimestamp(float(s["mtime"]))
    except (KeyError, TypeError, ValueError, OverflowError, OSError) as e:
        print(f"invalid session mtime at index {index}: {e}", file=sys.stderr)
        sys.exit(1)
    # Lookback spans days; an undated time would make a stale cluster look current.
    mt = dt.strftime("%H:%M:%S") if dt.date() == today else dt.strftime("%m-%d %H:%M")

    lines.append(
        "\t".join(
            [
                clean(provider),
                clean(sid),
                clean(cwd),
                clean(mt),
                resume_cmd,
                clean(s.get("title") or ""),
            ]
        )
    )
with open(out_path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines))
    if lines:
        fh.write("\n")

print(clean(data.get("boot_time_human") or "unknown"))
print(clean(data.get("mode") or ""))
print(clean(data.get("anchor_mtime_human") or ""))
print(len(lines))
print(clean(data.get("total_candidates_scanned") or 0))
print(clean(data.get("skipped_running") or 0))
print(clean(data.get("confidence") or "unknown"))
reasons = data.get("confidence_reasons") or []
print(clean(", ".join(str(reason) for reason in reasons)))
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

# Hub sessions (cwd exactly ~/projects, /data/projects, or /dp) go first so
# they land right after the agent-mail tab. Stable sort keeps newest-first
# order within each group.
ORDER_TMP="$(tmpfile)"
awk -F'\t' -v home="$HOME" 'BEGIN{OFS=FS}
  { pri = ($3 == home "/projects" || $3 == "/data/projects" || $3 == "/dp") ? 0 : 1
    printf "%d\t%s\n", pri, $0 }' "$SELECTED_FILE" \
  | sort -s -t$'\t' -k1,1n | cut -f2- > "$ORDER_TMP"
mv "$ORDER_TMP" "$SELECTED_FILE"

if (( ! DRY_RUN )) && [[ "$DRIVER" != "ghostty" ]]; then
  ensure_ghostty   # ghostty CLI driver spawns its own windows; no pre-launch needed
fi

# Agent-mail tab: when `am` is installed, open it FIRST so the mail hub is
# tab 1. Disable with PFR_AM=0; PFR_AM_BIN overrides the binary (tests).
AM_BIN="${PFR_AM_BIN:-am}"
if [[ "${PFR_AM:-1}" != "0" && -n "$AM_BIN" ]] && command -v "$AM_BIN" >/dev/null 2>&1; then
  if (( DRY_RUN )); then
    open_one "$HOME" "$AM_BIN"
  else
    log "opening agent-mail tab (${AM_BIN}) first…"
    open_one "$HOME" "$AM_BIN" || warn "failed to open agent-mail tab"
    sleep "$DELAY_SECONDS"
  fi
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

ATTEMPTS_FILE="$(tmpfile)"
i=0
while IFS=$'\t' read -r provider sid cwd mt resume_cmd title || [[ -n "${provider:-}" ]]; do
  [[ -z "${provider:-}" ]] && continue
  i=$((i + 1))
  short_cwd="${cwd/#$HOME/~}"
  printf '  [%d/%d] %s  %s\n' "$i" "$SEL_COUNT" "$provider" "$short_cwd"
  if open_one "$cwd" "$resume_cmd"; then
    OPEN_OKS=$((OPEN_OKS + 1))
    printf '%s\t%s\t%s\t1\n' "$provider" "$sid" "$cwd" >> "$ATTEMPTS_FILE"
  else
    OPEN_FAILS=$((OPEN_FAILS + 1))
    printf '%s\t%s\t%s\t0\n' "$provider" "$sid" "$cwd" >> "$ATTEMPTS_FILE"
    warn "failed to open: $provider $sid ($short_cwd)"
  fi
  if (( ! DRY_RUN )) && [[ "$i" -lt "$SEL_COUNT" ]]; then
    sleep "$DELAY_SECONDS"
  fi
done < "$SELECTED_FILE"

echo
if (( DRY_RUN )); then
  rm -f "$ATTEMPTS_FILE"
  log "dry-run complete — re-run with -y (or answer y) to open."
  if [[ -n "$PLAN_SAVED_TO" ]]; then
    log "plan saved: ${PLAN_SAVED_TO}  (confidence=${CONFIDENCE}, ${SEL_COUNT} sessions)"
    log "next: pfr --last-plan -y   or   pfr --last-plan --pick"
  fi
else
  log "done: ${OPEN_OKS} opened, ${OPEN_FAILS} failed (of ${SEL_COUNT})."
  VERIFY_RC=0
  if [[ "${PFR_VERIFY:-1}" != "0" ]]; then
    log "verifying resumes (up to ${PFR_VERIFY_TIMEOUT:-15}s)…"
    verify_args=(--timeout "${PFR_VERIFY_TIMEOUT:-15}" --state-dir "$STATE_DIR"
                 --driver "$DRIVER" --open-mode "$OPEN_MODE")
    [[ -n "$PS_FILE" ]] && verify_args+=(--ps-file "$PS_FILE")
    if VERIFY_OUT="$(python3 "${ROOT}/lib/verify.py" "${verify_args[@]}" < "$ATTEMPTS_FILE")"; then
      :
    else
      VERIFY_RC=1
    fi
    if [[ -n "${VERIFY_OUT:-}" ]]; then
      VERIFIED="$(printf '%s' "$VERIFY_OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["verified"])' 2>/dev/null || echo "?")"
      UNVERIFIED="$(printf '%s' "$VERIFY_OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(", ".join(d["unverified"]))' 2>/dev/null || true)"
      log "verified:      ${VERIFIED}/${OPEN_OKS} resumed sessions visible in ps"
      log "report:        ${STATE_DIR}/last-report.json"
      if [[ -n "$UNVERIFIED" ]]; then
        warn "no process evidence for: ${UNVERIFIED}"
        warn "check those tabs — the resume command may not have executed (try larger --settle)."
      fi
    fi
  fi
  rm -f "$ATTEMPTS_FILE"
  if (( OPEN_FAILS > 0 )); then
    warn "partial resume — re-run with --pick for the failures."
    exit 1
  fi
  if (( VERIFY_RC != 0 )); then
    exit 1
  fi
  log "tip: if a tab only shows a shell, press Up or re-run with a larger --settle."
fi
