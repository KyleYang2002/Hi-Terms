# Hi-Terms V0.1 编码实施任务分解

**文档类型:** 实施计划
**产品名称:** Hi-Terms
**版本:** v0.1
**语言:** 中文
**关联文档:**
- [V0.1 技术设计](../design/hi-terms-v0.1-technical-design.md)（技术规格，本文档的实施来源）
- [V0.1 验收标准](../reqs/hi-terms-v0.1-acceptance.md)（验收标准 SSOT）

---

## 1. 文档说明

本文档将 V0.1 技术设计（1200+ 行设计规格）转化为**分阶段、有依赖、可验证**的编码任务序列。每个 Phase 结束时有明确的验证里程碑，确保增量推进不偏航。

**设计原则：**
- 先修复 V0.0 接口不匹配，确保现有测试不被破坏
- 自底向上构建：数据层 → 渲染层 → 管线层 → Session → UI → 集成
- 每个 Phase 结束时可独立编译和测试
- 破坏性变更在单次 commit 中与所有受影响文件一起提交

---

## 2. 总览

```
Phase A: 基础修复（修改现有代码）
    ↓
Phase B: 渲染层（新增 CoreTextRenderer + RenderCoordinator）
    ↓
Phase C: 管线层（新增 DefaultTerminalPipeline）
    ↓
Phase D: Session 基础（新增 Session 协议 + 实现 + Registry）
    ↓
Phase E: UI 层（新增 InputHandler + TerminalView + WindowController）
    ↓
Phase F: 集成验收（B01-B12 全部通过）
```

**估计新增/修改文件：** 10 个新文件 + 6 个修改文件
**验收项覆盖：** B01-B12（12 项）

---

## 3. Phase A: 基础修复

**目标：** 修复 V0.0 → V0.1 的接口不匹配，为后续 Phase 铺路。完成后现有 40+ 测试仍全部通过。

### A1: PTYProcess 新增 exitHandler

**文件：** `Packages/PTYKit/Sources/PTYKit/PTYProcess.swift`
**设计参考：** 技术设计 §4.6

**任务：**
1. 新增 `public var exitHandler: ((Int32) -> Void)?` 属性
2. 修改 `setupReading()` 中 `bytesRead <= 0` 分支：
   - 调用 `waitpid(self.pid, &status, WNOHANG)` 采集退出码
   - 用 `WIFEXITED` / `WEXITSTATUS` 提取退出码
   - 调用 `self.exitHandler?(exitCode)`
3. 新增单元测试：验证 shell 退出时 exitHandler 被调用且退出码正确

**验证：** `make test` 全部通过 + 新增 exitHandler 测试通过

### A2: SwiftTermAdapter send() 回调

**文件：** `Packages/TerminalCore/Sources/TerminalCore/SwiftTermAdapter.swift`
**设计参考：** 技术设计 §6.4

**任务：**
1. SwiftTermAdapter 新增 `public var sendHandler: ((Data) -> Void)?`
2. SwiftTermDelegateAdapter 新增 `var onSendData: ((Data) -> Void)?`
3. 修改 `send(source:data:)` 方法：`onSendData?(Data(data))`
4. 在 SwiftTermAdapter.init 中连接：`delegateAdapter.onSendData = { [weak self] data in self?.sendHandler?(data) }`
5. 新增单元测试：向 adapter 发送含 DA 查询的序列，验证 sendHandler 被调用

**验证：** `make test` 全部通过 + send 回调测试通过

### A3: SwiftTermAdapter createSnapshot() 支持 scrollback

**文件：** `Packages/TerminalCore/Sources/TerminalCore/SwiftTermAdapter.swift`
**设计参考：** 技术设计 §7.6

**任务：**
1. 修改 `createSnapshot()` 签名为 `createSnapshot(scrollbackOffset: Int = 0)`
2. 实现 scrollback 行读取逻辑（使用 SwiftTerm 的 scrollback API）
3. scrollback 模式下光标设为不可见
4. 新增单元测试：向 adapter 灌入超过 rows 行的数据，验证 scrollbackOffset > 0 时返回历史行

> **注意：** 默认参数值确保现有调用兼容，不破坏编译。需先验证 SwiftTerm v1.13.0 的 scrollback API 可用性。

