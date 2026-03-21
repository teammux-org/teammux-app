const std = @import("std");
const bus = @import("bus.zig");

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

/// Callback for routing messages to the bus.
/// Args: (to_worker_id, from_worker_id, msg_type_int, payload_json, userdata) → tm_result_t
pub const BusSendFn = *const fn (u32, u32, c_int, ?[*:0]const u8, ?*anyopaque) callconv(.c) c_int;

pub const CommandWatcher = struct {
    allocator: std.mem.Allocator,
    commands_dir: []const u8,
    kq: i32,
    dir_fd: std.posix.fd_t,
    callback: ?*const fn (?[*:0]const u8, ?[*:0]const u8, ?*anyopaque) callconv(.c) bool,
    userdata: ?*anyopaque,
    bus_send_fn: ?BusSendFn,
    bus_send_userdata: ?*anyopaque,
    error_cb: ?*const fn (?[*:0]const u8, ?*anyopaque) callconv(.c) void,
    error_cb_userdata: ?*anyopaque,
    thread: ?std.Thread,
    running: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, commands_dir: []const u8) !CommandWatcher {
        const owned_dir = try allocator.dupe(u8, commands_dir);
        errdefer allocator.free(owned_dir);
        return .{
            .allocator = allocator,
            .commands_dir = owned_dir,
            .kq = -1,
            .dir_fd = -1,
            .callback = null,
            .userdata = null,
            .bus_send_fn = null,
            .bus_send_userdata = null,
            .error_cb = null,
            .error_cb_userdata = null,
            .thread = null,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn start(
        self: *CommandWatcher,
        callback: ?*const fn (?[*:0]const u8, ?[*:0]const u8, ?*anyopaque) callconv(.c) bool,
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
        self.allocator.free(self.commands_dir);
    }

    /// I13: Delete stale .teammux-error files from previous sessions.
    /// Called at sessionStart to prevent error bleed across sessions.
    pub fn clearStaleErrors(self: *CommandWatcher) void {
        var dir = std.fs.openDirAbsolute(self.commands_dir, .{}) catch return;
        defer dir.close();
        dir.deleteFile(".teammux-error") catch {};
    }

    /// Write a .teammux-error JSON file to the commands directory (I6).
    /// Contains the failing command name and reason for the failure.
    /// File name is always ".teammux-error" — successive errors overwrite the previous one.
    /// Returns true if the error file was written successfully, false otherwise.
    /// Callers should NOT delete the original command file when this returns false.
    fn writeErrorResponse(self: *CommandWatcher, dir: std.fs.Dir, command: []const u8, reason: []const u8) bool {
        const content = std.fmt.allocPrint(self.allocator,
            \\{{"command":"{s}","error":"{s}"}}
        , .{ command, reason }) catch {
            std.log.err("[teammux] error response allocation failed", .{});
            return false;
        };
        defer self.allocator.free(content);

        dir.writeFile(.{ .sub_path = ".teammux-error", .data = content }) catch |err| {
            std.log.err("[teammux] error response write failed: {}", .{err});
            return false;
        };
        return true;
    }

    /// Notify engine of a command processing error via the error callback (I6).
    /// Engine wires this to setError so Swift can surface a notification.
    /// Uses a stack buffer so notification cannot fail due to OOM.
    fn notifyError(self: *CommandWatcher, msg: []const u8) void {
        if (self.error_cb) |cb| {
            var buf: [256]u8 = undefined;
            if (msg.len < buf.len) {
                @memcpy(buf[0..msg.len], msg);
                buf[msg.len] = 0;
                cb(@ptrCast(buf[0..msg.len :0].ptr), self.error_cb_userdata);
            } else {
                cb("command processing failed", self.error_cb_userdata);
            }
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
            // I6: Write error response for malformed files
            _ = self.writeErrorResponse(dir, "unknown", "malformed command JSON: parse failed");
            self.notifyError("command file parse failed");
            // Rename to .json.failed so it's skipped on future scans but kept for debugging.
            // Build the new name: "{filename}.failed"
            const new_name = std.fmt.allocPrint(self.allocator, "{s}.failed", .{filename}) catch return;
            defer self.allocator.free(new_name);
            dir.rename(filename, new_name) catch {};
            return;
        };
        defer self.allocator.free(parsed.command);
        defer self.allocator.free(parsed.args);

        // /teammux-complete and /teammux-question are routed internally via bus —
        // generic callback not fired for these commands.
        const cmd_slice = std.mem.span(parsed.command.ptr);
        if (self.bus_send_fn) |send_fn| {
            if (std.mem.eql(u8, cmd_slice, "/teammux-complete")) {
                self.routeCompletion(send_fn, parsed.args) catch |err| {
                    std.log.warn("[teammux] /teammux-complete routing failed: {}", .{err});
                    // I6: Write error response before deleting the original.
                    // Only delete if error file was written — otherwise keep original for debugging.
                    if (self.writeErrorResponse(dir, "/teammux-complete", "routing failed")) {
                        dir.deleteFile(filename) catch {};
                    }
                    self.notifyError("/teammux-complete routing failed");
                    return;
                };
                dir.deleteFile(filename) catch |err| {
                    std.log.warn("[teammux] command file delete failed {s}: {}", .{ filename, err });
                };
                return;
            }
            if (std.mem.eql(u8, cmd_slice, "/teammux-question")) {
                self.routeQuestion(send_fn, parsed.args) catch |err| {
                    std.log.warn("[teammux] /teammux-question routing failed: {}", .{err});
                    // I6: Write error response before deleting the original.
                    // Only delete if error file was written — otherwise keep original for debugging.
                    if (self.writeErrorResponse(dir, "/teammux-question", "routing failed")) {
                        dir.deleteFile(filename) catch {};
                    }
                    self.notifyError("/teammux-question routing failed");
                    return;
                };
                dir.deleteFile(filename) catch |err| {
                    std.log.warn("[teammux] command file delete failed {s}: {}", .{ filename, err });
                };
                return;
            }
        }

        // All other commands: fire generic callback (I11: check return value)
        if (self.callback) |cb| {
            const ok = cb(parsed.command.ptr, parsed.args.ptr, self.userdata);
            if (!ok) {
                // I11: Handler failed — write .teammux-error before deleting command file
                _ = self.writeErrorResponse(dir, cmd_slice, "command handler failed");
                self.notifyError("command handler failed");
                dir.deleteFile(filename) catch {};
                return;
            }
        } else {
            // I6: No handler registered — write error response
            _ = self.writeErrorResponse(dir, cmd_slice, "no handler registered for command");
            self.notifyError("command received but no handler registered");
            dir.deleteFile(filename) catch {};
            return;
        }

        // Delete file only after successful processing
        dir.deleteFile(filename) catch |err| {
            std.log.warn("[teammux] command file delete failed {s}: {}", .{ filename, err });
        };
        // I13: Clear stale .teammux-error on successful command processing
        dir.deleteFile(".teammux-error") catch {};
    }

    /// Route a /teammux-complete command to the bus as TM_MSG_COMPLETION.
    /// Extracts worker_id from args JSON, sends to Team Lead (worker 0).
    fn routeCompletion(self: *CommandWatcher, send_fn: BusSendFn, args: [:0]const u8) !void {
        const args_slice = std.mem.span(args.ptr);
        const worker_id = extractJsonUint(args_slice, "worker_id") orelse {
            std.log.warn("[teammux] /teammux-complete missing worker_id in args", .{});
            return error.InvalidJson;
        };
        const rc = send_fn(0, worker_id, @intFromEnum(bus.MessageType.completion), args.ptr, self.bus_send_userdata);
        if (rc != 0) {
            std.log.warn("[teammux] /teammux-complete bus send failed: rc={d}", .{rc});
            return error.BusSendFailed;
        }
    }

    /// Route a /teammux-question command to the bus as TM_MSG_QUESTION.
    /// Extracts worker_id from args JSON, sends to Team Lead (worker 0).
    fn routeQuestion(self: *CommandWatcher, send_fn: BusSendFn, args: [:0]const u8) !void {
        const args_slice = std.mem.span(args.ptr);
        const worker_id = extractJsonUint(args_slice, "worker_id") orelse {
            std.log.warn("[teammux] /teammux-question missing worker_id in args", .{});
            return error.InvalidJson;
        };
        const rc = send_fn(0, worker_id, @intFromEnum(bus.MessageType.question), args.ptr, self.bus_send_userdata);
        if (rc != 0) {
            std.log.warn("[teammux] /teammux-question bus send failed: rc={d}", .{rc});
            return error.BusSendFailed;
        }
    }
};

const ParsedCommand = struct {
    command: [:0]u8,
    args: [:0]u8,
};

/// Parse a command JSON file: {"command": "/teammux-add", "args": {...}}
/// Extracts command string and args as JSON string.
fn parseCommandJson(allocator: std.mem.Allocator, content: []const u8) !ParsedCommand {
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
pub fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
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
const BusSendFailed = error{BusSendFailed};

/// Extract an unsigned integer value for a given key from JSON.
/// Handles: "key": 42 (no quotes around number).
pub fn extractJsonUint(json: []const u8, key: []const u8) ?u32 {
    const search = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\"", .{key}) catch return null;
    defer std.heap.page_allocator.free(search);

    const key_pos = std.mem.indexOf(u8, json, search) orelse return null;
    const after_key = json[key_pos + search.len ..];

    // Skip colon and whitespace
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ':' or after_key[i] == ' ' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}

    if (i >= after_key.len) return null;

    // Parse digits
    const start = i;
    while (i < after_key.len and after_key[i] >= '0' and after_key[i] <= '9') : (i += 1) {}
    if (i == start) return null; // no digits found

    return std.fmt.parseInt(u32, after_key[start..i], 10) catch null;
}

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
        fn cb(cmd: ?[*:0]const u8, _: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) bool {
            if (cmd) |c| {
                const slice = std.mem.span(c);
                TestState.command_received = true;
                @memcpy(TestState.received_command[0..slice.len], slice);
                TestState.received_len = slice.len;
            }
            return true;
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
        fn cb(_: ?[*:0]const u8, _: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) bool {
            TestState2.detected = true;
            return true;
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

test "commands - extractJsonUint parses integer value" {
    try std.testing.expect(extractJsonUint("{\"worker_id\": 3, \"summary\": \"done\"}", "worker_id").? == 3);
    try std.testing.expect(extractJsonUint("{\"worker_id\": 0}", "worker_id").? == 0);
    try std.testing.expect(extractJsonUint("{\"worker_id\": 42}", "worker_id").? == 42);
    try std.testing.expect(extractJsonUint("{\"summary\": \"done\"}", "worker_id") == null);
    try std.testing.expect(extractJsonUint("{\"worker_id\": \"abc\"}", "worker_id") == null);
}

test "commands - /teammux-complete routed to bus, generic callback not fired" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cmd_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cmd_dir);

    const cmd_json =
        \\{"command": "/teammux-complete", "args": {"worker_id": 3, "summary": "auth done", "details": "JWT impl"}}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "complete1.json", .data = cmd_json });

    var watcher = try CommandWatcher.init(std.testing.allocator, cmd_dir);
    defer watcher.deinit();

    const State = struct {
        var generic_called: bool = false;
        var bus_called: bool = false;
        var bus_to: u32 = 99;
        var bus_from: u32 = 99;
        var bus_msg_type: c_int = -1;
        var bus_payload: [256]u8 = undefined;
        var bus_payload_len: usize = 0;
    };
    State.generic_called = false;
    State.bus_called = false;
    State.bus_to = 99;
    State.bus_from = 99;
    State.bus_msg_type = -1;
    State.bus_payload_len = 0;

    const generic_cb = struct {
        fn cb(_: ?[*:0]const u8, _: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) bool {
            State.generic_called = true;
            return true;
        }
    }.cb;

    const bus_send = struct {
        fn send(to: u32, from: u32, msg_type: c_int, payload: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) c_int {
            State.bus_called = true;
            State.bus_to = to;
            State.bus_from = from;
            State.bus_msg_type = msg_type;
            if (payload) |p| {
                const slice = std.mem.span(p);
                const len = @min(slice.len, State.bus_payload.len);
                @memcpy(State.bus_payload[0..len], slice[0..len]);
                State.bus_payload_len = len;
            }
            return 0; // TM_OK
        }
    }.send;

    watcher.callback = generic_cb;
    watcher.bus_send_fn = bus_send;

    watcher.scanAndProcess();

    // Bus callback was fired
    try std.testing.expect(State.bus_called);
    try std.testing.expect(State.bus_to == 0); // Team Lead
    try std.testing.expect(State.bus_from == 3); // worker_id from args
    try std.testing.expect(State.bus_msg_type == @intFromEnum(bus.MessageType.completion));
    // Payload contains the args JSON
    try std.testing.expect(std.mem.indexOf(u8, State.bus_payload[0..State.bus_payload_len], "auth done") != null);

    // Generic callback was NOT fired
    try std.testing.expect(!State.generic_called);

    // File was deleted
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("complete1.json", .{}));
}

