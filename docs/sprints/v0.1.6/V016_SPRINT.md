# Teammux v0.1.6 — Sprint Master Spec

**Theme:** Depth & Polish
**Status:** Complete
**Baseline:** v0.1.5 tag, 388 engine tests passing
**Final:** v0.1.6 tag, 475 engine tests passing

## Objective

Complete all remaining deferred tech debt (TD21/TD24/TD29/TD30/
TD33/TD34/TD35/TD38/TD40/TD41/TD42/TD43/TD44), resolve all
remaining audit-001 findings (I6/I7/I8/I11/I13/I15), and ship
four new capabilities: MergeCoordinator full conflict workflow,
worker health monitoring, User terminal pane (7th right pane),
and agent memory. Deliver a premium macOS UI with a vertical
scrollable icon rail replacing the tab bar. This sprint
targets the first usable manual session milestone.

## TD Items Resolved This Sprint

| ID   | Module                      | Issue                                              |
|------|-----------------------------|----------------------------------------------------|
| TD21 | worktree_lifecycle.zig      | Dangling worktrees on crash — startup recovery     |
| TD24 | history.zig                 | JSONL log unbounded growth — rotation              |
| TD29 | teammux.h                   | 15 dead exports — deprecation annotations          |
| TD30 | teammux.h                   | TM_ERR_PTY stale — mark reserved                  |
| TD33 | merge.zig / coordinator.zig | getWorker raw pointer without lock                 |
| TD34 | main.zig                    | tm_roster_get iterates without mutex               |
| TD35 | worktree.zig                | claimNextId leaks ID slot on failure               |
| TD38 | GitView / ConflictView      | CLEANUP_INCOMPLETE warning never shown in UI       |
| TD40 | github.zig                  | getDiff no pagination, 1 MiB cap                   |
| TD41 | DiffView.swift              | loadDiff blocks main thread                        |
| TD42 | ContextView.swift           | LCS changedLineIndices has no unit tests           |
| TD43 | hotreload.zig               | reload_count never asserted in tests               |
| TD44 | ContextView.swift           | LCS DP table O(m*n) — two-row optimization         |

## Audit-001 Findings Resolved This Sprint

| ID  | Issue                                              |
|-----|----------------------------------------------------|
| I6  | Silent command failures (/teammux-assign etc.)     |
| I7  | Dispatch swallows delivery failures                |
| I8  | PTY death has no cleanup/state-reconciliation path |
| I11 | Worktree cleanup drops registry before git removal |
| I13 | PR_READY/PR_STATUS delivery failures — no retry    |
| I15 | O(n) history append stays on delivery path         |

## New Capabilities

- MergeCoordinator full workflow — conflict surfacing as
  deliberate Team Lead decision point (not runtime crash)
- Worker health monitoring — stall detection, health status
  in roster, restart action in worker drawer
- User terminal pane — 7th right pane PTY: user's own Claude
  Code session, message bus wired bi-directionally
- Agent memory — per-worker context summaries persisted in
  worktree across task boundaries, surfaced in Context tab
- Premium UI/UX — vertical scrollable icon rail replaces tab
  bar, Codex app aesthetic reference, native macOS design
  language throughout

---

## Stream Registry

| Stream | Branch | Owns | Layer | Wave |
|--------|--------|------|-------|------|
| S1  | fix/v016-s1-roster-safety         | TD33/TD34/TD35                        | Engine       | 1 |
| S2  | fix/v016-s2-crash-recovery        | TD21/I11                              | Engine       | 1 |
| S3  | fix/v016-s3-history-integrity     | TD24/I15                              | Engine       | 1 |
| S4  | fix/v016-s4-bus-reliability       | I6/I7/I13                             | Engine       | 1 |
| S5  | fix/v016-s5-pty-death             | I8                                    | Engine       | 1 |
| S6  | fix/v016-s6-capi-cleanup          | TD29/TD30                             | Engine       | 1 |
| S7  | fix/v016-s7-diff-reliability      | TD40/TD41                             | Engine+Swift | 2 |
| S8  | fix/v016-s8-cleanup-ui            | TD38                                  | Swift        | 2 |
| S9  | fix/v016-s9-test-coverage         | TD42/TD43/TD44                        | Engine+Swift | 2 |
| S10 | fix/v016-s10-merge-coordinator    | MergeCoordinator full workflow        | Engine+Swift | 2 |
| S11 | fix/v016-s11-worker-health        | Worker health monitoring              | Engine+Swift | 2 |
| S12 | fix/v016-s12-user-terminal        | User terminal pane (7th pane)         | Swift        | 3 |
| S13 | fix/v016-s13-agent-memory         | Agent memory                          | Engine+Swift | 3 |
| S14 | fix/v016-s14-ui-polish            | Premium UI/UX + vertical icon rail    | Swift        | 3 |
| S15 | fix/v016-s15-integration          | Integration tests + v0.1.6 ship       | Engine+Docs  | 4 |