**验证：** `make test` 全部通过 + scrollback 测试通过

### A4: SessionState.exited 破坏性变更

**文件：** `Packages/TerminalCore/Sources/TerminalCore/SessionTypes.swift` + 所有引用处
**设计参考：** 技术设计 §4.2

**任务：**
1. 修改 `case exited` → `case exited(code: Int32)`
2. 全局搜索 `.exited` 模式匹配，更新为 `.exited(let code)` 或 `.exited(_)`
3. 确认所有测试仍通过

**验证：** `make test` 全部通过（编译 + 运行）

### A5: TerminalPipeline 协议迁移至 TerminalCore

**文件：**
- 源：`Packages/TerminalUI/Sources/TerminalUI/TerminalPipeline.swift`
- 目标：`Packages/TerminalCore/Sources/TerminalCore/TerminalPipeline.swift`
**设计参考：** 技术设计 §11.1

**任务：**
1. 将 `TerminalPipeline` **协议定义**移至 TerminalCore（保留 `parser`、`screenBuffer`、`start/stop/write/resize`）
2. 从协议中**移除** `import TerminalRenderer` 和 `import PTYKit`（协议不再引用这些模块的类型）
3. 将 `TerminalPipelineStub` 留在 TerminalUI（更新 import 语句）
4. 更新 TerminalUI 中原文件：仅保留 Stub 实现，删除协议定义
5. 更新所有 import 语句和测试

**验证：** `make test` 全部通过 + `make build` Debug/Release 均通过

### Phase A 里程碑

- [ ] 现有 40+ 测试全部通过
- [ ] 新增 exitHandler、send()、scrollback 测试通过
- [ ] `make build` Debug + Release 均成功
- [ ] Git commit: "V0.1 Phase A: 修复接口不匹配，为 V0.1 实现做准备"

---

## 4. Phase B: 渲染层

**目标：** 实现 CoreTextRenderer 和 RenderCoordinator，可通过单元测试验证渲染逻辑正确性。

**依赖：** Phase A 完成

### B1: RenderCoordinator

**新增文件：** `Packages/TerminalRenderer/Sources/TerminalRenderer/RenderCoordinator.swift`
**设计参考：** 技术设计 §6.2

**任务：**
1. 实现 `RenderCoordinator` 类：
   - `submitSnapshot(_:)` — 后台线程提交快照（os_unfair_lock 保护）
   - `startDisplayLink()` / `stopDisplayLink()` — CADisplayLink 管理
   - `onDisplayLink()` — 主线程回调，获取最新快照并触发渲染
2. `weak var renderer` 和 `weak var targetLayer` 属性
3. 新增单元测试：验证 submitSnapshot 和 swapAndClear 的线程安全行为

**验证：** TerminalRendererTests 全部通过

### B2: CoreTextRenderer

**新增文件：** `Packages/TerminalRenderer/Sources/TerminalRenderer/CoreTextRenderer.swift`
**设计参考：** 技术设计 §5

**任务：**
1. 实现 `TerminalRendering` 协议：
   - `render(buffer:dirtyRegion:cursor:into:)` — 行级脏区增量渲染
   - 行内文本绘制：扫描连续相同属性字符段 → CFAttributedString → CTLine → CTLineDraw
   - 行背景色绘制
   - 光标渲染（block/underline/bar + 闪烁动画）
2. ANSI 8 色映射表
3. 颜色映射函数 `nsColor(from:isForeground:)`
4. 新增单元测试：
   - 颜色映射正确性
   - 光标位置和尺寸计算
   - 属性（bold/italic/underline）到 CoreText 属性字典的映射

**验证：** TerminalRendererTests 全部通过（含新增测试）

### Phase B 里程碑

- [ ] CoreTextRenderer + RenderCoordinator 编译通过
- [ ] 颜色映射、光标计算单元测试通过
- [ ] `make test` 全部通过
- [ ] Git commit: "V0.1 Phase B: 实现 CoreTextRenderer 和 RenderCoordinator"

---

## 5. Phase C: 管线层

**目标：** 实现 DefaultTerminalPipeline，跑通 PTY → Parser → Snapshot 完整数据管线。

**依赖：** Phase B 完成

