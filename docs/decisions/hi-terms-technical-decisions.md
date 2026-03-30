# Hi-Terms 技术选型决策

**文档类型:** 技术决策
**产品名称:** Hi-Terms
**语言:** 中文
**关联文档:**
- [愿景文档](../reqs/hi-terms-vision.md)
- [需求文档](../reqs/hi-terms-requirements.md)
- [Roadmap 文档](../reqs/hi-terms-roadmap.md)
- [产品定位与需求决策](hi-terms-product-and-requirements-decisions.md)
- [术语表](../SSOT/glossary.md)（术语权威定义）

## 1. 背景

Hi-Terms 是一个面向 macOS 的终端产品，采用[两大阶段](../SSOT/glossary.md#两大阶段two-phase-model)递进发展模型：[第一大阶段](../SSOT/glossary.md#第一大阶段phase-1)聚焦终端能力与用户体验，[第二大阶段](../SSOT/glossary.md#第二大阶段phase-2)构建会话化承载与第三方应用协作能力。

本文档记录在启动 v0.1 实现之前做出的关键技术选型决策。每项决策包含：决策内容、备选方案、选择理由、影响与约束。这些决策共同构成 Hi-Terms 的技术基础，指导后续开发实现。

> 产品定位与需求边界方面的决策参见[产品定位与需求决策](hi-terms-product-and-requirements-decisions.md)。

---

## 2. 决策一：编程语言与框架

### 决策

采用 **Swift + AppKit** 作为 Hi-Terms 的主要技术栈。

### 备选方案

| 方案 | 简述 |
| --- | --- |
| SwiftUI | Apple 新一代声明式 UI 框架 |
| Rust + macOS bindings | Rust 语言配合 macOS 原生 UI 桥接 |
| Electron | 基于 Chromium 的跨平台桌面应用框架 |

### 选择理由

- **AppKit 对终端核心需求的支持最为成熟。** 终端仿真应用需要精确的底层文本渲染（等宽字体、CJK 字符宽度计算、字体连字）、低级键盘事件处理（修饰键组合、功能键映射、IME 输入法）、PTY 管理（`forkpty`、信号传递、进程生命周期）。AppKit 在这些方面有超过 20 年的积累和稳定 API。
- **SwiftUI 在自定义文本渲染和低级键盘事件方面仍有局限。** 终端应用的核心渲染需求（逐字符着色、光标控制、选区绘制）超出了 SwiftUI 标准控件的能力范围。强制使用 SwiftUI 实现这些功能需要大量 `NSViewRepresentable` 桥接，本质上仍然是在写 AppKit 代码，但增加了间接层的复杂度。
- **Rust 生态有优秀的终端库（如 alacritty_terminal），但 macOS 原生 UI 集成需要大量桥接工作。** Rust-Swift FFI 目前缺乏成熟的工具链支持，调试和维护成本高，且团队需要同时精通两种语言。
- **Electron 性能开销大，不适合终端这种对延迟敏感的应用。** 终端用户对按键到渲染的延迟极为敏感（目标 <16ms），Electron 的多进程架构和 DOM 渲染管线在这方面天然处于劣势。
- **Swift 是 macOS 原生开发的一等公民。** Apple 长期投入 Swift 语言和工具链，长期维护性和生态兼容性有保障。

### 影响与约束

- 团队需要具备 Swift / macOS 开发经验
- 可充分复用 macOS 系统能力：通知中心、剪贴板（NSPasteboard）、Accessibility API、Uniform Type Identifiers 等
- 偏好设置界面、非核心 UI 面板等非性能敏感部分，可在后续版本中酌情使用 SwiftUI 实现
- 构建工具链为 Xcode + Swift Package Manager

---

## 3. 决策二：终端仿真引擎策略

### 决策

基于 **SwiftTerm** 进行评估和适配，必要时补充自研。

### 备选方案

| 方案 | 简述 |
| --- | --- |
| 完全自研 | 从零实现终端仿真引擎 |
| 封装 libvterm (C) | 使用 C 语言的 libvterm 库并通过 Swift-C 桥接 |
| 移植 alacritty_terminal (Rust) | 使用 Rust 语言的终端仿真库并通过 FFI 桥接 |

### 选择理由

- **SwiftTerm 是 Swift 原生的终端仿真库，与 Swift / AppKit 技术栈天然兼容。** 该库由 Miguel de Icaza 维护，代码质量和社区活跃度有一定保障。
- **完全自研终端仿真器的成本极高。** VT100 / xterm 规范包含数百个转义序列，加上各种边界情况（字符宽度、滚动区域、交替屏幕缓冲区等），完全自研需要数月专注投入，且难以在短期内达到生产级稳定性。
- **libvterm 是 C 库，需要 Swift-C 桥接。** 虽然 Swift 对 C 互操作支持较好，但维护桥接层、处理内存管理差异、调试跨语言问题仍然增加了复杂度。
- **alacritty_terminal 是 Rust 库，其渲染模型（面向 GPU）与 AppKit 的渲染模型不匹配。** 将其解耦为纯解析层并桥接到 Swift 需要大量适配工作。
- **SwiftTerm 可能在某些高级特性上不够完善，因此需要先评估再决定。** 这是一个务实的策略：尽可能复用成熟实现，在不满足需求的地方针对性补充。

### 评估标准

v0.0 必须完成对 SwiftTerm 的系统评估（详细评估维度、通过标准和流程参见 [V0.0 技术设计文档 §4](../design/hi-terms-v0.0-technical-design.md#4-swiftterm-评估方案)），核心评估方向包括：

- VT100/xterm 转义序列兼容性（vttest 基础测试套件）
- 解析性能（吞吐量基准）
- 高级特性支持（alternate screen buffer、SGR mouse mode、bracketed paste、True Color）
- API 可集成性（能否封装在 TerminalParser protocol 后）
- ScreenBuffer 数据可访问性（能否支撑自定义渲染）

### 影响与约束

- v0.0 需要分配时间完成 SwiftTerm 评估，评估结果直接影响后续开发路线
- 如评估不通过，需预留切换方案的时间（退回到自研或 libvterm 封装）
- 无论使用哪个引擎，终端仿真层的 API 接口应保持抽象，降低引擎切换成本

---

## 4. 决策三：渲染管线方案

### 决策

初期使用 **CoreText + CALayer**，v0.4（AI CLI 性能优化阶段）评估 Metal 加速路径。

### 备选方案

| 方案 | 简述 |
| --- | --- |
| 纯 Metal 从头开始 | 从第一个版本就使用 GPU 加速渲染 |
| Core Graphics | 使用 macOS 2D 图形框架 |
| WebView 渲染 | 使用 WKWebView 进行终端内容渲染 |

### 选择理由

- **CoreText 是 macOS 文本渲染的标准方案。** 对等宽字体布局、CJK 字符宽度计算（半角/全角）、字体连字（ligatures）、字体回退（font fallback）有成熟且经过大量验证的支持。
- **v0.1–v0.3 阶段的渲染需求 CoreText 完全可以满足。** 基础文本渲染、16 色 / 256 色 / True Color 着色、光标绘制、选区高亮——这些需求不需要 GPU 加速。
- **Metal 加速适合 v0.4 的高吞吐量场景，但初期投入过高。** [AI CLI](../SSOT/glossary.md#ai-cli) 输出大量代码（>500 行流式输出）时需要保持 30fps 以上的渲染帧率，这是 Metal 加速的合理引入时机。在 v0.1 就引入 Metal 会显著增加开发复杂度，但收益有限。
- **Core Graphics 虽然也能完成文本渲染，但在文本排版方面不如 CoreText 专业。** CoreText 是 Apple 推荐的文本渲染底层框架，Core Graphics 更适合图形绘制。
- **WebView 渲染引入了不必要的间接层和性能开销**，与 Electron 方案的劣势类似。

### 影响与约束

- **渲染架构从一开始必须隔离渲染后端。** v0.1 的渲染模块应通过协议（protocol）抽象渲染接口，使 v0.4 可以平滑切换到 Metal 后端而不影响上层逻辑。
- **渲染管线从一开始必须采用增量/脏区更新设计。** 只重绘变化的行和字符，不全屏刷新。这是 Metal 优化的前提，也是 CoreText 阶段的性能保障。
- 性能瓶颈监测应从 v0.2 开始，建立渲染帧率和内存使用的基准数据，为 v0.4 的 Metal 评估提供量化依据。

---

## 5. 决策四：分发渠道

### 决策

初期通过 **GitHub Releases 直接分发**（DMG + macOS 公证签名），后续评估 App Store 渠道。

### 备选方案

| 方案 | 简述 |
| --- | --- |
| 仅 App Store | 仅通过 Mac App Store 分发 |
| Homebrew Cask | 通过 Homebrew 包管理器分发 |
| 自建更新服务 | 搭建独立的更新分发服务器 |

### 选择理由

- **App Store 沙盒对终端应用核心功能有严格限制。** PTY 创建（`forkpty`）、Shell 进程启动、文件系统广泛访问、环境变量继承——这些是终端应用的基本需求，但 App Store 沙盒会限制或禁止其中多项。iTerm2 同样不在 App Store 上架，正是因为沙盒限制。
- **直接分发可使用完整的 macOS entitlements，不受沙盒限制。** 终端应用需要 `com.apple.security.cs.allow-unsigned-executable-memory` 等权限，这些在沙盒环境中不可用。
- **macOS 公证（Notarization）可确保安全性。** Apple 的公证流程会对应用进行恶意软件扫描，公证通过后用户打开应用时不会看到"无法验证开发者"的警告，安全性与 App Store 分发基本等效。
- **后续如确认沙盒兼容性可行，可补充 App Store 渠道。** 这不是一个不可逆的决策。
- **Homebrew Cask 可作为补充渠道，降低开发者用户的安装门槛。** 但不作为主分发渠道。

### 影响与约束

- 需要 Apple Developer 账号（年费 $99）进行代码签名和公证
- 需要在 CI 中集成公证流程（`notarytool`）
- 需要自行实现或集成更新检查机制——推荐使用 [Sparkle](https://sparkle-project.org/) 框架，macOS 开源应用中广泛使用的自动更新方案
- DMG 打包流程需要在 v0.0 阶段建立（作为构建链路验证的一部分）

---

## 6. 决策五：测试策略

### 决策

采用**三层测试体系**：单元测试 + 终端一致性测试 + 性能基准测试，辅以 AI CLI 集成验证。

### 选择理由与细节

#### 6.1 单元测试

- **框架:** XCTest（Xcode 内建测试框架）
- **覆盖范围:** 终端仿真解析（转义序列处理、字符宽度计算）、PTY 管理（进程生命周期、信号传递）、配置持久化（设置读写、主题加载）等核心模块
- **要求:** v0.1 起所有核心模块必须有单元测试覆盖

#### 6.2 终端一致性测试

- **工具:** 使用 [vttest](https://invisible-island.net/vttest/) 或类似工具验证 VT100 / xterm 转义序列兼容性
- **方式:** 自动化执行 vttest 测试套件，将实际输出与期望输出进行对比
- **目的:** 确保终端仿真引擎的行为与标准终端一致，防止转义序列处理的回退
- **要求:** 作为 CI 的一部分，每次提交自动运行

#### 6.3 性能基准测试

- **测量指标:** 渲染帧率（fps）、内存使用（RSS）、PTY I/O 吞吐量（bytes/s）、按键到渲染延迟（ms）
- **方式:** 使用标准化测试脚本（如大量 `cat` 输出、快速滚动）生成负载，自动采集性能数据
- **目的:** 防止性能回退，为 v0.4 的 Metal 评估提供基准线
- **要求:** 从 v0.2 起作为 CI 的一部分，性能数据需要持久化以支持趋势分析

#### 6.4 集成测试（AI CLI 行为模式）

- **方式:** 使用行为模式脚本模拟 [AI CLI](../SSOT/glossary.md#ai-cli) 的典型交互模式——流式输出（逐字符/逐行）、多轮 I/O（提问-回答-再提问）、信号中断（Ctrl+C 中断生成）
- **关键原则:** 脚本模拟通用行为模式，**不绑定特定 AI CLI 版本**。Claude Code、Codex CLI 等实际工具的测试作为补充验证，不作为 CI 门控标准。
- **目的:** 确保 Hi-Terms 能稳定承载 AI CLI 的交互模式，而不依赖外部工具的版本稳定性

### 影响与约束

- v0.1 必须搭建基础测试基础设施：CI 流水线 + XCTest 框架 + vttest 集成
- 测试覆盖率目标应在 v0.1 结束时确定，但核心模块（终端仿真、PTY 管理）必须有测试
- 性能基准测试的阈值需要在 v0.2 积累数据后确定

---

## 7. 决策六：最低 macOS 版本

### 决策

**macOS 14 (Sonoma)** 作为最低支持版本。

### 备选方案

| 方案 | 简述 |
| --- | --- |
| macOS 13 (Ventura) | 支持更早一代的 macOS |
| macOS 15 (Sequoia) | 只支持最新的 macOS |

### 选择理由

- **macOS 14 提供了稳定的 Swift 并发支持。** Swift Concurrency（async/await、Actor）在 macOS 14 上已经完全稳定，是实现异步 PTY I/O、会话生命周期管理的基础。
- **macOS 14 提供了最新的 AppKit API 改进。** 包括改进的文本输入处理、更好的 HDR 颜色支持等。
- **macOS 14+ 可覆盖大部分活跃 Mac 用户。** macOS 14 (Sonoma) 已发布超过 2 年（2023 年 9 月发布），绝大部分活跃 Mac 用户已经升级。
- **支持 macOS 13 (Ventura) 会增加兼容性维护成本。** 需要处理 Swift 并发在旧版系统上的行为差异和 API 可用性差异。
- **只支持 macOS 15 (Sequoia) 会不必要地缩小用户基数。** 部分用户因硬件或习惯原因未升级到最新版本。

### 影响与约束

- CI 环境需要 macOS 14+ 的构建和测试机器
- 如需使用 macOS 15 专有 API（例如新的窗口管理 API），必须通过 `#available` 进行可用性检查，提供 macOS 14 的降级路径
- Deployment Target 设置为 macOS 14.0

---

## 8. 决策总结

| 决策领域 | 选型 | 关键理由 |
| --- | --- | --- |
| 编程语言与框架 | Swift + AppKit | 对终端核心需求（文本渲染、键盘事件、PTY 管理）支持最成熟 |
| 终端仿真引擎 | SwiftTerm（评估优先） | Swift 原生兼容，务实复用，评估不通过时预留切换路径 |
| 渲染管线 | CoreText + CALayer → Metal（v0.4 评估） | 分阶段投入，初期满足需求，后期按需升级 |
| 分发渠道 | GitHub Releases (DMG + 公证) | 避免 App Store 沙盒限制，保留终端应用所需的完整系统权限 |
| 测试策略 | 三层体系（单元 + 一致性 + 性能） | 确保终端兼容性和性能不回退，AI CLI 测试不绑定特定版本 |
| 最低 macOS 版本 | macOS 14 (Sonoma) | 平衡 API 可用性与用户覆盖率 |

> 这些技术决策共同服务于 Hi-Terms 的[两大阶段](../SSOT/glossary.md#两大阶段two-phase-model)目标：为第一大阶段的终端能力迭代提供坚实的技术基础，同时为第二大阶段的会话化承载预留架构扩展空间。
