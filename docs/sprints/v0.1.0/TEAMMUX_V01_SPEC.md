# TEAMMUX — v0.1 Master Specification

**Status:** Pre-implementation · Living document  
**Authors:** Akram + Claude  
**Date:** March 2026  
**Repo:** `teammux-org/teammux-app`  
**License:** MIT

---

## 1. Vision

Teammux is a native macOS application for coordinating a team of AI coding agents on a single codebase. The mental model is a software engineering office — a Team Lead who directs, workers who execute, and the developer who oversees everything from one window.

The developer opens Teammux, assembles their team, and manages an entire engineering operation from their laptop. Workers are isolated in git worktrees. The Team Lead coordinates through a structured message bus. The developer can step into any worker's terminal at any time for manual override.

**The pitch:** Manage a SWE office from anywhere in the world on your laptop — the way you would in SF.

---

## 2. Architectural Decisions — Locked

| Decision | Choice | Rationale |
|---|---|---|
| Terminal rendering | Ghostty fork | Best-in-class native quality. No compromise. |
| Coordination engine | Zig → `libteammux.a` | Compiled into app binary. Direct C API. No IPC socket. No separate process. |
| UI layer | Swift + SwiftUI + AppKit | Native macOS. No Electron, no Tauri, no web. |
| Git isolation | Git worktrees | One worker = one worktree = one branch. Structural, not advisory. |
| Config format | TOML | Human-editable, supports comments, familiar from Cargo. |
| GitHub integration | First-class, GitHub API | 99% of users are on GitHub. Tight integration, not optional. |
| Message bus | TCP-style guaranteed delivery | Ordered, reliable. Engine owns the channel. Not observer/UDP. |
| Ownership registry | None | Git worktrees provide the isolation. No file locking needed. |
| Team Lead agent | Claude Code only in v0.1 | Simplest correct starting point. Other agents in v0.2+. |
| macOS minimum | macOS 15 Sequoia, Apple Silicon only | macOS 15 Sequoia. Latest SwiftUI APIs. Apple Silicon only. No legacy compromise. |
| Zig version | Pinned to Ghostty's `build.zig.zon` | Inherited automatically. Zero independent versioning decisions. |

---

## 3. Repository Structure

```
teammux-org/
└── teammux-app/                          ← monorepo root
    ├── .git/
    ├── src/                          ← Ghostty Zig core (upstream fork, do not modify)
    ├── include/                      ← Ghostty C headers (upstream)
    ├── engine/                       ← Zig coordination engine (Teammux-authored)
    │   ├── build.zig                 ← produces libteammux.a
    │   ├── src/
    │   │   ├── main.zig              ← engine entry point
    │   │   ├── worktree.zig          ← git worktree lifecycle
    │   │   ├── pty.zig               ← PTY ownership and scoping
    │   │   ├── bus.zig               ← message bus (TCP-style guaranteed delivery)
    │   │   ├── config.zig            ← TOML config parsing and hot-reload
    │   │   ├── github.zig            ← GitHub API integration
    │   │   └── commands.zig          ← /teammux-* command watcher
    │   └── include/
    │       └── teammux.h             ← C API boundary (Swift calls this)
    ├── macos/                        ← Swift layer (Teammux-authored)
    │   ├── Sources/
    │   │   ├── App/
    │   │   │   └── macOS/
    │   │   │       └── AppDelegate.swift
    │   │   └── Teammux/
    │   │       ├── Setup/            ← first-launch setup screens
    │   │       │   ├── SetupView.swift
    │   │       │   ├── ProjectPickerView.swift
    │   │       │   ├── TeamBuilderView.swift
    │   │       │   └── InitiateView.swift
    │   │       ├── Workspace/        ← main workspace
    │   │       │   ├── WorkspaceView.swift
    │   │       │   ├── ProjectTabBar.swift
    │   │       │   ├── RosterView.swift
    │   │       │   ├── WorkerPane.swift
    │   │       │   └── RightPane/
    │   │       │       ├── RightPaneView.swift
    │   │       │       ├── TeamLeadTerminalView.swift
    │   │       │       ├── GitView.swift
    │   │       │       ├── DiffView.swift
    │   │       │       └── LiveFeedView.swift
    │   │       ├── Engine/           ← Swift ↔ libteammux bridge
    │   │       │   ├── EngineClient.swift
    │   │       │   └── TeammuxBridge.swift
    │   │       └── GitHub/           ← GitHub API client (Swift)
    │   │           └── GitHubClient.swift
    │   └── Resources/
    │       └── libteammux.a          ← compiled engine binary (copied by build)
    ├── CLAUDE.md                     ← living context for Claude Code sessions
    ├── TEAMS.md                      ← guide for the /teammux-* skill
    ├── build.sh                      ← unified build: Zig engine → copy → Zig/Xcode
    ├── build.zig                     ← Ghostty + engine build
    └── build.zig.zon                 ← Zig dependencies (pinned, inherited from Ghostty)
```

