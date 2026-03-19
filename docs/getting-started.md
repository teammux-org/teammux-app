# Getting Started with Teammux

This guide walks you through installing, configuring, and using Teammux for the first time.

## 1. Install Prerequisites

You need:

- **macOS 15 Sequoia** on Apple Silicon (M1 or later)
- **Xcode 16+** — install from the App Store, then run `xcode-select --install`
- **Zig 0.15.x** (nightly) — download from [ziglang.org/download](https://ziglang.org/download/) and add to your PATH
- **GitHub CLI** — `brew install gh`, then authenticate with `gh auth login`
- **Git 2.40+** — ships with Xcode command line tools

Verify your setup:

```bash
zig version        # should show 0.15.x
gh auth status     # should show authenticated
git --version      # should show 2.40+
```

## 2. Clone and Build

```bash
git clone https://github.com/AkramHarazworktree/teammux.git
cd teammux
./build.sh
```

This builds the Zig coordination engine, the Swift/SwiftUI application layer, and the Ghostty terminal fork. On success, the Teammux.app bundle is ready to run.

To build just the engine (faster iteration):

```bash
cd engine && zig build
```

To run the engine test suite:

```bash
cd engine && zig build test
```

## 3. Configure Your Project

Teammux looks for a `.teammux/` directory in your project root. Create one:

```bash
cd /path/to/your/project
mkdir -p .teammux/roles
```

Create `.teammux/config.toml`:

```toml
[project]
name = "my-project"
# Optional: custom worktree root (default: ~/.teammux/worktrees/{hash}/)
# worktree_root = "/path/to/worktrees"
```

## 4. Define Your First Role

Roles define what a worker is allowed to do. Create `.teammux/roles/frontend.toml`:

```toml
id = "frontend"
name = "Frontend Developer"
division = "engineering"
emoji = "🎨"
description = "Works on the frontend UI components"

# Files this role is allowed to write
write_patterns = [
    "src/components/**",
    "src/styles/**",
    "src/pages/**",
]

# Files this role must NOT write (takes precedence over write_patterns)
deny_write_patterns = [
    "src/api/**",
    "src/database/**",
]

can_push = false
can_merge = false
```

The engine enforces these patterns via a git interceptor — `git add` on a denied file will be blocked before it reaches the index.

## 5. Launch Teammux

Open Teammux and point it at your project directory. The setup flow will:

1. Verify the directory is a git repository
2. Check for `gh` CLI authentication
3. Load your `.teammux/config.toml`
4. Initialize the coordination engine
5. Install the Team Lead interceptor on the project root

Once setup completes, you'll see the workspace view with an empty roster.

## 6. Spawn Your First Worker

Click the spawn button in the workspace. You'll be asked for:

- **Worker name** — a short label (e.g., "alice")
- **Role** — select from your defined roles (e.g., "frontend")
- **Task description** — what the worker should accomplish
- **Agent type** — Claude Code, Codex CLI, or a custom agent binary

When you confirm, the engine:

1. Claims the next available worker ID
2. Creates a git worktree on branch `teammux/{id}-{slug}`
3. Registers ownership rules from the role definition
4. Installs the git interceptor in the worktree
5. Launches the agent in an isolated terminal pane

The worker appears in the roster with status "idle".

## 7. The Team Lead Interface

Worker 0 is the **Team Lead**. It is created automatically and has special constraints:

- A **deny-all interceptor** is installed at session start — the Team Lead cannot write files
- It can **dispatch tasks** to workers via the Dispatch tab
- It can **respond to worker questions** that arrive via the message bus
- It **reviews PRs** in the Git tab and approves or rejects merges

The right pane shows tabs for:

- **Git** — Worker branches, PRs, merge controls
- **Diff** — Per-file diffs from GitHub PRs
- **LiveFeed** — Real-time message bus events (completions, questions, dispatches)
- **Dispatch** — Send task instructions or responses to workers
- **Context** — View and monitor each worker's CLAUDE.md with hot-reload diff highlights

## 8. Complete a Task and Review the PR

When a worker finishes its task, it signals completion. The flow is:

1. **Worker signals completion** — the agent writes a `/teammux-complete` command file with a summary. The engine routes a `TM_MSG_COMPLETION` message to the Team Lead.

2. **PR creation** — the engine creates a GitHub PR from the worker's branch to main. A `TM_MSG_PR_READY` message appears in the LiveFeed.

3. **Team Lead review** — in the Git tab, you can see the PR, view the diff, and decide:
   - **Approve merge** — choose squash, rebase, or merge strategy. The engine merges the branch, cleans up the worktree, and dismisses the worker.
   - **Reject** — the engine aborts the merge, removes the worktree, deletes the branch, and dismisses the worker.

4. **Cleanup** — on merge or rejection, the engine releases ownership rules and removes the interceptor. The worker disappears from the roster.

## Next Steps

- Read the [Architecture](architecture.md) doc to understand how the engine, C API, and Swift UI connect
- See [CONTRIBUTING.md](../CONTRIBUTING.md) for development conventions if you want to work on Teammux itself
- Check `docs/TECH_DEBT.md` for known issues and planned improvements
