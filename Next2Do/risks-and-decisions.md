# 风险登记册与决策日志

**文档类型:** 风险与决策追踪
**产品名称:** Hi-Terms
**语言:** 中文
**覆盖范围:** 跨版本（v0.1+）
**关联文档:**
- [V0.1 执行计划](v0.1-execution.md) — 任务执行状态
- [V0.2 蓝图](v0.2-blueprint.md) — v0.2 规划与风险预判
- [技术选型决策](../docs/decisions/hi-terms-technical-decisions.md) — 项目级技术决策

---

## 1. 文档说明

### 1.1 定位

本文档追踪**执行层面**的风险和运行时决策。

### 1.2 与 docs/decisions/ 的分工

| 文档 | 职责 | 示例 |
|------|------|------|
| `docs/decisions/` | 项目级、长期不变的技术选型 | Swift+AppKit、SwiftTerm、CoreText、macOS 14 |
| 本文档 | 执行过程中的运行时决策和风险 | API 选择、方案取舍、实现偏差 |

---

## 2. 活跃风险登记册

### 2.1 风险评级标准

| 影响等级 | 定义 |
|---------|------|
| 高 | 阻塞整个 Phase 或多个任务 |
| 中 | 阻塞单个任务或导致返工 |
| 低 | 需额外工作但不阻塞 |

| 概率等级 | 定义 |
|---------|------|
| 高 | >70% 会发生 |
| 中 | 30%-70% |
| 低 | <30% |

### 2.2 风险表