---

## 4. The C API Boundary — `teammux.h`

This file is the contract between Swift and Zig. Swift calls nothing from the engine except what is declared here. Every function is prefixed `tm_`.

### Core lifecycle

```c
// Engine lifecycle
tm_engine_t* tm_engine_create(const char* project_root);
void         tm_engine_destroy(tm_engine_t* engine);

// Session
tm_result_t  tm_session_start(tm_engine_t* engine);
void         tm_session_stop(tm_engine_t* engine);
```

### Config

```c
// Config loading and hot-reload
tm_config_t* tm_config_load(const char* config_path);
void         tm_config_watch(tm_engine_t* engine, tm_config_changed_cb callback);
void         tm_config_reload(tm_engine_t* engine);
```

### Worktree lifecycle

```c
// Spawn a worker in a new worktree
tm_worker_id_t tm_worker_spawn(
    tm_engine_t* engine,
    const char*  agent_binary,    // resolved path to claude, codex, etc.
    const char*  task_description,
    const char*  task_slug        // used for branch name: teammux/{task-slug}
);

// Dismiss a worker (worktree removed, branch kept)
tm_result_t tm_worker_dismiss(tm_engine_t* engine, tm_worker_id_t worker_id);

// Get current roster
tm_roster_t* tm_roster_get(tm_engine_t* engine);
void         tm_roster_free(tm_roster_t* roster);
```

### Message bus

```c
// Send message from Team Lead → worker (guaranteed delivery, ordered)
tm_result_t tm_message_send(
    tm_engine_t*   engine,
    tm_worker_id_t target,
    const char*    message_type,  // "task", "instruction", "context"
    const char*    payload        // JSON string
);

// Register callback for incoming messages (worker → engine → Swift)
void tm_message_subscribe(tm_engine_t* engine, tm_message_cb callback, void* userdata);
```

### GitHub

```c
// GitHub auth (reads from gh CLI credentials or config.toml token)
tm_result_t tm_github_auth(tm_engine_t* engine);

// PR operations
tm_pr_t*    tm_github_create_pr(tm_engine_t* engine, tm_worker_id_t worker_id, const char* title);
tm_result_t tm_github_merge_pr(tm_engine_t* engine, tm_pr_t* pr, tm_merge_strategy_t strategy);
tm_diff_t*  tm_github_get_diff(tm_engine_t* engine, tm_worker_id_t worker_id);
```

### /teammux-* command interception

```c
// Watch .teammux/commands/ for Team Lead command files
void tm_commands_watch(tm_engine_t* engine, tm_command_cb callback);
```

---

## 5. Config Schema — `.teammux/config.toml`

This file lives in the project root, committed to the repo. Team composition is version-controlled and shareable.

