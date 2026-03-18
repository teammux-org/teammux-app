const std = @import("std");
const merge = @import("merge.zig");
const worktree = @import("worktree.zig");
const commands = @import("commands.zig");

// ─────────────────────────────────────────────────────────
// Completion history JSONL persistence (TD16)
//
// Persists completion and question events to a JSONL file.
// File: {project_root}/.teammux/logs/completion_history.jsonl
// New entries are appended (append semantics) via atomic
// read-rewrite-rename to prevent partial writes on crash.
//
// Threading: callers must serialize access externally.
// The engine guarantees single-threaded access via its
// event loop. Concurrent writers are not supported (TD24).
// ─────────────────────────────────────────────────────────

/// Maximum JSONL file size for read operations (10 MB).
const max_history_file_bytes: usize = 10 * 1024 * 1024;

pub const EventKind = enum {
    completion,
    question,

    pub fn toString(self: EventKind) []const u8 {
        return switch (self) {
            .completion => "completion",
            .question => "question",
        };
    }

    pub fn fromString(s: []const u8) ?EventKind {
        if (std.mem.eql(u8, s, "completion")) return .completion;
        if (std.mem.eql(u8, s, "question")) return .question;
        return null;
    }
};

pub const HistoryEntry = struct {
    entry_type: EventKind,
    worker_id: u32,
    role_id: []const u8, // empty string if unknown at engine layer
    content: []const u8, // summary for completion, question text for question
    git_commit: ?[]const u8, // null if unavailable
    timestamp: u64,
};

/// Owned version of HistoryEntry — all string fields are heap-allocated.
/// Free with deinit() using the same allocator that created the entry.
pub const OwnedHistoryEntry = struct {
    entry_type: EventKind,
    worker_id: u32,
    role_id: []const u8,
    content: []const u8,
    git_commit: ?[]const u8,
    timestamp: u64,

    pub fn deinit(self: OwnedHistoryEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.role_id);
        allocator.free(self.content);
        if (self.git_commit) |gc| allocator.free(gc);
    }
};

pub const HistoryLogger = struct {
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    file_path: []const u8,
    tmp_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, project_root: []const u8) !HistoryLogger {
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/.teammux/logs", .{project_root});
        errdefer allocator.free(dir_path);

        const file_path = try std.fmt.allocPrint(allocator, "{s}/completion_history.jsonl", .{dir_path});
        errdefer allocator.free(file_path);

        const tmp_path = try std.fmt.allocPrint(allocator, "{s}/completion_history.jsonl.tmp", .{dir_path});
        errdefer allocator.free(tmp_path);

        // Ensure .teammux/ exists
        const teammux_dir = try std.fmt.allocPrint(allocator, "{s}/.teammux", .{project_root});
        defer allocator.free(teammux_dir);
        std.fs.makeDirAbsolute(teammux_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Ensure .teammux/logs/ exists
        std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        return .{
            .allocator = allocator,
            .dir_path = dir_path,
            .file_path = file_path,
            .tmp_path = tmp_path,
        };
    }

    pub fn deinit(self: *HistoryLogger) void {
        self.allocator.free(self.tmp_path);
        self.allocator.free(self.file_path);
        self.allocator.free(self.dir_path);
        self.* = undefined;
    }

    /// Append a history entry via atomic read-rewrite-rename.
    /// Reads existing file content, writes existing + new line to .tmp,
    /// then renames .tmp over the original file.
    pub fn append(self: *HistoryLogger, entry: HistoryEntry) !void {
        const json_line = try serializeEntry(self.allocator, entry);
        defer self.allocator.free(json_line);

        // Read existing file content (empty string literal if file doesn't exist,
        // heap-allocated slice otherwise — track which for correct cleanup)
        var heap_allocated = true;
        const existing = std.fs.cwd().readFileAlloc(self.allocator, self.file_path, max_history_file_bytes) catch |err| switch (err) {
            error.FileNotFound => blk: {
                heap_allocated = false;
                break :blk "";
            },
            else => return err,
        };
        defer if (heap_allocated) self.allocator.free(existing);

        // Write existing + new line to .tmp
        const tmp_file = try std.fs.createFileAbsolute(self.tmp_path, .{});
        errdefer {
            tmp_file.close();
            std.fs.deleteFileAbsolute(self.tmp_path) catch |err| {
                std.log.warn("[teammux] history: failed to clean up temp file: {}", .{err});
            };
        }
        if (existing.len > 0) try tmp_file.writeAll(existing);
        try tmp_file.writeAll(json_line);
        try tmp_file.writeAll("\n");
        tmp_file.close();

        // Atomic rename: .tmp → .jsonl
        var dir = try std.fs.openDirAbsolute(self.dir_path, .{});
        defer dir.close();
        try dir.rename("completion_history.jsonl.tmp", "completion_history.jsonl");
    }

    /// Load all history entries from the JSONL file.
    /// Malformed lines are skipped with a warning. Missing file returns empty list.
    /// OutOfMemory is propagated (not masked as "malformed").
    pub fn load(self: *HistoryLogger) !std.ArrayList(OwnedHistoryEntry) {
        var entries: std.ArrayList(OwnedHistoryEntry) = .{};
        errdefer {
            for (entries.items) |e| e.deinit(self.allocator);
            entries.deinit(self.allocator);
        }

        const content = std.fs.cwd().readFileAlloc(self.allocator, self.file_path, max_history_file_bytes) catch |err| switch (err) {
            error.FileNotFound => return entries,
            else => return err,
        };
        defer self.allocator.free(content);

        var line_num: usize = 0;
        var skipped: usize = 0;
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            line_num += 1;
            if (line.len == 0) continue;
            const entry = parseEntry(self.allocator, line) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                skipped += 1;
                const preview_len = @min(line.len, 80);
                std.log.warn("[teammux] history: skipping malformed line {d}: {s}", .{ line_num, line[0..preview_len] });
                continue;
            };
            try entries.append(self.allocator, entry);
        }
        if (skipped > 0) {
            std.log.warn("[teammux] history: {d} malformed lines skipped out of {d} total", .{ skipped, line_num });
        }

        return entries;
    }

    /// Clear the history file by truncating to zero length.
    /// Missing file is a no-op.
    pub fn clear(self: *HistoryLogger) !void {
        const file = std.fs.openFileAbsolute(self.file_path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();
        try file.setEndPos(0);
    }
};

