#!/usr/bin/env bash
# Hi-Terms — bare-text path detection smoke (manual)
#
# Run this script *inside Hi-Terms*. It prints lines containing file paths in
# various forms (no OSC 8 escapes — the renderer must detect them via regex
# scan + cwd validation + stat).
#
# Expected behaviour:
#   - Hover over the printed path → underline + pointing-hand cursor
#   - ⌘+click on the path → opens in Xcode (`xed -l <line>`) for Apple-toolchain
#     extensions; vscode://file/<path>:line[:col] for other extensions; system
#     default for files without `:line[:col]`.
#   - Negative cases: paths outside cwd or that don't exist on disk must not
#     hover/click — they should look like plain text.
#
# Usage (inside Hi-Terms):
#   ./Tools/smoke-bare-paths.sh

set -euo pipefail

CWD="$(pwd)"
SRC_DIR="${CWD}/.smoke-bare-paths"
mkdir -p "${SRC_DIR}"
trap 'rm -rf "${SRC_DIR}"' EXIT

# Real files inside cwd — detector should accept these.
SWIFT_FILE="${SRC_DIR}/Greeter.swift"
TEXT_FILE="${SRC_DIR}/notes.txt"
PYTHON_FILE="${SRC_DIR}/server.py"
cat > "${SWIFT_FILE}" <<'EOF'
struct Greeter {
    func greet(_ name: String) -> String {
        return "Hello, \(name)!"
    }
}
EOF
echo "manual smoke notes — safe to delete" > "${TEXT_FILE}"
echo "print('hello from python')" > "${PYTHON_FILE}"

printf '\n=== bare-text path detection ===\n\n'

printf '1) Absolute path with line:col → ⌘+click should open Xcode at line 2:\n'
printf '   %s:2:5\n\n' "${SWIFT_FILE}"

printf '2) Relative path with no line → ⌘+click opens system default app (TextEdit):\n'
printf '   .smoke-bare-paths/notes.txt\n\n'

printf '3) Python file with line → ⌘+click should open VS Code at line 1:\n'
printf '   .smoke-bare-paths/server.py:1\n\n'

printf '4) Home-relative path (uses ~) — only clickable if it is in cwd subtree.\n'
printf '   In a typical setup this expands OUTSIDE cwd, so it should be rejected:\n'
printf '   ~/Library/Logs/system.log\n\n'

printf '5) Absolute path OUTSIDE cwd → should NOT highlight or open:\n'
printf '   /etc/passwd\n\n'

printf '6) Non-existent file → should NOT highlight (stat fails):\n'
printf '   does/not/exist.swift\n\n'

printf '7) Plain identifier with a dot but no slash → should NOT highlight:\n'
printf '   version foo.bar 1.2.3\n\n'

printf 'Verify visually:\n'
printf '  - Lines 1-3: hover shows underline + pointing-hand; ⌘+click jumps.\n'
printf '  - Lines 4-7: no decoration on hover, ⌘+click does nothing.\n'
printf '  - Console.app (filter: com.hiterms.ui) should remain quiet.\n'
