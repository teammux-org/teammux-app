# Audit-Address-002 Sprint — Post Audit-002

**Theme:** Address audit-002 findings
**Status:** In Progress
**Baseline:** v0.1.6 tag, 475 engine tests passing
**Source:** docs/codex-audits/audit-002-post-v016/ACTION-PLAN.md

## Objective

Resolve all 6 Critical and 18 Important findings from
audit-002-post-v016. Fix 3 identified regressions.
Address all 5 open design questions from the ACTION-PLAN.
Ship a stable, hardened codebase ready for v0.1.7.

## Finding Inventory

| ID  | Severity | Domain | Issue | Stream |
|-----|----------|--------|-------|--------|
| C1  | CRITICAL | Concurrency | cfg race: health monitor reads cfg during tm_config_reload | S1 |
| C2  | CRITICAL | Concurrency | Failed tm_session_start leaves live history writer thread | S1 |
| C3  | CRITICAL | C API | Unchecked @enumFromInt panics at C ABI boundary | S2 |
| C4  | CRITICAL | Swift | Restart button clears health without PTY respawn | S4 |
| C5  | CRITICAL | Integration | recoverOrphans deletes restore-session worktrees before restoreSession | S1 |
| C6  | CRITICAL | Existing | Failed conflict finalize disables git enforcement for active worker | S3 |
| I1  | IMPORTANT | Concurrency | PtyMonitor stale PID clobbers restarted workers | S4 |
| I2  | IMPORTANT | C API | tm_worker_pty_died and tm_worker_monitor_pid missing from header | S2 |
| I3  | IMPORTANT | C API | Conflict exports collapse git failures into TM_ERR_INVALID_WORKER | S2 |
| I4  | IMPORTANT | C API | tm_version() hardcoded to 0.1.0 | S2 |
| I5  | IMPORTANT | Swift | CLEANUP_INCOMPLETE warnings disappear on merge-state transition | S5 |
| I6  | IMPORTANT | Swift | Conflict/restart actions run synchronous on MainActor | S3 |
| I7  | IMPORTANT | Cross | Memory timeline corrupts on markdown headings in summaries | S6 |
| I8  | IMPORTANT | Engine | History rotation hides newest entry from reload | S6 |
| I9  | IMPORTANT | Engine | Relative worktree_root not normalized to absolute at config load | S6 |
| I10 | IMPORTANT | Engine | Branch-only cleanup failures not recoverable on restart | S6 |
| I11 | IMPORTANT | Bus | Callback-routed /teammux-* failures still deleted silently (I6 regression) | S5 |
| I12 | IMPORTANT | Cross | PTY death never sets health_status = .errored (health desync) | S4 |
| I13 | IMPORTANT | Bus | .teammux-error never cleared after failures | S5 |
| I14 | IMPORTANT | Integration | Worker dismiss strands conflicted merge state | S3 |
| I15 | IMPORTANT | Integration | Completion/question history dropped on bus delivery failure | S5 |
| I16 | IMPORTANT | Existing | finalizeMerge reintroduces raw Roster.getWorker() (roster regression) | S3 |
| S1  | SUGGESTION | Bus | PR delivery diagnostic overwritten with generic error | S5 |

## Regressions (must fix — prior work undermined)

| Finding | Regresses |
|---------|-----------|
| I11 | audit-001 I6 — silent command failures fix |
| I16 | v0.1.6 roster-locking hardening |
| I5  | v0.1.6 TD38 — cleanup warning visibility |

## Stream Registry

| Stream | Branch | Owns | Layer | Wave |
|--------|--------|------|-------|------|
| S1 | fix/aa2-s1-lifecycle | C1, C2, C5 | Engine | 1 |
| S2 | fix/aa2-s2-capi | C3, I2, I3, I4 | Engine + Header | 1 |
| S3 | fix/aa2-s3-merge | C6, I6, I14, I16 | Engine + Swift | 2 |
| S4 | fix/aa2-s4-health | C4, I1, I12 | Engine + Swift | 2 |
| S5 | fix/aa2-s5-errors | I5, I11, I13, I15, S1 | Engine + Swift | 2 |
| S6 | fix/aa2-s6-correctness | I7, I8, I9, I10 | Engine + Swift | 2 |

