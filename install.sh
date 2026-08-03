#!/usr/bin/env bash
# power_failure_resumer installer
#
# Install with:
#   curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/power_failure_resumer/main/install.sh?$(date +%s)" | bash
#
# Flags (pass after `bash -s --` when curl-piping):
#   --easy-mode        Also add ~/.local/bin to PATH in your shell rc files
#   --prefix DIR       Install root (default: ~/.local/share/pfr)
#   --bin-dir DIR      Symlink dir for `pfr` (default: ~/.local/bin)
#   --ref REF          Git ref / branch / tag to install (default: main)
#   --offline TARBALL  Install from a local repo tarball (airgap)
#   --force            Reinstall even if the same version is present
#   --quiet            Only errors
#   --no-gum           Plain ANSI output even if gum is installed
#   --verify           Run `pfr --doctor` after install
#
# Note: this project ships as scripts (bash + python + applescript), not
# compiled binaries, so there is no per-artifact SHA256/sigstore step; the
# tarball comes straight from GitHub over TLS pinned to one repo/ref.
set -euo pipefail
shopt -s lastpipe 2>/dev/null || true
umask 022

REPO_OWNER="Dicklesworthstone"
REPO_NAME="power_failure_resumer"
REF="main"
PREFIX="${HOME}/.local/share/pfr"
BIN_DIR="${HOME}/.local/bin"
EASY=0
FORCE=0
QUIET=0
NO_GUM=0
VERIFY=0
OFFLINE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --easy-mode) EASY=1; shift ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --bin-dir) BIN_DIR="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --offline) OFFLINE="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --quiet) QUIET=1; shift ;;
    --no-gum) NO_GUM=1; shift ;;
    --verify) VERIFY=1; shift ;;
    -h|--help)
      sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown flag: $1 (see --help)" >&2; exit 2 ;;
  esac
done

# ── output stack: gum when available, ANSI fallback ─────────────────────────
HAS_GUM=0
if command -v gum >/dev/null 2>&1 && [[ -t 1 ]]; then
  HAS_GUM=1
fi
use_gum() { [[ "$HAS_GUM" -eq 1 && "$NO_GUM" -eq 0 ]]; }

info() {
  [[ "$QUIET" -eq 1 ]] && return 0
  if use_gum; then gum style --foreground 39 "-> $*"; else echo -e "\033[0;34m->\033[0m $*"; fi
}
ok() {
  [[ "$QUIET" -eq 1 ]] && return 0
  if use_gum; then gum style --foreground 42 "ok $*"; else echo -e "\033[0;32mok\033[0m $*"; fi
}
warn() {
  [[ "$QUIET" -eq 1 ]] && return 0
  if use_gum; then gum style --foreground 214 "!! $*"; else echo -e "\033[1;33m!!\033[0m $*"; fi
}
err() {
  if use_gum; then gum style --foreground 196 "xx $*" >&2; else echo -e "\033[0;31mxx\033[0m $*" >&2; fi
}

run_with_spinner() {
  local title="$1"; shift
  if use_gum && [[ "$QUIET" -eq 0 ]]; then
    gum spin --spinner dot --title "$title" -- "$@"
  else
    info "$title"
    "$@"
  fi
}

