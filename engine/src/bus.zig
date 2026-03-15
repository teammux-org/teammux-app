const std = @import("std");
const worktree = @import("worktree.zig");

// ─────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────

pub const MessageType = enum(c_int) {
    task = 0,
    instruction = 1,
    context = 2,
    status_req = 3,
    status_rpt = 4,
    completion = 5,
    err = 6,
    broadcast = 7,

    pub fn toString(self: MessageType) []const u8 {
        return switch (self) {
            .task => "task",
            .instruction => "instruction",
            .context => "context",
            .status_req => "status_req",
            .status_rpt => "status_rpt",
            .completion => "completion",
            .err => "error",
            .broadcast => "broadcast",
        };
    }
};

pub const Message = struct {
    from: worktree.WorkerId,
    to: worktree.WorkerId,
    msg_type: MessageType,
    payload: []const u8,
    timestamp: u64,
    seq: u64,
    git_commit: ?[]const u8,
};

// ─────────────────────────────────────────────────────────
// Message Bus
// ─────────────────────────────────────────────────────────

pub const MessageBus = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    seq_counter: std.atomic.Value(u64),
    log_file: ?std.fs.File,
    log_path: []const u8,
    project_root: []const u8,
    subscriber_cb: ?*const fn (?*const CMessage, ?*anyopaque) callconv(.c) c_int,
    subscriber_userdata: ?*anyopaque,
    retry_delays_ns: [3]u64 = .{
        1 * std.time.ns_per_s,
        2 * std.time.ns_per_s,
        4 * std.time.ns_per_s,
    },

    pub fn init(allocator: std.mem.Allocator, log_dir: []const u8, session_id: []const u8, project_root: []const u8) !MessageBus {
        // Ensure log directory exists
        std.fs.makeDirAbsolute(log_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Build log file path: {log_dir}/{YYYY-MM-DD}-{session_id}.jsonl
        var date_buf: [10]u8 = undefined;
        getDateString(&date_buf);
        const log_path = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}.jsonl", .{ log_dir, date_buf, session_id });
        errdefer allocator.free(log_path);

        // Open log file (create or append)
        const file = try std.fs.createFileAbsolute(log_path, .{ .truncate = false });
        // Seek to end for append — propagate error (corrupted file handle = unsafe to write)
        try file.seekFromEnd(0);

        return .{
            .allocator = allocator,
            .mutex = .{},
            .seq_counter = std.atomic.Value(u64).init(0),
            .log_file = file,
            .log_path = log_path,
            .project_root = project_root,
            .subscriber_cb = null,
            .subscriber_userdata = null,
        };
    }

    /// Send a message to a specific worker.
    /// Delivery: logs to JSONL, then fires tm_message_cb callback to Swift.
    /// Returns error.DeliveryFailed if the callback fails after all retries.
    /// The message is always persisted to JSONL regardless of delivery outcome.
    /// Swift is responsible for injecting text into the Ghostty SurfaceView.
    pub fn send(
        self: *MessageBus,
        to: worktree.WorkerId,
        from: worktree.WorkerId,
        msg_type: MessageType,
        payload: []const u8,
    ) !void {
        // 1. Assign sequence number atomically
        const seq = self.seq_counter.fetchAdd(1, .monotonic);

        // 2. Capture git commit hash (TD4)
        const git_commit = self.captureGitCommit();
        defer if (git_commit) |c| self.allocator.free(c);

        // 3. Build message
        const msg = Message{
            .from = from,
            .to = to,
            .msg_type = msg_type,
            .payload = payload,
            .timestamp = @intCast(std.time.timestamp()),
            .seq = seq,
            .git_commit = git_commit,
        };

        // 4. Persist to log BEFORE delivery (guarantees log even if callback fails)
        try self.appendLog(msg);

        // 5. Fire callback to Swift for delivery with retry on failure.
        // Initial attempt + up to 3 retries with exponential backoff (1s, 2s, 4s).
        // On 4th failure: append FAILED line to JSONL log and return error.
        if (self.subscriber_cb) |cb| {
            var c_msg = try self.toCMessage(msg);
            defer self.freeCMessage(c_msg);

            var last_rc = cb(&c_msg, self.subscriber_userdata);
            if (last_rc == 0) return; // TM_OK — delivered

            // Initial attempt failed — retry up to 3 times
            for (self.retry_delays_ns) |delay| {
                std.log.info("[teammux] message seq={d} delivery failed (rc={d}), retrying in {d}s", .{ seq, last_rc, delay / std.time.ns_per_s });
                std.Thread.sleep(delay);
                last_rc = cb(&c_msg, self.subscriber_userdata);
                if (last_rc == 0) return; // TM_OK — delivered on retry
            }

            // All retries exhausted — append FAILED audit line to log
            std.log.info("[teammux] message seq={d} delivery FAILED after 4 attempts (last rc={d})", .{ seq, last_rc });
            self.appendFailedLog(seq, 3) catch |err| {
                std.log.info("[teammux] message seq={d} FAILED audit log also failed: {s}", .{ seq, @errorName(err) });
            };
            return error.DeliveryFailed;
        } else {
            std.log.info("[teammux] message seq={d} logged but no subscriber (undelivered)", .{seq});
        }
    }

    /// Broadcast a message to all active workers.
    pub fn broadcast(
        self: *MessageBus,
        from: worktree.WorkerId,
        msg_type: MessageType,
        payload: []const u8,
        roster: *worktree.Roster,
    ) !void {
        // Hold roster mutex to prevent concurrent modification during iteration
        roster.mutex.lock();
        defer roster.mutex.unlock();

        var it = roster.workers.iterator();
        while (it.next()) |entry| {
            const worker_id = entry.key_ptr.*;
            self.send(worker_id, from, msg_type, payload) catch |err| {
                if (err == error.DeliveryFailed) continue; // per-worker failure, try others
                return err;
            };
        }
    }

    pub fn subscribe(
        self: *MessageBus,
        callback: ?*const fn (?*const CMessage, ?*anyopaque) callconv(.c) c_int,
        userdata: ?*anyopaque,
    ) void {
        self.subscriber_cb = callback;
        self.subscriber_userdata = userdata;
    }

    fn appendLog(self: *MessageBus, msg: Message) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const file = self.log_file orelse return error.LogFileUnavailable;
        const line = try self.formatJsonLine(msg);
        defer self.allocator.free(line);
        try file.writeAll(line);
        try file.writeAll("\n");
    }

    /// Append a delivery failure audit line to the JSONL log.
    fn appendFailedLog(self: *MessageBus, seq_num: u64, retries: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const file = self.log_file orelse return error.LogFileUnavailable;
        const ts: u64 = @intCast(std.time.timestamp());
        const line = try std.fmt.allocPrint(self.allocator,
            \\{{"seq":{d},"delivery_status":"FAILED","retries":{d},"timestamp":{d}}}
        , .{ seq_num, retries, ts });
        defer self.allocator.free(line);
        try file.writeAll(line);
        try file.writeAll("\n");
    }

    fn formatJsonLine(self: *MessageBus, msg: Message) ![]u8 {
        // Validate payload is valid JSON. If not, wrap it as a JSON string.
        // This prevents malformed JSONL when callers pass plain text.
        const payload = if (msg.payload.len > 0 and (msg.payload[0] == '{' or msg.payload[0] == '[' or msg.payload[0] == '"'))
            msg.payload
        else blk: {
            // Wrap bare text as a JSON string
            const wrapped = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{msg.payload});
            break :blk wrapped;
        };
        const payload_is_wrapped = payload.ptr != msg.payload.ptr;
        defer if (payload_is_wrapped) self.allocator.free(payload);

        const commit_str = if (msg.git_commit) |c| c else "null";
        const has_commit = msg.git_commit != null;

        if (has_commit) {
            return std.fmt.allocPrint(self.allocator,
                \\{{"seq":{d},"from":{d},"to":{d},"type":"{s}","timestamp":{d},"git_commit":"{s}","payload":{s}}}
            , .{ msg.seq, msg.from, msg.to, msg.msg_type.toString(), msg.timestamp, commit_str, payload });
        } else {
            return std.fmt.allocPrint(self.allocator,
                \\{{"seq":{d},"from":{d},"to":{d},"type":"{s}","timestamp":{d},"git_commit":null,"payload":{s}}}
            , .{ msg.seq, msg.from, msg.to, msg.msg_type.toString(), msg.timestamp, payload });
        }
    }

    pub fn deinit(self: *MessageBus) void {
        if (self.log_file) |file| {
            file.close();
            self.log_file = null;
        }
        self.allocator.free(self.log_path);
    }

    // ─────────────────────────────────────────────────────
    // C-compatible message struct for callbacks
    // ─────────────────────────────────────────────────────

    /// Run `git -C {project_root} rev-parse HEAD` and return the commit hash.
    /// Returns null if the command fails (not a git repo, no commits, etc.).
    fn captureGitCommit(self: *MessageBus) ?[]const u8 {
        var child = std.process.Child.init(
            &.{ "git", "-C", self.project_root, "rev-parse", "HEAD" },
            self.allocator,
        );
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        child.spawn() catch return null;
        const stdout = child.stdout.?;
        const result = stdout.readToEndAlloc(self.allocator, 256) catch {
            _ = child.wait() catch {};
            return null;
        };
        const term = child.wait() catch {
            self.allocator.free(result);
            return null;
        };

        if (term != .Exited or term.Exited != 0 or result.len == 0) {
            self.allocator.free(result);
            return null;
        }

        const trimmed = std.mem.trim(u8, result, &[_]u8{ '\n', '\r', ' ' });
        if (trimmed.len == 0) {
            self.allocator.free(result);
            return null;
        }

        const commit = self.allocator.dupe(u8, trimmed) catch {
            self.allocator.free(result);
            return null;
        };
        self.allocator.free(result);
        return commit;
    }

    fn toCMessage(self: *MessageBus, msg: Message) !CMessage {
        const payload_z = try self.allocator.dupeZ(u8, msg.payload);
        errdefer self.allocator.free(payload_z);
        const commit_z: ?[*:0]const u8 = if (msg.git_commit) |c| blk: {
            const z = try self.allocator.dupeZ(u8, c);
            break :blk z.ptr;
        } else null;
        return .{
            .from = msg.from,
            .to = msg.to,
            // Field is named msg_type in Zig (type is a keyword); ABI matches
            // tm_message_t.type by position — extern struct layout is order-based.
            .msg_type = @intFromEnum(msg.msg_type),
            .payload = payload_z.ptr,
            .timestamp = msg.timestamp,
            .seq = msg.seq,
            .git_commit = commit_z,
        };
    }

    fn freeCMessage(self: *MessageBus, c_msg: CMessage) void {
        if (c_msg.payload) |p| {
            self.allocator.free(std.mem.span(p));
        }
        if (c_msg.git_commit) |c| {
            self.allocator.free(std.mem.span(c));
        }
    }

    pub const LogFileUnavailable = error{LogFileUnavailable};
    pub const DeliveryFailed = error{DeliveryFailed};
};

