#!/bin/bash
# Generates the Xcode project from project.yml.
# Test targets are defined in project.yml and sourced from SPM package test directories.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

echo "Generating Xcode project..."
xcodegen generate

echo "Done. Project generated at HiTerms.xcodeproj"