## Wave Structure

Wave 1 — S1, S2 (pure engine, parallel, no deps)
Wave 2 — S3, S4, S5, S6 (parallel, S3+S4 dep on S1, S5 dep on S3)
          S3 depends on S1 (roster safety must land first)
          S4 depends on S2 (PTY API header declarations needed)
          S5 depends on S3 (merge workflow changes for cleanup warnings)
          S6 has no upstream deps — can start immediately

## Merge Order

S1 → S2 → S3 → S4 → S5 → S6

---

## Stream Specifications

---

### S1 — Lifecycle & Concurrency Safety

**Branch:** fix/aa2-s1-lifecycle
**Owns:** C1, C2, C5
**Layer:** Engine only
**Files:** engine/src/main.zig, engine/src/history.zig,
           engine/src/worktree_lifecycle.zig

**C1 — cfg race: health monitor reads cfg concurrently**
File: engine/src/main.zig:511

The health monitor background thread reads `e.cfg` (stall
threshold, etc.) directly without synchronisation. Meanwhile
`tm_config_reload` can free and replace `e.cfg` on the main
thread. This is a use-after-free / torn-read race.

Fix: Snapshot the config values the health monitor needs
(stall_threshold_secs) into the monitor struct at start
and at each reload. The monitor never reads e.cfg directly —
it reads from its own snapshot. On reload: acquire monitor
mutex, update snapshot, release.

**C2 — Failed tm_session_start leaves live history writer**
File: engine/src/main.zig:350

On a failed `sessionStart()`, the history writer background
thread may have been started but not stopped. The engine
struct is left in a partial state. A retry attempt on the
same engine instance races the still-running writer.

Fix: Add an errdefer in sessionStart() that calls
`e.logger.shutdown()` if any step after `startWriter()`
fails. This ensures the writer is always stopped on any
failure path.

**C5 — recoverOrphans deletes restore-session worktrees**
File: engine/src/main.zig:299 + engine/src/worktree_lifecycle.zig

**Phase 1 brainstorm required before implementing.**
Read these files first and present analysis:
- engine/src/main.zig (sessionStart order: recoverOrphans
  vs restoreSession call sequence)
- engine/src/worktree_lifecycle.zig (recoverOrphans logic —
  how it determines what is an orphan)
- macos/Sources/Teammux/Setup/SessionState.swift
  (what session state is persisted and when it is read)

Brainstorm questions:
1. At the point recoverOrphans runs, is the persisted session
   state file already readable on disk?
2. Can recoverOrphans be moved to run after restoreSession
   without breaking the orphan detection logic?
3. If session restore is running, which worktrees are
   legitimate vs truly orphaned? Is there a saved worker
   list in the session file that can be consulted?

Likely fix: defer recoverOrphans call until after
restoreSession() completes, or pass the restored worker
ID list into recoverOrphans as an exclusion set.

**Commit sequence:**
Commit 1: engine/src/main.zig — C2 errdefer on failed sessionStart
Commit 2: engine/src/main.zig — C1 cfg snapshot in health monitor
Commit 3: C5 fix (approach confirmed in brainstorm)

After each: cd engine && zig build && zig build test

**Definition of done:**
- Health monitor never reads e.cfg directly
- Failed sessionStart always stops history writer
- recoverOrphans does not delete legitimate restore worktrees
- Engine tests pass

---

### S2 — C API Boundary Hardening

**Branch:** fix/aa2-s2-capi
**Owns:** C3, I2, I3, I4
**Layer:** Engine + Header
**Files:** engine/src/main.zig, engine/include/teammux.h,
           engine/build.zig

**C3 — Unchecked @enumFromInt panics at C ABI boundary**
File: engine/src/main.zig:1008

`@enumFromInt(value)` on tm_message_type_t and
tm_merge_strategy_t at C entry points panics on invalid
values instead of returning TM_ERR_INVALID_ARG.

Fix: Replace `@enumFromInt(x)` with `std.meta.intToEnum(T, x)`
which returns an error on invalid values. On error: call
setError and return TM_ERR_INVALID_ARG. Apply to all C
entry points that accept enum parameters.