## Wave Structure

Wave 1 — S1, S2, S3, S4, S5, S6 (pure engine, all parallel)
Wave 2 — S7, S8, S9, S10, S11 (all parallel, no Wave 1 deps
          except S7 has thin dep on S3 for history async path)
Wave 3 — S12, S13, S14 (all parallel)
          S12 has dep on S14 for icon rail (can start, cannot
          merge until S14 icon rail Swift changes land)
Wave 4 — S15 (waits for all 14 streams merged)

## Merge Order

S1 → S2 → S3 → S4 → S5 → S6 → S7 → S8 → S9 → S10 →
S11 → S12 → S13 → S14 → S15

---

## Stream Specifications

---

### S1 — Roster Safety

**Branch:** fix/v016-s1-roster-safety
**Owns:** TD33, TD34, TD35
**Layer:** Engine only
**Files:** engine/src/merge.zig, engine/src/coordinator.zig,
           engine/src/main.zig, engine/src/worktree.zig

**TD33 — getWorker raw pointer without lock**
merge.zig approve/reject (lines 84, 143, 219) and
coordinator.zig dispatchTask (line 87) call
roster.getWorker() without lock protection. Line 143 is a
write through the raw pointer (status mutation).

Fix: Migrate all production callers in merge.zig and
coordinator.zig to copyWorkerFields/hasWorker pattern
established by AA2. No test-only callers need migration.

**TD34 — tm_roster_get iterates without mutex**
tm_roster_get iterates e.roster.workers via .iterator()
and passes entry.value_ptr to fillCWorkerInfo without
holding the roster mutex.

Fix: Acquire roster mutex before iteration. Either hold for
full iteration or copy workers via copyWorkerFields first,
then release and fill CWorkerInfo from copies.

**TD35 — claimNextId leaks ID slot on spawn failure**
Roster.claimNextId() permanently increments next_id.
If worktree_lifecycle.create or roster.spawn fails
afterward, the ID slot is consumed with no worker registered.

Fix: Add unclaimId(id: u32) method to Roster. Call it in
the error path of tm_worker_spawn after claimNextId but
before successful spawn completes.

**Commit sequence:**
Commit 1: merge.zig + coordinator.zig — TD33 copyWorkerFields
Commit 2: main.zig — TD34 roster mutex on tm_roster_get
Commit 3: worktree.zig + main.zig — TD35 unclaimId

After each: cd engine && zig build && zig build test

**Definition of done:**
- No production getWorker() calls without lock in merge/coordinator
- tm_roster_get holds mutex during iteration
- unclaimId called on all spawn failure paths
- Engine tests pass, count reported

---

### S2 — Crash Recovery

**Branch:** fix/v016-s2-crash-recovery
**Owns:** TD21, I11
**Layer:** Engine only
**Files:** engine/src/worktree_lifecycle.zig,
           engine/src/main.zig

**TD21 — Dangling worktrees on engine crash**
On engine crash mid-spawn, .teammux/worker-{id}/ directory
and branch teammux/worker-{id} may be left on disk with no
corresponding roster entry.

Fix: At engine init (tm_engine_create or sessionStart),
scan .teammux/ for worktree directories. For each found,
check if a roster entry exists. If not — orphan detected.
Run: git worktree remove --force .teammux/worker-{id}
and: git branch -D teammux/worker-{id}
Log each cleanup. Surface count via setError if > 0.

**I11 — Worktree cleanup drops registry entry before git removal**
In the current cleanup path, FileOwnershipRegistry entry
is dropped before git worktree remove succeeds. If git
removal fails, the registry is already gone — orphaned
worktree with no ownership tracking.

Fix: Reorder cleanup sequence:
1. git worktree remove (attempt)
2. git branch -D (attempt)
3. ONLY THEN drop FileOwnershipRegistry entry
4. Log any git failures with stderr (use runGitLoggedWithStderr)

**Commit sequence:**
Commit 1: worktree_lifecycle.zig — I11 reorder cleanup sequence
Commit 2: main.zig — TD21 startup recovery sweep

After each: cd engine && zig build && zig build test

