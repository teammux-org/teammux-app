# Audit-002 — Post v0.1.6 Codebase Audit

**Status:** In Progress
**Baseline:** v0.1.6 tag, 475 engine tests passing
**Output directory:** docs/codex-audits/audit-002-post-v016/
**Tool:** Codex CLI (AA1-AA7) + Claude Code (AA8 synthesis)

---

## Objective

Audit the v0.1.6 codebase with focus on the six high-risk
domains introduced or significantly changed during the
v0.1.6 depth sprint. The audit is read-only and produces
structured findings for a targeted address sprint.

The previous audit (audit-001-post-v014) found 4 criticals
and 31 importants across 6 domains. All were resolved across
the audit-address sprint and v0.1.5/v0.1.6. This audit
focuses specifically on the new surface area.

---

## Stream Registry

| Stream | Tool   | Domain                          | Branch |
|--------|--------|---------------------------------|--------|
| AA1    | Codex  | Concurrency & memory safety     | detach |
| AA2    | Codex  | C API contracts & header hygiene| detach |
| AA3    | Codex  | Swift layer — new views         | detach |
| AA4    | Codex  | Engine — new modules            | detach |
| AA5    | Codex  | Message bus & coordination      | detach |
| AA6    | Codex  | Integration correctness         | detach |
| AA7    | Codex  | Engine — existing modules refresh| detach |
| AA8    | Claude | Synthesis & ACTION-PLAN         | detach |

AA1-AA7 run in parallel. AA8 starts only after all 7 complete.

---

## Output Files

Each Codex stream (AA1-AA7) produces two files:
- `FINDINGS-AA{N}-{domain}.md` — detailed per-issue findings
- `SUMMARY-AA{N}-{domain}.md` — executive summary

AA8 produces:
- `ACTION-PLAN.md` — deduplicated findings, sprint proposal

All files committed to `docs/codex-audits/audit-002-post-v016/`

---

## Domain Specifications

---

### AA1 — Concurrency & Memory Safety

**Focus:** New concurrency primitives introduced in v0.1.6.
v0.1.6 added three background threads and two new mutex
patterns. This is the highest-risk domain.

**Primary files:**
- `engine/src/coordinator.zig` — PtyMonitor struct, health
  monitor thread, checkWorkerHealth, ptyDiedCallback,
  last_activity_ts updates
- `engine/src/history.zig` — async write queue ring buffer,
  startWriter background thread, flush/shutdown, enqueue
- `engine/src/main.zig` — PtyMonitor integration, session
  lifecycle (start/stop), tm_worker_restart mutex patterns,
  all new v0.1.6 mutex acquisitions

**Look for:**
- Data races on shared state between background threads and
  main thread (last_activity_ts, health_status, queue fields)
- Lock ordering issues (multiple mutexes acquired in different
  orders across call sites)
- Use-after-free in PtyMonitor (worker dismissed while monitor
  holds reference to its data)
- Mutex held too long (blocking main thread on background ops)
- Missing errdefer on partial allocations in new code paths
- Queue not fully draining on shutdown (flush timeout too short)
- Thread not joined on engine destroy (resource leak)
- ptyDiedCallback called after engine destroyed (dangling engine ptr)
- Health monitor not stopped before roster teardown

**Output:** FINDINGS-AA1-concurrency.md, SUMMARY-AA1-concurrency.md

---

### AA2 — C API Contracts & Header Hygiene

**Focus:** The C API boundary post-TD29/TD30 cleanup and
the new exports added in v0.1.6.

**Primary files:**
- `engine/include/teammux.h` — all exports, error codes,
  message types, deprecated annotations, caller-must-free docs
- `engine/src/main.zig` — all tm_* export implementations
  vs header declarations

**New exports to audit (v0.1.6 additions):**
- tm_worker_pty_died, tm_worker_monitor_pid
- tm_worker_restart, tm_worker_health_status, tm_worker_last_activity
- tm_memory_append, tm_memory_read, tm_memory_free
- tm_history_rotate
- tm_conflict_resolve, tm_conflict_finalize

**Look for:**
- Missing null checks on engine/worker_id at C API entry points
- caller-must-free contracts not documented in header or not
  honored in implementation (caller expected to free but engine
  frees, or vice versa)
- Error codes returned by implementation but not declared in
  tm_result_t enum
- New exports declared in header but not implemented (or vice versa)
- TM_ERR_PTY (6) still reachable despite being marked RESERVED
- DEPRECATED exports still called internally (should have no callers)
- Missing setError calls on failure paths in new exports
- Inconsistent null vs TM_ERR_* return on failure (some functions
  return null, some return error code — check for consistency)

**Output:** FINDINGS-AA2-capi.md, SUMMARY-AA2-capi.md

---

### AA3 — Swift Layer New Views

**Focus:** All new or significantly modified Swift views
introduced in v0.1.6.

**Primary files:**
- `macos/Sources/Teammux/RightPane/PaneIconRail.swift`
- `macos/Sources/Teammux/RightPane/UserTerminalView.swift`
- `macos/Sources/Teammux/RightPane/ContextView.swift`
  (memory section additions — lines ~200-450)
