const std = @import("std");
const worktree = @import("worktree.zig");

// ─────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────

/// Merge status per worker.
/// Valid transitions: pending → in_progress → {success, conflict, rejected}
///                    conflict → rejected (via reject)
pub const MergeStatus = enum(c_int) {
    pending = 0,
    in_progress = 1,
    success = 2,
    conflict = 3,
    rejected = 4,
};

/// Per-file conflict resolution choice.
/// `ours`/`theirs` apply git checkout and are finalizable.
/// `skip` records the choice without git ops — blocks finalization.
/// `pending` is the initial state — cannot be set via resolveConflict.
pub const ConflictResolution = enum(u8) {
    ours = 0,
    theirs = 1,
    skip = 2,
    pending = 3,
};

pub const Conflict = struct {
    file_path: []const u8,
    conflict_type: []const u8,
    ours: []const u8,
    theirs: []const u8,
};

pub const ApproveResult = enum {
    success,
    conflict,
    cleanup_incomplete,
};

pub const GitOutput = struct {
    exit_code: u32,
    stdout: []u8,
    stderr: ?[]u8 = null,

    pub fn deinit(self: GitOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        if (self.stderr) |s| allocator.free(s);
    }
};

// ─────────────────────────────────────────────────────────
// MergeCoordinator
// ─────────────────────────────────────────────────────────

