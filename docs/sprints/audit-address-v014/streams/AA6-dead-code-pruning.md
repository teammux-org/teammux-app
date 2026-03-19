# Stream AA6 — Dead Code Pruning

## Context

Read these files before doing anything else (in parallel):
- CLAUDE.md
- docs/TECH_DEBT.md
- docs/codex-audits/audit-001-post-v014/ACTION-PLAN.md
  (read findings I17, I18, S8, S9, S10, S11, S12, S13)
- engine/src/main.zig
- engine/src/bus.zig
- engine/include/teammux.h
- macos/Sources/Teammux/Engine/EngineClient.swift
- macos/Sources/Teammux/Models/TeamMessage.swift
- macos/Sources/Teammux/RightPane/RightPaneView.swift
- macos/Sources/Teammux/RightPane/DiffView.swift

Then run: cd engine && zig build test
Confirm 356 tests pass before writing any code.

## Your Task

Cleanup sweep. No new features. No behavior changes.
Remove dead code, hide broken UI, reduce misleading
API surface. Work through in this exact order.

## I17 — Disable Diff tab (broken UI)
**Files:** macos/Sources/Teammux/RightPane/RightPaneView.swift
**Fix:** In RightTab, make .diff unavailable in the tab bar.
Either add .disabled() modifier to the diff tab button,
or show a "Coming soon" empty state when .diff is selected.
Do NOT remove DiffView.swift or the .diff case.
The engine stub stays as-is. Just hide the entry point.

## I18 — Remove stale PTY C API
**Files:** engine/include/teammux.h:264, engine/src/main.zig
**Fix:**
1. Remove tm_pty_send and tm_pty_fd from the header
2. Remove or comment out the corresponding export fn
   in main.zig
3. Add a comment: // PTY ownership belongs to Ghostty.
   // Teammux does not directly manage PTY file descriptors.
Verify: rg "tm_pty_send|tm_pty_fd" macos/ — expect zero

## S10 — Remove dead statusReq/statusRpt protocol values
**Files:** macos/Sources/Teammux/Models/TeamMessage.swift,
           engine/src/bus.zig,
           engine/include/teammux.h
**Fix:**
1. Verify no sender or handler exists:
   rg "statusReq|statusRpt|status_req|status_rpt" \
     engine/src/ macos/Sources/Teammux/
2. Remove case statusReq and case statusRpt from Swift
   MessageType enum
3. Remove corresponding values from Zig bus MessageType
4. Remove from tm_message_type_t in teammux.h

## S8 — Remove orphaned worktreeReadyQueue
**File:** macos/Sources/Teammux/Engine/EngineClient.swift:38
**Fix:**
1. rg "worktreeReadyQueue|WorktreeReady" \
     macos/Sources/Teammux/ — find all references
2. Remove @Published var worktreeReadyQueue
3. Remove WorktreeReady helper type
4. Remove all enqueue and dequeue call sites
Terminals render from engine.roster directly.

## S9 — Remove githubStatus (never observed)
**File:** macos/Sources/Teammux/Engine/EngineClient.swift:56
**Fix:**
1. rg "githubStatus" macos/Sources/Teammux/ — verify
   no view observes it
2. Remove @Published var githubStatus
3. Remove all mutation sites in auth and webhook callbacks

## S11 + S12 — Mark dead C exports as removal candidates
**File:** engine/src/main.zig:1090, engine/src/main.zig:370
For each of these exports, verify no Swift caller:
  rg "tm_peer_question|tm_peer_delegate|\
tm_worker_complete|tm_worker_question|\
tm_completion_free|tm_question_free|\
tm_worktree_create|tm_worktree_remove|\
tm_history_clear|tm_ownership_get|\
tm_ownership_free|tm_ownership_update|\
tm_interceptor_remove|tm_agent_resolve|\
tm_result_to_string" \
    macos/Sources/Teammux/ --include="*.swift"

For each confirmed dead export, add this comment
immediately above the export fn:
  // NO SWIFT CALLER — candidate for removal in v0.2

Do NOT remove them yet — AA4 may depend on tm_config_get.
Do NOT mark tm_config_get until AA4 is merged.

## S13 — Make module-private Zig helpers private
**File:** engine/src/commands.zig:235
**Fix:**
1. rg "^pub fn " engine/src/commands.zig
2. For each pub fn, check if it is called from outside
   its own module: rg "<fn_name>" engine/src/ --include="*.zig"
3. Change pub fn to fn for helpers only called within
   commands.zig and its tests
   (parseCommandJson, readGhCliToken, resolveGitBinary,
   globMatch and any others confirmed module-internal)

## Commit Sequence

Commit 1: Swift — disable Diff tab (I17)
           ./build.sh after
Commit 2: header + engine — remove PTY API (I18),
           remove statusReq/statusRpt (S10)
           cd engine && zig build && zig build test after
Commit 3: Swift — remove worktreeReadyQueue (S8),
           remove githubStatus (S9)
           ./build.sh after
Commit 4: engine — mark dead C exports (S11, S12),
           make helpers private (S13)
           cd engine && zig build && zig build test after

## Definition of Done

- Diff tab hidden with disabled state or Coming soon
- tm_pty_send and tm_pty_fd removed from header
- statusReq/statusRpt removed from Swift, Zig, and header
- worktreeReadyQueue and WorktreeReady removed
- githubStatus removed
- Dead exports marked with removal candidate comments
- Module-private helpers no longer pub
- 356 engine tests passing
- ./build.sh passing
- Zero functional behavior changes

Raise PR from fix/aa6-dead-code-pruning against main.
Do NOT merge. Report back with PR link.
