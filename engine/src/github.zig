const std = @import("std");
const worktree = @import("worktree.zig");
const bus = @import("bus.zig");

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

/// Callback for routing messages to the bus.
/// Args: (to_worker_id, from_worker_id, msg_type_int, payload_json, userdata) → tm_result_t
/// See also: commands.BusSendFn (identical signature).
pub const BusSendFn = *const fn (u32, u32, c_int, ?[*:0]const u8, ?*anyopaque) callconv(.c) c_int;

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
    bus_send_fn: ?BusSendFn,
    bus_send_userdata: ?*anyopaque,

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
            .bus_send_fn = null,
            .bus_send_userdata = null,
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
    /// gh pr create outputs the PR URL as plain text to stdout on success.
    pub fn createPr(
        self: *GitHubClient,
        allocator: std.mem.Allocator,
        branch: []const u8,
        title: []const u8,
        body: []const u8,
    ) !Pr {
        const repo = self.repo orelse return error.NoRepo;

        const result = try runGhCommand(allocator, &.{
            "pr",     "create",
            "--repo",  repo,
            "--head",  branch,
            "--title", title,
            "--body",  body,
        });
        defer allocator.free(result);

        // gh pr create outputs the PR URL as plain text
        const url = try allocator.dupe(u8, std.mem.trim(u8, result, &[_]u8{ '\n', '\r', ' ' }));

        return .{
            .pr_number = 0,
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

            // Route PR status changes through bus for teammux/* branches
            if (std.mem.eql(u8, event_type, "PullRequestEvent")) {
                self.routePrStatusEvent(allocator, event, branch);
            }

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

    /// Route a PullRequestEvent as TM_MSG_PR_STATUS=15 through the bus.
    /// Extracts PR status, URL, and worker ID from the event payload.
    fn routePrStatusEvent(self: *GitHubClient, allocator: std.mem.Allocator, event: std.json.Value, branch: []const u8) void {
        const send_fn = self.bus_send_fn orelse return; // Feature not wired — acceptable silent return

        const obj = switch (event) {
            .object => |o| o,
            else => {
                std.log.warn("[teammux] routePrStatusEvent: event is not an object", .{});
                return;
            },
        };
        const payload_obj = switch (obj.get("payload") orelse {
            std.log.warn("[teammux] routePrStatusEvent: missing payload in PullRequestEvent", .{});
            return;
        }) {
            .object => |o| o,
            else => {
                std.log.warn("[teammux] routePrStatusEvent: payload is not an object", .{});
                return;
            },
        };

        // Determine status from action + merged flag
        const action = switch (payload_obj.get("action") orelse {
            std.log.warn("[teammux] routePrStatusEvent: missing action in PullRequestEvent", .{});
            return;
        }) {
            .string => |s| s,
            else => {
                std.log.warn("[teammux] routePrStatusEvent: action is not a string", .{});
                return;
            },
        };
        const status = mapPrAction(payload_obj, action) orelse return; // Irrelevant action (e.g. "labeled") — acceptable silent skip

        // Extract PR URL from payload.pull_request.html_url
        const pr_obj = switch (payload_obj.get("pull_request") orelse {
            std.log.warn("[teammux] routePrStatusEvent: missing pull_request object", .{});
            return;
        }) {
            .object => |o| o,
            else => {
                std.log.warn("[teammux] routePrStatusEvent: pull_request is not an object", .{});
                return;
            },
        };
        const pr_url = switch (pr_obj.get("html_url") orelse {
            std.log.warn("[teammux] routePrStatusEvent: missing html_url in pull_request", .{});
            return;
        }) {
            .string => |s| s,
            else => {
                std.log.warn("[teammux] routePrStatusEvent: html_url is not a string", .{});
                return;
            },
        };

        // Extract worker ID from branch name
        const worker_id = extractWorkerIdFromBranch(branch) orelse {
            std.log.warn("[teammux] routePrStatusEvent: cannot extract worker_id from branch '{s}'", .{branch});
            return;
        };

        // Build payload JSON: {"pr_url":"...","status":"...","worker_id":N}
        const payload_json = std.fmt.allocPrint(allocator,
            \\{{"pr_url":"{s}","status":"{s}","worker_id":{d}}}
        , .{ pr_url, status, worker_id }) catch {
            std.log.warn("[teammux] routePrStatusEvent: payload allocation failed", .{});
            return;
        };
        defer allocator.free(payload_json);

        const payload_z = allocator.dupeZ(u8, payload_json) catch {
            std.log.warn("[teammux] routePrStatusEvent: payload dupeZ failed", .{});
            return;
        };
        defer allocator.free(payload_z);

        const rc = send_fn(0, worker_id, @intFromEnum(bus.MessageType.pr_status), payload_z.ptr, self.bus_send_userdata);
        if (rc != 0) {
            std.log.warn("[teammux] PR status bus send failed: rc={d}", .{rc});
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

/// Extract worker ID from a teammux branch name.
/// Pattern: teammux/worker-{id}-* or refs/heads/teammux/worker-{id}-*
/// Returns null if pattern does not match.
pub fn extractWorkerIdFromBranch(branch: []const u8) ?u32 {
    // Strip refs/heads/ prefix if present
    const stripped = if (std.mem.startsWith(u8, branch, "refs/heads/"))
        branch["refs/heads/".len..]
    else
        branch;

    // Must start with teammux/worker-
    const prefix = "teammux/worker-";
    if (!std.mem.startsWith(u8, stripped, prefix)) return null;

    const after_prefix = stripped[prefix.len..];
    // Find end of digits (stop at '-' or end of string)
    var end: usize = 0;
    while (end < after_prefix.len and after_prefix[end] >= '0' and after_prefix[end] <= '9') : (end += 1) {}
    if (end == 0) return null;

    return std.fmt.parseInt(u32, after_prefix[0..end], 10) catch null;
}

/// Map GitHub PullRequestEvent action to PR status string.
/// "closed" with merged=true → "merged", "closed" with merged=false → "closed",
/// "opened"/"reopened" → "open". Returns null for irrelevant actions.
fn mapPrAction(payload_obj: std.json.ObjectMap, action: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, action, "opened") or std.mem.eql(u8, action, "reopened")) {
        return "open";
    }
    if (std.mem.eql(u8, action, "closed")) {
        // Check if merged
        const pr_obj = switch (payload_obj.get("pull_request") orelse return "closed") {
            .object => |o| o,
            else => return "closed",
        };
        const merged = switch (pr_obj.get("merged") orelse return "closed") {
            .bool => |b| b,
            else => return "closed",
        };
        return if (merged) "merged" else "closed";
    }
    return null;
}

/// Extract a quoted string value for a given key from a flat JSON string.
/// Simple scan approach matching the codebase pattern in commands.zig.
fn extractJsonStringSimple(json: []const u8, key: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, search) orelse return null;
    const after_key = json[key_pos + search.len ..];

    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ':' or after_key[i] == ' ' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}
    if (i >= after_key.len or after_key[i] != '"') return null;
    i += 1; // skip opening quote

    const start = i;
    while (i < after_key.len) : (i += 1) {
        if (after_key[i] == '\\' and i + 1 < after_key.len) {
            i += 1;
            continue;
        }
        if (after_key[i] == '"') break;
    }
    if (i >= after_key.len) return null;
    return after_key[start..i];
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

test "github - processEvents handles empty array" {
    var client = GitHubClient.init(std.testing.allocator, "owner/repo");
    defer client.deinit();

    var test_data = TestCallbackData{};
    client.event_callback = testPollCallback;
    client.event_userdata = @ptrCast(&test_data);

    try client.processEvents("[]");
    try std.testing.expect(test_data.callback_count == 0);
}

test "github - processEvents handles non-array JSON" {
    var client = GitHubClient.init(std.testing.allocator, "owner/repo");
    defer client.deinit();

    var test_data = TestCallbackData{};
    client.event_callback = testPollCallback;
    client.event_userdata = @ptrCast(&test_data);

    try client.processEvents("{}");
    try std.testing.expect(test_data.callback_count == 0);
}

test "github - processEvents skips events with missing fields" {
    var client = GitHubClient.init(std.testing.allocator, "owner/repo");
    defer client.deinit();

    var test_data = TestCallbackData{};
    client.event_callback = testPollCallback;
    client.event_userdata = @ptrCast(&test_data);

    // Missing "id" field
    try client.processEvents(
        \\[{"type":"PushEvent","payload":{"ref":"refs/heads/teammux/w1"}}]
    );
    try std.testing.expect(test_data.callback_count == 0);

    // Missing "type" field
    try client.processEvents(
        \\[{"id":"500","payload":{"ref":"refs/heads/teammux/w1"}}]
    );
    try std.testing.expect(test_data.callback_count == 0);

    // Missing "payload" field
    try client.processEvents(
        \\[{"id":"501","type":"PushEvent"}]
    );
    try std.testing.expect(test_data.callback_count == 0);
}

test "github - processEvents handles multi-event batch with dedup" {
    var client = GitHubClient.init(std.testing.allocator, "owner/repo");
    defer client.deinit();

    var test_data = TestCallbackData{};
    client.event_callback = testPollCallback;
    client.event_userdata = @ptrCast(&test_data);

    // Batch: 2 teammux branches + 1 main (newest first)
    const json =
        \\[{"id":"603","type":"PushEvent","payload":{"ref":"refs/heads/teammux/worker-3"}},
        \\{"id":"602","type":"PushEvent","payload":{"ref":"refs/heads/main"}},
        \\{"id":"601","type":"PushEvent","payload":{"ref":"refs/heads/teammux/worker-1"}}]
    ;

    try client.processEvents(json);
    try std.testing.expect(test_data.callback_count == 2);
    try std.testing.expect(test_data.push_count == 2);
    try std.testing.expectEqualStrings("603", client.last_event_id.?);

    // Second poll: only event 604 is new (603 already seen)
    test_data.callback_count = 0;
    test_data.push_count = 0;
    const json2 =
        \\[{"id":"604","type":"PushEvent","payload":{"ref":"refs/heads/teammux/worker-4"}},
        \\{"id":"603","type":"PushEvent","payload":{"ref":"refs/heads/teammux/worker-3"}}]
    ;

    try client.processEvents(json2);
    try std.testing.expect(test_data.callback_count == 1);
    try std.testing.expectEqualStrings("604", client.last_event_id.?);
}

// ─── T7 tests ────────────────────────────────────────────

test "github - extractWorkerIdFromBranch parses valid patterns" {
    try std.testing.expect(extractWorkerIdFromBranch("teammux/worker-2-auth").? == 2);
    try std.testing.expect(extractWorkerIdFromBranch("teammux/worker-0-setup").? == 0);
    try std.testing.expect(extractWorkerIdFromBranch("teammux/worker-42-long-name").? == 42);
    try std.testing.expect(extractWorkerIdFromBranch("refs/heads/teammux/worker-7-fix").? == 7);
}

test "github - extractWorkerIdFromBranch returns null for invalid patterns" {
    try std.testing.expect(extractWorkerIdFromBranch("main") == null);
    try std.testing.expect(extractWorkerIdFromBranch("teammux/feature-branch") == null);
    try std.testing.expect(extractWorkerIdFromBranch("teammux/worker-") == null);
    try std.testing.expect(extractWorkerIdFromBranch("feature/worker-2-auth") == null);
    try std.testing.expect(extractWorkerIdFromBranch("teammux/worker-abc-auth") == null);
}

test "github - extractJsonStringSimple parses url from gh JSON output" {
    const json = "{\"url\":\"https://github.com/owner/repo/pull/42\"}";
    const url = extractJsonStringSimple(json, "url");
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("https://github.com/owner/repo/pull/42", url.?);
}

test "github - extractJsonStringSimple returns null for missing key" {
    const json = "{\"other\":\"value\"}";
    try std.testing.expect(extractJsonStringSimple(json, "url") == null);
}

test "github - extractJsonStringSimple handles whitespace" {
    const json = "{ \"url\" : \"https://example.com\" }";
    const url = extractJsonStringSimple(json, "url");
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("https://example.com", url.?);
}

const BusTestData = struct {
    call_count: u32 = 0,
    last_to: u32 = 99,
    last_from: u32 = 99,
    last_msg_type: c_int = -1,
    last_payload: [512]u8 = undefined,
    last_payload_len: usize = 0,
};

fn testBusSend(to: u32, from: u32, msg_type: c_int, payload: ?[*:0]const u8, userdata: ?*anyopaque) callconv(.c) c_int {
    if (userdata) |ud| {
        const data: *BusTestData = @ptrCast(@alignCast(ud));
        data.call_count += 1;
        data.last_to = to;
        data.last_from = from;
        data.last_msg_type = msg_type;
        if (payload) |p| {
            const slice = std.mem.span(p);
            const len = @min(slice.len, data.last_payload.len);
            @memcpy(data.last_payload[0..len], slice[0..len]);
            data.last_payload_len = len;
        }
    }
    return 0;
}

test "github - processEvents routes PR status for teammux branch via bus_send_fn" {
    var client = GitHubClient.init(std.testing.allocator, "owner/repo");
    defer client.deinit();

    var bus_data = BusTestData{};
    client.bus_send_fn = testBusSend;
    client.bus_send_userdata = @ptrCast(&bus_data);

    // Also need event_callback set (processEvents uses it for generic forwarding)
    var test_data = TestCallbackData{};
    client.event_callback = testPollCallback;
    client.event_userdata = @ptrCast(&test_data);

    const json =
        \\[{"id":"700","type":"PullRequestEvent","payload":{"action":"opened","pull_request":{"html_url":"https://github.com/o/r/pull/1","merged":false,"head":{"ref":"teammux/worker-3-auth"}}}}]
    ;

    try client.processEvents(json);

    // Bus should have been called with TM_MSG_PR_STATUS=15
    try std.testing.expect(bus_data.call_count == 1);
    try std.testing.expect(bus_data.last_msg_type == @intFromEnum(bus.MessageType.pr_status));
    try std.testing.expect(bus_data.last_to == 0); // Team Lead
    try std.testing.expect(bus_data.last_from == 3); // worker_id from branch

    // Payload should contain status "open"
    const payload_slice = bus_data.last_payload[0..bus_data.last_payload_len];
    try std.testing.expect(std.mem.indexOf(u8, payload_slice, "\"status\":\"open\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload_slice, "\"worker_id\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload_slice, "https://github.com/o/r/pull/1") != null);
}

test "github - processEvents detects merged PR status" {
    var client = GitHubClient.init(std.testing.allocator, "owner/repo");
    defer client.deinit();

    var bus_data = BusTestData{};
    client.bus_send_fn = testBusSend;
    client.bus_send_userdata = @ptrCast(&bus_data);

    var test_data = TestCallbackData{};
    client.event_callback = testPollCallback;
    client.event_userdata = @ptrCast(&test_data);

    const json =
        \\[{"id":"701","type":"PullRequestEvent","payload":{"action":"closed","pull_request":{"html_url":"https://github.com/o/r/pull/2","merged":true,"head":{"ref":"teammux/worker-5-fix"}}}}]
    ;

    try client.processEvents(json);
    try std.testing.expect(bus_data.call_count == 1);

    const payload_slice = bus_data.last_payload[0..bus_data.last_payload_len];
    try std.testing.expect(std.mem.indexOf(u8, payload_slice, "\"status\":\"merged\"") != null);
    try std.testing.expect(bus_data.last_from == 5);
}

test "github - processEvents detects closed (not merged) PR status" {
    var client = GitHubClient.init(std.testing.allocator, "owner/repo");
    defer client.deinit();

    var bus_data = BusTestData{};
    client.bus_send_fn = testBusSend;
    client.bus_send_userdata = @ptrCast(&bus_data);

    var test_data = TestCallbackData{};
    client.event_callback = testPollCallback;
    client.event_userdata = @ptrCast(&test_data);

    const json =
        \\[{"id":"702","type":"PullRequestEvent","payload":{"action":"closed","pull_request":{"html_url":"https://github.com/o/r/pull/3","merged":false,"head":{"ref":"teammux/worker-1-feat"}}}}]
    ;

    try client.processEvents(json);
    try std.testing.expect(bus_data.call_count == 1);

    const payload_slice = bus_data.last_payload[0..bus_data.last_payload_len];
    try std.testing.expect(std.mem.indexOf(u8, payload_slice, "\"status\":\"closed\"") != null);
    try std.testing.expect(bus_data.last_from == 1);
}

test "github - processEvents does not route PR status for non-teammux branch" {
    var client = GitHubClient.init(std.testing.allocator, "owner/repo");
    defer client.deinit();

    var bus_data = BusTestData{};
    client.bus_send_fn = testBusSend;
    client.bus_send_userdata = @ptrCast(&bus_data);

    var test_data = TestCallbackData{};
    client.event_callback = testPollCallback;
    client.event_userdata = @ptrCast(&test_data);

    const json =
        \\[{"id":"703","type":"PullRequestEvent","payload":{"action":"opened","pull_request":{"html_url":"https://github.com/o/r/pull/4","merged":false,"head":{"ref":"feature/some-branch"}}}}]
    ;

    try client.processEvents(json);
    // Bus should NOT have been called (non-teammux branch)
    try std.testing.expect(bus_data.call_count == 0);
    // Event callback also not called (filtered by isTeammuxBranch)
    try std.testing.expect(test_data.callback_count == 0);
}

test "github - processEvents maps reopened action to open status" {
    var client = GitHubClient.init(std.testing.allocator, "owner/repo");
    defer client.deinit();

    var bus_data = BusTestData{};
    client.bus_send_fn = testBusSend;
    client.bus_send_userdata = @ptrCast(&bus_data);

    var test_data = TestCallbackData{};
    client.event_callback = testPollCallback;
    client.event_userdata = @ptrCast(&test_data);

    const json =
        \\[{"id":"710","type":"PullRequestEvent","payload":{"action":"reopened","pull_request":{"html_url":"https://github.com/o/r/pull/10","merged":false,"head":{"ref":"teammux/worker-8-reopen"}}}}]
    ;

    try client.processEvents(json);
    try std.testing.expect(bus_data.call_count == 1);

    const payload_slice = bus_data.last_payload[0..bus_data.last_payload_len];
    try std.testing.expect(std.mem.indexOf(u8, payload_slice, "\"status\":\"open\"") != null);
    try std.testing.expect(bus_data.last_from == 8);
}

test "github - processEvents defaults to closed when merged field missing" {
    var client = GitHubClient.init(std.testing.allocator, "owner/repo");
    defer client.deinit();

    var bus_data = BusTestData{};
    client.bus_send_fn = testBusSend;
    client.bus_send_userdata = @ptrCast(&bus_data);

    var test_data = TestCallbackData{};
    client.event_callback = testPollCallback;
    client.event_userdata = @ptrCast(&test_data);

    // closed action but no "merged" field in pull_request — should default to "closed"
    const json =
        \\[{"id":"711","type":"PullRequestEvent","payload":{"action":"closed","pull_request":{"html_url":"https://github.com/o/r/pull/11","head":{"ref":"teammux/worker-9-close"}}}}]
    ;

    try client.processEvents(json);
    try std.testing.expect(bus_data.call_count == 1);

    const payload_slice = bus_data.last_payload[0..bus_data.last_payload_len];
    try std.testing.expect(std.mem.indexOf(u8, payload_slice, "\"status\":\"closed\"") != null);
    try std.testing.expect(bus_data.last_from == 9);
}

test "github - extractJsonStringSimple handles escaped quotes in value" {
    const json = "{\"title\":\"Fix \\\"null\\\" handling\"}";
    const title = extractJsonStringSimple(json, "title");
    try std.testing.expect(title != null);
    // extractJsonStringSimple skips escaped quotes — returns content between outer quotes
    try std.testing.expect(std.mem.indexOf(u8, title.?, "null") != null);
}

test "github - extractJsonStringSimple returns null for truncated input" {
    const json = "{\"url\":\"https://example.com";
    try std.testing.expect(extractJsonStringSimple(json, "url") == null);
}