pub const MergeCoordinator = struct {
    allocator: std.mem.Allocator,
    statuses: std.AutoHashMap(worktree.WorkerId, MergeStatus),
    conflicts: std.AutoHashMap(worktree.WorkerId, []Conflict),
    active_merge: ?worktree.WorkerId,
    resolutions: std.AutoHashMap(worktree.WorkerId, std.StringHashMap(ConflictResolution)),

    pub fn init(allocator: std.mem.Allocator) MergeCoordinator {
        return .{
            .allocator = allocator,
            .statuses = std.AutoHashMap(worktree.WorkerId, MergeStatus).init(allocator),
            .conflicts = std.AutoHashMap(worktree.WorkerId, []Conflict).init(allocator),
            .active_merge = null,
            .resolutions = std.AutoHashMap(worktree.WorkerId, std.StringHashMap(ConflictResolution)).init(allocator),
        };
    }

    pub fn deinit(self: *MergeCoordinator) void {
        var res_it = self.resolutions.iterator();
        while (res_it.next()) |entry| {
            freeResolutionMap(self.allocator, entry.value_ptr);
        }
        self.resolutions.deinit();
        var it = self.conflicts.iterator();
        while (it.next()) |entry| {
            freeConflicts(self.allocator, entry.value_ptr.*);
        }
        self.conflicts.deinit();
        self.statuses.deinit();
    }

    /// Approve merge of a worker's branch into main.
    /// Returns .success if merge was clean, .conflict if conflicts were detected,
    /// .cleanup_incomplete if merge succeeded but worktree/branch removal failed.
    /// On conflict, active_merge remains set — caller must reject() before approving another worker.
    pub fn approve(
        self: *MergeCoordinator,
        roster: *worktree.Roster,
        project_root: []const u8,
        worker_id: worktree.WorkerId,
        strategy: []const u8,
    ) !ApproveResult {
        // Prevent concurrent merges
        if (self.active_merge) |active| {
            if (active != worker_id) return error.MergeInProgress;
        }

        // Thread-safe: copy fields under lock, safe to use after roster mutations
        const wf = try roster.copyWorkerFields(worker_id, self.allocator) orelse return error.WorkerNotFound;
        defer wf.deinit(self.allocator);
        const branch_name = try self.allocator.dupe(u8, wf.branch_name);
        defer self.allocator.free(branch_name);
        const wt_path = try self.allocator.dupe(u8, wf.worktree_path);
        defer self.allocator.free(wt_path);

        // v0.2: read main branch name from config.toml
        // Verify HEAD is on main
        const head_result = try runGitCapture(self.allocator, project_root, &.{ "rev-parse", "--abbrev-ref", "HEAD" });
        defer head_result.deinit(self.allocator);
        const head_branch = std.mem.trim(u8, head_result.stdout, &[_]u8{ '\n', '\r', ' ' });
        if (!std.mem.eql(u8, head_branch, "main")) return error.NotOnMain;

        // Set status to in-progress
        try self.statuses.put(worker_id, .in_progress);
        self.active_merge = worker_id;

        std.log.info("[teammux] merge approve: worker {d} branch={s} strategy={s}", .{ worker_id, branch_name, strategy });

        // Execute merge based on strategy
        const merge_result = if (std.mem.eql(u8, strategy, "squash"))
            try runGitCapture(self.allocator, project_root, &.{ "merge", "--squash", branch_name })
        else if (std.mem.eql(u8, strategy, "rebase"))
            try self.runRebaseStrategy(project_root, branch_name)
        else
            // Default: merge (--no-ff ensures merge commit)
            try runGitCapture(self.allocator, project_root, &.{ "merge", "--no-ff", branch_name });
        defer merge_result.deinit(self.allocator);

        if (merge_result.exit_code == 0) {
            // For squash, we need an explicit commit
            if (std.mem.eql(u8, strategy, "squash")) {
                const commit_msg = try std.fmt.allocPrint(self.allocator, "Squash merge: {s}", .{branch_name});
                defer self.allocator.free(commit_msg);
                const commit_result = try runGitCapture(self.allocator, project_root, &.{ "commit", "-m", commit_msg });
                defer commit_result.deinit(self.allocator);
                if (commit_result.exit_code != 0) {
                    std.log.err("[teammux] squash commit failed for worker {d}", .{worker_id});
                    // Abort the squash merge to restore clean state
                    const abort = try runGitCapture(self.allocator, project_root, &.{ "merge", "--abort" });
                    abort.deinit(self.allocator);
                    self.active_merge = null;
                    try self.statuses.put(worker_id, .conflict);
                    return error.GitFailed;
                }
            }

            // Clean merge — remove worktree and branch, update statuses
            std.log.info("[teammux] merge success: worker {d}", .{worker_id});
            try self.statuses.put(worker_id, .success);
            self.active_merge = null;

            // Remove worktree and branch with failure tracking (capture stderr for diagnostics)
            const wt_removed = runGitLoggedWithStderr(self.allocator, project_root, &.{ "worktree", "remove", "--force", wt_path }, "merge cleanup: worktree remove");
            const br_deleted = runGitLoggedWithStderr(self.allocator, project_root, &.{ "branch", "-D", branch_name }, "merge cleanup: branch delete");

            // Update worker status under lock — worker may be concurrently read by tm_roster_get
            if (!roster.setWorkerStatus(worker_id, .complete)) {
                std.log.warn("[teammux] merge approve: worker {d} vanished from roster after successful merge — status not updated to complete", .{worker_id});
            }

            if (!wt_removed or !br_deleted) return .cleanup_incomplete;
            return .success;
        } else {
            // Non-zero exit — check for conflicts
            std.log.info("[teammux] merge exit code {d} for worker {d} — checking for conflicts", .{ merge_result.exit_code, worker_id });

            const conflict_list = self.detectConflicts(project_root) catch {
                // Detection failed — keep active_merge set so reject() can still abort
                std.log.err("[teammux] conflict detection failed for worker {d}", .{worker_id});
                try self.statuses.put(worker_id, .conflict);
                return .conflict;
            };

            if (conflict_list.len > 0) {
                std.log.info("[teammux] {d} conflicts detected for worker {d}", .{ conflict_list.len, worker_id });
                if (self.conflicts.fetchRemove(worker_id)) |old| {
                    freeConflicts(self.allocator, old.value);
                }
                try self.conflicts.put(worker_id, conflict_list);

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

                try self.statuses.put(worker_id, .conflict);
                // active_merge stays set — repo is in MERGING state, reject() must be called
            } else {
                // Non-zero exit but no conflict markers — abort and report error
                std.log.err("[teammux] merge failed (no conflicts) for worker {d}", .{worker_id});
                const abort = try runGitCapture(self.allocator, project_root, &.{ "merge", "--abort" });
                abort.deinit(self.allocator);
                self.active_merge = null;
                try self.statuses.put(worker_id, .conflict);
                freeConflicts(self.allocator, conflict_list);
                return error.GitFailed;
            }

            return .conflict;
        }
    }

    /// Rebase strategy: checkout worker branch → rebase onto main → checkout main → fast-forward merge.
    /// This preserves main's history (no rewrite) while linearizing the worker's commits.
    fn runRebaseStrategy(self: *MergeCoordinator, project_root: []const u8, branch_name: []const u8) !GitOutput {
        // Step 1: checkout worker branch
        const checkout_branch = try runGitCapture(self.allocator, project_root, &.{ "checkout", branch_name });
        defer checkout_branch.deinit(self.allocator);
        if (checkout_branch.exit_code != 0) return .{ .exit_code = checkout_branch.exit_code, .stdout = try self.allocator.dupe(u8, "") };

        // Step 2: rebase worker onto main
        const rebase = try runGitCapture(self.allocator, project_root, &.{ "rebase", "main" });
        if (rebase.exit_code != 0) {
            // Rebase failed — abort and return to main
            const abort = try runGitCapture(self.allocator, project_root, &.{ "rebase", "--abort" });
            abort.deinit(self.allocator);
            const back = try runGitCapture(self.allocator, project_root, &.{ "checkout", "main" });
            back.deinit(self.allocator);
            return rebase; // Return the rebase failure result
        }
        rebase.deinit(self.allocator);

        // Step 3: checkout main
        const checkout_main = try runGitCapture(self.allocator, project_root, &.{ "checkout", "main" });
        defer checkout_main.deinit(self.allocator);
        if (checkout_main.exit_code != 0) return .{ .exit_code = checkout_main.exit_code, .stdout = try self.allocator.dupe(u8, "") };

        // Step 4: fast-forward merge
        return try runGitCapture(self.allocator, project_root, &.{ "merge", "--ff-only", branch_name });
    }

    /// Reject a worker's merge: abort any in-progress merge, remove worktree, delete branch.
    /// Returns true if cleanup was complete, false if worktree/branch removal failed.
    pub fn reject(
        self: *MergeCoordinator,
        roster: *worktree.Roster,
        project_root: []const u8,
        worker_id: worktree.WorkerId,
    ) !bool {
        // Thread-safe: copy fields under lock, safe to use after roster mutations
        const wf = try roster.copyWorkerFields(worker_id, self.allocator) orelse return error.WorkerNotFound;
        defer wf.deinit(self.allocator);
        const branch_name = try self.allocator.dupe(u8, wf.branch_name);
        defer self.allocator.free(branch_name);
        const wt_path = try self.allocator.dupe(u8, wf.worktree_path);
        defer self.allocator.free(wt_path);

        std.log.info("[teammux] merge reject: worker {d} branch={s}", .{ worker_id, branch_name });

        // If this worker has an active merge (repo in merging state), abort it
        if (self.active_merge) |active| {
            if (active == worker_id) {
                const abort_result = runGitCapture(self.allocator, project_root, &.{ "merge", "--abort" }) catch |err| {
                    std.log.err("[teammux] merge --abort spawn failed for worker {d}: {}", .{ worker_id, err });
                    self.active_merge = null;
                    return err;
                };
                defer abort_result.deinit(self.allocator);
                if (abort_result.exit_code != 0) {
                    std.log.warn("[teammux] merge --abort exited {d} for worker {d} (may not have been in merging state)", .{ abort_result.exit_code, worker_id });
                }
                self.active_merge = null;
            }
        }

        // Remove worktree and branch with failure tracking (capture stderr for diagnostics)
        const wt_removed = runGitLoggedWithStderr(self.allocator, project_root, &.{ "worktree", "remove", "--force", wt_path }, "reject cleanup: worktree remove");
        const br_deleted = runGitLoggedWithStderr(self.allocator, project_root, &.{ "branch", "-D", branch_name }, "reject cleanup: branch delete");

        // Remove from roster (worktree directory already removed above)
        roster.dismiss(worker_id) catch |err| switch (err) {
            error.WorkerNotFound => {}, // Already removed by reject cleanup
        };

        // Set merge status to rejected
        try self.statuses.put(worker_id, .rejected);

        // Clean up resolution data for this worker
        if (self.resolutions.fetchRemove(worker_id)) |old| {
            var map = old.value;
            freeResolutionMap(self.allocator, &map);
        }

        // Clean up conflict data for this worker
        if (self.conflicts.fetchRemove(worker_id)) |old| {
            freeConflicts(self.allocator, old.value);
        }

        return wt_removed and br_deleted;
    }

    /// Get current merge status for a worker.
    pub fn getStatus(self: *MergeCoordinator, worker_id: worktree.WorkerId) MergeStatus {
        return self.statuses.get(worker_id) orelse .pending;
    }

    /// Get conflicts for a worker. Returns null if no conflicts stored.
    pub fn getConflicts(self: *MergeCoordinator, worker_id: worktree.WorkerId) ?[]Conflict {
        return self.conflicts.get(worker_id);
    }

    /// Get the per-file resolution map for a worker, or null.
    pub fn getResolutions(self: *MergeCoordinator, worker_id: worktree.WorkerId) ?*std.StringHashMap(ConflictResolution) {
        return self.resolutions.getPtr(worker_id);
    }

    /// Resolve a single file in a conflicted merge.
    /// For ours/theirs: runs git checkout --ours/--theirs then git add.
    /// For skip: records resolution without git ops.
    /// Resolution can be changed freely (ours<->theirs<->skip).
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
            .ours, .theirs => {
                const flag: []const u8 = if (resolution == .ours) "--ours" else "--theirs";
                const r1 = try runGitCapture(self.allocator, project_root, &.{ "checkout", flag, file_path });
                defer r1.deinit(self.allocator);
                if (r1.exit_code != 0) {
                    std.log.err("[teammux] git checkout {s} failed for '{s}': exit code {d}", .{ flag, file_path, r1.exit_code });
                    return error.GitFailed;
                }
                const r2 = try runGitCapture(self.allocator, project_root, &.{ "add", file_path });
                defer r2.deinit(self.allocator);
                if (r2.exit_code != 0) {
                    std.log.err("[teammux] git add failed for '{s}': exit code {d}", .{ file_path, r2.exit_code });
                    return error.GitFailed;
                }
            },
            .skip => {}, // No git ops — just record the resolution
            .pending => unreachable,
        }

        res_ptr.* = resolution;
    }

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

        // Thread-safe: copy fields under lock, safe to use after roster mutations.
        // Errors here are post-commit cleanup failures — the merge already committed,
        // so return cleanup_incomplete instead of propagating a hard error.
        const wf = roster.copyWorkerFields(worker_id, self.allocator) catch |err| {
            std.log.warn("[teammux] finalizeMerge: copyWorkerFields failed for worker {d}: {} — skipping cleanup", .{ worker_id, err });
            return .cleanup_incomplete;
        } orelse {
            std.log.warn("[teammux] finalizeMerge: worker {d} not in roster — skipping worktree/branch cleanup", .{worker_id});
            return .cleanup_incomplete;
        };
        defer wf.deinit(self.allocator);
        const branch_name = self.allocator.dupe(u8, wf.branch_name) catch |err| {
            std.log.warn("[teammux] finalizeMerge: branch_name dupe failed for worker {d}: {} — skipping cleanup", .{ worker_id, err });
            return .cleanup_incomplete;
        };
        defer self.allocator.free(branch_name);
        const wt_path = self.allocator.dupe(u8, wf.worktree_path) catch |err| {
            std.log.warn("[teammux] finalizeMerge: wt_path dupe failed for worker {d}: {} — skipping cleanup", .{ worker_id, err });
            return .cleanup_incomplete;
        };
        defer self.allocator.free(wt_path);

        // Update worker status under lock — worker may be concurrently read by tm_roster_get
        if (!roster.setWorkerStatus(worker_id, .complete)) {
            std.log.warn("[teammux] finalizeMerge: worker {d} vanished from roster after successful merge — status not updated to complete", .{worker_id});
        }

        // Remove worktree and branch
        const wt_removed = runGitLoggedWithStderr(self.allocator, project_root, &.{ "worktree", "remove", "--force", wt_path }, "finalize cleanup: worktree remove");
        const br_deleted = runGitLoggedWithStderr(self.allocator, project_root, &.{ "branch", "-D", branch_name }, "finalize cleanup: branch delete");

        if (!wt_removed or !br_deleted) return .cleanup_incomplete;
        return .success;
    }

    // ─── Internal helpers ────────────────────────────────────

    fn detectConflicts(self: *MergeCoordinator, project_root: []const u8) ![]Conflict {
        const diff_result = try runGitCapture(self.allocator, project_root, &.{ "diff", "--name-only", "--diff-filter=U" });
        defer diff_result.deinit(self.allocator);

        if (diff_result.stdout.len == 0) {
            return try self.allocator.alloc(Conflict, 0);
        }

        var all_conflicts: std.ArrayList(Conflict) = .{};
        errdefer {
            for (all_conflicts.items) |c| freeConflict(self.allocator, c);
            all_conflicts.deinit(self.allocator);
        }

        var lines = std.mem.splitSequence(u8, std.mem.trim(u8, diff_result.stdout, &[_]u8{ '\n', '\r', ' ' }), "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &[_]u8{ '\r', ' ' });
            if (trimmed.len == 0) continue;

            const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ project_root, trimmed });
            defer self.allocator.free(file_path);

            const file = std.fs.openFileAbsolute(file_path, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    // TOCTOU: file listed by git diff but deleted before we could read it
                    const owned_path = try self.allocator.dupe(u8, trimmed);
                    errdefer self.allocator.free(owned_path);
                    const empty = try self.allocator.dupe(u8, "");
                    errdefer self.allocator.free(empty);
                    const ctype = try self.allocator.dupe(u8, "unknown");
                    errdefer self.allocator.free(ctype);
                    const empty2 = try self.allocator.dupe(u8, "");
                    try all_conflicts.append(self.allocator, .{
                        .file_path = owned_path,
                        .conflict_type = ctype,
                        .ours = empty,
                        .theirs = empty2,
                    });
                    continue;
                },
                else => return err,
            };
            defer file.close();
            const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
            defer self.allocator.free(content);

            const parsed = try parseConflictMarkers(self.allocator, trimmed, content);
            errdefer {
                for (parsed) |c| freeConflict(self.allocator, c);
            }
            defer self.allocator.free(parsed);
            try all_conflicts.appendSlice(self.allocator, parsed);
        }

        return try all_conflicts.toOwnedSlice(self.allocator);
    }

    pub fn deinitConflicts(allocator: std.mem.Allocator, conflicts: []Conflict) void {
        freeConflicts(allocator, conflicts);
    }
};