// ─────────────────────────────────────────────────────────
// JSON serialization
// ─────────────────────────────────────────────────────────

fn serializeEntry(allocator: std.mem.Allocator, entry: HistoryEntry) ![]u8 {
    const type_str = entry.entry_type.toString();
    const role_esc = try jsonEscape(allocator, entry.role_id);
    defer allocator.free(role_esc);
    const content_esc = try jsonEscape(allocator, entry.content);
    defer allocator.free(content_esc);

    if (entry.git_commit) |gc| {
        const gc_esc = try jsonEscape(allocator, gc);
        defer allocator.free(gc_esc);
        return std.fmt.allocPrint(allocator,
            \\{{"type":"{s}","worker_id":{d},"role_id":"{s}","content":"{s}","git_commit":"{s}","timestamp":{d}}}
        , .{ type_str, entry.worker_id, role_esc, content_esc, gc_esc, entry.timestamp });
    } else {
        return std.fmt.allocPrint(allocator,
            \\{{"type":"{s}","worker_id":{d},"role_id":"{s}","content":"{s}","git_commit":null,"timestamp":{d}}}
        , .{ type_str, entry.worker_id, role_esc, content_esc, entry.timestamp });
    }
}

// ─────────────────────────────────────────────────────────
// JSON parsing
// ─────────────────────────────────────────────────────────

/// Parse a JSONL line into an OwnedHistoryEntry.
/// All string fields are heap-allocated. Caller must free with deinit().
fn parseEntry(allocator: std.mem.Allocator, line: []const u8) !OwnedHistoryEntry {
    const entry_type_raw = commands.extractJsonString(line, "type") orelse return error.InvalidJson;
    const entry_type = EventKind.fromString(entry_type_raw) orelse return error.InvalidJson;

    const worker_id = commands.extractJsonUint(line, "worker_id") orelse return error.InvalidJson;

    const role_id_raw = commands.extractJsonString(line, "role_id") orelse "";
    const role_id = try jsonUnescape(allocator, role_id_raw);
    errdefer allocator.free(role_id);

    const content_raw = commands.extractJsonString(line, "content") orelse return error.InvalidJson;
    const content = try jsonUnescape(allocator, content_raw);
    errdefer allocator.free(content);

    const git_commit_raw = commands.extractJsonString(line, "git_commit");
    const git_commit = if (git_commit_raw) |gc| try jsonUnescape(allocator, gc) else null;
    errdefer if (git_commit) |gc| allocator.free(gc);

    const timestamp = extractJsonUint64(line, "timestamp") orelse return error.InvalidJson;

    return .{
        .entry_type = entry_type,
        .worker_id = worker_id,
        .role_id = role_id,
        .content = content,
        .git_commit = git_commit,
        .timestamp = timestamp,
    };
}

