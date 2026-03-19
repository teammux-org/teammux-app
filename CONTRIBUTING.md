# Contributing to Teammux

Thank you for your interest in contributing to Teammux. This guide covers development setup, project conventions, and the workflow for submitting changes.

## Development Setup

### Prerequisites

- macOS 15 Sequoia on Apple Silicon
- Xcode 16+ (with command line tools)
- Zig 0.15.x nightly — install via [ziglang.org/download](https://ziglang.org/download/)
- `gh` CLI — `brew install gh` and authenticate with `gh auth login`
- Git 2.40+

### Building

```bash
# Clone the repository
git clone https://github.com/AkramHarazworktree/teammux.git
cd teammux

# Full build (engine + Swift app + Ghostty fork)
./build.sh

# Engine only (faster iteration for Zig changes)
cd engine && zig build

# Run engine tests
cd engine && zig build test
```

> **Note:** Zig 0.15.x (nightly) is in use. The build runner may crash transiently — retry once before treating it as a code issue.

### Verifying Your Setup

After a successful `./build.sh`, you should find the Teammux.app bundle in the build output. The engine test suite should report all tests passing with zero failures.

## Repository Structure

```
engine/src/              — Zig coordination engine source
engine/include/          — C API header (teammux.h, source of truth)
macos/Sources/Teammux/   — Swift application layer
  Engine/                — EngineClient.swift (sole tm_* call site)
  Models/                — CoordinationTypes, TeamMessage
  RightPane/             — Git, Diff, LiveFeed, Dispatch, Context tabs
  Workspace/             — RosterView, WorkerDetailDrawer, WorkerRow
  Setup/                 — SetupView, SessionState
  App/                   — AppDelegate
src/                     — Ghostty upstream (DO NOT MODIFY)
docs/                    — Documentation
  sprints/               — Per-sprint master specs and stream task files
  codex-audits/          — Codex audit reports and action plans
  TECH_DEBT.md           — All known tech debt with target versions
```

## Sprint and Stream Workflow

Teammux uses a structured sprint model:

- **Sprints** are versioned (e.g., v0.1.5) with a master spec in `docs/sprints/{version}/`.
- **Streams** are numbered units of work (S1, S2, ...) within a sprint. Each stream gets its own branch and PR.
- **Waves** define merge order. Streams within a wave can run in parallel; waves are sequential.
- The **main thread** is the orchestrator — it reviews and merges stream PRs but never contains feature code directly.
- Stream task files live in `docs/sprints/{version}/streams/`.

### PR workflow

1. Create a branch from `main` following the naming convention: `fix/v{version}-s{number}-{slug}`
2. Implement the stream's scope — only modify files listed in the stream spec
3. Verify: `cd engine && zig build test` for engine changes, `./build.sh` for Swift changes
4. Open a PR against `main`
5. The main thread reviews and merges in the order defined by the sprint spec

## CLAUDE.md and AGENTS.md

These files are part of the Teammux development workflow:

- **CLAUDE.md** — Project instructions for Claude Code. Contains architecture rules, build commands, directory structure, C API conventions, and version history. This is the authoritative source for project constraints and is checked into the repository.
- **AGENTS.md** — Instructions for Codex agents running audits and analysis tasks. Contains the same project context in a format optimized for Codex, with explicit restrictions on what agents must not do.

Both files should be kept up to date when project conventions change.

## Code Conventions

### Zig (engine/)

- Manual allocator discipline — owned strings are duped on store
- Use `errdefer` on partial allocations to prevent leaks
- All public engine API surfaces through `engine/include/teammux.h`
- `tm_*` functions that return `const char*` — check the header comment for lifetime semantics (caller-must-free vs must-not-free)
- Thread safety: callbacks fire on the engine's internal thread. Document threading assumptions in comments.

### Swift (macos/)

- All `tm_*` C API calls are confined to `EngineClient.swift` exclusively. No direct `tm_*` calls anywhere else in the Swift layer.
- `@MainActor` on EngineClient
- No force-unwraps (`!`) in production code
- No raw POSIX PTY shortcuts — use Ghostty's native PTY infrastructure only

### Ghostty upstream (src/)

**Do not modify files in `src/`.** This directory contains the Ghostty fork and is treated as upstream. All Teammux functionality lives in `engine/` and `macos/Sources/Teammux/`.

## Reporting Bugs

Open an issue on GitHub with:

- Steps to reproduce
- Expected vs actual behavior
- macOS version and hardware
- Zig version (`zig version`)
- Relevant log output or error messages

If the issue involves the coordination engine, include the engine's last error message if available.

## Proposing Features

Open a GitHub discussion or issue describing:

- The problem you want to solve
- Your proposed approach
- Which layer it affects (engine, Swift UI, C API, or docs)

For significant changes, expect discussion before implementation begins. The sprint workflow means features are scoped and scheduled into versioned sprints.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