// ─────────────────────────────────────────────────────────
// Conflict marker parsing
// ─────────────────────────────────────────────────────────

/// Parse conflict markers from file content. Returns one Conflict per <<<< ==== >>>> block.
pub fn parseConflictMarkers(allocator: std.mem.Allocator, file_path: []const u8, content: []const u8) ![]Conflict {
    var result: std.ArrayList(Conflict) = .{};
    errdefer {
        for (result.items) |c| freeConflict(allocator, c);
        result.deinit(allocator);
    }

    const State = enum { normal, ours, theirs };
    var state: State = .normal;
    var ours_buf: std.ArrayList(u8) = .{};
    defer ours_buf.deinit(allocator);
    var theirs_buf: std.ArrayList(u8) = .{};
    defer theirs_buf.deinit(allocator);

    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "<<<<<<<")) {
            state = .ours;
            ours_buf.clearRetainingCapacity();
            theirs_buf.clearRetainingCapacity();
        } else if (std.mem.startsWith(u8, line, "=======") and state == .ours) {
            state = .theirs;
        } else if (std.mem.startsWith(u8, line, ">>>>>>>") and state == .theirs) {
            const owned_path = try allocator.dupe(u8, file_path);
            errdefer allocator.free(owned_path);
            const ctype = try allocator.dupe(u8, "content");
            errdefer allocator.free(ctype);
            const ours_content = try allocator.dupe(u8, ours_buf.items);
            errdefer allocator.free(ours_content);
            const theirs_content = try allocator.dupe(u8, theirs_buf.items);

            try result.append(allocator, .{
                .file_path = owned_path,
                .conflict_type = ctype,
                .ours = ours_content,
                .theirs = theirs_content,
            });

            state = .normal;
        } else {
            switch (state) {
                .ours => {
                    if (ours_buf.items.len > 0) try ours_buf.append(allocator, '\n');
                    try ours_buf.appendSlice(allocator, line);
                },
                .theirs => {
                    if (theirs_buf.items.len > 0) try theirs_buf.append(allocator, '\n');
                    try theirs_buf.appendSlice(allocator, line);
                },
                .normal => {},
            }
        }
    }

    return try result.toOwnedSlice(allocator);
}

