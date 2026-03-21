# Audit-002 Action Plan — Post v0.1.6

## Finding Summary

Total findings by severity across all 7 streams.

| Stream | Domain | Critical | Important | Suggestion | Total |
|--------|--------|----------|-----------|------------|-------|
| AA1 | Concurrency & memory safety | 2 | 1 | 0 | 3 |
| AA2 | C API contracts & header hygiene | 1 | 3 | 0 | 4 |
| AA3 | Swift layer new views | 1 | 3 | 0 | 4 |
| AA4 | Engine new modules | 0 | 4 | 0 | 4 |
| AA5 | Message bus & coordination | 0 | 3 | 1 | 4 |
| AA6 | Integration correctness | 1 | 3 | 0 | 4 |
| AA7 | Existing modules refresh | 1 | 1 | 0 | 2 |
| **Total** | | **6** | **18** | **1** | **25** |

After deduplication (2 cross-stream duplicates): **23 unique findings**.

---

## Critical Findings (must fix before next release)

### C1: Health monitor reads `cfg` concurrently with `tm_config_reload`
- **Finding ID:** 1-1
- **Source:** AA1 — Concurrency
- **File:** `engine/src/main.zig:511`
- **Risk:** Use-after-free or corrupted reads when config reload races the health-monitor background thread.

### C2: Failed `tm_session_start` leaves a live history writer attached to inline engine state
- **Finding ID:** 1-2
- **Source:** AA1 — Concurrency
- **File:** `engine/src/main.zig:350`
- **Risk:** Orphaned background writer thread on failed startup; retry on same engine causes data race and undefined behavior.

### C3: Unchecked enum conversion can crash C API callers
- **Finding ID:** 2-1
- **Source:** AA2 — C API
- **File:** `engine/src/main.zig:1008`
- **Risk:** Invalid `tm_message_type_t` or `tm_merge_strategy_t` value panics the process at the ABI boundary instead of returning an error.

### C4: Restart button clears health without recreating the worker PTY
- **Finding ID:** 3-1
- **Source:** AA3 — Swift
- **File:** `macos/Sources/Teammux/Workspace/WorkerDetailDrawer.swift:132`
- **Risk:** Dead worker marked healthy with no actual PTY recovery; hides failure from roster and allows dispatch to a non-functional worker.

### C5: Crash recovery deletes legitimate restore-session worktrees before restore begins
- **Finding ID:** 6-4
- **Source:** AA6 — Integration
- **File:** `engine/src/main.zig:299`
- **Risk:** Reopening a saved session can destroy unmerged worker worktrees and branches before `restoreSession()` runs.

### C6: Failed conflict finalization disables git enforcement for an active worker
- **Finding ID:** 7-1
- **Source:** AA7 — Existing modules
- **File:** `engine/src/main.zig:2207`
- **Risk:** Failed finalize removes interceptor and role watcher, leaving active worker without PATH-based git enforcement until manual reinstall.

---

## Important Findings (fix in next sprint)

### I1: PtyMonitor allows stale PID registrations to clobber restarted workers
- **Finding ID:** 1-3
- **Source:** AA1 — Concurrency
- **File:** `engine/src/main.zig:55`
- **Risk:** Late death notification for old PID re-errors a restarted worker and drops monitoring for the new PID.

### I2: PTY death APIs missing from public header
- **Finding ID:** 2-2
- **Source:** AA2 — C API
- **File:** `engine/include/teammux.h:238`
- **Risk:** `tm_worker_pty_died` and `tm_worker_monitor_pid` are exported but not declared in the header (source of truth).

### I3: Conflict-resolution exports collapse Git failures into `TM_ERR_INVALID_WORKER`
- **Finding ID:** 2-3
- **Source:** AA2 — C API
- **File:** `engine/src/main.zig:2177`
- **Risk:** Git checkout/add/commit failures misreported as roster precondition errors; hides real remediation path.