```toml
# .teammux/config.toml
# Committed to repo — shared with teammates
# Override locally with .teammux/config.local.toml (gitignored)

[project]
name = "my-project"
github_repo = "owner/repo"        # optional — enables GitHub integration

[team_lead]
agent = "claude-code"             # v0.1: always claude-code
model = "claude-opus-4-6"         # default model
permissions = "full"              # full | restricted

[[workers]]
id = "worker-1"
name = "Frontend"
agent = "claude-code"             # claude-code | codex-cli
model = "claude-sonnet-4-6"
permissions = "full"              # always defaults to full (worktree isolated)
default_task = ""                 # optional: pre-filled task on spawn

[[workers]]
id = "worker-2"
name = "Backend"
agent = "codex-cli"
model = "gpt-5"
permissions = "full"

[github]
# Token resolution order:
# 1. gh CLI credentials (~/.config/gh/hosts.yml) — auto-detected, zero config
# 2. OAuth flow via GUI — triggered if gh not found
# 3. PAT below — power user escape hatch
# token = "ghp_..."              # uncomment to use PAT directly

[bus]
delivery = "guaranteed"           # guaranteed | observer (toggle in future)
```

### Local overrides — `.teammux/config.local.toml` (gitignored)

```toml
# Machine-specific overrides — never committed
[github]
token = "ghp_personal_token_here"

[team_lead]
model = "claude-opus-4-6"         # override model locally
```

---

## 6. First Launch — Setup Flow

When Teammux opens a project with no `.teammux/` directory, the setup screen runs. It always runs on first launch — never auto-skipped.

### Screen 1 — Welcome

```
Teammux
─────────────────────────────────
Where does this mission begin?

[ Select project folder ]
[ Open recent: my-project ]
[ Open recent: another-project ]

Drag a git repo here to open it.
```

If the selected folder is not a git repo, show a clear message: "This folder isn't a git repository. Teammux needs a git repo to manage agent worktrees. You can initialise one: `git init`." Do not block — show a button to run `git init` for them.

### Screen 2 — Build Your Team

```
Who leads this mission?
─────────────────────────────────
Team Lead:  [ Claude Code ▼ ]   Model: [ claude-opus-4-6 ▼ ]

How many teammates?
─────────────────────────────────
[ 1 ]  [ 2 ]  [ 3 ]  [ 4 ]  [ + ]

Configure each teammate:
─────────────────────────────────
Teammate 1   Agent: [ Claude Code ▼ ]   Model: [ claude-sonnet-4-6 ▼ ]   Name: [ Frontend     ]
Teammate 2   Agent: [ Codex CLI   ▼ ]   Model: [ gpt-5            ▼ ]   Name: [ Backend      ]

Permissions: Full (recommended — git worktree isolation is in place)

Connect GitHub  [ ● Connected via gh CLI ]
```

Roles: worker names are free-form text. The developer names their team members however they want. Default names: Teammate 1, Teammate 2, etc.

### Screen 3 — Initiate

```
Your team is assembled.

  Team Lead     Claude Code    claude-opus-4-6
  Frontend      Claude Code    claude-sonnet-4-6
  Backend       Codex CLI      gpt-5

  GitHub        ● Connected — owner/repo

[ Initiate Mission ]
```

On click: Teammux writes `.teammux/config.toml`, creates `.teammux/` directory structure, writes the Team Lead's skill file, opens the main workspace.

---

## 7. Main Workspace Layout

```
┌─────────────────────────────────────────────────────────────────┐
│  my-project ×    another-project    [+]          ← project tabs │
├──────────┬────────────────────────┬────────────────────────────┤
│          │                        │ [ Team Lead │ Git │ Diff │ Feed ] │
│  ROSTER  │                        │                            │
│          │   ACTIVE WORKER        │   RIGHT PANE               │
│  Team    │   TERMINAL             │   (full height)            │
│  Lead    │                        │                            │
│          │   (Ghostty surface)    │   (Ghostty terminal        │
│  [●] F.. │                        │    or SwiftUI view         │
│  [●] B.. │                        │    depending on tab)       │
│          │                        │                            │
│  [+] New │                        │                            │
│  Worker  │                        │                            │
└──────────┴────────────────────────┴────────────────────────────┘
```

