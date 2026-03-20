const std = @import("std");
const config = @import("config.zig");

// ─────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────

pub const WorkerId = u32;

pub const WorkerStatus = enum(c_int) {
    idle = 0,
    working = 1,
    complete = 2,
    blocked = 3,
    err = 4,
};

pub const Worker = struct {
    id: WorkerId,
    name: []const u8,
    task_description: []const u8,
    branch_name: []const u8,
    worktree_path: []const u8,
    status: WorkerStatus,
    agent_type: config.AgentType,
    agent_binary: []const u8,
    model: []const u8,
    spawned_at: u64,
};

/// Caller-owned copy of worker fields, safe to use after releasing the
/// roster lock. Free with deinit().
pub const WorkerFields = struct {
    id: WorkerId,
    name: []const u8,
    task_description: []const u8,
    branch_name: []const u8,
    worktree_path: []const u8,
    status: WorkerStatus,
    agent_type: config.AgentType,
    agent_binary: []const u8,
    model: []const u8,
    spawned_at: u64,

    pub fn deinit(self: WorkerFields, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.task_description);
        allocator.free(self.branch_name);
        allocator.free(self.worktree_path);
        allocator.free(self.agent_binary);
        allocator.free(self.model);
    }
};

// ─────────────────────────────────────────────────────────
// Roster
// ─────────────────────────────────────────────────────────