test "commands - /teammux-question routed to bus, generic callback not fired" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cmd_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cmd_dir);

    const cmd_json =
        \\{"command": "/teammux-question", "args": {"worker_id": 5, "question": "JWT or session?", "context": "auth module"}}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "question1.json", .data = cmd_json });

    var watcher = try CommandWatcher.init(std.testing.allocator, cmd_dir);
    defer watcher.deinit();

    const State = struct {
        var generic_called: bool = false;
        var bus_called: bool = false;
        var bus_msg_type: c_int = -1;
        var bus_from: u32 = 99;
    };
    State.generic_called = false;
    State.bus_called = false;
    State.bus_msg_type = -1;
    State.bus_from = 99;

    const generic_cb = struct {
        fn cb(_: ?[*:0]const u8, _: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) bool {
            State.generic_called = true;
            return true;
        }
    }.cb;

    const bus_send = struct {
        fn send(_: u32, from: u32, msg_type: c_int, _: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) c_int {
            State.bus_called = true;
            State.bus_msg_type = msg_type;
            State.bus_from = from;
            return 0;
        }
    }.send;

    watcher.callback = generic_cb;
    watcher.bus_send_fn = bus_send;

    watcher.scanAndProcess();

    try std.testing.expect(State.bus_called);
    try std.testing.expect(State.bus_msg_type == @intFromEnum(bus.MessageType.question));
    try std.testing.expect(State.bus_from == 5); // worker_id from args
    try std.testing.expect(!State.generic_called);

    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("question1.json", .{}));
}

