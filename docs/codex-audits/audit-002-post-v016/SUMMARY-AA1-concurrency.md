## Domain
Concurrency & Memory Safety

## Files Reviewed
- `engine/src/coordinator.zig`
- `engine/src/history.zig`
- `engine/src/main.zig`
- `engine/src/worktree.zig`
- `engine/src/ownership.zig`
- `engine/src/interceptor.zig`

## Finding Counts (Critical / Important / Suggestion)
2 / 1 / 0

## Top 3 Findings
1. `engine/src/main.zig:511` exposes a real use-after-free race between the health monitor thread and `tm_config_reload()`.
2. `engine/src/main.zig:350` publishes and starts the inline history writer before the last hard-fail startup step, so a failed `tm_session_start()` can leave a live writer thread behind.
3. `engine/src/main.zig:55` lets old PTY PID registrations survive restarts, so late death notifications can re-error a recovered worker and drop monitoring for the new PID.

## Overall Health Assessment
The v0.1.6 concurrency work shows good discipline around roster locking, background-thread join paths, and keeping file I/O outside queue locks. The remaining issues are concentrated in lifecycle edges: one unsynchronized config access, one failed-start rollback gap that can leave an inline writer thread alive, and one PTY monitor design bug around PID replacement. Two of the three findings can reach memory-unsafe behavior, so the domain is not release-ready without follow-up fixes.
