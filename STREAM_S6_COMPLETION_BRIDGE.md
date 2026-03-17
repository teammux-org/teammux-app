# Stream S6 — TD13 Swift: Completion + Question Bridge

## Your branch
`feat/v013-stream-s6-completion-bridge`

## Your worktree path
`../teammux-stream-s6/`

## Read first
- `CLAUDE.md` — hard rules, build commands, sprint workflow
- `TECH_DEBT.md` — TD13 is your target (Swift half)
- `V013_SPRINT.md` — Section 3, stream-S6 scope

## Your mission

**Files to modify:** `macos/Sources/Teammux/Engine/EngineClient.swift`
**New file:** `macos/Sources/Teammux/Models/CoordinationTypes.swift`

**New Swift types (CoordinationTypes.swift):**
```swift
struct CompletionReport: Identifiable, Sendable {
    let id: UUID
    let workerId: UInt32
    let summary: String
    let gitCommit: String?
    let details: String?
    let timestamp: Date
}

struct QuestionRequest: Identifiable, Sendable {
    let id: UUID
    let workerId: UInt32
    let question: String
    let context: String?
    let timestamp: Date
}
```

**EngineClient additions (MARK: - Coordination):**
```swift
@Published var workerCompletions: [UInt32: CompletionReport] = [:]
@Published var workerQuestions: [UInt32: QuestionRequest] = [:]

func acknowledgeCompletion(workerId: UInt32)
func clearQuestion(workerId: UInt32)
```

**Message callback extension:**
When `tm_message_cb` fires with `TM_MSG_COMPLETION` or `TM_MSG_QUESTION`,
parse the payload JSON, bridge to Swift type, update the respective
`@Published` dict on `@MainActor`. Follows existing Unmanaged +
Task @MainActor callback pattern.

**Tests:** CompletionReport field access, QuestionRequest fields,
EngineClient initial state empty, acknowledgement clears entry.

## WAIT CHECK
Confirm S2 has merged to main before starting implementation:
```bash
git pull origin main
grep "TM_MSG_COMPLETION\|TM_MSG_QUESTION\|tm_worker_complete" \
  engine/include/teammux.h
```
If those symbols are not present, S2 has not merged yet — wait.

## Merge order context
S6 is in **Wave 2**. Depends on S2 merging first.
S10 depends on S6 merging (S10 builds the UI cards for completions/questions).

**Important:** S8 also creates/extends `CoordinationTypes.swift`. If S6 merges
first, S8 should extend the file rather than duplicating it.

## Done when
- `./build.sh` passes
- PR raised from `feat/v013-stream-s6-completion-bridge`

## Core rules
- NEVER modify `src/` (Ghostty upstream)
- ALL `tm_*` calls go through `EngineClient.swift` only
- NO force-unwraps in production code
- `./build.sh` must pass before raising PR
- TECH_DEBT.md updated when new debt discovered