### I4: `tm_version()` still reports `0.1.0`
- **Finding ID:** 2-4
- **Source:** AA2 — C API
- **File:** `engine/src/main.zig:2950`
- **Risk:** Stale version string in all consumers, diagnostics, and telemetry; test locks the wrong value.

### I5: CLEANUP_INCOMPLETE warnings disappear before user reads them
- **Finding ID:** 3-2
- **Source:** AA3 — Swift
- **File:** `macos/Sources/Teammux/RightPane/GitView.swift:245`
- **Risk:** Cleanup-needed warnings stored in transient `@State` on views that disappear on merge-state transition.

### I6: Conflict-resolution and restart actions run synchronous on MainActor
- **Finding ID:** 3-3
- **Source:** AA3 — Swift
- **File:** `macos/Sources/Teammux/RightPane/ConflictView.swift:145`
- **Risk:** Git/merge/restart FFI calls block the UI thread, freezing the app during recovery operations.

### I7: Memory timeline parsing corrupts entries with markdown headings
- **Finding ID:** 3-4 / 4-1 (cross-stream duplicate)
- **Source:** AA3 — Swift + AA4 — Engine
- **File:** `macos/Sources/Teammux/RightPane/ContextView.swift:461` + `engine/src/memory.zig:38`
- **Risk:** Agent summaries containing `##` or `#` headings split into fake entries or drop content in the memory timeline.

### I8: Automatic history rotation hides newest entry from reload
- **Finding ID:** 4-2
- **Source:** AA4 — Engine
- **File:** `engine/src/history.zig:159`
- **Risk:** Size-triggering append moves the active file to `.1`; `load()` only reads active file, so newest entry is invisible after restart.

### I9: Relative `worktree_root` overrides break downstream path assumptions
- **Finding ID:** 4-3
- **Source:** AA4 — Engine
- **File:** `engine/src/worktree_lifecycle.zig:106`
- **Risk:** Creation, recovery, and file writes disagree on worktree location; config override produces broken lifecycle.

### I10: Branch-only cleanup failures not recoverable on next startup
- **Finding ID:** 4-4
- **Source:** AA4 — Engine
- **File:** `engine/src/worktree_lifecycle.zig:232`
- **Risk:** Stale `teammux/{id}-*` branches accumulate if directory removal succeeds but branch deletion fails; no retry path.

### I11: Callback-routed `/teammux-*` failures still deleted silently
- **Finding ID:** 5-01
- **Source:** AA5 — Bus
- **File:** `engine/src/commands.zig:249`
- **Risk:** Internal command handler failures delete the source file without writing `.teammux-error`; recreates silent-failure class.

### I12: PTY death never marks worker `health_status` as errored
- **Finding ID:** 5-02 / 6-2 (cross-stream duplicate)
- **Source:** AA5 — Bus + AA6 — Integration
- **File:** `engine/src/coordinator.zig:158`
- **Risk:** Dead worker shows as health-healthy; restart resets health but not status, so monitoring never resumes.

### I13: `.teammux-error` never cleared after failures
- **Finding ID:** 5-03
- **Source:** AA5 — Bus
- **File:** `engine/src/commands.zig:99`
- **Risk:** Stale error payloads bleed into later commands or sessions.

### I14: Worker dismiss strands conflicted merge state
- **Finding ID:** 6-1
- **Source:** AA6 — Integration
- **File:** `engine/src/main.zig:806`
- **Risk:** Dismissing a worker mid-conflict leaves merge wedged; no API path to reject/finalize without manual git cleanup.

### I15: Completion/question history dropped on bus delivery failure
- **Finding ID:** 6-3
- **Source:** AA6 — Integration
- **File:** `engine/src/main.zig:403`
- **Risk:** History persistence gated on delivery success; transient bus failures suppress audit/restore records.

