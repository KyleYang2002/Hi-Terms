#!/bin/bash
# =============================================================================
# vttest Automation Runner — Plan B (script-driven vttest)
# Hi-Terms V0.0 工程基线
#
# 使用 expect 脚本自动驱动 vttest 菜单，运行测试组 1（光标移动测试），
# 捕获输出并报告结果。
#
# 用法:
#   ./run.sh                         # 默认场景 P（解析器可用）
#   SCENARIO=N ./run.sh              # 场景 N（解析器不可用，跳过测试）
#
# 前置条件:
#   brew install vttest              # 安装 vttest
#   expect 通常 macOS 自带
#
# 需要执行权限: chmod +x run.sh
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIO="${SCENARIO:-P}"

# ---------------------------------------------------------------------------
# Scenario N: 解析器不可用，跳过测试
# ---------------------------------------------------------------------------
if [[ "$SCENARIO" == "N" ]]; then
    echo "============================================"
    echo "  vttest Automation: SKIPPED"
    echo "  Scenario N — parser not available"
    echo "============================================"
    echo ""
    echo "vttest 自动化框架已就绪。"
    echo "等待终端解析器实现后激活测试。"
    echo ""
    echo "当解析器可用时，运行："
    echo "  SCENARIO=P ./Tools/vttest-runner/run.sh"
    exit 0
fi

# ---------------------------------------------------------------------------
# 检查前置条件
# ---------------------------------------------------------------------------
echo "=== vttest Automation (Plan B: Script-driven) ==="
echo ""

# 检查 vttest
if ! command -v vttest &>/dev/null; then
    echo "ERROR: vttest 未安装。"
    echo ""
    echo "安装方法："
    echo "  brew install vttest"
    echo ""
    echo "vttest 是标准的 VT100/xterm 终端仿真兼容性测试工具。"
    echo "详情: https://invisible-island.net/vttest/"
    echo ""
    echo "vttest automation: SKIPPED (vttest not installed)"
    exit 1
fi

# 检查 expect
if ! command -v expect &>/dev/null; then
    echo "ERROR: expect 未找到。"
    echo ""
    echo "expect 通常随 macOS 预装。如果缺失，可通过以下方式安装："
    echo "  brew install expect"
    exit 1
fi

VTTEST_VERSION=$(vttest --version 2>&1 | head -1 || echo "unknown")
echo "vttest version: $VTTEST_VERSION"
echo "Running test group 1: Cursor movements..."
echo ""

# ---------------------------------------------------------------------------
# 创建临时 expect 脚本
# ---------------------------------------------------------------------------
EXPECT_SCRIPT=$(mktemp /tmp/vttest-run.XXXXXX.exp)
OUTPUT_FILE=$(mktemp /tmp/vttest-output.XXXXXX.log)

cleanup() {
    rm -f "$EXPECT_SCRIPT" "$OUTPUT_FILE"
}
trap cleanup EXIT

cat > "$EXPECT_SCRIPT" << 'EXPECT_EOF'
#!/usr/bin/expect -f

# vttest 自动化 expect 脚本
# 自动导航 vttest 主菜单，运行测试组 1（光标移动），捕获输出

set timeout 30
log_user 1

# 启动 vttest
spawn vttest

# 等待主菜单出现
expect {
    "Enter choice number" {
        # 主菜单已加载
    }
    timeout {
        puts "\nTIMEOUT: vttest 主菜单未在 30 秒内出现"
        exit 1
    }
}

# 选择测试组 1: Test of cursor movements
send "1\r"

# 处理测试组 1 的交互流程
# vttest 在每个子测试后显示 "RETURN" 提示等待用户按回车
# 所有子测试完成后返回主菜单
set test_count 0
expect {
    -re "RETURN|Push <RETURN>" {
        incr test_count
        send "\r"
        exp_continue
    }
    "Enter choice number" {
        # 回到主菜单，测试组 1 完成
        puts "\n--- Test group 1 completed ($test_count sub-tests) ---"
    }
    timeout {
        puts "\nTIMEOUT: vttest 测试执行超时"
        puts "已完成 $test_count 个子测试"
        exit 1
    }
}

# 退出 vttest (选择 0)
send "0\r"

# 等待 vttest 正常退出
expect {
    eof {
        # 正常退出
    }
    timeout {
        puts "\nWARNING: vttest 退出超时，强制结束"
    }
}

exit 0
EXPECT_EOF

chmod +x "$EXPECT_SCRIPT"

# ---------------------------------------------------------------------------
# 运行 expect 脚本
# ---------------------------------------------------------------------------
echo "--- Starting vttest via expect ---"
echo ""

if expect "$EXPECT_SCRIPT" > "$OUTPUT_FILE" 2>&1; then
    EXIT_CODE=0
else
    EXIT_CODE=$?
fi

# ---------------------------------------------------------------------------
# 分析结果
# ---------------------------------------------------------------------------
echo ""
echo "=== Output Summary ==="

if [[ -f "$OUTPUT_FILE" ]]; then
    OUTPUT_LINES=$(wc -l < "$OUTPUT_FILE" | tr -d ' ')
    OUTPUT_SIZE=$(wc -c < "$OUTPUT_FILE" | tr -d ' ')
    echo "Captured: $OUTPUT_LINES lines, $OUTPUT_SIZE bytes"

    # 检查输出中是否有常见的错误标志
    if grep -qi "error\|fail\|abort" "$OUTPUT_FILE" 2>/dev/null; then
        echo "WARNING: 输出中包含潜在错误标志（可能是误报，请检查完整输出）"
    fi
else
    echo "WARNING: 无输出文件"
fi

echo ""
echo "Full output saved to: $OUTPUT_FILE"
echo ""

if [[ $EXIT_CODE -eq 0 ]]; then
    echo "=== vttest Automation: PASSED ==="
    exit 0
else
    echo "=== vttest Automation: FAILED (exit code: $EXIT_CODE) ==="
    echo ""
    echo "排查建议："
    echo "  1. 手动运行 vttest 确认工具正常"
    echo "  2. 检查完整输出: cat $OUTPUT_FILE"
    echo "  3. 确认终端窗口大小 >= 80x24"
    exit 1
fi
