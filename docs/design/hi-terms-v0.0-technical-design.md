# Hi-Terms V0.0 技术设计文档 — 工程基线与技术验证

**文档类型:** 技术设计
**产品名称:** Hi-Terms
**版本:** v0.0
**语言:** 中文
**关联文档:**
- [Roadmap](../reqs/hi-terms-roadmap.md)（版本定义）
- [技术选型决策](../decisions/hi-terms-technical-decisions.md)（技术选型依据）
- [需求文档](../reqs/hi-terms-requirements.md)（四层架构定义）
- [迭代计划评审](../reviews/iteration-plan-review-2026-03-30.md)（评审建议来源）
- [术语表](../SSOT/glossary.md)（术语权威定义）

---

## 1. 版本目标

V0.0 是工程基线版本，**不交付用户可见功能**，目标是：

1. 搭建可运行的 macOS 应用骨架与构建链路
2. 确定 Swift Package 模块结构与依赖方向
3. 完成 SwiftTerm 系统评估，确定终端仿真引擎路线
4. 建立测试骨架（XCTest + vttest 集成方案）
5. 建立日志与性能采样基础
6. 跑通从代码到可签名 DMG 的完整构建链路

**V0.0 不包含：**
- 任何终端功能交付（PTY、渲染、输入、滚动等归 V0.1）
- CI/CD 流水线搭建（V0.1 期间完成）
- 配置系统完整实现（V0.0 仅建立骨架）

---

## 2. Swift Package 模块结构

### 2.1 模块全景

```
HiTerms/
├── HiTermsApp/                  # 主应用 Target（AppKit 入口）
├── Packages/
│   ├── TerminalCore/            # 终端仿真核心（parser、screen buffer、属性模型）
│   ├── PTYKit/                  # PTY 管理（forkpty、I/O、进程生命周期）
│   ├── TerminalRenderer/        # 渲染抽象层 + CoreText 实现
│   ├── TerminalUI/              # AppKit 视图层（终端视图、窗口管理）
│   └── Configuration/           # 配置存储骨架
├── Tests/
│   ├── TerminalCoreTests/
│   ├── PTYKitTests/
│   ├── TerminalRendererTests/
│   └── IntegrationTests/        # vttest 集成、端到端测试
└── Tools/
    ├── vttest-runner/           # vttest 自动化运行脚本
    └── perf-baseline/           # 性能采样脚本
```

### 2.2 模块职责与依赖

```
                    ┌──────────────┐
                    │  HiTermsApp  │  (主应用入口，组装各模块)
                    └──────┬───────┘
                           │ depends on
              ┌────────────┼────────────┐
              ▼            ▼            ▼
      ┌──────────┐  ┌────────────┐  ┌──────────────┐
      │TerminalUI│  │Configuration│  │ TerminalCore │
      └────┬─────┘  └────────────┘  └──────────────┘
           │ depends on                     ▲
     ┌─────┼──────────┐                     │
     ▼     ▼          ▼                     │
┌────────┐┌──────────────────┐              │
│ PTYKit ││TerminalRenderer  │──────────────┘
└────────┘└──────────────────┘
```

**依赖规则（严格单向）：**

| 模块 | 依赖 | 不可依赖 |
|------|------|----------|
| TerminalCore | 无外部依赖（可能依赖 SwiftTerm） | 不依赖 AppKit、PTYKit、UI |
| PTYKit | 系统框架（Darwin/POSIX） | 不依赖 AppKit、TerminalCore |
| TerminalRenderer | TerminalCore、AppKit/QuartzCore（CoreText 渲染需要） | 不依赖 PTYKit |
| TerminalUI | TerminalCore、TerminalRenderer、PTYKit | — |
| Configuration | 无（Foundation only） | 不依赖其他业务模块 |
| HiTermsApp | 全部模块 | — |

### 2.3 模块详细说明

#### TerminalCore

终端仿真的核心逻辑，**不涉及渲染和 I/O**。

**关键类型：**

| 类型 | 职责 | V0.0 交付 |
|------|------|-----------|
| `TerminalParser` (protocol) | 解析 VT100/xterm 转义序列，输出操作指令 | protocol + SwiftTerm 封装或 stub |
| `ScreenBuffer` | 终端字符网格（cells + attributes），维护 dirty region 标记，提供 `snapshot()` 用于 COW 渲染 | 类型定义 + 基本读写 spike |
| `Cell` | 单个字符单元：character + foreground + background + attributes | 类型定义 |
| `TextAttributes` | 文本属性集（粗体、斜体、下划线、反色、颜色） | 类型定义 |
| `ScrollbackBuffer` | 滚回历史缓冲区 | V0.1 实现 |
| `CursorState` | 光标位置、样式、可见性 | 类型定义 |
| `TerminalState` | 终端状态聚合（screen buffer + cursor + 模式标志） | 类型定义 |