/// C-compatible message struct matching tm_message_t in teammux.h.
/// Field `msg_type` corresponds to C field `type` (Zig keyword; ABI is position-based).
pub const CMessage = extern struct {
    from: u32,
    to: u32,
    msg_type: c_int,
    payload: ?[*:0]const u8,
    timestamp: u64,
    seq: u64,
    git_commit: ?[*:0]const u8,
};

// ─────────────────────────────────────────────────────────
// Message formatting for PTY injection (via Swift callback)
// ─────────────────────────────────────────────────────────

/// Format a message for terminal injection.
/// Format: \n[Teammux] {message_type}: {payload}\n
pub fn formatMessageForPty(allocator: std.mem.Allocator, msg_type: MessageType, payload: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\n[Teammux] {s}: {s}\n", .{ msg_type.toString(), payload });
}

/// Generate an 8-character random hex session ID using crypto-secure random.
pub fn generateSessionId(buf: *[8]u8) void {
    var random_bytes: [4]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    const hex = "0123456789abcdef";
    for (0..4) |i| {
        buf[i * 2] = hex[random_bytes[i] >> 4];
        buf[i * 2 + 1] = hex[random_bytes[i] & 0xf];
    }
}

/// Format current date as YYYY-MM-DD into the provided buffer.
fn getDateString(buf: *[10]u8) void {
    const ts: u64 = @intCast(std.time.timestamp());
    const epoch_day = std.time.epoch.EpochDay{ .day = @intCast(ts / 86400) };
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    _ = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1, // day_index is 0-based
    }) catch {
        @memcpy(buf, "0000-00-00");
    };
}