**Definition of done:**
- Cleanup sequence is atomic: git first, registry after
- Startup scan removes orphaned worktrees and branches
- Orphan count surfaced via setError for Swift notification
- Engine tests pass

---

### S3 — History Integrity

**Branch:** fix/v016-s3-history-integrity
**Owns:** TD24, I15
**Layer:** Engine only
**Files:** engine/src/history.zig, engine/src/main.zig

**TD24 — JSONL log unbounded growth**
completion_history.jsonl is append-only and grows across
all sessions with no rotation.

Fix:
- Add max_size_bytes config (default 1 MiB) to history.zig
- On every append: check file size. If > max_size_bytes,
  rotate: rename to completion_history.jsonl.1, start fresh
- Keep at most 2 archive files (.1, .2) — discard older
- Add tm_history_rotate C export for manual trigger

**I15 — O(n) history append on delivery path**
History append currently happens synchronously on the
message delivery path. As history grows, each delivery
incurs O(n) file seek overhead.

Fix: Move history writes to an async write queue.
- Add a write queue (ring buffer or channel) in history.zig
- Delivery path enqueues the entry (non-blocking)
- Background Zig thread drains queue to disk
- Queue overflow: drop oldest entry, log warn
- Shutdown: flush queue before closing

**Commit sequence:**
Commit 1: history.zig — TD24 rotation logic
Commit 2: history.zig — I15 async write queue + background thread
Commit 3: main.zig — wire tm_history_rotate export

After each: cd engine && zig build && zig build test

**Definition of done:**
- JSONL log rotates at configurable max size (default 1 MiB)
- History writes are async, not on delivery path
- Rotation preserves at most 2 archive files
- Engine tests pass including queue drain on shutdown

---

### S4 — Message Bus Reliability

**Branch:** fix/v016-s4-bus-reliability
**Owns:** I6, I7, I13
**Layer:** Engine only
**Files:** engine/src/commands.zig, engine/src/coordinator.zig,
           engine/src/bus.zig, engine/src/main.zig

**I6 — Silent command failures**
/teammux-assign and related commands fail silently —
the command file is deleted and no error is surfaced to
the worker or Team Lead.

Fix: When commandRoutingCallback encounters an unknown
or malformed command, write an error response file back
to the worker's commands dir (e.g. .teammux-error with
the failure reason) before deleting the original.
Surface via setError so Swift can show a notification.

**I7 — Dispatch swallows delivery failures**
dispatchTask marks delivered=false but returns success
to the caller. The Team Lead sees a successful dispatch
but the message was never received.

Fix: propagate delivered=false as an error return from
dispatchTask. Caller (tm_worker_dispatch) should return
TM_ERR_DELIVERY_FAILED. Define TM_ERR_DELIVERY_FAILED
as error code 16 in tm_result_t.

**I13 — PR_READY/PR_STATUS delivery failures — no retry**
When PR_READY or PR_STATUS bus message delivery fails,
only a warning is logged. No retry, no surface to Swift.

Fix: Add retry with exponential backoff (3 attempts,
100ms/200ms/400ms) for PR_READY and PR_STATUS delivery.
After all retries exhausted: call setError with message
type and worker ID. Swift can surface a notification.

**Commit sequence:**
Commit 1: commands.zig — I6 error response on command failure
Commit 2: coordinator.zig + main.zig — I7 propagate delivery
           failure, TM_ERR_DELIVERY_FAILED (16) in header
Commit 3: bus.zig — I13 retry with backoff for PR messages

After each: cd engine && zig build && zig build test

**Definition of done:**
- Failed commands write error response to worker
- Dispatch delivery failures return TM_ERR_DELIVERY_FAILED
- PR message delivery retried 3 times before error surfaced
- TM_ERR_DELIVERY_FAILED (16) added to tm_result_t
- Engine tests pass

---

### S5 — PTY Death Cleanup

**Branch:** fix/v016-s5-pty-death
**Owns:** I8
**Layer:** Engine only
**Files:** engine/src/main.zig, engine/src/coordinator.zig,
           engine/src/worktree_lifecycle.zig

**I8 — PTY death has no cleanup/state-reconciliation path**
When a worker's PTY process dies unexpectedly (crash,
OOM, kill), the engine has no handler. The roster still
shows the worker as active. The worktree is left open.
The ownership registry still holds its file locks.

Fix:
1. Add PTY death detection: monitor worker PTY process
   via waitpid/kqueue. On death, fire ptyDiedCallback.