**I2 — PTY death APIs missing from header**
File: engine/include/teammux.h

`tm_worker_pty_died` and `tm_worker_monitor_pid` are
implemented in main.zig and called from Swift but not
declared in teammux.h (the source of truth).

Fix: Add declarations for both functions with correct
parameter types and comments documenting their purpose
and caller contract.

**I3 — Conflict exports collapse git failures into TM_ERR_INVALID_WORKER**
File: engine/src/main.zig:2177

`tm_conflict_resolve` and `tm_conflict_finalize` return
TM_ERR_INVALID_WORKER when the underlying git checkout/
commit fails. Swift gets a roster error instead of a git
error, hiding the real failure.

Fix: Add TM_ERR_GIT_FAILURE = 19 to tm_result_t. Return
TM_ERR_GIT_FAILURE (with setError containing git stderr)
when git operations fail inside conflict resolution.
Declare in header.

**I4 — tm_version() hardcoded to "0.1.0"**
File: engine/src/main.zig:2950 + engine/build.zig

Fix: Add a version option to build.zig:
  const version = b.option([]const u8, "version",
    "Teammux version string") orelse "dev";
Pass it as a build-time string via options module.
tm_version() returns the build-time string. Update
build.sh to pass -Dversion=0.1.6 (current). Update
any test that asserts the version string.

**Commit sequence:**
Commit 1: main.zig — C3 safe enum conversion at all C entry points
Commit 2: teammux.h — I2 PTY API declarations, I4 TM_ERR_GIT_FAILURE
Commit 3: build.zig + main.zig — I4 build-time version option
Commit 4: main.zig — I3 TM_ERR_GIT_FAILURE in conflict exports

After each: cd engine && zig build && zig build test

**Definition of done:**
- Invalid enum values at C boundary return TM_ERR_INVALID_ARG
- tm_worker_pty_died and tm_worker_monitor_pid declared in header
- TM_ERR_GIT_FAILURE = 19 declared and returned on git failures
- tm_version() returns build-time version string
- Engine tests pass

---

### S3 — Merge & Conflict Workflow

**Branch:** fix/aa2-s3-merge
**Owns:** C6, I6, I14, I16
**Layer:** Engine + Swift
**Depends on:** S1 (roster safety)
**Files:** engine/src/merge.zig, engine/src/main.zig,
           engine/include/teammux.h,
           macos/Sources/Teammux/Engine/EngineClient.swift,
           macos/Sources/Teammux/RightPane/GitView.swift

**C6 — Failed finalize disables git enforcement**
File: engine/src/main.zig:2207

`tm_conflict_finalize` removes the interceptor and role
watcher before the git commit succeeds. A failed commit
leaves an active worker with no git enforcement.

Fix: Move interceptor removal and role watcher teardown
to AFTER git commit succeeds. On failure: leave interceptor
and watcher in place, return TM_ERR_GIT_FAILURE.

**I16 — finalizeMerge reintroduces raw Roster.getWorker()**
File: engine/src/merge.zig:412 (REGRESSION — regresses v0.1.6 S1)

finalizeMerge() calls roster.getWorker() and mutates
through the raw pointer — the exact pattern S1 was meant
to eliminate.

Fix: Migrate to copyWorkerFields / setWorkerStatus
pattern established in v0.1.6 S1. Same pattern as
all other production callers in merge.zig.

**I14 — Worker dismiss strands conflicted merge state**
File: engine/src/main.zig:806

tm_worker_dismiss() does not check if the worker is in
an active conflict state. Dismissing a conflicted worker
leaves MergeCoordinator with a dangling active_merge entry
and no way to clean it up without manual git intervention.

Fix: In tm_worker_dismiss, check if worker has active
conflict state (active_merge set). If so: call
merge.reject() first to abort the git merge and clean
up resolution state, then proceed with dismiss.

**I6 — Conflict/restart actions run synchronous on MainActor**
File: macos/Sources/Teammux/RightPane/ConflictView.swift:145

tm_conflict_resolve and tm_conflict_finalize are called
directly on MainActor, blocking UI during git operations.

Fix: Wrap all conflict resolution and finalize calls in
Task.detached { } — same pattern as DiffView.loadDiff
after v0.1.5 S7. Dispatch results back to MainActor
via await MainActor.run { }.

