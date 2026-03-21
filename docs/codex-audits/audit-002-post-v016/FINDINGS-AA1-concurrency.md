## Finding 1-1: Health monitor reads `cfg` concurrently with `tm_config_reload`
**Severity:** CRITICAL
**File:** engine/src/main.zig:511
**Description:** `healthMonitorLoop()` dereferences the raw pointer returned by `cfgPtr()` on a background thread to parse `stall_threshold_secs`, while `tm_config_reload()` later frees the current `Config` in place and overwrites `e.cfg` with no mutex or snapshot handoff. Because `cfgPtr()` exposes inline engine storage directly, a reload that overlaps the monitor thread's startup window can free the same config data that `config.get()` is still reading.
**Risk:** A supported `tm_config_reload()` call can race the health-monitor thread and trigger use-after-free or corrupted reads, producing crashes or an invalid stall threshold in production.
**Recommendation:** Make config access thread-safe. The smallest fix is to snapshot `stall_threshold_secs` on the main thread before spawning the health monitor and update that snapshot under a dedicated mutex or atomic on reload; a broader fix is to guard all `e.cfg` reads/writes with a config mutex and never return raw pointers to mutable inline storage across threads.

## Finding 1-2: Failed `tm_session_start` leaves a live history writer attached to inline engine state
**Severity:** CRITICAL
**File:** engine/src/main.zig:350
**Description:** `sessionStart()` commits `self.history_logger` and starts its background writer before the last hard-fail step, `tm_interceptor_install()` (`engine/src/main.zig:372`). `HistoryLogger.startWriter()` spawns the writer with `self` pointing at the inline `Engine.history_logger` storage (`engine/src/history.zig:167-170`). If interceptor installation fails, `tm_session_start()` returns an error without shutting that writer down or rolling back the committed fields. A retry on the same engine then overwrites `self.history_logger` in place while the orphaned writer thread still holds a pointer to it.
**Risk:** A failed session start can leave background state running after an error return, and retrying the start on the same engine can create a data race against the orphaned writer thread, with undefined behavior ranging from corrupted queue state to crashes.
**Recommendation:** Do not publish `history_logger` into `self` until all hard-fail startup work has succeeded, or explicitly rollback on every post-commit failure by calling `shutdown()` and clearing the committed optionals before returning. Also reject repeated `tm_session_start()` calls unless the previous session has been fully stopped.

## Finding 1-3: `PtyMonitor` allows stale PID registrations to clobber restarted workers
**Severity:** IMPORTANT
**File:** engine/src/main.zig:55
**Description:** `tm_worker_monitor_pid()` inserts a fresh `pid -> worker_id` mapping every time it is called, but `unwatch(worker_id)` removes only the first matching PID for that worker and `handlePtyDied()` later calls `unwatch(worker_id)` rather than removing the specific dead PID. Because `tm_worker_restart()` reuses the same `worker_id`, a late death notification for an old PID can arrive after a respawn, mark the worker errored again, and then remove monitoring for the new live PID.
**Risk:** Restarted workers can be flipped back to `.err`, have ownership released unexpectedly, and lose PTY crash monitoring for the replacement process, leaving the engine with stale worker state and missed future crash detection.
**Recommendation:** Enforce a one-to-one worker-to-PID mapping by removing any existing registration for `worker_id` before inserting a new PID, and make death handling remove by PID or generation token rather than by `worker_id` alone.
