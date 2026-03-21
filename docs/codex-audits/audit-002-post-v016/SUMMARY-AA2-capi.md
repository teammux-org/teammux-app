## Domain
C API contracts and header hygiene

## Files Reviewed
- `engine/include/teammux.h`
- `engine/src/main.zig`
- Supporting verification: `engine/src/bus.zig`, `engine/src/merge.zig`, `engine/src/memory.zig`, `macos/Sources/Teammux/Engine/EngineClient.swift`

## Finding Counts (Critical / Important / Suggestion)
1 / 3 / 0

## Top 3 Findings
1. Unchecked `@enumFromInt(...)` in exported C entry points can panic the process on invalid runtime enum values.
2. `tm_worker_pty_died` and `tm_worker_monitor_pid` are implemented in `main.zig` but missing from `teammux.h`.
3. `tm_conflict_resolve` and `tm_conflict_finalize` return `TM_ERR_INVALID_WORKER` even for underlying Git failures, which breaks the documented error contract.

## Overall Health Assessment
The AA2 surface is mostly cleaner than the pre-TD29/TD30 state: the reserved `TM_ERR_PTY` path is not obviously reachable, the deprecated exports are annotated, and the new memory/history ownership contracts are documented and implemented consistently. The remaining issues are concentrated at the boundary itself: one crashable enum-conversion path, one missing-header drift for the PTY lifecycle exports, and two public contracts that report the wrong failure or version information. These should be fixed before the next release because they directly affect external callers and API correctness.