### Project tab bar (top)
Chrome-style horizontal tabs. One tab per open project. Active project highlighted. `[+]` opens folder picker or accepts drag-and-drop. Each tab is a fully independent Teammux workspace with its own engine instance.

When any agent in a background tab needs a decision, the tab pulses with a subtle amber indicator — same pattern as browser tabs showing activity.

### Left pane — roster

Fixed width ~200px. Never a terminal. Pure SwiftUI.

```
TEAM LEAD
● Claude Code        [active]

WORKERS
● Frontend           [working]
  "implement auth..."
● Backend            [idle]
  "fix login bug"

─────────────────────
[+] New Worker
[ ⚙ Project Settings ]
```

Team Lead row is pinned at top. Always present. Not dismissable. Clicking it focuses the Team Lead terminal in the right pane.

Worker rows show: status dot (green=active, amber=working, gray=idle, red=needs attention), worker name, truncated task description. Clicking a worker switches the centre pane to that worker's terminal. A small `×` button (visible on hover) dismisses the worker.

`[+] New Worker` opens a spawn popover (see Section 8).

### Centre pane — active worker terminal

Full Ghostty terminal surface. Switches on roster click. PTY state is preserved when hidden — `opacity(0)` + `allowsHitTesting(false)` keeps the process running. The active worker's terminal is `opacity(1)`.

When no workers exist, shows a placeholder:
```
No workers yet.
Click [+] to spawn your first teammate.
```

### Right pane — four tabs

**Tab 1: Team Lead**
Full Ghostty terminal running the Team Lead agent (Claude Code in v0.1). Full height. No split. This is where the developer spends most of their time — directing the team, reviewing work, approving merges.

**Tab 2: Git**
SwiftUI view. Shows:
- Current branch (main)
- All active worker branches with status
- Recent commits on main
- GitHub PR status for each worker branch (if GitHub connected)
- Merge buttons per worker branch (triggers Team Lead approval flow)

**Tab 3: Diff**
SwiftUI view. Shows the GitHub diff for the selected worker's branch vs main. File-by-file, syntax highlighted. Powered by GitHub API. Select worker from dropdown at top of pane.

**Tab 4: Live Feed**
SwiftUI view. Real-time activity stream from the message bus. Every message routed through the engine appears here with timestamp, source, target, and content preview. This is the audit trail of what every agent is doing.

---

## 8. Spawn Flow — New Worker

The `[+]` button in the roster opens a popover (not a sheet, not a modal):

```
New Teammate
──────────────────────────────
Task:     [ what should this worker do?    ]

Agent:    [ Claude Code ▼ ]
Model:    [ claude-sonnet-4-6 ▼ ]
Name:     [ auto-generated from task ▼ ]
Permissions: ● Full  ○ Restricted

[ Initiate Teammate ]
```

On confirm:
1. Engine creates git worktree: `git worktree add .teammux/{task-slug} -b teammux/{task-slug}`
2. Engine writes `CLAUDE.md` (or `AGENTS.md` for Codex) into the worktree with task context and `/teammux-*` skill
3. Engine spawns PTY with `cwd = .teammux/{task-slug}/`
4. Engine resolves agent binary via PATH
5. Ghostty SurfaceView created with worktree cwd
6. Task description injected into PTY stdin (2s delay for agent initialization — documented as known v0.1 limitation)
7. Worker appears in roster, centre pane switches to it

Branch naming: `teammux/{task-slug}` where task-slug is the first 40 chars of the task description, lowercased, spaces replaced with hyphens, non-alphanumeric stripped.

---

## 9. Team Lead Skill — `/teammux-*` Commands

The Team Lead's CLAUDE.md (written by Teammux at workspace creation) includes a built-in skill. This skill gives the Team Lead the ability to manage the team by writing command files that the engine watches.

