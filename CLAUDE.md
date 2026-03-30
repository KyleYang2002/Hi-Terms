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

Pre-implementation — the repo contains product vision, requirements, roadmap, design, and decision documents. No build system, tests, or source code yet. Next step: implement v0.0.
