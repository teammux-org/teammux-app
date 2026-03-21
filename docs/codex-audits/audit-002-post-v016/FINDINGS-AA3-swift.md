## Finding 3-1: Restart button clears health without recreating the worker PTY
**Severity:** CRITICAL
**File:** macos/Sources/Teammux/Workspace/WorkerDetailDrawer.swift:132
**Description:** The new `Restart Worker` button calls `engine.restartWorker(id:)` directly, but the shipped bridge and C header both document `tm_worker_restart` as a post-respawn health reset only, not a PTY restart. `EngineClient.restartWorker` just forwards to `tm_worker_restart` and refreshes the roster; it does not tear down the old surface, create a new worker terminal, or re-register any PTY lifecycle data first. A repo-wide search also shows no Swift caller for `tm_worker_monitor_pid` or `tm_worker_pty_died`, so the new health UI is not backed by a Swift-side restart path.
**Risk:** A dead or stalled worker can be marked healthy while its terminal process is still gone. That hides the failure from the roster/drawer and lets later recovery or dispatch attempts target a worker that never actually came back.
**Recommendation:** Move restart into the workspace terminal layer: tear down the old worker surface, create a replacement Ghostty surface for the same worktree, register PTY monitoring for the new process, and only then call `engine.restartWorker`. Until that exists, disable or remove the button.

## Finding 3-2: CLEANUP_INCOMPLETE warnings are attached to views that disappear before the user can read them
**Severity:** IMPORTANT
**File:** macos/Sources/Teammux/RightPane/GitView.swift:245
**Description:** The TD38 follow-up checks `engine.lastError` on success, but the warning is stored in local `@State` on transient subviews. In `GitWorkerRow`, a partial-success approve/reject immediately changes the worker to a terminal merge state, so the row drops out of `activeWorkers` before its `cleanupWarning` banner can render. In `ConflictView`, `cleanupWarning` is also local state, but the parent `GitWorkerRow` closes the sheet as soon as `mergeStatus` leaves `.conflict`, which dismisses the warning on finalize/reject partial-success paths.
**Risk:** The user still misses "manual cleanup may be needed" warnings, so leftover worktrees/branches can accumulate even though the UI appears to have handled the operation cleanly.
**Recommendation:** Hoist cleanup warnings into stable state owned by `EngineClient` or `GitView` and render them from a container that survives row reclassification and sheet dismissal, such as a per-worker banner in the main Git list or a shared toast/alert.

## Finding 3-3: New conflict-resolution and restart actions still run synchronous engine work on the MainActor
**Severity:** IMPORTANT
**File:** macos/Sources/Teammux/RightPane/ConflictView.swift:145
**Description:** `ConflictView.resolve`, `finalizeMerge`, and `reject` all wrap their work in `Task { @MainActor in ... }`, and `WorkerDetailDrawer` calls `engine.restartWorker(id:)` straight from the button action. Because `EngineClient` itself is `@MainActor` and its merge/restart methods are synchronous C-FFI calls, these new views still execute git/merge/restart work on the UI actor. The spinners make the flow look asynchronous, but the heavy work is not actually leaving the main thread.
**Risk:** Finalize/reject/resolve operations can freeze the app while git work runs, making the new recovery/conflict UI feel hung and delaying other UI updates exactly when the user needs feedback.
**Recommendation:** Move long-running bridge calls behind nonisolated/background wrappers and hop back to `MainActor` only to publish results. At minimum, keep the state mutation on `MainActor` but perform the FFI call itself off the UI actor.

## Finding 3-4: Memory timeline parsing corrupts entries when saved markdown contains headings
**Severity:** IMPORTANT
**File:** macos/Sources/Teammux/RightPane/ContextView.swift:461
**Description:** `parseMemoryEntries(_:)` treats every line beginning with `## ` as a new entry header and every line beginning with `# ` as the file header to skip. The v0.1.6 memory pipeline stores completion summaries/details as raw markdown body text, so ordinary content like `## Follow-ups`, `# Notes`, or fenced examples containing heading-like lines is reinterpreted as structure instead of body text.
**Risk:** The new memory timeline can invent fake entries, show non-timestamp strings as timestamps, or silently drop parts of a worker's persisted memory when completions include markdown headings.
**Recommendation:** Parse only real entry headers, e.g. `##` lines matching the expected ISO-8601 timestamp format, and keep all other headings/body lines inside the current entry. A more robust fix is to persist structured entries instead of reparsing markdown in Swift.
