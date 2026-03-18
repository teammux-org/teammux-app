const std = @import("std");
const config = @import("config.zig");
const worktree = @import("worktree.zig");

// ─────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────

/// A registered git worktree. Both `path` and `branch` are heap-allocated
/// and owned by the WorktreeRegistry — freed on removeWorker() or deinit().
pub const WorktreeEntry = struct {
    path: []const u8,
    branch: []const u8,
};

pub const WorktreeRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMap(u32, WorktreeEntry),

    pub fn init(allocator: std.mem.Allocator) WorktreeRegistry {
        return .{
            .allocator = allocator,
            .entries = std.AutoHashMap(u32, WorktreeEntry).init(allocator),
        };
    }

    pub fn deinit(self: *WorktreeRegistry) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.path);
            self.allocator.free(entry.value_ptr.branch);
        }
        self.entries.deinit();
    }

    pub fn get(self: *WorktreeRegistry, worker_id: u32) ?WorktreeEntry {
        return self.entries.get(worker_id);
    }
};

// ─────────────────────────────────────────────────────────
// Branch slugification
// ─────────────────────────────────────────────────────────

/// Build a git branch name from worker ID and task description.
/// Format: teammux/{worker_id}-{slug} where slug is the slugified task
/// (truncated to 40 chars). Returns owned string — caller must free.
pub fn makeBranch(allocator: std.mem.Allocator, worker_id: u32, task_description: []const u8) ![]u8 {
    const slug = try slugifyTask(allocator, task_description, 40);
    defer allocator.free(slug);
    return std.fmt.allocPrint(allocator, "teammux/{d}-{s}", .{ worker_id, slug });
}

/// Slugify: lowercase, spaces/underscores→hyphens, strip non-alphanumeric
/// (except hyphens), no consecutive hyphens, trim trailing hyphens,
/// truncate to max_len.
pub fn slugifyTask(allocator: std.mem.Allocator, input: []const u8, max_len: usize) ![]u8 {
    const alloc_size = @min(input.len, max_len);
    if (alloc_size == 0) return try allocator.alloc(u8, 0);

    var buf = try allocator.alloc(u8, alloc_size);
    var len: usize = 0;

    for (input) |c| {
        if (len >= max_len) break;
        if (c == ' ' or c == '_' or c == '-') {
            if (len > 0 and buf[len - 1] != '-') {
                buf[len] = '-';
                len += 1;
            }
        } else if (std.ascii.isAlphanumeric(c)) {
            buf[len] = std.ascii.toLower(c);
            len += 1;
        }
    }

    // Trim trailing hyphens
    while (len > 0 and buf[len - 1] == '-') {
        len -= 1;
    }

    if (len == 0) {
        allocator.free(buf);
        return try allocator.alloc(u8, 0);
    }

    if (len == buf.len) return buf;
    return allocator.realloc(buf, len);
}

// ─────────────────────────────────────────────────────────
// Worktree root resolution
// ─────────────────────────────────────────────────────────

/// Resolve worktree root directory.
/// 1. If cfg has worktree_root set, use that.
/// 2. Otherwise: ~/.teammux/worktrees/{SHA256(project_path)}/
pub fn resolveWorktreeRoot(
    allocator: std.mem.Allocator,
    cfg: ?*const config.Config,
    project_path: []const u8,
) ![]u8 {
    // Check config override
    if (cfg) |c| {
        if (c.worktree_root) |wr| {
            return allocator.dupe(u8, wr);
        }
    }

    // Default: ~/.teammux/worktrees/{SHA256(project_path)}/
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    const hash_hex = hashProjectPath(project_path);
    return std.fmt.allocPrint(allocator, "{s}/.teammux/worktrees/{s}", .{ home, hash_hex });
}

/// SHA256 hash of project path, returned as 64-char hex string.
pub fn hashProjectPath(project_path: []const u8) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(project_path);
    const digest = hasher.finalResult();
    return std.fmt.bytesToHex(digest, .lower);
}