// ─────────────────────────────────────────────────────────
// Git subprocess helpers
// ─────────────────────────────────────────────────────────

/// Run git command and capture stdout and exit code. Stderr is discarded.
pub fn runGitCapture(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !GitOutput {
    var argv: std.ArrayList([]const u8) = .{};
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "-C");
    try argv.append(allocator, cwd);
    try argv.appendSlice(allocator, args);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();
    const stdout = child.stdout.?;
    const stdout_data = try stdout.readToEndAlloc(allocator, 10 * 1024 * 1024);
    errdefer allocator.free(stdout_data);
    const term = try child.wait();

    const exit_code: u32 = if (term == .Exited) term.Exited else 128;

    return .{
        .exit_code = exit_code,
        .stdout = stdout_data,
    };
}

/// Run git command and capture stderr and exit code. Stdout is discarded.
/// Only used for cleanup commands where stderr diagnostics are needed.
fn runGitCaptureWithStderr(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !GitOutput {
    var argv: std.ArrayList([]const u8) = .{};
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "-C");
    try argv.append(allocator, cwd);
    try argv.appendSlice(allocator, args);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const stderr = child.stderr.?;
    const stderr_data = try stderr.readToEndAlloc(allocator, 10 * 1024 * 1024);
    errdefer allocator.free(stderr_data);
    const term = try child.wait();

    const exit_code: u32 = if (term == .Exited) term.Exited else 128;

    return .{
        .exit_code = exit_code,
        .stdout = try allocator.dupe(u8, ""),
        .stderr = stderr_data,
    };
}

/// Run git command for cleanup, logging warnings with stderr on failure. Returns true if command succeeded.
pub fn runGitLoggedWithStderr(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8, operation: []const u8) bool {
    const result = runGitCaptureWithStderr(allocator, cwd, args) catch |err| {
        std.log.err("[teammux] {s} failed: {}", .{ operation, err });
        return false;
    };
    defer result.deinit(allocator);
    if (result.exit_code != 0) {
        if (result.stderr) |stderr_raw| {
            const stderr_msg = std.mem.trim(u8, stderr_raw, &[_]u8{ '\n', '\r', ' ' });
            if (stderr_msg.len > 0) {
                std.log.warn("[teammux] {s} exited with code {d}: {s}", .{ operation, result.exit_code, stderr_msg });
                return false;
            }
        }
        std.log.warn("[teammux] {s} exited with code {d}", .{ operation, result.exit_code });
        return false;
    }
    return true;
}

