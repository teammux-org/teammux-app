# Teammux v0.1.1 — Stream B1: MergeCoordinator Engine

## Your branch
feat/v011-stream-b1-merge-engine

## Your worktree
../teammux-stream-b1

## Read first
Read V011_SPRINT.md Section 3 (stream-B1) and TECH_DEBT.md
(TD5) before doing anything else.
Read engine/include/teammux.h on main — you will extend it.
Read engine/src/worktree.zig — MergeCoordinator works closely
with the Roster and git worktree infrastructure already built.

## Your mission
Implement the MergeCoordinator. This is a new Zig module and
new C API surface. Resolve TD5.

### New file: engine/src/merge.zig
### New C API: 5 functions added to engine/include/teammux.h
### New exports: 5 export fn in engine/src/main.zig

The full C API signatures are in V011_SPRINT.md Section 3.
Copy them exactly into teammux.h — do not deviate.

### merge.zig core logic
tm_merge_approve:
- Look up worker in roster by worker_id
- Run: git -C {project_root} merge {branch_name} (or rebase)
- Detect conflicts: check exit code, parse conflict markers
- If clean merge: remove worktree, delete branch, update status
- If conflicts: set status TM_MERGE_CONFLICT, populate conflict list

tm_merge_reject:
- Run: git worktree remove {worktree_path} --force
- Run: git branch -D {branch_name}
- Update roster status to dismissed
- Clean up merge state for this worker_id

tm_merge_conflicts_get:
- Run: git -C {project_root} diff --name-only --diff-filter=U
- For each conflicting file, parse <<<< ==== >>>> markers
- Return allocated tm_conflict_t** array, caller frees via
  tm_merge_conflicts_free

## Depends on
stream-A1 must be merged before you begin implementation.
Your first action after pulling main: confirm tm_message_cb
has the updated signature in engine/include/teammux.h.

## Merge order
After A1 is merged. stream-B2 depends on your header additions.
Merge promptly after approval.

## Done when
- cd engine && zig build test — all tests pass including
  integration tests with real git operations in tmpdir
- tm_merge_approve produces a real git merge in test repo
- tm_merge_reject removes worktree and branch in test repo
- tm_merge_conflicts_get returns populated list for a
  repo with known conflicts in test
- All 5 new functions exported in main.zig
- PR raised, all checks pass

## Core rules
- Never modify src/
- No Swift changes — that is stream-B2's job
- engine/include/teammux.h additions are additive only —
  do not change existing function signatures
