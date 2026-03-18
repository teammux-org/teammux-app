# Stream T15 — Worker Detail Drawer + Branch Badge Extension

## Your branch
feat/v014-t15-worker-drawer

## Your worktree path
../teammux-stream-t15

## Read first
- CLAUDE.md — hard rules, build commands, sprint workflow
- TECH_DEBT.md — no specific TD, new UI feature
- V014_SPRINT.md — full sprint spec, Section 4 has your detailed scope

## WAIT CHECK
You MUST confirm BOTH T8 AND T11 have been merged to main before starting implementation.
Run these commands:
```
grep 'workerWorktrees\|workerBranches' \
  macos/Sources/Teammux/Engine/EngineClient.swift
grep 'workerPRs' \
  macos/Sources/Teammux/Engine/EngineClient.swift
```
Both greps must return results. If either returns nothing, STOP — the dependency has not merged yet.

## Your mission

**Files:** macos/Sources/Teammux/Workspace/WorkerPaneView.swift, macos/Sources/Teammux/Workspace/WorkerDetailDrawer.swift (new)

**WorkerPaneView additions:**
```swift
@State private var selectedDrawerWorkerId: UInt32?
```
Single click on WorkerRow toggles drawer (click same worker = collapse).

**WorkerDetailDrawer.swift:**
Layout (VStack in a collapsible section):
- Role emoji + name (large)
- Full task description (wrapping text)
- Branch row: label + monospace branch name + Copy button (NSPasteboard)
- Path row: label + truncated path + Copy button
- Spawned: relative timestamp
- PR row (if engine.workerPRs[workerId] exists): status badge + title + "Open in GitHub" button

Animation: .easeInOut(duration: 0.2) on open/close.

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
Wave 3 — depends on T8 AND T11 both merged.
Note: T13 adds sixth RightTab case and also touches RightPaneView. You MUST pull main after T13 merges to avoid tab bar conflict.

## Done when
- ./build.sh passes
- Drawer opens on worker row click, collapses on second click
- Branch name and path both copyable
- PR status shown when PR exists for worker
- PR raised from feat/v014-t15-worker-drawer

## Core rules
- Never modify src/ (Ghostty upstream)
- All tm_* calls go through EngineClient.swift only
- No force-unwraps in production code
- ./build.sh must pass before raising PR (Swift stream)
- engine/include/teammux.h is the authoritative C API contract
- roles/ is local only — no external network fetching
- TECH_DEBT.md updated when new debt discovered
- Message type values: do NOT reuse or skip — check registry above
