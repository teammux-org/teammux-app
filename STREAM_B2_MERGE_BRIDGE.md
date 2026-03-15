# Teammux v0.1.1 — Stream B2: MergeCoordinator Swift Bridge

## Your branch
feat/v011-stream-b2-merge-bridge

## Your worktree
../teammux-stream-b2

## Read first
Read V011_SPRINT.md Section 3 (stream-B2) and TECH_DEBT.md
(TD6) before doing anything else.
Read macos/Sources/Teammux/Engine/EngineClient.swift — you
are extending this file only.
Read engine/include/teammux.h on main AFTER stream-B1 merges —
the 5 new tm_merge_* functions must be present before you start.

## Your mission
Bridge the MergeCoordinator C API into Swift. Resolve TD6.
No UI. No view files. EngineClient.swift only.

### EngineClient.swift additions
Wrap all 5 tm_merge_* functions following the exact same
patterns already established in EngineClient.swift:
- C callback threading: Unmanaged.passUnretained + Task @MainActor
- Error handling: guard tm_result == TM_OK else { log, return false }
- @Published properties updated on main actor only

New @Published properties:
  @Published var mergeStatuses: [UInt32: MergeStatus] = [:]
  @Published var pendingConflicts: [UInt32: [ConflictInfo]] = [:]

New Swift types (add to Models/ or inline in EngineClient):
  enum MergeStatus matching tm_merge_status_e
  enum MergeStrategy { case merge, rebase }
  struct ConflictInfo matching tm_conflict_t fields

New methods:
  func approveMerge(workerId: UInt32, strategy: MergeStrategy) -> Bool
  func rejectMerge(workerId: UInt32) -> Bool
  func getMergeStatus(workerId: UInt32) -> MergeStatus
  func getConflicts(workerId: UInt32) -> [ConflictInfo]

## Depends on
stream-B1 must be merged before you begin implementation.
Your first action: git pull origin main, then confirm
tm_merge_approve and the 4 other functions exist in
engine/include/teammux.h before writing a single line.

## Merge order
After B1 is merged. stream-C1 depends on your EngineClient
additions. Merge promptly after approval.

## Done when
- ./build.sh passes end to end (Swift compiles with new methods)
- All 5 tm_merge_* functions wrapped in EngineClient.swift
- New @Published properties reactive to engine state
- EngineClient unit tests cover new merge methods
- No force-unwraps, no direct tm_* calls outside EngineClient
- PR raised, all checks pass

## Core rules
- Never modify src/
- EngineClient.swift is your only file
- No UI changes — stream-C1 owns the UI
- No tm_* calls anywhere outside EngineClient.swift