**Commit sequence:**
Commit 1: merge.zig — I16 copyWorkerFields in finalizeMerge
Commit 2: main.zig — C6 move teardown to success path only
Commit 3: main.zig — I14 merge-aware dismiss
Commit 4: ConflictView.swift — I6 Task.detached for FFI calls

After Commits 1-3: cd engine && zig build && zig build test
After Commit 4: ./build.sh

**Definition of done:**
- finalizeMerge uses copyWorkerFields (no raw pointer)
- Failed finalize leaves interceptor and role watcher active
- Dismissing a conflicted worker aborts merge cleanly
- Conflict resolution calls run off MainActor
- Engine tests pass, ./build.sh passes

---

### S4 — Worker Health & PTY Recovery

**Branch:** fix/aa2-s4-health
**Owns:** C4, I1, I12
**Layer:** Engine + Swift
**Depends on:** S2 (PTY API header declarations)
**Files:** engine/src/coordinator.zig, engine/src/main.zig,
           macos/Sources/Teammux/Engine/EngineClient.swift,
           macos/Sources/Teammux/Workspace/WorkerDetailDrawer.swift,
           macos/Sources/Teammux/Workspace/ (PTY surface lifecycle)

**C4 — Restart button clears health without PTY respawn**
File: macos/Sources/Teammux/Workspace/WorkerDetailDrawer.swift:132

The "Restart Worker" button calls engine.restartWorker(id:)
which only resets health state. No PTY teardown or respawn
occurs. Dead worker appears healthy with no terminal.

Fix (Swift side — Option C confirmed):
1. In WorkerDetailDrawer restart action:
   a. Call the existing dismissWorker surface teardown path
      (stop/remove the SurfaceView) but WITHOUT removing
      the worktree or registry entries
   b. Spawn a new SurfaceView PTY in the same worktree path
      (same pattern as initial worker spawn in WorkspaceView)
   c. Re-register PATH injector for the new PTY
   d. Call engine.restartWorker(id:) last to reset engine state

**Phase 1 brainstorm required before implementing.**
Read these files first and present analysis:
- macos/Sources/Teammux/Workspace/WorkerDetailDrawer.swift
  (current restart button action)
- macos/Sources/Teammux/Workspace/WorkspaceView.swift or
  equivalent (how PTY surfaces are spawned for workers)
- macos/Sources/Teammux/App/AppDelegate.swift (Ghostty
  surface lifecycle — how surfaces are created/destroyed)
- macos/Sources/Teammux/Engine/EngineClient.swift
  (restartWorker, spawnWorker, dismissWorker paths)

**I1 — PtyMonitor stale PID clobbers restarted workers**
File: engine/src/main.zig:55

When a worker is restarted, the old PID may still be
registered in PtyMonitor. A late death notification for
the old PID calls ptyDiedCallback again, re-erroring the
now-healthy restarted worker.

Fix: In tm_worker_restart: call pty_monitor.unwatch(worker_id)
before resetting health state. This removes any stale PID
registration. The new PTY will register its PID via
tm_worker_monitor_pid after spawn.

**I12 — PTY death never sets health_status = .errored**
File: engine/src/coordinator.zig:158 (CROSS-STREAM with AA5)

ptyDiedCallback sets worker status = .err but never sets
health_status = .errored. Health monitor may then fire
TM_MSG_HEALTH_STALLED for a dead worker — wrong event type.
Restart path doesn't reconcile both fields.

Fix:
- In ptyDiedCallback: set both status = .err AND
  health_status = .errored atomically under roster mutex
- In tm_worker_restart: reset both status = .active AND
  health_status = .healthy atomically
- In checkWorkerHealth: skip workers with status = .err
  (they are dead, not stalled)

**Commit sequence:**
Commit 1: coordinator.zig + main.zig — I12 health_status sync,
           I1 unwatch on restart
Commit 2: WorkerDetailDrawer.swift — C4 full PTY respawn
           (approach confirmed in brainstorm)

After Commit 1: cd engine && zig build && zig build test
After Commit 2: ./build.sh