**如果采用 SwiftTerm：** `TerminalParser` 的默认实现封装 SwiftTerm 的 `Terminal` 类，通过 protocol 抽象隔离具体实现。

**如果不采用 SwiftTerm：** 需自研 parser，工作量显著增加（参见 §4 评估方案）。

#### PTYKit

PTY 生命周期管理，**不涉及终端仿真逻辑**。

**关键类型：**

| 类型 | 职责 | V0.0 交付 |
|------|------|-----------|
| `PTYProcess` | 单个 PTY 实例：fd 管理、读写、进程 PID | spike 实现（echo hello） |
| `PTYManager` | 管理多个 PTY 实例，支持并发创建/销毁 | V0.1 实现 |
| `PTYConfiguration` | PTY 创建参数：shell 路径、环境变量、初始窗口大小 | 类型定义 |

**关键操作：**
- `create(config:) -> PTYProcess` — forkpty + execve
- `read(from:) -> AsyncStream<Data>` — 非阻塞读取 PTY 输出
- `write(to:data:)` — 写入用户输入到 PTY
- `resize(process:cols:rows:)` — SIGWINCH
- `terminate(process:)` — 优雅关闭

#### TerminalRenderer

渲染抽象 + CoreText 具体实现。依赖 AppKit/QuartzCore（CoreText 渲染需要 NSFont、CALayer 等系统类型）。

**关键类型：**

| 类型 | 职责 | V0.0 交付 |
|------|------|-----------|
| `TerminalRendering` (protocol) | 渲染接口抽象（为 Metal 替换预留） | protocol 定义 |
| `CoreTextRenderer` | CoreText + CALayer 实现 | V0.1 实现 |
| `FontMetrics` | 字体度量：cell 宽高、baseline 偏移、字体回退链 | 类型定义 |
| `DirtyRegion` | 脏区跟踪：需要重绘的行/列范围，`os_unfair_lock` 保护并发访问 | 类型定义 |

**渲染协议核心方法：**
```swift
protocol TerminalRendering {
    func render(
        buffer: ScreenBuffer,
        dirtyRegion: DirtyRegion,
        cursor: CursorState,
        into layer: CALayer
    )
    func measure(font: NSFont) -> FontMetrics
}
```

#### TerminalUI

AppKit 视图层 + 终端会话编排。本模块既包含视图组件，也包含将 PTY、Parser、ScreenBuffer、Renderer 串联为完整数据管线的核心协调器。

**关键类型：**

| 类型 | 职责 | V0.0 交付 |
|------|------|-----------|
| `TerminalSession` | **核心协调器**：持有 PTYProcess + TerminalParser + ScreenBuffer + RenderCoordinator，驱动 PTY 输出 → Parser → ScreenBuffer 数据管线，转发 InputHandler → PTY 输入 | protocol + stub |
| `TerminalView` (NSView) | 单个终端视图，处理键盘/鼠标输入，持有渲染层，以 TerminalSession 为数据源 | V0.1 实现 |
| `TerminalWindowController` | 窗口管理（V0.0 仅单窗口） | V0.1 实现 |
| `InputHandler` | NSEvent → 终端按键序列转换 | V0.1 实现 |

#### Configuration

配置存储骨架，V0.0 仅建立接口，不实现完整 Profile。

**关键类型：**

| 类型 | 职责 |
|------|------|
| `AppConfig` (protocol) | 配置读取接口 |
| `DefaultConfig` | 默认值提供者（字体、字号、颜色等） |
| `UserDefaultsConfig` | 基于 UserDefaults 的持久化实现 |

---

## 3. 核心数据流设计

> **范围说明：** 本节描述目标架构设计，V0.0 仅定义相关 protocol 和类型骨架，完整实现归 V0.1+。

### 3.1 输出管线（PTY → 屏幕）

