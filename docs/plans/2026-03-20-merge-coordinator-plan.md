# MergeCoordinator Per-Conflict Resolution — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable per-file conflict resolution in the MergeCoordinator so the Team Lead can accept-ours, accept-theirs, or skip individual files, then finalize the merge.

**Architecture:** Engine adds `ConflictResolution` enum and per-worker resolution tracking map. Two new C exports (`tm_conflict_resolve`, `tm_conflict_finalize`) let Swift call per-file resolution and merge finalization. ConflictView replaces Force Merge with per-file buttons and a Finalize Merge button.

**Tech Stack:** Zig (engine), C API (teammux.h), Swift/SwiftUI (macOS app)

---

### Task 1: Engine — ConflictResolution type + resolutions map

**Files:**
- Modify: `engine/src/merge.zig:11-69` (types, MergeCoordinator struct, init, deinit)

**Step 1: Add ConflictResolution enum after MergeStatus**

In `engine/src/merge.zig`, after the `MergeStatus` enum (line 17), add:

```zig
pub const ConflictResolution = enum(u8) {
    ours = 0,
    theirs = 1,
    skip = 2,
    pending = 3,
};
```

**Step 2: Add resolutions map to MergeCoordinator struct**

Add after `active_merge` field (line 51):

```zig
    resolutions: std.AutoHashMap(worktree.WorkerId, std.StringHashMap(ConflictResolution)),
```

**Step 3: Update init to initialize resolutions**

In `init()`, add after `active_merge: null`:

```zig
            .resolutions = std.AutoHashMap(worktree.WorkerId, std.StringHashMap(ConflictResolution)).init(allocator),
```

**Step 4: Add freeResolutionMap helper**

Add after `freeConflicts` function (after line 516):

```zig
fn freeResolutionMap(allocator: std.mem.Allocator, map: *std.StringHashMap(ConflictResolution)) void {
    var it = map.iterator();
    while (it.next()) |kv| {
        allocator.free(kv.key_ptr.*);
    }
    map.deinit();
}
```

**Step 5: Update deinit to free resolutions**

In `deinit()`, add before `self.conflicts.deinit()`:

```zig
        var res_it = self.resolutions.iterator();
        while (res_it.next()) |entry| {
            freeResolutionMap(self.allocator, entry.value_ptr);
        }
        self.resolutions.deinit();
```

**Step 6: Run tests to verify no regressions**

Run: `cd engine && zig build test`
Expected: All existing tests pass (baseline ~388).

**Step 7: Commit**

```bash
git add engine/src/merge.zig
git commit -m "feat(s10): add ConflictResolution type and resolutions map to MergeCoordinator"
```

---

### Task 2: Engine — resolveConflict method with TDD

**Files:**
- Modify: `engine/src/merge.zig` (new method + tests)

**Step 1: Write unit tests for resolveConflict validation**

Add after existing tests (after line 1017):

```zig
test "merge - resolveConflict rejects when no active merge" {
    var mc = MergeCoordinator.init(std.testing.allocator);
    defer mc.deinit();

    const result = mc.resolveConflict("/tmp", 1, "file.txt", .ours);
    try std.testing.expectError(error.NoActiveMerge, result);
}

test "merge - resolveConflict rejects wrong worker" {
    var mc = MergeCoordinator.init(std.testing.allocator);
    defer mc.deinit();

    mc.active_merge = 5;
    const result = mc.resolveConflict("/tmp", 99, "file.txt", .ours);
    try std.testing.expectError(error.NoActiveMerge, result);
}

test "merge - resolveConflict rejects file not in conflicts" {
    var mc = MergeCoordinator.init(std.testing.allocator);
    defer mc.deinit();

    mc.active_merge = 1;
    var file_map = std.StringHashMap(ConflictResolution).init(std.testing.allocator);
    const key = try std.testing.allocator.dupe(u8, "other.txt");
    try file_map.put(key, .pending);
    try mc.resolutions.put(1, file_map);

    const result = mc.resolveConflict("/tmp", 1, "missing.txt", .ours);
    try std.testing.expectError(error.FileNotInConflicts, result);
}
```

**Step 2: Run tests to verify they fail**

Run: `cd engine && zig build test`
Expected: FAIL — `resolveConflict` does not exist yet.

**Step 3: Implement resolveConflict method**

Add inside `MergeCoordinator` struct, after `getConflicts()` (after line 275):

