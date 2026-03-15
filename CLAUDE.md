# Teammux

Native macOS application for coordinating teams of AI coding agents.

## Stack
- Swift + SwiftUI + AppKit — UI layer (macos/)
- Zig — coordination engine (engine/) → libteammux.a
- Ghostty fork — terminal rendering (src/ — DO NOT MODIFY)
- C API boundary — engine/include/teammux.h

## Architecture rules
- engine/ contains all coordination logic. Swift calls it via teammux.h only.
- src/ is Ghostty upstream. Never modify files in src/.
- macos/Sources/Teammux/ is the Teammux Swift layer.
- All Swift → Zig calls go through macos/Sources/Teammux/Engine/EngineClient.swift only.
- No direct tm_* calls outside EngineClient.swift.

## Build
./build.sh          — full build (engine + app)
cd engine && zig build   — engine only
zig build -Demit-macos-app=true  — app only (requires libteammux.a in macos/Resources/)

## Key documents
- engine/include/teammux.h     — C API contract (source of truth)
- .teammux/config.toml         — project team configuration (per user project)
- CLAUDE.md                    — this file
- TECH_DEBT.md                 — known tech debt items with owner and target version
- V011_SPRINT.md               — v0.1.1 sprint master spec

## Zig version
Pinned to build.zig.zon. Never update independently — sync with Ghostty upstream.

## macOS target
macOS 15 Sequoia, Apple Silicon only.
Bundle: com.teammux.app

## Sprint workflow
- Main thread: orchestrator only — no feature code
- All feature work happens in numbered stream worktrees
- Every stream raises a PR, main thread reviews, then merges
- Merge order is defined in V011_SPRINT.md
- No stream merges without main thread approval

## Version History
- v0.1.0 — shipped: Ghostty fork, Zig engine, Swift UI, git worktrees, message bus, setup flow, workspace
- v0.1.1 — in progress: tech debt resolution + MergeCoordinator + Team Lead review workflow
