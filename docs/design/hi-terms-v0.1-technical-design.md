# Hi-Terms V0.1 技术设计文档 — 终端内核启动

**文档类型:** 技术设计
**产品名称:** Hi-Terms
**版本:** v0.1
**语言:** 中文
**关联文档:**
- [Roadmap](../reqs/hi-terms-roadmap.md)（版本定义与交付物）
- [V0.0 技术设计](hi-terms-v0.0-technical-design.md)（工程基线，V0.1 直接继承）
- [技术选型决策](../decisions/hi-terms-technical-decisions.md)（技术选型依据）
- [需求文档](../reqs/hi-terms-requirements.md)（四层架构定义）
- [SwiftTerm 评估报告](../decisions/hi-terms-swiftterm-evaluation.md)（SwiftTerm 评估结论与 Strategy B 决策）
- [V0.1 验收标准](../reqs/hi-terms-v0.1-acceptance.md)（V0.1 验收标准权威来源）
- [术语表](../SSOT/glossary.md)（术语权威定义）

---

## 1. 版本目标

V0.1 是第一个交付用户可见功能的版本，目标是搭建最小可运行的终端内核，跑通完整的 PTY + Shell + 渲染管线。

**核心目标：**

1. 实现完整的数据管线：PTY → SwiftTermAdapter → ScreenBuffer → DirtyRegion → CoreTextRenderer → CALayer
2. 实现单窗口交互式终端：可启动 shell、执行命令、运行 TUI 应用
3. 建立 Session Foundation 基础抽象，为后续版本的 Tab、分屏、Session Host 铺路
4. 达到 vttest 基础测试项 ≥ 80% 通过率

**V0.1 不包含：**

- Tab 管理和多窗口支持（V0.2）
- 256 色 / True Color 渲染（V0.2，但 SwiftTerm 和类型系统已支持）
- 分屏（V0.3）
- Metal 渲染加速（V0.4）
- 剪贴板集成（V0.2）
- Profile / 主题系统（V0.5）
- IME 输入法支持（V0.2，V0.1 仅支持 ASCII 字符输入和 Ctrl 组合键）
- 完整 Session Host 状态机（7 状态，V0.7）
- CI/CD 流水线搭建（V0.1 期间完成，但不属于终端内核交付物）
- SIGWINCH 窗口大小调整通知（V0.2，V0.1 为固定窗口尺寸）

---

## 2. 前置依赖与继承

V0.1 直接继承 V0.0 的全部工程基础设施，不重复搭建：

| V0.0 产出 | V0.1 使用方式 |
|-----------|-------------|
| SPM 模块结构（5 个 Package） | 在现有模块中填充实现代码 |
| SwiftTermAdapter（Strategy B） | 作为 TerminalParser 的唯一实现使用 |
| PTYProcess（forkpty + DispatchIO） | 作为 PTY 管理的基础，集成到 Session 中 |
| ScreenBuffer + ScreenBufferSnapshot | 直接使用，可能根据需要扩展 |
| DirtyRegion（线程安全） | 在渲染管线中直接使用 |
| FontMetrics | 在 CoreTextRenderer 中直接使用 |
| TerminalPipeline 协议 | **迁移至 TerminalCore 模块**（解决 Session 协议循环依赖），stub 替换为完整实现 |
| AppConfig / DefaultConfig | 读取字体、字号、shell 路径等配置 |
| OSLog 子系统 | 在新增代码中沿用相同的日志模式 |
| 测试基础设施 | 在现有测试目标中扩展测试用例 |

**关键决策继承（不可变更）：**

- Swift + AppKit（非 SwiftUI）
- SwiftTerm v1.13.0 Strategy B（SwiftTerm 持有状态，Hi-Terms 读取快照）
- CoreText + CALayer 渲染（非 Metal）
- macOS 14.0 最低部署目标
- GCD 并发模型（DispatchQueue，非 Swift Concurrency Actor）

---

## 3. 核心数据流设计

### 3.1 输出管线（PTY → 屏幕）

```
┌─────────────────────────────────────────────────────────┐
│ Per-Session DispatchQueue (后台线程)                      │
│                                                          │
│  Shell 子进程 → PTY fd → DispatchIO 回调                  │
│       ↓                                                  │
│  PTYProcess.dataHandler(data)                            │
│       ↓                                                  │
│  SwiftTermAdapter.parse(data)                            │
│       ↓ (SwiftTerm 内部更新 Terminal 状态)                 │
│  SwiftTermDelegateAdapter.rangeChanged()                 │
│       ↓                                                  │
│  DirtyRegion.merge(rows:)                                │
│       ↓                                                  │
│  RenderCoordinator.submitSnapshot(adapter.createSnapshot)│
└──────────────────────────┬──────────────────────────────┘
                           │ os_unfair_lock 保护
                           ↓
┌──────────────────────────────────────────────────────────┐
│ Main Thread (CADisplayLink 回调)                         │
│                                                          │
│  RenderCoordinator.onDisplayLink()                       │
│       ↓ swapAndClear() 获取脏行 + 最新快照                │
│  CoreTextRenderer.render(snapshot, dirtyRegion, cursor)  │
│       ↓ CoreText 字形绘制                                │
│  CALayer 树更新 → 屏幕显示                                │
└──────────────────────────────────────────────────────────┘
```

### 3.2 输入管线（键盘/鼠标 → PTY）

```
Main Thread:
  NSEvent (keyDown / flagsChanged / mouseDown / mouseMoved / scrollWheel)
       ↓
  InputHandler.handle(event:) → Data?
       ↓ (将 NSEvent 转换为终端转义序列)
  Session.write(data:)
       ↓
  PTYProcess.write(data:) → PTY fd → Shell 子进程
```

### 3.3 线程切换点标注

| 步骤 | 线程 | 说明 |
|------|------|------|
| PTY 读取 | per-Session DispatchQueue | DispatchIO 回调自动在指定队列执行 |
| 解析 + Buffer 更新 | per-Session DispatchQueue | 与 PTY 读取同队列，无跨线程开销 |
| DirtyRegion 标记 | per-Session DispatchQueue | os_unfair_lock 保护 |
| RenderCoordinator 提交快照 | per-Session DispatchQueue | os_unfair_lock 保护写入 |
| CADisplayLink 回调 | Main Thread | os_unfair_lock 保护读取 |
| CoreText 渲染 | Main Thread | CALayer 操作必须在主线程 |
| 键盘/鼠标事件 | Main Thread | NSEvent 回调在主线程 |
| PTY 写入 | Main Thread → 直接写 fd | write() 是线程安全的 POSIX 调用 |