```zig
    /// Get the per-file resolution map for a worker, or null.
    pub fn getResolutions(self: *MergeCoordinator, worker_id: worktree.WorkerId) ?*std.StringHashMap(ConflictResolution) {
        return self.resolutions.getPtr(worker_id);
    }

    /// Resolve a single file in a conflicted merge.
    /// For ours/theirs: runs git checkout --ours/--theirs then git add.
    /// For skip: records resolution without git ops.
    /// Resolution can be changed freely (ours↔theirs↔skip).
    pub fn resolveConflict(
        self: *MergeCoordinator,
        project_root: []const u8,
        worker_id: worktree.WorkerId,
        file_path: []const u8,
        resolution: ConflictResolution,
    ) !void {
        // Must have an active merge for this worker
        if (self.active_merge == null or self.active_merge.? != worker_id) return error.NoActiveMerge;
        if (resolution == .pending) return error.InvalidResolution;

        // Verify file is in the resolution map
        const file_resolutions = self.resolutions.getPtr(worker_id) orelse return error.NoConflicts;
        const res_ptr = file_resolutions.getPtr(file_path) orelse return error.FileNotInConflicts;

        // Apply git operations
        switch (resolution) {
            .ours => {
                const r1 = try runGitCapture(self.allocator, project_root, &.{ "checkout", "--ours", file_path });
                defer r1.deinit(self.allocator);
                if (r1.exit_code != 0) return error.GitFailed;
                const r2 = try runGitCapture(self.allocator, project_root, &.{ "add", file_path });
                defer r2.deinit(self.allocator);
                if (r2.exit_code != 0) return error.GitFailed;
            },
            .theirs => {
                const r1 = try runGitCapture(self.allocator, project_root, &.{ "checkout", "--theirs", file_path });
                defer r1.deinit(self.allocator);
                if (r1.exit_code != 0) return error.GitFailed;
                const r2 = try runGitCapture(self.allocator, project_root, &.{ "add", file_path });
                defer r2.deinit(self.allocator);
                if (r2.exit_code != 0) return error.GitFailed;
            },
            .skip => {}, // No git ops — just record the resolution
            .pending => unreachable,
        }

        res_ptr.* = resolution;
    }
```

**Step 4: Run tests to verify they pass**

Run: `cd engine && zig build test`
Expected: All tests pass including 3 new validation tests.

**Step 5: Commit**

```bash
git add engine/src/merge.zig
git commit -m "feat(s10): add resolveConflict method to MergeCoordinator"
```

---

### Task 3: Engine — finalizeMerge + approve/reject wiring + integration tests

**Files:**
- Modify: `engine/src/merge.zig` (finalizeMerge method, approve/reject updates, tests)

**Step 1: Write unit test for finalizeMerge rejecting pending files**

Add after the resolveConflict tests:

```zig
test "merge - finalizeMerge rejects with pending files" {
    var mc = MergeCoordinator.init(std.testing.allocator);
    defer mc.deinit();

    mc.active_merge = 1;
    var file_map = std.StringHashMap(ConflictResolution).init(std.testing.allocator);
    const k1 = try std.testing.allocator.dupe(u8, "a.txt");
    try file_map.put(k1, .ours);
    const k2 = try std.testing.allocator.dupe(u8, "b.txt");
    try file_map.put(k2, .pending);
    try mc.resolutions.put(1, file_map);

    var roster = worktree.Roster.init(std.testing.allocator);
    defer roster.deinit();

    const result = mc.finalizeMerge(&roster, "/tmp", 1);
    try std.testing.expectError(error.UnresolvedConflicts, result);
}

test "merge - finalizeMerge rejects with skip files" {
    var mc = MergeCoordinator.init(std.testing.allocator);
    defer mc.deinit();

    mc.active_merge = 1;
    var file_map = std.StringHashMap(ConflictResolution).init(std.testing.allocator);
    const k1 = try std.testing.allocator.dupe(u8, "a.txt");
    try file_map.put(k1, .theirs);
    const k2 = try std.testing.allocator.dupe(u8, "b.txt");
    try file_map.put(k2, .skip);
    try mc.resolutions.put(1, file_map);

    var roster = worktree.Roster.init(std.testing.allocator);
    defer roster.deinit();

    const result = mc.finalizeMerge(&roster, "/tmp", 1);
    try std.testing.expectError(error.UnresolvedConflicts, result);
}
```

**Step 2: Run tests to verify they fail**

Run: `cd engine && zig build test`
Expected: FAIL — `finalizeMerge` does not exist yet.

**Step 3: Implement finalizeMerge method**

Add inside `MergeCoordinator` struct, after `resolveConflict()`:

```zig
    /// Finalize a conflicted merge after all files are resolved.
    /// All files must have resolution ours or theirs (not pending, not skip).
    /// Runs git commit --no-edit to complete the merge, then cleans up
    /// worktree and branch. Returns .success or .cleanup_incomplete.
    pub fn finalizeMerge(
        self: *MergeCoordinator,
        roster: *worktree.Roster,
        project_root: []const u8,
        worker_id: worktree.WorkerId,
    ) !ApproveResult {
        if (self.active_merge == null or self.active_merge.? != worker_id) return error.NoActiveMerge;

        // Check all files resolved (not pending, not skip)
        const file_resolutions = self.resolutions.getPtr(worker_id) orelse return error.NoConflicts;
        var it = file_resolutions.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.* == .pending or kv.value_ptr.* == .skip) return error.UnresolvedConflicts;
        }

        // Complete the merge
        const commit_result = try runGitCapture(self.allocator, project_root, &.{ "commit", "--no-edit" });
        defer commit_result.deinit(self.allocator);
        if (commit_result.exit_code != 0) return error.GitFailed;

        std.log.info("[teammux] merge finalized: worker {d}", .{worker_id});
        try self.statuses.put(worker_id, .success);
        self.active_merge = null;

        // Clean up resolutions
        if (self.resolutions.fetchRemove(worker_id)) |old| {
            var map = old.value;
            freeResolutionMap(self.allocator, &map);
        }

        // Clean up conflicts
        if (self.conflicts.fetchRemove(worker_id)) |old| {
            freeConflicts(self.allocator, old.value);
        }

        // Look up worker for worktree/branch cleanup
        const worker = roster.getWorker(worker_id) orelse return .success;
        const branch_name = try self.allocator.dupe(u8, worker.branch_name);
        defer self.allocator.free(branch_name);
        const wt_path = try self.allocator.dupe(u8, worker.worktree_path);
        defer self.allocator.free(wt_path);

        worker.status = .complete;

        // Remove worktree and branch
        const wt_removed = runGitLoggedWithStderr(self.allocator, project_root, &.{ "worktree", "remove", "--force", wt_path }, "finalize cleanup: worktree remove");
        const br_deleted = runGitLoggedWithStderr(self.allocator, project_root, &.{ "branch", "-D", branch_name }, "finalize cleanup: branch delete");

        if (!wt_removed or !br_deleted) return .cleanup_incomplete;
        return .success;
    }
```

