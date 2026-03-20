# MergeCoordinator Per-Conflict Resolution — Design

**Stream:** S10
**Branch:** fix/v016-s10-merge-coordinator
**Date:** 2026-03-20

## Problem

The MergeCoordinator surfaces conflicts when merging a worker's
branch into main, but provides only two options: Force Merge
(re-attempt on dirty state) or Reject (abort and dismiss worker).
The Team Lead cannot resolve individual file conflicts — they must
accept or reject the entire merge as a unit.

## Design Decision

**Per-file resolution** (not per-conflict-block). The Team Lead
workflow is a review decision, not a code editor. Each conflicting
file gets one resolution: accept ours (main), accept theirs
(worker branch), or skip (leave unresolved, reject the merge).

## Current State

### Engine (merge.zig)

- `approve()` runs `git merge`, detects conflicts via
  `git diff --name-only --diff-filter=U`, parses conflict markers
- Conflicts stored in `conflicts: AutoHashMap(WorkerId, []Conflict)`
- On conflict: `active_merge` stays set, repo in MERGING state
- Only exit: `reject()` calls `git merge --abort`
- `Conflict` struct has: file_path, conflict_type, ours, theirs

### C API (teammux.h)

- `tm_merge_approve` / `tm_merge_reject` / `tm_merge_get_status`
- `tm_merge_conflicts_get` / `tm_merge_conflicts_free`
- `tm_conflict_t`: file_path, conflict_type, ours, theirs
- No resolve or finalize exports

### Swift (ConflictView.swift)

- Read-only conflict cards with ours/theirs preview
- Footer: Force Merge + Reject buttons only
- Comment explicitly states: "Per-file resolution is not supported"

## Changes

### 1. Engine — merge.zig

**New enum:**
```zig
pub const ConflictResolution = enum(u8) {
    ours = 0,
    theirs = 1,
    skip = 2,
    pending = 3,
};
```

**New field on MergeCoordinator:**
```zig
resolutions: std.AutoHashMap(worktree.WorkerId, std.StringHashMap(ConflictResolution)),
```

Tracks per-worker, per-file resolution state. Populated with
`.pending` for each file when conflicts are detected. Updated
by `resolveConflict()`.

**New method: `resolveConflict()`**
```zig
pub fn resolveConflict(
    self: *MergeCoordinator,
    project_root: []const u8,
    worker_id: worktree.WorkerId,
    file_path: []const u8,
    resolution: ConflictResolution,
) !void
```

- Validates: active_merge == worker_id, file exists in conflicts
- For `.ours`: `git checkout --ours <file>` then `git add <file>`
- For `.theirs`: `git checkout --theirs <file>` then `git add <file>`
- For `.skip`: no git ops, just records the resolution
- Updates resolution map entry

**New method: `finalizeMerge()`**
```zig
pub fn finalizeMerge(
    self: *MergeCoordinator,
    roster: *worktree.Roster,
    project_root: []const u8,
    worker_id: worktree.WorkerId,
) !ApproveResult
```

- Validates: active_merge == worker_id
- Checks all files resolved (no `.pending`, no `.skip`)
- Runs `git commit --no-edit` to complete the merge
- On success: cleans up worktree/branch, sets status to `.success`
- Returns `.success` or `.cleanup_incomplete`

**Modification to `approve()`:**
When conflicts are detected, populate the resolutions map with
`.pending` for each conflicting file path.

**Modification to `reject()`:**
Clean up resolutions map for the worker.

**New method: `getResolutions()`**
```zig
pub fn getResolutions(
    self: *MergeCoordinator,
    worker_id: worktree.WorkerId,
) ?*std.StringHashMap(ConflictResolution)
```

Returns the per-file resolution map for the worker, or null.

### 2. C API — teammux.h

**New enum:**
```c
typedef enum {
    TM_RESOLUTION_OURS    = 0,
    TM_RESOLUTION_THEIRS  = 1,
    TM_RESOLUTION_SKIP    = 2,
    TM_RESOLUTION_PENDING = 3,
} tm_resolution_t;
```

**New field on tm_conflict_t:**
```c
typedef struct {
    const char*        file_path;
    const char*        conflict_type;
    const char*        ours;
    const char*        theirs;
    tm_resolution_t    resolution;  // NEW
} tm_conflict_t;
```