// ─────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────

test "bus - messages get monotonically increasing seq numbers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(log_dir);

    var b = try MessageBus.init(std.testing.allocator, log_dir, "test1234", log_dir);
    defer b.deinit();

    try b.send(1, 0, .task, "\"first\"");
    try b.send(1, 0, .instruction, "\"second\"");
    try b.send(2, 0, .context, "\"third\"");

    try std.testing.expect(b.seq_counter.load(.acquire) == 3);
}

test "bus - log file is created and contains valid JSONL" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(log_dir);

    var b = try MessageBus.init(std.testing.allocator, log_dir, "jsonltest", log_dir);
    defer b.deinit();

    try b.send(1, 0, .task, "\"hello world\"");
    try b.send(2, 0, .instruction, "\"do the thing\"");

    // Close and re-read the log file
    b.log_file.?.close();
    b.log_file = null;

    const log_content = try std.fs.cwd().openFile(b.log_path, .{});
    defer log_content.close();
    const content = try log_content.readToEndAlloc(std.testing.allocator, 1024 * 1024);
    defer std.testing.allocator.free(content);

    var line_count: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) line_count += 1;
    }
    try std.testing.expect(line_count == 2);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"seq\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"type\":\"task\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"hello world\"") != null);
}

test "bus - log file name contains date" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(log_dir);

    var b = try MessageBus.init(std.testing.allocator, log_dir, "datetest", log_dir);
    defer b.deinit();

    // Log path should contain a date pattern like YYYY-MM-DD
    try std.testing.expect(std.mem.indexOf(u8, b.log_path, "20") != null); // year starts with 20xx
    try std.testing.expect(std.mem.indexOf(u8, b.log_path, "-datetest.jsonl") != null);
}