pub const Roster = struct {
    allocator: std.mem.Allocator,
    workers: std.AutoHashMap(WorkerId, Worker),
    next_id: WorkerId,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) Roster {
        return .{
            .allocator = allocator,
            .workers = std.AutoHashMap(WorkerId, Worker).init(allocator),
            .next_id = 1, // 0 is TM_WORKER_TEAM_LEAD
            .mutex = .{},
        };
    }

    /// Claim the next available worker ID. The returned ID is reserved.
    /// Caller must subsequently call spawn() to fully create the worker
    /// entry, or call unclaimId() to release the slot on failure.
    pub fn claimNextId(self: *Roster) WorkerId {
        self.mutex.lock();
        defer self.mutex.unlock();
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    /// Release a claimed ID slot when spawn fails after claimNextId.
    /// Only reclaims if id == next_id - 1 (the most recently claimed);
    /// otherwise the slot is consumed. Non-contiguous reclaim would risk
    /// assigning a previously-used ID to a new worker (ID collision).
    pub fn unclaimId(self: *Roster, id: WorkerId) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.next_id > 0 and id == self.next_id - 1) {
            self.next_id -= 1;
        } else {
            std.log.warn("[teammux] unclaimId: slot {d} leaked (next_id={d}, non-contiguous reclaim unsafe)", .{ id, self.next_id });
        }
    }

    /// Register a worker with a pre-claimed ID and externally-created
    /// worktree metadata. All string arguments are duped; the roster
    /// owns the copies. Does NOT create git worktrees or context files —
    /// the caller (tm_worker_spawn) handles that via worktree_lifecycle.
    pub fn spawn(
        self: *Roster,
        id: WorkerId,
        agent_binary: []const u8,
        agent_type: config.AgentType,
        worker_name: []const u8,
        task_description: []const u8,
        worktree_path: []const u8,
        branch_name: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const owned_name = try self.allocator.dupe(u8, worker_name);
        errdefer self.allocator.free(owned_name);
        const owned_task = try self.allocator.dupe(u8, task_description);
        errdefer self.allocator.free(owned_task);
        const owned_binary = try self.allocator.dupe(u8, agent_binary);
        errdefer self.allocator.free(owned_binary);
        const owned_model = try self.allocator.dupe(u8, ""); // model set later via config
        errdefer self.allocator.free(owned_model);
        const owned_path = try self.allocator.dupe(u8, worktree_path);
        errdefer self.allocator.free(owned_path);
        const owned_branch = try self.allocator.dupe(u8, branch_name);
        errdefer self.allocator.free(owned_branch);

        try self.workers.put(id, .{
            .id = id,
            .name = owned_name,
            .task_description = owned_task,
            .branch_name = owned_branch,
            .worktree_path = owned_path,
            .status = .idle,
            .agent_type = agent_type,
            .agent_binary = owned_binary,
            .model = owned_model,
            .spawned_at = @intCast(std.time.timestamp()),
        });
    }

    /// Remove a worker from the roster and free owned memory.
    /// Does NOT remove git worktrees — the caller handles cleanup
    /// via worktree_lifecycle.removeWorker().
    pub fn dismiss(self: *Roster, worker_id: WorkerId) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const kv = self.workers.fetchRemove(worker_id) orelse return error.WorkerNotFound;
        const worker = kv.value;

        // Free owned memory
        self.allocator.free(worker.name);
        self.allocator.free(worker.task_description);
        self.allocator.free(worker.branch_name);
        self.allocator.free(worker.worktree_path);
        self.allocator.free(worker.agent_binary);
        self.allocator.free(worker.model);
    }

    /// Returns a raw internal pointer WITHOUT lock protection. Prefer
    /// copyWorkerFields() or hasWorker() for thread-safe access.
    /// Retained for test convenience only; no production callers.
    pub fn getWorker(self: *Roster, worker_id: WorkerId) ?*Worker {
        return self.workers.getPtr(worker_id);
    }

    /// Thread-safe: set a worker's status under the roster mutex.
    /// Returns false if worker not found. Prefer this over direct
    /// field mutation via getWorker().
    pub fn setWorkerStatus(self: *Roster, worker_id: WorkerId, status: WorkerStatus) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.workers.getPtr(worker_id)) |w| {
            w.status = status;
            return true;
        }
        return false;
    }

    /// Thread-safe: check whether a worker exists in the roster.
    pub fn hasWorker(self: *Roster, worker_id: WorkerId) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.workers.contains(worker_id);
    }

    /// Thread-safe copy of worker fields. All string fields are owned by
    /// the caller — free with WorkerFields.deinit(). Returns null if worker
    /// not found, error on allocation failure.
    pub fn copyWorkerFields(self: *Roster, worker_id: WorkerId, alloc: std.mem.Allocator) !?WorkerFields {
        self.mutex.lock();
        defer self.mutex.unlock();

        const w = self.workers.get(worker_id) orelse return null;

        const name = try alloc.dupe(u8, w.name);
        errdefer alloc.free(name);
        const task_desc = try alloc.dupe(u8, w.task_description);
        errdefer alloc.free(task_desc);
        const branch = try alloc.dupe(u8, w.branch_name);
        errdefer alloc.free(branch);
        const wt_path = try alloc.dupe(u8, w.worktree_path);
        errdefer alloc.free(wt_path);
        const binary = try alloc.dupe(u8, w.agent_binary);
        errdefer alloc.free(binary);
        const model = try alloc.dupe(u8, w.model);
        errdefer alloc.free(model);

        return .{
            .id = w.id,
            .name = name,
            .task_description = task_desc,
            .branch_name = branch,
            .worktree_path = wt_path,
            .status = w.status,
            .agent_type = w.agent_type,
            .agent_binary = binary,
            .model = model,
            .spawned_at = w.spawned_at,
        };
    }

    /// Does NOT acquire mutex. Only call from code that already holds self.mutex
    /// or from single-threaded contexts (tests). Use workers.count() directly
    /// when you already hold the lock.
    pub fn count(self: *Roster) u32 {
        return @intCast(self.workers.count());
    }

    pub fn deinit(self: *Roster) void {
        var it = self.workers.iterator();
        while (it.next()) |entry| {
            const w = entry.value_ptr;
            self.allocator.free(w.name);
            self.allocator.free(w.task_description);
            self.allocator.free(w.branch_name);
            self.allocator.free(w.worktree_path);
            self.allocator.free(w.agent_binary);
            self.allocator.free(w.model);
        }
        self.workers.deinit();
    }

    pub const WorkerNotFound = error{WorkerNotFound};
};

// ─────────────────────────────────────────────────────────
// Branch naming and slugification
// ─────────────────────────────────────────────────────────

