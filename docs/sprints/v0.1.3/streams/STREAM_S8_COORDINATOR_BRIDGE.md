# Stream S8 — Team Lead Dispatch Swift Bridge

## Your branch
`feat/v013-stream-s8-coordinator-bridge`

## Your worktree path
`../teammux-stream-s8/`

## Read first
- `CLAUDE.md` — hard rules, build commands, sprint workflow
- `TECH_DEBT.md` — current debt items
- `V013_SPRINT.md` — Section 3, stream-S8 scope

## Your mission

**Files to modify:** `macos/Sources/Teammux/Engine/EngineClient.swift`
**Extend file:** `macos/Sources/Teammux/Models/CoordinationTypes.swift`
  (S6 creates this file — extend it, do not duplicate)

**EngineClient additions (MARK: - Coordinator):**
```swift
@Published var dispatchHistory: [DispatchEvent] = []

func dispatchTask(workerId: UInt32, instruction: String) -> Bool
func dispatchResponse(workerId: UInt32, response: String) -> Bool
```

**New Swift type (add to CoordinationTypes.swift):**
```swift
struct DispatchEvent: Identifiable, Sendable {
    let id: UUID
    let targetWorkerId: UInt32
    let instruction: String
    let timestamp: Date
    let delivered: Bool
}
```

Wraps `tm_dispatch_task` and `tm_dispatch_response`. On success, appends
to `dispatchHistory`. History capped at 100 items (trim oldest).

**Tests:** dispatchTask returns Bool, history populated, cap enforced.

## WAIT CHECK
Confirm S5 has merged to main before starting implementation:
```bash
git pull origin main
grep "tm_dispatch_task\|tm_dispatch_response" engine/include/teammux.h
```
If those symbols are not present, S5 has not merged yet — wait.

**Also confirm S6 has merged** (for CoordinationTypes.swift):
```bash
ls macos/Sources/Teammux/Models/CoordinationTypes.swift
```
If the file exists, extend it. If not, create it (but S6 should merge first).

## Merge order context
S8 is in **Wave 2**. Depends on S5 merging first.
S11 depends on S8 merging (S11 builds the Dispatch tab UI).

**Important:** S6 also creates `CoordinationTypes.swift`. Coordinate so you
extend that file rather than overwriting it.

## Done when
- `./build.sh` passes
- PR raised from `feat/v013-stream-s8-coordinator-bridge`

## Core rules
- NEVER modify `src/` (Ghostty upstream)
- ALL `tm_*` calls go through `EngineClient.swift` only
- NO force-unwraps in production code
- `./build.sh` must pass before raising PR
- TECH_DEBT.md updated when new debt discovered
