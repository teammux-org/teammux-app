# Stream AA3 — Architecture & Team Lead Enforcement

## Context

Read these files before doing anything else (in parallel):
- CLAUDE.md
- docs/TECH_DEBT.md
- docs/codex-audits/audit-001-post-v014/ACTION-PLAN.md
  (read findings C3, C4, and TD25 in full)
- engine/src/main.zig
- engine/src/worktree_lifecycle.zig
- engine/src/worktree.zig
- engine/src/interceptor.zig
- engine/include/teammux.h
- macos/Sources/Teammux/RightPane/TeamLeadTerminalView.swift
- macos/Sources/Teammux/Engine/EngineClient.swift

Then run: cd engine && zig build test
Confirm 356 tests pass before writing any code.

## Your Task

This is the most architecturally significant stream.
THREE fixes required. Follow this process:

STEP 1: Do the Phase 1 brainstorm for C3 and C4 only.
Analyze the current implementation and propose your
fix approach in detail. Report back before implementing.
TD25 can be implemented immediately without brainstorm.

## Fix TD25 — Push-to-main refspec bypass (implement first)
**File:** engine/src/interceptor.zig (push elif block)
**Problem:** git push HEAD:main and HEAD:refs/heads/main
bypass the current main|master) case pattern.
**Fix:** Extend the push interception bash case statement
to also match these refspec patterns:
  HEAD:main) → block
  HEAD:master) → block
  HEAD:refs/heads/main) → block
  HEAD:refs/heads/master) → block
  +:main) → block
  +:master) → block
Add these as additional cases in the existing push elif
block. Add tests for each new pattern.

## Fix C3 — Dual worktree split-brain on worker spawn
**File:** engine/src/main.zig:383
**Problem:** tm_worker_spawn calls both Roster.spawn
(git worktree add with one path/branch scheme) AND
worktree_lifecycle.create (second git worktree add
with different scheme). One logical worker gets two
independent worktrees.

BRAINSTORM FIRST: Before implementing, analyze:
1. Every caller of Roster.spawn and what it does with
   the resulting worker data
2. Every field of Roster.Worker that currently stores
   path/branch (these become references to lifecycle data)
3. How tm_worktree_path and tm_worktree_branch are used
   in Swift (workerWorktrees, workerBranches, Context tab,
   session snapshots)
4. The cleanest collapse strategy (Option A preferred:
   remove git worktree operations from Roster.spawn,
   make worktree_lifecycle the single creator)

Report your analysis before implementing.

## Fix C4 — Team Lead not structurally prevented from writing
**File:** macos/Sources/Teammux/RightPane/TeamLeadTerminalView.swift:116
**Problem:** Team Lead runs plain claude in project root
with no interceptor PATH injection, no ownership registry
rules enforced, worker 0 unrestricted by default.

BRAINSTORM FIRST: Before implementing, analyze:
1. How TeamLeadTerminalView currently launches its PTY
   (compare with WorkerTerminalView interceptor injection)
2. How tm_interceptor_install works for worker terminals
3. What deny-all rules look like in the registry
4. Whether worker 0 has any special cases in the engine

Then implement:
1. TeamLeadTerminalView: inject git wrapper into PATH
   using same interceptor install path as worker terminals
2. Engine: in tm_interceptor_install, if worker_id == 0
   install deny-all rules (no write patterns, all deny)
3. Engine: in tm_ownership_register, reject write grants
   for worker_id == 0 at registry level
4. Engine: in commandRoutingCallback, block from_id == 0
   from /teammux-assign and /teammux-delegate

Report your analysis before implementing.

## Commit Sequence

Commit 1: interceptor.zig — TD25 refspec patterns + tests
Commit 2: engine — worktree unification C3
           (after brainstorm approved)
Commit 3: engine + Swift — Team Lead enforcement C4
           (after C3 stable)

After Commit 1:
  cd engine && zig build && zig build test
After Commits 2 and 3:
  cd engine && zig build && zig build test
  ./build.sh (Swift involved)

## Definition of Done

- git push HEAD:main blocked for all workers
- Single git worktree per worker, no dual-creation
- Team Lead PTY has interceptor PATH injection
- Worker 0 cannot receive write grants from registry
- Worker 0 push to main blocked at engine level
- Worker 0 blocked from sending peer assign/delegate cmds
- 356+ tests passing (new interceptor tests included)
- ./build.sh passing

Raise PR from fix/aa3-architecture-teamlead against main.
Do NOT merge. Report back with PR link.