/// Generate branch name: {worker-name-slug}/teammux-{task-slug}
pub fn makeBranchName(allocator: std.mem.Allocator, worker_name: []const u8, task_description: []const u8) ![]u8 {
    const name_slug = try slugify(allocator, worker_name, 40);
    defer allocator.free(name_slug);
    const task_slug = try slugify(allocator, task_description, 40);
    defer allocator.free(task_slug);
    return std.fmt.allocPrint(allocator, "{s}/teammux-{s}", .{ name_slug, task_slug });
}

/// Slugify: lowercase, spaces→hyphens, strip non-alphanumeric (except hyphens),
/// truncate to max_len, trim trailing hyphens.
pub fn slugify(allocator: std.mem.Allocator, input: []const u8, max_len: usize) ![]u8 {
    var buf = try allocator.alloc(u8, @min(input.len, max_len));
    var len: usize = 0;

    for (input) |c| {
        if (len >= max_len) break;
        if (c == ' ' or c == '_') {
            // Avoid consecutive hyphens
            if (len > 0 and buf[len - 1] != '-') {
                buf[len] = '-';
                len += 1;
            }
        } else if (std.ascii.isAlphanumeric(c)) {
            buf[len] = std.ascii.toLower(c);
            len += 1;
        } else if (c == '-') {
            if (len > 0 and buf[len - 1] != '-') {
                buf[len] = '-';
                len += 1;
            }
        }
        // Other characters stripped
    }

    // Trim trailing hyphens
    while (len > 0 and buf[len - 1] == '-') {
        len -= 1;
    }

    if (len == buf.len) return buf;
    // Shrink allocation
    return allocator.realloc(buf, len);
}

// ─────────────────────────────────────────────────────────
// Context file writing
// ─────────────────────────────────────────────────────────

/// Write CLAUDE.md (for Claude Code) or AGENTS.md (for all other agents)
/// into the worktree root with task context. When a RoleDefinition is provided
/// and agent_type is claude_code, generates a rich role-aware CLAUDE.md instead
/// of the generic template. For non-claude_code agents, role_def is ignored
/// and the generic template is always used.
pub fn writeContextFile(
    allocator: std.mem.Allocator,
    worktree_path: []const u8,
    agent_type: config.AgentType,
    task_description: []const u8,
    role_def: ?config.RoleDefinition,
    branch_name: []const u8,
) !void {
    const filename = if (agent_type == .claude_code) "CLAUDE.md" else "AGENTS.md";
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ worktree_path, filename });
    defer allocator.free(path);

    const content = blk: {
        if (agent_type == .claude_code) {
            if (role_def) |rd| {
                break :blk try generateRoleClaude(allocator, rd, task_description, branch_name);
            }
        }
        break :blk try buildContextFileContent(allocator, task_description);
    };
    defer allocator.free(content);

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(content);
}

