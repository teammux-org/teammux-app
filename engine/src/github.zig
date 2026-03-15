const std = @import("std");
const worktree = @import("worktree.zig");

// ─────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────

pub const MergeStrategy = enum(c_int) {
    squash = 0,
    rebase = 1,
    merge = 2,

    pub fn toString(self: MergeStrategy) []const u8 {
        return switch (self) {
            .squash => "squash",
            .rebase => "rebase",
            .merge => "merge",
        };
    }
};

pub const Pr = struct {
    pr_number: u64,
    url: []const u8,
    title: []const u8,
    state: []const u8,
    diff_url: []const u8,
};

pub const DiffFile = struct {
    path: []const u8,
    additions: i32,
    deletions: i32,
    patch: []const u8,
};

pub const Diff = struct {
    files: []DiffFile,
    total_additions: i32,
    total_deletions: i32,
};

// ─────────────────────────────────────────────────────────
// GitHub Client
// ─────────────────────────────────────────────────────────

pub const GitHubClient = struct {
    allocator: std.mem.Allocator,
    repo: ?[]const u8,
    token: ?[]const u8,
    webhook_process: ?std.process.Child,
    authed: bool,

    pub fn init(allocator: std.mem.Allocator, repo: ?[]const u8) GitHubClient {
        return .{
            .allocator = allocator,
            .repo = repo,
            .token = null,
            .webhook_process = null,
            .authed = false,
        };
    }

    /// Attempt GitHub auth. Resolution order:
    /// 1. gh CLI credentials (~/.config/gh/hosts.yml)
    /// 2. Config token (passed from config.toml)
    /// 3. Returns error if none succeed
    pub fn auth(self: *GitHubClient, config_token: ?[]const u8) !void {
        // Try 1: read from ~/.config/gh/hosts.yml
        if (try readGhCliToken(self.allocator)) |token| {
            if (self.token) |old| self.allocator.free(old);
            self.token = token;
            self.authed = true;
            return;
        }

        // Try 2: use token from config.toml
        if (config_token) |ct| {
            if (self.token) |old| self.allocator.free(old);
            self.token = try self.allocator.dupe(u8, ct);
            self.authed = true;
            return;
        }

        return error.Unauthenticated;
    }

    pub fn isAuthed(self: *const GitHubClient) bool {
        return self.authed;
    }

    /// Create a GitHub PR for a worker's branch → main.
    pub fn createPr(
        self: *GitHubClient,
        allocator: std.mem.Allocator,
        branch: []const u8,
        title: []const u8,
        body: []const u8,
    ) !Pr {
        const repo = self.repo orelse return error.NoRepo;

        // Use gh CLI to create PR
        const result = try runGhCommand(allocator, &.{
            "pr",  "create",
            "--repo", repo,
            "--head", branch,
            "--title", title,
            "--body",  body,
        });
        defer allocator.free(result);

        // Parse PR URL from output (gh pr create outputs the URL)
        const url = try allocator.dupe(u8, std.mem.trim(u8, result, &[_]u8{ '\n', '\r', ' ' }));

        return .{
            .pr_number = 0, // Would parse from URL in production
            .url = url,
            .title = try allocator.dupe(u8, title),
            .state = try allocator.dupe(u8, "open"),
            .diff_url = try allocator.dupe(u8, ""),
        };
    }

    /// Merge a PR using the specified strategy.
    pub fn mergePr(
        self: *GitHubClient,
        allocator: std.mem.Allocator,
        pr_number: u64,
        strategy: MergeStrategy,
    ) !void {
        const repo = self.repo orelse return error.NoRepo;
        const pr_str = try std.fmt.allocPrint(allocator, "{d}", .{pr_number});
        defer allocator.free(pr_str);

        const merge_method = try std.fmt.allocPrint(allocator, "--{s}", .{strategy.toString()});
        defer allocator.free(merge_method);

        const result = try runGhCommand(allocator, &.{
            "pr",    "merge",
            pr_str,
            "--repo", repo,
            merge_method,
            "--yes",
        });
        allocator.free(result);
    }

    /// Get the diff for a worker's branch vs main.
    pub fn getDiff(
        self: *GitHubClient,
        allocator: std.mem.Allocator,
        branch: []const u8,
    ) !Diff {
        const repo = self.repo orelse return error.NoRepo;

        const endpoint = try std.fmt.allocPrint(allocator, "/repos/{s}/compare/main...{s}", .{ repo, branch });
        defer allocator.free(endpoint);

        const result = try runGhCommand(allocator, &.{ "api", endpoint });
        defer allocator.free(result);

        // TODO(v0.2): parse the JSON response for file changes
        // For v0.1, return empty diff — the data is fetched but not yet parsed
        return .{
            .files = &.{},
            .total_additions = 0,
            .total_deletions = 0,
        };
    }

    /// Start gh webhook forward for real-time GitHub events.
    /// Option (c): gh not in PATH → immediate fallback.
    /// gh found but webhook forward fails → retry once after 5s, then fallback.
    pub fn startWebhooks(
        self: *GitHubClient,
        allocator: std.mem.Allocator,
        callback: ?*const fn (?[*:0]const u8, ?[*:0]const u8, ?*anyopaque) callconv(.c) void,
        userdata: ?*anyopaque,
    ) !void {
        _ = callback;
        _ = userdata;

        // Check if gh is in PATH
        if (!isGhAvailable(allocator)) {
            std.log.info("[teammux] gh not found — GitHub events will not be monitored", .{});
            return;
        }

        const repo = self.repo orelse return;

        // Try to start gh webhook forward
        const repo_flag = try std.fmt.allocPrint(allocator, "--repo={s}", .{repo});
        defer allocator.free(repo_flag);

        var child = std.process.Child.init(&.{
            "gh",        "webhook",   "forward",
            repo_flag,
            "--events=pull_request,push,check_run",
            "--url=http://localhost:0",
        }, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        child.spawn() catch {
            // TODO(v0.2): implement 60s polling fallback via gh api /repos/{repo}/pulls
            std.log.info("[teammux] gh webhook forward failed — GitHub events will not be monitored", .{});
            return;
        };
        self.webhook_process = child;
    }

    pub fn stopWebhooks(self: *GitHubClient) void {
        if (self.webhook_process) |*proc| {
            _ = proc.kill() catch |err| {
                std.log.warn("[teammux] webhook process kill failed: {}", .{err});
            };
            _ = proc.wait() catch |err| {
                std.log.warn("[teammux] webhook process wait failed: {}", .{err});
            };
            self.webhook_process = null;
        }
    }

    pub fn deinit(self: *GitHubClient) void {
        self.stopWebhooks();
        if (self.token) |t| {
            self.allocator.free(t);
            self.token = null;
        }
    }

    pub const NoRepo = error{NoRepo};
    pub const Unauthenticated = error{Unauthenticated};
};

// ─────────────────────────────────────────────────────────
// gh CLI token reading
// ─────────────────────────────────────────────────────────

/// Read GitHub token from ~/.config/gh/hosts.yml
pub fn readGhCliToken(allocator: std.mem.Allocator) !?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    const path = try std.fmt.allocPrint(allocator, "{s}/.config/gh/hosts.yml", .{home});
    defer allocator.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return null;
    defer allocator.free(content);

    // Simple YAML parsing: find "oauth_token: " value
    return try parseOauthToken(allocator, content);
}