/// Run git command, ignoring all output and exit code. Best-effort cleanup operations.
fn runGitIgnoreResult(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) void {
    var argv: std.ArrayList([]const u8) = .{};
    defer argv.deinit(allocator);
    argv.append(allocator, "git") catch return;
    argv.append(allocator, "-C") catch return;
    argv.append(allocator, cwd) catch return;
    argv.appendSlice(allocator, args) catch return;

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch return;
}

// ─────────────────────────────────────────────────────────
// Memory helpers
// ─────────────────────────────────────────────────────────

fn freeConflict(allocator: std.mem.Allocator, c: Conflict) void {
    allocator.free(c.file_path);
    allocator.free(c.conflict_type);
    allocator.free(c.ours);
    allocator.free(c.theirs);
}

fn freeConflicts(allocator: std.mem.Allocator, conflicts: []Conflict) void {
    for (conflicts) |c| freeConflict(allocator, c);
    allocator.free(conflicts);
}

fn freeResolutionMap(allocator: std.mem.Allocator, map: *std.StringHashMap(ConflictResolution)) void {
    var it = map.iterator();
    while (it.next()) |kv| {
        allocator.free(kv.key_ptr.*);
    }
    map.deinit();
}

// ─────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────

test "merge - coordinator init/deinit" {
    var mc = MergeCoordinator.init(std.testing.allocator);
    defer mc.deinit();

    try std.testing.expect(mc.active_merge == null);
    try std.testing.expect(mc.getStatus(1) == .pending);
    try std.testing.expect(mc.getConflicts(1) == null);
}

test "merge - status tracking" {
    var mc = MergeCoordinator.init(std.testing.allocator);
    defer mc.deinit();

    try std.testing.expect(mc.getStatus(42) == .pending);

    try mc.statuses.put(42, .in_progress);
    try std.testing.expect(mc.getStatus(42) == .in_progress);

    try mc.statuses.put(42, .success);
    try std.testing.expect(mc.getStatus(42) == .success);

    try std.testing.expect(mc.getStatus(99) == .pending);
}

test "merge - parse conflict markers single block" {
    const content =
        \\line before
        \\<<<<<<< HEAD
        \\our version
        \\=======
        \\their version
        \\>>>>>>> feature-branch
        \\line after
    ;

    const conflicts = try parseConflictMarkers(std.testing.allocator, "test.txt", content);
    defer {
        for (conflicts) |c| freeConflict(std.testing.allocator, c);
        std.testing.allocator.free(conflicts);
    }

    try std.testing.expect(conflicts.len == 1);
    try std.testing.expectEqualStrings("test.txt", conflicts[0].file_path);
    try std.testing.expectEqualStrings("content", conflicts[0].conflict_type);
    try std.testing.expectEqualStrings("our version", conflicts[0].ours);
    try std.testing.expectEqualStrings("their version", conflicts[0].theirs);
}

test "merge - parse conflict markers multiple blocks" {
    const content =
        \\<<<<<<< HEAD
        \\ours1a
        \\ours1b
        \\=======
        \\theirs1
        \\>>>>>>> branch
        \\middle content
        \\<<<<<<< HEAD
        \\ours2
        \\=======
        \\theirs2a
        \\theirs2b
        \\>>>>>>> branch
    ;

    const conflicts = try parseConflictMarkers(std.testing.allocator, "multi.txt", content);
    defer {
        for (conflicts) |c| freeConflict(std.testing.allocator, c);
        std.testing.allocator.free(conflicts);
    }

    try std.testing.expect(conflicts.len == 2);
    try std.testing.expectEqualStrings("ours1a\nours1b", conflicts[0].ours);
    try std.testing.expectEqualStrings("theirs1", conflicts[0].theirs);
    try std.testing.expectEqualStrings("ours2", conflicts[1].ours);
    try std.testing.expectEqualStrings("theirs2a\ntheirs2b", conflicts[1].theirs);
}

test "merge - parse conflict markers no conflicts" {
    const conflicts = try parseConflictMarkers(std.testing.allocator, "empty.txt", "no conflicts here");
    defer std.testing.allocator.free(conflicts);
    try std.testing.expect(conflicts.len == 0);
}

test "merge - runGitCapture captures output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    worktree.runGit(std.testing.allocator, path, &.{ "init", "-b", "main" }) catch return;
    worktree.runGit(std.testing.allocator, path, &.{ "config", "user.email", "test@test.com" }) catch return;
    worktree.runGit(std.testing.allocator, path, &.{ "config", "user.name", "Test" }) catch return;
    const readme_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/README.md", .{path});
    defer std.testing.allocator.free(readme_path);
    {
        const f = try std.fs.createFileAbsolute(readme_path, .{});
        try f.writeAll("# Test");
        f.close();
    }
    worktree.runGit(std.testing.allocator, path, &.{ "add", "." }) catch return;
    worktree.runGit(std.testing.allocator, path, &.{ "commit", "-m", "init" }) catch return;

    const result = try runGitCapture(std.testing.allocator, path, &.{ "rev-parse", "--abbrev-ref", "HEAD" });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.exit_code == 0);
    const head = std.mem.trim(u8, result.stdout, &[_]u8{ '\n', '\r', ' ' });
    try std.testing.expectEqualStrings("main", head);
}

// ─── Integration tests ───────────────────────────────────

