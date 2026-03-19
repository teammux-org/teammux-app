# Stream T10 — TD16 Swift Bridge: Completion History

## Your branch
feat/v014-t10-history-bridge

## Your worktree path
../teammux-stream-t10

## Read first
- CLAUDE.md — hard rules, build commands, sprint workflow
- TECH_DEBT.md — TD16 (history not persisted) — engine side done by T5, you do Swift bridge
- V014_SPRINT.md — full sprint spec, Section 4 has your detailed scope

## WAIT CHECK
You MUST confirm T5 has been merged to main before starting implementation.
Run this command:
```
grep 'tm_history_load\|tm_history_free\|tm_history_entry_t' \
  engine/include/teammux.h
```
If the grep returns no results, STOP — T5 has not merged yet. Wait for main thread to confirm.

## Your mission

**Files:** macos/Sources/Teammux/Models/CoordinationTypes.swift (extend), macos/Sources/Teammux/Engine/EngineClient.swift, macos/Sources/Teammux/RightPane/LiveFeedView.swift

**New type in CoordinationTypes.swift:**
```swift
enum HistoryEntryType: String, Sendable, Codable { case completion, question }

struct HistoryEntry: Identifiable, Sendable {
    let id: UUID
    let type: HistoryEntryType
    let workerId: UInt32
    let roleId: String?
    let content: String
    let gitCommit: String?
    let timestamp: Date
}
```

**EngineClient additions (MARK: - Completion History):**
```swift
@Published var completionHistory: [HistoryEntry] = []
```

In sessionStart: call tm_history_load after engine init, bridge to [HistoryEntry], merge with live entries (live takes precedence for same worker).

**LiveFeedView history section:** Below active cards — "Show history (N)" toggle button. When expanded: ForEach completionHistory entries in greyed-out card style (.opacity(0.6)), sorted newest-first, max 50 shown with "Show more" if longer.

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
Wave 2 — depends on T5 merged.
Note: T9, T10, T11 all extend CoordinationTypes.swift — pull main before implementing to avoid conflicts.

## Done when
- ./build.sh passes
- completionHistory populated from JSONL on sessionStart
- History section appears in LiveFeedView with correct toggle
- PR raised from feat/v014-t10-history-bridge

## Core rules
- Never modify src/ (Ghostty upstream)
- All tm_* calls go through EngineClient.swift only
- No force-unwraps in production code
- ./build.sh must pass before raising PR (Swift stream)
- engine/include/teammux.h is the authoritative C API contract
- roles/ is local only — no external network fetching
- TECH_DEBT.md updated when new debt discovered
- Message type values: do NOT reuse or skip — check registry above
