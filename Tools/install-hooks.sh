#!/bin/bash
# 安装 Git hooks
# 用法: ./Tools/install-hooks.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cp "$SCRIPT_DIR/pre-commit" "$PROJECT_ROOT/.git/hooks/pre-commit"
chmod +x "$PROJECT_ROOT/.git/hooks/pre-commit"
echo "Git hooks 安装完成"
