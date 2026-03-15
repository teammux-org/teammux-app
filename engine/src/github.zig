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
    polling_thread: ?std.Thread,
    polling_running: std.atomic.Value(bool),
    event_callback: ?*const fn (?[*:0]const u8, ?[*:0]const u8, ?*anyopaque) callconv(.c) void,
    event_userdata: ?*anyopaque,
    last_event_id: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, repo: ?[]const u8) GitHubClient {
        return .{
            .allocator = allocator,
            .repo = repo,
            .token = null,
            .webhook_process = null,
            .authed = false,
            .polling_thread = null,
            .polling_running = std.atomic.Value(bool).init(false),
            .event_callback = null,
            .event_userdata = null,
            .last_event_id = null,
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
        _ = self;
        _ = allocator;
        _ = branch;
        // TODO(v0.2): fetch and parse the GitHub compare API response.
        // For v0.1, diff parsing is not implemented.
        return error.NotImplemented;
    }

    pub const NotImplemented = error{NotImplemented};

    /// Start gh webhook forward for real-time GitHub events.
    /// If gh is not in PATH: skip retry, go straight to polling fallback.
    /// If gh webhook forward fails: retry once after 5s, then polling fallback.
    pub fn startWebhooks(
        self: *GitHubClient,
        allocator: std.mem.Allocator,
        callback: ?*const fn (?[*:0]const u8, ?[*:0]const u8, ?*anyopaque) callconv(.c) void,
        userdata: ?*anyopaque,
    ) !void {
        self.event_callback = callback;
        self.event_userdata = userdata;

        const repo = self.repo orelse {
            std.log.warn("[teammux] no repo configured — GitHub event monitoring disabled", .{});
            return;
        };

        if (!isGhAvailable(allocator)) {
            std.log.info("[teammux] gh not found — falling back to 60s polling", .{});
            self.startPollingFallback();
            return;
        }

        const repo_flag = try std.fmt.allocPrint(allocator, "--repo={s}", .{repo});
        defer allocator.free(repo_flag);

        // First attempt
        var child = std.process.Child.init(&.{
            "gh",        "webhook",   "forward",
            repo_flag,
            "--events=pull_request,push,check_run",
            "--url=http://localhost:0",
        }, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        child.spawn() catch |err| {
            std.log.info("[teammux] gh webhook forward failed: {} — retrying in 5s", .{err});
            std.Thread.sleep(5 * std.time.ns_per_s);

            // Second attempt
            var retry = std.process.Child.init(&.{
                "gh",        "webhook",   "forward",
                repo_flag,
                "--events=pull_request,push,check_run",
                "--url=http://localhost:0",
            }, allocator);
            retry.stdin_behavior = .Ignore;
            retry.stdout_behavior = .Ignore;
            retry.stderr_behavior = .Ignore;

            retry.spawn() catch |retry_err| {
                std.log.info("[teammux] gh webhook forward retry failed: {} — falling back to 60s polling", .{retry_err});
                self.startPollingFallback();
                return;
            };
            self.webhook_process = retry;
            return;
        };
        self.webhook_process = child;
    }

    /// Start 60s polling fallback when webhooks are unavailable.
    /// Callers log the specific reason before calling this.
    fn startPollingFallback(self: *GitHubClient) void {
        if (self.polling_running.load(.acquire)) return;
        self.polling_running.store(true, .release);
        self.polling_thread = std.Thread.spawn(.{}, pollingLoop, .{self}) catch |err| {
            std.log.warn("[teammux] failed to start polling thread: {}", .{err});
            self.polling_running.store(false, .release);
            return;
        };
    }

    /// Poll every 60s. Sleeps in 1s increments to allow responsive shutdown (max 1s stop latency).
    fn pollingLoop(self: *GitHubClient) void {
        while (self.polling_running.load(.acquire)) {
            var elapsed: usize = 0;
            while (elapsed < 60) : (elapsed += 1) {
                if (!self.polling_running.load(.acquire)) return;
                std.Thread.sleep(1 * std.time.ns_per_s);
            }
            self.pollEvents();
        }
    }

    /// Fetch recent events from GitHub Events API (repos/{owner}/{repo}/events).
    fn pollEvents(self: *GitHubClient) void {
        const repo = self.repo orelse return;
        const allocator = self.allocator;

        const endpoint = std.fmt.allocPrint(allocator, "repos/{s}/events", .{repo}) catch return;
        defer allocator.free(endpoint);

        const result = runGhCommand(allocator, &.{ "api", endpoint }) catch |err| {
            std.log.warn("[teammux] poll failed: {}", .{err});
            return;
        };
        defer allocator.free(result);

        self.processEvents(result) catch |err| {
            std.log.warn("[teammux] event processing failed: {}", .{err});
        };
    }

    /// Parse GitHub Events API JSON array (newest-first order).
    /// Deduplicates by comparing event IDs against last_event_id.
    /// Only teammux/* branch events are forwarded to the callback.
    fn processEvents(self: *GitHubClient, json_data: []const u8) !void {
        const allocator = self.allocator;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_data, .{});
        defer parsed.deinit();

        const events = switch (parsed.value) {
            .array => |arr| arr,
            else => return,
        };

        var new_last_id: ?[]const u8 = null;

        for (events.items) |event| {
            const obj = switch (event) {
                .object => |o| o,
                else => continue,
            };

            const id_str = switch (obj.get("id") orelse continue) {
                .string => |s| s,
                else => continue,
            };

            if (new_last_id == null) new_last_id = id_str;

            if (self.last_event_id) |last_id| {
                if (std.mem.eql(u8, id_str, last_id)) break;
            }

            const event_type = switch (obj.get("type") orelse continue) {
                .string => |s| s,
                else => continue,
            };

            const branch = extractBranch(event, event_type) orelse continue;
            if (!isTeammuxBranch(branch)) continue;

            const mapped_type = mapEventType(event_type) orelse continue;

            const callback = self.event_callback orelse continue;
            const type_z = allocator.dupeZ(u8, mapped_type) catch continue;
            defer allocator.free(type_z);

            const json_str = std.json.Stringify.valueAlloc(allocator, event, .{}) catch continue;
            defer allocator.free(json_str);
            const json_z = allocator.dupeZ(u8, json_str) catch continue;
            defer allocator.free(json_z);

            callback(type_z.ptr, json_z.ptr, self.event_userdata);
        }

        if (new_last_id) |nid| {
            const new_id = allocator.dupe(u8, nid) catch return;
            if (self.last_event_id) |old| allocator.free(old);
            self.last_event_id = new_id;
        }
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
        self.polling_running.store(false, .release);
        if (self.polling_thread) |t| {
            t.join();
            self.polling_thread = null;
        }
    }

    pub fn deinit(self: *GitHubClient) void {
        self.stopWebhooks();
        if (self.token) |t| {
            self.allocator.free(t);
            self.token = null;
        }
        if (self.last_event_id) |id| {
            self.allocator.free(id);
            self.last_event_id = null;
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

    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null, // gh not installed — expected, silent
        else => {
            std.log.warn("[teammux] cannot read gh CLI token at {s}: {}", .{ path, err });
            return null;
        },
    };
    defer file.close();
    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        std.log.warn("[teammux] cannot read gh CLI token file: {}", .{err});
        return null;
    };
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

/// Extract branch ref from a GitHub event.
/// PushEvent -> payload.ref, PullRequestEvent -> payload.pull_request.head.ref.
fn extractBranch(event: std.json.Value, event_type: []const u8) ?[]const u8 {
    const obj = switch (event) {
        .object => |o| o,
        else => return null,
    };
    const payload = switch (obj.get("payload") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    if (std.mem.eql(u8, event_type, "PushEvent")) {
        return switch (payload.get("ref") orelse return null) {
            .string => |s| s,
            else => null,
        };
    } else if (std.mem.eql(u8, event_type, "PullRequestEvent")) {
        const pr = switch (payload.get("pull_request") orelse return null) {
            .object => |o| o,
            else => return null,
        };
        const head = switch (pr.get("head") orelse return null) {
            .object => |o| o,
            else => return null,
        };
        return switch (head.get("ref") orelse return null) {
            .string => |s| s,
            else => null,
        };
    }
    return null;
}

/// Match teammux branches. PushEvent refs include "refs/heads/" prefix;
/// PullRequestEvent head.ref does not.
fn isTeammuxBranch(ref: []const u8) bool {
    return std.mem.startsWith(u8, ref, "refs/heads/teammux/") or
        std.mem.startsWith(u8, ref, "teammux/");
}

fn mapEventType(github_type: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, github_type, "PushEvent")) return "push";
    if (std.mem.eql(u8, github_type, "PullRequestEvent")) return "pull_request";
    return null;
}

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