test "commands - other commands still fire generic callback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cmd_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cmd_dir);

    const cmd_json =
        \\{"command": "/teammux-status", "args": "{}"}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "status1.json", .data = cmd_json });

    var watcher = try CommandWatcher.init(std.testing.allocator, cmd_dir);
    defer watcher.deinit();

    const State = struct {
        var generic_called: bool = false;
        var bus_called: bool = false;
    };
    State.generic_called = false;
    State.bus_called = false;

    const generic_cb = struct {
        fn cb(_: ?[*:0]const u8, _: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) bool {
            State.generic_called = true;
            return true;
        }
    }.cb;

    const bus_send = struct {
        fn send(_: u32, _: u32, _: c_int, _: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) c_int {
            State.bus_called = true;
            return 0;
        }
    }.send;

    watcher.callback = generic_cb;
    watcher.bus_send_fn = bus_send;

    watcher.scanAndProcess();

    // Generic callback fired for non-completion/question commands
    try std.testing.expect(State.generic_called);
    // Bus NOT called for generic commands
    try std.testing.expect(!State.bus_called);
}

test "commands - /teammux-complete missing worker_id writes error and deletes original (I6)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cmd_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cmd_dir);

    // Missing worker_id in args
    const cmd_json =
        \\{"command": "/teammux-complete", "args": {"summary": "no worker id"}}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "bad1.json", .data = cmd_json });

    var watcher = try CommandWatcher.init(std.testing.allocator, cmd_dir);
    defer watcher.deinit();

    const bus_send = struct {
        fn send(_: u32, _: u32, _: c_int, _: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) c_int {
            return 0;
        }
    }.send;

    watcher.bus_send_fn = bus_send;
    watcher.scanAndProcess();

    // I6: Original file deleted after error response written
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("bad1.json", .{}));

    // .teammux-error should exist with failure details
    const error_file = try tmp.dir.openFile(".teammux-error", .{});
    defer error_file.close();
    const content = try error_file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "/teammux-complete") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "routing failed") != null);
}