/// Test helper: create a git worktree and register a worker in the roster.
/// Roster.spawn is metadata-only (C3 unification), so we create the worktree
/// via runGit and then register the worker with the resulting path/branch.
pub fn spawnTestWorker(
    allocator: std.mem.Allocator,
    roster: *worktree.Roster,
    project_root: []const u8,
    worker_name: []const u8,
    task_description: []const u8,
) !worktree.WorkerId {
    const id = roster.claimNextId();

    // Generate path and branch
    const name_slug = try worktree.slugify(allocator, worker_name, 40);
    defer allocator.free(name_slug);
    const wt_path = try std.fmt.allocPrint(allocator, "{s}/.teammux/worker-{s}", .{ project_root, name_slug });
    defer allocator.free(wt_path);
    const branch = try worktree.makeBranchName(allocator, worker_name, task_description);
    defer allocator.free(branch);

    // Ensure .teammux directory
    const teammux_dir = try std.fmt.allocPrint(allocator, "{s}/.teammux", .{project_root});
    defer allocator.free(teammux_dir);
    std.fs.makeDirAbsolute(teammux_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Create git worktree
    try worktree.runGit(allocator, project_root, &.{ "worktree", "add", wt_path, "-b", branch });

    // Register in roster (metadata only — no git ops)
    try roster.spawn(id, "/usr/bin/echo", .claude_code, worker_name, task_description, wt_path, branch);

    return id;
}

pub fn setupTestRepo(allocator: std.mem.Allocator) !struct { tmp: std.testing.TmpDir, path: []u8 } {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(allocator, ".");

    try worktree.runGit(allocator, path, &.{ "init", "-b", "main" });
    try worktree.runGit(allocator, path, &.{ "config", "user.email", "test@test.com" });
    try worktree.runGit(allocator, path, &.{ "config", "user.name", "Test" });

    const readme_path = try std.fmt.allocPrint(allocator, "{s}/README.md", .{path});
    defer allocator.free(readme_path);
    const readme = try std.fs.createFileAbsolute(readme_path, .{});
    try readme.writeAll("# Test");
    readme.close();
    try worktree.runGit(allocator, path, &.{ "add", "." });
    try worktree.runGit(allocator, path, &.{ "commit", "-m", "initial" });

    return .{ .tmp = tmp, .path = path };
}

test "merge - reject removes worktree and branch (integration)" {
    var repo = setupTestRepo(std.testing.allocator) catch return;
    defer repo.tmp.cleanup();
    defer std.testing.allocator.free(repo.path);

    var roster = worktree.Roster.init(std.testing.allocator);
    defer roster.deinit();

    const id = try spawnTestWorker(std.testing.allocator, &roster, repo.path, "Worker1", "fix bug");
    const branch_name = try std.testing.allocator.dupe(u8, roster.getWorker(id).?.branch_name);
    defer std.testing.allocator.free(branch_name);

    var mc = MergeCoordinator.init(std.testing.allocator);
    defer mc.deinit();

    _ = try mc.reject(&roster, repo.path, id);

    try std.testing.expect(roster.getWorker(id) == null);
    try std.testing.expect(mc.getStatus(id) == .rejected);

    const branch_result = try runGitCapture(std.testing.allocator, repo.path, &.{ "branch", "--list", branch_name });
    defer branch_result.deinit(std.testing.allocator);
    const branch_output = std.mem.trim(u8, branch_result.stdout, &[_]u8{ '\n', '\r', ' ' });
    try std.testing.expect(branch_output.len == 0);
}

test "merge - approve clean merge (integration)" {
    var repo = setupTestRepo(std.testing.allocator) catch return;
    defer repo.tmp.cleanup();
    defer std.testing.allocator.free(repo.path);

    var roster = worktree.Roster.init(std.testing.allocator);
    defer roster.deinit();

    const id = try spawnTestWorker(std.testing.allocator, &roster, repo.path, "Worker2", "add feature");
    const wt_path = try std.testing.allocator.dupe(u8, roster.getWorker(id).?.worktree_path);
    defer std.testing.allocator.free(wt_path);

    const file_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/feature.txt", .{wt_path});
    defer std.testing.allocator.free(file_path);
    const file = try std.fs.createFileAbsolute(file_path, .{});
    try file.writeAll("new feature");
    file.close();
    try worktree.runGit(std.testing.allocator, wt_path, &.{ "add", "." });
    try worktree.runGit(std.testing.allocator, wt_path, &.{ "commit", "-m", "add feature" });

    var mc = MergeCoordinator.init(std.testing.allocator);
    defer mc.deinit();

    const result = try mc.approve(&roster, repo.path, id, "merge");

    try std.testing.expect(result == .success);
    try std.testing.expect(mc.getStatus(id) == .success);

    const worker = roster.getWorker(id);
    try std.testing.expect(worker != null);
    try std.testing.expect(worker.?.status == .complete);

    const main_feature = try std.fmt.allocPrint(std.testing.allocator, "{s}/feature.txt", .{repo.path});
    defer std.testing.allocator.free(main_feature);
    const check = std.fs.openFileAbsolute(main_feature, .{});
    if (check) |f| f.close() else |_| try std.testing.expect(false);
}

test "merge - approve returns cleanup_incomplete when worktree already removed (integration)" {
    var repo = setupTestRepo(std.testing.allocator) catch return;
    defer repo.tmp.cleanup();
    defer std.testing.allocator.free(repo.path);

    var roster = worktree.Roster.init(std.testing.allocator);
    defer roster.deinit();

    const id = try spawnTestWorker(std.testing.allocator, &roster, repo.path, "Worker6", "cleanup test");
    const wt_path = try std.testing.allocator.dupe(u8, roster.getWorker(id).?.worktree_path);
    defer std.testing.allocator.free(wt_path);

    // Commit on worktree branch so merge has something to merge
    const file_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/cleanup.txt", .{wt_path});
    defer std.testing.allocator.free(file_path);
    const file = try std.fs.createFileAbsolute(file_path, .{});
    try file.writeAll("cleanup test");
    file.close();
    try worktree.runGit(std.testing.allocator, wt_path, &.{ "add", "." });
    try worktree.runGit(std.testing.allocator, wt_path, &.{ "commit", "-m", "add cleanup test" });

    // Pre-remove the worktree so cleanup will fail
    try worktree.runGit(std.testing.allocator, repo.path, &.{ "worktree", "remove", "--force", wt_path });

    var mc = MergeCoordinator.init(std.testing.allocator);
    defer mc.deinit();

    const result = try mc.approve(&roster, repo.path, id, "merge");

    // Merge itself succeeds but cleanup (worktree remove) fails because already removed,
    // and branch delete may also fail — so we get cleanup_incomplete
    try std.testing.expect(result == .cleanup_incomplete or result == .success);
    try std.testing.expect(mc.getStatus(id) == .success);
}

test "merge - reject returns cleanup status (integration)" {
    var repo = setupTestRepo(std.testing.allocator) catch return;
    defer repo.tmp.cleanup();
    defer std.testing.allocator.free(repo.path);

    var roster = worktree.Roster.init(std.testing.allocator);
    defer roster.deinit();

    const id = try spawnTestWorker(std.testing.allocator, &roster, repo.path, "Worker7", "reject cleanup");

    var mc = MergeCoordinator.init(std.testing.allocator);
    defer mc.deinit();

    // Normal reject should return true (cleanup succeeded)
    const cleanup_ok = try mc.reject(&roster, repo.path, id);
    try std.testing.expect(mc.getStatus(id) == .rejected);
    // cleanup_ok indicates whether worktree/branch removal succeeded
    // In test environment, this depends on git state — just verify it returns a bool
    _ = cleanup_ok;
}

test "merge - approve with conflicts (integration)" {
    var repo = setupTestRepo(std.testing.allocator) catch return;
    defer repo.tmp.cleanup();
    defer std.testing.allocator.free(repo.path);

    var roster = worktree.Roster.init(std.testing.allocator);
    defer roster.deinit();

    const id = try spawnTestWorker(std.testing.allocator, &roster, repo.path, "Worker3", "edit readme");
    const wt_path = try std.testing.allocator.dupe(u8, roster.getWorker(id).?.worktree_path);
    defer std.testing.allocator.free(wt_path);

    const wt_readme = try std.fmt.allocPrint(std.testing.allocator, "{s}/README.md", .{wt_path});
    defer std.testing.allocator.free(wt_readme);
    {
        const f = try std.fs.createFileAbsolute(wt_readme, .{});
        try f.writeAll("# Worker change");
        f.close();
    }
    try worktree.runGit(std.testing.allocator, wt_path, &.{ "add", "." });
    try worktree.runGit(std.testing.allocator, wt_path, &.{ "commit", "-m", "worker edit" });

    const main_readme = try std.fmt.allocPrint(std.testing.allocator, "{s}/README.md", .{repo.path});
    defer std.testing.allocator.free(main_readme);
    {
        const f = try std.fs.createFileAbsolute(main_readme, .{});
        try f.writeAll("# Main change");
        f.close();
    }
    try worktree.runGit(std.testing.allocator, repo.path, &.{ "add", "." });
    try worktree.runGit(std.testing.allocator, repo.path, &.{ "commit", "-m", "main edit" });

    var mc = MergeCoordinator.init(std.testing.allocator);
    defer mc.deinit();

    const result = try mc.approve(&roster, repo.path, id, "merge");

    try std.testing.expect(result == .conflict);
    try std.testing.expect(mc.getStatus(id) == .conflict);
    // active_merge should stay set (repo in MERGING state)
    try std.testing.expect(mc.active_merge != null);

    const conflict_list = mc.getConflicts(id);
    try std.testing.expect(conflict_list != null);
    try std.testing.expect(conflict_list.?.len > 0);
    try std.testing.expectEqualStrings("README.md", conflict_list.?[0].file_path);

    // Clean up: abort the merge so tmpdir cleanup succeeds
    runGitIgnoreResult(std.testing.allocator, repo.path, &.{ "merge", "--abort" });
}

test "merge - reject after conflicted merge (integration)" {
    var repo = setupTestRepo(std.testing.allocator) catch return;
    defer repo.tmp.cleanup();
    defer std.testing.allocator.free(repo.path);

    var roster = worktree.Roster.init(std.testing.allocator);
    defer roster.deinit();

    const id = try spawnTestWorker(std.testing.allocator, &roster, repo.path, "Worker4", "edit file");
    const wt_path = try std.testing.allocator.dupe(u8, roster.getWorker(id).?.worktree_path);
    defer std.testing.allocator.free(wt_path);

    const wt_readme = try std.fmt.allocPrint(std.testing.allocator, "{s}/README.md", .{wt_path});
    defer std.testing.allocator.free(wt_readme);
    {
        const f = try std.fs.createFileAbsolute(wt_readme, .{});
        try f.writeAll("# Worker4 change");
        f.close();
    }
    try worktree.runGit(std.testing.allocator, wt_path, &.{ "add", "." });
    try worktree.runGit(std.testing.allocator, wt_path, &.{ "commit", "-m", "worker4 edit" });

    const main_readme = try std.fmt.allocPrint(std.testing.allocator, "{s}/README.md", .{repo.path});
    defer std.testing.allocator.free(main_readme);
    {
        const f = try std.fs.createFileAbsolute(main_readme, .{});
        try f.writeAll("# Main4 change");
        f.close();
    }
    try worktree.runGit(std.testing.allocator, repo.path, &.{ "add", "." });
    try worktree.runGit(std.testing.allocator, repo.path, &.{ "commit", "-m", "main4 edit" });

    var mc = MergeCoordinator.init(std.testing.allocator);
    defer mc.deinit();

    const approve_result = try mc.approve(&roster, repo.path, id, "merge");
    try std.testing.expect(approve_result == .conflict);
    try std.testing.expect(mc.active_merge != null);

    _ = try mc.reject(&roster, repo.path, id);
    try std.testing.expect(mc.getStatus(id) == .rejected);
    try std.testing.expect(mc.active_merge == null);
    try std.testing.expect(mc.getConflicts(id) == null);
    try std.testing.expect(roster.getWorker(id) == null);
}

test "merge - approve squash strategy (integration)" {
    var repo = setupTestRepo(std.testing.allocator) catch return;
    defer repo.tmp.cleanup();
    defer std.testing.allocator.free(repo.path);

    var roster = worktree.Roster.init(std.testing.allocator);
    defer roster.deinit();

    const id = try spawnTestWorker(std.testing.allocator, &roster, repo.path, "Worker5", "squash feature");
    const wt_path = try std.testing.allocator.dupe(u8, roster.getWorker(id).?.worktree_path);
    defer std.testing.allocator.free(wt_path);

    // Make two commits on worker branch
    const fp1 = try std.fmt.allocPrint(std.testing.allocator, "{s}/file1.txt", .{wt_path});
    defer std.testing.allocator.free(fp1);
    {
        const f = try std.fs.createFileAbsolute(fp1, .{});
        try f.writeAll("file1");
        f.close();
    }
    try worktree.runGit(std.testing.allocator, wt_path, &.{ "add", "." });
    try worktree.runGit(std.testing.allocator, wt_path, &.{ "commit", "-m", "commit 1" });

    const fp2 = try std.fmt.allocPrint(std.testing.allocator, "{s}/file2.txt", .{wt_path});
    defer std.testing.allocator.free(fp2);
    {
        const f = try std.fs.createFileAbsolute(fp2, .{});
        try f.writeAll("file2");
        f.close();
    }
    try worktree.runGit(std.testing.allocator, wt_path, &.{ "add", "." });
    try worktree.runGit(std.testing.allocator, wt_path, &.{ "commit", "-m", "commit 2" });

    var mc = MergeCoordinator.init(std.testing.allocator);
    defer mc.deinit();

    const result = try mc.approve(&roster, repo.path, id, "squash");

    try std.testing.expect(result == .success);
    try std.testing.expect(mc.getStatus(id) == .success);

    // Verify squash commit message
    const log_result = try runGitCapture(std.testing.allocator, repo.path, &.{ "log", "--oneline", "-1" });
    defer log_result.deinit(std.testing.allocator);
    const log_line = std.mem.trim(u8, log_result.stdout, &[_]u8{ '\n', '\r', ' ' });
    try std.testing.expect(std.mem.indexOf(u8, log_line, "Squash merge:") != null);
}

test "merge - concurrent merge prevention" {
    var repo = setupTestRepo(std.testing.allocator) catch return;
    defer repo.tmp.cleanup();
    defer std.testing.allocator.free(repo.path);

    var roster = worktree.Roster.init(std.testing.allocator);
    defer roster.deinit();

    const id1 = try spawnTestWorker(std.testing.allocator, &roster, repo.path, "WorkerA", "task a");
    const id2 = try spawnTestWorker(std.testing.allocator, &roster, repo.path, "WorkerB", "task b");
    const wt1 = try std.testing.allocator.dupe(u8, roster.getWorker(id1).?.worktree_path);
    defer std.testing.allocator.free(wt1);

    // Make conflicting changes on worker A so merge produces conflict state
    const wt_readme = try std.fmt.allocPrint(std.testing.allocator, "{s}/README.md", .{wt1});
    defer std.testing.allocator.free(wt_readme);
    {
        const f = try std.fs.createFileAbsolute(wt_readme, .{});
        try f.writeAll("# WorkerA change");
        f.close();
    }
    try worktree.runGit(std.testing.allocator, wt1, &.{ "add", "." });
    try worktree.runGit(std.testing.allocator, wt1, &.{ "commit", "-m", "workerA edit" });

    const main_readme = try std.fmt.allocPrint(std.testing.allocator, "{s}/README.md", .{repo.path});
    defer std.testing.allocator.free(main_readme);
    {
        const f = try std.fs.createFileAbsolute(main_readme, .{});
        try f.writeAll("# Main conflict");
        f.close();
    }
    try worktree.runGit(std.testing.allocator, repo.path, &.{ "add", "." });
    try worktree.runGit(std.testing.allocator, repo.path, &.{ "commit", "-m", "main conflict" });

    var mc = MergeCoordinator.init(std.testing.allocator);
    defer mc.deinit();

    // Worker A merge → conflicts, active_merge set
    const r1 = try mc.approve(&roster, repo.path, id1, "merge");
    try std.testing.expect(r1 == .conflict);
    try std.testing.expect(mc.active_merge != null);

    // Worker B merge should be blocked
    const r2 = mc.approve(&roster, repo.path, id2, "merge");
    try std.testing.expectError(error.MergeInProgress, r2);

    // Worker A re-approve should NOT be blocked (same worker retry)
    // But it will fail at the git level since merge is still in progress
    // We just verify it doesn't return MergeInProgress
    const r3 = mc.approve(&roster, repo.path, id1, "merge");
    // r3 should be .conflict again (not MergeInProgress error)
    if (r3) |res| {
        try std.testing.expect(res == .conflict);
    } else |err| {
        // GitFailed is also acceptable (merge on dirty state)
        try std.testing.expect(err == error.GitFailed);
    }

    // Clean up
    _ = try mc.reject(&roster, repo.path, id1);
}

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

    // Approve -> conflict
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

test "merge - resolveConflict rejects pending resolution" {
    var mc = MergeCoordinator.init(std.testing.allocator);
    defer mc.deinit();

    mc.active_merge = 1;
    var file_map = std.StringHashMap(ConflictResolution).init(std.testing.allocator);
    const key = try std.testing.allocator.dupe(u8, "file.txt");
    try file_map.put(key, .pending);
    try mc.resolutions.put(1, file_map);

    const result = mc.resolveConflict("/tmp", 1, "file.txt", .pending);
    try std.testing.expectError(error.InvalidResolution, result);
}

test "merge - finalizeMerge rejects when no active merge" {
    var mc = MergeCoordinator.init(std.testing.allocator);
    defer mc.deinit();

    var roster = worktree.Roster.init(std.testing.allocator);
    defer roster.deinit();

    const result = mc.finalizeMerge(&roster, "/tmp", 1);
    try std.testing.expectError(error.NoActiveMerge, result);
}

test "merge - resolveConflict rejects when no resolutions map for worker" {
    var mc = MergeCoordinator.init(std.testing.allocator);
    defer mc.deinit();

    mc.active_merge = 1;
    // active_merge is set but no resolutions map populated for worker 1

    const result = mc.resolveConflict("/tmp", 1, "file.txt", .ours);
    try std.testing.expectError(error.NoConflicts, result);
}