**Step 4: Run tests to verify they pass**

Run: `cd engine && zig build test`
Expected: All tests pass including 2 new finalizeMerge tests.

**Step 5: Wire resolutions into approve() — populate on conflict detection**

In `approve()`, inside the `if (conflict_list.len > 0)` block (around line 162), add after the `try self.conflicts.put(worker_id, conflict_list)` line:

```zig
                // Populate resolution map (deduplicate by file path)
                if (self.resolutions.fetchRemove(worker_id)) |old| {
                    var map = old.value;
                    freeResolutionMap(self.allocator, &map);
                }
                var file_resolutions = std.StringHashMap(ConflictResolution).init(self.allocator);
                errdefer {
                    var free_it = file_resolutions.iterator();
                    while (free_it.next()) |kv| self.allocator.free(kv.key_ptr.*);
                    file_resolutions.deinit();
                }
                for (conflict_list) |conflict| {
                    if (!file_resolutions.contains(conflict.file_path)) {
                        const key = try self.allocator.dupe(u8, conflict.file_path);
                        errdefer self.allocator.free(key);
                        try file_resolutions.put(key, .pending);
                    }
                }
                try self.resolutions.put(worker_id, file_resolutions);
```

**Step 6: Wire resolutions into reject() — clean up**

In `reject()`, add before or after `self.conflicts.fetchRemove(worker_id)` block (around line 260):

```zig
        // Clean up resolution data for this worker
        if (self.resolutions.fetchRemove(worker_id)) |old| {
            var map = old.value;
            freeResolutionMap(self.allocator, &map);
        }
```

**Step 7: Write test for approve populating resolutions**

```zig
test "merge - approve populates resolutions map on conflict (integration)" {
    var repo = setupTestRepo(std.testing.allocator) catch return;
    defer repo.tmp.cleanup();
    defer std.testing.allocator.free(repo.path);

    var roster = worktree.Roster.init(std.testing.allocator);
    defer roster.deinit();

    const id = try spawnTestWorker(std.testing.allocator, &roster, repo.path, "ResWorker", "edit readme");
    const wt_path = try std.testing.allocator.dupe(u8, roster.getWorker(id).?.worktree_path);
    defer std.testing.allocator.free(wt_path);

    // Create conflicting changes
    const wt_readme = try std.fmt.allocPrint(std.testing.allocator, "{s}/README.md", .{wt_path});
    defer std.testing.allocator.free(wt_readme);
    {
        const f = try std.fs.createFileAbsolute(wt_readme, .{});
        try f.writeAll("# Worker change for resolve test");
        f.close();
    }
    try worktree.runGit(std.testing.allocator, wt_path, &.{ "add", "." });
    try worktree.runGit(std.testing.allocator, wt_path, &.{ "commit", "-m", "worker edit" });

    const main_readme = try std.fmt.allocPrint(std.testing.allocator, "{s}/README.md", .{repo.path});
    defer std.testing.allocator.free(main_readme);
    {
        const f = try std.fs.createFileAbsolute(main_readme, .{});
        try f.writeAll("# Main change for resolve test");
        f.close();
    }
    try worktree.runGit(std.testing.allocator, repo.path, &.{ "add", "." });
    try worktree.runGit(std.testing.allocator, repo.path, &.{ "commit", "-m", "main edit" });

    var mc = MergeCoordinator.init(std.testing.allocator);
    defer mc.deinit();

    const result = try mc.approve(&roster, repo.path, id, "merge");
    try std.testing.expect(result == .conflict);

    // Verify resolutions map populated
    const resolutions = mc.getResolutions(id);
    try std.testing.expect(resolutions != null);
    try std.testing.expect(resolutions.?.get("README.md") == .pending);

    // Clean up
    runGitIgnoreResult(std.testing.allocator, repo.path, &.{ "merge", "--abort" });
}
```

**Step 8: Write test for reject cleaning up resolutions**