---

## 4. Session Foundation 规格

### 4.1 设计目标

Session Foundation 是 V0.1 前移的架构投资（原计划 V0.6），目标是在终端内核启动时就建立统一的 Session 抽象，使后续版本可基于此逐步扩展：

- V0.2 Tab：每个 Tab 对应一个 Session
- V0.3 分屏：每个窗格对应一个 Session
- V0.4 AI CLI：Session 承载进程管理
- V0.7 Session Host：完整 7 状态生命周期
- Phase 2：Session 对外暴露 API

### 4.2 核心类型

```swift
// 已在 V0.0 定义，V0.1 保持不变
public typealias SessionID = UUID

// V0.1 扩展：仅 2 个状态（V0.7 扩展到 7 个）
public enum SessionState: Sendable {
    case running
    case exited(code: Int32)  // V0.1 扩展：携带退出码
}
```

### 4.3 Session 协议

```swift
/// Session 代表一个终端会话的完整生命周期。
/// V0.1 只有一个具体实现 TerminalSession。
/// 后续版本可通过协议扩展增加能力（如持久化、外部 API）。
public protocol Session: AnyObject {
    /// 唯一标识符
    var id: SessionID { get }

    /// 当前状态
    var state: SessionState { get }

    /// 创建时间
    var createdAt: Date { get }

    /// 启动命令（shell 路径）
    var launchCommand: String { get }

    /// 关联的 TerminalPipeline（管线所有权归 Session）
    var pipeline: TerminalPipeline { get }

    /// 启动会话：创建 PTY、启动 shell、连接管线
    func start() throws

    /// 停止会话：终止 PTY、清理资源
    func stop()

    /// 向 PTY 写入数据
    func write(data: Data)

    /// 调整终端尺寸（V0.2 实际使用，V0.1 预留接口）
    func resize(cols: Int, rows: Int)

    /// 状态变更回调
    var onStateChanged: ((SessionState) -> Void)? { get set }
}
```

### 4.4 TerminalSession 具体实现

```swift
/// V0.1 的唯一 Session 实现
public final class TerminalSession: Session {
    public let id: SessionID = UUID()
    public private(set) var state: SessionState = .running
    public let createdAt: Date = Date()
    public let launchCommand: String

    public let pipeline: TerminalPipeline
    public var onStateChanged: ((SessionState) -> Void)?

    // 内部持有
    private let ptyProcess: PTYProcess
    private let config: AppConfig

    public init(config: AppConfig) {
        self.config = config
        self.launchCommand = config.shellPath
        // 创建 PTYProcess 和 TerminalPipeline（详见 §6）
    }

    public func start() throws { ... }
    public func stop() { ... }
    public func write(data: Data) { ... }
    public func resize(cols: Int, rows: Int) { ... }
}
```

**所有权关系：**

```
TerminalSession (强引用)
    ├── PTYProcess (独占持有，Session 销毁时终止 PTY)
    ├── TerminalPipeline (独占持有)
    │     ├── SwiftTermAdapter (parser)
    │     ├── ScreenBuffer
    │     └── RenderCoordinator
    └── onStateChanged (闭包回调)
```

> **关键约束：** PTY 实例必须通过 Session 持有和管理（非直接由视图层持有）。Session 是 PTY 生命周期的唯一管理者。TerminalView 通过 Session 访问 pipeline，不直接持有 PTYProcess。

### 4.5 SessionRegistry

```swift
/// 全局 Session 注册表，管理所有活跃 Session。
/// 线程安全：使用 GCD 串行队列保护内部状态。
public final class SessionRegistry {
    public static let shared = SessionRegistry()

    private let queue = DispatchQueue(label: "com.hiterms.session-registry")
    private var sessions: [SessionID: Session] = [:]

    /// 注册新 Session
    public func register(_ session: Session) {
        queue.sync { sessions[session.id] = session }
    }

    /// 注销 Session
    public func unregister(_ sessionID: SessionID) {
        queue.sync { sessions.removeValue(forKey: sessionID) }
    }

    /// 查询所有活跃 Session
    public func allSessions() -> [Session] {
        queue.sync { Array(sessions.values) }
    }

    /// 按 ID 查询
    public func session(for id: SessionID) -> Session? {
        queue.sync { sessions[id] }
    }

    /// 活跃 Session 数量
    public var count: Int {
        queue.sync { sessions.count }
    }
}
```

**线程安全策略选择：GCD 串行队列（非 Actor）**

理由：
- V0.1 整体并发模型基于 GCD（技术决策已锁定）
- SessionRegistry 操作简单（CRUD），不需要 Actor 的 async/await 语义
- 与 TerminalSession、PTYProcess 的 GCD 队列模型保持一致
- V0.2+ 如需迁移到 Actor，协议层已预留扩展空间

### 4.6 Session 生命周期

```
┌─────────────────────────────────────────────────────┐
│ V0.1 Session 状态机（2 状态）                         │
│                                                      │
│  ┌──────────┐   start()    ┌───────────┐            │
│  │ (created) │ ──────────→ │  running   │            │
│  └──────────┘              └─────┬─────┘            │
│                                  │                   │
│                    Shell 退出 / stop()                │
│                                  │                   │
│                            ┌─────▼─────┐            │
│                            │   exited   │            │
│                            └───────────┘            │
└─────────────────────────────────────────────────────┘
```

**状态转换触发条件：**

| 转换 | 触发条件 | 处理逻辑 |
|------|---------|---------|
| created → running | `session.start()` 调用成功 | 创建 PTY、启动 shell、连接 dataHandler、注册到 Registry |
| running → exited | Shell 子进程退出（SIGCHLD / EOF） | 记录退出码、清理 DispatchIO、触发 `onStateChanged`、从 Registry 注销 |
| running → exited | `session.stop()` 显式调用 | 发送 SIGHUP → 等待 → SIGKILL、清理资源 |