- `macos/Sources/Teammux/RightPane/GitView.swift`
  (ConflictView per-file resolution, cleanup warning banner)
- `macos/Sources/Teammux/Workspace/WorkerDetailDrawer.swift`
  (health section, restart button)
- `macos/Sources/Teammux/Workspace/WorkerRow.swift`
  (health indicator dot)

**Look for:**
- Force unwraps in production code paths
- Memory leaks in SwiftUI views (strong reference cycles,
  @StateObject vs @ObservedObject misuse)
- MainActor violations (calling engine functions from non-actor
  context, or blocking MainActor with synchronous C calls)
- PTY lifecycle issues in UserTerminalView (PTY created before
  project root available, PTY not cleaned up on session end)
- ConflictView stale state (resolution state not cleared between
  different workers' conflicts, finalize enabled when it shouldn't be)
- Keyboard shortcut conflicts (Cmd+1..7 may conflict with system
  shortcuts in certain contexts)
- NSEvent local monitor not removed on view disappear (retain cycle)
- Memory timeline parseMemoryEntries crashing on malformed markdown
- Restart button accessible when worker is healthy (should be
  disabled for healthy workers)
- Missing empty/error states in new views

**Output:** FINDINGS-AA3-swift.md, SUMMARY-AA3-swift.md

---

### AA4 — Engine Correctness New Modules

**Focus:** New Zig modules and significantly changed existing
modules in v0.1.6 — correctness, not concurrency.

**Primary files:**
- `engine/src/memory.zig` — agent memory append/read, timestamp
  formatting, file path construction, special character handling
- `engine/src/history.zig` — JSONL rotation logic, archive naming,
  boundary conditions, async queue correctness (not threading)
- `engine/src/worktree_lifecycle.zig` — recoverOrphans scan logic,
  cleanup reorder (I11 fix), git error handling

**Look for:**

*memory.zig:*
- File path construction using wrong separator or missing
  path components
- Timestamp formatting incorrect for non-UTC timezones
- Markdown entry corruption on summary strings containing
  `##` headers (confuses parseMemoryEntries)
- File not created if worktree directory doesn't exist yet
- tm_memory_free not matching tm_memory_read allocation strategy

*history.zig:*
- Rotation renames .1 → .2 before .jsonl → .1 (wrong order
  could lose data)
- max_size_bytes check on post-write size vs pre-write (rotation
  trigger timing)
- async queue entries not freed on overflow (memory leak)
- flush() returning before all entries drained

*worktree_lifecycle.zig:*
- recoverOrphans treating non-numeric dirs as orphans (false positive)
- recoverOrphans running before config loaded (wrong worktree root)
- Cleanup reorder (I11): registry drop still reachable if git
  commands panic rather than return error
- git branch -D hardcoded pattern may not match all branch formats

**Output:** FINDINGS-AA4-engine-modules.md, SUMMARY-AA4-engine-modules.md

---

### AA5 — Message Bus & Coordination

**Focus:** All new delivery, retry, and event paths introduced
in v0.1.6.

**Primary files:**
- `engine/src/bus.zig` — retry logic, backoff delays, PR message
  special casing, error_notify_cb, general vs PR retry timing
- `engine/src/coordinator.zig` — ptyDiedCallback idempotency,
  health stall event firing, delivery failure propagation (I7)
- `engine/src/commands.zig` — writeErrorResponse, error_cb wiring,
  .teammux-error file lifetime

**Look for:**

*bus.zig:*
- Retry loop not terminating if bus keeps returning transient error
- Backoff delay arithmetic overflow on large attempt counts
- error_notify_cb called with freed message type string
- Non-PR messages accidentally getting PR retry timing
- Retry sleeping on main thread (blocking)

*coordinator.zig:*
- ptyDiedCallback: ownership_registry.release called without
  confirming worker is in registry (double-release risk)
- Health stall event: TM_MSG_HEALTH_STALLED fired every 30s
  indefinitely for a stalled worker (should fire once per stall)
- Delivery failure: error code 16 returned but lastError not set
  (Swift sees error code but no message)

*commands.zig:*
- .teammux-error file written but never cleaned up if engine
  restarts before worker reads it (stale error files accumulate)
- writeErrorResponse fails silently if worker commands dir
  doesn't exist (no fallback notification)
- error_cb invoked after engine destroyed (dangling callback)

**Output:** FINDINGS-AA5-bus.md, SUMMARY-AA5-bus.md

---

### AA6 — Integration Correctness Cross-Module

**Focus:** How v0.1.6 modules interact at boundaries.
Each audit item examines a specific module pair.

**Pairs to audit:**

1. **Roster safety (S1) + MergeCoordinator (S10)**
   merge.zig uses copyWorkerFields for roster access. But
   conflict resolution state (resolutions hashmap) is keyed
   by worker_id. If a worker is dismissed mid-conflict, is
   the resolution state cleaned up? Does the hashmap entry
   get freed?