```zig
test "merge - reject cleans up resolutions (integration)" {
    var repo = setupTestRepo(std.testing.allocator) catch return;
    defer repo.tmp.cleanup();
    defer std.testing.allocator.free(repo.path);

    var roster = worktree.Roster.init(std.testing.allocator);
    defer roster.deinit();

    const id = try spawnTestWorker(std.testing.allocator, &roster, repo.path, "RejectRes", "edit file");
    const wt_path = try std.testing.allocator.dupe(u8, roster.getWorker(id).?.worktree_path);
    defer std.testing.allocator.free(wt_path);

    // Create conflict
    const wt_readme = try std.fmt.allocPrint(std.testing.allocator, "{s}/README.md", .{wt_path});
    defer std.testing.allocator.free(wt_readme);
    {
        const f = try std.fs.createFileAbsolute(wt_readme, .{});
        try f.writeAll("# RejectRes change");
        f.close();
    }
    try worktree.runGit(std.testing.allocator, wt_path, &.{ "add", "." });
    try worktree.runGit(std.testing.allocator, wt_path, &.{ "commit", "-m", "rejectres edit" });
    const main_readme = try std.fmt.allocPrint(std.testing.allocator, "{s}/README.md", .{repo.path});
    defer std.testing.allocator.free(main_readme);
    {
        const f = try std.fs.createFileAbsolute(main_readme, .{});
        try f.writeAll("# Main RejectRes change");
        f.close();
    }
    try worktree.runGit(std.testing.allocator, repo.path, &.{ "add", "." });
    try worktree.runGit(std.testing.allocator, repo.path, &.{ "commit", "-m", "main rejectres edit" });

    var mc = MergeCoordinator.init(std.testing.allocator);
    defer mc.deinit();

    const approve_result = try mc.approve(&roster, repo.path, id, "merge");
    try std.testing.expect(approve_result == .conflict);
    try std.testing.expect(mc.getResolutions(id) != null);

    _ = try mc.reject(&roster, repo.path, id);
    try std.testing.expect(mc.getResolutions(id) == null);
}
```

**Step 9: Write integration test for full resolve + finalize flow**

```zig
test "merge - resolve ours + finalize completes merge (integration)" {
    var repo = setupTestRepo(std.testing.allocator) catch return;
    defer repo.tmp.cleanup();
    defer std.testing.allocator.free(repo.path);

    var roster = worktree.Roster.init(std.testing.allocator);
    defer roster.deinit();

    const id = try spawnTestWorker(std.testing.allocator, &roster, repo.path, "FinalizeW", "edit readme");
    const wt_path = try std.testing.allocator.dupe(u8, roster.getWorker(id).?.worktree_path);
    defer std.testing.allocator.free(wt_path);

    // Create conflict
    const wt_readme = try std.fmt.allocPrint(std.testing.allocator, "{s}/README.md", .{wt_path});
    defer std.testing.allocator.free(wt_readme);
    {
        const f = try std.fs.createFileAbsolute(wt_readme, .{});
        try f.writeAll("# Worker finalize version");
        f.close();
    }
    try worktree.runGit(std.testing.allocator, wt_path, &.{ "add", "." });
    try worktree.runGit(std.testing.allocator, wt_path, &.{ "commit", "-m", "finalize worker edit" });
    const main_readme = try std.fmt.allocPrint(std.testing.allocator, "{s}/README.md", .{repo.path});
    defer std.testing.allocator.free(main_readme);
    {
        const f = try std.fs.createFileAbsolute(main_readme, .{});
        try f.writeAll("# Main finalize version");
        f.close();
    }
    try worktree.runGit(std.testing.allocator, repo.path, &.{ "add", "." });
    try worktree.runGit(std.testing.allocator, repo.path, &.{ "commit", "-m", "finalize main edit" });

    var mc = MergeCoordinator.init(std.testing.allocator);
    defer mc.deinit();

    // Approve → conflict
    const approve_result = try mc.approve(&roster, repo.path, id, "merge");
    try std.testing.expect(approve_result == .conflict);

    // Resolve with ours
    try mc.resolveConflict(repo.path, id, "README.md", .ours);

    // Verify resolution recorded
    const resolutions = mc.getResolutions(id);
    try std.testing.expect(resolutions.?.get("README.md") == .ours);

    // Finalize
    const finalize_result = try mc.finalizeMerge(&roster, repo.path, id);
    try std.testing.expect(finalize_result == .success or finalize_result == .cleanup_incomplete);
    try std.testing.expect(mc.getStatus(id) == .success);
    try std.testing.expect(mc.active_merge == null);

    // Verify main has ours content
    const content = blk: {
        const f = try std.fs.openFileAbsolute(main_readme, .{});
        defer f.close();
        break :blk try f.readToEndAlloc(std.testing.allocator, 1024);
    };
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("# Main finalize version", content);
}

test "merge - resolve theirs + finalize uses worker content (integration)" {
    var repo = setupTestRepo(std.testing.allocator) catch return;
    defer repo.tmp.cleanup();
    defer std.testing.allocator.free(repo.path);

    var roster = worktree.Roster.init(std.testing.allocator);
    defer roster.deinit();

    const id = try spawnTestWorker(std.testing.allocator, &roster, repo.path, "TheirsW", "edit readme");
    const wt_path = try std.testing.allocator.dupe(u8, roster.getWorker(id).?.worktree_path);
    defer std.testing.allocator.free(wt_path);

    const wt_readme = try std.fmt.allocPrint(std.testing.allocator, "{s}/README.md", .{wt_path});
    defer std.testing.allocator.free(wt_readme);
    {
        const f = try std.fs.createFileAbsolute(wt_readme, .{});
        try f.writeAll("# Worker theirs version");
        f.close();
    }
    try worktree.runGit(std.testing.allocator, wt_path, &.{ "add", "." });
    try worktree.runGit(std.testing.allocator, wt_path, &.{ "commit", "-m", "theirs worker edit" });
    const main_readme = try std.fmt.allocPrint(std.testing.allocator, "{s}/README.md", .{repo.path});
    defer std.testing.allocator.free(main_readme);
    {
        const f = try std.fs.createFileAbsolute(main_readme, .{});
        try f.writeAll("# Main theirs version");
        f.close();
    }
    try worktree.runGit(std.testing.allocator, repo.path, &.{ "add", "." });
    try worktree.runGit(std.testing.allocator, repo.path, &.{ "commit", "-m", "theirs main edit" });

    var mc = MergeCoordinator.init(std.testing.allocator);
    defer mc.deinit();

    const approve_result = try mc.approve(&roster, repo.path, id, "merge");
    try std.testing.expect(approve_result == .conflict);

    // Resolve with theirs (worker's version)
    try mc.resolveConflict(repo.path, id, "README.md", .theirs);

    const finalize_result = try mc.finalizeMerge(&roster, repo.path, id);
    try std.testing.expect(finalize_result == .success or finalize_result == .cleanup_incomplete);

    // Verify main has theirs content
    const content = blk: {
        const f = try std.fs.openFileAbsolute(main_readme, .{});
        defer f.close();
        break :blk try f.readToEndAlloc(std.testing.allocator, 1024);
    };
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("# Worker theirs version", content);
}
```

