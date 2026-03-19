# Stream T14 — Fully Autonomous Team Lead Dispatch

## Your branch
feat/v014-t14-autonomous-dispatch

## Your worktree path
../teammux-stream-t14

## Read first
- CLAUDE.md — hard rules, build commands, sprint workflow
- TECH_DEBT.md — no specific TD, new autonomous dispatch feature
- V014_SPRINT.md — full sprint spec, Section 4 has your detailed scope

## WAIT CHECK
You MUST confirm BOTH T9 AND T10 have been merged to main before starting implementation.
Run these commands:
```
grep 'peerQuestions\|clearPeerQuestion' \
  macos/Sources/Teammux/Engine/EngineClient.swift
grep 'completionHistory' \
  macos/Sources/Teammux/Engine/EngineClient.swift
```
Both greps must return results. If either returns nothing, STOP — the dependency has not merged yet.

## Your mission

**Files:** macos/Sources/Teammux/Models/CoordinationTypes.swift (extend), macos/Sources/Teammux/Engine/EngineClient.swift, macos/Sources/Teammux/RightPane/DispatchView.swift

**New type in CoordinationTypes.swift:**
```swift
struct AutonomousDispatch: Identifiable, Sendable {
    let id: UUID
    let workerId: UInt32
    let instruction: String
    let triggerSummary: String
    let timestamp: Date
}
```

**EngineClient additions (MARK: - Autonomous Dispatch):**
```swift
@Published var autonomousDispatches: [UInt32: AutonomousDispatch] = [:]

private func triggerAutonomousDispatch(for completion: CompletionReport)
private func suggestFollowUp(completion: CompletionReport, role: RoleDefinition?) -> String
```

suggestFollowUp heuristics (deterministic, no LLM):
- "implement"/"built"/"added" → "Review the implementation and write tests"
- "fix"/"bug"/"patch" → "Verify the fix resolves the issue and add a regression test"
- "refactor"/"restructure" → "Verify all existing tests pass after the refactor"
- "test"/"spec" → "Review test coverage and identify any gaps"
- fallback → "Review the completed work and confirm it meets requirements"

triggerAutonomousDispatch called immediately when workerCompletions[workerId] is set (in handleCompletionMessage). No human step, no cancel window per confirmed design. Calls engine.dispatchTask immediately.

**DispatchView history:** Auto-dispatches shown with "Auto" badge in .secondary color alongside manual dispatches.

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
Wave 3 — depends on T9 AND T10 both merged.
Note: T14 calls engine.dispatchTask which requires T8's worktree bridge — but T9 depends on T2, and T10 depends on T5, so by the time T9+T10 are merged, T8 will also be merged.

## Done when
- ./build.sh passes
- On completion signal, follow-up dispatched immediately
- Auto badge visible in DispatchView history
- No human approval step
- PR raised from feat/v014-t14-autonomous-dispatch

## Core rules
- Never modify src/ (Ghostty upstream)
- All tm_* calls go through EngineClient.swift only
- No force-unwraps in production code
- ./build.sh must pass before raising PR (Swift stream)
- engine/include/teammux.h is the authoritative C API contract
- roles/ is local only — no external network fetching
- TECH_DEBT.md updated when new debt discovered
- Message type values: do NOT reuse or skip — check registry above
