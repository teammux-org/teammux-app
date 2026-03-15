# Teammux

Native macOS ADE (Agentic Development Environment) for coordinating teams of AI coding agents.

## What this is
Teammux lets a developer manage a team of AI coding agents (Claude Code, Codex CLI, etc.)
from a single native macOS window. Each agent works in an isolated git worktree on its own
branch. A structured Team Lead coordinates workers via a guaranteed-delivery message bus.

## Stack
- Swift + SwiftUI + AppKit — UI layer (macos/)
- Zig — coordination engine (engine/) → libteammux.a
- Ghostty fork — terminal rendering (src/ — DO NOT MODIFY upstream files)
- C API boundary — engine/include/teammux.h (source of truth between Zig and Swift)

## Repo
GitHub: teammux-org/teammux-app
Bundle: com.teammux.app
macOS: 15 Sequoia, Apple Silicon only

## Key documents (read these before doing anything)
- TEAMMUX_V01_SPEC.md — full architecture, all decisions locked
- STREAM_1_FOUNDATION.md — Stream 1 implementation guide
- STREAM_2_ZIG_ENGINE.md — Stream 2 implementation guide
- STREAM_3_SWIFT_UI.md — Stream 3 implementation guide

## Core rules
- Never modify files in src/ (Ghostty upstream)
- All Swift → Zig calls go through EngineClient.swift only
- No direct tm_* calls outside EngineClient.swift
- Every PR goes through review before merge
- main branch is always clean and deployable

## Build
./build.sh          — full build
cd engine && zig build   — engine only

## Zig version
Pinned to build.zig.zon — never update independently