**Definition of done:**
- Restart button tears down old PTY surface and spawns new one
- ptyDiedCallback sets health_status = .errored
- checkWorkerHealth skips .err workers
- tm_worker_restart clears stale PID from PtyMonitor
- tm_worker_restart resets both status and health_status
- Engine tests pass, ./build.sh passes

---

### S5 — Error Surface & Command Reliability

**Branch:** fix/aa2-s5-errors
**Owns:** I5, I11, I13, I15, S1
**Layer:** Engine + Swift
**Depends on:** S3 (merge workflow for cleanup warning fix)
**Files:** engine/src/commands.zig, engine/src/main.zig,
           engine/src/history.zig,
           macos/Sources/Teammux/Engine/EngineClient.swift,
           macos/Sources/Teammux/RightPane/GitView.swift

**I11 — Callback-routed /teammux-* failures still silent**
File: engine/src/commands.zig:249 (REGRESSION — re-opens I6)

Internal command handler failures (e.g. bus routing fails
inside the callback) delete the source command file without
writing .teammux-error. The fix in S4 (I6 address sprint)
only covered the CommandWatcher outer layer.

Fix: Change the internal command callback contract to
return a bool (success/failure). On failure: write
.teammux-error before returning. CommandWatcher checks
the return value and calls notifyError.

**I13 — .teammux-error never cleared after failures**
File: engine/src/commands.zig:99

.teammux-error files accumulate on disk indefinitely.
They bleed into later sessions if the worker picks up
a stale error.

Fix:
- At sessionStart: scan worker commands dirs and delete
  any stale .teammux-error files from previous sessions
- On successful command processing: delete .teammux-error
  if it exists in the same worker dir

**I15 — Completion/question history dropped on bus failure**
File: engine/src/main.zig:403

History persistence (completion_history.jsonl) is gated
on bus delivery success. Transient bus failures suppress
audit and restore records permanently.

Fix: Decouple history write from delivery result. Write
to history BEFORE attempting bus delivery. If delivery
fails, history entry still exists. Only suppress duplicate
writes (not all writes on failure).

**I5 — CLEANUP_INCOMPLETE warnings disappear on transition**
File: macos/Sources/Teammux/RightPane/GitView.swift:245
(REGRESSION — undermines v0.1.6 TD38 fix)

cleanupWarning is stored in @State on GitWorkerRow and
PRCardView — views that are recreated when merge state
changes. The warning disappears before the user reads it.

Fix: Move cleanupWarning storage up to the parent
GitView @StateObject or to EngineClient's published state.
Warning persists across view recreation until explicitly
dismissed by the user.

**S1 (Suggestion) — PR delivery diagnostic overwritten**
File: engine/src/main.zig:403

busSendBridge() overwrites the specific error_notify_cb
message with a generic string, losing worker/message context.

Fix: Pass the original error message from error_notify_cb
through to setError instead of generating a new generic one.
Low priority — fix only if scope allows.

**Commit sequence:**
Commit 1: commands.zig — I11 callback contract returns bool,
           I13 stale error cleanup on sessionStart and success
Commit 2: main.zig — I15 decouple history write from delivery
Commit 3: GitView.swift — I5 hoist cleanupWarning to stable state
Commit 4: main.zig — S1 preserve specific error message (optional)

After Commits 1-2: cd engine && zig build && zig build test
After Commit 3: ./build.sh

**Definition of done:**
- Internal command failures write .teammux-error
- Stale .teammux-error files cleared on sessionStart
- History written before delivery attempt
- cleanupWarning persists across view recreation
- Engine tests pass, ./build.sh passes

---

### S6 — Engine Correctness

**Branch:** fix/aa2-s6-correctness
**Owns:** I7, I8, I9, I10
**Layer:** Engine + Swift
**No upstream deps — can start immediately**
**Files:** engine/src/memory.zig, engine/src/history.zig,
           engine/src/worktree_lifecycle.zig,
           engine/src/main.zig,
           macos/Sources/Teammux/RightPane/ContextView.swift

**I7 — Memory timeline corrupts on markdown headings**
File: engine/src/memory.zig:38 + ContextView.swift:461
(CROSS-STREAM — flagged by AA3 and AA4)

