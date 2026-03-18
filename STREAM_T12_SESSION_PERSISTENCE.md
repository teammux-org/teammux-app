# Stream T12 — Persistent Session State

## Your branch
feat/v014-t12-session-persistence

## Your worktree path
../teammux-stream-t12

## Read first
- CLAUDE.md — hard rules, build commands, sprint workflow
- TECH_DEBT.md — TD22 (session restore ownership) is relevant new debt
- V014_SPRINT.md — full sprint spec, Section 4 has your detailed scope

## WAIT CHECK
You MUST confirm T8 has been merged to main before starting implementation.
Run this command:
```
grep 'workerWorktrees\|workerBranches\|tm_worktree_path' \
  macos/Sources/Teammux/Engine/EngineClient.swift
```
If the grep returns no results, STOP — T8 has not merged yet. Wait for main thread to confirm.

## Your mission

**New file:** macos/Sources/Teammux/Session/SessionState.swift

**Snapshot types (all Codable):**
```swift
struct WorkerSnapshot: Codable {
    let id: UInt32; let name: String; let roleId: String?
    let taskDescription: String; let worktreePath: String; let branchName: String
}
struct SessionSnapshot: Codable {
    let projectPath: String; let timestamp: Date
    let workers: [WorkerSnapshot]
    let completionHistoryEntries: [HistoryEntrySnapshot]
    let dispatchHistoryEntries: [DispatchEventSnapshot]
    let workerPRs: [String: PREventSnapshot]
}
```

**Persistence path:** ~/.teammux/sessions/{SHA256(projectPath)}.json

**Save triggers:** applicationWillResignActive + applicationWillTerminate via AppDelegate. Encodes current engine state.

**Load trigger:** SetupView project selection. If session file exists, show "Restore previous session" card: N workers, last saved timestamp, role list. "Restore" button and "Start fresh" button.

**Restore sequence:** For each WorkerSnapshot, call spawnWorker with worktreePath override parameter (skips tm_worktree_create, uses saved path). If worktree path missing on disk: skip worker, show warning banner. Load completion and dispatch history into engine.

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
Wave 2 — depends on T8 merged.

## Done when
- ./build.sh passes
- Session saved on app resign/terminate
- SetupView shows restore card when session exists
- Workers restored with correct roles and worktree paths
- Missing worktrees skipped with warning
- PR raised from feat/v014-t12-session-persistence

## Core rules
- Never modify src/ (Ghostty upstream)
- All tm_* calls go through EngineClient.swift only
- No force-unwraps in production code
- ./build.sh must pass before raising PR (Swift stream)
- engine/include/teammux.h is the authoritative C API contract
- roles/ is local only — no external network fetching
- TECH_DEBT.md updated when new debt discovered
- Message type values: do NOT reuse or skip — check registry above
