#!/usr/bin/env bash
# install.sh must run under /bin/bash 3.2, the shell `curl | bash` gets on stock
# macOS. Under `set -u`, bash < 4.4 treats an empty array expanded as
# "${name[@]}" as unbound (PROXY_ARGS is empty when no proxy is set), so every
# array expansion must use ${name[@]+"${name[@]}"}. bash 3.2 also has no
# mapfile/readarray.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$PFR_ROOT/install.sh"
bare="$(grep -nE '(^|[^+])"\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\}"' "$INSTALLER" \
  | grep -vE '\$\{(BASH_SOURCE|BASH_LINENO|FUNCNAME|PIPESTATUS|BASH_REMATCH)\[@\]\}' || true)"
[[ -z "$bare" ]] || fail "install.sh has bare array expansions (unbound on bash 3.2 under set -u): $bare"
if grep -nE '^[^#]*\b(mapfile|readarray)\b' "$INSTALLER"; then
  fail "install.sh uses mapfile/readarray, which bash 3.2 lacks"
fi

echo "install bash 3.2 compatibility OK"
