# Teammux Architecture

Technical overview of the Teammux system design, data flow, and key decisions.

## System Diagram

```text
┌─────────────────────────────────────────────────────┐
│                   Teammux.app                       │
│                                                     │
│  ┌──────────────────────────────────────────────┐   │
│  │           Swift / SwiftUI / AppKit            │   │
│  │                                               │   │
│  │  SetupView ─ WorkspaceView ─ RightPaneView   │   │
│  │  RosterView   WorkerDrawer   ContextView     │   │
│  │  GitView      DiffView       LiveFeedView    │   │
│  │  DispatchView                                 │   │
│  └────────────────────┬─────────────────────────┘   │
│                       │                             │
│              EngineClient.swift                      │
│           (sole tm_* call site)                      │
│                       │                             │
│              C API boundary                          │
│          engine/include/teammux.h                    │
│                       │                             │
│  ┌────────────────────┴─────────────────────────┐   │
│  │         Zig Coordination Engine               │   │
│  │              libteammux.a                     │   │
│  │                                               │   │
│  │  main.zig ─── C API exports                   │   │
│  │  worktree.zig ─── roster + worktree mgmt      │   │
│  │  worktree_lifecycle.zig ─── create/remove      │   │
│  │  ownership.zig ─── file ownership registry     │   │
│  │  interceptor.zig ─── git wrapper scripts       │   │
│  │  bus.zig ─── message bus                       │   │
│  │  coordinator.zig ─── dispatch + relay          │   │
│  │  merge.zig ─── merge coordinator               │   │
│  │  github.zig ─── GitHub client (gh CLI)         │   │
│  │  commands.zig ─── /teammux-* interception      │   │
│  │  hotreload.zig ─── role file watcher           │   │
│  │  history.zig ─── JSONL persistence             │   │
│  │  config.zig ─── TOML config loader             │   │
│  │  pty.zig ─── PTY types (Ghostty owns PTY fds)   │   │
│  └──────────────────────────────────────────────┘   │
│                                                     │
│  ┌──────────────────────────────────────────────┐   │
│  │         Ghostty Fork (src/)                   │   │
│  │    Terminal rendering, Metal GPU, PTY mgmt    │   │
│  │         (upstream — not modified)              │   │
│  └──────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

## Worktree Isolation Model

Each worker operates in its own git worktree. This is the foundation of Teammux's isolation model.

```text
project-root/
├── .git/                          ← shared git database
├── .teammux/
│   ├── config.toml
│   ├── roles/
│   └── logs/
│       └── completion_history.jsonl
└── (project files on main branch)