2. ptyDiedCallback: mark worker state as .errored in
   roster. Release all ownership registry entries for
   the worker. Do NOT remove worktree (preserve work).
   Send TM_MSG_PTY_DIED (17) on message bus.
   Call setError with worker ID and exit code.
3. Add TM_MSG_PTY_DIED = 17 to message type enum.
4. Swift bridge: EngineClient handles TM_MSG_PTY_DIED
   by surfacing a worker error state in the UI.

**Commit sequence:**
Commit 1: main.zig — PTY death detection (kqueue/waitpid)
Commit 2: coordinator.zig — ptyDiedCallback state reconciliation
Commit 3: main.zig — TM_MSG_PTY_DIED (17) bus event + setError

After each: cd engine && zig build && zig build test

**Definition of done:**
- PTY death detected within 1s of process exit
- Worker marked errored, ownership released, worktree preserved
- TM_MSG_PTY_DIED event fired on bus
- Swift can observe and surface worker error state
- TM_MSG_PTY_DIED = 17 added to message enum
- Engine tests pass

---

### S6 — C API Cleanup

**Branch:** fix/v016-s6-capi-cleanup
**Owns:** TD29, TD30
**Layer:** Engine only (header only)
**Files:** engine/include/teammux.h

**TD29 — 15 dead exports lack deprecation annotations**
The following 15 exports are marked in main.zig as
"NO SWIFT CALLER — candidate for removal in v0.2" but
the header has no corresponding annotation:
tm_worktree_create, tm_worktree_remove, tm_peer_question,
tm_peer_delegate, tm_worker_complete, tm_worker_question,
tm_completion_free, tm_question_free, tm_history_clear,
tm_ownership_get, tm_ownership_free, tm_ownership_update,
tm_interceptor_remove, tm_agent_resolve, tm_result_to_string

Fix: Add TEAMMUX_DEPRECATED comment block above each
declaration in teammux.h:
  /* DEPRECATED: No active callers. Candidate for removal
     in v0.2. Do not add new callers. */

**TD30 — TM_ERR_PTY stale**
TM_ERR_PTY = 6 is defined in tm_result_t but no function
returns it after PTY removal (AA6).

Fix: Add comment to TM_ERR_PTY in the enum:
  TM_ERR_PTY = 6, /* RESERVED: was PTY error, no longer
                     returned by any function. v0.2: remove */

Note: Also add TM_ERR_DELIVERY_FAILED = 16 and
TM_MSG_PTY_DIED = 17 from S4/S5 to the header.

**Commit sequence:**
Commit 1: teammux.h — TD29 deprecation annotations
Commit 2: teammux.h — TD30 TM_ERR_PTY reserved comment,
           add TM_ERR_DELIVERY_FAILED (16), TM_MSG_PTY_DIED (17)

After: cd engine && zig build (header only, no test change)

**Definition of done:**
- All 15 dead exports annotated as deprecated in header
- TM_ERR_PTY marked reserved with explanation
- TM_ERR_DELIVERY_FAILED and TM_MSG_PTY_DIED declared
- Engine builds cleanly

---

### S7 — Diff Reliability

**Branch:** fix/v016-s7-diff-reliability
**Owns:** TD40, TD41
**Layer:** Engine + Swift
**Files:** engine/src/github.zig,
           macos/Sources/Teammux/RightPane/DiffView.swift

**TD40 — getDiff no pagination**
getDiff uses ?per_page=100 without --paginate. PRs with
>100 files silently return only the first 100 files.
runGhCommand caps stdout at 1 MiB.

Fix:
- Replace single gh api call with --paginate --slurp
- --slurp wraps multi-page JSON arrays into a single array
- Increase runGhCommand buffer cap from 1 MiB to 10 MiB
  (configurable, PR files endpoint rarely exceeds this)
- Add page count to getDiff log output

**TD41 — loadDiff blocks main thread**
DiffView.loadDiff wraps engine.getDiff in
Task { @MainActor in } — spawns on MainActor, blocking
UI during gh subprocess (1-5 seconds).

Fix:
- Change to Task.detached { } (runs off MainActor)
- Capture engine reference before detach
- Dispatch result back to MainActor:
  await MainActor.run { self.diffFiles = result }
- Loading spinner will now render during fetch

**Commit sequence:**
Commit 1: github.zig — TD40 --paginate --slurp, 10 MiB cap
Commit 2: DiffView.swift — TD41 Task.detached, MainActor dispatch

After Commit 1: cd engine && zig build && zig build test
After Commit 2: ./build.sh

