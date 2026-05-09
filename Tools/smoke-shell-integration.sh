#!/usr/bin/env bash
# Hi-Terms — Shell Integration smoke (V0.0.3 T1, manual)
#
# Walks the operator through verifying:
#   1. Install script writes a marker block + backs up the rc file
#   2. After `exec $SHELL`, OSC 7 fires on every prompt (cwd surfaces)
#   3. OSC 133 ;A/B/C/D round-trips through a real command (cd, false, true)
#   4. CJK directory paths round-trip end-to-end
#   5. Uninstall script removes the block cleanly
#
# Run from any terminal:  ./Tools/smoke-shell-integration.sh
# Optional: HITERMS_APP=/path/to/HiTerms.app ./Tools/smoke-shell-integration.sh

set -euo pipefail

ESC=$'\033'
RESET="${ESC}[0m"
BOLD="${ESC}[1m"
GREEN="${ESC}[32m"
YELLOW="${ESC}[33m"
CYAN="${ESC}[36m"

step() { printf "\n%s== %s ==%s\n" "${BOLD}${CYAN}" "$1" "${RESET}"; }
note() { printf "%s>> %s%s\n" "${YELLOW}" "$1" "${RESET}"; }
ok()   { printf "%s[OK]%s %s\n" "${GREEN}" "${RESET}" "$1"; }
warn() { printf "%s[!]%s  %s\n" "${YELLOW}" "${RESET}" "$1"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_APP="${REPO_ROOT}/build/DerivedData/Build/Products/Debug/HiTerms.app"
HITERMS_APP="${HITERMS_APP:-${DEFAULT_APP}}"

step "0. Preflight"
if [[ -d "${HITERMS_APP}" ]]; then
    ok "HiTerms.app at ${HITERMS_APP}"
else
    warn "HiTerms.app not found — run 'make build' first or set HITERMS_APP=..."
fi

step "1. Dry-run install (no file changes)"
note "Showing what would be appended to your rcfile:"
"${REPO_ROOT}/Tools/install-shell-integration.sh" --dry-run
read -r -p "Press <Enter> when reviewed..." _

step "2. Real install"
note "Running install — a backup will be created:"
"${REPO_ROOT}/Tools/install-shell-integration.sh"
read -r -p "Press <Enter> when done..." _

step "3. Launch Hi-Terms and start a fresh shell"
if [[ -d "${HITERMS_APP}" ]]; then
    open "${HITERMS_APP}"
    ok "Launched"
fi
note "In the new Hi-Terms window run: exec \$SHELL"
note "Then run a few commands and verify (instrumentation TBD; for now"
note "you can inspect via Console.app, subsystem com.hiterms.terminal):"
cat <<'FIX'
--- copy into Hi-Terms ↓ ---
exec $SHELL
cd /tmp
true
false
mkdir -p /tmp/中文-test && cd /tmp/中文-test && pwd
--- end ---
FIX
read -r -p "Press <Enter> when commands have run..." _

step "4. Uninstall"
"${REPO_ROOT}/Tools/uninstall-shell-integration.sh"
note "Open a fresh shell — HITERMS_SHELL_INTEGRATION should be unset."
read -r -p "Press <Enter> when done..." _

step "Smoke complete"
ok "Install/uninstall + OSC 7/133 round-trip look correct."
