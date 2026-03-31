#!/bin/bash
# =============================================================================
# Performance Baseline Test Data Generator
# Hi-Terms V0.0 工程基线
#
# 生成混合终端数据，用于 SwiftTerm 解析性能基准测试：
#   - 80% 可打印 ASCII (0x20-0x7E)，含偶尔换行
#   - 15% ANSI SGR 序列（颜色、属性）
#   - 5% 光标移动序列
#
# 用法:
#   ./generate-test-data.sh                    # 默认 10MB, 输出到 Tools/perf-baseline/test-data.bin
#   ./generate-test-data.sh 50                 # 50MB
#   ./generate-test-data.sh 10 /tmp/data.bin   # 指定输出路径
#
# 需要执行权限: chmod +x generate-test-data.sh
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
SIZE_MB="${1:-10}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_FILE="${2:-$SCRIPT_DIR/test-data.bin}"

# 创建输出目录（如果不存在）
OUTPUT_DIR="$(dirname "$OUTPUT_FILE")"
mkdir -p "$OUTPUT_DIR"

echo "=== Hi-Terms Performance Test Data Generator ==="
echo ""
echo "Target size:  ${SIZE_MB} MB"
echo "Output file:  ${OUTPUT_FILE}"
echo ""

# ---------------------------------------------------------------------------
# 检查 Python3
# ---------------------------------------------------------------------------
if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 未找到。"
    echo "macOS 通常预装 Python 3。如果缺失："
    echo "  brew install python3"
    exit 1
fi

# ---------------------------------------------------------------------------
# 生成混合终端数据
# ---------------------------------------------------------------------------
echo "Generating data..."

python3 << PYEOF
import sys
import os
import random

size_mb = ${SIZE_MB}
output_file = """${OUTPUT_FILE}"""
target_size = size_mb * 1_000_000

# 可打印 ASCII 范围 (0x20 - 0x7E)
ascii_chars = bytes(range(0x20, 0x7F))

# ANSI SGR 序列：颜色和文本属性
sgr_sequences = [
    # 基本文本属性
    b'\x1b[0m',             # reset
    b'\x1b[1m',             # bold
    b'\x1b[2m',             # dim
    b'\x1b[3m',             # italic
    b'\x1b[4m',             # underline
    b'\x1b[7m',             # inverse
    b'\x1b[8m',             # invisible
    b'\x1b[9m',             # strikethrough
    # 基本前景色 (30-37)
    b'\x1b[31m',            # red
    b'\x1b[32m',            # green
    b'\x1b[33m',            # yellow
    b'\x1b[34m',            # blue
    b'\x1b[35m',            # magenta
    b'\x1b[36m',            # cyan
    b'\x1b[37m',            # white
    # 基本背景色 (40-47)
    b'\x1b[41m',            # bg red
    b'\x1b[42m',            # bg green
    b'\x1b[44m',            # bg blue
    # 256 色
    b'\x1b[38;5;196m',      # fg 256-color red
    b'\x1b[38;5;46m',       # fg 256-color green
    b'\x1b[38;5;226m',      # fg 256-color yellow
    b'\x1b[48;5;236m',      # bg 256-color dark gray
    b'\x1b[48;5;17m',       # bg 256-color dark blue
    # True Color (24-bit)
    b'\x1b[38;2;255;128;0m',    # fg orange
    b'\x1b[38;2;0;255;128m',    # fg spring green
    b'\x1b[38;2;128;0;255m',    # fg purple
    b'\x1b[48;2;32;32;32m',     # bg dark gray
    b'\x1b[48;2;0;43;54m',      # bg solarized base03
    # 组合属性
    b'\x1b[1;31m',          # bold red
    b'\x1b[1;4;33m',        # bold underline yellow
    b'\x1b[3;36m',          # italic cyan
]

# 光标移动序列
cursor_sequences = [
    b'\x1b[A',              # cursor up
    b'\x1b[B',              # cursor down
    b'\x1b[C',              # cursor right
    b'\x1b[D',              # cursor left
    b'\x1b[H',              # cursor home
    b'\x1b[1;1H',           # cursor to (1,1)
    b'\x1b[10;20H',         # cursor to (10,20)
    b'\x1b[5;40H',          # cursor to (5,40)
    b'\x1b[24;80H',         # cursor to (24,80)
    b'\x1b[2J',             # erase display
    b'\x1b[K',              # erase to end of line
    b'\x1b[1K',             # erase to start of line
    b'\x1b[2K',             # erase entire line
    b'\x1b[5A',             # cursor up 5
    b'\x1b[10B',            # cursor down 10
    b'\x1b[3C',             # cursor right 3
    b'\x1b[s',              # save cursor position
    b'\x1b[u',              # restore cursor position
]

# 使用确定性种子确保可重复生成
random.seed(42)

# 使用 bytearray 构建数据，避免频繁内存分配
chunks = []
written = 0

while written < target_size:
    roll = random.randint(0, 99)

    if roll < 80:
        # 80% 可打印 ASCII，带偶尔换行
        line_len = random.randint(20, 80)
        line = bytearray(line_len)
        for i in range(line_len):
            line[i] = ascii_chars[random.randint(0, len(ascii_chars) - 1)]
        # 每行末尾加 CR+LF
        line.extend(b'\r\n')
        chunks.append(bytes(line))
        written += line_len + 2
    elif roll < 95:
        # 15% ANSI SGR 序列，后跟一些可打印字符
        seq = sgr_sequences[random.randint(0, len(sgr_sequences) - 1)]
        # SGR 序列后跟 1-5 个可打印字符（模拟着色文本）
        text_len = random.randint(1, 5)
        text = bytearray(text_len)
        for i in range(text_len):
            text[i] = ascii_chars[random.randint(0, len(ascii_chars) - 1)]
        chunk = seq + bytes(text)
        chunks.append(chunk)
        written += len(chunk)
    else:
        # 5% 光标移动序列
        seq = cursor_sequences[random.randint(0, len(cursor_sequences) - 1)]
        chunks.append(seq)
        written += len(seq)

# 写入文件
with open(output_file, 'wb') as f:
    for chunk in chunks:
        f.write(chunk)

actual_size = os.path.getsize(output_file)
print(f"Generated {actual_size:,} bytes ({actual_size / 1_000_000:.1f} MB)")
PYEOF

# ---------------------------------------------------------------------------
# 验证输出
# ---------------------------------------------------------------------------
echo ""

if [[ -f "$OUTPUT_FILE" ]]; then
    # macOS 和 Linux 兼容的文件大小获取
    FILE_SIZE=$(stat -f%z "$OUTPUT_FILE" 2>/dev/null || stat --format=%s "$OUTPUT_FILE" 2>/dev/null)
    FILE_SIZE_MB=$(echo "scale=1; $FILE_SIZE / 1000000" | bc)

    echo "=== Verification ==="
    echo "File exists:  yes"
    echo "File size:    ${FILE_SIZE} bytes (${FILE_SIZE_MB} MB)"
    echo "File path:    ${OUTPUT_FILE}"
    echo ""
    echo "=== Generation: SUCCESS ==="
    exit 0
else
    echo "=== Verification ==="
    echo "ERROR: Output file was not created."
    echo "Expected: ${OUTPUT_FILE}"
    echo ""
    echo "=== Generation: FAILED ==="
    exit 1
fi