// ─────────────────────────────────────────────────────────
// Lifecycle operations
// ─────────────────────────────────────────────────────────

pub const CreateError = error{
    OutOfMemory,
    GitFailed,
    NoHomeDir,
    MkdirFailed,
} || std.process.Child.SpawnError;

/// Create a git worktree for a worker.
/// 1. Resolve worktree root from config or default
/// 2. Build path: {root}/{worker_id}/
/// 3. Slugify branch: teammux/{worker_id}-{task-slug}
/// 4. mkdir -p for parent directory
/// 5. git worktree add {path} -b {branch}
/// 6. Store in registry
pub fn create(
    registry: *WorktreeRegistry,
    cfg: ?*const config.Config,
    project_path: []const u8,
    worker_id: u32,
    task_description: []const u8,
) CreateError!void {
    const allocator = registry.allocator;

    // 1. Resolve root
    const root = try resolveWorktreeRoot(allocator, cfg, project_path);
    defer allocator.free(root);

    // 2. Build path
    const wt_path = try std.fmt.allocPrint(allocator, "{s}/{d}", .{ root, worker_id });
    errdefer allocator.free(wt_path);

    // 3. Slugify branch
    const branch = try makeBranch(allocator, worker_id, task_description);
    errdefer allocator.free(branch);

    // 4. mkdir -p for root directory (recursive — handles missing parents)
    if (root.len > 0 and root[0] == '/') {
        var root_dir = std.fs.openDirAbsolute("/", .{}) catch return error.MkdirFailed;
        defer root_dir.close();
        root_dir.makePath(root[1..]) catch return error.MkdirFailed;
    } else {
        std.fs.cwd().makePath(root) catch return error.MkdirFailed;
    }

    // 5. git worktree add
    worktree.runGit(allocator, project_path, &.{ "worktree", "add", wt_path, "-b", branch }) catch |err| {
        std.log.warn("[teammux] git worktree add failed for worker {d} at {s}: {}", .{ worker_id, wt_path, err });
        return error.GitFailed;
    };

    // 6. Store in registry (clean up old entry if duplicate worker_id)
    if (registry.entries.fetchRemove(worker_id)) |old| {
        worktree.runGit(allocator, project_path, &.{ "worktree", "remove", "--force", old.value.path }) catch |err| {
            std.log.warn("[teammux] failed to remove old worktree for worker {d} at {s}: {}", .{ worker_id, old.value.path, err });
        };
        allocator.free(old.value.path);
        allocator.free(old.value.branch);
    }
    registry.entries.put(worker_id, .{
        .path = wt_path,
        .branch = branch,
    }) catch |err| {
        // Rollback: remove the git worktree we just created
        worktree.runGit(allocator, project_path, &.{ "worktree", "remove", "--force", wt_path }) catch |rollback_err| {
            std.log.err("[teammux] rollback failed after registry OOM for worker {d} at {s}: {}", .{ worker_id, wt_path, rollback_err });
        };
        allocator.free(wt_path);
        allocator.free(branch);
        return err;
    };
}

/// Remove a specific worker's worktree.
/// Runs git worktree remove --force, then frees registry entry.
/// Logs but does not fail if git removal fails (fire-and-forget cleanup).
pub fn removeWorker(
    registry: *WorktreeRegistry,
    project_path: []const u8,
    worker_id: u32,
) void {
    const kv = registry.entries.fetchRemove(worker_id) orelse return;
    const entry = kv.value;

    worktree.runGit(registry.allocator, project_path, &.{ "worktree", "remove", "--force", entry.path }) catch |err| {
        std.log.warn("[teammux] lifecycle worktree remove failed for worker {d}: {}", .{ worker_id, err });
    };

    registry.allocator.free(entry.path);
    registry.allocator.free(entry.branch);
}

/// Get worktree path for a worker. Returns null if not registered.
pub fn getPath(registry: *WorktreeRegistry, worker_id: u32) ?[]const u8 {
    return if (registry.get(worker_id)) |e| e.path else null;
}

