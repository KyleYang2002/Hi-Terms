#!/usr/bin/env bash
# Hi-Terms — install shell integration (OSC 7 + OSC 133)
#
# Appends a marker block to ~/.zshrc or ~/.bashrc that sources the matching
# Tools/shell-integration/<shell>.sh. POSIX-friendly: uses awk + grep + sed
# from the macOS base system, no GNU-only flags, no sudo.
#
# Usage:
#   ./Tools/install-shell-integration.sh                  # auto-detect $SHELL
#   ./Tools/install-shell-integration.sh --shell zsh
#   ./Tools/install-shell-integration.sh --shell bash --rcfile ~/.bash_profile
#   ./Tools/install-shell-integration.sh --dry-run        # show diff, write nothing
#
# Idempotent: running twice replaces the existing block in place.
# A timestamped backup of the rcfile is written on first modification.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SNIPPET_DIR="$(cd "$SCRIPT_DIR/shell-integration" && pwd)"
MARK_BEGIN='# >>> hi-terms shell integration >>>'
MARK_END='# <<< hi-terms shell integration <<<'

shell=""
rcfile=""
dry_run=0

usage() {
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --shell)   shell="$2"; shift 2 ;;
        --rcfile)  rcfile="$2"; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) usage 0 ;;
        *)         echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

# Auto-detect shell from $SHELL if not explicit.
if [ -z "$shell" ]; then
    case "${SHELL-}" in
        */zsh)  shell="zsh" ;;
        */bash) shell="bash" ;;
        *)      echo "unable to detect shell from \$SHELL=${SHELL-}; pass --shell zsh|bash" >&2; exit 1 ;;
    esac
fi

case "$shell" in
    zsh)
        snippet="$SNIPPET_DIR/zsh.sh"
        default_rc="$HOME/.zshrc"
        ;;
    bash)
        snippet="$SNIPPET_DIR/bash.sh"
        # macOS bash login shells read .bash_profile, not .bashrc; prefer it
        # when it exists so the integration actually loads.
        if [ -z "$rcfile" ] && [ -f "$HOME/.bash_profile" ]; then
            default_rc="$HOME/.bash_profile"
        else
            default_rc="$HOME/.bashrc"
        fi
        ;;
    *)
        echo "unsupported shell: $shell (expected zsh or bash)" >&2; exit 1 ;;
esac

[ -z "$rcfile" ] && rcfile="$default_rc"

if [ ! -f "$snippet" ]; then
    echo "snippet not found: $snippet" >&2; exit 1
fi

block=$(cat <<EOF
$MARK_BEGIN
# Managed by Hi-Terms install-shell-integration.sh — do not edit by hand.
[ -f "$snippet" ] && . "$snippet"
$MARK_END
EOF
)

# Build the new rcfile contents in a temp file. Existing markers (if any)
# are stripped first so we never duplicate the block.
tmp="$(mktemp -t hiterms-shell-integration)"
trap 'rm -f "$tmp"' EXIT

if [ -f "$rcfile" ] && grep -q "$MARK_BEGIN" "$rcfile"; then
    awk -v B="$MARK_BEGIN" -v E="$MARK_END" '
        $0 == B { skip = 1; next }
        $0 == E { skip = 0; next }
        skip == 0 { print }
    ' "$rcfile" > "$tmp"
elif [ -f "$rcfile" ]; then
    cp "$rcfile" "$tmp"
fi

# Ensure trailing newline before appending.
if [ -s "$tmp" ]; then
    last_byte=$(tail -c 1 "$tmp" 2>/dev/null || true)
    if [ "$last_byte" != "" ]; then
        printf '\n' >> "$tmp"
    fi
fi
printf '%s\n' "$block" >> "$tmp"

if [ "$dry_run" -eq 1 ]; then
    echo "--- dry-run diff against $rcfile ---"
    if [ -f "$rcfile" ]; then
        diff -u "$rcfile" "$tmp" || true
    else
        echo "(rcfile does not exist; would create)"
        cat "$tmp"
    fi
    echo "--- end dry-run ---"
    exit 0
fi

# Backup once per install (timestamped).
if [ -f "$rcfile" ]; then
    backup="$rcfile.hiterms.bak.$(date +%s)"
    cp "$rcfile" "$backup"
    echo "backed up: $backup"
fi

mv "$tmp" "$rcfile"
trap - EXIT

echo "installed Hi-Terms shell integration into $rcfile"
echo "Run: exec $shell  # to apply now"