/// Generate a rich CLAUDE.md from a role definition, task description, and branch name.
/// Empty sections (arrays with no items, strings with zero length) are omitted to
/// produce clean markdown.
pub fn generateRoleClaude(
    allocator: std.mem.Allocator,
    role_def: config.RoleDefinition,
    task_description: []const u8,
    branch_name: []const u8,
) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 2048);
    errdefer buf.deinit(allocator);

    // Header
    try buf.appendSlice(allocator, "# ");
    try buf.appendSlice(allocator, role_def.name);
    try buf.appendSlice(allocator, " \xe2\x80\x94 Teammux Worker\n\n");

    // Your role
    try buf.appendSlice(allocator, "## Your role\n");
    try buf.appendSlice(allocator, role_def.description);
    try buf.appendSlice(allocator, "\n\n");
    if (role_def.mission.len > 0) {
        try buf.appendSlice(allocator, "**Mission:** ");
        try buf.appendSlice(allocator, role_def.mission);
        try buf.appendSlice(allocator, "\n");
    }
    if (role_def.focus.len > 0) {
        try buf.appendSlice(allocator, "**Focus:** ");
        try buf.appendSlice(allocator, role_def.focus);
        try buf.appendSlice(allocator, "\n");
    }
    try buf.appendSlice(allocator, "\n");

    // Your mission for this task
    try buf.appendSlice(allocator, "## Your mission for this task\n");
    try buf.appendSlice(allocator, task_description);
    try buf.appendSlice(allocator, "\n\n");

    // What you own in this worktree
    if (role_def.write_patterns.len > 0 or role_def.deny_write_patterns.len > 0) {
        try buf.appendSlice(allocator, "## What you own in this worktree\n");
        if (role_def.write_patterns.len > 0) {
            try buf.appendSlice(allocator, "**Write access:**\n");
            for (role_def.write_patterns) |pat| {
                try buf.appendSlice(allocator, "- `");
                try buf.appendSlice(allocator, pat);
                try buf.appendSlice(allocator, "`\n");
            }
            try buf.appendSlice(allocator, "\n");
        }
        if (role_def.deny_write_patterns.len > 0) {
            try buf.appendSlice(allocator, "**You must NOT modify (engine will block attempts):**\n");
            for (role_def.deny_write_patterns) |pat| {
                try buf.appendSlice(allocator, "- `");
                try buf.appendSlice(allocator, pat);
                try buf.appendSlice(allocator, "`\n");
            }
            try buf.appendSlice(allocator, "\n");
        }
    }

    // Rules (non-negotiable)
    if (role_def.rules.len > 0) {
        try buf.appendSlice(allocator, "## Rules (non-negotiable)\n");
        for (role_def.rules, 0..) |rule, i| {
            var num_buf: [20]u8 = undefined;
            const num = try std.fmt.bufPrint(&num_buf, "{d}. ", .{i + 1});
            try buf.appendSlice(allocator, num);
            try buf.appendSlice(allocator, rule);
            try buf.appendSlice(allocator, "\n");
        }
        try buf.appendSlice(allocator, "\n");
    }

    // Workflow
    if (role_def.workflow.len > 0) {
        try buf.appendSlice(allocator, "## Workflow\n");
        for (role_def.workflow, 0..) |step, i| {
            var num_buf: [20]u8 = undefined;
            const num = try std.fmt.bufPrint(&num_buf, "{d}. ", .{i + 1});
            try buf.appendSlice(allocator, num);
            try buf.appendSlice(allocator, step);
            try buf.appendSlice(allocator, "\n");
        }
        try buf.appendSlice(allocator, "\n");
    }

    // Definition of done
    if (role_def.deliverables.len > 0 or role_def.success_metrics.len > 0) {
        try buf.appendSlice(allocator, "## Definition of done\n");
        for (role_def.deliverables) |d| {
            try buf.appendSlice(allocator, "- [ ] ");
            try buf.appendSlice(allocator, d);
            try buf.appendSlice(allocator, "\n");
        }
        for (role_def.success_metrics) |m| {
            try buf.appendSlice(allocator, "- [ ] ");
            try buf.appendSlice(allocator, m);
            try buf.appendSlice(allocator, "\n");
        }
        try buf.appendSlice(allocator, "\n");
    }

    // Teammux coordination
    try buf.appendSlice(allocator, "## Teammux coordination\n");
    try buf.appendSlice(allocator, "- Branch: ");
    try buf.appendSlice(allocator, branch_name);
    try buf.appendSlice(allocator, "\n");
    try buf.appendSlice(allocator, "- Report completion: /teammux-complete \"{brief summary}\"\n");
    try buf.appendSlice(allocator, "- Request guidance: /teammux-question \"{your question}\"\n");
    try buf.appendSlice(allocator, "- Your changes are isolated \xe2\x80\x94 git commands only affect this worktree\n");

    return try buf.toOwnedSlice(allocator);
}