**Shell 退出检测机制：**

> **V0.1 变更：PTYProcess 需新增 `exitHandler` 属性。** V0.0 的 PTYProcess 在 EOF 时仅做 `source.cancel()` + 日志，不采集退出码也不触发回调。V0.1 必须扩展 PTYProcess 以支持 Session 生命周期管理。

PTYProcess 需新增以下接口：

```swift
// PTYProcess V0.1 新增
public var exitHandler: ((Int32) -> Void)?
```

在 DispatchSource 的读取回调中，EOF 时触发退出流程：

```swift
// PTYProcess.setupReading() 内部修改
source.setEventHandler { [weak self] in
    guard let self = self else { return }
    var buffer = [UInt8](repeating: 0, count: 8192)
    let bytesRead = Darwin.read(self.masterFD, &buffer, buffer.count)

    if bytesRead > 0 {
        let data = Data(buffer[0..<bytesRead])
        self.dataHandler?(data)
        self.asyncContinuation?.yield(data)
    } else if bytesRead <= 0 {
        // EOF：Shell 已退出
        self.asyncContinuation?.finish()
        var status: Int32 = 0
        waitpid(self.pid, &status, WNOHANG)
        let exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1
        self.exitHandler?(exitCode)
        source.cancel()
        PTYLog.lifecycle.info("PTY read ended: pid=\(self.pid), exitCode=\(exitCode)")
    }
}
```

---

## 5. CoreTextRenderer 实现方案

### 5.1 职责

CoreTextRenderer 是 TerminalRendering 协议的唯一实现（V0.1），负责将 ScreenBufferSnapshot 的字符和属性渲染为可视化的终端界面。

### 5.2 渲染架构

```
TerminalView (NSView)
    └── rootLayer (CALayer, 由 NSView.wantsLayer = true 启用)
         ├── backgroundLayer (CALayer, 整体背景色)
         ├── textLayer (CALayer, 文本内容)
         │    └── draw(in:) 时使用 CoreText 绘制字符
         └── cursorLayer (CALayer, 光标)
              └── 通过 opacity 动画实现闪烁
```

### 5.3 文本绘制流程

```swift
public final class CoreTextRenderer: TerminalRendering {
    private var fontMetrics: FontMetrics
    private let font: CTFont

    public func render(
        buffer: ScreenBufferSnapshot,
        dirtyRegion: DirtyRegion,
        cursor: CursorState,
        into layer: CALayer
    ) {
        let dirtyRows = dirtyRegion.swapAndClear()
        guard !dirtyRows.isEmpty else { return }

        // 在 textLayer 的 draw(in:) 中：
        for row in dirtyRows {
            let y = CGFloat(row) * fontMetrics.cellHeight
            // 1. 绘制该行背景色（逐 cell 检查 backgroundColor）
            drawRowBackground(buffer: buffer, row: row, y: y, context: context)
            // 2. 绘制该行文本（合并相同属性的连续字符为一个 CTLine）
            drawRowText(buffer: buffer, row: row, y: y, context: context)
        }

        // 更新光标位置和可见性
        updateCursor(cursor: cursor, fontMetrics: fontMetrics, cursorLayer: cursorLayer)
    }
}
```

**行内文本绘制策略：**

```
对于一行中的字符：
  1. 扫描找出连续相同属性（字体样式+前景色）的字符段（run）
  2. 对每个 run：
     a. 创建 CFAttributedString（字符 + 属性字典）
     b. 创建 CTLine
     c. 设置绘制位置 (col * cellWidth, y + baseline)
     d. CTLineDraw(line, context)
  3. 如果字符有 inverse 属性，交换前景/背景色
  4. 如果字符有 underline/strikethrough，额外绘制装饰线
```

### 5.4 颜色映射

V0.1 仅支持基础 ANSI 8 色（前景 + 背景），256 色和 True Color 在 V0.2 激活。

```swift
/// V0.1 ANSI 8 色映射表
private func nsColor(from color: TerminalColor, isForeground: Bool) -> NSColor {
    switch color {
    case .default:
        return isForeground ? .textColor : .textBackgroundColor
    case .defaultInverted:
        return isForeground ? .textBackgroundColor : .textColor
    case .ansi256(let code) where code < 8:
        return Self.ansi8Colors[Int(code)]
    case .ansi256(let code) where code < 16:
        // 明亮色：V0.1 映射到同一组基础色
        return Self.ansi8Colors[Int(code) - 8]
    case .ansi256, .trueColor:
        // V0.2 支持，V0.1 回退到默认色
        return isForeground ? .textColor : .textBackgroundColor
    }
}

private static let ansi8Colors: [NSColor] = [
    .black,                          // 0: Black
    NSColor(red: 0.8, green: 0.0, blue: 0.0, alpha: 1.0),  // 1: Red
    NSColor(red: 0.0, green: 0.8, blue: 0.0, alpha: 1.0),  // 2: Green
    NSColor(red: 0.8, green: 0.8, blue: 0.0, alpha: 1.0),  // 3: Yellow
    NSColor(red: 0.0, green: 0.0, blue: 0.8, alpha: 1.0),  // 4: Blue
    NSColor(red: 0.8, green: 0.0, blue: 0.8, alpha: 1.0),  // 5: Magenta
    NSColor(red: 0.0, green: 0.8, blue: 0.8, alpha: 1.0),  // 6: Cyan
    NSColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1.0),  // 7: White
]
```

### 5.5 光标渲染

```swift
/// 光标层：独立 CALayer，通过位置和动画控制
private func updateCursor(cursor: CursorState, fontMetrics: FontMetrics, cursorLayer: CALayer) {
    guard cursor.visible else {
        cursorLayer.isHidden = true
        return
    }
    cursorLayer.isHidden = false

    let x = CGFloat(cursor.col) * fontMetrics.cellWidth
    let y = CGFloat(cursor.row) * fontMetrics.cellHeight

    switch cursor.style {
    case .block, .blinkingBlock:
        cursorLayer.frame = CGRect(x: x, y: y, width: fontMetrics.cellWidth, height: fontMetrics.cellHeight)
    case .underline, .blinkingUnderline:
        cursorLayer.frame = CGRect(x: x, y: y + fontMetrics.cellHeight - 2, width: fontMetrics.cellWidth, height: 2)
    case .bar, .blinkingBar:
        cursorLayer.frame = CGRect(x: x, y: y, width: 2, height: fontMetrics.cellHeight)
    }

    // 闪烁动画
    let shouldBlink = [.blinkingBlock, .blinkingUnderline, .blinkingBar].contains(cursor.style)
    if shouldBlink && cursorLayer.animation(forKey: "blink") == nil {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.0
        animation.duration = 0.5
        animation.autoreverses = true
        animation.repeatCount = .infinity
        cursorLayer.add(animation, forKey: "blink")
    } else if !shouldBlink {
        cursorLayer.removeAnimation(forKey: "blink")
    }
}
```