### How it works

When the Team Lead writes any `/teammux-*` command in its terminal, Claude Code executes a tool call that writes a structured JSON file to `.teammux/commands/{timestamp}.json`. The engine watches this directory via file system events (kqueue on macOS). On detecting a new file, the engine parses and executes the command. This preserves agent sovereignty — the Team Lead chose to write the command, Teammux doesn't intercept PTY output.

### Available commands in v0.1

```
/teammux-add "task description" [--agent claude-code] [--model claude-sonnet-4-6]
    Spawns a new worker with the given task.

/teammux-remove worker-id
    Dismisses a worker. Branch kept permanently.

/teammux-message worker-id "message"
    Sends a message to a specific worker via the message bus.

/teammux-broadcast "message"
    Sends a message to all active workers.

/teammux-status
    Requests a status update from all workers. Updates Live Feed.
```

### CLAUDE.md template written to Team Lead worktree

```markdown
# Teammux Team Lead

You are the Team Lead for this project. You coordinate a team of AI agents working in parallel.

## Your team
- Each worker runs in an isolated git worktree on its own branch
- Workers cannot see each other's changes until merged
- You review and approve merges to main

## Commands available to you
Use these commands to manage your team. They are executed by writing to the Teammux command bus.

/teammux-add "task description"     — spawn a new worker
/teammux-remove <worker-id>         — dismiss a worker
/teammux-message <worker-id> "msg"  — send instruction to specific worker
/teammux-broadcast "msg"            — send to all workers
/teammux-status                     — request status from all workers

## Review workflow
When a worker completes their task, they push their branch and open a GitHub PR.
You will see the PR in the Git tab. Review the diff, then approve or reject.
Approved PRs are squash-merged to main automatically.
```

---

## 10. Message Bus — Guaranteed Delivery Protocol

The Zig engine owns the communication channel between Team Lead and workers. Messages are ordered and guaranteed to deliver or the engine reports the failure.

### Message types

```
TASK        Team Lead → worker: assign or update a task
INSTRUCTION Team Lead → worker: inline instruction (not a task change)
STATUS_REQ  Team Lead → worker: request current status
STATUS_RPT  worker → Team Lead: status report (what I'm doing, what I've done)
COMPLETION  worker → Team Lead: task complete, PR ready for review
ERROR       worker → Team Lead: blocked, needs guidance
CONTEXT     Team Lead → worker: additional context/files to be aware of
```

### Delivery guarantee

The engine maintains a per-worker message queue. Each message has a sequence number. The engine retries delivery until the worker's PTY accepts the input or a timeout occurs (30s default). On timeout, the engine marks the message as failed and notifies the Live Feed.

### In v0.1 — minimum viable bus

Full bidirectional from day one. Team Lead sends `TASK`, `INSTRUCTION`, `CONTEXT`. Workers send `STATUS_RPT`, `COMPLETION`, `ERROR`. The Live Feed shows all messages in real time.

---

## 11. GitHub Integration

### Auth resolution (in priority order)

1. Detect `gh` CLI: run `gh auth status` — if success, read token from `~/.config/gh/hosts.yml`. Zero friction. Covers 80%+ of users.
2. OAuth flow: if `gh` not found, show "Connect GitHub" button in setup. Browser OAuth. Token stored in macOS Keychain under `com.teammux.app`.
3. PAT in config: `github_token = "ghp_..."` in `.teammux/config.local.toml`. Power user escape hatch.

GitHub connection is non-blocking — all Teammux features work without it. GitHub unlocks: PR creation, Diff View tab, PR status in Git tab, merge via Team Lead.

### GitHub operations in v0.1

**PR creation:** When a worker is dismissed or signals completion, Teammux offers "Open PR". Creates a PR from `teammux/{task-slug}` → `main` with title from task description and body from the message bus conversation log.

**Diff View:** GitHub Commits API + GitHub Compare API. Shows files changed, additions/deletions, syntax-highlighted diff. Refreshes on PR status change.