fn buildContextFileContent(allocator: std.mem.Allocator, task: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\# Teammux Worker Context
        \\
        \\## Your assigned task
        \\{s}
        \\
        \\## How to signal completion
        \\When your task is complete, write this file to signal the Team Lead:
        \\```
        \\echo '{{"status":"complete","summary":"brief description of what you did"}}' > .task_complete.json
        \\```
        \\Then push your branch: `git push origin HEAD`
        \\
        \\## Working context
        \\- You are working in an isolated git worktree on your own branch
        \\- Your changes are fully isolated — you cannot affect other workers
        \\- The Team Lead may send you instructions via this terminal
        \\- Always commit your work before signaling completion
        \\
    , .{task});
}

// ─────────────────────────────────────────────────────────
// Git subprocess helper
// ─────────────────────────────────────────────────────────

pub fn runGit(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    var argv = try std.ArrayList([]const u8).initCapacity(allocator, args.len + 3);
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "-C");
    try argv.append(allocator, cwd);
    try argv.appendSlice(allocator, args);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = try child.spawnAndWait();
    if (term != .Exited or term.Exited != 0) return error.GitFailed;
}

pub const GitFailed = error{GitFailed};

// ─────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────

test "worktree - branch name from worker name and task" {
    const branch = try makeBranchName(std.testing.allocator, "Frontend", "implement auth middleware");
    defer std.testing.allocator.free(branch);
    try std.testing.expectEqualStrings("frontend/teammux-implement-auth-middleware", branch);
}

test "worktree - branch name truncation at 40 chars" {
    const branch = try makeBranchName(
        std.testing.allocator,
        "Backend",
        "implement the extremely long and verbose task description that exceeds forty characters",
    );
    defer std.testing.allocator.free(branch);
    // Task slug truncated to 40 chars
    try std.testing.expect(std.mem.startsWith(u8, branch, "backend/teammux-"));
    // Total branch name should be reasonable length
    try std.testing.expect(branch.len <= 60);
}

test "worktree - slugify strips special characters" {
    const slug = try slugify(std.testing.allocator, "Hello World! @#$ Test_Case", 40);
    defer std.testing.allocator.free(slug);
    try std.testing.expectEqualStrings("hello-world-test-case", slug);
}

test "worktree - slugify no consecutive hyphens" {
    const slug = try slugify(std.testing.allocator, "foo---bar   baz", 40);
    defer std.testing.allocator.free(slug);
    try std.testing.expectEqualStrings("foo-bar-baz", slug);
}

test "worktree - slugify trims trailing hyphens" {
    const slug = try slugify(std.testing.allocator, "trailing-", 40);
    defer std.testing.allocator.free(slug);
    try std.testing.expectEqualStrings("trailing", slug);
}

test "worktree - context file is CLAUDE.md for claude_code agent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    try writeContextFile(std.testing.allocator, path, .claude_code, "test task", null, "test-branch");

    // Verify CLAUDE.md exists
    const file = try tmp.dir.openFile("CLAUDE.md", .{});
    defer file.close();
    const content = try file.readToEndAlloc(std.testing.allocator, 1024 * 1024);
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "test task") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Teammux Worker Context") != null);
}

test "worktree - context file is AGENTS.md for codex_cli agent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    try writeContextFile(std.testing.allocator, path, .codex_cli, "codex task", null, "test-branch");

    // Verify AGENTS.md exists (not CLAUDE.md)
    const file = try tmp.dir.openFile("AGENTS.md", .{});
    defer file.close();
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("CLAUDE.md", .{}));
}

test "worktree - claimNextId assigns sequential IDs" {
    var roster = Roster.init(std.testing.allocator);
    defer roster.deinit();

    try std.testing.expect(roster.claimNextId() == 1);
    try std.testing.expect(roster.claimNextId() == 2);
    try std.testing.expect(roster.claimNextId() == 3);
}

test "worktree - unclaimId reclaims most recent ID" {
    var roster = Roster.init(std.testing.allocator);
    defer roster.deinit();

    const id = roster.claimNextId(); // 1
    try std.testing.expect(id == 1);

    roster.unclaimId(id);
    // next_id rolled back — next claim should return 1 again
    try std.testing.expect(roster.claimNextId() == 1);
}