/// Get branch name for a worker. Returns null if not registered.
pub fn getBranch(registry: *WorktreeRegistry, worker_id: u32) ?[]const u8 {
    return if (registry.get(worker_id)) |e| e.branch else null;
}

// ─────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────

test "lifecycle - slugifyTask basic" {
    const slug = try slugifyTask(std.testing.allocator, "implement JWT auth", 40);
    defer std.testing.allocator.free(slug);
    try std.testing.expectEqualStrings("implement-jwt-auth", slug);
}

test "lifecycle - slugifyTask strips special chars" {
    const slug = try slugifyTask(std.testing.allocator, "Hello World! @#$ Test_Case", 40);
    defer std.testing.allocator.free(slug);
    try std.testing.expectEqualStrings("hello-world-test-case", slug);
}

test "lifecycle - slugifyTask no consecutive hyphens" {
    const slug = try slugifyTask(std.testing.allocator, "foo---bar   baz", 40);
    defer std.testing.allocator.free(slug);
    try std.testing.expectEqualStrings("foo-bar-baz", slug);
}

test "lifecycle - slugifyTask truncates at 40 chars" {
    const slug = try slugifyTask(std.testing.allocator, "this is an extremely long task description that definitely exceeds forty characters", 40);
    defer std.testing.allocator.free(slug);
    try std.testing.expect(slug.len <= 40);
    try std.testing.expect(slug.len > 0);
    // Should not end with hyphen
    try std.testing.expect(slug[slug.len - 1] != '-');
}

test "lifecycle - slugifyTask trims trailing hyphens" {
    const slug = try slugifyTask(std.testing.allocator, "trailing---", 40);
    defer std.testing.allocator.free(slug);
    try std.testing.expectEqualStrings("trailing", slug);
}

test "lifecycle - slugifyTask empty input" {
    const slug = try slugifyTask(std.testing.allocator, "", 40);
    defer std.testing.allocator.free(slug);
    try std.testing.expect(slug.len == 0);
}

test "lifecycle - slugifyTask all special chars produces empty slug" {
    const slug = try slugifyTask(std.testing.allocator, "!@#$%^&*()", 40);
    defer std.testing.allocator.free(slug);
    try std.testing.expect(slug.len == 0);
}

test "lifecycle - makeBranch with empty slug produces valid branch" {
    const branch = try makeBranch(std.testing.allocator, 3, "!@#$");
    defer std.testing.allocator.free(branch);
    try std.testing.expectEqualStrings("teammux/3-", branch);
}

test "lifecycle - makeBranch includes worker ID and prefix" {
    const branch = try makeBranch(std.testing.allocator, 2, "implement JWT auth");
    defer std.testing.allocator.free(branch);
    try std.testing.expectEqualStrings("teammux/2-implement-jwt-auth", branch);
}

test "lifecycle - makeBranch with large worker ID" {
    const branch = try makeBranch(std.testing.allocator, 42, "fix login bug");
    defer std.testing.allocator.free(branch);
    try std.testing.expectEqualStrings("teammux/42-fix-login-bug", branch);
}

test "lifecycle - hashProjectPath produces consistent 64-char hex" {
    const hash1 = hashProjectPath("/Users/test/myproject");
    const hash2 = hashProjectPath("/Users/test/myproject");
    try std.testing.expectEqualStrings(&hash1, &hash2);
    try std.testing.expect(hash1.len == 64);

    // Different path produces different hash
    const hash3 = hashProjectPath("/Users/test/other");
    try std.testing.expect(!std.mem.eql(u8, &hash1, &hash3));
}

/// Test helper: build a Config with only worktree_root set (all other fields use minimal defaults).
fn testConfig(wt_root: ?[]const u8) config.Config {
    return .{
        .project = .{ .name = "", .github_repo = null },
        .team_lead = .{ .agent = .claude_code, .model = "", .permissions = "" },
        .workers = &.{},
        .github_token = null,
        .bus_delivery = "",
        .worktree_root = wt_root,
    };
}