**Step 10: Run tests to verify all pass**

Run: `cd engine && zig build test`
Expected: All tests pass.

**Step 11: Commit**

```bash
git add engine/src/merge.zig
git commit -m "feat(s10): add finalizeMerge, wire resolutions into approve/reject, integration tests"
```

---

### Task 4: C API — types, exports, CConflict update

**Files:**
- Modify: `engine/include/teammux.h:153-158` (tm_conflict_t), `engine/include/teammux.h:328-354` (merge section)
- Modify: `engine/src/main.zig:313-316` (CConflict), `engine/src/main.zig:344` (size assertion)
- Modify: `engine/src/main.zig:2544-2550` (fillCConflict)
- Modify: `engine/src/main.zig:1672-1701` (tm_merge_conflicts_get)
- Add new exports after `tm_merge_conflicts_free`

**Step 1: Add tm_resolution_t enum to teammux.h**

Add before `tm_conflict_t` (before line 153):

```c
typedef enum {
    TM_RESOLUTION_OURS    = 0,
    TM_RESOLUTION_THEIRS  = 1,
    TM_RESOLUTION_SKIP    = 2,
    TM_RESOLUTION_PENDING = 3,
} tm_resolution_t;
```

**Step 2: Add resolution field to tm_conflict_t**

Change `tm_conflict_t` (line 153-158) to:

```c
typedef struct {
    const char*        file_path;
    const char*        conflict_type;
    const char*        ours;
    const char*        theirs;
    tm_resolution_t    resolution;
} tm_conflict_t;
```

**Step 3: Add new export declarations to teammux.h**

Add after `tm_merge_conflicts_free` declaration (after line 354):

```c
// Resolve a single file in a conflicted merge.
// resolution: TM_RESOLUTION_OURS, TM_RESOLUTION_THEIRS, or TM_RESOLUTION_SKIP.
// Returns TM_OK on success. Returns TM_ERR_INVALID_WORKER if no active merge
// for this worker or file not in conflict list.
tm_result_t tm_conflict_resolve(tm_engine_t* engine,
                                 uint32_t worker_id,
                                 const char* file_path,
                                 tm_resolution_t resolution);

// Finalize a conflicted merge after all files are resolved (ours or theirs).
// Files with pending or skip resolution block finalization.
// Returns TM_OK on clean success, TM_ERR_CLEANUP_INCOMPLETE if merge succeeded
// but worktree/branch removal failed. Returns TM_ERR_INVALID_WORKER if
// preconditions not met (no active merge, unresolved files).
tm_result_t tm_conflict_finalize(tm_engine_t* engine,
                                  uint32_t worker_id);
```

**Step 4: Update CConflict struct in main.zig**

Change line 313-316:

```zig
const CConflict = extern struct {
    file_path: ?[*:0]const u8, conflict_type: ?[*:0]const u8,
    ours: ?[*:0]const u8, theirs: ?[*:0]const u8,
    resolution: c_int,
};
```

**Step 5: Update size assertion**

Change line 344 from `32` to `40`:

```zig
    if (@sizeOf(CConflict) != 40) @compileError("CConflict size mismatch with tm_conflict_t");
```

**Step 6: Update fillCConflict to include resolution**

Change `fillCConflict` (line 2544-2550) to accept resolutions map:

```zig
fn fillCConflict(alloc: std.mem.Allocator, c: merge.Conflict, resolutions: ?*std.StringHashMap(merge.ConflictResolution)) !CConflict {
    const fp = try alloc.dupeZ(u8, c.file_path); errdefer alloc.free(fp);
    const ct = try alloc.dupeZ(u8, c.conflict_type); errdefer alloc.free(ct);
    const ours = try alloc.dupeZ(u8, c.ours); errdefer alloc.free(ours);
    const theirs = try alloc.dupeZ(u8, c.theirs);
    const res: c_int = if (resolutions) |r|
        @intFromEnum(r.get(c.file_path) orelse merge.ConflictResolution.pending)
    else
        @intFromEnum(merge.ConflictResolution.pending);
    return .{ .file_path = fp.ptr, .conflict_type = ct.ptr, .ours = ours.ptr, .theirs = theirs.ptr, .resolution = res };
}
```

