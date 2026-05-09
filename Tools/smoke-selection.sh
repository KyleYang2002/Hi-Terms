#!/usr/bin/env bash
# Hi-Terms — Selection + Copy smoke (Wave 2-A, manual)
#
# Walks the operator through verifying mouse-driven selection and Cmd+C copy:
#   1. Off-mode shell — drag selects, Cmd+C copies into the system pasteboard
#   2. Mouse-mode + Option override — selection still works under e.g. vim
#   3. Word + line snap (double + triple click)
#
# Run from any terminal:  ./Tools/smoke-selection.sh
# Optional: HITERMS_APP=/path/to/HiTerms.app ./Tools/smoke-selection.sh

set -euo pipefail

ESC=$'\033'
RESET="${ESC}[0m"
BOLD="${ESC}[1m"
GREEN="${ESC}[32m"
YELLOW="${ESC}[33m"
CYAN="${ESC}[36m"
RED="${ESC}[31m"

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
else
  warn "Skipped"
fi
read -r -p "Press <Enter> when Hi-Terms is focused..." _

step "2. Shell selection + Cmd+C"
note "Paste this into Hi-Terms, then drag-select the printed line."
note "Press Cmd+C; the selection should be in the system pasteboard."
cat <<'FIX'
--- copy into Hi-Terms ↓ ---
echo 'hi-terms-selection-smoke-12345'
--- end ---
FIX
note "After Cmd+C, run 'pbpaste' in this terminal to verify."
read -r -p "Press <Enter> when done..." _
note "What pbpaste says now:"
pbpaste; echo

step "3. Word + line snap"
note "Paste, then DOUBLE-click on a word (must select the whole word)."
note "TRIPLE-click on a line (must select the whole line, edge to edge)."
cat <<'FIX'
--- copy into Hi-Terms ↓ ---
echo 'foo_bar.baz/qux ~/some/path one two three'
--- end ---
FIX
read -r -p "Press <Enter> when both snaps look right..." _

step "4. Mouse-mode + Option override"
note "Launch a mouse-aware app (vim works) inside Hi-Terms."
note "Without modifier — drag should NOT select (vim sees mouse)."
note "Holding OPTION while dragging — should bypass vim and build a"
note "local highlight; Cmd+C should copy the visible text."
cat <<'FIX'
--- copy into Hi-Terms ↓ ---
vim -c 'set mouse=a' -c 'put =\"line1\\nline2\\nline3\\nline4\"' -c 'normal! gg'
--- end ---
FIX
note "Quit vim with :q! when done."
read -r -p "Press <Enter> when both behaviors confirmed..." _

step "Smoke complete"
ok "Selection + copy round-trips look correct."