### 5.6 脏区增量渲染策略

V0.1 采用行级脏区粒度（与 DirtyRegion 的 IndexSet 行追踪一致）：

1. **普通命令输出**：仅重绘变化的行（通常 1-5 行），效率高
2. **全屏 TUI 应用**（vim、top）：全部行标脏，等效全屏重绘，但仍通过 DirtyRegion 机制触发（不是独立路径）
3. **快速滚动输出**：CADisplayLink 限制 60fps，多次 buffer 更新合并为一次渲染，自动跳帧

> V0.4 可进一步细化到 cell 级脏区追踪，但 V0.1 行级粒度足够。

---

## 6. TerminalPipeline 完整实现

### 6.1 从 Stub 到真实管线

V0.0 的 `TerminalPipelineStub` 替换为 `DefaultTerminalPipeline`：

```swift
public final class DefaultTerminalPipeline: TerminalPipeline {
    public let parser: any TerminalParser
    public let screenBuffer: ScreenBuffer
    public let dirtyRegion: DirtyRegion
    public let renderCoordinator: RenderCoordinator

    private let ptyProcess: PTYProcess
    private let adapter: SwiftTermAdapter

    public init(ptyProcess: PTYProcess, config: AppConfig) {
        self.ptyProcess = ptyProcess
        self.adapter = SwiftTermAdapter(cols: config.terminalCols, rows: config.terminalRows)
        self.parser = adapter
        self.screenBuffer = ScreenBuffer(rows: config.terminalRows, cols: config.terminalCols)
        self.dirtyRegion = DirtyRegion()
        self.renderCoordinator = RenderCoordinator(dirtyRegion: dirtyRegion)

        // 连接 SwiftTermAdapter 的 rangeChanged → DirtyRegion
        // （通过 TerminalParserDelegate 回调）
    }

    public func start() {
        // 连接 PTY 数据到 parser
        ptyProcess.setDataHandler { [weak self] data in
            self?.adapter.parse(data: data)
        }
    }

    public func stop() {
        ptyProcess.terminate()
    }

    public func write(data: Data) {
        ptyProcess.write(data: data)
    }

    public func resize(cols: Int, rows: Int) {
        ptyProcess.resize(cols: UInt16(cols), rows: UInt16(rows))
        adapter.terminal.resize(cols: cols, rows: rows)
    }
}
```

### 6.2 RenderCoordinator

```swift
/// 协调后台线程的 buffer 更新与主线程的渲染节奏。
/// CADisplayLink 回调驱动渲染，确保最大 60fps。
public final class RenderCoordinator {
    private var displayLink: CADisplayLink?
    private var lock = os_unfair_lock()
    private var latestSnapshot: ScreenBufferSnapshot?
    private let dirtyRegion: DirtyRegion

    weak var renderer: TerminalRendering?
    weak var targetLayer: CALayer?

    public init(dirtyRegion: DirtyRegion) {
        self.dirtyRegion = dirtyRegion
    }

    /// 启动渲染循环（在主线程调用）
    public func startDisplayLink() {
        let link = CADisplayLink(target: self, selector: #selector(onDisplayLink))
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    /// 停止渲染循环
    public func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// 后台线程调用：提交新快照
    public func submitSnapshot(_ snapshot: ScreenBufferSnapshot) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        latestSnapshot = snapshot
    }

    /// CADisplayLink 回调（主线程）
    @objc private func onDisplayLink() {
        os_unfair_lock_lock(&lock)
        let snapshot = latestSnapshot
        os_unfair_lock_unlock(&lock)

        guard let snapshot, let renderer, let targetLayer else { return }

        let cursor = snapshot.cursor
        renderer.render(
            buffer: snapshot,
            dirtyRegion: dirtyRegion,
            cursor: cursor,
            into: targetLayer
        )
    }
}
```

### 6.3 Pipeline 与 SwiftTermAdapter 的集成

由于 Strategy B（SwiftTerm 持有状态），ScreenBuffer 快照直接从 SwiftTermAdapter 获取，而非通过 ParserAction 回调逐步更新：

```
PTY 数据到达
    ↓
SwiftTermAdapter.parse(data:)
    ↓ (SwiftTerm 内部更新 Terminal 对象)
SwiftTermDelegateAdapter.rangeChanged(startY:, endY:)
    ↓
DirtyRegion.merge(rows: startY..<endY)
    ↓
let snapshot = adapter.createSnapshot()
RenderCoordinator.submitSnapshot(snapshot)
```

> **注意：** 在 Strategy B 下，TerminalPipeline 的 `screenBuffer` 属性仍然存在（协议要求），但不作为渲染数据源。渲染使用 `SwiftTermAdapter.createSnapshot()` 生成的快照。`screenBuffer` 属性可用于测试和外部查询。

### 6.4 终端响应序列回传（send() 回调）

> **V0.1 变更：SwiftTermDelegateAdapter.send() 必须实现。** V0.0 中 `send(source:data:)` 是空操作。SwiftTerm 通过此回调发送终端响应序列（Device Attributes、Cursor Position Report、Primary DA 等）回 PTY。空操作会导致：
> - vttest 发送查询无响应，B09（vttest ≥80%）不达标
> - 部分 TUI 应用依赖 DA 响应判断终端能力

**实现方式：** SwiftTermAdapter 持有一个 `sendHandler` 闭包，由 DefaultTerminalPipeline 在初始化时注入，将数据写回 PTYProcess：

