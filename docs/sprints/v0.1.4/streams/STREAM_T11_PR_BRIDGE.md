# Stream T11 — PR Workflow Swift Bridge

## Your branch
feat/v014-t11-pr-bridge

## Your worktree path
../teammux-stream-t11

## Read first
- CLAUDE.md — hard rules, build commands, sprint workflow
- TECH_DEBT.md — no specific TD, bridges T7's PR engine types to Swift
- V014_SPRINT.md — full sprint spec, Section 4 has your detailed scope

## WAIT CHECK
You MUST confirm T7 has been merged to main before starting implementation.
Run this command:
```
grep 'TM_MSG_PR_READY\|TM_MSG_PR_STATUS\|tm_pr_create' \
  engine/include/teammux.h
```
If the grep returns no results, STOP — T7 has not merged yet. Wait for main thread to confirm.

## Your mission

**Files:** macos/Sources/Teammux/Models/CoordinationTypes.swift (extend), macos/Sources/Teammux/Engine/EngineClient.swift, macos/Sources/Teammux/RightPane/GitView.swift

**New types in CoordinationTypes.swift:**
```swift
enum PRStatus: String, Sendable, Codable { case open, merged, closed }

struct PREvent: Identifiable, Sendable {
    let id: UUID
    let workerId: UInt32
    let branchName: String
    let prUrl: String
    let title: String
    var status: PRStatus
    let timestamp: Date
}
```

**EngineClient additions (MARK: - PR Workflow):**
```swift
@Published var workerPRs: [UInt32: PREvent] = [:]
```

Handles TM_MSG_PR_READY (creates PREvent) and TM_MSG_PR_STATUS (updates status on existing PREvent).

**GitView PR section:** At top of Git tab when workerPRs non-empty. Per-worker PR card showing: status badge (green/purple/grey), title, branch name, Approve button (engine.approveMerge), Reject button (engine.rejectMerge), "Open in GitHub" link (NSWorkspace.shared.open). Section hidden when workerPRs is empty.

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
Wave 2 — depends on T7 merged.
Note: T9, T10, T11 all extend CoordinationTypes.swift — pull main before implementing to avoid conflicts.
T11 is a dependency for T15.

## Done when
- ./build.sh passes
- workerPRs populated on TM_MSG_PR_READY
- Status updated on TM_MSG_PR_STATUS
- PR section appears in Git tab
- Approve/Reject wired to existing MergeCoordinator flow
- PR raised from feat/v014-t11-pr-bridge

## Core rules
- Never modify src/ (Ghostty upstream)
- All tm_* calls go through EngineClient.swift only
- No force-unwraps in production code
- ./build.sh must pass before raising PR (Swift stream)
- engine/include/teammux.h is the authoritative C API contract
- roles/ is local only — no external network fetching
- TECH_DEBT.md updated when new debt discovered
- Message type values: do NOT reuse or skip — check registry above
