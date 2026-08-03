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
# compiled binaries. Online installs download the selected repository ref over
# TLS. For reproducible installs, pass an immutable commit SHA with --ref.
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

usage() {
  cat <<'EOF'
power_failure_resumer installer

Usage: install.sh [OPTIONS]

Options:
  --easy-mode        Also add the bin directory to PATH in shell rc files
  --prefix DIR       Install root (default: ~/.local/share/pfr)
  --bin-dir DIR      Symlink directory for pfr (default: ~/.local/bin)
  --ref REF          Git ref, branch, tag, or commit (default: main)
  --offline TARBALL  Install from a local repository tarball
  --force            Reinstall even if the installed tree is unchanged
  --quiet            Print errors only
  --no-gum           Use plain ANSI output even if gum is installed
  --verify           Run pfr --doctor after installation
  -h, --help         Show this help
EOF
}

require_value() {
  local option="$1" value="${2:-}"
  if [[ -z "$value" || "$value" == -* ]]; then
    echo "$option requires a value" >&2
    usage >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --easy-mode) EASY=1; shift ;;
    --prefix) require_value "$1" "${2:-}"; PREFIX="$2"; shift 2 ;;
    --bin-dir) require_value "$1" "${2:-}"; BIN_DIR="$2"; shift 2 ;;
    --ref) require_value "$1" "${2:-}"; REF="$2"; shift 2 ;;
    --offline) require_value "$1" "${2:-}"; OFFLINE="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --quiet) QUIET=1; shift ;;
    --no-gum) NO_GUM=1; shift ;;
    --verify) VERIFY=1; shift ;;
    -h|--help) usage; exit 0 ;;
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
  local lines=("$@") width=0 stripped line esc border="" i
  esc="$(printf '\033')"
  for line in "${lines[@]}"; do
    stripped="$(printf '%s' "$line" | LC_ALL=C sed "s/${esc}\\[[0-9;]*m//g")"
    (( ${#stripped} > width )) && width=${#stripped}
  done
  for ((i=0; i<width + 2; i++)); do border+="═"; done
  printf '\033[%sm╔%s╗\033[0m\n' "$color" "$border"
  for line in "${lines[@]}"; do
    stripped="$(printf '%s' "$line" | LC_ALL=C sed "s/${esc}\\[[0-9;]*m//g")"
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
  if [[ -z "$OFFLINE" ]]; then
    command -v curl >/dev/null 2>&1 || { err "curl is required for online installs"; exit 1; }
    if [[ ! "$REF" =~ ^[A-Za-z0-9._/-]+$ || "$REF" == *..* || "$REF" == /* || "$REF" == */ ]]; then
      err "invalid --ref: $REF"
      exit 2
    fi
  fi
  [[ "$PREFIX" == /* && "$BIN_DIR" == /* ]] || {
    err "--prefix and --bin-dir must be absolute paths"; exit 2;
  }
  [[ "$PREFIX" != "/" && "$BIN_DIR" != "/" ]] || {
    err "refusing to install into the filesystem root"; exit 2;
  }
  local avail_kb
  avail_kb="$(df -Pk "${HOME}" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ -n "$avail_kb" && "$avail_kb" -lt 10240 ]]; then
    err "less than 10MB free in \$HOME"; exit 1
  fi
  mkdir -p "$(dirname "$PREFIX")" "$BIN_DIR" 2>/dev/null || {
    err "cannot create install parent / $BIN_DIR"; exit 1;
  }
  [[ -w "$(dirname "$PREFIX")" && -w "$BIN_DIR" ]] || {
    err "install parent or $BIN_DIR is not writable"; exit 1;
  }
  if [[ -e "$PREFIX" || -L "$PREFIX" ]]; then
    [[ -d "$PREFIX" && ! -L "$PREFIX" ]] || {
      err "install root exists but is not a real directory: $PREFIX"; exit 1;
    }
    if [[ ! -f "$PREFIX/.pfr-install" ]]; then
      if [[ ! -f "$PREFIX/power_failure_resumer.sh" || ! -f "$PREFIX/lib/discover.py" ]]; then
        err "refusing to replace an unrelated directory: $PREFIX"
        exit 1
      fi
    fi
  fi
  local link_path="$BIN_DIR/pfr"
  if [[ -e "$link_path" || -L "$link_path" ]]; then
    if [[ ! -L "$link_path" || "$(readlink "$link_path" 2>/dev/null || true)" != "$PREFIX/power_failure_resumer.sh" ]]; then
      err "refusing to replace unrelated path: $link_path"
      exit 1
    fi
  fi
  if [[ -z "$OFFLINE" ]]; then
    if ! curl -fsSL "${PROXY_ARGS[@]}" --connect-timeout 5 -o /dev/null \
        "https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/${REF}" 2>/dev/null; then
      warn "network check to GitHub failed — download may not work (try --offline)"
    fi
  fi
}

# ── atomic lock ─────────────────────────────────────────────────────────────
LOCK_DIR="${PFR_INSTALL_LOCK_DIR:-${TMPDIR:-/tmp}/pfr-install.lock}"
TEMP_DIR=""
STAGED_DIR=""
cleanup() {
  [[ "${PFR_INSTALLER_KEEP_TEMPS:-0}" == "1" ]] && return 0
  [[ -n "$STAGED_DIR" && -d "$STAGED_DIR" ]] && rm -rf "$STAGED_DIR"
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
      curl --proto '=https' --tlsv1.2 -fsSL "${PROXY_ARGS[@]}" -o "$tarball" "$url" \
      || { err "download failed: $url"; exit 1; }
  fi
  info "Validating and extracting archive"
  SRC_DIR="$(python3 - "$tarball" "$TEMP_DIR" <<'PY'
import sys
import tarfile
from pathlib import PurePosixPath

archive, destination = sys.argv[1:]
with tarfile.open(archive, "r:gz") as tf:
    members = [
        m for m in tf.getmembers()
        # macOS bsdtar adds AppleDouble (._*) companions for files with
        # xattrs; ignore them (and .DS_Store) instead of failing validation.
        if not PurePosixPath(m.name).name.startswith("._")
        and PurePosixPath(m.name).name != ".DS_Store"
    ]
    if not members or len(members) > 10_000:
        raise SystemExit("archive has an invalid member count")
    roots = set()
    total = 0
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or not path.parts:
            raise SystemExit(f"unsafe archive member: {member.name!r}")
        roots.add(path.parts[0])
        if not (member.isfile() or member.isdir()):
            raise SystemExit(f"unsupported archive member type: {member.name!r}")
        total += member.size
        if member.size > 20 * 1024 * 1024 or total > 100 * 1024 * 1024:
            raise SystemExit("archive is unexpectedly large")
    if len(roots) != 1:
        raise SystemExit("archive must contain exactly one top-level directory")
    tf.extractall(destination, members=members)
    print(str(PurePosixPath(destination) / next(iter(roots))))
PY
)" || { err "archive validation or extraction failed"; exit 1; }
  [[ -f "$SRC_DIR/power_failure_resumer.sh" ]] || { err "tarball layout unexpected"; exit 1; }
  [[ -f "$SRC_DIR/lib/discover.py" && -f "$SRC_DIR/lib/plan.py" &&
     -f "$SRC_DIR/lib/confidence.py" && -f "$SRC_DIR/lib/verify.py" ]] || {
    err "tarball is missing required library files"; exit 1;
  }
}

install_tree() {
  local backup="" link_path="$BIN_DIR/pfr" link_tmp="$BIN_DIR/.pfr-link.$$"
  STAGED_DIR="$(mktemp -d "${PREFIX}.staging.XXXXXX")"
  cp -R "$SRC_DIR/power_failure_resumer.sh" "$SRC_DIR/lib" "$STAGED_DIR/"
  [[ -d "$SRC_DIR/docs" ]] && cp -R "$SRC_DIR/docs" "$STAGED_DIR/"
  printf '%s/%s\n' "$REPO_OWNER" "$REPO_NAME" > "$STAGED_DIR/.pfr-install"
  chmod 0755 "$STAGED_DIR/power_failure_resumer.sh"
  # Swap only after the complete tree is staged. Keep the previous tree until
  # both the move and launcher update succeed so a failed upgrade can roll back.
  if [[ -d "$PREFIX" ]]; then
    backup="${PREFIX}.backup.$(date +%Y%m%d%H%M%S).$$"
    mv "$PREFIX" "$backup"
  fi
  if ! mv "$STAGED_DIR" "$PREFIX"; then
    [[ -n "$backup" && -d "$backup" ]] && mv "$backup" "$PREFIX"
    err "failed to activate staged install"
    exit 1
  fi
  STAGED_DIR=""
  if ! ln -s "$PREFIX/power_failure_resumer.sh" "$link_tmp" ||
     ! mv -f "$link_tmp" "$link_path"; then
    [[ -L "$link_tmp" ]] && rm -f "$link_tmp"
    rm -rf "$PREFIX"
    [[ -n "$backup" && -d "$backup" ]] && mv "$backup" "$PREFIX"
    err "failed to install launcher; previous tree restored"
    exit 1
  fi
  if [[ -n "$backup" && -d "$backup" ]]; then
    if [[ "${PFR_INSTALLER_KEEP_TEMPS:-0}" == "1" ]]; then
      info "retained previous install at $backup"
    else
      rm -rf "$backup"
    fi
  fi
  ok "installed to $PREFIX  (pfr -> $BIN_DIR/pfr)"
}

tree_version() {
  local root="$1"
  [[ -f "$root/power_failure_resumer.sh" && -d "$root/lib" ]] || return 1
  python3 - "$root" <<'PY'
import hashlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
paths = [root / "power_failure_resumer.sh"]
for dirname in ("lib", "docs"):
    base = root / dirname
    if base.is_dir():
        paths.extend(path for path in base.rglob("*") if path.is_file())
digest = hashlib.sha256()
for path in sorted(paths, key=lambda item: item.relative_to(root).as_posix()):
    rel = path.relative_to(root).as_posix().encode()
    digest.update(len(rel).to_bytes(4, "big"))
    digest.update(rel)
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
print(digest.hexdigest()[:12])
PY
}

installed_version() {
  tree_version "$PREFIX"
}

maybe_add_path() {
  case ":$PATH:" in
    *:"$BIN_DIR":*) return 0 ;;
  esac
  if [[ "$EASY" -eq 1 ]]; then
    local rc added=0
    for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
      if [[ -e "$rc" && -w "$rc" ]] && ! grep -Fqs "$BIN_DIR" "$rc"; then
        # $PATH must remain literal for expansion by future interactive shells.
        # shellcheck disable=SC2016
        printf '\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >> "$rc"
        added=1
      fi
    done
    if (( added )); then
      ok "added $BIN_DIR to PATH in shell rc (restart your shell)"
    else
      warn "no writable .zshrc or .bashrc found; add $BIN_DIR to PATH manually"
    fi
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
    "uninstall paths: $PREFIX and $BIN_DIR/pfr"
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
    incoming="$(tree_version "$SRC_DIR")"
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
