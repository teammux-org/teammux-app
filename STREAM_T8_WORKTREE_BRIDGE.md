# Stream T8 — Worktree Lifecycle Swift Bridge

## Your branch
feat/v014-t8-worktree-bridge

## Your worktree path
../teammux-stream-t8

## Read first
- CLAUDE.md — hard rules, build commands, sprint workflow
- TECH_DEBT.md — TD21 (dangling worktrees) and TD22 (session restore ownership) are relevant
- V014_SPRINT.md — full sprint spec, Section 4 has your detailed scope

## WAIT CHECK
You MUST confirm T1 has been merged to main before starting implementation.
Run these commands:
```
git pull origin main
grep 'tm_worktree_create\|tm_worktree_path\|tm_worktree_branch' \
  engine/include/teammux.h
```
If the grep returns no results, STOP — T1 has not merged yet. Wait for main thread to confirm.

## Your mission

**Files:** macos/Sources/Teammux/Engine/EngineClient.swift, macos/Sources/Teammux/Workspace/WorkerRow.swift

**EngineClient additions (MARK: - Worktree Lifecycle):**
```swift
@Published var workerWorktrees: [UInt32: String] = [:]
@Published var workerBranches: [UInt32: String] = [:]
```

spawnWorker: call tm_worktree_create before tm_worker_spawn. Pass worktree path to SurfaceConfiguration.workingDirectory. On failure: log warning, spawn continues in project root (graceful degradation). Cache path and branch.

dismissWorker: call tm_worktree_remove after PTY closes. Remove from both dicts.

destroy(): removeAll() on both dicts.

**WorkerRow branch badge:** Below task description text:
```swift
if let branch = engine.workerBranches[worker.id] {
    Text(branch)
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .onTapGesture { NSPasteboard.general.setString(branch, forType: .string) }
}
```

## Message type registry (v0.1.4 additions)

Existing types (do not reuse):
- TM_MSG_TASK=0, TM_MSG_INSTRUCTION=1, TM_MSG_CONTEXT=2, TM_MSG_STATUS_REQ=3
- TM_MSG_STATUS_RPT=4, TM_MSG_COMPLETION=5, TM_MSG_ERROR=6, TM_MSG_BROADCAST=7
- TM_MSG_QUESTION=8, TM_MSG_DISPATCH=10, TM_MSG_RESPONSE=11

New in v0.1.4:
- TM_MSG_PEER_QUESTION = 12 (T2)
- TM_MSG_DELEGATION = 13 (T2)
- TM_MSG_PR_READY = 14 (T7)
- TM_MSG_PR_STATUS = 15 (T7)

## Merge order context
Wave 2 — depends on T1 merged.
T8 is a dependency for T12, T13, and T15.

## Done when
- ./build.sh passes
- spawnWorker calls tm_worktree_create, PTY cwd set to worktree
- dismissWorker calls tm_worktree_remove
- Branch badge visible in WorkerRow
- PR raised from feat/v014-t8-worktree-bridge

## Core rules
- Never modify src/ (Ghostty upstream)
- All tm_* calls go through EngineClient.swift only
- No force-unwraps in production code
- ./build.sh must pass before raising PR (Swift stream)
- engine/include/teammux.h is the authoritative C API contract
- roles/ is local only — no external network fetching
- TECH_DEBT.md updated when new debt discovered
- Message type values: do NOT reuse or skip — check registry above
