#!/usr/bin/env bash
# Hi-Terms — BEL handling smoke (Wave 2-C, manual)
#
# Walks the operator through verifying:
#   1. BEL fires the visual flash overlay
#   2. Bursts of bells inside ~200 ms collapse to a single visible flash
#   3. Backgrounded app posts a system notification (default config: visual only)
#
# Run from any terminal:  ./Tools/smoke-bell.sh
# Optional: HITERMS_APP=/path/to/HiTerms.app ./Tools/smoke-bell.sh

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

step "1. Launch Hi-Terms"
if [[ -d "${HITERMS_APP}" ]]; then
  open "${HITERMS_APP}"
  ok "Launched"
fi
read -r -p "Press <Enter> when focused..." _

step "2. Single BEL → visual flash"
note "Paste this into Hi-Terms; expect one quick white pulse on the window."
cat <<'FIX'
--- copy into Hi-Terms ↓ ---
printf '\a'
--- end ---
FIX
read -r -p "Press <Enter> when you see the flash..." _

step "3. Burst BELs → collapsed to one flash"
note "Paste this; despite firing 10 BELs in ~50 ms, you should see ONE"
note "flash, not ten flickers (200 ms throttle)."
cat <<'FIX'
--- copy into Hi-Terms ↓ ---
for i in $(seq 1 10); do printf '\a'; done
--- end ---
FIX
read -r -p "Press <Enter> when behavior confirmed..." _

step "4. Backgrounded BEL → system notification"
note "Default config is .visual (no notification). To exercise the"
note "notification path, change AppConfig.bellBehavior to"
note ".visualAndNotification, rebuild, then:"
note "  - move focus to another app (Cmd-Tab)"
note "  - in another terminal: osascript -e 'tell app \"HiTerms\" to activate'"
note "  - run 'printf \\a' inside Hi-Terms via send keys, then Cmd-Tab away"
note "Expected: a Hi-Terms banner appears in Notification Center."
read -r -p "Press <Enter> when manual notification check is done..." _

step "Smoke complete"
ok "BEL throttling + visual flash look correct."
