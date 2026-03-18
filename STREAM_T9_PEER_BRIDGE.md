# Stream T9 — TD15 Swift Bridge: Peer Messaging

## Your branch
feat/v014-t9-peer-bridge

## Your worktree path
../teammux-stream-t9

## Read first
- CLAUDE.md — hard rules, build commands, sprint workflow
- TECH_DEBT.md — TD15 (worker-to-worker messaging) — engine side done by T2, you do Swift bridge
- V014_SPRINT.md — full sprint spec, Section 4 has your detailed scope

## WAIT CHECK
You MUST confirm T2 has been merged to main before starting implementation.
Run this command:
```
grep 'TM_MSG_PEER_QUESTION\|TM_MSG_DELEGATION\|tm_peer_question' \
  engine/include/teammux.h
```
If the grep returns no results, STOP — T2 has not merged yet. Wait for main thread to confirm.

## Your mission

**Files:** macos/Sources/Teammux/Models/CoordinationTypes.swift (extend), macos/Sources/Teammux/Engine/EngineClient.swift, macos/Sources/Teammux/RightPane/LiveFeedView.swift

**New types in CoordinationTypes.swift:**
```swift
struct PeerQuestion: Identifiable, Sendable {
    let id: UUID
    let fromWorkerId: UInt32
    let targetWorkerId: UInt32
    let message: String
    let timestamp: Date
}

struct PeerDelegation: Identifiable, Sendable {
    let id: UUID
    let fromWorkerId: UInt32
    let targetWorkerId: UInt32
    let task: String
    let timestamp: Date
}
```

**EngineClient additions (MARK: - Peer Messaging):**
```swift
@Published var peerQuestions: [UInt32: PeerQuestion] = [:]
@Published var peerDelegations: [PeerDelegation] = []

func clearPeerQuestion(fromWorkerId: UInt32)
```

Message callback handles TM_MSG_PEER_QUESTION and TM_MSG_DELEGATION.

**LiveFeedView peer question cards:** Worker {from} → Worker {target}: {message} with Relay button (calls engine.dispatchTask(workerId: targetWorkerId, instruction: message)) and Dismiss button (calls engine.clearPeerQuestion). Delegations appended to dispatchHistory with "Delegated" label.

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
Wave 2 — depends on T2 merged.
Note: T9, T10, T11 all extend CoordinationTypes.swift — pull main before implementing to avoid conflicts.

## Done when
- ./build.sh passes
- peerQuestions populated on TM_MSG_PEER_QUESTION
- Peer question cards visible in Feed tab
- Relay button calls dispatchTask correctly
- PR raised from feat/v014-t9-peer-bridge

## Core rules
- Never modify src/ (Ghostty upstream)
- All tm_* calls go through EngineClient.swift only
- No force-unwraps in production code
- ./build.sh must pass before raising PR (Swift stream)
- engine/include/teammux.h is the authoritative C API contract
- roles/ is local only — no external network fetching
- TECH_DEBT.md updated when new debt discovered
- Message type values: do NOT reuse or skip — check registry above
