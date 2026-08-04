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

# The installed launcher is a symlink (~/.local/bin/pfr -> <prefix>/power_failure_resumer.sh),
# so walk the symlink chain before taking dirname or lib/ resolves next to the
# link instead of the real script. macOS readlink has no -f; resolve by hand.
PFR_SELF="${BASH_SOURCE[0]}"
while [[ -h "$PFR_SELF" ]]; do
  PFR_SELF_DIR="$(cd "$(dirname "$PFR_SELF")" && pwd)"
  PFR_SELF="$(readlink "$PFR_SELF")"
  [[ "$PFR_SELF" == /* ]] || PFR_SELF="${PFR_SELF_DIR}/${PFR_SELF}"
done
ROOT="$(cd "$(dirname "$PFR_SELF")" && pwd)"
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
NOTIFY=0
# Cleaned up by the EXIT trap; pre-set so plan-load runs (which skip
# discovery) don't trip `set -u` when the trap fires.
DISCOVER_ERR=""
ORDERED_FILE=""
MAP_FILE=""
PROJECTS_ONLY=0
INCLUDE_SUBAGENTS=0
INCLUDE_NTM=0
NTM_HISTORY="${PFR_NTM_HISTORY:-}"    # override the ntm send-history path (tests)
NTM_DATA="${PFR_NTM_DATA:-}"          # override the ntm data dir (manifests/checkpoints)
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
  --include-ntm         Include sessions spawned by ntm tmux swarms (excluded by default)
  --ntm-history PATH    ntm send-history file used to detect ntm-spawned sessions
                        (default: ~/.local/share/ntm/history.jsonl; or PFR_NTM_HISTORY)
  --ntm-data DIR        ntm data dir holding manifests/ and checkpoints/ used for
                        attribution (default: ~/.local/share/ntm; or PFR_NTM_DATA)
  --force-reopen        Offer sessions even if a live process already resumed them
  --limit N             Cap listed/opened sessions (keeps newest)
  --json                Print discovery JSON and exit
  --notify              Quietly save a qualifying plan and send a desktop notification; never opens tabs

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
  --settle SECS         Adaptive shell-ready poll cap is 4× this value; use this
                        fixed wait when Ghostty terminal contents are unreadable
                        (default: 0.55)
  --max N               Safety cap on opens (default: 40)

ENVIRONMENT:
  PFR_WINDOW, PFR_LOOKBACK_HOURS, PFR_PRE_BOOT_LOOKBACK, PFR_PROVIDERS,
  PFR_OPEN_MODE, PFR_DRIVER, PFR_DELAY, PFR_SETTLE, PFR_MAX_OPEN,
  PFR_NOTIFY_CMD (optional notification-command override)

EXAMPLES:
  ./power_failure_resumer.sh --dry-run
  ./power_failure_resumer.sh -y
  ./power_failure_resumer.sh -y --api
  ./power_failure_resumer.sh --providers codex --projects-only --pick
EOF
}

# Every log line also lands in the run log (tab 1 tails it live during opens).
log()  { printf '› %s\n' "$*" >&2; [[ -n "${RUN_LOG:-}" ]] && printf '› %s\n' "$*" >> "$RUN_LOG" || true; }
warn() { printf '⚠ %s\n' "$*" >&2; [[ -n "${RUN_LOG:-}" ]] && printf '⚠ %s\n' "$*" >> "$RUN_LOG" || true; }
die()  { printf '✗ %s\n' "$*" >&2; [[ -n "${RUN_LOG:-}" ]] && printf '✗ %s\n' "$*" >> "$RUN_LOG" || true; exit 1; }

# Styled header for the run log (gum when present, ANSI/ASCII fallback).
run_log_header() {
  [[ -n "${RUN_LOG:-}" ]] || return 0
  if command -v gum >/dev/null 2>&1; then
    CLICOLOR_FORCE=1 gum style \
      --border double --border-foreground 39 --padding "0 2" \
      "$(CLICOLOR_FORCE=1 gum style --foreground 42 --bold 'power_failure_resumer — resume run')" \
      "$(CLICOLOR_FORCE=1 gum style --foreground 245 "$(date '+%Y-%m-%d %H:%M:%S')  driver=${DRIVER} mode=${OPEN_MODE}")" \
      >> "$RUN_LOG" 2>/dev/null && return 0
  fi
  {
    printf '╔══════════════════════════════════════════╗\n'
    printf '║  power_failure_resumer — resume run      ║\n'
    printf '╚══════════════════════════════════════════╝\n'
    printf '%s  driver=%s mode=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$DRIVER" "$OPEN_MODE"
  } >> "$RUN_LOG"
}

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

# Run a command with combined output on stdout, killing it after $1 seconds.
# Returns the command's status, or 124 on timeout. Bash 3.2 compatible.
run_bounded() {
  local secs="$1"; shift
  local out pid rc=0 waited=0 limit
  limit=$((secs * 10))
  out="$(tmpfile)"
  ( exec "$@" > "$out" 2>&1 ) &
  pid=$!
  while [[ "$waited" -lt "$limit" ]]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 0.2
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rc=124
  else
    wait "$pid" 2>/dev/null && rc=0 || rc=$?
  fi
  cat "$out"
  cleanup_files "$out"
  return "$rc"
}

tmpfile() {
  # Portable: macOS `mktemp -t prefix` does NOT expand XXXXXX the way GNU does.
  mktemp "${TMPDIR:-/tmp}/pfr.XXXXXX"
}

cleanup_files() {
  [[ "${PFR_KEEP_TEMPS:-0}" == "1" ]] && return 0
  local path
  for path in "$@"; do
    [[ -n "$path" ]] && rm -f -- "$path"
  done
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

# The macOS drivers open every queued surface in ONE osascript invocation.
# Each surface RUNS its command via the Ghostty surface `command` property in
# an interactive login shell (aliases apply) — nothing is typed at a prompt,
# so submission cannot race shell startup or die in bracketed paste.
# queue_open() collects entries; flush_opens() launches and reports per entry.
OPEN_CWDS=()
OPEN_CMDS=()

# Resolve a launch cwd, falling back like the old per-open path did.
resolved_cwd() {
  local cwd="$1"
  if [[ ! -d "$cwd" ]]; then
    warn "cwd missing, falling back to ~/projects: $cwd"
    cwd="${HOME}/projects"
    if [[ ! -d "$cwd" ]]; then
      cwd="${HOME}"
      warn "\$HOME/projects also missing; using \$HOME"
    fi
  fi
  printf '%s\n' "$cwd"
}

queue_open() {
  local cwd resume_cmd="$2"
  cwd="$(resolved_cwd "$1")"
  if (( DRY_RUN )); then
    printf '  DRY  cd %q && %s\n' "$cwd" "$resume_cmd"
  fi
  OPEN_CWDS+=("$cwd")
  OPEN_CMDS+=("$resume_cmd")
}

open_batch_ghostty() {
  # Linux: no scripting API — spawn one window per session via the ghostty CLI.
  # Interactive shell (-i) so cod/cc aliases from rc files resolve.
  # Commands are reconstructed from provider + validated UUID at the JSON/TSV
  # boundary. Escaping the whole string with %q would turn it into one command
  # name containing spaces instead of a command plus arguments.
  local idx
  BATCH_RESULTS=()
  for idx in "${!OPEN_CWDS[@]}"; do
    nohup ghostty --working-directory="${OPEN_CWDS[$idx]}" \
      -e "${SHELL:-/bin/sh}" -ic "${OPEN_CMDS[$idx]}" >/dev/null 2>&1 &
    disown 2>/dev/null || true
    # Spawn is asynchronous; launch failures surface through post-open verify.
    BATCH_RESULTS+=("ok")
    if [[ "$idx" -lt $(( ${#OPEN_CWDS[@]} - 1 )) ]]; then
      sleep "$DELAY_SECONDS"
    fi
  done
}

open_batch_osascript() {
  local script="$1" out idx
  local -a args=("$OPEN_MODE" "$SETTLE_SECONDS" "$DELAY_SECONDS" "${SHELL:-/bin/zsh}")
  for idx in "${!OPEN_CWDS[@]}"; do
    args+=("${OPEN_CWDS[$idx]}" "${OPEN_CMDS[$idx]}")
  done
  BATCH_RESULTS=()
  if out="$(osascript "$script" "${args[@]}")"; then
    while IFS= read -r line; do
      BATCH_RESULTS+=("$line")
    done <<< "$out"
  fi
  # Pad so a truncated or failed batch reports every remaining entry as failed.
  while [[ "${#BATCH_RESULTS[@]}" -lt "${#OPEN_CWDS[@]}" ]]; do
    BATCH_RESULTS+=("fail no result from batch open")
  done
}

# Launch all queued surfaces. Results land in BATCH_RESULTS (index-aligned
# with the queue): "ok", "ok fallback", or "fail <reason>".
flush_opens() {
  BATCH_RESULTS=()
  [[ "${#OPEN_CWDS[@]}" -eq 0 ]] && return 0
  if (( DRY_RUN )); then
    local idx
    for idx in "${!OPEN_CWDS[@]}"; do
      BATCH_RESULTS+=("ok")
    done
    return 0
  fi
  case "$DRIVER" in
    ui)      open_batch_osascript "$OPEN_UI_AS" ;;
    api)     open_batch_osascript "$OPEN_API_AS" ;;
    ghostty) open_batch_ghostty ;;
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
    --include-ntm) INCLUDE_NTM=1; shift ;;
    --ntm-history) need_arg "$@"; NTM_HISTORY="$2"; shift 2 ;;
    --ntm-data) need_arg "$@"; NTM_DATA="$2"; shift 2 ;;
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
    --notify) NOTIFY=1; shift ;;
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

if (( NOTIFY && (JSON_OUT || DOCTOR) )); then
  die "--notify cannot be combined with --json or --doctor"
fi
if (( NOTIFY )) && [[ -n "$PLAN_PATH" ]]; then
  die "--notify always runs fresh discovery; do not combine it with --plan or --last-plan"
fi
if (( NOTIFY && NO_SAVE_PLAN )); then
  die "--notify requires last-plan persistence; do not combine it with --no-save-plan"
fi

# --notify stops after discovery and optional notification. It must not depend
# on a launch driver or tab/window settings, including stale PFR_* values from
# an interactive recovery configuration.
if (( ! NOTIFY )); then
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
fi

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

  local state_parent="$STATE_DIR"
  while [[ ! -e "$state_parent" && "$state_parent" != "/" ]]; do
    state_parent="$(dirname "$state_parent")"
  done
  if [[ -d "$state_parent" && -w "$state_parent" && -x "$state_parent" ]]; then
    add_check state_dir ok "$STATE_DIR creatable/writable (via $state_parent)"
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
  if [[ -d "$codex_dir" ]]; then
    add_check codex_root ok "$codex_dir"
  else
    add_check codex_root warn "$codex_dir missing (no codex sessions will be found)"
  fi
  if [[ -d "$claude_dir" ]]; then
    add_check claude_root ok "$claude_dir"
  else
    add_check claude_root warn "$claude_dir missing (no claude sessions will be found)"
  fi

  if command -v fzf >/dev/null 2>&1; then
    add_check fzf ok "$(command -v fzf) (nicer --pick)"
  else
    add_check fzf warn "fzf not found — --pick falls back to numeric prompt"
  fi
  if command -v am >/dev/null 2>&1; then
    add_check agent_mail ok "am found — recovery will open an agent-mail tab first"
  else
    add_check agent_mail warn "am not found — no agent-mail tab (optional)"
  fi
  local ntm_hist="${NTM_HISTORY:-$HOME/.local/share/ntm/history.jsonl}"
  if [[ -f "$ntm_hist" ]]; then
    add_check ntm_history ok "$ntm_hist — ntm-spawned sessions excluded (--include-ntm to keep)"
  fi
  # Probe the user's login shell (the same kind resume tabs run in), with a
  # hard time bound: a hung rc file must not hang the doctor.
  local agent_cmds probe_shell probe_rc
  probe_shell="${SHELL:-/bin/zsh}"
  if [[ ! -x "$probe_shell" ]]; then
    add_check agent_commands warn "login shell not executable ($probe_shell); cannot probe cod/cc"
  elif agent_cmds="$(run_bounded 8 "$probe_shell" -lic 'type cod; type cc')"; then
    add_check agent_commands ok "$agent_cmds"
  else
    probe_rc=$?
    if [[ "$probe_rc" -eq 124 ]]; then
      add_check agent_commands warn "login-shell probe timed out after 8s (slow rc files?); check skipped"
    else
      add_check agent_commands warn "cod/cc not both resolvable in login shell ($probe_shell): $agent_cmds"
    fi
  fi

  local fails=0 i
  for i in "${!c_name[@]}"; do
    [[ "${c_status[$i]}" == "fail" ]] && fails=$((fails + 1))
  done

  if (( JSON_OUT )); then
    for i in "${!c_name[@]}"; do
      printf '%s\0%s\0%s\0' "${c_name[$i]}" "${c_status[$i]}" "${c_detail[$i]}"
    done | python3 -c '
import json, sys
checks = []
fields = sys.stdin.buffer.read().split(b"\0")
if fields and fields[-1] == b"":
    fields.pop()
if len(fields) % 3:
    raise SystemExit("invalid doctor record framing")
for offset in range(0, len(fields), 3):
    name, status, detail = (field.decode("utf-8", "replace") for field in fields[offset:offset + 3])
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
require_uint "--limit" "$LIMIT"
if (( ! NOTIFY )); then
  require_number "--settle" "$SETTLE_SECONDS"
  require_uint "--max" "$MAX_OPEN"

  # Per-driver default inter-surface delay if user did not set one. The macOS
  # drivers launch commands directly (no typing), so tabs can open fast.
  if [[ -z "$DELAY_SECONDS" ]]; then
    if [[ "$DRIVER" == "ghostty" ]]; then
      DELAY_SECONDS="0.35"
    else
      DELAY_SECONDS="0.10"
    fi
  fi
  require_number "--delay" "$DELAY_SECONDS"
fi

need_cmd python3
[[ -f "$DISCOVER_PY" ]] || die "missing $DISCOVER_PY"
if (( ! DRY_RUN && ! JSON_OUT && ! NOTIFY )); then
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
if (( INCLUDE_NTM )); then
  discover_args+=(--include-ntm)
fi
if [[ -n "$NTM_HISTORY" ]]; then
  discover_args+=(--ntm-history "$NTM_HISTORY")
fi
if [[ -n "$NTM_DATA" ]]; then
  discover_args+=(--ntm-data "$NTM_DATA")
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
  if (( ! NOTIFY )); then
    log "scanning sessions (providers=${PROVIDERS}, mode=${MODE}, window=${WINDOW_SECONDS}s)…"
  fi
  # discover.py: JSON on stdout, diagnostics on stderr — keep them separate.
  DISCOVER_ERR="$(tmpfile)"
  if ! JSON="$(python3 "$DISCOVER_PY" "${discover_args[@]}" 2>"$DISCOVER_ERR")"; then
    [[ -s "$DISCOVER_ERR" ]] && cat "$DISCOVER_ERR" >&2
    cleanup_files "$DISCOVER_ERR"
    die "discovery failed"
  fi
  [[ -s "$DISCOVER_ERR" ]] && cat "$DISCOVER_ERR" >&2
  cleanup_files "$DISCOVER_ERR"

  # --notify is discovery-only. Count only offered sessions, so the saved plan
  # always contains work that remains available for the user to pick.
  if (( NOTIFY )); then
    NOTIFY_COUNT="$(python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
sessions = data.get("sessions")
confidence = data.get("confidence")
if not isinstance(sessions, list):
    raise SystemExit(1)
count = len(sessions)
if count and (confidence == "high" or (confidence == "medium" and count >= 3)):
    print(count)
' <<<"$JSON")" || exit 0
    if [[ -z "$NOTIFY_COUNT" ]]; then
      exit 0
    fi
  fi

  # Persist the plan (discover once, open later) unless opted out.
  if (( ! NO_SAVE_PLAN )) || [[ -n "$SAVE_PLAN_PATH" ]]; then
    if [[ ! -f "$PLAN_PY" ]]; then
      warn "missing $PLAN_PY — plan not saved"
      PLAN_SAVED_TO=""
    else
      if (( NO_SAVE_PLAN )); then
        plan_save_args=(save --extra-only --extra-path "$SAVE_PLAN_PATH")
      else
        plan_save_args=(save --state-dir "$STATE_DIR")
        [[ -n "$SAVE_PLAN_PATH" ]] && plan_save_args+=(--extra-path "$SAVE_PLAN_PATH")
      fi
      if PLAN_INFO="$(printf '%s' "$JSON" | python3 "$PLAN_PY" "${plan_save_args[@]}" 2>/dev/null)"; then
        PLAN_SAVED_TO="$(printf '%s' "$PLAN_INFO" | python3 -c 'import json,sys; print(json.load(sys.stdin)["saved"])' 2>/dev/null || true)"
        if (( NOTIFY )) && [[ -z "$PLAN_SAVED_TO" ]]; then
          warn "could not confirm qualifying plan was saved; notification not sent"
          exit 1
        fi
      else
        if (( NOTIFY )); then
          warn "could not save qualifying plan; notification not sent"
          exit 1
        fi
        warn "could not save plan (continuing)"
        PLAN_SAVED_TO=""
      fi
    fi
  else
    PLAN_SAVED_TO=""
  fi
fi

send_notification() {
  local session_count="$1"
  local notification_body
  notification_body="${session_count} session(s) ready — run: pfr --last-plan --pick"

  if [[ -n "${PFR_NOTIFY_CMD:-}" ]]; then
    run_bounded 5 "$PFR_NOTIFY_CMD" "pfr" "$notification_body" >/dev/null 2>&1 || true
  elif [[ "$PLATFORM" == "Darwin" ]]; then
    run_bounded 5 osascript -e \
      'on run argv
  display notification (item 1 of argv) with title "pfr"
end run' -- "$notification_body" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    run_bounded 5 notify-send "pfr" "$notification_body" >/dev/null 2>&1 || true
  fi
}

if (( NOTIFY )); then
  send_notification "$NOTIFY_COUNT"
  exit 0
fi

if (( JSON_OUT )); then
  printf '%s\n' "$JSON"
  exit 0
fi

SESS_FILE="$(tmpfile)"
SELECTED_FILE="$(tmpfile)"
MAP_FILE=""
ORDERED_FILE=""
# DISCOVER_ERR already removed on the happy path; include it so early die still cleans up.
trap 'cleanup_files "$SESS_FILE" "$SELECTED_FILE" "$MAP_FILE" "$ORDERED_FILE" "$DISCOVER_ERR"' EXIT

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
    # Model/effort are authority-bearing (joined into the resume command), so
    # they pass the same strict validation here as in discover.py and plan.py.
    model = s.get("model") or ""
    effort = s.get("effort") or ""
    if not isinstance(model, str) or (model and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", model)):
        print(f"invalid session model at index {index}: {model!r}", file=sys.stderr)
        sys.exit(1)
    if not isinstance(effort, str) or (effort and not re.fullmatch(r"[a-z]{1,16}", effort)):
        print(f"invalid session effort at index {index}: {effort!r}", file=sys.stderr)
        sys.exit(1)
    if provider == "codex":
        resume_cmd = f"cod resume {sid}"
        if model:
            resume_cmd += f" -m {model}"
        if effort:
            resume_cmd += f" -c model_reasoning_effort={effort}"
    else:
        resume_cmd = f"cc --resume {sid}"
        if model:
            resume_cmd += f" --model {model}"
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
                clean(s.get("preview") or ""),
                clean(model),
                clean(effort),
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
print(clean(data.get("skipped_ntm") or 0))
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
SKIPPED_NTM="$(printf '%s\n' "$META" | sed -n '9p')"

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
if [[ "${SKIPPED_NTM:-0}" != "0" ]]; then
  log "skipped:       ${SKIPPED_NTM} ntm-spawned session(s)  (--include-ntm to include)"
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
while IFS=$'\t' read -r provider sid cwd mt resume_cmd title preview model effort || [[ -n "${provider:-}" ]]; do
  [[ -z "${provider:-}" ]] && continue
  n=$((n + 1))
  short_cwd="${cwd/#$HOME/~}"
  printf '%2d. %-6s  %-11s  %s\n' "$n" "$provider" "$mt" "$short_cwd"
  printf '      %s\n' "$resume_cmd"
  base="$(basename "$cwd")"
  if [[ -n "$title" && "$title" != "$base" ]]; then
    printf '      (%s)\n' "$title"
  fi
  if [[ -n "${preview:-}" && "$preview" != "$title" ]]; then
    printf '      » %.100s\n' "$preview"
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
    cleanup_files "$map"
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
ORDERED_FILE="$ORDER_TMP"

if (( ! DRY_RUN )) && [[ "$DRIVER" != "ghostty" ]]; then
  ensure_ghostty   # ghostty CLI driver spawns its own windows; no pre-launch needed
fi

# All surfaces (status tab, agent-mail, sessions) are queued and opened in a
# single batch: on macOS one osascript invocation opens every tab, each
# running its command directly. Queue order is tab order.

# Tab 1 — live status: a Ghostty tab tailing this run's formatted log so the
# whole resume is observable as it happens. Disable with PFR_STATUS_TAB=0.
STATUS_QUEUED=0
AM_QUEUED=0
if [[ "${PFR_STATUS_TAB:-1}" != "0" ]]; then
  RUN_LOG="${STATE_DIR}/run-$(date +%Y%m%d_%H%M%S)-$$.log"
  if (( DRY_RUN )); then
    status_cmd="$(printf 'tail -n +1 -f %q' "$RUN_LOG")"
    queue_open "$HOME" "$status_cmd"
    STATUS_QUEUED=1
    RUN_LOG=""
  elif mkdir -p "$STATE_DIR" 2>/dev/null \
      && chmod 700 "$STATE_DIR" 2>/dev/null \
      && (umask 077; : > "$RUN_LOG") 2>/dev/null; then
    # Keep the newest 10 run logs; these are per-run and would pile up forever.
    # shellcheck disable=SC2012  # filenames are self-generated, no odd chars
    ls -1t "$STATE_DIR"/run-*.log 2>/dev/null | tail -n +11 | while IFS= read -r old_log; do
      rm -f -- "$old_log"
    done
    run_log_header
    log "run log: ${RUN_LOG}"
    status_cmd="$(printf 'tail -n +1 -f %q' "$RUN_LOG")"
    queue_open "$HOME" "$status_cmd"
    STATUS_QUEUED=1
  else
    RUN_LOG=""
  fi
fi

# Tab 2 — agent-mail: when `am` is installed, open it before any resumes.
# Disable with PFR_AM=0; PFR_AM_BIN overrides the binary (tests).
AM_BIN="${PFR_AM_BIN:-am}"
if [[ "${PFR_AM:-1}" != "0" && -n "$AM_BIN" ]] && command -v "$AM_BIN" >/dev/null 2>&1; then
  queue_open "$HOME" "$AM_BIN"
  AM_QUEUED=1
fi

if (( DRY_RUN )); then
  log "dry-run plan (${SEL_COUNT} ${OPEN_MODE}(s), driver=${DRIVER}):"
else
  log "opening ${SEL_COUNT} Ghostty ${OPEN_MODE}(s) via driver=${DRIVER}…"
  if [[ "$DRIVER" == "ui" ]]; then
    log "Commands launch directly in each tab; keystroke fallback needs Accessibility."
  fi
fi

ATTEMPTS_FILE="$(tmpfile)"
SESSION_PROVIDERS=()
SESSION_SIDS=()
SESSION_CWDS=()
i=0
# shellcheck disable=SC2034  # model/effort terminate the TSV record; resume_cmd already carries them
while IFS=$'\t' read -r provider sid cwd mt resume_cmd title preview model effort || [[ -n "${provider:-}" ]]; do
  [[ -z "${provider:-}" ]] && continue
  i=$((i + 1))
  short_cwd="${cwd/#$HOME/~}"
  printf '  [%d/%d] %s  %s\n' "$i" "$SEL_COUNT" "$provider" "$short_cwd"
  queue_open "$cwd" "$resume_cmd"
  SESSION_PROVIDERS+=("$provider")
  SESSION_SIDS+=("$sid")
  SESSION_CWDS+=("$cwd")
done < "$ORDERED_FILE"

flush_opens

# Map batch results back: entries before the sessions are status/agent-mail.
PRE_COUNT=$((STATUS_QUEUED + AM_QUEUED))
if (( ! DRY_RUN )); then
  if (( STATUS_QUEUED )) && [[ "${BATCH_RESULTS[0]}" != ok* ]]; then
    warn "failed to open status tab (${BATCH_RESULTS[0]#fail })"
  fi
  if (( AM_QUEUED )) && [[ "${BATCH_RESULTS[$STATUS_QUEUED]}" != ok* ]]; then
    warn "failed to open agent-mail tab (${BATCH_RESULTS[$STATUS_QUEUED]#fail })"
  fi
fi
for idx in "${!SESSION_SIDS[@]}"; do
  result="${BATCH_RESULTS[$((PRE_COUNT + idx))]:-fail missing result}"
  provider="${SESSION_PROVIDERS[$idx]}"
  sid="${SESSION_SIDS[$idx]}"
  cwd="${SESSION_CWDS[$idx]}"
  if [[ "$result" == ok* ]]; then
    OPEN_OKS=$((OPEN_OKS + 1))
    printf '%s\t%s\t%s\t1\n' "$provider" "$sid" "$cwd" >> "$ATTEMPTS_FILE"
  else
    OPEN_FAILS=$((OPEN_FAILS + 1))
    printf '%s\t%s\t%s\t0\n' "$provider" "$sid" "$cwd" >> "$ATTEMPTS_FILE"
    warn "failed to open: $provider $sid (${cwd/#$HOME/~}): ${result#fail }"
  fi
done

echo
if (( DRY_RUN )); then
  cleanup_files "$ATTEMPTS_FILE"
  log "dry-run complete — re-run with -y (or answer y) to open."
  if [[ -n "$PLAN_SAVED_TO" ]]; then
    log "plan saved: ${PLAN_SAVED_TO}  (confidence=${CONFIDENCE}, ${SEL_COUNT} sessions)"
    log "next: pfr --last-plan -y   or   pfr --last-plan --pick"
  fi
else
  log "done: ${OPEN_OKS} opened, ${OPEN_FAILS} failed (of ${SEL_COUNT})."
  VERIFY_RC=0
  if [[ "${PFR_VERIFY:-1}" != "0" ]]; then
    require_number "PFR_VERIFY_TIMEOUT" "${PFR_VERIFY_TIMEOUT:-15}"
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
  cleanup_files "$ATTEMPTS_FILE"
  if (( OPEN_FAILS > 0 )); then
    warn "partial resume — re-run with --pick for the failures."
    exit 1
  fi
  if (( VERIFY_RC != 0 )); then
    exit 1
  fi
  log "tip: if a tab only shows a shell, press Up or re-run with a larger --settle."
fi