draw_box() {
  local color="$1"; shift
  local lines=("$@") width=0 stripped line
  for line in "${lines[@]}"; do
    stripped="$(printf '%s' "$line" | sed 's/\x1b\[[0-9;]*m//g')"
    (( ${#stripped} > width )) && width=${#stripped}
  done
  local border
  border="$(printf '═%.0s' $(seq 1 $((width + 2))))"
  printf '\033[%sm╔%s╗\033[0m\n' "$color" "$border"
  for line in "${lines[@]}"; do
    stripped="$(printf '%s' "$line" | sed 's/\x1b\[[0-9;]*m//g')"
    printf '\033[%sm║\033[0m %s%*s \033[%sm║\033[0m\n' \
      "$color" "$line" $((width - ${#stripped})) "" "$color"
  done
  printf '\033[%sm╚%s╝\033[0m\n' "$color" "$border"
}

banner() {
  [[ "$QUIET" -eq 1 ]] && return 0
  if use_gum; then
    gum style --border normal --border-foreground 39 --padding "0 1" --margin "1 0" \
      "$(gum style --foreground 42 --bold 'power_failure_resumer installer')" \
      "$(gum style --foreground 245 'Resume your Codex/Claude Ghostty tabs after a power failure')"
  else
    draw_box "0;36" \
      $'\033[1;32mpower_failure_resumer installer\033[0m' \
      $'\033[0;90mResume your Codex/Claude Ghostty tabs after a power failure\033[0m'
  fi
}

# ── proxy support ───────────────────────────────────────────────────────────
PROXY_ARGS=()
if [[ -n "${HTTPS_PROXY:-}" ]]; then
  PROXY_ARGS=(--proxy "$HTTPS_PROXY")
elif [[ -n "${HTTP_PROXY:-}" ]]; then
  PROXY_ARGS=(--proxy "$HTTP_PROXY")
fi

# ── platform detection ──────────────────────────────────────────────────────
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$OS" in
  darwin) ;;
  linux)
    if grep -qi microsoft /proc/version 2>/dev/null; then
      warn "WSL detected — Ghostty automation will need an X/Wayland-capable setup"
    fi
    ;;
  *) err "unsupported platform: $OS (need macOS or Linux)"; exit 1 ;;
esac

# ── preflight ───────────────────────────────────────────────────────────────
preflight() {
  info "Running preflight checks"
  command -v python3 >/dev/null 2>&1 || { err "python3 is required"; exit 1; }
  command -v tar >/dev/null 2>&1 || { err "tar is required"; exit 1; }
  local avail_kb
  avail_kb="$(df -Pk "${HOME}" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ -n "$avail_kb" && "$avail_kb" -lt 10240 ]]; then
    err "less than 10MB free in \$HOME"; exit 1
  fi
  mkdir -p "$PREFIX" "$BIN_DIR" 2>/dev/null || { err "cannot create $PREFIX / $BIN_DIR"; exit 1; }
  [[ -w "$PREFIX" && -w "$BIN_DIR" ]] || { err "$PREFIX or $BIN_DIR not writable"; exit 1; }
  if [[ -z "$OFFLINE" ]] && command -v curl >/dev/null 2>&1; then
    if ! curl -fsSL "${PROXY_ARGS[@]}" --connect-timeout 5 -o /dev/null \
        "https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/main" 2>/dev/null; then
      warn "network check to GitHub failed — download may not work (try --offline)"
    fi
  fi
}

# ── atomic lock ─────────────────────────────────────────────────────────────
LOCK_DIR="${TMPDIR:-/tmp}/pfr-install.lock"
TEMP_DIR=""
cleanup() {
  [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
  [[ -d "$LOCK_DIR" && -f "$LOCK_DIR/pid" && "$(cat "$LOCK_DIR/pid" 2>/dev/null)" == "$$" ]] \
    && rm -rf "$LOCK_DIR"
  return 0
}
take_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_DIR/pid"
    return 0
  fi
  local old_pid
  old_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ -n "$old_pid" ]] && ! kill -0 "$old_pid" 2>/dev/null; then
    warn "removing stale install lock (pid $old_pid)"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" && echo "$$" > "$LOCK_DIR/pid"
    return 0
  fi
  err "another install is running (lock: $LOCK_DIR)"; exit 1
}

# ── acquire + install ───────────────────────────────────────────────────────
fetch_tree() {
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pfr-install.XXXXXX")"
  local tarball="$TEMP_DIR/repo.tar.gz"
  if [[ -n "$OFFLINE" ]]; then
    [[ -f "$OFFLINE" ]] || { err "offline tarball not found: $OFFLINE"; exit 1; }
    cp "$OFFLINE" "$tarball"
  else
    local url="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/${REF}"
    run_with_spinner "Downloading ${REPO_NAME}@${REF}" \
      curl -fsSL "${PROXY_ARGS[@]}" -o "$tarball" "$url" \
      || { err "download failed: $url"; exit 1; }
  fi
  run_with_spinner "Extracting" tar -xzf "$tarball" -C "$TEMP_DIR"
  SRC_DIR="$(find "$TEMP_DIR" -maxdepth 1 -mindepth 1 -type d | head -1)"
  [[ -f "$SRC_DIR/power_failure_resumer.sh" ]] || { err "tarball layout unexpected"; exit 1; }
}

install_tree() {
  local staged="${PREFIX}.staging.$$"
  rm -rf "$staged"
  mkdir -p "$staged"
  cp -R "$SRC_DIR/power_failure_resumer.sh" "$SRC_DIR/lib" "$staged/"
  [[ -d "$SRC_DIR/docs" ]] && cp -R "$SRC_DIR/docs" "$staged/"
  chmod 0755 "$staged/power_failure_resumer.sh"
  # Atomic-ish swap: old tree moved aside, staged moved in, old removed.
  if [[ -d "$PREFIX" ]]; then
    rm -rf "${PREFIX}.old"
    mv "$PREFIX" "${PREFIX}.old"
  fi
  mv "$staged" "$PREFIX"
  rm -rf "${PREFIX}.old"
  ln -sf "$PREFIX/power_failure_resumer.sh" "$BIN_DIR/pfr"
  ok "installed to $PREFIX  (pfr -> $BIN_DIR/pfr)"
}

installed_version() {
  # The script tree has no embedded version; use the content hash of the CLI.
  if [[ -f "$PREFIX/power_failure_resumer.sh" ]]; then
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$PREFIX/power_failure_resumer.sh" | cut -c1-12
    else
      shasum -a 256 "$PREFIX/power_failure_resumer.sh" | cut -c1-12
    fi
  fi
}

maybe_add_path() {
  case ":$PATH:" in
    *:"$BIN_DIR":*) return 0 ;;
  esac
  if [[ "$EASY" -eq 1 ]]; then
    local rc added=0
    for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
      if [[ -e "$rc" && -w "$rc" ]] && ! grep -qs "$BIN_DIR" "$rc"; then
        printf '\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >> "$rc"
        added=1
      fi
    done
    (( added )) && ok "added $BIN_DIR to PATH in shell rc (restart your shell)"
  else
    warn "$BIN_DIR is not in PATH — add it, or re-run with --easy-mode"
  fi
}