### C1: DefaultTerminalPipeline

**新增文件：** `Packages/TerminalUI/Sources/TerminalUI/DefaultTerminalPipeline.swift`
**设计参考：** 技术设计 §6.1, §6.3

**任务：**
1. 实现 `TerminalPipeline` 协议：
   - `start()` — 连接 PTY dataHandler → adapter.parse() → DirtyRegion.merge → submitSnapshot
   - `stop()` — 终止 PTY
   - `write(data:)` — 转发到 PTY
   - `resize(cols:rows:)` — 同步调整 PTY 窗口和 SwiftTerm Terminal
2. 连接 send() 回调：`adapter.sendHandler = { ptyProcess.write(data:) }`
3. 连接 rangeChanged → DirtyRegion.merge → createSnapshot → submitSnapshot
4. 公开 `dirtyRegion` 和 `renderCoordinator` 属性（作为实现特有属性，非协议要求）

### C2: 管线集成测试

**任务：**
1. 新增集成测试：创建 PTYProcess + DefaultTerminalPipeline → 发送 `echo hello\r` → 等待 → 验证 snapshot 包含 "hello"
2. 新增测试：管线 start/stop 生命周期验证
3. 验证 DirtyRegion 在数据到达后被正确标记

**验证：** 集成测试通过 — PTY 数据可通过管线到达 ScreenBufferSnapshot

### Phase C 里程碑

- [ ] DefaultTerminalPipeline 编译通过
- [ ] PTY → Parser → Snapshot 集成测试通过
- [ ] `make test` 全部通过
- [ ] Git commit: "V0.1 Phase C: 实现 DefaultTerminalPipeline 数据管线"

---

## 6. Phase D: Session 基础

**目标：** 实现 Session Foundation，满足 B10-B12 验收标准。

**依赖：** Phase C 完成

### D1: Session 协议

**新增文件：** `Packages/TerminalCore/Sources/TerminalCore/Session.swift`
**设计参考：** 技术设计 §4.3

**任务：**
1. 定义 `Session` 协议：`id`, `state`, `createdAt`, `launchCommand`, `pipeline`, `start()`, `stop()`, `write(data:)`, `resize(cols:rows:)`, `onStateChanged`

### D2: TerminalSession 实现

**新增文件：** `Packages/TerminalCore/Sources/TerminalCore/TerminalSession.swift`
**设计参考：** 技术设计 §4.4

**任务：**
1. 实现 `Session` 协议
2. 内部创建并持有 PTYProcess 和 DefaultTerminalPipeline
3. `start()` — 创建 PTY、启动 shell、连接管线、注册到 Registry
4. `stop()` — 发送 SIGHUP、清理资源、从 Registry 注销
5. PTYProcess.exitHandler → 更新 state 为 `.exited(code:)` → 触发 onStateChanged

> **注意：** TerminalSession 位于 TerminalCore，但需要创建 DefaultTerminalPipeline（位于 TerminalUI）。解决方式：TerminalSession 通过 TerminalPipeline 协议持有管线，具体 Pipeline 实例由外部（AppDelegate 或工厂方法）注入。

### D3: SessionRegistry

**新增文件：** `Packages/TerminalCore/Sources/TerminalCore/SessionRegistry.swift`
**设计参考：** 技术设计 §4.5

**任务：**
1. 实现 `SessionRegistry.shared` 单例
2. GCD 串行队列保护的 `register`/`unregister`/`allSessions`/`session(for:)`/`count`

### D4: Session 单元测试

**任务：**
1. SessionTests：创建 → start → state == .running → stop → state == .exited
2. SessionRegistryTests：register → query → unregister → query 返回 nil
3. B10 验证：Session.id 唯一性（创建多个 Session，验证 ID 不重复）
4. B11 验证：Session 持有 PTY（session.pipeline 非 nil，PTY 生命周期跟随 Session）
5. B12 验证：Registry 查询（通过 ID 查询、列出全部 Session）

**验证：** B10-B12 验收项在单元测试级别通过

### Phase D 里程碑

- [ ] Session + TerminalSession + SessionRegistry 编译通过
- [ ] Session 生命周期单元测试通过
- [ ] B10-B12 验收逻辑在测试中验证
- [ ] `make test` 全部通过
- [ ] Git commit: "V0.1 Phase D: 实现 Session Foundation (B10-B12)"