**Step 7: Update tm_merge_conflicts_get to pass resolutions**

Change line 1682 area — add resolutions lookup and pass to fillCConflict:

```zig
    const resolutions = e.merge_coordinator.getResolutions(worker_id);
```

Add this line after `if (conflicts.len == 0)` check and before the `ptrs` allocation. Then change the `fillCConflict` call from:

```zig
        cc.* = fillCConflict(alloc, conf) catch {
```

to:

```zig
        cc.* = fillCConflict(alloc, conf, resolutions) catch {
```

**Step 8: Add tm_conflict_resolve export**

Add after `tm_merge_conflicts_free` export (after line 1701):

```zig
export fn tm_conflict_resolve(engine: ?*Engine, worker_id: u32, file_path: ?[*:0]const u8, resolution: c_int) c_int {
    const e = engine orelse return 99;
    const fp = std.mem.span(file_path orelse {
        e.setError("tm_conflict_resolve: file_path is NULL") catch {};
        return 12;
    });
    const res: merge.ConflictResolution = switch (resolution) {
        0 => .ours,
        1 => .theirs,
        2 => .skip,
        else => {
            e.setError("tm_conflict_resolve: invalid resolution value") catch {};
            return 12;
        },
    };
    e.merge_coordinator.resolveConflict(e.project_root, worker_id, fp, res) catch |err| {
        e.setError(switch (err) {
            error.NoActiveMerge => "conflict resolve failed: no active merge for this worker",
            error.NoConflicts => "conflict resolve failed: no conflicts for this worker",
            error.FileNotInConflicts => "conflict resolve failed: file not in conflict list",
            error.InvalidResolution => "conflict resolve failed: invalid resolution",
            error.GitFailed => "conflict resolve failed: git operation failed",
            else => "conflict resolve failed",
        }) catch {};
        return 12; // TM_ERR_INVALID_WORKER
    };
    return 0;
}
```

**Step 9: Add tm_conflict_finalize export**

Add after `tm_conflict_resolve`:

```zig
export fn tm_conflict_finalize(engine: ?*Engine, worker_id: u32) c_int {
    const e = engine orelse return 99;
    // Stop and remove role watcher before finalize cleanup
    if (e.role_watchers.fetchRemove(worker_id)) |kv| {
        kv.value.destroy();
    }
    // Remove interceptor wrapper before worktree is deleted
    if (e.roster.copyWorkerFields(worker_id, e.allocator) catch |err| blk: {
        std.log.warn("[teammux] interceptor cleanup skipped for worker {d}: {}", .{ worker_id, err });
        break :blk null;
    }) |wf| {
        defer wf.deinit(e.allocator);
        interceptor.remove(e.allocator, wf.worktree_path) catch |err| {
            std.log.warn("[teammux] interceptor remove failed for worker {d}: {}", .{ worker_id, err });
        };
    }
    const result = e.merge_coordinator.finalizeMerge(&e.roster, e.project_root, worker_id) catch |err| {
        e.setError(switch (err) {
            error.NoActiveMerge => "conflict finalize failed: no active merge for this worker",
            error.NoConflicts => "conflict finalize failed: no conflicts for this worker",
            error.UnresolvedConflicts => "conflict finalize failed: unresolved files remain",
            error.GitFailed => "conflict finalize failed: git commit failed",
            else => "conflict finalize failed",
        }) catch {};
        return 12; // TM_ERR_INVALID_WORKER
    };
    e.ownership_registry.release(worker_id);
    if (result == .cleanup_incomplete) {
        e.setError("merge finalized but cleanup incomplete — manual worktree/branch removal may be needed") catch {};
        return 15; // TM_ERR_CLEANUP_INCOMPLETE
    }
    return 0;
}
```

Note: the `interceptor` import is already available — check the existing imports at top of main.zig. The pattern follows `tm_merge_reject` exactly for role watcher/interceptor cleanup.

**Step 10: Add null-safety tests**

Add after existing merge tests in main.zig:

```zig
test "tm_conflict_resolve null engine returns TM_ERR_UNKNOWN" { try std.testing.expect(tm_conflict_resolve(null, 0, null, 0) == 99); }
test "tm_conflict_finalize null engine returns TM_ERR_UNKNOWN" { try std.testing.expect(tm_conflict_finalize(null, 0) == 99); }
```

**Step 11: Run tests**

Run: `cd engine && zig build test`
Expected: All tests pass.

**Step 12: Commit**

```bash
git add engine/src/main.zig engine/include/teammux.h
git commit -m "feat(s10): add tm_conflict_resolve and tm_conflict_finalize C exports, update tm_conflict_t"
```

---

### Task 5: Swift — Model + Bridge changes

**Files:**
- Modify: `macos/Sources/Teammux/Models/MergeTypes.swift`
- Modify: `macos/Sources/Teammux/Engine/EngineClient.swift`