test "bus - broadcast sends to all active workers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(log_dir);

    var b = try MessageBus.init(std.testing.allocator, log_dir, "bcasttest", log_dir);
    defer b.deinit();

    var roster = worktree.Roster.init(std.testing.allocator);
    defer roster.deinit();

    const alloc = std.testing.allocator;
    try roster.workers.put(1, .{
        .id = 1,
        .name = try alloc.dupe(u8, "w1"),
        .task_description = try alloc.dupe(u8, "t1"),
        .branch_name = try alloc.dupe(u8, "b1"),
        .worktree_path = try alloc.dupe(u8, "/tmp/w1"),
        .status = .idle,
        .agent_type = .claude_code,
        .agent_binary = try alloc.dupe(u8, "echo"),
        .model = try alloc.dupe(u8, ""),
        .spawned_at = 0,
    });
    try roster.workers.put(2, .{
        .id = 2,
        .name = try alloc.dupe(u8, "w2"),
        .task_description = try alloc.dupe(u8, "t2"),
        .branch_name = try alloc.dupe(u8, "b2"),
        .worktree_path = try alloc.dupe(u8, "/tmp/w2"),
        .status = .idle,
        .agent_type = .codex_cli,
        .agent_binary = try alloc.dupe(u8, "echo"),
        .model = try alloc.dupe(u8, ""),
        .spawned_at = 0,
    });

    try b.broadcast(0, .broadcast, "\"status update\"", &roster);
    try std.testing.expect(b.seq_counter.load(.acquire) == 2);
}

