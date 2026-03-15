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

## Key files
- engine/include/teammux.h     — C API contract (source of truth)
- .teammux/config.toml         — project team configuration (per user project)
- CLAUDE.md                    — this file

## Zig version
Pinned to build.zig.zon. Never update independently — sync with Ghostty upstream.

## macOS target
macOS 15 Sequoia, Apple Silicon only.
Bundle: com.teammux.app