**Step 1: Add ConflictResolution enum to MergeTypes.swift**

Add after `ConflictType` enum (after line 76):

```swift
// MARK: - ConflictResolution

/// Per-file conflict resolution choice. Maps to `tm_resolution_t` in teammux.h.
enum ConflictResolution: UInt8, CaseIterable, Sendable {
    case ours    = 0
    case theirs  = 1
    case skip    = 2
    case pending = 3

    var label: String {
        switch self {
        case .ours:    return "Ours"
        case .theirs:  return "Theirs"
        case .skip:    return "Skipped"
        case .pending: return "Pending"
        }
    }

    var color: Color {
        switch self {
        case .ours:    return .green
        case .theirs:  return .blue
        case .skip:    return .orange
        case .pending: return .secondary
        }
    }

    var isResolved: Bool {
        self == .ours || self == .theirs
    }
}
```

**Step 2: Add resolution field to ConflictInfo**

Change `ConflictInfo` struct (line 82-101) to include resolution:

```swift
struct ConflictInfo: Identifiable, Equatable, Sendable {
    let id: UUID
    let filePath: String
    let conflictType: ConflictType
    let ours: String?
    let theirs: String?
    var resolution: ConflictResolution

    init(
        id: UUID = UUID(),
        filePath: String,
        conflictType: ConflictType,
        ours: String? = nil,
        theirs: String? = nil,
        resolution: ConflictResolution = .pending
    ) {
        self.id = id
        self.filePath = filePath
        self.conflictType = conflictType
        self.ours = ours
        self.theirs = theirs
        self.resolution = resolution
    }
}
```

**Step 3: Update getConflicts() in EngineClient.swift to read resolution field**

In `getConflicts()` (around line 970), change the `ConflictInfo` constructor call:

```swift
            let conflict = ConflictInfo(
                filePath: String(cString: ptr.pointee.file_path),
                conflictType: ConflictType(rawString: String(cString: ptr.pointee.conflict_type)),
                ours: ours,
                theirs: theirs,
                resolution: ConflictResolution(rawValue: UInt8(ptr.pointee.resolution)) ?? .pending
            )
```

**Step 4: Add resolveConflict() to EngineClient.swift**

Add after `getConflicts()` method:

```swift
    /// Resolve a single file in a conflicted merge.
    /// Wraps `tm_conflict_resolve()`.
    func resolveConflict(workerId: UInt32, filePath: String, resolution: ConflictResolution) -> Bool {
        lastError = nil
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("Engine not created")
            return false
        }

        let result = filePath.withCString { cPath in
            tm_conflict_resolve(engine, workerId, cPath, Int32(resolution.rawValue))
        }

        if result != TM_OK {
            let msg = lastEngineError() ?? "tm_conflict_resolve failed (\(result.rawValue))"
            lastError = msg
            Self.logger.error("resolveConflict failed: \(msg)")
            return false
        }

        // Refresh conflicts to update resolution state
        pendingConflicts[workerId] = getConflicts(workerId: workerId)
        return true
    }
```

**Step 5: Add finalizeMerge() to EngineClient.swift**

Add after `resolveConflict()`:

```swift
    /// Finalize a conflicted merge after all files are resolved.
    /// Wraps `tm_conflict_finalize()`. Returns `true` on success.
    func finalizeMerge(workerId: UInt32) -> Bool {
        lastError = nil
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("Engine not created")
            return false
        }

        let result = tm_conflict_finalize(engine, workerId)

        if result == TM_ERR_CLEANUP_INCOMPLETE {
            let engineMsg = lastEngineError() ?? "worktree cleanup was incomplete"
            let warning = "Merge finalized but \(engineMsg). Manual cleanup may be needed."
            lastError = warning
            Self.logger.warning("finalizeMerge: worker \(workerId) \(warning)")
        } else if result != TM_OK {
            let msg = lastEngineError() ?? "tm_conflict_finalize failed (\(result.rawValue))"
            lastError = msg
            Self.logger.error("finalizeMerge failed: \(msg)")
            return false
        }

        mergeStatuses[workerId] = .success
        pendingConflicts.removeValue(forKey: workerId)
        return true
    }
```

**Step 6: Build**

Run: `./build.sh`
Expected: Build succeeds.

**Step 7: Commit**

```bash
git add macos/Sources/Teammux/Models/MergeTypes.swift macos/Sources/Teammux/Engine/EngineClient.swift
git commit -m "feat(s10): add ConflictResolution type and resolve/finalize bridge methods"
```

---

### Task 6: Swift UI — ConflictView per-file resolution

**Files:**
- Modify: `macos/Sources/Teammux/RightPane/ConflictView.swift`

**Step 1: Update ConflictView to use @State for mutable conflicts**

The ConflictView currently takes `let conflicts: [ConflictInfo]`. Since resolution changes update the `engine.pendingConflicts` published property, the view should read from the engine directly. Change the struct:

```swift
struct ConflictView: View {
    let worker: WorkerInfo
    @ObservedObject var engine: EngineClient
    @Environment(\.dismiss) var dismiss

    @State private var isActionInFlight = false
    @State private var actionError: String?

    private var conflicts: [ConflictInfo] {
        engine.pendingConflicts[worker.id] ?? []
    }

    /// True when all files have resolution ours or theirs.
    private var allResolved: Bool {
        let c = conflicts
        return !c.isEmpty && c.allSatisfy { $0.resolution.isResolved }
    }
```

