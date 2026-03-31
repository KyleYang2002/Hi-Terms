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

V0.0 engineering baseline implemented. The repo now has:
- Xcode project (via XcodeGen `project.yml`) with HiTerms app target and 6 test targets
- 5 SPM packages: TerminalCore, PTYKit, TerminalRenderer, TerminalUI, Configuration
- SwiftTerm v1.13.0 adopted (Strategy B — SwiftTerm owns state, Hi-Terms reads cells)
- SwiftTermAdapter wrapping SwiftTerm.Terminal behind TerminalParser protocol
- PTYProcess spike (forkpty + DispatchIO)
- OSLog subsystems configured (com.hiterms.pty/terminal/renderer/app)
- 40 tests passing across all modules
- DMG packaging script, vttest automation framework, performance baseline tooling
- `Tools/verify-acceptance.sh` for automated A01-A11 verification

Next step: implement v0.1 (terminal kernel — full PTY+shell+rendering).

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
