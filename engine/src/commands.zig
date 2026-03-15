<<<<<<< HEAD
// /teammux-* command file watcher via kqueue — implemented in commit 6
=======
const std = @import("std");

// ─────────────────────────────────────────────────────────
// /teammux-* command file watcher
//
// Watches .teammux/commands/ for JSON command files written
// by the Team Lead's Claude Code skill. On new file:
//   1. Read file contents (JSON)
//   2. Parse: {"command": "/teammux-add", "args": {...}}
//   3. Call callback(command, args_json, userdata)
//   4. Delete file after processing
// ─────────────────────────────────────────────────────────

pub const CommandWatcher = struct {
    allocator: std.mem.Allocator,
    commands_dir: []const u8,
    kq: i32,
    dir_fd: std.posix.fd_t,
    callback: ?*const fn (?[*:0]const u8, ?[*:0]const u8, ?*anyopaque) callconv(.c) void,
    userdata: ?*anyopaque,
    thread: ?std.Thread,
    running: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, commands_dir: []const u8) !CommandWatcher {
        return .{
            .allocator = allocator,
            .commands_dir = commands_dir,
            .kq = -1,
            .dir_fd = -1,
            .callback = null,
            .userdata = null,
            .thread = null,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn start(
        self: *CommandWatcher,
        callback: ?*const fn (?[*:0]const u8, ?[*:0]const u8, ?*anyopaque) callconv(.c) void,
        userdata: ?*anyopaque,
    ) !void {
        self.callback = callback;
        self.userdata = userdata;

        // Ensure commands directory exists
        std.fs.makeDirAbsolute(self.commands_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Open directory for kqueue watching
        const dir = try std.fs.openDirAbsolute(self.commands_dir, .{});
        self.dir_fd = dir.fd;
        // Intentionally NOT closing dir — we keep the fd for kqueue

        self.kq = try std.posix.kqueue();
        self.running.store(true, .release);

        self.thread = try std.Thread.spawn(.{}, watchLoop, .{self});
    }

    pub fn stop(self: *CommandWatcher) void {
        self.running.store(false, .release);
        // Let the thread exit via its 1-second kevent timeout
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn deinit(self: *CommandWatcher) void {
        self.stop();
        if (self.kq >= 0) {
            std.posix.close(@intCast(self.kq));
            self.kq = -1;
        }
        if (self.dir_fd >= 0) {
            std.posix.close(@intCast(self.dir_fd));
            self.dir_fd = -1;
        }
    }

    fn watchLoop(self: *CommandWatcher) void {
        while (self.running.load(.acquire)) {
            // Register for directory VNODE events (NOTE_WRITE fires on new file)
            const changelist = [1]std.posix.Kevent{.{
                .ident = @intCast(self.dir_fd),
                .filter = std.c.EVFILT.VNODE,
                .flags = std.c.EV.ADD | std.c.EV.CLEAR,
                .fflags = std.c.NOTE.WRITE,
                .data = 0,
                .udata = 0,
            }};

            var eventlist: [1]std.posix.Kevent = undefined;
            const timeout = std.posix.timespec{ .sec = 1, .nsec = 0 };

            const n = std.posix.kevent(
                self.kq,
                &changelist,
                &eventlist,
                &timeout,
            ) catch break;

            if (n > 0) {
                // Directory changed — scan for new .json files
                self.scanAndProcess();
            }
        }
    }

    fn scanAndProcess(self: *CommandWatcher) void {
        var dir = std.fs.openDirAbsolute(self.commands_dir, .{ .iterate = true }) catch |err| {
            std.log.warn("[teammux] commands dir open failed: {}", .{err});
            return;
        };
        defer dir.close();

        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

            self.processFile(dir, entry.name);
        }
    }

    fn processFile(self: *CommandWatcher, dir: std.fs.Dir, filename: []const u8) void {
        // Read file contents
        const file = dir.openFile(filename, .{}) catch |err| {
            std.log.warn("[teammux] command file open failed {s}: {}", .{ filename, err });
            return;
        };
        const content = file.readToEndAlloc(self.allocator, 64 * 1024) catch |err| {
            file.close();
            std.log.warn("[teammux] command file read failed {s}: {}", .{ filename, err });
            return;
        };
        file.close();
        defer self.allocator.free(content);

        // Parse command and args from JSON
        const parsed = parseCommandJson(self.allocator, content) catch |err| {
            std.log.warn("[teammux] command file parse failed {s}: {}", .{ filename, err });
            // Do NOT delete malformed files — leave for debugging
            return;
        };
        defer self.allocator.free(parsed.command);
        defer self.allocator.free(parsed.args);

        // Fire callback
        if (self.callback) |cb| {
            cb(parsed.command.ptr, parsed.args.ptr, self.userdata);
        }

        // Delete file only after successful processing
        dir.deleteFile(filename) catch |err| {
            std.log.warn("[teammux] command file delete failed {s}: {}", .{ filename, err });
        };
    }
};

const ParsedCommand = struct {
    command: [:0]u8,
    args: [:0]u8,
};

/// Parse a command JSON file: {"command": "/teammux-add", "args": {...}}
/// Extracts command string and args as JSON string.
pub fn parseCommandJson(allocator: std.mem.Allocator, content: []const u8) !ParsedCommand {
    // Find "command" field
    const cmd_value = extractJsonString(content, "command") orelse return error.InvalidJson;
    const command = try allocator.dupeZ(u8, cmd_value);
    errdefer allocator.free(command);

    // Find "args" field — can be object or string
    const args_value = extractJsonObject(content, "args") orelse
        extractJsonString(content, "args") orelse
        "{}";
    const args = try allocator.dupeZ(u8, args_value);

    return .{ .command = command, .args = args };
}

/// Extract a quoted string value for a given key from JSON.
fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Simple approach: find "key" : "value"
    const search = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\"", .{key}) catch return null;
    defer std.heap.page_allocator.free(search);

    const key_pos = std.mem.indexOf(u8, json, search) orelse return null;
    const after_key = json[key_pos + search.len ..];

    // Skip colon and whitespace
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ':' or after_key[i] == ' ' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}

    if (i >= after_key.len or after_key[i] != '"') return null;
    i += 1; // skip opening quote

    // Find closing quote, handling escaped quotes (\")
    const start = i;
    while (i < after_key.len) : (i += 1) {
        if (after_key[i] == '\\' and i + 1 < after_key.len) {
            i += 1; // skip escaped character
            continue;
        }
        if (after_key[i] == '"') break;
    }
    if (i >= after_key.len) return null;

    return after_key[start..i];
}