**Definition of done:**
- PRs with >100 files fully paginated
- Buffer cap raised to 10 MiB
- Diff loading runs off main thread
- Loading spinner renders during fetch
- Tests pass, ./build.sh passes

---

### S8 — CLEANUP_INCOMPLETE UI

**Branch:** fix/v016-s8-cleanup-ui
**Owns:** TD38
**Layer:** Swift only
**Files:** macos/Sources/Teammux/RightPane/GitView.swift,
           macos/Sources/Teammux/RightPane/ConflictView.swift

**TD38 — CLEANUP_INCOMPLETE warning never shown in UI**
approveMerge/rejectMerge return true on code 15 and log
a warning — but all UI callers only check lastError
inside `if !success`. The user never sees the warning.

Affected call sites:
- GitView.approveMerge (line 411)
- GitView.rejectMerge (line 422)
- GitView PREventCard.approveMerge (line 562)
- PREventCard.rejectMerge (line 576)
- ConflictView.forceMerge (line 128)

Fix: After each call site where success == true, also
check engine.lastError. If non-nil, show a non-fatal
banner or toast: "Merge succeeded — worktree cleanup
incomplete. Manual cleanup may be needed." Use SwiftUI
overlay or .alert with informational style (not error).

**Commit sequence:**
Single commit: GitView.swift + ConflictView.swift — check
lastError on success path, show non-fatal banner at all
5 call sites.

After: ./build.sh

**Definition of done:**
- All 5 call sites check lastError after success
- Non-fatal banner displayed on CLEANUP_INCOMPLETE
- No behavior change on true failures
- ./build.sh passes

---

### S9 — Test Coverage

**Branch:** fix/v016-s9-test-coverage
**Owns:** TD42, TD43, TD44
**Layer:** Engine + Swift
**Files:** engine/src/hotreload.zig,
           macos/Sources/Teammux/RightPane/ContextView.swift

**TD42 — LCS changedLineIndices has no unit tests**
changedLineIndices(old:new:) is a private static function
in ContextView.swift with no tests. Multiple code paths:
empty-old, empty-new, insertion, deletion, mixed,
identical, complete replacement.

Fix: Add @testable import in test target. Write at minimum
5 test cases: identical content (0 changes), single edit,
insertion-in-middle (the TD28 motivating case that was
previously broken), deletion, both-empty. Test via
XCTestCase if test target exists, or via a standalone
Swift test runner script if not.

**TD43 — reload_count never asserted in Zig tests**
All 10 Zig test callbacks accept the u64 reload_seq
parameter but discard it. No test verifies that
reload_count starts at 0, increments monotonically,
or increments on parse failure.

Fix: In the "watcher detects NOTE_WRITE" test and related
tests, capture the reload_seq value. Assert:
- First reload: seq == 1
- Second rapid reload: seq == 2 (increments even on repeat)
- Parse failure reload: seq still increments

**TD44 — LCS DP table O(m*n) memory**
computeChangedLineIndices allocates Array(repeating:
Array(repeating: 0, count: n+1), count: m+1).
For large CLAUDE.md files (1000+ lines), this causes
allocation pressure on the main thread.

Fix: Implement two-row optimization. LCS only needs
the previous row and current row. Replace the full
m*n table with two arrays of size n+1. Backtracking
requires a separate direction table (same size as
original) — use a compact UInt8 array instead of Int.

**Commit sequence:**
Commit 1: hotreload.zig — TD43 reload_count assertions
Commit 2: ContextView.swift — TD44 two-row LCS optimization
Commit 3: ContextView test — TD42 LCS unit tests

After Commit 1: cd engine && zig build test
After Commits 2+3: ./build.sh

**Definition of done:**
- reload_count asserted in Zig tests (start, increment, failure)
- LCS uses two-row optimization (O(n) space not O(m*n))
- LCS has minimum 5 unit test cases passing
- Engine tests pass, ./build.sh passes

---

### S10 — MergeCoordinator Full Workflow

**Branch:** fix/v016-s10-merge-coordinator
**Owns:** MergeCoordinator conflict surfacing as deliberate
          Team Lead decision point
**Layer:** Engine + Swift
**Files:** engine/src/merge.zig, engine/src/main.zig,
           engine/include/teammux.h,
           macos/Sources/Teammux/Engine/EngineClient.swift,
           macos/Sources/Teammux/RightPane/GitView.swift

**Background:**
The architecture brief (docs/) describes the full vision:
conflicts appear at merge time as deliberate decision points,
not runtime crashes. The Team Lead approves or rejects each
conflict. The current implementation surfaces conflicts
but does not provide per-conflict resolution UI.