**PR status:** GitHub Events API polling (30s interval) or webhook if user configures one. Status shown in Git tab and roster status dot.

**Merge:** Team Lead approves in Git tab → Teammux calls GitHub Merge PR API with squash strategy → commit message: `[teammux] {task-slug}: {task-description}` → worktree removed locally.

---

## 12. Worktree Lifecycle

```
spawn       git worktree add .teammux/{slug} -b teammux/{slug}
            PTY spawned with cwd = .teammux/{slug}/
            CLAUDE.md written to worktree root
            Agent binary resolved via PATH
            Task injected into PTY stdin

active      Worker is running. Roster shows status dot.
            Message bus active for this worker.
            Developer can click into worker pane at any time.

complete    Worker signals completion (COMPLETION message or PR opened)
            Roster dot turns amber: "ready for review"
            Git tab shows PR status

merged      Team Lead approves in Git tab
            GitHub PR merged (squash)
            git worktree remove .teammux/{slug}
            Worker removed from roster
            Branch kept permanently on remote

dismissed   Developer clicks × on roster row
            Confirmation if branch has commits ahead of main
            git worktree remove .teammux/{slug}
            Worker removed from roster
            Branch kept permanently on remote (never auto-deleted)
```

---

## 13. Directory Structure — Inside a Project

```
my-project/
├── .git/                          ← shared object store
├── .teammux/                      ← Teammux artifacts (gitignored except config.toml)
│   ├── config.toml                ← committed — team composition
│   ├── config.local.toml          ← gitignored — machine-specific overrides
│   ├── commands/                  ← /teammux-* command files (watched by engine)
│   ├── worker-frontend/           ← worktree for Frontend worker
│   ├── worker-backend/            ← worktree for Backend worker
│   └── logs/                      ← message bus log (gitignored)
├── src/                           ← main branch (Team Lead works here)
└── ...
```

`.teammux/` gitignore entry (written automatically):
```gitignore
.teammux/worker-*/
.teammux/config.local.toml
.teammux/commands/
.teammux/logs/
```

`config.toml` and `TEAMS.md` are committed — team composition is part of the project.

---

## 14. Build System

```bash
# build.sh — unified build
#!/bin/bash
set -e

echo "[1/3] Building Zig engine..."
cd engine && zig build -Doptimize=ReleaseFast
cp zig-out/lib/libteammux.a ../macos/Resources/libteammux.a
cd ..

echo "[2/3] Building Ghostty + app..."
zig build

echo "[3/3] Done. App at: zig-out/bin/Teammux.app"
```

The Zig build system compiles both the Ghostty core and the `engine/` as part of a single `zig build` invocation. `libteammux.a` is linked into the Swift/Xcode target via the existing Ghostty Xcode project.

---

## 15. v0.1 Build Streams

Three parallel streams. Each gets this master spec + a focused implementation file.

### Stream 1 — Foundation (merges first)
- Fork Ghostty into `teammux-org/teammux-app`
- Rename app bundle: `Teammux` / `com.teammux.app`
- Suppress spurious Ghostty window (single window, Teammux layout only)
- Define `engine/include/teammux.h` — all function signatures, types, structs
- Confirm `zig build` produces `libteammux.a` that Swift can link
- Write `build.sh`
- Write `CLAUDE.md` (project context for future Claude Code sessions)
- Write `.gitignore`

### Stream 2 — Zig Engine (merges second)
- Implement all functions declared in `teammux.h`
- `worktree.zig` — full lifecycle (spawn, dismiss, cleanup)
- `pty.zig` — PTY ownership, stdin injection, stdout monitoring
- `bus.zig` — message queue, guaranteed delivery, sequence numbers
- `config.zig` — TOML parsing, hot-reload via kqueue
- `github.zig` — GitHub API client (auth, PR CRUD, diff fetch)
- `commands.zig` — `.teammux/commands/` directory watcher
- Full test coverage for all modules