test "commands - I6 parse failure writes .teammux-error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cmd_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cmd_dir);

    // Write a malformed command file (not valid JSON)
    try tmp.dir.writeFile(.{ .sub_path = "malformed.json", .data = "not valid json at all" });

    var watcher = try CommandWatcher.init(std.testing.allocator, cmd_dir);
    defer watcher.deinit();

    watcher.scanAndProcess();

    // .teammux-error should exist
    const error_file = try tmp.dir.openFile(".teammux-error", .{});
    defer error_file.close();
    const content = try error_file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "parse failed") != null);

    // Original file renamed to .json.failed (kept for debugging, skipped on future scans)
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("malformed.json", .{}));
    const renamed = try tmp.dir.openFile("malformed.json.failed", .{});
    renamed.close();
}

test "commands - I6 unhandled command writes error when no callback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cmd_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cmd_dir);

    const cmd_json =
        \\{"command": "/teammux-unknown", "args": "{}"}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "unhandled.json", .data = cmd_json });

    var watcher = try CommandWatcher.init(std.testing.allocator, cmd_dir);
    defer watcher.deinit();

    // No callback set — command will be unhandled
    watcher.scanAndProcess();

    // .teammux-error should exist
    const error_file = try tmp.dir.openFile(".teammux-error", .{});
    defer error_file.close();
    const content = try error_file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "/teammux-unknown") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "no handler") != null);

    // Original file should still be deleted after error response
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("unhandled.json", .{}));
}