test "bus - subscriber callback is fired" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(log_dir);

    var b = try MessageBus.init(std.testing.allocator, log_dir, "cbtest12", log_dir);
    defer b.deinit();

    const CallbackState = struct {
        var received: bool = false;
        var received_seq: u64 = 0;
    };

    const callback = struct {
        fn cb(msg: ?*const CMessage, _: ?*anyopaque) callconv(.c) c_int {
            if (msg) |m| {
                CallbackState.received = true;
                CallbackState.received_seq = m.seq;
            }
            return 0; // TM_OK
        }
    }.cb;

    b.subscribe(callback, null);
    try b.send(1, 0, .task, "\"callback test\"");

    try std.testing.expect(CallbackState.received);
    try std.testing.expect(CallbackState.received_seq == 0);
}

test "bus - delivery failure is logged not silently dropped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(log_dir);

    var b = try MessageBus.init(std.testing.allocator, log_dir, "failtest", log_dir);
    defer b.deinit();

    // No subscriber registered — send should still succeed (logs message)
    try b.send(1, 0, .task, "\"no subscriber\"");

    b.log_file.?.close();
    b.log_file = null;

    const log_content = try std.fs.cwd().openFile(b.log_path, .{});
    defer log_content.close();
    const content = try log_content.readToEndAlloc(std.testing.allocator, 1024 * 1024);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "\"no subscriber\"") != null);
}

test "bus - formatMessageForPty produces correct format" {
    const result = try formatMessageForPty(std.testing.allocator, .task, "implement auth");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\n[Teammux] task: implement auth\n", result);
}

test "bus - session ID is 8 random hex chars" {
    var buf1: [8]u8 = undefined;
    var buf2: [8]u8 = undefined;
    generateSessionId(&buf1);
    generateSessionId(&buf2);
    // All chars should be hex
    for (buf1) |c| {
        try std.testing.expect(std.ascii.isHex(c));
    }
    // Two calls should produce different IDs (crypto random)
    try std.testing.expect(!std.mem.eql(u8, &buf1, &buf2));
}

test "bus - getDateString produces YYYY-MM-DD format" {
    var buf: [10]u8 = undefined;
    getDateString(&buf);
    // Should match pattern: 20XX-XX-XX
    try std.testing.expect(buf[0] == '2');
    try std.testing.expect(buf[4] == '-');
    try std.testing.expect(buf[7] == '-');
}

test "bus - git_commit is populated in a git repo" {
    const alloc = std.testing.allocator;

    // Set up a temp git repo with an initial commit
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(project_root);

    worktree.runGit(alloc, project_root, &.{ "init", "-b", "main" }) catch return;
    worktree.runGit(alloc, project_root, &.{ "config", "user.email", "test@test.com" }) catch return;
    worktree.runGit(alloc, project_root, &.{ "config", "user.name", "Test" }) catch return;

    // Create a file and commit
    const readme_path = try std.fmt.allocPrint(alloc, "{s}/README.md", .{project_root});
    defer alloc.free(readme_path);
    const readme = try std.fs.createFileAbsolute(readme_path, .{});
    try readme.writeAll("# Test");
    readme.close();
    worktree.runGit(alloc, project_root, &.{ "add", "." }) catch return;
    worktree.runGit(alloc, project_root, &.{ "commit", "-m", "initial" }) catch return;

    // Create log dir inside the temp directory
    const log_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{project_root});
    defer alloc.free(log_dir);

    var b = try MessageBus.init(alloc, log_dir, "gitcommit", project_root);
    defer b.deinit();

    try b.send(1, 0, .task, "\"test message\"");

    // Read the log and verify git_commit is a 40-char hex string
    b.log_file.?.close();
    b.log_file = null;

    const log_content = try std.fs.cwd().openFile(b.log_path, .{});
    defer log_content.close();
    const content = try log_content.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(content);

    // Should contain git_commit with a quoted hex value, not null
    try std.testing.expect(std.mem.indexOf(u8, content, "\"git_commit\":null") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"git_commit\":\"") != null);
}

