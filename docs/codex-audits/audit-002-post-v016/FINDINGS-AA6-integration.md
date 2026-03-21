## Finding 6-1: Generic worker dismiss strands conflicted merge state
**Severity:** IMPORTANT
**File:** engine/src/main.zig:806
**Description:** `tm_worker_dismiss()` removes the worker from the roster and worktree registry directly, but it never reconciles `MergeCoordinator` state. If the dismissed worker is the one currently held in `active_merge`, the coordinator keeps its `active_merge`, `conflicts`, and `resolutions` entries because only `reject()` / `finalizeMerge()` free those structures.
**Risk:** Dismissing a worker mid-conflict can leave the main repo stuck in an in-progress merge while future `tm_merge_approve()` calls fail with `MergeInProgress`. Because the worker is already gone from the roster, there is no normal UI/API path left to reject or finalize that merge, so the merge workflow stays wedged until manual git cleanup or engine restart.
**Recommendation:** Reject generic dismiss for a worker that owns `active_merge`, or route dismiss through a merge-aware cleanup path that aborts the merge and frees the conflict/resolution maps before removing the worker.

## Finding 6-2: PTY death and restart leave worker status/health out of sync
**Severity:** IMPORTANT
**File:** engine/src/coordinator.zig:158
**Description:** `ptyDiedCallback()` sets `worker.status = .err` but does not set `health_status = .errored`. Later, `tm_worker_restart()` only resets `health_status` and `last_activity_ts`; it does not restore `worker.status` to a live state. The health monitor only tracks workers whose status is `.idle` or `.working`.
**Risk:** A dead worker can still surface as health-healthy to `tm_worker_health_status()` consumers, and once that worker is restarted it remains `status = .err`, so health monitoring never resumes for that worker. In the Swift layer this also blocks or mis-drives restart affordances that are keyed off errored/stalled health.
**Recommendation:** Make PTY death set `health_status = .errored`, and make restart reconcile both fields together by restoring `status` to a live state before the worker re-enters health monitoring.

## Finding 6-3: Completion/question history is dropped when bus delivery exhausts retries
**Severity:** IMPORTANT
**File:** engine/src/main.zig:403
**Description:** `busSendBridge()` returns immediately when `b.send()` fails after retries, and the same ordering exists in `tm_worker_complete()` / `tm_worker_question()`. The `HistoryLogger.append()` call only runs after successful delivery, even though the C API contract says completion/question events are appended to `completion_history.jsonl` on every call and command-file event.
**Risk:** The exact failure mode that triggers bus retries also suppresses completion-history persistence, so operators lose audit/restore history for completion and question events during transient delivery outages. The message is still written to the bus log, but it never reaches the history log that the UI reloads on session start.
**Recommendation:** Decouple history persistence from delivery success. Enqueue the history entry before returning delivery status, or use a `defer`/post-send path that records the event regardless of whether delivery succeeded.

## Finding 6-4: Crash recovery deletes legitimate restore-session worktrees before restore begins
**Severity:** CRITICAL
**File:** engine/src/main.zig:299
**Description:** `sessionStart()` always runs `recoverOrphans()` while the engine roster is intentionally empty. In the restore flow, Swift calls `sessionStart()` before `restoreSession()`, so every numeric worktree directory from the saved session is absent from the roster and is therefore treated as an orphan by `recoverOrphans()`.
**Risk:** Reopening a saved session can delete legitimate worker worktrees and branches before Swift has a chance to restore them. `restoreSession()` then sees missing `worktreePath`s and skips those workers, which can destroy unmerged work rather than merely failing to restore it.
**Recommendation:** Skip orphan recovery during session restore, or defer it until after saved workers have been re-registered and compared against the snapshot. At minimum, make recovery consult persisted session metadata before deleting numeric worktree directories.