/// Extract a u64 value for a given key from JSON.
fn extractJsonUint64(json: []const u8, key: []const u8) ?u64 {
    // Build search string on stack to avoid heap allocation
    var search_buf: [128]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, search) orelse return null;
    const after_key = json[key_pos + search.len ..];

    // Skip colon and whitespace
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ':' or after_key[i] == ' ' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}

    if (i >= after_key.len) return null;

    // Parse digits
    const start = i;
    while (i < after_key.len and after_key[i] >= '0' and after_key[i] <= '9') : (i += 1) {}
    if (i == start) return null;

    return std.fmt.parseInt(u64, after_key[start..i], 10) catch null;
}

// ─────────────────────────────────────────────────────────
// JSON escape / unescape
// ─────────────────────────────────────────────────────────

fn jsonEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var needs_escape = false;
    for (input) |c| {
        if (c == '"' or c == '\\' or c <= 0x1F) {
            needs_escape = true;
            break;
        }
    }
    if (!needs_escape) return try allocator.dupe(u8, input);

    const hex = "0123456789abcdef";
    const buf = try allocator.alloc(u8, input.len * 6);
    var pos: usize = 0;
    for (input) |c| {
        switch (c) {
            '"' => {
                buf[pos] = '\\';
                buf[pos + 1] = '"';
                pos += 2;
            },
            '\\' => {
                buf[pos] = '\\';
                buf[pos + 1] = '\\';
                pos += 2;
            },
            '\n' => {
                buf[pos] = '\\';
                buf[pos + 1] = 'n';
                pos += 2;
            },
            '\r' => {
                buf[pos] = '\\';
                buf[pos + 1] = 'r';
                pos += 2;
            },
            '\t' => {
                buf[pos] = '\\';
                buf[pos + 1] = 't';
                pos += 2;
            },
            0x00...0x07, 0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                buf[pos] = '\\';
                buf[pos + 1] = 'u';
                buf[pos + 2] = '0';
                buf[pos + 3] = '0';
                buf[pos + 4] = hex[c >> 4];
                buf[pos + 5] = hex[c & 0x0F];
                pos += 6;
            },
            else => {
                buf[pos] = c;
                pos += 1;
            },
        }
    }
    if (pos < buf.len) {
        return try allocator.realloc(buf, pos);
    }
    return buf;
}

/// Reverse JSON string escaping: \" → ", \\ → \, \n → newline, etc.
/// Allocates and returns a new heap string with escape sequences resolved.
fn jsonUnescape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Fast path: no escape sequences
    if (std.mem.indexOf(u8, input, "\\") == null) {
        return try allocator.dupe(u8, input);
    }

    const buf = try allocator.alloc(u8, input.len);
    var pos: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            switch (input[i + 1]) {
                '"' => {
                    buf[pos] = '"';
                    pos += 1;
                    i += 2;
                },
                '\\' => {
                    buf[pos] = '\\';
                    pos += 1;
                    i += 2;
                },
                'n' => {
                    buf[pos] = '\n';
                    pos += 1;
                    i += 2;
                },
                'r' => {
                    buf[pos] = '\r';
                    pos += 1;
                    i += 2;
                },
                't' => {
                    buf[pos] = '\t';
                    pos += 1;
                    i += 2;
                },
                'b' => {
                    buf[pos] = 0x08;
                    pos += 1;
                    i += 2;
                },
                'f' => {
                    buf[pos] = 0x0C;
                    pos += 1;
                    i += 2;
                },
                'u' => {
                    // \uXXXX — parse 4 hex digits as a single byte (ASCII range only)
                    if (i + 5 < input.len) {
                        const hex_val = std.fmt.parseInt(u8, input[i + 2 .. i + 6], 16) catch {
                            buf[pos] = input[i];
                            pos += 1;
                            i += 1;
                            continue;
                        };
                        buf[pos] = hex_val;
                        pos += 1;
                        i += 6;
                    } else {
                        buf[pos] = input[i];
                        pos += 1;
                        i += 1;
                    }
                },
                else => {
                    buf[pos] = input[i];
                    pos += 1;
                    i += 1;
                },
            }
        } else {
            buf[pos] = input[i];
            pos += 1;
            i += 1;
        }
    }

    if (pos < buf.len) {
        return try allocator.realloc(buf, pos);
    }
    return buf;
}

