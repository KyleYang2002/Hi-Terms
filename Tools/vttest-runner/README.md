# vttest 自动化方案决策

**文档类型:** 技术决策
**产品名称:** Hi-Terms
**日期:** 2026-03-31
**语言:** 中文
**关联文档:**
- [V0.0 技术设计文档](../../docs/design/hi-terms-v0.0-technical-design.md)（vttest 集成方案：§4.2）
- [V0.0 验收标准](../../docs/reqs/hi-terms-v0.0-acceptance.md)
- [SwiftTerm 评估报告](../../docs/decisions/hi-terms-swiftterm-evaluation.md)

---

## 1. 背景

V0.0 技术设计要求建立 vttest 集成测试方案，用于验证终端仿真引擎的 VT100/xterm 兼容性。本文档记录 vttest 自动化方案的选型决策。

vttest 是标准的终端仿真兼容性测试工具，通过交互式菜单驱动多组测试。自动化 vttest 需要解决两个问题：(1) 自动导航菜单选择测试项；(2) 捕获和验证输出。

---

## 2. 候选方案

### Plan A：PTY 回放驱动

手动录制 vttest PTY I/O（输入序列 + 预期输出），回放到解析器并比对 buffer 快照。

| 维度 | 评估 |
|------|------|
| 确定性 | **高** — 录制数据固定，无外部依赖 |
| 真实性 | **低** — 录制数据可能与不同版本 vttest 行为不一致 |
| 维护成本 | **高** — vttest 版本更新需重新录制；录制脆弱，格式变化即失效 |
| 环境依赖 | **无** — 不需要安装 vttest 二进制 |
| CI 适配性 | **好** — 无外部二进制依赖，CI 环境直接运行 |

### Plan B：脚本驱动 vttest

使用 `expect` 脚本自动驱动 vttest 菜单导航，捕获实际终端输出进行验证。

| 维度 | 评估 |
|------|------|
| 确定性 | **中** — 依赖 vttest 实际运行，但 expect 脚本可控制交互流程 |
| 真实性 | **高** — 运行真实 vttest 二进制，测试结果最具代表性 |
| 维护成本 | **中** — vttest 菜单结构变化时需更新 expect 脚本 |
| 环境依赖 | 需要安装 `vttest`（`brew install vttest`）和 `expect`（macOS 自带） |
| CI 适配性 | **中** — CI 环境需安装 vttest，但 Homebrew 可自动化 |

---

## 3. 决策

**选择 Plan B — 脚本驱动 vttest。**

### 选择理由

1. **V0.0 评估重点是验证兼容性。** 脚本驱动 vttest 更接近真实场景，测试结果的可信度更高。
2. **真实性优于确定性。** 终端仿真兼容性测试的核心价值在于"与标准工具的行为一致"，而非"与录制数据的比对一致"。
3. **macOS 开发环境自带 expect。** 无额外工具链负担。vttest 通过 Homebrew 一条命令安装。
4. **录制方案的脆弱性风险更高。** PTY 录制数据与 vttest 版本、终端窗口大小、时序等因素耦合，任何变化都可能导致快照不匹配，产生大量误报。

### 放弃方案评估

Plan A（PTY 回放驱动）作为 **备选方案保留**，适用于以下场景：

- **CI 环境无法安装 vttest 时：** 使用预录制数据运行回放测试，提供基本兼容性回归保护
- **特定序列的精确回归测试：** 对已知 bug 修复的精确验证，录制 + 回放比完整 vttest 更高效

---

## 4. 实现方案

### 目录结构

```
Tools/vttest-runner/
├── README.md           # 本文档
└── run.sh              # vttest 自动化运行脚本
```

### 使用方式

```bash
# 前置条件
brew install vttest     # 安装 vttest

# 运行（默认场景 P — 解析器可用）
./Tools/vttest-runner/run.sh

# 指定场景
SCENARIO=N ./Tools/vttest-runner/run.sh    # 解析器不可用，跳过测试
```

### 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `SCENARIO` | `P` | `P` = 解析器可用，运行测试；`N` = 解析器不可用，打印跳过消息 |

---

## 5. 后续计划

1. V0.1 阶段扩展 expect 脚本覆盖 vttest 的更多测试组（字符集、滚动、颜色等）
2. 评估将 vttest 结果与 SwiftTerm buffer 状态进行自动化比对的可行性
3. CI 集成时评估是否需要补充 Plan A 回放测试作为 fallback