~/.teammux/worktrees/{project-hash}/
├── 1/                             ← Worker 1's worktree
│   ├── (project files on teammux/1-frontend-auth)
│   └── .git-wrapper/             ← interceptor scripts
├── 2/                             ← Worker 2's worktree
│   ├── (project files on teammux/2-api-endpoints)
│   └── .git-wrapper/
└── ...
```

**Key properties:**

- One worker = one worktree = one branch
- Branch naming: `teammux/{worker_id}-{task_slug}`
- Default worktree root: `~/.teammux/worktrees/{SHA256(project_path)}/{worker_id}/`
- Configurable via `config.toml` `[project] worktree_root`
- Worktrees share the git object database but have independent working trees and indexes
- Workers cannot see each other's uncommitted changes

## Ownership Registry and Interceptor

The ownership system has two layers: a registry that tracks rules, and an interceptor that enforces them.

### Ownership Registry (ownership.zig)

Each worker has a set of file path patterns:

- **Write patterns** — glob patterns the worker is allowed to write (e.g., `src/components/**`)
- **Deny patterns** — glob patterns the worker must not write (e.g., `src/api/**`)

Deny patterns take precedence over write patterns. When no rules are registered for a worker, the default is allow-all.

Rules come from the worker's role definition (TOML file) and are registered at spawn time. Hot-reload updates rules atomically when the role file changes.

### Git Interceptor (interceptor.zig)

The interceptor is a shell script installed in each worker's worktree at `.git-wrapper/git`. It:

1. Intercepts `git add`, `git commit -a`, `git stash pop/apply`, `git apply`, and `git push` (to main/master)
2. Checks each staged file against the ownership registry
3. Blocks denied files with exit code 126 (POSIX "command cannot execute")
4. Passes through allowed operations to the real `git` binary

The interceptor directory is prepended to PATH when launching the worker's PTY, so the wrapper is found before the system `git`.

Push-to-main is blocked for workers that have deny patterns registered (which includes all workers spawned with role-based restrictions). Workers with no deny patterns receive a pass-through wrapper. The Team Lead's deny-all interceptor also blocks push.

## Team Lead Structural Constraints

Worker 0 is always the Team Lead. The engine enforces several constraints:

- **Deny-all interceptor** — installed at session start on the project root. The Team Lead cannot stage any files.
- **Never in roster** — Worker 0 does not appear in `tm_roster_get` results. It exists as a structural element, not a managed worker.
- **Message routing target** — completion signals (`TM_MSG_COMPLETION`), questions (`TM_MSG_QUESTION`), and peer questions (`TM_MSG_PEER_QUESTION`) all route to the Team Lead.
- **Dispatch source** — only the Team Lead dispatches tasks (`TM_MSG_DISPATCH`) and responses (`TM_MSG_RESPONSE`).

These constraints are enforced by the engine, not by prompt instructions. An agent running as Team Lead physically cannot write files — the interceptor blocks it at the git level.

## Message Bus

The message bus (bus.zig) connects all components:

```text
Worker PTY ──→ Command File ──→ commands.zig ──→ bus.zig ──→ Subscribers
                                                    │
Agent writes    Engine detects   Parses command,    Routes to     Swift UI
/teammux-*      file in          creates typed      registered    updates via
command file    worktree         tm_message_t       callbacks     roster/message
                                                                  subscriptions
```

### Message types

| Type | Value | Direction | Purpose |
|------|-------|-----------|---------|
| TM_MSG_TASK | 0 | Lead → Worker | Task assignment |
| TM_MSG_INSTRUCTION | 1 | Lead → Worker | Supplementary instruction |
| TM_MSG_CONTEXT | 2 | Lead → Worker | Context information |
| TM_MSG_COMPLETION | 5 | Worker → Lead | Task completion signal |
| TM_MSG_ERROR | 6 | Any → Any | Error notification |
| TM_MSG_BROADCAST | 7 | One → All | Broadcast message |
| TM_MSG_QUESTION | 8 | Worker → Lead | Worker question |
| TM_MSG_DISPATCH | 10 | Lead → Worker | Dispatch task instruction |
| TM_MSG_RESPONSE | 11 | Lead → Worker | Response to question |
| TM_MSG_PEER_QUESTION | 12 | Worker → Lead | Peer question (relayed) |
| TM_MSG_DELEGATION | 13 | Worker → Worker | Direct task delegation |
| TM_MSG_PR_READY | 14 | Engine → Lead | PR created for worker |
| TM_MSG_PR_STATUS | 15 | GitHub → Lead | PR state change |

### Subscription model

Swift subscribes to message and roster change callbacks via `tm_message_subscribe` and `tm_roster_watch`. Callbacks fire on the engine's internal thread — callers must dispatch to the main thread for UI updates.

## Session Persistence

Session state is persisted in two forms:

- **Roster snapshot** — worker IDs, names, roles, branches, and status are saved by `SessionState.swift` and restored on relaunch. Workers are re-spawned into their existing worktrees.
- **Completion history** — completion and question events are appended to `.teammux/logs/completion_history.jsonl` using an atomic read-rewrite-rename pattern. History is loaded on session start and displayed in the LiveFeed's collapsible history section.

## Key Design Decisions

### Why a C API boundary?

The engine is written in Zig for performance and manual memory control. The Swift UI layer is a standard SwiftUI application. The C API (`teammux.h`) provides a clean, stable boundary between the two. All engine functions are exported with C linkage, documented with lifetime semantics, and callable from Swift via a single `EngineClient.swift` file. This makes the engine independently testable with a comprehensive test suite without the Swift layer.

### Why git worktrees instead of containers?

Worktrees are lightweight (shared object database), fast to create/remove, and require no extra infrastructure. They provide working directory isolation while keeping git history unified. For AI agents that primarily need file isolation — not process isolation — worktrees are the right abstraction.

### Why structural enforcement instead of prompt-based rules?

Prompt-based rules ("please don't write to files outside your scope") depend on agent compliance. A git interceptor that exits 126 on denied files is deterministic — it cannot be circumvented by a misbehaving agent. The ownership registry is the source of truth, and the interceptor is the enforcement mechanism. This is the core design philosophy of Teammux: enforce at the system level, not the instruction level.

### Why Ghostty as the terminal base?

Ghostty provides a production-quality, GPU-accelerated terminal with native macOS integration (SwiftUI, Metal rendering). Rather than building terminal emulation from scratch, Teammux forks Ghostty and adds the coordination layer on top. The `src/` directory is treated as upstream and is never modified — all Teammux code lives in `engine/` and `macos/Sources/Teammux/`.