fn testEventCallback(_: ?[*:0]const u8, _: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) void {}

test "github - webhook start stores callback and stop cleans up" {
    var client = GitHubClient.init(std.testing.allocator, "owner/repo");
    defer client.deinit();

    // startWebhooks stores callback regardless of webhook outcome
    client.startWebhooks(std.testing.allocator, testEventCallback, null) catch {};
    try std.testing.expect(client.event_callback == testEventCallback);

    // stopWebhooks cleans up without crashing
    client.stopWebhooks();
    try std.testing.expect(client.webhook_process == null);
    try std.testing.expect(client.polling_thread == null);
}

test "github - polling thread starts and stops cleanly" {
    var client = GitHubClient.init(std.testing.allocator, "owner/repo");
    defer client.deinit();

    client.startPollingFallback();
    try std.testing.expect(client.polling_running.load(.acquire));
    try std.testing.expect(client.polling_thread != null);

    client.stopWebhooks();
    try std.testing.expect(!client.polling_running.load(.acquire));
    try std.testing.expect(client.polling_thread == null);
}

const TestCallbackData = struct {
    callback_count: u32 = 0,
    push_count: u32 = 0,
    pr_count: u32 = 0,
};

fn testPollCallback(event_type: ?[*:0]const u8, _: ?[*:0]const u8, userdata: ?*anyopaque) callconv(.c) void {
    if (userdata) |ud| {
        const data: *TestCallbackData = @ptrCast(@alignCast(ud));
        data.callback_count += 1;
        if (event_type) |et| {
            const span = std.mem.span(et);
            if (std.mem.eql(u8, span, "push")) data.push_count += 1;
            if (std.mem.eql(u8, span, "pull_request")) data.pr_count += 1;
        }
    }
}

