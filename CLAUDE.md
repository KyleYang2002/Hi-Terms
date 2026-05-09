# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Hi-Terms is a macOS terminal application with two sequential product phases:
1. **Phase 1 — Terminal UX** — iterating toward parity with (and eventually surpassing) macOS Terminal / iTerm in capability and UX; architecture anticipates Phase 2
2. **Phase 2 — CLI session host** — building on the mature terminal product, treating command-line tool sessions (especially AI CLIs like Claude Code, Codex CLI) as first-class objects that external apps can observe, control, and collaborate around

The primary documentation language is Chinese (中文).

## Key Documents

- `docs/reqs/hi-terms-vision.md` — product vision and phase definitions (authoritative source for two-phase model)
- `docs/reqs/hi-terms-requirements.md` — capabilities, scenarios, boundaries, architecture, and detailed requirements
- `docs/reqs/hi-terms-roadmap.md` — phase milestones (v0.0–v0.7 + Phase 2), challenges, and exit criteria
- `docs/decisions/hi-terms-product-and-requirements-decisions.md` — product positioning decisions
- `docs/decisions/hi-terms-technical-decisions.md` — technical decisions (Swift+AppKit, SwiftTerm, CoreText, distribution, testing, macOS 14)
- `docs/reqs/hi-terms-v0.0-acceptance.md` — v0.0 acceptance criteria (SSOT for v0.0 verification)
- `docs/design/hi-terms-v0.0-technical-design.md` — v0.0 engineering baseline: module structure, data flow, SwiftTerm evaluation plan, threading model
- `docs/reqs/hi-terms-v0.1-acceptance.md` — v0.1 acceptance criteria (SSOT for v0.1 verification, 12 items B01-B12)
- `docs/design/hi-terms-v0.1-technical-design.md` — v0.1 terminal kernel: session foundation, rendering pipeline, input handling, threading model
- `docs/plans/archived/hi-terms-v0.1-implementation-plan.md` — v0.1 implementation plan (6 phases A-F, task breakdown; archived, task definitions referenced by Next2Do)
- `Next2Do/` — execution plan SSOT (replaces docs/plans/ for active planning):
  - `Next2Do/v0.1-execution.md` — v0.1 Phase C-F execution tracking, task status, deviation log
  - `Next2Do/v0.2-blueprint.md` — v0.2 preliminary technical planning
  - `Next2Do/risks-and-decisions.md` — cross-version risk register and runtime decision log

## Architecture (Four-Layer Design)

1. **Terminal Runtime** *(Phase 1 core)* — PTY, shell/subprocess execution, rendering, tab/window management
2. **Session Host** *(Phase 1 foundation, Phase 2 full)* — session lifecycle (start, persist, interrupt, resume, stop), context tracking, long-lived sessions. Phase 1 builds basic process management and state; Phase 2 adds full session lifecycle management
3. **Interaction Layer** *(Phase 2 core)* — APIs for external apps (`start_session`, `attach_session`, `send_input`, `read_output`, `get_session_state`, `interrupt_session`); high-level session interface as primary path, raw terminal injection as fallback
4. **Tool Bridge** *(Phase 2 core)* — third-party app integration: launch/connect sessions, send tasks, receive output/state/events, manage concurrent access

## Critical Product Boundaries

- Hi-Terms does NOT do prompt optimization, rewriting, or task-intent enhancement — natural language capability belongs to the AI CLIs themselves
- Phase 1 focuses on terminal capability and UX, iterating toward and beyond macOS Terminal / iTerm parity; architecture must anticipate Phase 2 session capabilities
- Phase 2: external apps interact with **session objects** (with identity, state, lifecycle), not anonymous terminal buffers
- Phase 2 primary scenario: third-party macOS apps driving AI CLI sessions (e.g., a Telegram bot triggering Claude Code via Hi-Terms)

## Phase 1 Versions

- **v0.0** — Engineering baseline & tech validation (app skeleton, module structure, SwiftTerm evaluation, test scaffolding). No user-facing features.
- **v0.1** — Terminal kernel (PTY, shell, parser, rendering, input, scrolling, mouse events)
- **v0.2–v0.7** — Progressive terminal capability (tabs, split panes, AI CLI stability, themes, shell integration, Session Host foundation)

## Current State

V0.0 + V0.1 complete. V0.1 Phase A-F all done (commits `558d074` through `276f106`); B01-B12 all pass; CJK rendering + paste/IME shipped in commit `3171aab`. v0.2 in progress: test suite has grown to **~250 tests across SPM packages, 0 failures**. The repo has:

- Xcode project (via XcodeGen `project.yml`) with HiTerms app target and 6 test targets
- 5 SPM packages: TerminalCore, PTYKit, TerminalRenderer, TerminalUI, Configuration
- SwiftTerm v1.13.0 adopted (Strategy B — SwiftTerm owns state, Hi-Terms reads cells)
- SwiftTermAdapter with exitHandler, sendHandler, rangeChangedHandler, scrollback support, color mapping (default/inverted/ansi256/trueColor)
- PTYProcess: forkpty + DispatchIO + exitHandler + `resize(cols:rows:)` (TIOCSWINSZ + SIGWINCH)
- CoreTextRenderer: text attributes + cursor; **only ANSI 8 color is rendered** — 256/True Color cases fall back to default (v0.2 gap)
- DefaultTerminalPipeline connecting PTY → Parser → DirtyRegion → RenderCoordinator; `resize(cols:rows:)` wired to PTY + adapter
- Session protocol + TerminalSession (pipeline injection) + SessionRegistry (GCD thread-safe)
- InputHandler (keyboard mapping, Ctrl combos, SGR mouse reporting)
- TerminalView (NSView + CALayer): keyboard/mouse/scroll, NSTextInputClient (IME), bracketed-paste-mode-aware paste; **does NOT yet propagate window resize to Pipeline.resize**
- TerminalWindowController (font-metrics-driven window sizing)
- AppDelegate assembling full pipeline: PTY → Adapter → Pipeline → Session → Window
- OSLog subsystems configured (com.hiterms.pty/terminal/renderer/ui/app)
- DMG packaging, vttest automation, performance baseline tooling
- `Tools/verify-acceptance.sh` (A01-A11) and `Tools/verify-v0.1.sh` for automated verification

**Current step:** v0.2 mid-stream. Already shipped in v0.2:

- True Color + 256 color rendering (`6fcdf1a`)
- Window resize → SIGWINCH propagation (`efca6e6`)
- Bracketed paste tests + selection / Bell / DECTCEM trio (`96a5dfc`, `d5ed68c`, `a5d7105`)
- Shell Integration: OSC 7 (cwd → window title) + OSC 133 (`commandHistory` lifecycle, `b7`)
- **OSC 8 hyperlinks + OSC 133 visualization** (`98f6e25`): `Cell.hyperlinkURL` plumbed through SwiftTerm payload; hover underline + ⌘+click open via `HyperlinkOpener` (http/https direct, file:// gated to cwd subtree, other schemes rejected); command-boundary gutter band (success green / failure red / running blue), prompt-top 1px separator, `✗ exit=N` failure badge, alt-screen suppression. New tests: `HyperlinkPayloadTests`, `HyperlinkOpenerPolicyTests`, `HyperlinkClickTests`, `HoverDirtyTests`, `CommandBandTests`, `ShellMarkerRenderTests`, `ShellMarkerPublishTests`. Manual smoke: `Tools/smoke-hyperlinks.sh`.
- **Bare-text path detection (Smart Selection) + editor jump** (`v0.0.4` / `b9`): regex-based path scanner over the row under cursor (`PathScanner` + `RowText` in TerminalCore); `BareTextPathDetector` validates each candidate against cwd subtree (reuses `HyperlinkOpener.canOpenFile`) and `FileManager.fileExists`; `EditorJump` dispatches by extension — `.swift/.m/.h/.mm/.c/.cc/.cpp/.hpp/.xcodeproj/.xcworkspace/.xcconfig` → `xed -l <line>`; other extensions with `:line[:col]` → `vscode://file/<path>:line[:col]`; no line info → `NSWorkspace.open(fileURL)`. New `BareTextHoverSpan` channel on `RenderCoordinator`/`TerminalRendering` paints the underline; mutually exclusive with OSC 8 hover so the two never stack. Per-row LRU cache keyed by `(rowText, cwd.path)` keeps mouseMoved out of the regex/stat hot path. New tests: `PathScannerTests`, `RowTextBuilderTests`, `BareTextPathDetectorTests`, `EditorJumpTests`, `BareTextHoverTests`, `BareTextClickTests`. Manual smoke: `Tools/smoke-bare-paths.sh`.
- **Configuration 暴露视觉/安全旋钮** (this PR, `v0.0.5` / `b11`): `AppConfig` 协议新增 7 个字段——gutter alpha×3 + widthPx + separator 开关、`hyperlinkSchemeAllowlist`、`hoverMode`（`always/commandKey/off`）。`TerminalRenderer` 新增 `GutterAppearance` 值类型（不引入对 Configuration 的依赖），`CoreTextRenderer` 通过它读取 alpha/宽度/分隔线开关。`HyperlinkOpener.open` 接受 `allowedSchemes` 参数；`file://` 的 cwd 子树校验保持硬性策略（不可关闭）。`TerminalView` 持有 `appConfig`，`mouseMoved`/`flagsChanged` 据 `hoverMode` 决定是否高亮，⌘+click 不受 hover 模式约束。`AppDelegate` 改为 `UserDefaultsConfig()`，用户即时通过 `defaults write com.hiterms.* …` 调整。Settings UI 留待下一阶段。新测试：`GutterAppearanceTests`、`HoverModeTests`、扩展 `HyperlinkOpenerPolicyTests` 与 `DefaultConfigTests`。

Remaining v0.2 priorities (Roadmap §2.2): tab management, multi-window, Settings UI（绑定到本期暴露的字段）, themes, fold (skipped per ROI). See `Next2Do/v0.2-blueprint.md` for the full v0.2 scope and `Next2Do/risks-and-decisions.md` for cross-version risks.

## Development Workflow

- `make ci` — 本地 CI 全流程（构建 + lint + 测试）
- `make test` — 运行全部测试
- `make test-unit` — 仅运行单元测试（跳过集成测试）
- `make build` — Debug 构建
- `make lint` — SwiftLint 检查（可选，需 `brew install swiftlint`）
- `make clean` — 清理构建产物
- `make generate` — 重新生成 Xcode 项目
- `./Tools/install-hooks.sh` — 安装 Git pre-commit hook
- GitHub Actions CI 在 push/PR 到 main 时自动运行构建和测试