**New exports:**
```c
// Resolve a single file in a conflicted merge.
// resolution: TM_RESOLUTION_OURS, TM_RESOLUTION_THEIRS, or TM_RESOLUTION_SKIP.
// Returns TM_OK on success, TM_ERR_INVALID_WORKER if no active merge for worker.
tm_result_t tm_conflict_resolve(tm_engine_t* engine,
                                 uint32_t worker_id,
                                 const char* file_path,
                                 tm_resolution_t resolution);

// Finalize a conflicted merge after all files are resolved.
// All files must be resolved (not pending, not skip) before calling.
// Returns TM_OK or TM_ERR_CLEANUP_INCOMPLETE on success.
// Returns TM_ERR_INVALID_WORKER if preconditions not met.
tm_result_t tm_conflict_finalize(tm_engine_t* engine,
                                  uint32_t worker_id);
```

**CConflict struct update:**
Add `resolution: u8` field (maps to ConflictResolution enum).
Update `fillCConflict` to populate from resolution map.
Update compile-time size assertion.

### 3. C API export layer — main.zig

**New exports:**
- `tm_conflict_resolve`: validates engine, spans file_path string,
  delegates to `merge_coordinator.resolveConflict()`
- `tm_conflict_finalize`: validates engine, delegates to
  `merge_coordinator.finalizeMerge()`

**Modified export:**
- `tm_merge_conflicts_get`: populates `resolution` field on CConflict
  from the resolutions map

### 4. Swift bridge — EngineClient.swift

**New methods:**
```swift
func resolveConflict(workerId: UInt32, filePath: String,
                     resolution: ConflictResolution) -> Bool

func finalizeMerge(workerId: UInt32) -> Bool
```

**New type:**
```swift
enum ConflictResolution: UInt8 {
    case ours = 0, theirs = 1, skip = 2, pending = 3
}
```

**ConflictInfo update:**
Add `resolution: ConflictResolution` property. Populated from
`tm_conflict_t.resolution` in `getConflicts()`.

**Polling update:**
`pollMergeStatuses()` already refreshes `pendingConflicts` on
`.conflict` status — resolution state will flow through naturally
via the updated `getConflicts()` call.

### 5. Swift UI — ConflictView.swift

**ConflictFileRow changes:**
- Add three resolution buttons per file: Accept Ours, Accept Theirs, Skip
- Show resolution badge (Resolved/Skipped/Pending) per file
- Disable buttons while resolution is in flight
- Buttons call `engine.resolveConflict()`

**ConflictView footer changes:**
- Remove Force Merge button
- Add Finalize Merge button (enabled only when all files resolved
  and none are skip/pending)
- Finalize calls `engine.finalizeMerge()`
- Keep Reject button as-is

## Testing

### Engine tests (merge.zig)

1. `resolveConflict` with ours/theirs applies git checkout and git add
2. `resolveConflict` with skip records resolution without git ops
3. `resolveConflict` rejects if active_merge is wrong worker
4. `resolveConflict` rejects if file not in conflict list
5. `finalizeMerge` commits and cleans up on all-resolved
6. `finalizeMerge` rejects if any file is pending
7. `finalizeMerge` rejects if any file is skip
8. Resolution map cleaned up on reject
9. Resolution map populated on conflict detection in approve

### C API tests (main.zig)

1. `tm_conflict_resolve` null engine returns TM_ERR_UNKNOWN
2. `tm_conflict_finalize` null engine returns TM_ERR_UNKNOWN
3. `tm_conflict_resolve` null file_path returns error
4. Integration: resolve + finalize flow

## Files Modified

| File | Changes |
|------|---------|
| engine/src/merge.zig | ConflictResolution enum, resolutions map, resolveConflict(), finalizeMerge(), getResolutions() |
| engine/src/main.zig | tm_conflict_resolve export, tm_conflict_finalize export, CConflict resolution field |
| engine/include/teammux.h | tm_resolution_t enum, tm_conflict_t.resolution field, 2 new exports |
| macos/Sources/Teammux/Engine/EngineClient.swift | resolveConflict(), finalizeMerge(), ConflictResolution enum |
| macos/Sources/Teammux/Models/MergeTypes.swift | ConflictResolution enum, ConflictInfo.resolution |
| macos/Sources/Teammux/RightPane/ConflictView.swift | Per-file resolution buttons, Finalize Merge button |
