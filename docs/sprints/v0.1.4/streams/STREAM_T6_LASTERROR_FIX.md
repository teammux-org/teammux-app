# Stream T6 — TD20: EngineClient lastError Refactor

## Your branch
feat/v014-t6-lasterror-fix

## Your worktree path
../teammux-stream-t6

## Read first
- CLAUDE.md — hard rules, build commands, sprint workflow
- TECH_DEBT.md — TD20 is your target (lastError stale state)
- V014_SPRINT.md — full sprint spec, Section 4 has your detailed scope

## Your mission

**Files:** macos/Sources/Teammux/Models/EngineError.swift (new), macos/Sources/Teammux/Engine/EngineClient.swift, macos/Sources/Teammux/RightPane/DispatchView.swift, macos/Sources/Teammux/RightPane/GitView.swift, macos/Sources/Teammux/RightPane/QuestionCardView.swift

**New EngineError.swift:**
```swift
enum EngineError: LocalizedError {
    case engineNotStarted
    case workerNotFound(UInt32)
    case dispatchFailed(String)
    case mergeFailed(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .engineNotStarted: return "Engine not started"
        case .workerNotFound(let id): return "Worker \(id) not found"
        case .dispatchFailed(let msg): return "Dispatch failed: \(msg)"
        case .mergeFailed(let msg): return "Merge failed: \(msg)"
        case .unknown(let msg): return msg
        }
    }
}
```

**EngineClient fix:** At entry of every method that sets lastError, add `self.lastError = nil`. Guarantees lastError is always fresh. Bool return type preserved — no method signature changes.

**View fixes:** DispatchView DispatchWorkerRow, GitView, QuestionCardView — add @State private var operationError: String? cleared at operation start. Read engine.lastError immediately after the call returns false and store locally. Do NOT rely on reading lastError after any async boundary.

**Tests:** operationError cleared on retry, stale error from previous call does not persist, multiple rapid calls each see fresh lastError.

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
Wave 1 (parallel) — you can START NOW, no dependencies.
T1-T7 merge first, then Wave 2 (T8-T12), Wave 3 (T13-T15), T16 last.

## Done when
- ./build.sh passes
- All methods that set lastError clear it at entry
- View local error states cleared correctly on retry
- PR raised from feat/v014-t6-lasterror-fix

## Core rules
- Never modify src/ (Ghostty upstream)
- All tm_* calls go through EngineClient.swift only
- No force-unwraps in production code
- ./build.sh must pass before raising PR (Swift stream)
- engine/include/teammux.h is the authoritative C API contract
- roles/ is local only — no external network fetching
- TECH_DEBT.md updated when new debt discovered
- Message type values: do NOT reuse or skip — check registry above