2. **PTY death (S5) + Health monitor (S11)**
   ptyDiedCallback sets worker to .err. Health monitor checks
   last_activity_ts for stall. If a worker dies and is marked
   .err, does the health monitor still fire TM_MSG_HEALTH_STALLED
   for it? Does checkWorkerHealth skip .err workers?

3. **History async queue (S3) + Bus delivery path (S4)**
   Delivery path enqueues history entries. Bus retry loop retries
   on failure. If the retry fires rapidly, does the queue overflow?
   Is the enqueue called on the retry thread or the main thread?

4. **Agent memory (S13) + Session restore**
   loadAllWorkerMemory iterates roster post-restore. If a worker's
   worktree was cleaned up (merged PR), the memory file may be
   gone. Does memoryRead handle FileNotFound gracefully when
   called for a restored worker whose worktree no longer exists?

5. **Crash recovery (S2) + Health monitor (S11)**
   recoverOrphans removes orphaned worktrees at sessionStart.
   Health monitor then starts. If a worker is restored from
   session state but its worktree was removed by recoverOrphans,
   does the health monitor fire for a worker with no worktree?

**Output:** FINDINGS-AA6-integration.md, SUMMARY-AA6-integration.md

---

### AA7 — Engine Existing Modules Refresh

**Focus:** Modules that existed before v0.1.6 but were
touched by v0.1.6 changes. Verify no regressions.

**Primary files:**
- `engine/src/merge.zig` — post-S10 additions (resolveConflict,
  finalizeMerge, ConflictResolution enum, resolutions hashmap)
- `engine/src/ownership.zig` — verify unchanged and clean
  (no new callers bypassing registry)
- `engine/src/interceptor.zig` — verify S1 roster changes did
  not break PATH injection or interceptor install/remove
- `engine/src/github.zig` — post-S7 pagination changes,
  runGhCommand max_output parameter, getDiff --paginate --slurp

**Look for:**

*merge.zig:*
- resolveConflict: git checkout --ours/--theirs fails silently
  (exit code not checked)
- finalizeMerge: git commit message hardcoded or missing
- resolutions hashmap entry not freed on reject() path
- ConflictResolution.skip causes finalizeMerge to block (pending
  check should exclude skip or document behaviour)
- Multiple calls to approve() without reject() in between
  leaving resolutions in partial state

*ownership.zig:*
- Any new code paths in v0.1.6 that touch ownership registry
  without going through the registered API (verify grep shows
  no direct struct access from main.zig bypassing registry)

*interceptor.zig:*
- S1's copyWorkerFields changes: interceptor reads worker's
  deny patterns — verify it still reads them correctly post-S1
- Team Lead interceptor (worker 0) deny-all still enforced
  after S1's roster mutex changes

*github.zig:*
- --paginate --slurp: if gh exits non-zero mid-pagination,
  partial output may be returned as valid JSON
- runGhCommand max_output: verify caller-supplied max_output
  is actually used in readToEndAlloc, not silently capped

**Output:** FINDINGS-AA7-existing.md, SUMMARY-AA7-existing.md

---

### AA8 — Synthesis (Claude Code)

**Runs after:** AA1-AA7 all committed their output files.
**Tool:** Claude Code (`claude --effort max --dangerously-skip-permissions`)

**Task:**
1. Read all FINDINGS-AA{1-7}-*.md and SUMMARY-AA{1-7}-*.md
2. Deduplicate findings appearing in multiple streams
3. Classify all findings by severity across all domains
4. Identify any finding that contradicts a v0.1.5/v0.1.6 fix
   (potential regression)
5. Group findings by recommended fix ownership (engine vs Swift
   vs header vs cross-module)
6. Propose address sprint structure:
   - How many streams needed
   - Which findings cluster naturally
   - Suggested merge order
7. Produce ACTION-PLAN.md in this directory

**Output:** ACTION-PLAN.md

---

## Completion Criteria

Audit-002 is complete when:
- All 7 FINDINGS files committed
- All 7 SUMMARY files committed
- ACTION-PLAN.md committed
- Total finding count and severity breakdown documented
- Address sprint structure proposed in ACTION-PLAN.md

---

## File Checklist

```
docs/codex-audits/audit-002-post-v016/
├── AUDIT-002-SPEC.md          ← this file
├── FINDINGS-AA1-concurrency.md
├── FINDINGS-AA2-capi.md
├── FINDINGS-AA3-swift.md
├── FINDINGS-AA4-engine-modules.md
├── FINDINGS-AA5-bus.md
├── FINDINGS-AA6-integration.md
├── FINDINGS-AA7-existing.md
├── SUMMARY-AA1-concurrency.md
├── SUMMARY-AA2-capi.md
├── SUMMARY-AA3-swift.md
├── SUMMARY-AA4-engine-modules.md
├── SUMMARY-AA5-bus.md
├── SUMMARY-AA6-integration.md
├── SUMMARY-AA7-existing.md
└── ACTION-PLAN.md
```