**Phase 1 brainstorm required before implementing.**
Read these files first and present analysis:
- engine/src/merge.zig (current conflict handling)
- engine/include/teammux.h (tm_conflict_t, ConflictInfo)
- macos/Sources/Teammux/RightPane/GitView.swift (ConflictView)
- macos/Sources/Teammux/Engine/EngineClient.swift (merge bridge)

Brainstorm questions:
1. What does the current conflict surfacing actually do?
   Does it stop at the conflict and wait, or does it
   crash/abort the merge automatically?
2. What data is available in tm_conflict_t — file paths,
   conflict markers, ours/theirs content?
3. Does ConflictView currently allow per-conflict resolution
   (accept ours, accept theirs, manual edit) or just
   force-merge / reject?
4. What engine changes are needed to pause at a conflict
   and wait for Team Lead input?

**Likely fix (to be confirmed in brainstorm):**
Engine: add TM_CONFLICT_AWAIT state — merge pauses, fires
event with conflict details, waits for tm_conflict_resolve
call. Add tm_conflict_resolve(engine, worker_id,
resolution: ours/theirs/skip) C export.
Swift: ConflictView shows per-file resolution options.
Team Lead can accept-ours, accept-theirs, or skip per file.
On resolution: calls tm_conflict_resolve, merge continues.

**Definition of done:**
- Merge pauses on conflict, waits for Team Lead input
- Per-conflict resolution (ours/theirs/skip) available
- Conflict cards in GitView show file + conflicting sections
- Merge continues or aborts based on Team Lead decision
- Engine tests pass, ./build.sh passes

---

### S11 — Worker Health Monitoring

**Branch:** fix/v016-s11-worker-health
**Owns:** Worker health monitoring — stall detection,
          health status in roster, restart action
**Layer:** Engine + Swift
**Files:** engine/src/coordinator.zig, engine/src/main.zig,
           engine/include/teammux.h,
           macos/Sources/Teammux/Engine/EngineClient.swift,
           macos/Sources/Teammux/Workspace/WorkerDetailDrawer.swift,
           macos/Sources/Teammux/Workspace/WorkerRow.swift

**Engine side:**
- Add last_activity_ts: i64 field to Worker struct
  (updated on every message send/receive)
- Add health_status: enum { healthy, stalled, errored }
- Add stall_threshold_secs to config (default 300s = 5min)
- Background monitor thread: every 30s, check all active
  workers. If now - last_activity_ts > stall_threshold:
  set health_status = .stalled, fire TM_MSG_HEALTH_STALLED
- Add TM_MSG_HEALTH_STALLED = 18 to message enum
- Add tm_worker_restart(engine, worker_id) C export:
  kills current PTY, spawns new PTY in same worktree,
  resets health_status to .healthy

**Swift side:**
- WorkerRow: show health indicator dot (green/yellow/red)
  based on health_status
- WorkerDetailDrawer: show last activity timestamp,
  health status, "Restart Worker" button
- Restart button calls engine.restartWorker(id:)
- Live Feed: show stall notification card when
  TM_MSG_HEALTH_STALLED received

**Definition of done:**
- Stall detection fires after configurable threshold
- Health status visible in WorkerRow and drawer
- Restart action kills and respawns PTY in same worktree
- TM_MSG_HEALTH_STALLED = 18 in message enum
- Engine tests pass, ./build.sh passes

---

### S12 — User Terminal Pane

**Branch:** fix/v016-s12-user-terminal
**Owns:** 7th right pane — user's own Claude Code PTY,
          message bus wired bi-directionally
**Layer:** Swift only (Ghostty PTY infrastructure)
**Files:** macos/Sources/Teammux/RightPane/UserTerminalView.swift (new),
           macos/Sources/Teammux/App/AppDelegate.swift,
           macos/Sources/Teammux/Engine/EngineClient.swift

**Background:**
The mental model of Teammux is: every agent is a terminal.
The user's own session is no different — it's a PTY surface
in the right pane. The message bus already handles
bi-directional exchange between PTY sessions. The user
types in their own Claude Code session (their subscription,
their model), and the bus wires their messages to workers
and the Team Lead naturally.

**S12 depends on S14 for the icon rail** — it can be
implemented independently but must not merge until S14's
vertical icon rail changes are on main.

**Implementation:**
1. Create UserTerminalView.swift — a Ghostty SurfaceView
   PTY surface identical in structure to TeamLeadTerminalView