### Stream 3 — Swift UI (merges third)
- Setup screens (Project picker, Team builder, Initiate)
- Project tab bar (Chrome-style, multi-project)
- Three-pane layout (roster, centre, right)
- Roster view (Team Lead pinned, workers scrollable, spawn popover)
- Worker pane switching (ZStack + opacity, PTY preserved)
- Right pane tabs (Team Lead terminal, Git, Diff, Live Feed)
- `EngineClient.swift` — Swift wrapper around `teammux.h` C calls
- `GitHubClient.swift` — Swift GitHub API client for SwiftUI views
- All views call into `EngineClient` — no direct Zig calls outside the bridge

---

## 16. What Is NOT in v0.1

These are explicitly deferred. Do not implement, do not stub, do not reference:

- Windows or Linux support
- Themes or visual customisation
- Keyboard shortcuts beyond system defaults
- Worker-to-worker direct messaging (all messages go Team Lead ↔ worker)
- Offline mode / local-only git (GitHub required for PR/merge workflow)
- Multiple Team Lead agents (Claude Code only in v0.1)
- Any form of cloud sync or remote agents
- Billing, licensing, or user accounts within the app

---

## 17. Competitive Differentiation

| Tool | What they have | What Teammux has that they don't |
|---|---|---|
| Conductor | Git worktrees, diff review, beautiful UI | Structural Team Lead role, message bus, GitHub-native merge |
| Superset | Worktrees, parallel agents, fast shipping | Native macOS quality (not Electron), structured coordination |
| BridgeSpace | 16 terminals, Tauri, role-based swarm | True git worktrees (not copy/sync), native terminal quality |
| Codex app | Parallel agents, built-in worktrees | Agent-agnostic, Team Lead as architectural constraint |
| Claude Code desktop | Single agent, visual diffs | Multi-agent, coordinated team, Team Lead |
| Warp | Block-based output, Oz cloud agents | Local-first, git-native isolation, Team Lead |

**The one thing nobody has:** A Team Lead that is structurally prevented from writing code, with a guaranteed-delivery message bus routing instructions to workers in git-isolated worktrees, on a native macOS terminal with Ghostty-quality rendering.

---

## 18. Resolved Decisions

1. **Hot-reload scope:** When `config.toml` changes, idle workers are affected immediately. Workers actively executing a task are affected on their next idle state. All new spawns always use the latest config.

2. **Branch naming:** Worker name (or role) is always the prefix. Format: `{worker-name}/teammux-{slug}` — e.g. `frontend/teammux-implement-auth`. Clean, scalable, immediately readable in `git branch -a`.

3. **Message log persistence:** The message bus log survives session restart. Persisted to `.teammux/logs/{date}-{session-id}.log` with timestamps, sender/receiver, message type, and git commit hashes at the time of each message. The Team Lead can retrieve any prior conversation on demand from the filesystem. Logs are gitignored but never auto-deleted.

4. **Agent context files:** The engine writes `CLAUDE.md` for Claude Code workers and `AGENTS.md` for all other agent types (Codex CLI, Gemini CLI, any other CLI). All major coding agent CLIs support `AGENTS.md`. Only Claude Code uses `CLAUDE.md`. The engine resolves which file to write based on the agent binary name in `config.toml`.

5. **GitHub real-time events:** `gh webhook forward` from day one. No polling. When a project session starts and GitHub auth is confirmed, the engine runs `gh webhook forward --repo=owner/repo --events=pull_request,push,check_run --url=http://localhost:{port}` and spins up a local HTTP server on a dynamic port to receive events. Events feed directly into the Live Feed tab and trigger real-time Git/Diff tab refreshes. Silent fallback to 60s polling if `gh webhook forward` fails (network issue, `gh` not installed) — user never notices the difference.

---

*Teammux — Architecture Specification · March 2026*  
*"Managing a SWE office from anywhere in the world on your laptop — the way you would in SF."*