test "worktree - unclaimId skips non-contiguous ID" {
    var roster = Roster.init(std.testing.allocator);
    defer roster.deinit();

    const id1 = roster.claimNextId(); // 1
    _ = roster.claimNextId(); // 2

    // Trying to unclaim id1 (not the most recent) — should be a no-op
    roster.unclaimId(id1);
    // next_id should still be 3
    try std.testing.expect(roster.claimNextId() == 3);
}

test "worktree - setWorkerStatus updates existing worker" {
    var roster = Roster.init(std.testing.allocator);
    defer roster.deinit();

    const id = roster.claimNextId();
    try roster.spawn(id, "/usr/bin/echo", .claude_code, "W", "task", "/tmp/wt", "br");

    try std.testing.expect(roster.getWorker(id).?.status == .idle);
    try std.testing.expect(roster.setWorkerStatus(id, .working));
    try std.testing.expect(roster.getWorker(id).?.status == .working);
    try std.testing.expect(roster.setWorkerStatus(id, .complete));
    try std.testing.expect(roster.getWorker(id).?.status == .complete);
}

test "worktree - setWorkerStatus returns false for missing worker" {
    var roster = Roster.init(std.testing.allocator);
    defer roster.deinit();

    try std.testing.expect(!roster.setWorkerStatus(999, .working));
}

test "worktree - spawn registers metadata without git operations" {
    var roster = Roster.init(std.testing.allocator);
    defer roster.deinit();

    const id = roster.claimNextId();
    try roster.spawn(id, "/usr/bin/echo", .claude_code, "Frontend", "implement auth", "/tmp/wt/1", "teammux/1-implement-auth");

    try std.testing.expect(id == 1);
    try std.testing.expect(roster.count() == 1);

    const worker = roster.getWorker(id).?;
    try std.testing.expectEqualStrings("Frontend", worker.name);
    try std.testing.expectEqualStrings("implement auth", worker.task_description);
    try std.testing.expectEqualStrings("/tmp/wt/1", worker.worktree_path);
    try std.testing.expectEqualStrings("teammux/1-implement-auth", worker.branch_name);
    try std.testing.expectEqualStrings("/usr/bin/echo", worker.agent_binary);
    try std.testing.expect(worker.agent_type == .claude_code);
    try std.testing.expect(worker.status == .idle);
}

test "worktree - dismiss removes worker from roster without git ops" {
    var roster = Roster.init(std.testing.allocator);
    defer roster.deinit();

    const id = roster.claimNextId();
    try roster.spawn(id, "/usr/bin/echo", .claude_code, "Backend", "fix login bug", "/tmp/wt/1", "teammux/1-fix-login-bug");
    try roster.dismiss(id);

    try std.testing.expect(roster.getWorker(id) == null);
    try std.testing.expect(roster.count() == 0);
}

test "worktree - dismiss non-existent worker returns error" {
    var roster = Roster.init(std.testing.allocator);
    defer roster.deinit();

    try std.testing.expectError(error.WorkerNotFound, roster.dismiss(999));
}