test "bus - git_commit is null in non-git directory" {
    const alloc = std.testing.allocator;

    // Create a temp directory under /tmp — guaranteed outside any git repo.
    // std.testing.tmpDir creates inside .zig-cache which is inside the project
    // git repo, so git -C would traverse upward and find the parent repo.
    var rand_buf: [4]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);
    var name_buf: [8]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (0..4) |i| {
        name_buf[i * 2] = hex_chars[rand_buf[i] >> 4];
        name_buf[i * 2 + 1] = hex_chars[rand_buf[i] & 0xf];
    }
    const dir_name = try std.fmt.allocPrint(alloc, "teammux-nogit-{s}", .{&name_buf});
    defer alloc.free(dir_name);
    const project_root = try std.fmt.allocPrint(alloc, "/tmp/{s}", .{dir_name});
    defer alloc.free(project_root);

    std.fs.makeDirAbsolute(project_root) catch return; // skip if /tmp not writable
    defer {
        var parent = std.fs.openDirAbsolute("/tmp", .{}) catch unreachable;
        defer parent.close();
        parent.deleteTree(dir_name) catch {};
    }

    const log_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{project_root});
    defer alloc.free(log_dir);

    var b = try MessageBus.init(alloc, log_dir, "nogitcmt", project_root);
    defer b.deinit();

    try b.send(1, 0, .task, "\"no git\"");

    // Read the log and verify git_commit is null
    b.log_file.?.close();
    b.log_file = null;

    const log_content = try std.fs.cwd().openFile(b.log_path, .{});
    defer log_content.close();
    const content = try log_content.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "\"git_commit\":null") != null);
}

test "bus - retry delivers on transient failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(log_dir);

    var b = try MessageBus.init(std.testing.allocator, log_dir, "retryok1", log_dir);
    defer b.deinit();
    b.retry_delays_ns = .{ 0, 0, 0 }; // no sleep in tests

    const State = struct {
        var call_count: u32 = 0;
    };
    State.call_count = 0;

    const callback = struct {
        fn cb(_: ?*const CMessage, _: ?*anyopaque) callconv(.c) c_int {
            State.call_count += 1;
            // Fail first 2 times, succeed on 3rd (retry 2)
            return if (State.call_count <= 2) 8 else 0; // TM_ERR_BUS then TM_OK
        }
    }.cb;

    b.subscribe(callback, null);
    try b.send(1, 0, .task, "\"retry test\"");

    // 1 initial + 2 retries = 3 calls before success
    try std.testing.expect(State.call_count == 3);

    // No FAILED line should be in the log
    b.log_file.?.close();
    b.log_file = null;
    const log_content = try std.fs.cwd().openFile(b.log_path, .{});
    defer log_content.close();
    const content = try log_content.readToEndAlloc(std.testing.allocator, 1024 * 1024);
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"delivery_status\":\"FAILED\"") == null);
}

test "bus - retry exhaustion logs FAILED" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(log_dir);

    var b = try MessageBus.init(std.testing.allocator, log_dir, "retryfai", log_dir);
    defer b.deinit();
    b.retry_delays_ns = .{ 0, 0, 0 }; // no sleep in tests

    const State = struct {
        var call_count: u32 = 0;
    };
    State.call_count = 0;

    const callback = struct {
        fn cb(_: ?*const CMessage, _: ?*anyopaque) callconv(.c) c_int {
            State.call_count += 1;
            return 8; // TM_ERR_BUS — always fail
        }
    }.cb;

    b.subscribe(callback, null);
    try std.testing.expectError(error.DeliveryFailed, b.send(1, 0, .task, "\"will fail\""));

    // 1 initial + 3 retries = 4 total calls
    try std.testing.expect(State.call_count == 4);

    // FAILED audit line should be in the log with correct seq
    b.log_file.?.close();
    b.log_file = null;
    const log_content = try std.fs.cwd().openFile(b.log_path, .{});
    defer log_content.close();
    const content = try log_content.readToEndAlloc(std.testing.allocator, 1024 * 1024);
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"delivery_status\":\"FAILED\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"retries\":3") != null);
    // Verify seq in FAILED line matches the original message's seq (0)
    try std.testing.expect(std.mem.indexOf(u8, content, "\"seq\":0,\"delivery_status\":\"FAILED\"") != null);
}