summary() {
  [[ "$QUIET" -eq 1 ]] && return 0
  local lines=(
    "pfr installed:   $BIN_DIR/pfr"
    "install root:    $PREFIX"
    "first steps:     pfr --doctor        # health check"
    "                 pfr --dry-run       # inspect crash cluster"
    "                 pfr -y              # reopen everything"
    "uninstall:       rm -rf '$PREFIX' '$BIN_DIR/pfr'"
  )
  if use_gum; then
    gum style --border rounded --border-foreground 42 --padding "0 2" --margin "1 0" \
      "${lines[@]}"
  else
    draw_box "0;32" "${lines[@]}"
  fi
}

main() {
  banner
  preflight
  take_lock
  trap cleanup EXIT

  local before after
  before="$(installed_version || true)"
  fetch_tree

  if [[ "$FORCE" -eq 0 && -n "$before" ]]; then
    local incoming
    if command -v sha256sum >/dev/null 2>&1; then
      incoming="$(sha256sum "$SRC_DIR/power_failure_resumer.sh" | cut -c1-12)"
    else
      incoming="$(shasum -a 256 "$SRC_DIR/power_failure_resumer.sh" | cut -c1-12)"
    fi
    if [[ "$incoming" == "$before" ]]; then
      ok "already up to date (content $before) — use --force to reinstall"
      maybe_add_path
      summary
      return 0
    fi
  fi

  install_tree
  after="$(installed_version || true)"
  [[ -n "$before" && "$before" != "$after" ]] && info "updated ${before} -> ${after}"
  maybe_add_path

  if [[ "$VERIFY" -eq 1 ]]; then
    info "running post-install doctor"
    "$BIN_DIR/pfr" --doctor || warn "doctor reported problems — see above"
  fi
  summary
}

main "$@"