test "worktree - generateRoleClaude contains all role sections" {
    var write_pats = [_][]const u8{ "src/frontend/**", "tests/frontend/**" };
    var deny_pats = [_][]const u8{ "src/backend/**", "src/api/**" };
    var rules = [_][]const u8{ "Never modify backend files", "Always write tests" };
    var workflow_steps = [_][]const u8{ "Read the task", "Implement the solution", "Write tests" };
    var deliverables = [_][]const u8{"Working components with tests"};
    var metrics = [_][]const u8{ "Tests pass", "No regressions" };
    var triggers = [_][]const u8{};

    const role_def = config.RoleDefinition{
        .id = "frontend-engineer",
        .name = "Frontend Engineer",
        .division = "engineering",
        .emoji = "",
        .description = "React, Vue, UI implementation",
        .write_patterns = &write_pats,
        .deny_write_patterns = &deny_pats,
        .can_push = false,
        .can_merge = false,
        .trigger_events = &triggers,
        .mission = "Build pixel-perfect UI components",
        .focus = "Component architecture and accessibility",
        .deliverables = &deliverables,
        .rules = &rules,
        .workflow = &workflow_steps,
        .success_metrics = &metrics,
    };

    const content = try generateRoleClaude(std.testing.allocator, role_def, "Implement the login form", "feat/login-form");
    defer std.testing.allocator.free(content);

    // Header
    try std.testing.expect(std.mem.indexOf(u8, content, "# Frontend Engineer") != null);
    // Role section with description, mission, focus
    try std.testing.expect(std.mem.indexOf(u8, content, "React, Vue, UI implementation") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "**Mission:** Build pixel-perfect UI components") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "**Focus:** Component architecture and accessibility") != null);
    // Task description
    try std.testing.expect(std.mem.indexOf(u8, content, "Implement the login form") != null);
    // Write patterns as bullet list
    try std.testing.expect(std.mem.indexOf(u8, content, "- `src/frontend/**`") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "- `tests/frontend/**`") != null);
    // Deny write patterns
    try std.testing.expect(std.mem.indexOf(u8, content, "- `src/backend/**`") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "- `src/api/**`") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "must NOT modify") != null);
    // Rules (numbered)
    try std.testing.expect(std.mem.indexOf(u8, content, "1. Never modify backend files") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "2. Always write tests") != null);
    // Workflow (numbered)
    try std.testing.expect(std.mem.indexOf(u8, content, "1. Read the task") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "3. Write tests") != null);
    // Deliverables and metrics (checkboxes)
    try std.testing.expect(std.mem.indexOf(u8, content, "- [ ] Working components with tests") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "- [ ] Tests pass") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "- [ ] No regressions") != null);
    // Branch name in coordination section
    try std.testing.expect(std.mem.indexOf(u8, content, "- Branch: feat/login-form") != null);
    // Coordination commands
    try std.testing.expect(std.mem.indexOf(u8, content, "/teammux-complete") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "/teammux-question") != null);
}

test "worktree - generateRoleClaude omits empty sections" {
    var empty = [_][]const u8{};

    const role_def = config.RoleDefinition{
        .id = "minimal-role",
        .name = "Minimal Role",
        .division = "testing",
        .emoji = "",
        .description = "A minimal role for testing",
        .write_patterns = &empty,
        .deny_write_patterns = &empty,
        .can_push = false,
        .can_merge = false,
        .trigger_events = &empty,
        .mission = "",
        .focus = "",
        .deliverables = &empty,
        .rules = &empty,
        .workflow = &empty,
        .success_metrics = &empty,
    };

    const content = try generateRoleClaude(std.testing.allocator, role_def, "test task", "test-branch");
    defer std.testing.allocator.free(content);

    // Core sections always present
    try std.testing.expect(std.mem.indexOf(u8, content, "# Minimal Role") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "## Your role") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "## Your mission for this task") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "## Teammux coordination") != null);
    // Empty sections must be omitted
    try std.testing.expect(std.mem.indexOf(u8, content, "## What you own") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "## Rules") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "## Workflow") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "## Definition of done") == null);
    // Empty mission/focus must not produce empty bold markers
    try std.testing.expect(std.mem.indexOf(u8, content, "**Mission:**") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "**Focus:**") == null);
}

test "worktree - generateRoleClaude partial ownership deny only" {
    var empty = [_][]const u8{};
    var deny_pats = [_][]const u8{ "src/backend/**", "infra/**" };

    const role_def = config.RoleDefinition{
        .id = "partial-role",
        .name = "Partial Role",
        .division = "testing",
        .emoji = "",
        .description = "Role with deny patterns but no write patterns",
        .write_patterns = &empty,
        .deny_write_patterns = &deny_pats,
        .can_push = false,
        .can_merge = false,
        .trigger_events = &empty,
        .mission = "",
        .focus = "",
        .deliverables = &empty,
        .rules = &empty,
        .workflow = &empty,
        .success_metrics = &empty,
    };

    const content = try generateRoleClaude(std.testing.allocator, role_def, "task", "branch");
    defer std.testing.allocator.free(content);

    // Ownership section should appear with deny sub-section only
    try std.testing.expect(std.mem.indexOf(u8, content, "## What you own in this worktree") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "must NOT modify") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "- `src/backend/**`") != null);
    // Write access sub-section should be absent
    try std.testing.expect(std.mem.indexOf(u8, content, "**Write access:**") == null);
}