```
PTY fd (read)
    │
    ▼ [Background Thread / DispatchIO]
Raw bytes (Data)
    │
    ▼ [Background Thread]
TerminalParser.parse(data:)
    │
    ▼
Parser Actions (cursor move, write char, set attribute, scroll, ...)
    │
    ▼ [Parser applies to ScreenBuffer, marks dirty regions]
ScreenBuffer (updated cells + DirtyRegion)
    │
    ▼ [Main Thread - CATransaction]
CoreTextRenderer.render(buffer:dirtyRegion:cursor:into:)
    │
    ▼
CALayer tree (updated sublayers for dirty cells only)
    │
    ▼
Display
```

**关键设计约束：**

- **PTY 读取不在主线程**：使用 DispatchIO 或专用后台线程读取 PTY fd
- **Parser 在后台线程执行**：与 PTY 读取在同一后台线程，避免跨线程数据拷贝
- **ScreenBuffer 更新和 dirty region 标记在后台线程**：parser 直接操作 buffer
- **渲染切回主线程**：通过 `DispatchQueue.main.async` 或 `MainActor` 将 dirty region 快照提交给 renderer
- **只重绘脏区**：renderer 仅更新 DirtyRegion 标记的行/列，不全屏重绘

### 3.2 输入管线（键盘/鼠标 → PTY）

```
NSEvent (keyDown / mouseDown / mouseMoved)
    │
    ▼ [Main Thread]
InputHandler.handle(event:) -> Data?
    │  ├─ 普通字符 → UTF-8 编码
    │  ├─ 方向键 → ESC 序列 (e.g., \e[A)
    │  ├─ Ctrl+C → byte 0x03
    │  ├─ 鼠标事件 → SGR 鼠标报告序列
    │  └─ Cmd 系快捷键 → 不传递给 PTY，由应用处理
    │
    ▼
PTYProcess.write(data:)
    │
    ▼
PTY fd (write) → shell 接收
```

### 3.3 背压处理

背压存在于两个层面：

**层面一：PTY I/O 线程 vs. 渲染线程**

当 PTY 输出速率超过渲染速率时：

1. PTY 读取和 Parser 在同一后台线程持续执行，不受渲染速率影响
2. Parser 持续更新 ScreenBuffer，dirty region 不断累积
3. 渲染按帧率节流（最高 60fps）：如果上一帧尚未渲染完成，合并多次 buffer 更新的 dirty region
4. 效果：用户看到的是"跳过中间帧"而非卡顿，类似视频快进

**层面二：Parser 处理速率 vs. 子进程输出速率**

Parser 和 PTY 读取同步运行在同一线程。如果 Parser 处理复杂转义序列导致变慢，PTY 读取也随之变慢，内核 PTY 缓冲区（通常 4-16KB）逐渐填满，最终子进程的写操作阻塞。这是操作系统提供的天然背压机制，终端仿真器通常依赖此机制限速，无需额外缓冲队列。

---

## 4. SwiftTerm 评估方案

### 4.1 评估目标

确定 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 是否满足 Hi-Terms 终端仿真引擎需求，产出明确的"采用/不采用"决策。

### 4.2 评估维度与通过标准

| 维度 | 评估方法 | 通过标准 | 不通过则 |
|------|----------|----------|----------|
| **VT100/xterm 兼容性** | 运行 vttest 基础测试套件 | 基础项通过率 ≥ 70%（V0.0 spike 标准，V0.1 验收为 ≥ 80%） | 需评估缺失项是否可补齐 |
| **解析性能** | 喂入 10MB 混合终端数据（约 80% 可打印 ASCII + 15% ANSI 颜色/属性序列 + 5% 光标移动序列，或录制的真实终端会话），测量解析耗时 | 解析速率 ≥ 50MB/s | 性能瓶颈是否可绕过 |
| **高级特性** | 逐项验证 | 必须支持：alternate screen buffer、SGR mouse mode。应支持：bracketed paste、True Color | 缺失项是否可扩展补充 |
| **API 可集成性** | 尝试将 SwiftTerm 的 Terminal 类封装在 TerminalParser protocol 后 | 可在不修改 SwiftTerm 源码的前提下完成封装 | 是否需要 fork 并修改 |
| **ScreenBuffer 可访问性** | 检查是否可读取 cell 级别的字符、属性、颜色数据 | 可逐 cell 读取完整数据，用于自定义渲染 | 是否可通过扩展解决 |

### 4.3 评估流程