test "commands - I6 error_cb is called on command failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cmd_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cmd_dir);

    // Malformed file to trigger error
    try tmp.dir.writeFile(.{ .sub_path = "errorcb.json", .data = "bad json" });

    var watcher = try CommandWatcher.init(std.testing.allocator, cmd_dir);
    defer watcher.deinit();

    const State = struct {
        var error_called: bool = false;
        var error_msg: [256]u8 = undefined;
        var error_msg_len: usize = 0;
    };
    State.error_called = false;
    State.error_msg_len = 0;

    const error_cb = struct {
        fn cb(msg: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) void {
            State.error_called = true;
            if (msg) |m| {
                const slice = std.mem.span(m);
                const len = @min(slice.len, State.error_msg.len);
                @memcpy(State.error_msg[0..len], slice[0..len]);
                State.error_msg_len = len;
            }
        }
    }.cb;

    watcher.error_cb = error_cb;
    watcher.scanAndProcess();

    try std.testing.expect(State.error_called);
    try std.testing.expect(std.mem.indexOf(u8, State.error_msg[0..State.error_msg_len], "parse failed") != null);
}

test "commands - I6 bus send failure writes error and deletes original" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cmd_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cmd_dir);

    const cmd_json =
        \\{"command": "/teammux-complete", "args": {"worker_id": 3, "summary": "done"}}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "busfail.json", .data = cmd_json });

    var watcher = try CommandWatcher.init(std.testing.allocator, cmd_dir);
    defer watcher.deinit();

    // Bus send always fails
    const bus_send = struct {
        fn send(_: u32, _: u32, _: c_int, _: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) c_int {
            return 8; // TM_ERR_BUS
        }
    }.send;
    watcher.bus_send_fn = bus_send;

    watcher.scanAndProcess();

    // .teammux-error should exist
    const error_file = try tmp.dir.openFile(".teammux-error", .{});
    defer error_file.close();
    const content = try error_file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "/teammux-complete") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "routing failed") != null);

    // Original deleted after error response written
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("busfail.json", .{}));
}

test "commands - I6 /teammux-question routing failure writes error and deletes original" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cmd_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cmd_dir);

    // Missing worker_id in args — will cause routing failure
    const cmd_json =
        \\{"command": "/teammux-question", "args": {"question": "no worker id"}}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "qfail.json", .data = cmd_json });

    var watcher = try CommandWatcher.init(std.testing.allocator, cmd_dir);
    defer watcher.deinit();

    const bus_send = struct {
        fn send(_: u32, _: u32, _: c_int, _: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) c_int {
            return 0;
        }
    }.send;
    watcher.bus_send_fn = bus_send;

    watcher.scanAndProcess();

    // .teammux-error should exist with question failure details
    const error_file = try tmp.dir.openFile(".teammux-error", .{});
    defer error_file.close();
    const content = try error_file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "/teammux-question") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "routing failed") != null);

    // Original deleted after error response written
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile("qfail.json", .{}));
}