**Phase 1 brainstorm required before implementing.**
Read these files and present analysis:
- engine/src/memory.zig (how entries are appended — format)
- macos/Sources/Teammux/RightPane/ContextView.swift
  (parseMemoryEntries — how entries are parsed)

Brainstorm question: The entry format uses `## {timestamp}`
as the delimiter. If a summary contains `## heading`, the
parser splits it into a fake entry. Two fix approaches:
(A) Minimal — escape `##` in summary body at write time
    in memory.zig (prepend a zero-width space or use
    HTML entity). Swift parser unchanged. Preserves
    existing memory files.
(B) Structural — switch to JSONL format for memory entries.
    Each line: {"ts":"...","summary":"..."}. Swift
    parser updated. Breaks existing memory files.

Confirmed direction: Minimal fix (A) — escape `##` in
summary body. Do not switch to JSONL.

**I8 — History rotation hides newest entry from reload**
File: engine/src/history.zig:159

Size check triggers after the append is written. The newly
written entry is in the file that gets renamed to .1.
`load()` only reads the active .jsonl file, so the newest
entry is invisible after the rotation.

Fix: Check size BEFORE writing the new entry. If rotation
is needed, rotate first (rename .jsonl → .1), then write
the new entry to the fresh .jsonl. Newest entry always
lands in the active file.

**I9 — Relative worktree_root not normalized**
File: engine/src/worktree_lifecycle.zig:106

Relative worktree_root paths from config.toml are used
as-is. Different call sites resolve them relative to
different cwd values, producing inconsistent paths.

Fix: At config load time in main.zig (when config.toml
is parsed), normalize worktree_root to an absolute path
relative to the project root. Use
`std.fs.path.resolve(allocator, &.{project_path, worktree_root})`
All downstream callers then receive an absolute path.

**I10 — Branch-only cleanup failures not recoverable**
File: engine/src/worktree_lifecycle.zig:232

When worktree directory removal succeeds but `git branch -D`
fails, the stale branch accumulates. recoverOrphans only
scans for orphaned worktree directories — it does not scan
for orphaned branches.

Fix: Add a separate orphaned branch cleanup pass in
recoverOrphans: run `git branch --list 'teammux/*'` and
for each branch, check if a corresponding worktree
directory exists in the worktree root. If no directory
exists and the branch is not on the active roster,
delete the branch.

**Commit sequence:**
Commit 1: history.zig — I8 rotate before write not after
Commit 2: main.zig — I9 normalize worktree_root at config load
Commit 3: memory.zig — I7 escape ## in summary body
Commit 4: ContextView.swift — I7 parser robustness (if needed)
Commit 5: worktree_lifecycle.zig — I10 orphaned branch cleanup

After Commits 1-3: cd engine && zig build && zig build test
After Commit 4: ./build.sh

**Definition of done:**
- History rotation happens before write — newest entry
  always in active file
- worktree_root normalized to absolute at config load
- Memory summaries with ## headings render correctly
- Orphaned branches cleaned up on recoverOrphans
- Engine tests pass, ./build.sh passes

---

## Merge Order

S1 → S2 → S3 → S4 → S5 → S6

Rationale:
- S1 first: lifecycle and concurrency fundamentals —
  roster safety, session start/stop correctness
- S2 second: C API hardening — header declarations
  needed by S4 for PTY API
- S3 third: merge workflow — roster safety from S1 needed;
  S5 cleanup warning fix depends on S3 state changes
- S4 third (parallel with S3): PTY respawn — header from S2
- S5 fourth: error surfaces — merge workflow from S3 needed
- S6 last: correctness fixes — no downstream dependencies

## PR Review Standards

All PRs follow established review standards:
- Branch based on current main
- Only correct files modified
- No force-unwraps in production Swift
- No tm_* calls outside EngineClient.swift
- Engine builds cleanly
- All engine tests pass (report count)
- ./build.sh passes for Swift streams
- Conflict check with main
- No src/ modifications

## References

- docs/codex-audits/audit-002-post-v016/ACTION-PLAN.md
- docs/codex-audits/audit-002-post-v016/ (all FINDINGS files)
- engine/include/teammux.h — C API source of truth
- docs/TECH_DEBT.md — debt registry
