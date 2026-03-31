#!/bin/bash
# Builds a signed DMG containing HiTerms.app for distribution.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SKIP_BUILD=false
SKIP_SIGN=false
OUTPUT=""
DERIVED_DATA="$PROJECT_ROOT/build/DerivedData"

# ---------------------------------------------------------------------------
# Cleanup trap — remove staging directory on exit
# ---------------------------------------------------------------------------
STAGING=""
MOUNT_POINT=""

cleanup() {
    if [ -n "$MOUNT_POINT" ] && diskutil info "$MOUNT_POINT" &>/dev/null; then
        echo "Cleaning up: unmounting $MOUNT_POINT"
        hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    fi
    if [ -n "$STAGING" ] && [ -d "$STAGING" ]; then
        rm -rf "$STAGING"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
    --skip-build    Skip the xcodebuild step (use existing build artifacts)
    --skip-sign     Skip code signing
    --output PATH   Output DMG path (default: build/HiTerms-0.0.0.dmg)
    -h, --help      Show this help message

Examples:
    $(basename "$0")
    $(basename "$0") --skip-build --output ~/Desktop/HiTerms.dmg
    $(basename "$0") --skip-sign
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --skip-sign)
            SKIP_SIGN=true
            shift
            ;;
        --output)
            if [[ $# -lt 2 ]]; then
                echo "Error: --output requires a path argument"
                exit 1
            fi
            OUTPUT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: unknown option '$1'"
            usage
            ;;
    esac
done

if [ -z "$OUTPUT" ]; then
    OUTPUT="$PROJECT_ROOT/build/HiTerms-0.0.0.dmg"
fi

# ---------------------------------------------------------------------------
# Step 1: Check prerequisites
# ---------------------------------------------------------------------------
echo "==> Checking prerequisites..."

missing=()
for cmd in xcodebuild hdiutil codesign security diskutil; do
    if ! command -v "$cmd" &>/dev/null; then
        missing+=("$cmd")
    fi
done

if [ ${#missing[@]} -gt 0 ]; then
    echo "Error: required tools not found: ${missing[*]}"
    exit 1
fi

echo "    All prerequisites satisfied."

# ---------------------------------------------------------------------------
# Step 2: Build (unless --skip-build)
# ---------------------------------------------------------------------------
if [ "$SKIP_BUILD" = true ]; then
    echo "==> Skipping build (--skip-build)"
else
    echo "==> Building HiTerms (Release)..."
    xcodebuild build \
        -scheme HiTerms \
        -configuration Release \
        -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED_DATA" \
        | tail -5
    echo "    Build complete."
fi

# ---------------------------------------------------------------------------
# Step 3: Locate HiTerms.app
# ---------------------------------------------------------------------------
echo "==> Locating HiTerms.app..."

APP_PATH=$(find "$DERIVED_DATA" -name "HiTerms.app" -type d | head -1)

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "Error: HiTerms.app not found in $DERIVED_DATA"
    echo "       Run without --skip-build, or verify the build output."
    exit 1
fi

echo "    Found: $APP_PATH"

# ---------------------------------------------------------------------------
# Step 4: Code signing (unless --skip-sign)
# ---------------------------------------------------------------------------
IDENTITY=""

if [ "$SKIP_SIGN" = true ]; then
    echo "==> Skipping code signing (--skip-sign)"
else
    echo "==> Discovering signing identity..."

    IDENTITY_LINE=$(security find-identity -v -p codesigning \
        | grep "Apple Development\|Developer ID Application" \
        | head -1 || true)

    if [ -n "$IDENTITY_LINE" ]; then
        # Format: "  1) <HEX> \"Name (TEAM)\""
        # Extract the hex hash (second field)
        IDENTITY=$(echo "$IDENTITY_LINE" | awk '{print $2}')
        IDENTITY_NAME=$(echo "$IDENTITY_LINE" | sed 's/.*"\(.*\)".*/\1/')
        echo "    Using identity: $IDENTITY_NAME"

        echo "==> Signing HiTerms.app..."
        codesign --deep --force --options runtime \
            --sign "$IDENTITY" \
            "$APP_PATH"
        echo "    App signed."
    else
        echo "    Warning: no signing identity found. Continuing without signing."
    fi
fi

# ---------------------------------------------------------------------------
# Step 5: Create staging directory
# ---------------------------------------------------------------------------
echo "==> Preparing staging directory..."

STAGING=$(mktemp -d "${TMPDIR:-/tmp}/HiTerms-dmg-staging.XXXXXX")

cp -R "$APP_PATH" "$STAGING/HiTerms.app"
ln -s /Applications "$STAGING/Applications"

echo "    Staging ready: $STAGING"

# ---------------------------------------------------------------------------
# Step 6: Create DMG
# ---------------------------------------------------------------------------
echo "==> Creating DMG..."

# Ensure output directory exists
mkdir -p "$(dirname "$OUTPUT")"

hdiutil create \
    -volname "HiTerms" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$OUTPUT"

echo "    DMG created: $OUTPUT"

# ---------------------------------------------------------------------------
# Step 7: Sign DMG (if identity available and not --skip-sign)
# ---------------------------------------------------------------------------
if [ "$SKIP_SIGN" = false ] && [ -n "$IDENTITY" ]; then
    echo "==> Signing DMG..."
    codesign --force --sign "$IDENTITY" "$OUTPUT"
    echo "    DMG signed."
fi

# ---------------------------------------------------------------------------
# Step 8: Verify DMG
# ---------------------------------------------------------------------------
echo "==> Verifying DMG..."

MOUNT_POINT=$(hdiutil attach "$OUTPUT" -nobrowse -readonly \
    | grep "/Volumes/" \
    | awk -F'\t' '{print $NF}')

if [ -z "$MOUNT_POINT" ]; then
    echo "Error: failed to mount DMG for verification"
    exit 1
fi

# Check that the app bundle exists inside the mounted volume
if [ ! -d "$MOUNT_POINT/HiTerms.app" ]; then
    echo "Error: HiTerms.app not found in mounted DMG"
    exit 1
fi

echo "    HiTerms.app found in DMG volume."

# Check DMG file size (must be > 1 MB = 1048576 bytes)
DMG_SIZE=$(stat -f%z "$OUTPUT")
if [ "$DMG_SIZE" -le 1048576 ]; then
    echo "Error: DMG too small (${DMG_SIZE} bytes). Expected > 1 MB."
    exit 1
fi

# Unmount (cleanup trap will also handle this, but be explicit)
hdiutil detach "$MOUNT_POINT" -quiet
MOUNT_POINT=""

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
DMG_SIZE_MB=$(echo "scale=1; $DMG_SIZE / 1048576" | bc)
echo ""
echo "==> Success!"
echo "    Output: $OUTPUT"
echo "    Size:   ${DMG_SIZE_MB} MB (${DMG_SIZE} bytes)"