```swift
// SwiftTermAdapter V0.1 新增
public var sendHandler: ((Data) -> Void)?

// SwiftTermDelegateAdapter V0.1 修改
private class SwiftTermDelegateAdapter: TerminalDelegate {
    var onBufferUpdated: (() -> Void)?
    var onSendData: ((Data) -> Void)?       // V0.1 新增

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        let bytes = Data(data)
        onSendData?(bytes)                   // V0.1: 回传到 PTY
    }
    // ... 其余不变
}

// SwiftTermAdapter.init 中连接：
delegateAdapter.onSendData = { [weak self] data in
    self?.sendHandler?(data)
}

// DefaultTerminalPipeline.init 中注入：
adapter.sendHandler = { [weak ptyProcess] data in
    ptyProcess?.write(data: data)
}
```

---

## 7. TerminalView 设计

### 7.1 NSView 子类结构

```swift
/// 终端视图：NSView 子类，负责显示终端内容和处理用户输入。
/// 不直接持有 PTYProcess，通过 Session 间接访问。
public final class TerminalView: NSView {
    // 渲染相关
    private var textLayer: CALayer!
    private var cursorLayer: CALayer!
    private let renderer: CoreTextRenderer
    private let fontMetrics: FontMetrics

    // 输入处理
    private let inputHandler: InputHandler

    // 数据源：通过 Session 访问
    private weak var session: TerminalSession?

    // 滚动
    private var scrollbackOffset: Int = 0

    public init(session: TerminalSession, frame: NSRect) {
        // 初始化渲染器、输入处理器
        // 设置 layer-backed view
        // 配置 CADisplayLink
    }
}
```

### 7.2 Layer 设置

```swift
extension TerminalView {
    private func setupLayers() {
        wantsLayer = true
        guard let rootLayer = layer else { return }

        // 背景层
        rootLayer.backgroundColor = NSColor.textBackgroundColor.cgColor

        // 文本层（自定义绘制）
        textLayer = CALayer()
        textLayer.delegate = self  // 实现 draw(in:) 进行 CoreText 绘制
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        rootLayer.addSublayer(textLayer)

        // 光标层
        cursorLayer = CALayer()
        cursorLayer.backgroundColor = NSColor.textColor.cgColor
        rootLayer.addSublayer(cursorLayer)
    }
}
```

### 7.3 键盘事件处理

```swift
extension TerminalView {
    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        guard let data = inputHandler.handleKeyDown(event) else { return }
        session?.write(data: data)
    }

    public override func flagsChanged(with event: NSEvent) {
        // 仅追踪修饰键状态，不产生输出
        inputHandler.updateModifiers(event.modifierFlags)
    }
}
```

### 7.4 鼠标事件处理

```swift
extension TerminalView {
    public override func mouseDown(with event: NSEvent) {
        guard let data = inputHandler.handleMouseEvent(event, type: .press, in: self) else { return }
        session?.write(data: data)
    }

    public override func mouseUp(with event: NSEvent) {
        guard let data = inputHandler.handleMouseEvent(event, type: .release, in: self) else { return }
        session?.write(data: data)
    }

    public override func mouseMoved(with event: NSEvent) {
        guard let data = inputHandler.handleMouseEvent(event, type: .move, in: self) else { return }
        session?.write(data: data)
    }

    /// 将鼠标像素坐标转换为终端网格坐标
    private func terminalCoordinate(for event: NSEvent) -> (col: Int, row: Int) {
        let point = convert(event.locationInWindow, from: nil)
        let col = Int(point.x / fontMetrics.cellWidth)
        let row = Int(point.y / fontMetrics.cellHeight)
        return (col: max(0, col), row: max(0, row))
    }
}
```

### 7.5 滚动实现

V0.1 采用 **自定义滚动**（非 NSScrollView），原因：
- 终端滚动逻辑与标准 UI 滚动不同（scrollback 是历史内容，不是可视区域偏移）
- SwiftTerm 的 Terminal 对象管理 scrollback buffer，直接读取即可
- NSScrollView 的 contentView 偏移模型与终端 scrollback 不匹配

```swift
extension TerminalView {
    public override func scrollWheel(with event: NSEvent) {
        let delta = Int(event.scrollingDeltaY)
        scrollbackOffset = max(0, scrollbackOffset + delta)
        // 标记全部行为脏，触发重绘
        // （V0.2 可优化为仅标记变化行）
        setNeedsDisplay(bounds)
    }
}
```

### 7.6 Scrollback 快照支持

> **V0.1 变更：SwiftTermAdapter.createSnapshot() 需扩展支持 scrollback。** V0.0 的 `createSnapshot()` 仅遍历 `0..<terminal.rows`（可见区域），无法支持 B06 滚动验收。

SwiftTerm 的 `Terminal` 对象通过 `getScrollInvariantLine(row:)` 方法提供 scrollback 行访问（负数行号表示 scrollback 区域）。V0.1 扩展 `createSnapshot()` 支持 scrollback offset：

```swift
// SwiftTermAdapter V0.1 扩展
public func createSnapshot(scrollbackOffset: Int = 0) -> ScreenBufferSnapshot {
    let rows = terminal.rows
    let cols = terminal.cols
    var cells = [[Cell]]()
    cells.reserveCapacity(rows)

    for visibleRow in 0..<rows {
        // scrollbackOffset > 0 时，向上偏移读取 scrollback 区域
        let bufferRow = visibleRow - scrollbackOffset
        guard let line = terminal.getScrollInvariantLine(row: bufferRow) else {
            cells.append(Array(repeating: .empty, count: cols))
            continue
        }
        var rowCells = [Cell]()
        rowCells.reserveCapacity(cols)
        for col in 0..<cols {
            if col < line.count {
                let cd = line[col]
                rowCells.append(Cell(
                    character: cd.getCharacter(),
                    attributes: mapAttributes(cd.attribute)
                ))
            } else {
                rowCells.append(.empty)
            }
        }
        cells.append(rowCells)
    }

    // scrollback 模式下光标不可见（历史内容无活跃光标）
    let cursorVisible = scrollbackOffset == 0
    return ScreenBufferSnapshot(
        cells: cells,
        cursor: CursorState(
            row: terminal.buffer.y,
            col: terminal.buffer.x,
            visible: cursorVisible
        ),
        rows: rows,
        cols: cols
    )
}
```