### I16: `finalizeMerge` reintroduces raw roster-pointer access on production path
- **Finding ID:** 7-2
- **Source:** AA7 — Existing modules
- **File:** `engine/src/merge.zig:412`
- **Risk:** Direct `getWorker()` mutation races concurrent roster readers; regresses v0.1.6 roster-locking hardening.

---

## Suggestions (deferred/optional)

- **5-04:** PR status delivery diagnostics overwritten with generic error (`engine/src/main.zig:403`) — `busSendBridge()` overwrites the specific `error_notify_cb` message with a generic string, losing worker/message-specific context.

---

## Cross-Stream Duplicates

Two findings were independently flagged by multiple audit streams:

| Consolidated ID | Streams | Finding IDs | Issue |
|-----------------|---------|-------------|-------|
| I7 | AA3 + AA4 | 3-4, 4-1 | Memory markdown heading corruption — engine writes raw markdown, Swift parser splits on `##` |
| I12 | AA5 + AA6 | 5-02, 6-2 | PTY death / health_status desync — `ptyDiedCallback` never sets `health_status = .errored`, restart doesn't reconcile `status` |

Both are consolidated into single entries in the Important Findings section above.

---

## Regression Indicators

Three findings contradict or undermine fixes shipped in v0.1.5 or v0.1.6:

| Finding | Regresses | Detail |
|---------|-----------|--------|
| I11 (5-01) | **audit-001 I6** (silent failure fix) | Callback-routed `/teammux-*` command failures are still silently deleted without `.teammux-error`, reopening the exact silent-failure class I6 was supposed to close. |
| I16 (7-2) | **v0.1.6 roster-locking hardening** | `finalizeMerge()` uses raw `Roster.getWorker()` + direct mutation, bypassing the `copyWorkerFields()` / `setWorkerStatus()` pattern established elsewhere in v0.1.6. |
| I5 (3-2) | **v0.1.6 TD38** (cleanup warning visibility) | CLEANUP_INCOMPLETE warnings are still stored in transient `@State` on views that disappear on merge-state transition, undermining the TD38 fix. |

These should be prioritized within their respective fix clusters as they represent incomplete prior work.

---

## Proposed Address Sprint Structure

### Stream 1: Lifecycle & Concurrency Safety
- **Branch:** `audit-addr-002/s1-lifecycle`
- **Findings:** C1 (1-1), C2 (1-2), C5 (6-4)
- **Layer:** Engine
- **Complexity:** Large
- **Notes:** All three are lifecycle-ordering bugs in `main.zig`. C5 (restore vs orphan recovery) is the highest-impact data-loss risk. C1 and C2 are session-start/config-reload races. Fix C5 first (defer `recoverOrphans` until after restore), then C2 (rollback history writer on failed start), then C1 (snapshot config for health monitor).

### Stream 2: C API Boundary Hardening
- **Branch:** `audit-addr-002/s2-capi`
- **Findings:** C3 (2-1), I2 (2-2), I3 (2-3), I4 (2-4)
- **Layer:** Engine + Header
- **Complexity:** Medium
- **Notes:** C3 is the only critical — replace `@enumFromInt` with checked conversion at all C entry points. I2 adds header declarations. I3 remaps error codes. I4 updates version constant and test.

### Stream 3: Merge & Conflict Workflow
- **Branch:** `audit-addr-002/s3-merge`
- **Findings:** C6 (7-1), I16 (7-2), I14 (6-1), I6 (3-3)
- **Layer:** Engine + Swift
- **Complexity:** Large
- **Notes:** C6 is critical — move interceptor/watcher teardown to success path only. I16 is a regression — migrate `finalizeMerge` to `copyWorkerFields`/`setWorkerStatus`. I14 adds merge-aware dismiss. I6 moves FFI calls off MainActor. Merge order: after Stream 1 (depends on roster safety).

