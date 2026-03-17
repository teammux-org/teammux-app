# Stream S7 — Role Hot-Reload Swift Bridge

## Your branch
`feat/v013-stream-s7-hot-reload-bridge`

## Your worktree path
`../teammux-stream-s7/`

## Read first
- `CLAUDE.md` — hard rules, build commands, sprint workflow
- `TECH_DEBT.md` — TD10 context (engine half done by S4)
- `V013_SPRINT.md` — Section 3, stream-S7 scope

## Your mission

**Files to modify:** `macos/Sources/Teammux/Engine/EngineClient.swift`,
`macos/Sources/Teammux/Workspace/WorkerTerminalView.swift`

**EngineClient additions (MARK: - Role Hot-Reload):**
```swift
@Published var hotReloadedWorkers: Set<UInt32> = []

private func startRoleWatch(workerId: UInt32)
private func stopRoleWatch(workerId: UInt32)
```

`startRoleWatch` calls `tm_role_watch` with a callback that:
1. Receives new CLAUDE.md content as `new_claude_md`
2. Injects it into the worker's PTY via `injectText`:
   `\n[Teammux] role-update: Your role definition has been updated.\n{new_claude_md}\n`
3. Adds workerId to `hotReloadedWorkers` set
4. After 3 seconds, removes from set (transient notification)

`startRoleWatch` called from `spawnWorker` after ownership registration
when roleId is non-nil. `stopRoleWatch` called from `dismissWorker`.

**WorkerTerminalView addition:**
Subtle banner overlay when `engine.hotReloadedWorkers.contains(worker.id)`:
"Role updated — context refreshed" — same pattern as review pending banner.
Auto-dismisses after 3 seconds.

**Tests:** hotReloadedWorkers populated on callback, cleared after timeout.

## WAIT CHECK
Confirm S4 has merged to main before starting implementation:
```bash
git pull origin main
grep "tm_role_watch\|tm_role_unwatch" engine/include/teammux.h
```
If those symbols are not present, S4 has not merged yet — wait.

## Merge order context
S7 is in **Wave 2**. Depends on S4 merging first.
No downstream streams depend on S7 directly (S12 depends on S9+S10+S11).

## Done when
- `./build.sh` passes
- PR raised from `feat/v013-stream-s7-hot-reload-bridge`

## Core rules
- NEVER modify `src/` (Ghostty upstream)
- ALL `tm_*` calls go through `EngineClient.swift` only
- NO force-unwraps in production code
- `./build.sh` must pass before raising PR
- TECH_DEBT.md updated when new debt discovered