| ID | 风险描述 | 关联任务 | 影响 | 概率 | 状态 | 缓解措施 | 触发条件 | 更新日期 |
|----|---------|---------|------|------|------|---------|---------|---------|
| R-01 | CoreTextRenderer 性能不达 30fps | F6 | 中 | 中 | open | 行级脏区已是第一层优化；Phase F 验证后评估是否需要进一步优化 | F6 性能验证不达标 | 2026-04-06 |
| R-02 | vttest 通过率不达 80% | F4 | 中 | 中 | open | 优先修复高影响项；低影响项标记为已知限制（v0.2 修复） | F4 验证不达标 | 2026-04-06 |
| R-03 | TerminalSession 跨模块依赖 — TerminalSession（TerminalCore）需创建 DefaultTerminalPipeline（TerminalUI） | D2 | 中 | 低 | open | 采用 Pipeline 注入模式：TerminalSession 通过 TerminalPipeline 协议持有管线，具体 Pipeline 由外部注入。Phase A6 已将协议迁移至 TerminalCore | D2 编码时发现循环依赖 | 2026-04-06 |
| R-04 | macOS 权限问题阻止 PTY/fork 操作 | E4 | 中 | 低 | open | App Sandbox 保持 disabled（entitlements 已配置）；确保签名证书有效 | E4 集成时应用无法启动 PTY | 2026-04-06 |
| R-05 | Phase B RenderCoordinator 实际 API 与原技术设计有差异，影响 C1 管线连接 | C1 | 低 | 高 | open | C1 开始前确认 Phase B 实际 API（见 [DEC-02](#dec-02-macos-displaylink-替代方案)），基于实际实现编码 | C1 编码时 API 不匹配 | 2026-04-06 |

### 2.3 已关闭风险

| ID | 风险描述 | 关联任务 | 结果 | 关闭日期 |
|----|---------|---------|------|---------|
| R-00 | SwiftTerm scrollback API 不暴露，A3 无法实现 | A3 | mitigated — `getScrollInvariantLine` 可用（见 [DEC-01](#dec-01-swiftterm-scrollback-api-选择)） | 2026-04-02 |

---

## 3. 决策日志

### DEC-01: SwiftTerm Scrollback API 选择

| 字段 | 内容 |
|------|------|
| **ID** | DEC-01 |
| **日期** | 2026-04-02 |
| **状态** | decided |
| **上下文** | Phase A PF-3 前置验证：需确定 SwiftTerm v1.13.0 中 scrollback 行的访问方式 |
| **选项** | (a) `getScrollInvariantLine` — 直接 API<br/>(b) `buffer.lines` 直接访问 — CircularList 遍历<br/>(c) `getLine` 负偏移计算 — 行号偏移 |
| **决策** | 采用 (a) `getScrollInvariantLine` |
| **理由** | API 直接可用，签名明确（`getScrollInvariantLine(_ row: Int) -> BufferLine`），无需手动计算偏移 |
| **影响** | A3 按原技术设计 §7.6 方案执行，无需修改 |
| **关联** | 风险 R-00（已关闭），任务 A3，技术设计 §7.6 |

### DEC-02: macOS DisplayLink 替代方案

| 字段 | 内容 |
|------|------|
| **ID** | DEC-02 |
| **日期** | 2026-04-05 |
| **状态** | decided |
| **上下文** | Phase B 实现发现 `CADisplayLink(target:selector:)` 构造器在 macOS 上不可用（仅 iOS） |
| **选项** | (a) `NSScreen.main?.displayLink(target:selector:)` — macOS 14+ 原生 API<br/>(b) `CVDisplayLink` — 底层 Core Video API<br/>(c) `DispatchSourceTimer` — GCD 定时器模拟 |
| **决策** | 采用 (a) `NSScreen.main?.displayLink(target:selector:)` |
| **理由** | macOS 14+ 原生支持，与项目最低部署目标一致；API 层次与 iOS CADisplayLink 对等，代码结构无需大改 |
| **影响** | RenderCoordinator 初始化方式与原技术设计 §6.2 有差异：原设计用 `CADisplayLink(target:selector:)`，实际用 `NSScreen.main?.displayLink(target:selector:)`。C1 连接管线时需基于 Phase B 实际实现 |
| **关联** | 风险 R-05，任务 B1，commit `8d843a8` |

---

### DEC-03: 鼠标上报必须按 SwiftTerm `mouseMode` 门控

| 字段 | 内容 |
|------|------|
| **ID** | DEC-03 |
| **日期** | 2026-05-01 |
| **状态** | decided |
| **上下文** | `refs/22.png`：在 zsh 提示符上左键点击会回显 `0;50;12M0;50;12m` 这样的 SGR 参数残骸。根因是 `TerminalView.mouseDown/mouseUp/mouseMoved` 无条件向 PTY 写 SGR 鼠标上报，没有看 SwiftTerm 的 `mouseMode` 状态——shell 未开启鼠标模式时把 ESC[< 当做未识别 CSI 消化掉，剩余可见字符回显成乱码 |
| **选项** | (a) 仅在 `TerminalView` 里直接 `import SwiftTerm` 读 `terminal.mouseMode`<br/>(b) 在 `SwiftTermAdapter` 上暴露 Hi-Terms 自有的 `MouseReportingMode` 枚举映射，UI 层只依赖 TerminalCore<br/>(c) 把鼠标编码逻辑搬到 TerminalCore，UI 层只传事件 |
| **决策** | 采用 (b)：`SwiftTermAdapter.mouseReportingMode` 暴露 Hi-Terms 自有的 `MouseReportingMode` 枚举；UI 在 `mouseDown/mouseUp/mouseDragged/mouseMoved` 各自先按该枚举判定是否上报；`InputHandler` 保持不依赖 SwiftTerm，纯做字节编码 |
| **理由** | 维持 TerminalUI → TerminalCore 单向依赖边界；InputHandler 仍可纯单测；MouseReportingMode 是 SwiftTerm `MouseMode` 的一对一镜像，未来切换鼠标解析器实现也只需改 adapter 一处 |
| **影响** | (1) 默认 `.off` 模式下任何鼠标事件都不再写 PTY；(2) `.x10` 仅 press；(3) `.vt200` press+release；(4) `.buttonEventTracking` 加 drag；(5) `.anyEvent` 加 move；(6) drag 编码改为 xterm 标准 `button + 32`（之前固定 35），SGR release 携带 press 时记录的按钮号；(7) 安装 `NSTrackingArea` 让 `.anyEvent` 模式真正能拿到 mouseMoved |
| **关联** | `refs/22.png`，`Packages/TerminalUI/Sources/TerminalUI/{InputHandler,TerminalView}.swift`，`Packages/TerminalCore/Sources/TerminalCore/SwiftTermAdapter.swift`，新增测试 `TerminalViewMouseGatingTests` |

---

## 4. 待决事项

| ID | 描述 | 关联 | 需要的信息 | 目标决策时间 |
|----|------|------|-----------|------------|
| PENDING-01 | v0.2 Tab UI 方案选择（NSTabView / 自定义 TabBar / 系统 Tab 组） | [v0.2-blueprint.md §3.2](v0.2-blueprint.md#32-关键技术决策点) | v0.1 Phase E 完成后评估 NSWindow/NSView 层级实际情况 | v0.1 完成前 |
| PENDING-02 | v0.2 选区模型设计（字符级 / 行级 / 矩形选区） | [v0.2-blueprint.md §3.2](v0.2-blueprint.md#32-关键技术决策点) | 剪贴板和搜索（v0.3）功能需求联合评估 | v0.2 开始前 |
| PENDING-03 | v0.2 IME 方案范围（最小 NSTextInputClient / 完整实现） | [v0.2-blueprint.md §3.2](v0.2-blueprint.md#32-关键技术决策点) | v0.2 范围确认 | v0.2 开始前 |