> **注意：** 需验证 SwiftTerm v1.13.0 是否暴露 `getScrollInvariantLine(row:)` API。如未暴露，替代方案是直接访问 `terminal.buffer.lines` 的底层 CircularList，或通过 `terminal.getLine(row:)` 加行号偏移计算。实现时以 SwiftTerm API 实际可用性为准。

---

## 8. InputHandler 设计

### 8.1 职责

将 NSEvent 转换为终端可识别的字节序列（VT100/xterm 转义序列）。

### 8.2 键盘映射

```swift
public final class InputHandler {
    private var modifiers: NSEvent.ModifierFlags = []

    /// 处理键盘事件，返回要写入 PTY 的字节数据
    public func handleKeyDown(_ event: NSEvent) -> Data? {
        let keyCode = event.keyCode
        let modifiers = event.modifierFlags

        // Cmd 键组合保留给应用快捷键，不传递到终端
        if modifiers.contains(.command) { return nil }

        // Ctrl 组合键
        if modifiers.contains(.control) {
            return handleCtrlKey(event)
        }

        // 特殊键映射
        if let specialData = handleSpecialKey(keyCode: keyCode) {
            return specialData
        }

        // 普通字符
        guard let characters = event.characters else { return nil }
        return characters.data(using: .utf8)
    }
}
```

### 8.3 特殊键映射表

| 键 | NSEvent keyCode | 终端序列 | 说明 |
|----|----------------|---------|------|
| Return | 36 | `\r` (0x0D) | 回车 |
| Backspace | 51 | `\u{7F}` (0x7F) | DEL 字符 |
| Tab | 48 | `\t` (0x09) | 水平制表 |
| Escape | 53 | `\u{1B}` (0x1B) | ESC |
| Up Arrow | 126 | `\u{1B}[A` | 光标上移 |
| Down Arrow | 125 | `\u{1B}[B` | 光标下移 |
| Right Arrow | 124 | `\u{1B}[C` | 光标右移 |
| Left Arrow | 123 | `\u{1B}[D` | 光标左移 |
| Home | 115 | `\u{1B}[H` | 行首 |
| End | 119 | `\u{1B}[F` | 行末 |
| Page Up | 116 | `\u{1B}[5~` | 上翻页 |
| Page Down | 121 | `\u{1B}[6~` | 下翻页 |
| Delete (Fn+Backspace) | 117 | `\u{1B}[3~` | 删除 |

### 8.4 Ctrl 组合键映射

```swift
private func handleCtrlKey(_ event: NSEvent) -> Data? {
    guard let char = event.charactersIgnoringModifiers?.first else { return nil }
    let asciiValue = char.asciiValue ?? 0

    // Ctrl+A(0x01) 到 Ctrl+Z(0x1A)
    if asciiValue >= 0x61 && asciiValue <= 0x7A {  // a-z
        let controlCode = asciiValue - 0x60
        return Data([controlCode])
    }

    // 特殊 Ctrl 组合
    switch char {
    case "[": return Data([0x1B])  // Ctrl+[ = ESC
    case "\\": return Data([0x1C]) // Ctrl+\
    case "]": return Data([0x1D])  // Ctrl+]
    case "/": return Data([0x1F])  // Ctrl+/
    default: return nil
    }
}
```

### 8.5 鼠标事件编码（SGR 模式）

```swift
/// SGR 鼠标报告格式：ESC [ < Cb ; Cx ; Cy M/m
/// M = 按下，m = 释放
public func handleMouseEvent(_ event: NSEvent, type: MouseEventType, in view: TerminalView) -> Data? {
    let (col, row) = view.terminalCoordinate(for: event)
    let button: Int
    switch type {
    case .press:
        switch event.buttonNumber {
        case 0: button = 0   // 左键
        case 1: button = 2   // 右键
        case 2: button = 1   // 中键
        default: return nil
        }
    case .release:
        button = 0  // SGR 释放不区分按钮
    case .move:
        button = 35  // 移动事件
    }

    let suffix = type == .release ? "m" : "M"
    let sequence = "\u{1B}[<\(button);\(col + 1);\(row + 1)\(suffix)"
    return sequence.data(using: .utf8)
}

public enum MouseEventType {
    case press
    case release
    case move
}
```

---

## 9. 窗口管理流程

### 9.1 启动流程

```
AppDelegate.applicationDidFinishLaunching()
    ↓
创建 DefaultConfig
    ↓
创建 TerminalSession(config: config)
    ↓
session.start()  // 创建 PTY、启动 shell
    ↓
SessionRegistry.shared.register(session)
    ↓
创建 TerminalWindowController(session: session)
    ↓
WindowController 创建 TerminalView(session: session)
    ↓
TerminalView 启动 RenderCoordinator.startDisplayLink()
    ↓
用户看到 shell 提示符
```

### 9.2 TerminalWindowController

```swift
/// V0.1 窗口控制器：管理单个终端窗口
public final class TerminalWindowController: NSWindowController {
    private let session: TerminalSession
    private var terminalView: TerminalView!

    public init(session: TerminalSession) {
        self.session = session

        // 创建窗口
        let contentRect = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Hi-Terms"
        window.center()

        super.init(window: window)

        // 创建 TerminalView
        terminalView = TerminalView(session: session, frame: contentRect)
        window.contentView = terminalView
        window.makeFirstResponder(terminalView)

        // 监听 Session 状态变更
        session.onStateChanged = { [weak self] state in
            if case .exited = state {
                DispatchQueue.main.async {
                    self?.window?.close()
                }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}
```

### 9.3 窗口关闭与资源清理

```
用户关闭窗口 / Shell 退出
    ↓
TerminalWindowController 收到关闭通知
    ↓
session.stop()
    ↓
PTYProcess.terminate() → 发送 SIGHUP → 等待 → SIGKILL
    ↓
RenderCoordinator.stopDisplayLink()
    ↓
SessionRegistry.shared.unregister(session.id)
    ↓
Session、Pipeline、PTYProcess 释放（ARC）
```

---

## 10. 线程模型详细设计

### 10.1 线程分配

