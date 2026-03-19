# Teammux v0.1.1 — Stream C1: Team Lead Review UI

## Your branch
feat/v011-stream-c1-review-ui

## Your worktree
../teammux-stream-c1

## Read first
Read V011_SPRINT.md Section 3 (stream-C1) and TECH_DEBT.md
(TD7) before doing anything else.
Read macos/Sources/Teammux/RightPane/GitView.swift — your
primary existing file to extend.
Read macos/Sources/Teammux/Engine/EngineClient.swift on main
AFTER stream-B2 merges — mergeStatuses and pendingConflicts
must be present before you start.

## Your mission
Elevate GitView.swift to a full Team Lead review surface.
Ship the Team Lead review workflow. Resolve TD7.

### Files to modify
macos/Sources/Teammux/RightPane/GitView.swift — extend with
approve/reject buttons, merge status indicators, history section.

### Files to create
macos/Sources/Teammux/RightPane/ConflictView.swift — new view
that appears when engine.pendingConflicts[workerId] is non-empty.

### Worker branch row additions
Each active worker branch row in GitView gets:
- Approve button → engine.approveMerge(workerId, strategy: .merge)
- Reject button → engine.rejectMerge(workerId)
- Merge status badge: pending / in-progress / success / conflict / rejected
  using system semantic colors matching the roster status pattern
- Status updates reactively from engine.mergeStatuses[workerId]

### ConflictView.swift
Shown as a sheet or inline expansion when merge status is .conflict:
- Header: "Merge conflict in {workerName}'s branch"
- List of conflicting files from engine.pendingConflicts[workerId]
- Per file: file path, ours preview (green), theirs preview (red)
- "Accept Ours" / "Accept Theirs" buttons per conflict
- "Force merge" button at bottom for Team Lead override
- All actions call appropriate engine methods

### History section in GitView
New Section("Completed") below active workers:
- Shows workers whose merge status is .success or .rejected
- Each row: worker name + task + outcome (merged/rejected) +
  timestamp + short commit hash if merged
- Source: engine.mergeStatuses filtered for terminal states

### Team Lead terminal banner
In TeamLeadTerminalView.swift:
- Overlay a subtle banner at top when any worker's merge status
  is .pending: "Worker {name} is ready for review"
- Banner tappable — switches active roster selection to that worker
  and switches right pane to Git tab
- Banner dismissed automatically when status moves past .pending

## Depends on
stream-B2 must be merged before you begin implementation.
Your first action: git pull origin main, then confirm
engine.mergeStatuses and engine.pendingConflicts exist in
EngineClient.swift before writing a single line.

## Merge order
Last. After B2. No other stream depends on you.

## Done when
- ./build.sh passes end to end
- Approve button in GitView calls engine.approveMerge
- Reject button calls engine.rejectMerge
- ConflictView.swift renders when pendingConflicts is non-empty
- History section shows completed workers
- Team Lead terminal banner appears for pending reviews
- All three states handled: loading, empty, populated
- No force-unwraps
- PR raised, all checks pass

## Core rules
- Never modify src/
- No engine changes — engine is done, bridge is done
- No tm_* calls — call engine.approveMerge() not tm_merge_approve()
- No force-unwraps