/// Test helper: init a git repo with one commit inside an existing tmpDir.
fn initTestRepo(allocator: std.mem.Allocator, project_root: []const u8) !void {
    try worktree.runGit(allocator, project_root, &.{ "init", "-b", "main" });
    try worktree.runGit(allocator, project_root, &.{ "config", "user.email", "test@test.com" });
    try worktree.runGit(allocator, project_root, &.{ "config", "user.name", "Test" });
    const readme_path = try std.fmt.allocPrint(allocator, "{s}/README.md", .{project_root});
    defer allocator.free(readme_path);
    const readme = try std.fs.createFileAbsolute(readme_path, .{});
    try readme.writeAll("# Test");
    readme.close();
    try worktree.runGit(allocator, project_root, &.{ "add", "." });
    try worktree.runGit(allocator, project_root, &.{ "commit", "-m", "initial" });
}

test "lifecycle - resolveWorktreeRoot with config override" {
    var cfg = testConfig("/custom/path");
    const root = try resolveWorktreeRoot(std.testing.allocator, &cfg, "/any/project");
    defer std.testing.allocator.free(root);
    try std.testing.expectEqualStrings("/custom/path", root);
}

test "lifecycle - resolveWorktreeRoot default uses SHA256" {
    const root = try resolveWorktreeRoot(std.testing.allocator, null, "/Users/test/myproject");
    defer std.testing.allocator.free(root);
    const hash = hashProjectPath("/Users/test/myproject");
    try std.testing.expect(std.mem.indexOf(u8, root, &hash) != null);
    try std.testing.expect(std.mem.indexOf(u8, root, ".teammux/worktrees/") != null);
}

test "lifecycle - registry init/deinit" {
    var reg = WorktreeRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expect(reg.get(1) == null);
}

test "lifecycle - getPath and getBranch return null for missing worker" {
    var reg = WorktreeRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expect(getPath(&reg, 99) == null);
    try std.testing.expect(getBranch(&reg, 99) == null);
}

test "lifecycle - create and remove full lifecycle (integration)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(project_root);
    try initTestRepo(std.testing.allocator, project_root);

    const wt_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/worktrees", .{project_root});
    defer std.testing.allocator.free(wt_root);

    var cfg = testConfig(wt_root);
    var reg = WorktreeRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try create(&reg, &cfg, project_root, 1, "implement auth");

    // Verify path and branch registered
    const expected_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/1", .{wt_root});
    defer std.testing.allocator.free(expected_path);
    try std.testing.expectEqualStrings(expected_path, getPath(&reg, 1).?);
    try std.testing.expectEqualStrings("teammux/1-implement-auth", getBranch(&reg, 1).?);

    // Verify directory exists on disk
    var wt_dir = try std.fs.openDirAbsolute(getPath(&reg, 1).?, .{});
    wt_dir.close();

    // Remove and verify cleanup
    removeWorker(&reg, project_root, 1);
    try std.testing.expect(getPath(&reg, 1) == null);
    try std.testing.expect(getBranch(&reg, 1) == null);
    try std.testing.expectError(error.FileNotFound, std.fs.openDirAbsolute(expected_path, .{}));
}

test "lifecycle - create with config override path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(project_root);
    try initTestRepo(std.testing.allocator, project_root);

    const custom_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/custom-wt", .{project_root});
    defer std.testing.allocator.free(custom_root);

    var cfg = testConfig(custom_root);
    var reg = WorktreeRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try create(&reg, &cfg, project_root, 5, "fix login bug");

    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}/5", .{custom_root});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, getPath(&reg, 5).?);
    try std.testing.expectEqualStrings("teammux/5-fix-login-bug", getBranch(&reg, 5).?);

    removeWorker(&reg, project_root, 5);
}

test "lifecycle - remove non-existent worker is safe" {
    var reg = WorktreeRegistry.init(std.testing.allocator);
    defer reg.deinit();
    removeWorker(&reg, "/tmp", 999);
    try std.testing.expect(getPath(&reg, 999) == null);
}