| 线程 | 职责 | 机制 | V0.1 实例数 |
|------|------|------|-----------|
| Main Thread | UI 事件、CALayer 更新、CADisplayLink 回调 | MainActor / RunLoop | 1 |
| PTY I/O Queue | PTY fd 读取 + SwiftTermAdapter 解析 + 快照生成 | per-Session DispatchQueue | 1（V0.1 单窗口） |
| Session Registry Queue | Registry CRUD 操作 | 串行 DispatchQueue | 1（全局） |

### 10.2 数据保护

| 共享数据 | 写入线程 | 读取线程 | 保护机制 |
|---------|---------|---------|---------|
| SwiftTerm Terminal 对象 | PTY I/O Queue | PTY I/O Queue | 单线程访问（无竞争） |
| ScreenBufferSnapshot | PTY I/O Queue 创建 | Main Thread 消费 | os_unfair_lock（RenderCoordinator） |
| DirtyRegion | PTY I/O Queue merge | Main Thread swapAndClear | os_unfair_lock（DirtyRegion 内部） |
| SessionRegistry | 任意线程 | 任意线程 | 串行 DispatchQueue |
| PTY fd | PTY I/O Queue 读 / Main Thread 写 | — | POSIX write() 线程安全 |

### 10.3 避免的并发陷阱

1. **不在主线程解析 PTY 数据** — 大量输出时会阻塞 UI
2. **不在后台线程更新 CALayer** — AppKit 要求 UI 操作在主线程
3. **不跨线程共享 SwiftTerm Terminal 对象** — 无锁设计，单队列独占
4. **不使用 DispatchQueue.main.sync 从后台调用** — 避免死锁

---

## 11. TerminalPipeline 协议迁移与扩展

### 11.1 协议迁移（V0.1 架构变更）

> **V0.1 变更：TerminalPipeline 协议从 TerminalUI 迁移至 TerminalCore。**
>
> **原因：** Session 协议（TerminalCore）需要引用 `TerminalPipeline` 类型（`var pipeline: TerminalPipeline { get }`）。如果协议留在 TerminalUI，TerminalCore 需要 import TerminalUI，形成循环依赖（TerminalUI → TerminalCore → TerminalUI）。
>
> **方案：** 将 TerminalPipeline **协议定义**移至 TerminalCore，具体实现（`DefaultTerminalPipeline`、`TerminalPipelineStub`）留在 TerminalUI。协议本质上是核心抽象，放在 TerminalCore 符合模块职责。

**迁移步骤：**

1. 将 `TerminalPipeline` 协议定义从 `Packages/TerminalUI/Sources/TerminalUI/TerminalPipeline.swift` 移至 `Packages/TerminalCore/Sources/TerminalCore/TerminalPipeline.swift`
2. TerminalUI 的 Package.swift 已依赖 TerminalCore，无需修改依赖关系
3. TerminalPipeline 协议中引用的 `ScreenBuffer`、`TerminalParser` 均已在 TerminalCore 中定义
4. `DirtyRegion` 和 `RenderCoordinator` 在 TerminalRenderer 中 — 协议扩展时 TerminalCore 需新增对 TerminalRenderer 的依赖（见下方 11.2 的替代方案）
5. 更新 `TerminalPipelineStub` 和测试中的 import 语句

**TerminalCore 对 TerminalRenderer 的新依赖问题：**

TerminalPipeline 协议新增的 `dirtyRegion: DirtyRegion` 和 `renderCoordinator: RenderCoordinator` 属性引用了 TerminalRenderer 的类型。如果将协议放入 TerminalCore，则 TerminalCore 需要 import TerminalRenderer，改变了原有的依赖图。

**推荐解决方式：** TerminalPipeline 协议的核心定义仅保留 TerminalCore 已有的类型（`parser`、`screenBuffer`、生命周期方法），`dirtyRegion` 和 `renderCoordinator` 通过协议扩展或作为 `DefaultTerminalPipeline` 的实现细节（非协议要求）：

```swift
// TerminalCore/TerminalPipeline.swift — 协议核心定义
public protocol TerminalPipeline: AnyObject {
    var parser: any TerminalParser { get }
    var screenBuffer: ScreenBuffer { get }

    func start()
    func stop()
    func write(data: Data)
    func resize(cols: Int, rows: Int)
}
```

`dirtyRegion` 和 `renderCoordinator` 作为 `DefaultTerminalPipeline` 的公开属性（而非协议要求），由 TerminalView 通过具体类型访问：

```swift
// TerminalUI/DefaultTerminalPipeline.swift — 具体实现
public final class DefaultTerminalPipeline: TerminalPipeline {
    // 协议要求
    public let parser: any TerminalParser
    public let screenBuffer: ScreenBuffer

    // 实现特有属性（非协议要求，避免 TerminalCore 依赖 TerminalRenderer）
    public let dirtyRegion: DirtyRegion
    public let renderCoordinator: RenderCoordinator
    // ...
}
```

> 这样 TerminalCore 无需依赖 TerminalRenderer，保持原有模块依赖图不变。TerminalPipelineStub 也无需提供 dirtyRegion/renderCoordinator 的 no-op 实现。

---

## 12. 配置集成

### 12.1 V0.1 使用的配置项

| 配置项 | 来源 | 默认值 | 使用位置 |
|--------|------|--------|---------|
| fontName | AppConfig.fontName | "Menlo" | CoreTextRenderer 字体选择 |
| fontSize | AppConfig.fontSize | 13 | CoreTextRenderer + FontMetrics |
| shellPath | AppConfig.shellPath | SHELL 环境变量 or /bin/zsh | PTYConfiguration.shellPath |
| terminalCols | AppConfig.terminalCols | 80 | SwiftTermAdapter 初始列数 |
| terminalRows | AppConfig.terminalRows | 25 | SwiftTermAdapter 初始行数 |
| scrollbackLines | AppConfig.scrollbackLines | 10,000 | SwiftTerm Terminal scrollback 大小 |

### 12.2 配置读取路径

V0.1 使用 `DefaultConfig`（硬编码默认值），`UserDefaultsConfig` 保持 stub 状态。V0.5 Profile 系统完成后再激活 UserDefaults 持久化。

---

## 13. 模块文件清单

### 13.1 V0.1 新增文件