---

## 7. Phase E: UI 层

**目标：** 实现完整 UI，首次在屏幕上看到 shell 提示符并可交互。

**依赖：** Phase D 完成

### E1: InputHandler

**新增文件：** `Packages/TerminalUI/Sources/TerminalUI/InputHandler.swift`
**设计参考：** 技术设计 §8

**任务：**
1. `handleKeyDown(_:) -> Data?` — NSEvent 转终端字节序列
2. 特殊键映射表（Return、Backspace、Tab、Escape、方向键、Home/End/PageUp/PageDown）
3. Ctrl 组合键映射（Ctrl+A 到 Ctrl+Z、Ctrl+[、Ctrl+\）
4. Cmd 键过滤（不传递到终端）
5. `handleMouseEvent(_:type:in:) -> Data?` — SGR 鼠标报告编码
6. `updateModifiers(_:)` — 修饰键状态追踪
7. 新增单元测试：键盘映射正确性、Ctrl 组合键、鼠标事件编码

**验证：** InputHandler 单元测试全部通过

### E2: TerminalView

**新增文件：** `Packages/TerminalUI/Sources/TerminalUI/TerminalView.swift`
**设计参考：** 技术设计 §7

**任务：**
1. NSView 子类，`wantsLayer = true`
2. Layer 设置：rootLayer（背景）+ textLayer（CoreText 绘制）+ cursorLayer（光标）
3. `acceptsFirstResponder = true`
4. `keyDown(with:)` → InputHandler → session.write()
5. `mouseDown/mouseUp/mouseMoved(with:)` → InputHandler → session.write()
6. `scrollWheel(with:)` → 更新 scrollbackOffset → 标记全部行为脏
7. `terminalCoordinate(for:)` — 像素坐标转网格坐标

### E3: TerminalWindowController

**新增文件：** `Packages/TerminalUI/Sources/TerminalUI/TerminalWindowController.swift`
**设计参考：** 技术设计 §9.2

**任务：**
1. 创建 NSWindow（800x600，titled+closable+miniaturizable+resizable）
2. 创建 TerminalView 作为 contentView
3. 设置 TerminalView 为 firstResponder
4. 监听 Session.onStateChanged → .exited 时关闭窗口

### E4: AppDelegate 集成

**修改文件：** `HiTermsApp/AppDelegate.swift`
**设计参考：** 技术设计 §9.1

**任务：**
1. `applicationDidFinishLaunching` 中：
   - 创建 DefaultConfig
   - 创建 TerminalSession（注入 DefaultTerminalPipeline）
   - `session.start()`
   - `SessionRegistry.shared.register(session)`
   - 创建 TerminalWindowController → showWindow

### Phase E 里程碑

- [ ] 应用启动后显示终端窗口
- [ ] Shell 提示符可见
- [ ] 可输入字符并看到回显
- [ ] `make build` Debug + Release 均成功
- [ ] Git commit: "V0.1 Phase E: 实现 TerminalView + InputHandler + WindowController"

---

## 8. Phase F: 集成验收

**目标：** 全部 B01-B12 验收项通过。

**依赖：** Phase E 完成

### F1: B01 构建验证

```bash
xcodebuild build -scheme HiTerms -configuration Debug -destination 'platform=macOS'
xcodebuild build -scheme HiTerms -configuration Release -destination 'platform=macOS'
# 检查项目自身 warning 数为 0
```

### F2: B02-B07 终端功能验证

手动或自动化验证：

| 验收项 | 验证操作 | 预期结果 |
|--------|---------|---------|
| B02 Shell 启动 | 启动应用 | 显示 shell 提示符，可输入字符 |
| B03 基础命令 | `echo hello`、`ls /`、`cd /tmp && pwd` | 正确输出 |
| B04 TUI 应用 | `top` → `q`、`vim` → `:wq` | 界面正常，退出后状态恢复 |
| B05 Ctrl+C | `sleep 60` → Ctrl+C | 进程中断，显示 `^C` |
| B06 滚动 | `seq 1 200` → 滚轮上滚 | 可看到历史行 |
| B07 ANSI 颜色 | `ls --color` 或 `printf '\e[31mRED\e[0m'` | 红色文本显示 |

### F3: B08 稳定性验证

```bash
# 连续执行 50 条命令，无崩溃/无泄漏
# 监控 RSS 增长 < 50MB
# Instruments Leaks 零泄漏
```

### F4: B09 vttest 验证

```bash
# 在 Hi-Terms 中运行 vttest
# 执行菜单 1-2 基础测试
# 通过率 ≥ 80%
```

### F5: B10-B12 Session Foundation 验证

```bash
# 运行 Session 相关测试
make test  # 包含 SessionTests, SessionRegistryTests
# 验证：Session 有唯一 ID、PTY 归 Session 持有、Registry 可查询
```

### F6: 性能验证

| 指标 | 目标 | 测量方法 |
|------|------|---------|
| 渲染帧率 | ≥ 30fps | CADisplayLink 回调间隔 |
| 解析吞吐量 | ≥ 50 MB/s (Release) | PerformanceBaselineTests |
| 50 命令后 RSS 增长 | < 50 MB | Instruments Allocations |
| 内存泄漏 | 0 | Instruments Leaks |

### Phase F 里程碑

- [ ] B01-B12 全部通过
- [ ] 性能指标达标
- [ ] `make ci` 全流程通过
- [ ] Git tag: v0.1
- [ ] Git commit: "V0.1 Phase F: 集成验收通过，V0.1 发布"

---

## 9. 任务依赖全景图

```
A1 (exitHandler) ──────────────────────────────┐
A2 (send callback) ────────────────────────────┤
A3 (scrollback) ───────────────────────────────┤
A4 (SessionState) ─────────────────────────────┤
A5 (Protocol migration) ───────────────────────┤
                                                ↓
                                     Phase A 里程碑验证
                                                ↓
B1 (RenderCoordinator) ────────────────────────┐
B2 (CoreTextRenderer) ─────────────────────────┤
                                                ↓
                                     Phase B 里程碑验证
                                                ↓
C1 (DefaultTerminalPipeline) ──────────────────┐
C2 (管线集成测试) ─────────────────────────────┤
                                                ↓
                                     Phase C 里程碑验证
                                                ↓
D1 (Session 协议) ─────────────────────────────┐
D2 (TerminalSession) ─────────────────────────┤
D3 (SessionRegistry) ─────────────────────────┤
D4 (Session 测试) ─────────────────────────────┤
                                                ↓
                                     Phase D 里程碑验证
                                                ↓
E1 (InputHandler) ─────────────────────────────┐
E2 (TerminalView) ─────────────────────────────┤
E3 (WindowController) ─────────────────────────┤
E4 (AppDelegate) ──────────────────────────────┤
                                                ↓
                                     Phase E 里程碑验证
                                                ↓
F1-F6 (B01-B12 验收) ─────────────────────────→ V0.1 发布
```

**Phase 内部并行度：**
- Phase A: A1-A3 可并行，A4 需在 A1 之后（exitHandler 用到 exitCode），A5 最后执行
- Phase B: B1 和 B2 可并行
- Phase C: C1 先，C2 后
- Phase D: D1 先，D2/D3 可并行，D4 最后
- Phase E: E1 可独立开发，E2 依赖 B2+E1，E3 依赖 E2，E4 最后

---

## 10. 风险与注意事项

| 风险 | 影响 | 缓解措施 |
|------|------|---------|
| SwiftTerm scrollback API 可能不暴露 | A3 实现受阻 | 实施前先验证 API，必要时直接访问 terminal.buffer.lines |
| CoreTextRenderer 性能不达标 (< 30fps) | B09 性能验收 | 先实现功能正确性，性能优化延后；行级脏区已是第一层优化 |
| vttest 通过率不达 80% | B09 | 分析失败项，优先修复高影响项；低影响项可标记为已知限制（V0.2 修复） |
| TerminalSession 跨模块依赖 | D2 | 采用管线注入模式（外部创建 Pipeline，注入 Session），避免 TerminalCore 依赖 TerminalUI |
| macOS 权限问题（PTY/fork） | 运行时 | 确保 App Sandbox 保持 disabled；签名证书有效 |