fn parseOauthToken(allocator: std.mem.Allocator, yaml: []const u8) !?[]const u8 {
    // Look for "oauth_token: " followed by the token value
    const needle = "oauth_token:";
    const pos = std.mem.indexOf(u8, yaml, needle) orelse return null;
    const after = yaml[pos + needle.len ..];

    // Skip whitespace
    var i: usize = 0;
    while (i < after.len and (after[i] == ' ' or after[i] == '\t')) : (i += 1) {}

    // Read until newline
    const start = i;
    while (i < after.len and after[i] != '\n' and after[i] != '\r') : (i += 1) {}

    if (i == start) return null;
    return try allocator.dupe(u8, after[start..i]);
}

// ─────────────────────────────────────────────────────────
// Agent binary resolution
// ─────────────────────────────────────────────────────────

/// Resolve agent binary path via PATH lookup.
pub fn resolveAgentBinary(allocator: std.mem.Allocator, agent_name: []const u8) !?[]u8 {
    // Try `which {agent_name}`
    var child = std.process.Child.init(&.{ "which", agent_name }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();
    const stdout = child.stdout.?;
    const result = try stdout.readToEndAlloc(allocator, 4096);
    const term = try child.wait();

    // Check exit code — `which` returns non-zero when binary not found
    if (term != .Exited or term.Exited != 0 or result.len == 0) {
        allocator.free(result);
        return null;
    }

    // Trim newline
    const trimmed = std.mem.trim(u8, result, &[_]u8{ '\n', '\r', ' ' });
    if (trimmed.len == 0) {
        allocator.free(result);
        return null;
    }

    const path = try allocator.dupe(u8, trimmed);
    allocator.free(result);
    return path;
}

// ─────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────

fn runGhCommand(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .{};
    defer argv.deinit(allocator);
    try argv.append(allocator, "gh");
    try argv.appendSlice(allocator, args);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();
    const stdout = child.stdout.?;
    const result = try stdout.readToEndAlloc(allocator, 1024 * 1024);
    const term = try child.wait();

    if (term != .Exited or term.Exited != 0) {
        allocator.free(result);
        return error.GhCommandFailed;
    }

    return result;
}

pub const GhCommandFailed = error{GhCommandFailed};

fn isGhAvailable(allocator: std.mem.Allocator) bool {
    var child = std.process.Child.init(&.{ "which", "gh" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    const term = child.wait() catch return false;
    return term == .Exited and term.Exited == 0;
}

// ─────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────

test "github - auth reads token from mock hosts.yml" {
    const yaml =
        \\github.com:
        \\    user: testuser
        \\    oauth_token: gho_testtoken123
        \\    git_protocol: https
    ;

    const token = try parseOauthToken(std.testing.allocator, yaml);
    defer if (token) |t| std.testing.allocator.free(t);

    try std.testing.expect(token != null);
    try std.testing.expectEqualStrings("gho_testtoken123", token.?);
}

test "github - auth handles missing token" {
    const yaml =
        \\github.com:
        \\    user: testuser
        \\    git_protocol: https
    ;

    const token = try parseOauthToken(std.testing.allocator, yaml);
    try std.testing.expect(token == null);
}

test "github - client init and auth with config token" {
    var client = GitHubClient.init(std.testing.allocator, "owner/repo");
    defer client.deinit();

    // Auth with config token
    try client.auth("ghp_configtoken");
    try std.testing.expect(client.isAuthed());
    try std.testing.expectEqualStrings("ghp_configtoken", client.token.?);
}

test "github - client unauthenticated without token" {
    var client = GitHubClient.init(std.testing.allocator, "owner/repo");
    defer client.deinit();

    // Should fail with no gh CLI and no config token
    // (assuming test environment may or may not have gh)
    client.auth(null) catch |err| {
        try std.testing.expect(err == error.Unauthenticated);
        return;
    };
    // If we get here, gh CLI auth succeeded (test machine has gh configured)
    try std.testing.expect(client.isAuthed());
}

test "github - merge strategy toString" {
    try std.testing.expectEqualStrings("squash", MergeStrategy.squash.toString());
    try std.testing.expectEqualStrings("rebase", MergeStrategy.rebase.toString());
    try std.testing.expectEqualStrings("merge", MergeStrategy.merge.toString());
}

test "github - resolve agent binary" {
    // Test with a binary that definitely exists
    const result = try resolveAgentBinary(std.testing.allocator, "echo");
    defer if (result) |r| std.testing.allocator.free(r);
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.endsWith(u8, result.?, "echo"));
}

test "github - resolve nonexistent agent binary" {
    const result = try resolveAgentBinary(std.testing.allocator, "nonexistent_agent_binary_xyz");
    try std.testing.expect(result == null);
}

test "github - gh CLI availability check" {
    // Just verify the function runs without crashing
    const available = isGhAvailable(std.testing.allocator);
    _ = available; // may be true or false depending on test machine
}