### Stream 4: Worker Health & PTY Recovery
- **Branch:** `audit-addr-002/s4-health`
- **Findings:** C4 (3-1), I1 (1-3), I12 (5-02/6-2)
- **Layer:** Engine + Swift
- **Complexity:** Large
- **Notes:** C4 is critical — implement actual PTY restart path in Swift workspace layer before calling `tm_worker_restart`. I1 enforces one-to-one PID mapping. I12 sets `health_status = .errored` on PTY death and reconciles both fields on restart. Merge order: after Stream 2 (depends on header declarations for PTY APIs).

### Stream 5: Error Surface & Command Reliability
- **Branch:** `audit-addr-002/s5-errors`
- **Findings:** I11 (5-01), I13 (5-03), I15 (6-3), I5 (3-2)
- **Layer:** Engine + Swift
- **Complexity:** Medium
- **Notes:** I11 is a regression (I6 re-open) — change callback contract to report success/failure. I13 cleans stale `.teammux-error` on startup and success. I15 decouples history persistence from delivery success. I5 hoists cleanup warnings to stable state. Merge order: after Stream 3 (depends on merge workflow changes for cleanup warnings).

### Stream 6: Memory, History & Worktree Correctness
- **Branch:** `audit-addr-002/s6-correctness`
- **Findings:** I7 (3-4/4-1), I8 (4-2), I9 (4-3), I10 (4-4), S1 (5-04)
- **Layer:** Engine + Swift
- **Complexity:** Medium
- **Notes:** I7 is a cross-stream duplicate — escape or fence markdown body in `memory.zig` and tighten the Swift parser. I8 rotates before writing instead of after. I9 normalizes `worktree_root` to absolute at config load. I10 enumerates leftover branches independently of directory presence. S1 is optional polish. Merge order: last (no downstream dependencies).

### Recommended Merge Order

```
Stream 1 (lifecycle)     ← first: fixes data-loss and concurrency fundamentals
  └─► Stream 2 (C API)  ← second: header + enum safety, enables PTY API declarations
       └─► Stream 4 (health/PTY) ← third: depends on header declarations from S2
       └─► Stream 3 (merge)      ← third: depends on roster safety from S1
            └─► Stream 5 (errors) ← fourth: depends on merge workflow from S3
                 └─► Stream 6 (correctness) ← last: independent, lowest risk
```

**Total streams:** 6
**Estimated scope:** 6 criticals + 16 importants + 1 suggestion = 23 unique findings

---

## Open Questions

1. **C4 / Restart scope (3-1):** The restart button currently calls `tm_worker_restart` which only resets health state. A real restart requires tearing down the Ghostty surface and creating a new one. **Decision needed:** Should the address sprint implement a full PTY restart path in the Swift workspace layer, or should the button be disabled/removed until a future sprint? Full implementation touches Ghostty surface lifecycle which may be non-trivial.

2. **C5 / Orphan recovery timing (6-4):** `recoverOrphans` runs at `sessionStart` while the roster is empty, so it deletes saved-session worktrees. **Decision needed:** Should orphan recovery be deferred until after `restoreSession`, or should it consult persisted session metadata before deleting? The latter is safer but requires session state to be readable before the engine is fully started.

3. **I7 / Memory format (3-4/4-1):** The memory timeline corruption is caused by storing raw markdown under `##` headers. **Decision needed:** Should the fix be minimal (escape/fence body text in `memory.zig`) or structural (switch to a structured format like JSONL for memory entries)? Structural fix is cleaner but breaks existing memory files.

4. **I9 / Relative worktree_root (4-3):** Relative paths are handled inconsistently. **Decision needed:** Should relative paths be supported (normalize to absolute relative to `project_path`) or rejected outright at config load? Rejection is simpler but may break edge-case configurations.

5. **I4 / Version sourcing (2-4):** `tm_version()` is hardcoded to `"0.1.0"`. **Decision needed:** Should version be sourced from a build-time constant (e.g., `build.zig` option), a version file, or the git tag? Build-time is cleanest but requires build system changes.