```
Step 1: 集成 SwiftTerm 到最小应用（约 1 天）
        ├─ 添加 SwiftTerm 为 SPM 依赖
        ├─ 创建最小 PTY + SwiftTerm Terminal 实例
        └─ 验证基础数据流是否跑通
        ⚑ 门控：基础数据流跑通方可进入 Step 2-4；否则直接评估退路方案
             │
Step 2: VT100 兼容性测试（约 1-2 天）
        ├─ 运行 vttest，记录通过/失败项
        └─ 分析失败项的严重性和可修复性
             │
Step 3: 性能基准测试（约 0.5 天）
        ├─ 构造 10MB 混合终端输出数据
        ├─ 测量 SwiftTerm 解析耗时
        └─ 对比直接字节处理的基准
             │  （Step 2 和 Step 3 可并行）
Step 4: API 集成评估（约 1-2 天）
        ├─ 实现 TerminalParser protocol 封装
        ├─ 验证 ScreenBuffer 数据可读取性
        └─ 评估自定义渲染的可行性
        ⚑ 门控：Step 2-4 全部完成方可进入 Step 5
             │
Step 5: 输出决策文档（约 0.5 天）
        ├─ 各维度评估结果
        ├─ 采用/不采用决策
        └─ 如不采用，退路方案和工期影响
```

### 4.4 退路方案

如果 SwiftTerm 评估不通过：

| 退路 | 工期影响 | 适用场景 |
|------|----------|----------|
| **Fork SwiftTerm 并修改** | +1-2 周 | SwiftTerm 基本满足但个别 API 需调整 |
| **封装 libvterm (C)** | +2-3 周 | SwiftTerm 兼容性不足，但 libvterm 稳定 |
| **自研 parser** | +6-8 周 | 以上方案均不可行（极端情况） |

### 4.5 评估交付物

- `docs/decisions/hi-terms-swiftterm-evaluation.md` — 评估结果与决策记录
- `Tests/IntegrationTests/SwiftTermSpikeTests.swift` — 评估过程中的测试代码

---

## 5. 线程与并发模型

> **范围说明：** 本节描述目标架构设计，V0.0 仅定义相关 protocol 和类型骨架，完整实现归 V0.1+。

### 5.1 线程分配

| 线程 | 职责 | 并发机制 |
|------|------|----------|
| **Main Thread** | UI 事件处理、CALayer 渲染更新、键盘/鼠标事件接收 | MainActor |
| **PTY I/O Thread** | 每个 PTY 实例一个，负责 fd 读取 + parser 执行 + ScreenBuffer 更新 | DispatchIO / 专用 DispatchQueue |
| **Renderer Coalesce** | 帧率节流，合并 dirty region，提交渲染 | CADisplayLink callback (Main RunLoop) |

> **关于 CADisplayLink vs CVDisplayLink：** macOS 14+ 提供 `CADisplayLink`，可绑定到 main RunLoop，回调天然在主线程执行。相比 `CVDisplayLink`（回调在私有高优先级线程，需手动 dispatch 到主线程），`CADisplayLink` 更安全且与本文描述的线程模型一致。Hi-Terms 最低支持 macOS 14，因此采用 `CADisplayLink`。

> **线程扩展性说明：** 每个 PTY 一个专用 I/O 线程在 V0.0-V0.1（单终端）和 V0.2（5-20 个 Tab）场景下是合理的。V0.2+ 如果 Tab 数量显著增长，可评估切换到 `DispatchSource` + 共享并发队列的方案以减少线程数。

### 5.2 数据保护

| 共享数据 | 保护方式 | 说明 |
|----------|----------|------|
| ScreenBuffer | copy-on-write 快照 | 后台线程写入 live buffer，主线程通过 `snapshot()` 获取只读副本进行渲染，两者互不阻塞 |
| CursorState | 包含在 ScreenBuffer 快照中 | 始终与 buffer 一致 |
| DirtyRegion | `os_unfair_lock` 保护 merge 和 swap | 后台线程 `merge()` 标记脏行，主线程 `swapAndClear()` 获取并清空 |
| PTY fd | PTYProcess 内部封装，单线程访问 | 每个 PTY 的读写在其专用队列 |

> **为什么不用 pthread_rwlock：** 如果渲染持读锁时间较长（一次 CoreText 全屏渲染可达 5-10ms），Parser 线程获取写锁会阻塞，连带 PTY 读取也阻塞，导致可感知的微卡顿。COW 快照让 Parser 和渲染互不阻塞，是终端仿真器的常见选择。

### 5.3 渲染节流