// ─────────────────────────────────────────────────────────
// Git commit capture helper
// ─────────────────────────────────────────────────────────

/// Capture HEAD commit hash from a worker's worktree.
/// Returns null on any failure. Logs warnings for non-trivial failures
/// so operators can diagnose broken worktrees.
pub fn captureGitCommit(allocator: std.mem.Allocator, worktree_path: []const u8) ?[]u8 {
    if (worktree_path.len == 0) return null;
    const result = merge.runGitCapture(allocator, worktree_path, &.{ "rev-parse", "HEAD" }) catch |err| {
        std.log.warn("[teammux] history: git rev-parse HEAD failed for '{s}': {}", .{ worktree_path, err });
        return null;
    };
    defer result.deinit(allocator);
    if (result.exit_code != 0) {
        std.log.warn("[teammux] history: git rev-parse HEAD exited {d} for '{s}'", .{ result.exit_code, worktree_path });
        return null;
    }
    const trimmed = std.mem.trim(u8, result.stdout, &[_]u8{ '\n', '\r', ' ' });
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch |err| {
        std.log.warn("[teammux] history: dupe git commit failed: {}", .{err});
        return null;
    };
}

// ─────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────

test "history - append completion entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var logger = try HistoryLogger.init(std.testing.allocator, root);
    defer logger.deinit();

    try logger.append(.{
        .entry_type = .completion,
        .worker_id = 2,
        .role_id = "frontend-engineer",
        .content = "Implemented JWT auth",
        .git_commit = "abc1234",
        .timestamp = 1234567890,
    });

    const content = try std.fs.cwd().readFileAlloc(std.testing.allocator, logger.file_path, 1024 * 1024);
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"type\":\"completion\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"worker_id\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"role_id\":\"frontend-engineer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"content\":\"Implemented JWT auth\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"git_commit\":\"abc1234\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"timestamp\":1234567890") != null);
}

test "history - append question entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var logger = try HistoryLogger.init(std.testing.allocator, root);
    defer logger.deinit();

    try logger.append(.{
        .entry_type = .question,
        .worker_id = 3,
        .role_id = "backend-engineer",
        .content = "Should I use JWT?",
        .git_commit = null,
        .timestamp = 1234567891,
    });

    const content = try std.fs.cwd().readFileAlloc(std.testing.allocator, logger.file_path, 1024 * 1024);
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"type\":\"question\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"worker_id\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"content\":\"Should I use JWT?\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"git_commit\":null") != null);
}

test "history - load round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var logger = try HistoryLogger.init(std.testing.allocator, root);
    defer logger.deinit();

    try logger.append(.{ .entry_type = .completion, .worker_id = 1, .role_id = "fe", .content = "task one done", .git_commit = "aaa1111", .timestamp = 100 });
    try logger.append(.{ .entry_type = .question, .worker_id = 2, .role_id = "be", .content = "how to do X?", .git_commit = null, .timestamp = 200 });
    try logger.append(.{ .entry_type = .completion, .worker_id = 3, .role_id = "", .content = "task three done", .git_commit = "ccc3333", .timestamp = 300 });

    var entries = try logger.load();
    defer {
        for (entries.items) |e| e.deinit(std.testing.allocator);
        entries.deinit(std.testing.allocator);
    }

    try std.testing.expect(entries.items.len == 3);

    try std.testing.expect(entries.items[0].entry_type == .completion);
    try std.testing.expect(entries.items[0].worker_id == 1);
    try std.testing.expectEqualStrings("fe", entries.items[0].role_id);
    try std.testing.expectEqualStrings("task one done", entries.items[0].content);
    try std.testing.expectEqualStrings("aaa1111", entries.items[0].git_commit.?);
    try std.testing.expect(entries.items[0].timestamp == 100);

    try std.testing.expect(entries.items[1].entry_type == .question);
    try std.testing.expect(entries.items[1].worker_id == 2);
    try std.testing.expectEqualStrings("how to do X?", entries.items[1].content);
    try std.testing.expect(entries.items[1].git_commit == null);
    try std.testing.expect(entries.items[1].timestamp == 200);

    try std.testing.expect(entries.items[2].entry_type == .completion);
    try std.testing.expect(entries.items[2].worker_id == 3);
    try std.testing.expectEqualStrings("", entries.items[2].role_id);
    try std.testing.expect(entries.items[2].timestamp == 300);
}

