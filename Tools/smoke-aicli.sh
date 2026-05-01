#!/usr/bin/env bash
# Hi-Terms — AI CLI smoke test (manual / semi-automated)
#
# Walks the operator through verifying that the three v0.2 task outcomes
# survive in real-world AI CLI usage:
#   1. True Color + 256-color rendering
#   2. Window resize → SIGWINCH (TUI reflow)
#   3. Bracketed Paste mode (multiline prompts not auto-executed)
#
# Strategy: ANSI fixtures and shell snippets are printed here; the operator
# pastes them into a running Hi-Terms.app window and visually confirms.
# The codex CLI is launched at the end if available.
#
# Run from any terminal:  ./Tools/smoke-aicli.sh
# Optional: HITERMS_APP=/path/to/HiTerms.app ./Tools/smoke-aicli.sh

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
fail() { printf "%s[X]%s  %s\n" "${RED}" "${RESET}" "$1"; }

# -----------------------------------------------------------------------------
# 0. Preflight
# -----------------------------------------------------------------------------
step "0. Preflight"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DEFAULT_APP="${REPO_ROOT}/build/DerivedData/Build/Products/Debug/HiTerms.app"
HITERMS_APP="${HITERMS_APP:-${DEFAULT_APP}}"

if [[ -d "${HITERMS_APP}" ]]; then
  ok "HiTerms.app at ${HITERMS_APP}"
else
  warn "HiTerms.app not found at ${HITERMS_APP}"
  warn "Run 'make build' first, or set HITERMS_APP=/path/to/HiTerms.app"
fi

if command -v codex >/dev/null 2>&1; then
  ok "codex CLI: $(codex --version 2>/dev/null || echo 'unknown')"
  CODEX_AVAILABLE=1
else
  warn "codex CLI not found — task 4 will be skipped"
  CODEX_AVAILABLE=0
fi

if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  ok "OPENAI_API_KEY is set"
  KEY_AVAILABLE=1
else
  warn "OPENAI_API_KEY not set — codex interactive run will be skipped"
  KEY_AVAILABLE=0
fi

# -----------------------------------------------------------------------------
# 1. Launch
# -----------------------------------------------------------------------------
step "1. Launch Hi-Terms"
if [[ -d "${HITERMS_APP}" ]]; then
  open "${HITERMS_APP}"
  ok "Launched ${HITERMS_APP}"
  note "Bring the Hi-Terms window to the front."
else
  warn "Skipped launch (app missing)"
fi

cat <<'EOF'

Operator: in the rest of this run, you will be asked to copy each "fixture"
block into the Hi-Terms window and confirm what you see. Press <Enter> in THIS
terminal between checks.

EOF
read -r -p "Press <Enter> when Hi-Terms is focused..." _

# -----------------------------------------------------------------------------
# 2. True Color + 256-color
# -----------------------------------------------------------------------------
step "2. Verify True Color + 256-color"
note "Paste the following into Hi-Terms. Expect:"
note "  - smooth horizontal RGB gradient (no banding)"
note "  - the 6×6×6 cube and grayscale row look like a continuous palette"
cat <<'FIX'
--- copy into Hi-Terms ↓ ---
printf '\n24-bit gradient:\n'
for i in $(seq 0 79); do
  r=$(( i * 255 / 79 ))
  printf '\033[48;2;%d;0;%dm ' "$r" "$((255 - r))"
done
printf '\033[0m\n\n256-color cube (16-231):\n'
for i in $(seq 16 231); do
  printf '\033[48;5;%dm  \033[0m' "$i"
  [ $(( (i - 15) % 36 )) -eq 0 ] && printf '\n'
done
printf '\nGrayscale (232-255):\n'
for i in $(seq 232 255); do printf '\033[48;5;%dm  \033[0m' "$i"; done
printf '\n'
--- end ---
FIX
read -r -p "Press <Enter> after confirming the gradient looks smooth..." _

# -----------------------------------------------------------------------------
# 3. Window resize → SIGWINCH
# -----------------------------------------------------------------------------
step "3. Verify window resize propagates SIGWINCH"
note "Paste this into Hi-Terms; it prints stty size live."
note "Then DRAG the window edge to a noticeably different size."
note "The reported size should change WITHOUT killing the loop."
cat <<'FIX'
--- copy into Hi-Terms ↓ ---
trap 'echo got SIGWINCH at $(stty size)' WINCH
while sleep 1; do printf '\rsize=%s' "$(stty size)"; done
--- end ---
FIX
note "After resizing 2-3 times, hit Ctrl+C in Hi-Terms to stop the loop."
read -r -p "Press <Enter> when resize works..." _

# -----------------------------------------------------------------------------
# 4. Bracketed paste mode
# -----------------------------------------------------------------------------
step "4. Verify bracketed paste mode"
note "Paste the FIRST block into Hi-Terms (it enables bracketed paste in"
note "the shell prompt). Then COPY the multi-line block below from THIS"
note "terminal and paste it into Hi-Terms — it must NOT execute on its own."
cat <<'FIX'
--- copy into Hi-Terms (enable) ↓ ---
printf '\033[?2004h'
--- end ---

--- multiline payload (paste into Hi-Terms; no auto-execute) ↓ ---
echo first
echo second
echo third
--- end ---
FIX
note "Expected: the three echo lines appear on the prompt as a single"
note "edit; you must press <Enter> in Hi-Terms to actually run them."
read -r -p "Press <Enter> when bracketed paste behaves correctly..." _

# -----------------------------------------------------------------------------
# 5. codex interactive sanity check (optional)
# -----------------------------------------------------------------------------
step "5. codex interactive run"
if [[ "${CODEX_AVAILABLE}" == "1" && "${KEY_AVAILABLE}" == "1" ]]; then
  note "Paste this in Hi-Terms; it spawns codex with a short prompt."
  cat <<'FIX'
--- copy into Hi-Terms ↓ ---
codex "print a 3-line haiku about terminals" || echo "codex exited $?"
--- end ---
FIX
  note "Expected: colored output flows in without garbling; resizing the"
  note "window during the response keeps the layout sane; Ctrl+C cleanly"
  note "interrupts."
  read -r -p "Press <Enter> when done..." _
else
  warn "Skipped: need both 'codex' on PATH and OPENAI_API_KEY in env."
fi

step "Smoke complete"
ok "If all four checks above looked correct, the v0.2 trio is shipping cleanly."
