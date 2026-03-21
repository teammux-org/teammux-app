## Domain
Integration correctness — cross-module interactions introduced in v0.1.6.

## Files Reviewed
- `engine/src/merge.zig`
- `engine/src/coordinator.zig`
- `engine/src/history.zig`
- `engine/src/bus.zig`
- `engine/src/memory.zig`
- `engine/src/worktree_lifecycle.zig`
- `engine/src/main.zig`
- `macos/Sources/Teammux/Engine/EngineClient.swift`
- `macos/Sources/Teammux/Setup/SetupView.swift`
- `macos/Sources/Teammux/Session/SessionState.swift`
- `macos/Sources/Teammux/Workspace/RosterView.swift`
- `macos/Sources/Teammux/Workspace/WorkerDetailDrawer.swift`
- `macos/Sources/Teammux/RightPane/ContextView.swift`

## Finding Counts (Critical / Important / Suggestion)
1 / 3 / 0

## Top 3 Findings
1. `sessionStart()` crash recovery can delete legitimate saved-session worktrees before `restoreSession()` runs, causing restore-time data loss.
2. Generic worker dismiss bypasses `MergeCoordinator` cleanup, leaving conflicted merge state stranded and future merges blocked.
3. Completion/question events stop being written to `completion_history.jsonl` when bus delivery exhausts retries, despite the documented persistence contract.

## Overall Health Assessment
Most AA6 boundaries are structurally sound: the health monitor correctly skips dead workers for stall notifications, and missing memory files themselves are handled gracefully. The major failures appear at lifecycle boundaries, where independently reasonable modules are composed in the wrong order or with incomplete state reconciliation. The restore-path crash-recovery bug is release-blocking because it can delete legitimate worker state; the remaining three findings are important workflow-correctness issues that can wedge merge operations, desynchronize PTY/health state, or silently lose completion-history records under delivery failure.
