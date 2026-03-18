# Teammux

Native macOS ADE for coordinating teams of AI coding agents.

## Stack
- Swift + SwiftUI + AppKit — UI (macos/)
- Zig — coordination engine (engine/) → libteammux.a
- Ghostty fork — terminal rendering (src/)
- C API boundary — engine/include/teammux.h

## Hard rules
- NEVER modify src/ (Ghostty upstream — read only)
- ALL tm_* calls go through EngineClient.swift only
- NO force-unwraps in production code
- NO direct git operations outside worktree.zig, worktree_lifecycle.zig, merge.zig, interceptor.zig, coordinator.zig, history.zig
- engine/include/teammux.h is the authoritative C API contract
- roles/ directory is the authoritative role library — never fetch external roles
- Worktree root defaults to ~/.teammux/worktrees/{project_hash}/{worker_id}/ — configurable via config.toml worktree_root key

## Build
./build.sh                  — full build
cd engine && zig build       — engine only
cd engine && zig build test  — engine tests

## Zig version
Pinned to build.zig.zon — never update independently

## macOS target
macOS 15 Sequoia, Apple Silicon only — com.teammux.app

## Sprint workflow
- main thread: orchestrator only — no feature code
- feature work happens in stream worktrees only
- every stream raises a PR, main thread reviews and merges
- merge order defined in current sprint file
- no stream merges without main thread approval

## Key documents
- engine/include/teammux.h  — C API source of truth
- roles/                    — bundled role library (local only, no external fetching)
- TECH_DEBT.md              — open and resolved debt items
- V014_SPRINT.md            — current sprint spec

## Version history
- v0.1.0 — Ghostty fork, Zig engine, Swift UI, git worktrees, message bus
- v0.1.1 — bus retry, webhook polling, MergeCoordinator, Team Lead review UI
- v0.1.2 — role definitions, FileOwnershipRegistry, PTY interceptor, 31 role library
- v0.1.3 — coordination loop, completion signaling, hot-reload, interceptor hardening, role selector, dispatch UI
- v0.1.4 — in progress: git worktree isolation, fully autonomous Team Lead, persistent sessions, PR lifecycle, worker-to-worker messaging, CLAUDE.md context viewer
