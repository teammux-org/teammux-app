# Teammux

Native macOS ADE (AI Development Environment) for coordinating
teams of AI coding agents. A fork of Ghostty 1.3.0 extended with
a multi-agent coordination engine.

## Stack

- Swift + SwiftUI + AppKit — UI layer (macos/)
- Zig — coordination engine (engine/) → libteammux.a
- Ghostty fork — terminal rendering (src/ — DO NOT MODIFY)
- C API boundary — engine/include/teammux.h
- Bundle: com.teammux.app
- macOS 15 Sequoia, Apple Silicon only

## Architecture Rules

- engine/ contains all coordination logic. Swift calls it via
  teammux.h only.
- src/ is Ghostty upstream. NEVER modify files in src/.
- macos/Sources/Teammux/ is the Teammux Swift layer.
- All Swift → Zig calls go through EngineClient.swift ONLY.
  No direct tm_* calls outside EngineClient.swift.
- No raw POSIX PTY shortcuts — Ghostty native PTY infrastructure only.
- Engine memory: manual Zig allocator discipline, owned strings
  duped on store, errdefer on partial allocations.

## Build

```bash
./build.sh                    # full build (engine + Swift + Ghostty)
cd engine && zig build        # engine only
cd engine && zig build test   # engine tests (baseline: see version history)
```

Note: Zig 0.15.2 (nightly) in use. Build runner may crash
transiently — retry once before treating as a code issue.

## Key Documents

- engine/include/teammux.h              — C API contract (source of truth)
- docs/TECH_DEBT.md                     — all known tech debt with target versions
- docs/sprints/v0.1.6/V016_SPRINT.md   — current sprint master spec
- docs/codex-audits/audit-001-post-v014/ACTION-PLAN.md — audit findings

## Directory Structure

```
engine/src/          — Zig coordination engine
engine/include/      — C API header (teammux.h)
macos/Sources/Teammux/Engine/    — EngineClient.swift (sole tm_* caller)
macos/Sources/Teammux/Models/    — CoordinationTypes, TeamMessage
macos/Sources/Teammux/RightPane/ — Right pane views (vertical icon rail nav)
macos/Sources/Teammux/Workspace/ — RosterView, WorkerDetailDrawer, WorkerRow
macos/Sources/Teammux/Setup/     — SetupView, SessionState
macos/Sources/Teammux/App/       — AppDelegate
docs/sprints/                    — per-sprint master specs and stream task files
docs/codex-audits/               — Codex audit reports and action plans
src/                             — Ghostty upstream (DO NOT TOUCH)
```

## Right Pane Navigation

The right pane uses a vertical scrollable icon rail on the far
right edge of the screen. Each icon selects a pane view. Icons
are stacked vertically, scrollable, with tooltip on hover and
active state highlight. Current panes:

1. Team Lead terminal (PTY surface — worker 0)
2. Git (PR review, branch list, merge coordinator)
3. Diff (GitHub PR files diff)
4. Live Feed (message bus events, completion history)
5. Dispatch (task dispatch, autonomous dispatch feed)
6. Context (CLAUDE.md viewer, hot-reload diff)
7. You (user's own Claude Code PTY session)

## Sprint Workflow

- Main thread: orchestrator only — no feature code
- All feature work happens in numbered stream worktrees
- Every stream raises a PR, main thread reviews, then merges
- Merge order defined in the active sprint master spec
- No stream merges without main thread approval
- Stream task files live in docs/sprints/{version}/

## C API Conventions

- tm_* functions that return const char*: check header comment
  for lifetime (caller-must-free vs must-not-free)
- tm_engine_create: out parameter must not be NULL
- tm_config_get: returned pointer valid until next tm_config_get call
- TM_ERR_CLEANUP_INCOMPLETE (15): partial success — merge/reject
  succeeded, worktree/branch cleanup failed. Not a hard error.
- Worker ID 0 is always Team Lead. Never in roster. Deny-all
  interceptor installed at session start.
- Dead exports in header: see TD29 — 15 exports annotated as
  deprecated candidates. Do not add new callers.

## Version History

- v0.1.0 — shipped: Ghostty fork, Zig engine, Swift UI, git
  worktrees, message bus, setup flow, workspace
- v0.1.1 — shipped: MergeCoordinator, Team Lead review workflow,
  GitHub integration, conflict surfacing
- v0.1.2 — shipped: interceptor hardening, role system, hot-reload
- v0.1.3 — shipped: coordination loop, completion signaling,
  hot-reload registry sync, dispatch UI
- v0.1.4 — shipped: git worktree isolation, peer messaging (TD15),
  JSONL history (TD16), interceptor hardening (TD17/TD19),
  hot-reload registry sync (TD18), lastError fix (TD20),
  PR workflow engine, session persistence, context viewer,
  autonomous dispatch, worker drawer. 356 engine tests.
- audit-address — shipped: 4 critical + 12 important audit findings
  resolved. Lifetime safety, concurrency, Team Lead structural
  enforcement, C API contracts, performance hot path, dead code.
  Tag: audit-address-v014
- v0.1.5 — shipped: polish and stability sprint.
  TD22(partial)/TD23/TD26/TD27/TD28/TD31/TD32/TD36/TD37
  resolved, diff tab backend via GitHub PR files API,
  updateRepo thread safety (repo_mutex), PRStatus color
  unification, LCS diff highlighting, markdown rendering,
  hot-reload repeat detection, OSS docs. 388 engine tests.
- v0.1.6 — in progress: depth and polish sprint.
  All remaining TD items (TD21/TD24/TD29/TD30/TD33/TD34/TD35/
  TD38/TD40/TD41/TD42/TD43/TD44), all remaining audit-001
  findings (I6/I7/I8/I11/I13/I15), MergeCoordinator full
  workflow, worker health monitoring, User terminal pane,
  agent memory, premium UI/UX with vertical icon rail.