```swift
// 概念示意，非最终代码
class RenderCoordinator {
    private var displayLink: CADisplayLink  // macOS 14+，绑定到 main RunLoop
    private var pendingDirtyRegion: DirtyRegion  // 累积的脏区（os_unfair_lock 保护）

    // PTY I/O 线程调用：标记新的脏区
    func markDirty(_ region: DirtyRegion) {
        lock.lock()
        pendingDirtyRegion.merge(region)
        lock.unlock()
    }

    // CADisplayLink 回调（主线程）：执行渲染
    func onDisplayLink() {
        lock.lock()
        let region = pendingDirtyRegion
        pendingDirtyRegion = DirtyRegion.empty
        lock.unlock()
        if !region.isEmpty {
            renderer.render(buffer: buffer.snapshot(), dirtyRegion: region, ...)
        }
    }
}
```

### 5.4 并发模型选择说明

本设计以 GCD（DispatchQueue、DispatchIO）为主要并发机制。PTYKit 的 `read(from:) -> AsyncStream<Data>` API 使用 Swift Structured Concurrency 桥接 GCD 数据源，消费端在 async 上下文中使用。V0.0 不要求统一为纯 Swift Concurrency 或纯 GCD，但需确保 GCD ↔ async/await 桥接点明确且线程安全。

---

## 6. 测试基础设施

> **依赖说明：** 终端一致性测试和性能基准测试均依赖可运行的 TerminalParser 实现。V0.0 中这一实现预计来自 SwiftTerm spike（§4）。如果 SwiftTerm 评估产出否定结论，这两项交付物降级为"测试框架就绪，待替代 parser 实现后可运行"，不阻塞 V0.0 验收。

### 6.1 测试层级

| 层级 | 框架 | 覆盖范围 | V0.0 交付 |
|------|------|----------|-----------|
| 单元测试 | XCTest | TerminalCore（parser、buffer）、PTYKit（进程管理）、Configuration | 各模块 ≥ 1 个测试文件，验证核心类型可实例化和基本操作 |
| 终端一致性 | vttest + 自定义脚本 | VT100/xterm 转义序列兼容性 | vttest 运行方案确定，≥ 1 组基础测试可自动执行 |
| 性能基准 | XCTest + 自定义计时 | 解析吞吐量、渲染帧率 | ≥ 1 组解析性能基准可采集 |

### 6.2 vttest 自动化方案

vttest 是交互式 ncurses 程序，不能直接作为 CI 测试。V0.0 需要验证以下方案之一：

**方案 A：PTY 回放驱动**
1. 在真实终端中手动运行 vttest，录制 PTY I/O 序列
2. 将录制的输出序列回放给 Hi-Terms 的 parser
3. 对比 parser 产出的 ScreenBuffer 与预期快照

**方案 B：脚本驱动 vttest**
1. 通过 expect 脚本自动驱动 vttest 的菜单选择
2. 捕获 vttest 输出并解析测试结果
3. 将结果汇总为通过率报告

V0.0 的出口标准是**确定可行方案并至少有 1 组测试可运行**，不要求全部 vttest 项目自动化。

### 6.3 性能基准采集

**基准测试内容：**

| 指标 | 方法 | 单位 |
|------|------|------|
| 解析吞吐量 | 喂入 N MB 原始终端数据，计算 bytes/s | MB/s |
| 单帧渲染耗时 | 全屏脏区渲染一次的耗时 | ms |
| 内存基线 | 空终端启动后的 RSS | MB |

V0.0 仅建立采集能力和首次基准值，不设定通过阈值。阈值在 V0.1 完成后根据实际数据确定。

---

## 7. 日志与 Crash 基础

### 7.1 日志框架

使用 Apple 的 **os.log (OSLog)** 框架：

| 子系统 | 类别 | 用途 |
|--------|------|------|
| `com.hiterms.pty` | `lifecycle`, `io` | PTY 创建/销毁、I/O 错误 |
| `com.hiterms.terminal` | `parser`, `buffer` | 解析异常、buffer 操作 |
| `com.hiterms.renderer` | `frame`, `perf` | 渲染帧率、脏区大小 |
| `com.hiterms.app` | `general` | 应用生命周期 |

**日志级别使用约定：**
- `fault`：不可恢复的错误（crash 前最后一条）
- `error`：可恢复的错误（PTY 读取失败、解析异常字符序列）
- `info`：关键事件（PTY 创建/销毁、窗口 resize）
- `debug`：调试信息（仅 DEBUG 构建有效）

### 7.2 Crash 收集

