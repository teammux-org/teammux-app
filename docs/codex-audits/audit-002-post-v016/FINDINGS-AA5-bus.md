## Finding 5-01: Callback-routed `/teammux-*` failures are still deleted silently
**Severity:** IMPORTANT
**File:** engine/src/commands.zig:249
**Description:** `CommandWatcher.processFile()` treats the generic command callback as infallible and deletes the original `.json` file afterward. That callback has a `void` signature, so internal handlers reached through `commandRoutingCallback()` can only log and return on failure. In the reviewed codepaths, blocked or invalid `/teammux-assign`, `/teammux-ask`, `/teammux-delegate`, and `/teammux-pr-ready` commands never go through `writeErrorResponse()` or `notifyError()`, but the watcher still treats them as successfully processed and removes the source file.
**Risk:** Worker and Team Lead coordination commands can disappear with no `.teammux-error` file and no surfaced engine error, recreating the silent-failure class that I6 was supposed to close for callback-routed commands.
**Recommendation:** Change the generic callback contract so it can report success vs failure back to `CommandWatcher`, and only delete the original command file on explicit success. For internal handler failures, route through the same `.teammux-error` and `error_cb` path used for parse and bus-routing failures.

## Finding 5-02: PTY death never marks worker health as `errored`
**Severity:** IMPORTANT
**File:** engine/src/coordinator.zig:158
**Description:** `ptyDiedCallback()` updates `w.status` to `.err` and releases ownership, but it leaves `w.health_status` unchanged. The v0.1.6 health UI and restart affordance are keyed off `health_status`, not `status`, so a worker whose PTY died can remain `healthy` in the health model even after reconciliation succeeds.
**Risk:** Dead workers can miss the red health indicator and the restart affordance, making PTY crashes harder to notice and recover from in production.
**Recommendation:** Set `w.health_status = .errored` as part of PTY-death reconciliation and add a regression test that exercises the full PTY-death path through roster health state.

## Finding 5-03: `.teammux-error` is never cleared after failures
**Severity:** IMPORTANT
**File:** engine/src/commands.zig:99
**Description:** Error responses are always written to a fixed `.teammux-error` filename, but there is no cleanup on watcher startup and no success-path cleanup after a later command is processed correctly. Once written, the old error payload stays in the commands directory until some later failure overwrites it.
**Risk:** Workers can observe stale error state after an engine restart or after subsequent successful commands and misattribute an old failure to the current command/session.
**Recommendation:** Remove `.teammux-error` when the watcher starts and after successful command processing, or version error responses per command and clean them up after acknowledgement.

## Finding 5-04: PR status delivery diagnostics are overwritten with a generic error
**Severity:** SUGGESTION
**File:** engine/src/main.zig:403
**Description:** On a PR status delivery failure, `MessageBus.send()` already calls `error_notify_cb` with a specific message that includes the message type and worker ID. `busSendBridge()` then immediately overwrites `lastError` with the generic string `"bus message delivery failed after retries exhausted"`. That loses the I13-specific context for `TM_MSG_PR_STATUS` failures.
**Risk:** When PR status delivery fails, Swift loses the worker/message-specific diagnostic that was added for recovery and debugging, which makes failures harder to correlate to the affected worker.
**Recommendation:** Preserve the detailed `lastError` set by `error_notify_cb`, or only set the generic bridge error when no bus-specific error has already been recorded.