test "worktree - generateRoleClaude partial done deliverables only" {
    var empty = [_][]const u8{};
    var deliverables = [_][]const u8{ "Feature complete", "Tests pass" };

    const role_def = config.RoleDefinition{
        .id = "partial-done",
        .name = "Partial Done",
        .division = "testing",
        .emoji = "",
        .description = "Role with deliverables but no success metrics",
        .write_patterns = &empty,
        .deny_write_patterns = &empty,
        .can_push = false,
        .can_merge = false,
        .trigger_events = &empty,
        .mission = "",
        .focus = "",
        .deliverables = &deliverables,
        .rules = &empty,
        .workflow = &empty,
        .success_metrics = &empty,
    };

    const content = try generateRoleClaude(std.testing.allocator, role_def, "task", "branch");
    defer std.testing.allocator.free(content);

    // Definition of done section should appear with deliverables only
    try std.testing.expect(std.mem.indexOf(u8, content, "## Definition of done") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "- [ ] Feature complete") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "- [ ] Tests pass") != null);
}

test "worktree - writeContextFile with role produces role-aware CLAUDE.md" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    var write_pats = [_][]const u8{"src/**"};
    var deny_pats = [_][]const u8{"infra/**"};
    var rules = [_][]const u8{"Test everything"};
    var workflow_steps = [_][]const u8{"Read specs first"};
    var deliverables = [_][]const u8{"Passing tests"};
    var empty = [_][]const u8{};

    const role_def = config.RoleDefinition{
        .id = "test-engineer",
        .name = "Test Engineer",
        .division = "testing",
        .emoji = "",
        .description = "Testing specialist",
        .write_patterns = &write_pats,
        .deny_write_patterns = &deny_pats,
        .can_push = false,
        .can_merge = false,
        .trigger_events = &empty,
        .mission = "Ensure quality",
        .focus = "Test coverage",
        .deliverables = &deliverables,
        .rules = &rules,
        .workflow = &workflow_steps,
        .success_metrics = &empty,
    };

    try writeContextFile(std.testing.allocator, path, .claude_code, "write unit tests", role_def, "feat/unit-tests");

    const file = try tmp.dir.openFile("CLAUDE.md", .{});
    defer file.close();
    const content = try file.readToEndAlloc(std.testing.allocator, 1024 * 1024);
    defer std.testing.allocator.free(content);

    // Should contain role-aware content, not generic
    try std.testing.expect(std.mem.indexOf(u8, content, "# Test Engineer") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Teammux Worker Context") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "feat/unit-tests") != null);
}

test "worktree - writeContextFile non-claude agent with role gets generic AGENTS.md" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    var write_pats = [_][]const u8{"src/**"};
    var empty = [_][]const u8{};

    const role_def = config.RoleDefinition{
        .id = "test-role",
        .name = "Test Role",
        .division = "testing",
        .emoji = "",
        .description = "test",
        .write_patterns = &write_pats,
        .deny_write_patterns = &empty,
        .can_push = false,
        .can_merge = false,
        .trigger_events = &empty,
        .mission = "",
        .focus = "",
        .deliverables = &empty,
        .rules = &empty,
        .workflow = &empty,
        .success_metrics = &empty,
    };

    try writeContextFile(std.testing.allocator, path, .codex_cli, "codex task", role_def, "test-branch");

    // Should produce AGENTS.md with generic content, role ignored
    const file = try tmp.dir.openFile("AGENTS.md", .{});
    defer file.close();
    const content = try file.readToEndAlloc(std.testing.allocator, 1024 * 1024);
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "Teammux Worker Context") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Test Role") == null);
    // No CLAUDE.md should exist
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("CLAUDE.md", .{}));
}