Remove the `let conflicts: [ConflictInfo]` property.

**Step 2: Update footer — replace Force Merge with Finalize Merge**

Replace the `footer` computed property:

```swift
    private var footer: some View {
        VStack(spacing: 8) {
            if let error = actionError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                Button(action: finalizeMerge) {
                    if isActionInFlight {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Finalize Merge", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .disabled(isActionInFlight || !allResolved)
                .help(allResolved ? "Complete the merge" : "Resolve all files first")

                Button(action: reject) {
                    Label("Reject", systemImage: "xmark.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isActionInFlight)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .disabled(isActionInFlight)
            }
        }
        .padding()
    }
```

**Step 3: Replace forceMerge action with finalizeMerge**

Replace the `forceMerge()` function:

```swift
    private func finalizeMerge() {
        isActionInFlight = true
        actionError = nil
        Task { @MainActor in
            let success = engine.finalizeMerge(workerId: worker.id)
            if success {
                dismiss()
            } else {
                actionError = engine.lastError ?? "Finalize merge failed"
            }
            isActionInFlight = false
        }
    }
```

**Step 4: Update ConflictFileRow to include resolution buttons**

Replace the entire `ConflictFileRow` struct:

```swift
struct ConflictFileRow: View {
    let conflict: ConflictInfo
    let workerId: UInt32
    @ObservedObject var engine: EngineClient

    @State private var isResolving = false
    @State private var resolveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // File path, conflict type, and resolution badge
            HStack(spacing: 8) {
                Image(systemName: conflict.resolution.isResolved ? "checkmark.circle.fill" : "doc.text")
                    .font(.system(size: 10))
                    .foregroundColor(conflict.resolution.isResolved ? .green : .red)

                Text(conflict.filePath)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                // Resolution badge
                Text(conflict.resolution.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(conflict.resolution.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(conflict.resolution.color.opacity(0.12))
                    .cornerRadius(4)

                Text(conflict.conflictType.displayName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(4)
            }

            // Ours preview
            if let ours = conflict.ours, !ours.isEmpty {
                conflictPreview(label: "ours (main)", content: ours, color: .green)
            }

            // Theirs preview
            if let theirs = conflict.theirs, !theirs.isEmpty {
                conflictPreview(label: "theirs (worker)", content: theirs, color: .blue)
            }

            // Resolution buttons
            HStack(spacing: 8) {
                Button(action: { resolve(.ours) }) {
                    Label("Accept Ours", systemImage: "arrow.left.circle")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.green)
                .disabled(isResolving || conflict.resolution == .ours)

                Button(action: { resolve(.theirs) }) {
                    Label("Accept Theirs", systemImage: "arrow.right.circle")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.blue)
                .disabled(isResolving || conflict.resolution == .theirs)

                Button(action: { resolve(.skip) }) {
                    Label("Skip", systemImage: "forward.circle")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.orange)
                .disabled(isResolving || conflict.resolution == .skip)

                if isResolving {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()
            }

            if let error = resolveError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }

    private func resolve(_ resolution: ConflictResolution) {
        isResolving = true
        resolveError = nil
        Task { @MainActor in
            let success = engine.resolveConflict(
                workerId: workerId,
                filePath: conflict.filePath,
                resolution: resolution
            )
            if !success {
                resolveError = engine.lastError ?? "Resolution failed"
            }
            isResolving = false
        }
    }

    private func conflictPreview(label: String, content: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(color)

            Text(content)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(color.opacity(0.06))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(color.opacity(0.2), lineWidth: 1)
                )
        }
    }
}
```

**Step 5: Update ConflictView conflictList to pass workerId and engine**

Change the `conflictList` computed property:

```swift
    private var conflictList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(conflicts) { conflict in
                    ConflictFileRow(
                        conflict: conflict,
                        workerId: worker.id,
                        engine: engine
                    )
                }
            }
            .padding()
        }
    }
```

**Step 6: Update GitWorkerRow ConflictView sheet call**

In `macos/Sources/Teammux/RightPane/GitView.swift`, the `.sheet` modifier (line 337) passes `conflicts:` — remove that parameter since ConflictView now reads from engine directly:

```swift
        .sheet(isPresented: $showConflictSheet) {
            ConflictView(
                worker: worker,
                engine: engine
            )
        }
```

**Step 7: Build**

Run: `./build.sh`
Expected: Build succeeds.

**Step 8: Commit**

```bash
git add macos/Sources/Teammux/RightPane/ConflictView.swift macos/Sources/Teammux/RightPane/GitView.swift
git commit -m "feat(s10): per-file conflict resolution UI with Finalize Merge button"
```

---

### Task 7: Build verification + final engine test run

**Step 1: Run engine tests**

Run: `cd engine && zig build test`
Expected: All tests pass. Count should be baseline + 9 new tests (3 resolveConflict validation + 2 finalizeMerge validation + 2 approve/reject resolution wiring + 2 resolve+finalize integration + 2 null-safety C API).

**Step 2: Full build**

Run: `./build.sh`
Expected: Build succeeds with no warnings.

**Step 3: Commit any fixups if needed**

If build/tests revealed issues, fix and commit.
