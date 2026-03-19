# Teammux

A native macOS AI Development Environment (ADE) for coordinating teams of AI coding agents. Built as a fork of [Ghostty](https://ghostty.org) 1.3.0, Teammux extends a GPU-accelerated terminal emulator with a multi-agent coordination engine that enforces file ownership, worktree isolation, and Team Lead review at the engine level — not by convention.

## Why Teammux

Most multi-agent setups rely on prompts and good behavior to prevent agents from stepping on each other's work. Teammux enforces it structurally:

- **Worktree isolation** — Each worker gets its own git worktree and branch. No shared working directory, no merge conflicts during development.
- **Ownership registry** — The engine tracks which files each worker is allowed to write. A git interceptor blocks unauthorized writes before they reach the index.
- **Team Lead constraints** — Worker 0 is the Team Lead. It has a deny-all interceptor installed at session start — it reviews and merges, but never writes code directly.
- **Coordination engine** — A Zig engine (libteammux.a) manages the full lifecycle: spawn, dispatch, messaging, completion signaling, PR creation, merge, and dismiss — all through a C API that Swift calls exclusively via a single EngineClient.

<!-- TODO: Add screenshot or architecture diagram -->

## Requirements

- macOS 15 Sequoia
- Apple Silicon (arm64)
- Xcode 16+
- Zig 0.15.x (nightly)
- `gh` CLI (for GitHub integration)
- Git 2.40+

## Quick Start

```bash
# Clone the repository
git clone https://github.com/AkramHarazworktree/teammux.git
cd teammux

# Build everything (engine + Swift + Ghostty)
./build.sh

# Or build the engine only
cd engine && zig build

# Run engine tests
cd engine && zig build test
```

> **Note:** Zig 0.15.x (nightly) is in use. The build runner may crash transiently — retry once before treating it as a code issue.

## How It Works

1. **Session start** — You open Teammux on a git repository. The engine initializes, installs the Team Lead interceptor on the project root, and loads project configuration from `.teammux/config.toml`.

2. **Spawn workers** — Each worker gets a name, a role (from a TOML file defining write/deny patterns), and a task description. The engine creates a git worktree on a dedicated branch (`teammux/{id}-{slug}`), registers ownership rules, installs a git interceptor, and launches the agent in its isolated terminal.

3. **Work in isolation** — Workers operate in their own worktrees. The interceptor blocks writes to files outside their role's allowed patterns. Workers can signal completion (`/teammux-complete`) or ask questions (`/teammux-question`) through command files routed via the message bus.

4. **Review and merge** — The Team Lead reviews each worker's output. The merge coordinator handles squash/rebase/merge strategies, surfaces conflicts, and cleans up worktrees and branches after merge or rejection.

## Documentation

- **[Getting Started Guide](docs/getting-started.md)** — Step-by-step walkthrough for first-time users
- **[Architecture](docs/architecture.md)** — System design, data flow, and key decisions
- **[Contributing](CONTRIBUTING.md)** — Development setup, conventions, and workflow

## Project Structure

```
engine/src/          — Zig coordination engine
engine/include/      — C API header (teammux.h)
macos/Sources/Teammux/   — Swift application layer
src/                 — Ghostty upstream (not modified)
docs/                — Sprint specs, architecture, audit reports
```

See [Architecture](docs/architecture.md) for the full system breakdown.

## Current Status

Teammux is in active development. The current version is **v0.1.5** (polish and stability). See the [version history in CLAUDE.md](CLAUDE.md) for shipped milestones.

## License

MIT — see [LICENSE](LICENSE).

Teammux is a fork of [Ghostty](https://ghostty.org) by Mitchell Hashimoto and contributors.
