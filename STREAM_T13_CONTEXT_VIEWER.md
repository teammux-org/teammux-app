# Stream T13 — Worker CLAUDE.md Context Viewer

## Your branch
feat/v014-t13-context-viewer

## Your worktree path
../teammux-stream-t13

## Read first
- CLAUDE.md — hard rules, build commands, sprint workflow
- TECH_DEBT.md — TD23 (CLAUDE.md rendered as plain text) is relevant new debt
- V014_SPRINT.md — full sprint spec, Section 4 has your detailed scope

## WAIT CHECK
You MUST confirm T8 has been merged to main before starting implementation.
Run this command:
```
grep 'workerWorktrees' \
  macos/Sources/Teammux/Engine/EngineClient.swift
```
If the grep returns no results, STOP — T8 has not merged yet. Wait for main thread to confirm.

## Your mission

**Files:** macos/Sources/Teammux/RightPane/RightPaneView.swift, macos/Sources/Teammux/RightPane/ContextView.swift (new)

**RightTab addition:** case context. Tab bar: Team Lead | Git | Diff | Feed | Dispatch | Context. Icon: doc.text.fill. 6 tabs total.

**ContextView.swift:**
- Reads {worktreePath}/CLAUDE.md via FileManager.default.contents(atPath:) → String
- Renders in ScrollView, monospace font size 11
- Section headers (## prefix) rendered bold
- Refresh button: re-reads from disk
- Auto-refresh: when engine.hotReloadedWorkers.contains(selectedWorkerId), auto-refresh + show "Updated" badge 3 seconds
- Live diff highlight: on hot-reload, compare old content with new, highlight changed lines with yellow background for 2 seconds before settling
- Edit button: NSWorkspace.shared.open(URL(fileURLWithPath: roleDefinitionPath)) — role TOML path resolved from role library
- Empty state: "Select a worker to view their CLAUDE.md context" when no worker selected or worktree path unavailable

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
Wave 3 — depends on T8 merged.
Note: T13 adds sixth RightTab case. T15 also touches RightPaneView — T15 must pull main after T13 merges.

## Done when
- ./build.sh passes
- Sixth Context tab renders in right pane
- CLAUDE.md content displayed for selected worker
- Auto-refresh on hot-reload with changed line highlight
- Edit button opens role TOML in default editor
- PR raised from feat/v014-t13-context-viewer

## Core rules
- Never modify src/ (Ghostty upstream)
- All tm_* calls go through EngineClient.swift only
- No force-unwraps in production code
- ./build.sh must pass before raising PR (Swift stream)
- engine/include/teammux.h is the authoritative C API contract
- roles/ is local only — no external network fetching
- TECH_DEBT.md updated when new debt discovered
- Message type values: do NOT reuse or skip — check registry above