V0.0 阶段使用 macOS 内建的 crash reporter（`~/Library/Logs/DiagnosticReports/`）。不引入第三方 crash 上报 SDK。

V0.2+ 评估是否需要集成 Sentry 或类似服务。

---

## 8. 构建与分发链路

### 8.1 构建链路

```
源码 (Swift + SPM)
    │
    ▼
Xcode Build (Debug / Release)
    │
    ▼
HiTerms.app (macOS Application Bundle)
    │
    ▼ [Release only]
Code Signing (Apple Developer Certificate)
    │
    ▼
Notarization (notarytool)
    │
    ▼
DMG 打包 (create-dmg 或 hdiutil)
    │
    ▼
GitHub Release
```

### 8.2 V0.0 构建出口

- Debug 构建可运行（显示空白窗口即可）
- Release 构建可签名（需要 Apple Developer 证书）
- DMG 打包脚本可运行

---

## 9. V0.0 交付物与验收标准

### 9.1 交付物清单

| # | 交付物 | 说明 |
|---|--------|------|
| 1 | Xcode 项目 + SPM 模块结构 | 5 个 Package + 主应用 Target |
| 2 | 可启动的空白 macOS 应用 | 显示空白窗口，证明构建链路通 |
| 3 | SwiftTerm 评估报告 | 评估文档 + spike 测试代码 |
| 4 | 终端仿真引擎路线决策 | 基于评估结果的正式决策记录 |
| 5 | 各模块核心 protocol/type 定义 | 接口骨架（含 TerminalSession 协调器），非完整实现 |
| 6 | XCTest 测试骨架 | 每个模块 ≥ 1 个测试文件 |
| 7 | vttest 自动化方案 + ≥ 1 组可运行测试 | 证明 vttest 集成方案可行 |
| 8 | 性能基准首次采集结果 | 解析吞吐量、内存基线 |
| 9 | OSLog 日志基础 | 各模块日志子系统已配置 |
| 10 | DMG 打包脚本 | 可生成可签名的 DMG |

### 9.2 验收标准

每条标准均可客观验证：

- [ ] `xcodebuild build` 成功，无 warning（允许第三方依赖 warning）
- [ ] 运行应用，显示空白 NSWindow，无 crash
- [ ] `xcodebuild test` 通过，所有测试 target 至少有 1 个 passing test
- [ ] SwiftTerm 评估文档存在，包含各维度评估结果和明确的采用/不采用决策
- [ ] TerminalParser protocol 已定义，有至少一个实现（SwiftTerm 封装或 stub）
- [ ] ScreenBuffer 类型已定义，可创建实例并读写 cell 数据（有测试验证）
- [ ] PTYProcess 可创建 PTY 实例并启动 `/bin/echo hello`，读取输出（有测试验证）
- [ ] vttest 至少 1 组基础测试可通过自动化脚本运行并产出结果
- [ ] 存在 ≥ 1 组性能基准测试，可执行并输出数值
- [ ] OSLog 日志在 Console.app 中可按子系统过滤查看
- [ ] `hdiutil` 或打包脚本可生成 DMG 文件

---

## 10. V0.0 与 V0.1 的边界

| V0.0 做什么 | V0.1 做什么 |
|------------|------------|
| 建立模块骨架和 protocol 定义 | 填充完整实现 |
| SwiftTerm 评估和集成决策 | 基于决策实现完整 parser |
| PTY 最小 spike（echo hello） | 完整 PTY + shell 交互 |
| 渲染 protocol 定义 | CoreText 完整渲染实现 |
| TerminalSession protocol + stub | 完整的数据管线编排实现 |
| 空白窗口 | 可交互的终端窗口 |
| 测试骨架 | 覆盖核心功能的完整测试 |
| 性能采样能力 | 性能基准值和阈值 |
| 日志基础 | 关键路径日志完善 |

**关于 V0.0 实现物的性质：** V0.0 的验收标准要求部分类型具备最小可运行实现（如 ScreenBuffer 可读写 cell、PTYProcess 可启动 echo hello）。这些实现是**验证性 spike**——目的是验证接口设计的可行性，而非提供生产级实现。V0.1 可能基于 V0.0 spike 演进，也可能根据 SwiftTerm 评估结果大幅重写。Protocol 定义力求稳定，具体实现不保证延续。

V0.0 的产出是 V0.1 的**起跑线**。V0.1 开发者拿到 V0.0 后，应能立即在已有模块结构中填充功能代码，而不需要先花时间搭基础设施。