test "history - round-trip with JSON-special characters" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var logger = try HistoryLogger.init(std.testing.allocator, root);
    defer logger.deinit();

    const special_content = "He said \"hello\" and\\or\nnewline\ttab";
    const special_role = "role-with-\"quotes\"";

    try logger.append(.{
        .entry_type = .completion,
        .worker_id = 1,
        .role_id = special_role,
        .content = special_content,
        .git_commit = "abc\"def",
        .timestamp = 100,
    });

    var entries = try logger.load();
    defer {
        for (entries.items) |e| e.deinit(std.testing.allocator);
        entries.deinit(std.testing.allocator);
    }

    try std.testing.expect(entries.items.len == 1);
    try std.testing.expectEqualStrings(special_content, entries.items[0].content);
    try std.testing.expectEqualStrings(special_role, entries.items[0].role_id);
    try std.testing.expectEqualStrings("abc\"def", entries.items[0].git_commit.?);
}

test "history - clear truncates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var logger = try HistoryLogger.init(std.testing.allocator, root);
    defer logger.deinit();

    try logger.append(.{ .entry_type = .completion, .worker_id = 1, .role_id = "", .content = "done", .git_commit = null, .timestamp = 100 });

    {
        const stat = try std.fs.cwd().statFile(logger.file_path);
        try std.testing.expect(stat.size > 0);
    }

    try logger.clear();

    {
        const stat = try std.fs.cwd().statFile(logger.file_path);
        try std.testing.expect(stat.size == 0);
    }

    var entries = try logger.load();
    defer entries.deinit(std.testing.allocator);
    try std.testing.expect(entries.items.len == 0);
}

test "history - append after clear produces correct single entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var logger = try HistoryLogger.init(std.testing.allocator, root);
    defer logger.deinit();

    try logger.append(.{ .entry_type = .completion, .worker_id = 1, .role_id = "", .content = "first", .git_commit = null, .timestamp = 100 });
    try logger.clear();
    try logger.append(.{ .entry_type = .question, .worker_id = 2, .role_id = "", .content = "second", .git_commit = null, .timestamp = 200 });

    var entries = try logger.load();
    defer {
        for (entries.items) |e| e.deinit(std.testing.allocator);
        entries.deinit(std.testing.allocator);
    }

    try std.testing.expect(entries.items.len == 1);
    try std.testing.expectEqualStrings("second", entries.items[0].content);
    try std.testing.expect(entries.items[0].entry_type == .question);
}

test "history - atomic write temp rename" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var logger = try HistoryLogger.init(std.testing.allocator, root);
    defer logger.deinit();

    try logger.append(.{ .entry_type = .completion, .worker_id = 1, .role_id = "", .content = "first", .git_commit = null, .timestamp = 100 });

    // Verify .tmp is NOT left behind after successful append
    _ = std.fs.cwd().statFile(logger.tmp_path) catch |err| {
        try std.testing.expect(err == error.FileNotFound);
        return;
    };
    return error.TmpFileLeftBehind;
}

test "history - missing file load returns empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var logger = try HistoryLogger.init(std.testing.allocator, root);
    defer logger.deinit();

    var entries = try logger.load();
    defer entries.deinit(std.testing.allocator);
    try std.testing.expect(entries.items.len == 0);
}

test "history - missing directory handled by init" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var logger = try HistoryLogger.init(std.testing.allocator, root);
    defer logger.deinit();

    const logs_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/.teammux/logs", .{root});
    defer std.testing.allocator.free(logs_dir);
    var dir = try std.fs.openDirAbsolute(logs_dir, .{});
    dir.close();
}