test "github - processEvents fires callback for push on teammux branch" {
    var client = GitHubClient.init(std.testing.allocator, "owner/repo");
    defer client.deinit();

    var test_data = TestCallbackData{};
    client.event_callback = testPollCallback;
    client.event_userdata = @ptrCast(&test_data);

    const json =
        \\[{"id":"100","type":"PushEvent","payload":{"ref":"refs/heads/teammux/worker-1"}}]
    ;

    try client.processEvents(json);
    try std.testing.expect(test_data.callback_count == 1);
    try std.testing.expect(test_data.push_count == 1);
}

test "github - processEvents fires callback for PR on teammux branch" {
    var client = GitHubClient.init(std.testing.allocator, "owner/repo");
    defer client.deinit();

    var test_data = TestCallbackData{};
    client.event_callback = testPollCallback;
    client.event_userdata = @ptrCast(&test_data);

    const json =
        \\[{"id":"200","type":"PullRequestEvent","payload":{"action":"opened","pull_request":{"head":{"ref":"teammux/worker-2"}}}}]
    ;

    try client.processEvents(json);
    try std.testing.expect(test_data.callback_count == 1);
    try std.testing.expect(test_data.pr_count == 1);
}

test "github - processEvents ignores non-teammux branches" {
    var client = GitHubClient.init(std.testing.allocator, "owner/repo");
    defer client.deinit();

    var test_data = TestCallbackData{};
    client.event_callback = testPollCallback;
    client.event_userdata = @ptrCast(&test_data);

    const json =
        \\[{"id":"300","type":"PushEvent","payload":{"ref":"refs/heads/main"}}]
    ;

    try client.processEvents(json);
    try std.testing.expect(test_data.callback_count == 0);
}

test "github - processEvents deduplicates by event ID" {
    var client = GitHubClient.init(std.testing.allocator, "owner/repo");
    defer client.deinit();

    var test_data = TestCallbackData{};
    client.event_callback = testPollCallback;
    client.event_userdata = @ptrCast(&test_data);

    const json =
        \\[{"id":"400","type":"PushEvent","payload":{"ref":"refs/heads/teammux/worker-1"}}]
    ;

    try client.processEvents(json);
    try std.testing.expect(test_data.callback_count == 1);

    // Same event ID — should not fire again
    try client.processEvents(json);
    try std.testing.expect(test_data.callback_count == 1);
}

test "github - isTeammuxBranch matches correct patterns" {
    try std.testing.expect(isTeammuxBranch("refs/heads/teammux/worker-1"));
    try std.testing.expect(isTeammuxBranch("teammux/worker-2"));
    try std.testing.expect(!isTeammuxBranch("refs/heads/main"));
    try std.testing.expect(!isTeammuxBranch("feature/something"));
}

test "github - mapEventType maps correctly" {
    try std.testing.expectEqualStrings("push", mapEventType("PushEvent").?);
    try std.testing.expectEqualStrings("pull_request", mapEventType("PullRequestEvent").?);
    try std.testing.expect(mapEventType("WatchEvent") == null);
}
