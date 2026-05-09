#!/usr/bin/env bash
# Hi-Terms — uninstall shell integration
#
# Strips the marker block written by install-shell-integration.sh from the
# specified rcfile (or auto-detected default). Safe to run multiple times:
# if no marker block is found, exits 0 without touching the file.
#
# Usage:
#   ./Tools/uninstall-shell-integration.sh                    # auto-detect
#   ./Tools/uninstall-shell-integration.sh --shell bash
#   ./Tools/uninstall-shell-integration.sh --rcfile ~/.zshrc

set -euo pipefail

MARK_BEGIN='# >>> hi-terms shell integration >>>'
MARK_END='# <<< hi-terms shell integration <<<'

shell=""
rcfile=""

usage() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --shell)   shell="$2"; shift 2 ;;
        --rcfile)  rcfile="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *)         echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

if [ -z "$rcfile" ]; then
    if [ -z "$shell" ]; then
        case "${SHELL-}" in
            */zsh)  shell="zsh" ;;
            */bash) shell="bash" ;;
            *)      echo "unable to detect shell from \$SHELL=${SHELL-}; pass --shell or --rcfile" >&2; exit 1 ;;
        esac
    fi
    case "$shell" in
        zsh)  rcfile="$HOME/.zshrc" ;;
        bash)
            if [ -f "$HOME/.bash_profile" ]; then
                rcfile="$HOME/.bash_profile"
            else
                rcfile="$HOME/.bashrc"
            fi
            ;;
        *)    echo "unsupported shell: $shell" >&2; exit 1 ;;
    esac
fi

if [ ! -f "$rcfile" ]; then
    echo "rcfile not found: $rcfile (nothing to do)"
    exit 0
fi

if ! grep -q "$MARK_BEGIN" "$rcfile"; then
    echo "no Hi-Terms integration block in $rcfile (nothing to do)"
    exit 0
fi

backup="$rcfile.hiterms.uninstall.bak.$(date +%s)"
cp "$rcfile" "$backup"
echo "backed up: $backup"

tmp="$(mktemp -t hiterms-shell-integration)"
trap 'rm -f "$tmp"' EXIT

awk -v B="$MARK_BEGIN" -v E="$MARK_END" '
    $0 == B { skip = 1; next }
    $0 == E { skip = 0; next }
    skip == 0 { print }
' "$rcfile" > "$tmp"

mv "$tmp" "$rcfile"
trap - EXIT

echo "removed Hi-Terms shell integration block from $rcfile"
echo "Run: exec $SHELL  # to apply now"
