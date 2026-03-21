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
cd engine && zig build test   # engine tests (baseline: 475)
```

Note: Zig 0.15.2 (nightly) in use. Build runner may crash
transiently — retry once before treating as a code issue.

## Key Documents

- engine/include/teammux.h              — C API contract (source of truth)
- docs/TECH_DEBT.md                     — all known tech debt with target versions
- docs/sprints/audit-address-002/AUDIT-ADDRESS-002-SPRINT.md — active sprint
- docs/codex-audits/audit-002-post-v016/ACTION-PLAN.md — audit findings

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
docs/sprints/                    — per-sprint master specs
docs/codex-audits/               — Codex audit specs, findings, action plans
docs/TECH_DEBT.md                — tech debt registry
src/                             — Ghostty upstream (DO NOT TOUCH)
```

## Right Pane Navigation

The right pane uses a vertical scrollable icon rail on the far
right edge of the screen. Current panes (top to bottom):

1. terminal — Team Lead (PTY surface, worker 0)
2. arrow.triangle.branch — Git (PR review, merge coordinator)
3. doc.text.magnifyingglass — Diff (GitHub PR files)
4. bubble.left.and.bubble.right — Live Feed (message bus events)
5. paperplane — Dispatch (task dispatch, autonomous feed)
6. doc.text — Context (CLAUDE.md viewer, agent memory timeline)
7. person.fill — You (user's own shell PTY session)

Cmd+1..7 keyboard shortcuts map to pane order above.

## Sprint Workflow

- Main thread: orchestrator only — no feature code
- All feature work happens in numbered stream worktrees
- Every stream raises a PR, main thread reviews, then merges
- Merge order defined in the active sprint master spec
- No stream merges without main thread approval

## Audit Workflow

- After each sprint: run Codex audit (AA1-AA7 parallel read-only
  streams) followed by Claude Code synthesis (AA8)
- Audit spec lives in docs/codex-audits/audit-00N-post-vX.X.X/
- Findings committed to same directory by Codex streams
- AA8 produces ACTION-PLAN.md
- Address sprint follows audit to resolve CRITICAL + IMPORTANT findings

## C API Conventions

- tm_* functions that return const char*: check header comment
  for lifetime (caller-must-free vs must-not-free)
- tm_engine_create: out parameter must not be NULL
- tm_config_get: returned pointer valid until next tm_config_get call
- TM_ERR_CLEANUP_INCOMPLETE (15): partial success — not a hard error
- TM_ERR_DELIVERY_FAILED (16): dispatch delivery failure
- TM_MSG_PTY_DIED (17): worker PTY process died
- TM_MSG_HEALTH_STALLED (18): worker stall detected
- Worker ID 0 is always Team Lead. Never in roster. Deny-all
  interceptor installed at session start.
- Dead exports: 15 exports annotated DEPRECATED in header.
  Do not add new callers. Removal target: v0.2.
- TM_ERR_PTY (6): RESERVED — no longer returned by any function.
- tm_version(): must return build-time version string from
  build.zig option. Do not hardcode.

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
- audit-address — shipped: 4 critical + 12 important audit-001
  findings resolved. Tag: audit-address-v014
- v0.1.5 — shipped: polish and stability. TD22(partial)/TD23/
  TD26/TD27/TD28/TD31/TD32/TD36/TD37 resolved, GitHub diff
  backend, updateRepo thread safety, OSS docs. 388 engine tests.
- v0.1.6 — shipped: depth and polish. All remaining TD items,
  all audit-001 findings, MergeCoordinator full conflict workflow,
  worker health monitoring, User terminal pane, agent memory,
  premium UI with vertical icon rail. 475 engine tests.
- audit-002 — shipped: 23 unique findings (6C/18I/1S) across
  7 domains. Tag: audit-002-post-v016.
  See docs/codex-audits/audit-002-post-v016/ACTION-PLAN.md
- audit-address-002 — in progress: 6-stream address sprint.
  See docs/sprints/audit-address-002/AUDIT-ADDRESS-002-SPRINT.md
