## Domain
AA5 — Message bus and coordination new v0.1.6 paths

## Files Reviewed
- `engine/src/bus.zig`
- `engine/src/coordinator.zig`
- `engine/src/commands.zig`
- `engine/src/main.zig`
- `engine/src/github.zig`
- `engine/src/worktree.zig`
- `engine/src/ownership.zig`
- `macos/Sources/Teammux/Engine/EngineClient.swift`
- `macos/Sources/Teammux/Models/TeamMessage.swift`
- `macos/Sources/Teammux/Models/WorkerInfo.swift`
- `macos/Sources/Teammux/Workspace/WorkerRow.swift`
- `macos/Sources/Teammux/Workspace/WorkerDetailDrawer.swift`

## Finding Counts (Critical / Important / Suggestion)
0 / 3 / 1

## Top 3 Findings
1. Callback-routed `/teammux-*` command failures are still treated as success, so the watcher deletes the original file without writing `.teammux-error`.
2. PTY death reconciliation never sets `health_status = .errored`, leaving the v0.1.6 health model and restart affordance out of sync with crashed workers.
3. `.teammux-error` persists indefinitely after a failure, so stale error payloads can bleed into later commands or later sessions.

## Overall Health Assessment
The reviewed v0.1.6 bus and coordination paths are mostly sound on retry termination, PR-vs-non-PR retry selection, one-shot stall firing, and teardown ordering. The main gaps are around error-surface semantics: command-file failures are not propagated consistently, PTY death does not fully update the health model, and one of the PR delivery diagnostics is downgraded before Swift can read it. These are reliability/correctness issues rather than memory-safety issues, but they are user-visible enough that the three IMPORTANT findings should be addressed in the next sprint.