2. On session start: spawn a PTY with the user's shell
   (inherit $SHELL, $PATH, project root as cwd)
3. Do NOT inject the claude binary or any role — this is
   a raw shell the user controls
4. Wire to message bus: UserTerminalView sends/receives
   messages via the existing bus infrastructure
5. Add to right pane icon rail as "You" pane (icon: person)
6. The PTY persists for the session duration alongside
   the Team Lead terminal

**Definition of done:**
- UserTerminalView PTY surface spawns on session start
- Shell inherits project context (cwd = project root)
- Message bus wired bi-directionally
- Icon rail shows "You" pane icon
- PTY persists for session duration
- ./build.sh passes

---

### S13 — Agent Memory

**Branch:** fix/v016-s13-agent-memory
**Owns:** Per-worker context summaries persisted across
          task boundaries, surfaced in Context tab
**Layer:** Engine + Swift
**Files:** engine/src/main.zig, engine/include/teammux.h,
           macos/Sources/Teammux/Engine/EngineClient.swift,
           macos/Sources/Teammux/RightPane/ContextView.swift

**Engine side:**
- Each worker worktree gets a .teammux-memory.md file
- On worker completion: append a summary entry
  (timestamp, task description, completion summary,
  files modified, PR number if any)
- tm_memory_append(engine, worker_id, summary: [*:0]u8)
  C export — called by Swift on completion signal
- tm_memory_read(engine, worker_id) C export — returns
  current memory file content (caller-must-free)
- Memory file persists across session restore (it's in
  the worktree on disk)

**Swift side:**
- ContextView: add "Memory" section below CLAUDE.md
  content showing the memory timeline
- Each memory entry: timestamp, task, files touched,
  PR link if available
- On session restore: load memory file for each worker
  and populate the section
- Memory timeline collapses/expands per entry

**Definition of done:**
- .teammux-memory.md written in each worker's worktree
- Memory entries appended on task completion
- Memory timeline visible in Context tab
- Persists across session restore
- Engine tests pass, ./build.sh passes

---

### S14 — Premium UI/UX Polish

**Branch:** fix/v016-s14-ui-polish
**Owns:** Vertical scrollable icon rail replacing tab bar,
          premium macOS design language throughout
**Layer:** Swift only
**Files:** macos/Sources/Teammux/RightPane/RightPaneView.swift,
           macos/Sources/Teammux/RightPane/PaneIconRail.swift (new),
           macos/Sources/Teammux/ (all view files — style pass)

**Design Reference:** OpenAI Codex macOS app (developers.openai.com/codex/app)
Dark sidebar, clean cards, minimal chrome, native macOS
materials (vibrancy, blur), focused command center aesthetic.

**Vertical Icon Rail (PaneIconRail.swift):**
- New component: vertical ScrollView on far right edge
- Each icon: SF Symbol, 44pt tap target, tooltip on hover
- Active state: accent color fill, subtle background
- Inactive state: secondary label color
- Icons (top to bottom):
  1. terminal — Team Lead (worker 0)
  2. arrow.triangle.branch — Git
  3. doc.text.magnifyingglass — Diff
  4. bubble.left.and.bubble.right — Live Feed
  5. paperplane — Dispatch
  6. doc.text — Context
  7. person.fill — You (user terminal)
- Scroll indicator hidden, smooth momentum scroll
- Icon order matches mental model (coordination → review
  → user)
- RightPaneView: replace TabView/tab bar with PaneIconRail
  + conditional view rendering based on selected pane

**UI/UX Polish pass (all views):**
- Consistent 8pt/16pt/24pt spacing grid throughout
- Typography: SF Pro Text for body, SF Pro Display for
  headers, SF Mono for code and terminal content
- Worker cards in RosterView: status dot, role badge,
  task preview truncated to 2 lines, hover state
- Empty states: all views have a considered empty state
  (no workers, no PRs, no history, no diff loaded)
- Loading states: shimmer placeholders while data loads
- Smooth transitions: pane switching with cross-fade
- vibrancy/blur on sidebar panels where appropriate
- Keyboard shortcuts:
  Cmd+1..7 to switch panes
  Cmd+W to dismiss worker drawer
  Cmd+R to refresh current pane
  Esc to close popovers

**Commit sequence:**
Commit 1: PaneIconRail.swift — new component, RightPaneView
           wired to use it
Commit 2: RosterView + WorkerRow — worker card polish,
           empty state, status dots
Commit 3: Global style pass — spacing, typography, empty
           states, loading states across all views
Commit 4: Keyboard shortcuts + transitions

