#!/usr/bin/env bash
# Hi-Terms — OSC 8 hyperlink + OSC 133 visualization smoke (manual)
#
# Run this script *inside Hi-Terms*. It prints sequences that exercise:
#   1. OSC 8 https://… link  → hover shows underline, ⌘+click opens browser
#   2. OSC 8 file:// inside cwd  → ⌘+click opens in Finder/default app
#   3. OSC 8 file:// outside cwd → policy rejects, no app launches
#   4. OSC 8 javascript:…       → policy rejects, no app launches
#   5. OSC 133 success command  → gutter band (green) covers prompt+output rows
#   6. OSC 133 failure exit=N   → gutter band (red) + ✗ exit=N badge at end
#
# The OSC 133 portion does NOT require shell-integration rc files; we emit the
# control sequences directly so the visual decoration shows up without a real
# shell prompt cycle.
#
# Usage (inside Hi-Terms):
#   ./Tools/smoke-hyperlinks.sh

set -euo pipefail

CWD="$(pwd)"
TMPFILE="${CWD}/hi-terms-smoke-target.txt"
echo "manual smoke target — safe to delete" > "${TMPFILE}"
trap 'rm -f "${TMPFILE}"' EXIT

# --- OSC 8 hyperlinks ---------------------------------------------------------

printf '\n=== OSC 8 hyperlinks ===\n'

printf '1) HTTPS link  → hover for underline, ⌘+click opens browser:\n'
printf '   \033]8;;https://anthropic.com\033\\Anthropic\033]8;;\033\\\n'

printf '2) file:// inside cwd  → ⌘+click opens %s in Finder:\n' "${TMPFILE}"
printf '   \033]8;;file://%s\033\\smoke target file\033]8;;\033\\\n' "${TMPFILE}"

printf '3) file:// outside cwd  → ⌘+click should be REJECTED (Console: rejected file://):\n'
printf '   \033]8;;file:///etc/passwd\033\\/etc/passwd (denied)\033]8;;\033\\\n'

printf '4) javascript: scheme  → ⌘+click should be REJECTED:\n'
printf '   \033]8;;javascript:alert(1)\033\\javascript:alert(1) (denied)\033]8;;\033\\\n'

printf '5) Mid-sentence link spanning multiple words:\n'
printf '   See \033]8;;https://example.com/docs\033\\the docs over here\033]8;;\033\\ for details.\n'

# --- OSC 133 command boundary visualization ----------------------------------

printf '\n=== OSC 133 command boundaries ===\n'
printf 'Three synthetic command lifecycles. The gutter color band on the\n'
printf 'left should switch (green / red) per status; failed commands also\n'
printf 'show a "✗ exit=N" badge at the right edge of their last output row.\n\n'

printf '\033]133;A\033\\\n'
printf '$ echo "succeeded" \n'
printf '\033]133;B\033\\\n'
printf 'succeeded\n'
printf '\033]133;C\033\\\n'
printf 'this is the output\n'
printf 'of a successful command\n'
printf '\033]133;D;0\033\\\n'

printf '\033]133;A\033\\\n'
printf '$ false # this command failed \n'
printf '\033]133;B\033\\\n'
printf '\033]133;C\033\\\n'
printf 'simulated failure output\n'
printf 'spanning two rows\n'
printf '\033]133;D;1\033\\\n'

printf '\033]133;A\033\\\n'
printf '$ exit-127 \n'
printf '\033]133;B\033\\\n'
printf '\033]133;C\033\\\n'
printf 'command not found (exit=127)\n'
printf '\033]133;D;127\033\\\n'

printf '\nVerify visually:\n'
printf '  - Hyperlinks 1-2: underline appears on hover, ⌘+click opens.\n'
printf '  - Hyperlinks 3-4: ⌘+click does NOT open; Console.app should\n'
printf '    show "rejected file:// outside cwd" / "rejected scheme" lines\n'
printf '    under com.hiterms.ui / category hyperlink.\n'
printf '  - First fake command: green gutter, no badge.\n'
printf '  - Second/third fake commands: red gutter + ✗ exit=N badge.\n'