| 模块 | 文件 | 说明 |
|------|------|------|
| TerminalCore | `TerminalPipeline.swift` | **从 TerminalUI 迁入**，Pipeline 协议定义（见 §11.1） |
| TerminalCore | `Session.swift` | Session 协议定义 |
| TerminalCore | `TerminalSession.swift` | Session 具体实现 |
| TerminalCore | `SessionRegistry.swift` | 全局 Session 注册表 |
| TerminalRenderer | `CoreTextRenderer.swift` | CoreText 渲染实现 |
| TerminalRenderer | `RenderCoordinator.swift` | 渲染协调器（CADisplayLink） |
| TerminalUI | `DefaultTerminalPipeline.swift` | Pipeline 完整实现 |
| TerminalUI | `TerminalView.swift` | 终端 NSView |
| TerminalUI | `InputHandler.swift` | 键盘/鼠标事件处理 |
| TerminalUI | `TerminalWindowController.swift` | 窗口管理 |

### 13.2 V0.1 修改的现有文件

| 文件 | 修改内容 |
|------|---------|
| `TerminalCore/SessionTypes.swift` | SessionState.exited 增加退出码参数：`.exited(code: Int32)` |
| `TerminalCore/SwiftTermAdapter.swift` | 1) `send()` 回调实现（见 §6.4）2) `createSnapshot()` 支持 scrollback offset（见 §7.6） |
| `PTYKit/PTYProcess.swift` | 新增 `exitHandler: ((Int32) -> Void)?` 属性和退出码采集逻辑（见 §4.6） |
| `TerminalUI/TerminalPipeline.swift` | **删除**（协议定义迁移至 TerminalCore，仅保留 TerminalPipelineStub） |
| `HiTermsApp/AppDelegate.swift` | 替换空白窗口为 TerminalWindowController |
| `project.yml` | 更新源文件列表（如需要） |

---

## 14. 测试策略

### 14.1 单元测试扩展

| 测试目标 | 新增测试 | 覆盖范围 |
|---------|---------|---------|
| TerminalCoreTests | SessionTests | Session 创建、状态转换、Registry CRUD |
| TerminalRendererTests | CoreTextRendererTests | 颜色映射、FontMetrics 计算、光标位置 |
| TerminalUITests | InputHandlerTests | 键盘映射、Ctrl 组合键、鼠标事件编码 |
| TerminalUITests | DefaultTerminalPipelineTests | Pipeline 组装、start/stop 生命周期 |

### 14.2 集成测试

| 测试 | 验证内容 |
|------|---------|
| PTY → Parser → Snapshot | 发送 echo 命令，验证 snapshot 包含正确字符 |
| Session 生命周期 | 创建 Session → start → 执行命令 → Shell 退出 → state == .exited |
| 键盘输入 → PTY | 模拟 NSEvent → InputHandler → PTYProcess → 验证输出 |

### 14.3 vttest 验证

V0.1 要求 vttest 基础测试项通过率 ≥ 80%。验证方式：

1. 启动 Hi-Terms 应用
2. 在终端中运行 `vttest`
3. 执行菜单 1（VT100 测试）、菜单 2（光标移动）等基础测试
4. 通过自动化脚本或手动验证通过率

### 14.4 性能验证

| 指标 | V0.1 目标 | 测量方法 |
|------|----------|---------|
| 渲染帧率 | ≥ 30fps（普通操作） | CADisplayLink 回调间隔统计 |
| 解析吞吐量 | Release ≥ 50 MB/s | 已有 PerformanceBaselineTests |
| 内存稳定性 | 50 条命令后 RSS 增长 < 50MB | Instruments Allocations 追踪 |
| 无泄漏 | Instruments Leaks 零泄漏 | Instruments Leaks 检测 |

---

## 15. V0.1 与 V0.2 边界

| V0.1 | V0.2 |
|------|------|
| 单窗口 | Tab + 多窗口 |
| ANSI 8 色 | xterm-256color + True Color |
| 固定窗口大小 | 窗口调整 + SIGWINCH |
| 基础键盘（ASCII + Ctrl） | IME 输入法 + 剪贴板 |
| 自定义滚动（功能性） | 滚动优化 + 滚动条 |
| Session Foundation（2 状态） | Tab ↔ Session 映射 |
| DefaultConfig 硬编码 | 基础字体/字号设置 UI |
| 本地构建 | CI/CD 流水线（V0.1 期间搭建但不是内核交付物） |
| Shell 退出 → 窗口关闭 | Shell 退出提示 + 可选关闭 |

---

## 16. V0.1 破坏性变更清单

> 本节汇总 V0.1 对 V0.0 代码的所有破坏性变更，实施时应按此顺序执行以确保编译通过。

| # | 变更 | 影响范围 | 迁移步骤 |
|---|------|---------|---------|
| 1 | `TerminalPipeline` 协议从 TerminalUI 迁移至 TerminalCore | 所有 import TerminalUI 使用 TerminalPipeline 的文件 | 移动协议文件 → 更新 TerminalUI 中的 import → 确认 TerminalPipelineStub 编译通过 |
| 2 | `SessionState.exited` 增加关联值 `(code: Int32)` | SessionTypes.swift + 所有 `case .exited` 模式匹配 | 修改枚举定义 → 全局搜索 `.exited` → 更新为 `.exited(let code)` 或 `.exited(_)` |
| 3 | `PTYProcess` 新增 `exitHandler` 属性 | PTYProcess.swift 内部 | 添加属性 → 修改 `setupReading()` 的 EOF 分支 → 添加 `waitpid` + 退出码采集 |
| 4 | `SwiftTermDelegateAdapter.send()` 从空操作改为回调实现 | SwiftTermAdapter.swift | 添加 `onSendData` 闭包 → 修改 `send()` 方法 → 在 init 中连接 |
| 5 | `SwiftTermAdapter.createSnapshot()` 签名变更（增加 scrollback 参数） | SwiftTermAdapter.swift + 所有调用处 | 添加默认参数 `scrollbackOffset: Int = 0` → 现有调用无需修改（默认值兼容） |

**执行顺序建议：** 3 → 4 → 5 → 2 → 1（先做不破坏编译的内部变更，最后做协议迁移）

> **注意：** 变更 5 使用默认参数值，不会破坏现有调用。变更 1 和 2 是真正的破坏性变更，需要同步更新所有引用处。建议在单次 commit 中完成每个变更及其所有影响文件的修改。