After each: ./build.sh

**Definition of done:**
- Vertical icon rail replaces tab bar in right pane
- 7 pane icons including "You" slot for S12
- Cmd+1..7 keyboard shortcuts work
- Empty and loading states in all major views
- Worker cards show status dot, role badge, task preview
- ./build.sh passes

---

### S15 — Integration Tests + v0.1.6 Ship

**Branch:** fix/v016-s15-integration
**Owns:** Integration tests, TECH_DEBT.md updates,
          CLAUDE.md shipped, tag v0.1.6
**Depends on:** All 14 streams merged to main

**Pull main first:**
git pull origin main

**Verify baseline before writing tests:**
cd engine && zig build test 2>&1 | tail -3
Report: test count (baseline from S1-S9 engine additions)

**Integration scenarios to test:**

1. Roster safety — spawn 3 workers, dismiss one mid-approve,
   verify no race crash, copyWorkerFields used throughout

2. Crash recovery — create orphaned worktree directory
   manually, start engine, verify it's cleaned up on init

3. History rotation — append entries until > 1 MiB,
   verify rotation creates .1 archive, fresh file starts

4. Bus reliability — send /teammux-assign (unknown command),
   verify error response written back to worker

5. Dispatch delivery failure — simulate bus failure,
   verify TM_ERR_DELIVERY_FAILED returned not swallowed

6. PTY death — spawn worker, kill its PTY process,
   verify TM_MSG_PTY_DIED fired, ownership released

7. Diff pagination — mock getDiff with 150-file response,
   verify all files returned (not truncated at 100)

8. Worker health — advance time past stall threshold,
   verify TM_MSG_HEALTH_STALLED fired

9. Agent memory — complete a worker task, verify
   .teammux-memory.md written with entry

10. MergeCoordinator conflict — trigger merge conflict,
    verify engine pauses and waits for resolution

**Documentation updates:**
TECH_DEBT.md:
- TD21/TD24/TD29/TD30/TD33/TD34/TD35/TD38/TD40/TD41/
  TD42/TD43/TD44 → RESOLVED
- I6/I7/I8/I11/I13/I15 → RESOLVED
- Add any new TD items discovered (TD45+)

CLAUDE.md:
- v0.1.6 → shipped
- Update engine test baseline count
- Update right pane section with all 7 icons confirmed

V016_SPRINT.md: All 15 streams → complete

**Tag and release:**
git tag -a v0.1.6 \
  -m "v0.1.6 — Depth & Polish: all remaining TD items resolved, audit-001 findings complete, MergeCoordinator full workflow, worker health monitoring, User terminal pane, agent memory, premium UI/UX with vertical icon rail"

git push origin v0.1.6

gh release create v0.1.6 \
  --title "v0.1.6 — Depth & Polish" \
  --notes "15-stream depth sprint. All deferred TD items and audit-001 findings resolved. New: MergeCoordinator full conflict workflow, worker health monitoring with restart, User terminal pane (7th right pane), agent memory timeline. UI: vertical scrollable icon rail, premium macOS design language, empty/loading states, keyboard shortcuts."

**Definition of done:**
- All 10 integration scenarios pass
- All resolved TD items marked in TECH_DEBT.md
- CLAUDE.md updated with shipped status and test count
- v0.1.6 tag on remote
- GitHub release created

---

## Message Type Registry (additions this sprint)

Existing:
- 0-11: task/instruction/context/etc (v0.1.x)
- 12: TM_MSG_PEER_QUESTION
- 13: TM_MSG_DELEGATION
- 14: TM_MSG_PR_READY
- 15: TM_MSG_PR_STATUS

New this sprint:
- 16: TM_ERR_DELIVERY_FAILED (error code, not message type)
- 17: TM_MSG_PTY_DIED (S5)
- 18: TM_MSG_HEALTH_STALLED (S11)

## PR Review Standards

All PRs follow established review standards:
- Branch based on current main (Check 1)
- Only correct files modified (Check 2)
- No force-unwraps in production Swift
- No tm_* calls outside EngineClient.swift
- Engine builds cleanly
- All engine tests pass (report count)
- ./build.sh passes for Swift streams
- Conflict check with main (final check)
- No src/ modifications (any check)

## References

- docs/TECH_DEBT.md — full debt registry
- docs/codex-audits/audit-001-post-v014/ACTION-PLAN.md
- docs/sprints/v0.1.5/V015_SPRINT.md — prior sprint
- engine/include/teammux.h — C API source of truth
- docs/architecture.md — system design overview