test "history - malformed line skipped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var logger = try HistoryLogger.init(std.testing.allocator, root);
    defer logger.deinit();

    const garbage_and_valid =
        \\this is not json
        \\{"type":"completion","worker_id":1,"role_id":"","content":"valid entry","git_commit":null,"timestamp":999}
        \\also garbage {{{{
        \\{"type":"question","worker_id":2,"role_id":"be","content":"valid question","git_commit":null,"timestamp":1000}
        \\
    ;
    const file = try std.fs.createFileAbsolute(logger.file_path, .{});
    try file.writeAll(garbage_and_valid);
    file.close();

    var entries = try logger.load();
    defer {
        for (entries.items) |e| e.deinit(std.testing.allocator);
        entries.deinit(std.testing.allocator);
    }

    try std.testing.expect(entries.items.len == 2);
    try std.testing.expectEqualStrings("valid entry", entries.items[0].content);
    try std.testing.expectEqualStrings("valid question", entries.items[1].content);
}

test "history - multiple sessions persist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    {
        var logger = try HistoryLogger.init(std.testing.allocator, root);
        defer logger.deinit();
        try logger.append(.{ .entry_type = .completion, .worker_id = 1, .role_id = "", .content = "session1-a", .git_commit = null, .timestamp = 100 });
        try logger.append(.{ .entry_type = .question, .worker_id = 2, .role_id = "", .content = "session1-b", .git_commit = null, .timestamp = 200 });
    }

    {
        var logger = try HistoryLogger.init(std.testing.allocator, root);
        defer logger.deinit();
        try logger.append(.{ .entry_type = .completion, .worker_id = 3, .role_id = "", .content = "session2-a", .git_commit = "def456", .timestamp = 300 });

        var entries = try logger.load();
        defer {
            for (entries.items) |e| e.deinit(std.testing.allocator);
            entries.deinit(std.testing.allocator);
        }
        try std.testing.expect(entries.items.len == 3);
        try std.testing.expectEqualStrings("session1-a", entries.items[0].content);
        try std.testing.expectEqualStrings("session1-b", entries.items[1].content);
        try std.testing.expectEqualStrings("session2-a", entries.items[2].content);
    }
}

test "history - clear on missing file is no-op" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var logger = try HistoryLogger.init(std.testing.allocator, root);
    defer logger.deinit();

    try logger.clear();
}

test "history - jsonEscape handles special characters" {
    const escaped = try jsonEscape(std.testing.allocator, "hello \"world\"\nnewline\\backslash");
    defer std.testing.allocator.free(escaped);
    try std.testing.expect(std.mem.indexOf(u8, escaped, "\\\"world\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, escaped, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, escaped, "\\\\") != null);
}

test "history - jsonUnescape reverses jsonEscape" {
    const original = "hello \"world\"\nnewline\\backslash\ttab";
    const escaped = try jsonEscape(std.testing.allocator, original);
    defer std.testing.allocator.free(escaped);
    const unescaped = try jsonUnescape(std.testing.allocator, escaped);
    defer std.testing.allocator.free(unescaped);
    try std.testing.expectEqualStrings(original, unescaped);
}

test "history - extractJsonUint64 parses large timestamp" {
    const ts = extractJsonUint64("{\"timestamp\": 1711800000000}", "timestamp");
    try std.testing.expect(ts != null);
    try std.testing.expect(ts.? == 1711800000000);
}

test "history - extractJsonUint64 returns null for missing key" {
    try std.testing.expect(extractJsonUint64("{\"other\": 123}", "timestamp") == null);
}

test "history - serializeEntry round-trip" {
    const entry = HistoryEntry{
        .entry_type = .completion,
        .worker_id = 5,
        .role_id = "test-role",
        .content = "task done",
        .git_commit = "abc123",
        .timestamp = 999,
    };
    const json = try serializeEntry(std.testing.allocator, entry);
    defer std.testing.allocator.free(json);

    const parsed = try parseEntry(std.testing.allocator, json);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expect(parsed.entry_type == .completion);
    try std.testing.expect(parsed.worker_id == 5);
    try std.testing.expectEqualStrings("test-role", parsed.role_id);
    try std.testing.expectEqualStrings("task done", parsed.content);
    try std.testing.expectEqualStrings("abc123", parsed.git_commit.?);
    try std.testing.expect(parsed.timestamp == 999);
}

test "history - invalid entry_type rejected on parse" {
    const bad_json =
        \\{"type":"banana","worker_id":1,"role_id":"","content":"x","git_commit":null,"timestamp":1}
    ;
    try std.testing.expectError(error.InvalidJson, parseEntry(std.testing.allocator, bad_json));
}
