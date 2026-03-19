# Teammux — Codex Agent Instructions

## Project Overview

Teammux is a native macOS ADE (AI Development Environment)
for coordinating teams of AI coding agents. It is a fork
of Ghostty 1.3.0 — a GPU-accelerated terminal emulator —
extended with a multi-agent coordination engine.

**Stack:**
- Engine: Zig (coordination engine, built as libteammux.a)
- UI: Swift + SwiftUI + AppKit (macOS 15 Sequoia, Apple Silicon only)
- Terminal rendering: Ghostty fork (Zig + Metal)
- C API boundary: engine/include/teammux.h
- Bundle: com.teammux.app
- Build: ./build.sh (full), cd engine && zig build (engine only)
- Tests: cd engine && zig build test (356 tests, 0 failures baseline)

**Key directories:**
- engine/src/ — Zig coordination engine source
- engine/include/teammux.h — C API (source of truth for engine↔Swift boundary)
- macos/Sources/Teammux/ — Swift application source
- macos/Sources/Teammux/Engine/EngineClient.swift — sole tm_* call site in Swift
- docs/ — all documentation (sprint specs, architecture, audit reports)
- src/ — Ghostty upstream files (DO NOT MODIFY)

**Authoritative docs to read before any task:**
- CLAUDE.md — project rules, conventions, hard constraints
- docs/TECH_DEBT.md — known open (TD21-TD28) and resolved tech debt
- engine/include/teammux.h — C API contract

## Build & Test Commands

  # Full build (Swift + engine + Ghostty fork)
  ./build.sh

  # Engine only
  cd engine && zig build

  # Engine tests (356 passing baseline)
  cd engine && zig build test

  # Fast search (always prefer rg over grep)
  rg <pattern> engine/src/
  rg --files engine/src/

Note: Zig 0.15.2 (nightly) is in use. The build runner
may crash transiently — retry once before concluding it
is a code issue.

## Core Conventions

- ALL tm_* C API calls confined to EngineClient.swift exclusively
- No raw POSIX PTY shortcuts — Ghostty native PTY infrastructure only
- Engine memory: manual Zig allocator discipline, owned strings
  duped on store, errdefer on partial allocations
- Swift: @MainActor on EngineClient, no force-unwraps in production
- C API strings: some are caller-must-free (tm_free_string),
  some are must-not-free (const char* owned by engine) — check header
- No src/ modifications (Ghostty upstream, not owned by Teammux)

## What Codex MUST NOT Do

- DO NOT modify any source files (*.zig, *.swift, *.h, *.toml)
- DO NOT modify src/ under any circumstances
- DO NOT modify CLAUDE.md, README.md, AGENTS.md, or LICENSE
- DO NOT make commits
- DO NOT run git push
- DO NOT run git checkout or switch branches
- DO NOT install dependencies or modify build configuration

## Current State

Version v0.1.4 shipped. Tag: v0.1.4.
Engine: 356 tests passing, 0 failures.
Open tech debt: TD21-TD28 (see docs/TECH_DEBT.md).
Sprint history: docs/sprints/