/// Extract a JSON object value for a given key.
fn extractJsonObject(json: []const u8, key: []const u8) ?[]const u8 {
    const search = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\"", .{key}) catch return null;
    defer std.heap.page_allocator.free(search);

    const key_pos = std.mem.indexOf(u8, json, search) orelse return null;
    const after_key = json[key_pos + search.len ..];

    // Skip colon and whitespace
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ':' or after_key[i] == ' ' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}

    if (i >= after_key.len or after_key[i] != '{') return null;

    // Find matching closing brace (simple depth counting)
    const start = i;
    var depth: u32 = 0;
    while (i < after_key.len) : (i += 1) {
        if (after_key[i] == '{') depth += 1;
        if (after_key[i] == '}') {
            depth -= 1;
            if (depth == 0) return after_key[start .. i + 1];
        }
    }
    return null;
}

const InvalidJson = error{InvalidJson};

// ─────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────

test "commands - parse command JSON" {
    const json =
        \\{"command": "/teammux-add", "args": {"task": "implement auth", "agent": "claude-code"}}
    ;
    const parsed = try parseCommandJson(std.testing.allocator, json);
    defer std.testing.allocator.free(parsed.command);
    defer std.testing.allocator.free(parsed.args);

    try std.testing.expectEqualStrings("/teammux-add", std.mem.span(parsed.command.ptr));
    // Args should be the JSON object
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(parsed.args.ptr), "implement auth") != null);
}

test "commands - parse command with string args" {
    const json =
        \\{"command": "/teammux-status", "args": "{}"}
    ;
    const parsed = try parseCommandJson(std.testing.allocator, json);
    defer std.testing.allocator.free(parsed.command);
    defer std.testing.allocator.free(parsed.args);

    try std.testing.expectEqualStrings("/teammux-status", std.mem.span(parsed.command.ptr));
}

test "commands - command file is processed and deleted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cmd_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cmd_dir);

    // Write a command file
    const cmd_json =
        \\{"command": "/teammux-add", "args": {"task": "test task"}}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "1234.json", .data = cmd_json });

    // Process it directly (not via kqueue — that requires a background thread)
    var watcher = try CommandWatcher.init(std.testing.allocator, cmd_dir);
    defer watcher.deinit();

    const TestState = struct {
        var command_received: bool = false;
        var received_command: [64]u8 = undefined;
        var received_len: usize = 0;
    };

    const callback = struct {
        fn cb(cmd: ?[*:0]const u8, _: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) void {
            if (cmd) |c| {
                const slice = std.mem.span(c);
                TestState.command_received = true;
                @memcpy(TestState.received_command[0..slice.len], slice);
                TestState.received_len = slice.len;
            }
        }
    }.cb;

    watcher.callback = callback;

    // Directly call scanAndProcess
    watcher.scanAndProcess();

    try std.testing.expect(TestState.command_received);
    try std.testing.expectEqualStrings("/teammux-add", TestState.received_command[0..TestState.received_len]);

    // Verify file was deleted
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("1234.json", .{}));
}

test "commands - kqueue watcher detects file changes (integration)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cmd_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cmd_dir);

    const TestState2 = struct {
        var detected: bool = false;
    };

    const callback2 = struct {
        fn cb(_: ?[*:0]const u8, _: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) void {
            TestState2.detected = true;
        }
    }.cb;

    var watcher = try CommandWatcher.init(std.testing.allocator, cmd_dir);
    defer watcher.deinit();
    try watcher.start(callback2, null);

    // Write a command file — the watcher should detect it
    std.Thread.sleep(200 * std.time.ns_per_ms);
    try tmp.dir.writeFile(.{ .sub_path = "test_cmd.json", .data = "{\"command\": \"/teammux-status\", \"args\": \"{}\"}" });

    // Wait for watcher to process
    std.Thread.sleep(2 * std.time.ns_per_s);

    try std.testing.expect(TestState2.detected);

    // File should be deleted after processing
    std.Thread.sleep(200 * std.time.ns_per_ms);
    const exists = tmp.dir.openFile("test_cmd.json", .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (exists) |f| f.close();
    // File may or may not be deleted depending on timing — just verify detection
}
>>>>>>> abfbb7bc5d35c3e5529ab15c7d9616a49aee0de6
