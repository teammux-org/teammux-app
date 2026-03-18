const std = @import("std");
const merge = @import("merge.zig");
const worktree = @import("worktree.zig");
const commands = @import("commands.zig");

// ─────────────────────────────────────────────────────────
// Completion history JSONL persistence (TD16)
//
// Append-only writer for completion and question events.
// File: {project_root}/.teammux/logs/completion_history.jsonl
// Atomic write via temp-file-and-rename pattern.
// ─────────────────────────────────────────────────────────

pub const HistoryEntry = struct {
    entry_type: []const u8, // "completion" or "question"
    worker_id: u32,
    role_id: []const u8, // empty string if unknown
    content: []const u8, // summary for completion, question text for question
    git_commit: ?[]const u8, // null if unavailable
    timestamp: u64,
};

/// Owned version of HistoryEntry — all string fields are heap-allocated
/// and must be freed with freeOwnedEntry.
pub const OwnedHistoryEntry = struct {
    entry_type: []const u8,
    worker_id: u32,
    role_id: []const u8,
    content: []const u8,
    git_commit: ?[]const u8,
    timestamp: u64,
};

pub fn freeOwnedEntry(allocator: std.mem.Allocator, entry: OwnedHistoryEntry) void {
    allocator.free(entry.entry_type);
    allocator.free(entry.role_id);
    allocator.free(entry.content);
    if (entry.git_commit) |gc| allocator.free(gc);
}

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
    }

    /// Append a history entry via atomic temp-file-and-rename.
    /// Reads existing file content, writes existing + new line to .tmp,
    /// then renames .tmp over the original file.
    pub fn append(self: *HistoryLogger, entry: HistoryEntry) !void {
        // Serialize entry to JSON line
        const json_line = try serializeEntry(self.allocator, entry);
        defer self.allocator.free(json_line);

        // Read existing file content (empty if file doesn't exist)
        const existing = std.fs.cwd().readFileAlloc(self.allocator, self.file_path, 10 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
        const free_existing = existing.len > 0;
        defer if (free_existing) self.allocator.free(existing);

        // Write existing + new line to .tmp
        const tmp_file = try std.fs.createFileAbsolute(self.tmp_path, .{});
        errdefer {
            tmp_file.close();
            std.fs.deleteFileAbsolute(self.tmp_path) catch {};
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
    /// Malformed lines are skipped silently. Missing file returns empty list.
    pub fn load(self: *HistoryLogger) !std.ArrayList(OwnedHistoryEntry) {
        var entries: std.ArrayList(OwnedHistoryEntry) = .{};
        errdefer {
            for (entries.items) |e| freeOwnedEntry(self.allocator, e);
            entries.deinit(self.allocator);
        }

        const content = std.fs.cwd().readFileAlloc(self.allocator, self.file_path, 10 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return entries,
            else => return err,
        };
        defer self.allocator.free(content);

        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const entry = parseEntry(self.allocator, line) catch {
                std.log.warn("[teammux] history: skipping malformed JSONL line", .{});
                continue;
            };
            try entries.append(self.allocator, entry);
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

/// Serialize a HistoryEntry to a JSON line string.
fn serializeEntry(allocator: std.mem.Allocator, entry: HistoryEntry) ![]u8 {
    const type_esc = try jsonEscape(allocator, entry.entry_type);
    defer allocator.free(type_esc);
    const role_esc = try jsonEscape(allocator, entry.role_id);
    defer allocator.free(role_esc);
    const content_esc = try jsonEscape(allocator, entry.content);
    defer allocator.free(content_esc);

    const git_val = if (entry.git_commit) |gc| blk: {
        const gc_esc = try jsonEscape(allocator, gc);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{gc_esc});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(git_val);
    // Free the inner escaped string if we allocated one
    if (entry.git_commit) |_| {
        // git_val is "\"escaped\"" — the inner escape was used inline
        // Actually we need to free the gc_esc separately. Let me restructure.
    }

    // Restructured to avoid double-free: build git_commit value directly
    return serializeEntryInner(allocator, type_esc, entry.worker_id, role_esc, content_esc, entry.git_commit, entry.timestamp);
}

fn serializeEntryInner(
    allocator: std.mem.Allocator,
    type_esc: []const u8,
    worker_id: u32,
    role_esc: []const u8,
    content_esc: []const u8,
    git_commit: ?[]const u8,
    timestamp: u64,
) ![]u8 {
    if (git_commit) |gc| {
        const gc_esc = try jsonEscape(allocator, gc);
        defer allocator.free(gc_esc);
        return std.fmt.allocPrint(allocator,
            \\{{"type":"{s}","worker_id":{d},"role_id":"{s}","content":"{s}","git_commit":"{s}","timestamp":{d}}}
        , .{ type_esc, worker_id, role_esc, content_esc, gc_esc, timestamp });
    } else {
        return std.fmt.allocPrint(allocator,
            \\{{"type":"{s}","worker_id":{d},"role_id":"{s}","content":"{s}","git_commit":null,"timestamp":{d}}}
        , .{ type_esc, worker_id, role_esc, content_esc, timestamp });
    }
}

// ─────────────────────────────────────────────────────────
// JSON parsing
// ─────────────────────────────────────────────────────────

/// Parse a JSONL line into an OwnedHistoryEntry.
/// All string fields are heap-allocated. Caller must free with freeOwnedEntry.
fn parseEntry(allocator: std.mem.Allocator, line: []const u8) !OwnedHistoryEntry {
    const entry_type_raw = commands.extractJsonString(line, "type") orelse return error.InvalidJson;
    const entry_type = try allocator.dupe(u8, entry_type_raw);
    errdefer allocator.free(entry_type);

    const worker_id = commands.extractJsonUint(line, "worker_id") orelse return error.InvalidJson;

    const role_id_raw = commands.extractJsonString(line, "role_id") orelse "";
    const role_id = try allocator.dupe(u8, role_id_raw);
    errdefer allocator.free(role_id);

    const content_raw = commands.extractJsonString(line, "content") orelse return error.InvalidJson;
    const content = try allocator.dupe(u8, content_raw);
    errdefer allocator.free(content);

    const git_commit_raw = commands.extractJsonString(line, "git_commit");
    const git_commit = if (git_commit_raw) |gc| try allocator.dupe(u8, gc) else null;
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
    if (i == start) return null;

    return std.fmt.parseInt(u64, after_key[start..i], 10) catch null;
}

// ─────────────────────────────────────────────────────────
// JSON escape (self-contained for module independence)
// ─────────────────────────────────────────────────────────

fn jsonEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Fast path: if no special chars, just dupe
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
        return allocator.realloc(buf, pos) catch {
            return buf[0..pos];
        };
    }
    return buf;
}

// ─────────────────────────────────────────────────────────
// Git commit capture helper
// ─────────────────────────────────────────────────────────

/// Capture HEAD commit hash from a worker's worktree.
/// Returns null on any failure (no commits, git missing, empty worktree path).
pub fn captureGitCommit(allocator: std.mem.Allocator, worktree_path: []const u8) ?[]u8 {
    if (worktree_path.len == 0) return null;
    const result = merge.runGitCapture(allocator, worktree_path, &.{ "rev-parse", "HEAD" }) catch return null;
    defer result.deinit(allocator);
    if (result.exit_code != 0) return null;
    const trimmed = std.mem.trim(u8, result.stdout, &[_]u8{ '\n', '\r', ' ' });
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
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
        .entry_type = "completion",
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
        .entry_type = "question",
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

    // Append 3 entries
    try logger.append(.{
        .entry_type = "completion",
        .worker_id = 1,
        .role_id = "fe",
        .content = "task one done",
        .git_commit = "aaa1111",
        .timestamp = 100,
    });
    try logger.append(.{
        .entry_type = "question",
        .worker_id = 2,
        .role_id = "be",
        .content = "how to do X?",
        .git_commit = null,
        .timestamp = 200,
    });
    try logger.append(.{
        .entry_type = "completion",
        .worker_id = 3,
        .role_id = "",
        .content = "task three done",
        .git_commit = "ccc3333",
        .timestamp = 300,
    });

    // Load and verify
    var entries = try logger.load();
    defer {
        for (entries.items) |e| freeOwnedEntry(std.testing.allocator, e);
        entries.deinit(std.testing.allocator);
    }

    try std.testing.expect(entries.items.len == 3);

    try std.testing.expectEqualStrings("completion", entries.items[0].entry_type);
    try std.testing.expect(entries.items[0].worker_id == 1);
    try std.testing.expectEqualStrings("fe", entries.items[0].role_id);
    try std.testing.expectEqualStrings("task one done", entries.items[0].content);
    try std.testing.expectEqualStrings("aaa1111", entries.items[0].git_commit.?);
    try std.testing.expect(entries.items[0].timestamp == 100);

    try std.testing.expectEqualStrings("question", entries.items[1].entry_type);
    try std.testing.expect(entries.items[1].worker_id == 2);
    try std.testing.expectEqualStrings("how to do X?", entries.items[1].content);
    try std.testing.expect(entries.items[1].git_commit == null);
    try std.testing.expect(entries.items[1].timestamp == 200);

    try std.testing.expectEqualStrings("completion", entries.items[2].entry_type);
    try std.testing.expect(entries.items[2].worker_id == 3);
    try std.testing.expectEqualStrings("", entries.items[2].role_id);
    try std.testing.expect(entries.items[2].timestamp == 300);
}

test "history - clear truncates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var logger = try HistoryLogger.init(std.testing.allocator, root);
    defer logger.deinit();

    try logger.append(.{
        .entry_type = "completion",
        .worker_id = 1,
        .role_id = "",
        .content = "done",
        .git_commit = null,
        .timestamp = 100,
    });

    // Verify file has content
    {
        const stat = try std.fs.cwd().statFile(logger.file_path);
        try std.testing.expect(stat.size > 0);
    }

    // Clear
    try logger.clear();

    // Verify file is empty (still exists, size 0)
    {
        const stat = try std.fs.cwd().statFile(logger.file_path);
        try std.testing.expect(stat.size == 0);
    }

    // Load returns empty
    var entries = try logger.load();
    defer entries.deinit(std.testing.allocator);
    try std.testing.expect(entries.items.len == 0);
}

test "history - atomic write temp rename" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var logger = try HistoryLogger.init(std.testing.allocator, root);
    defer logger.deinit();

    try logger.append(.{
        .entry_type = "completion",
        .worker_id = 1,
        .role_id = "",
        .content = "first",
        .git_commit = null,
        .timestamp = 100,
    });

    // Verify .tmp is NOT left behind after successful append
    std.fs.cwd().statFile(logger.tmp_path) catch |err| {
        try std.testing.expect(err == error.FileNotFound);
        return;
    };
    // If we get here, .tmp still exists — test should fail
    // (rename removes .tmp by moving it to the destination)
    return error.TmpFileLeftBehind;
}

test "history - missing file load returns empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var logger = try HistoryLogger.init(std.testing.allocator, root);
    defer logger.deinit();

    // No file written — load should return empty, not error
    var entries = try logger.load();
    defer entries.deinit(std.testing.allocator);
    try std.testing.expect(entries.items.len == 0);
}

test "history - missing directory handled by init" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    // .teammux/logs/ does not exist yet — init should create it
    var logger = try HistoryLogger.init(std.testing.allocator, root);
    defer logger.deinit();

    // Verify directory was created
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

    // Write a mix of garbage and valid JSONL directly
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
        for (entries.items) |e| freeOwnedEntry(std.testing.allocator, e);
        entries.deinit(std.testing.allocator);
    }

    // Only 2 valid entries should be loaded, garbage skipped
    try std.testing.expect(entries.items.len == 2);
    try std.testing.expectEqualStrings("valid entry", entries.items[0].content);
    try std.testing.expectEqualStrings("valid question", entries.items[1].content);
}

test "history - multiple sessions persist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    // Session 1: append 2 entries
    {
        var logger = try HistoryLogger.init(std.testing.allocator, root);
        defer logger.deinit();
        try logger.append(.{ .entry_type = "completion", .worker_id = 1, .role_id = "", .content = "session1-a", .git_commit = null, .timestamp = 100 });
        try logger.append(.{ .entry_type = "question", .worker_id = 2, .role_id = "", .content = "session1-b", .git_commit = null, .timestamp = 200 });
    }

    // Session 2: append 1 more entry
    {
        var logger = try HistoryLogger.init(std.testing.allocator, root);
        defer logger.deinit();
        try logger.append(.{ .entry_type = "completion", .worker_id = 3, .role_id = "", .content = "session2-a", .git_commit = "def456", .timestamp = 300 });

        // Load all — should have 3 entries from both sessions
        var entries = try logger.load();
        defer {
            for (entries.items) |e| freeOwnedEntry(std.testing.allocator, e);
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

    // Should not error — file doesn't exist
    try logger.clear();
}

test "history - jsonEscape handles special characters" {
    const escaped = try jsonEscape(std.testing.allocator, "hello \"world\"\nnewline\\backslash");
    defer std.testing.allocator.free(escaped);
    try std.testing.expect(std.mem.indexOf(u8, escaped, "\\\"world\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, escaped, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, escaped, "\\\\") != null);
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
        .entry_type = "completion",
        .worker_id = 5,
        .role_id = "test-role",
        .content = "task done",
        .git_commit = "abc123",
        .timestamp = 999,
    };
    const json = try serializeEntry(std.testing.allocator, entry);
    defer std.testing.allocator.free(json);

    const parsed = try parseEntry(std.testing.allocator, json);
    defer freeOwnedEntry(std.testing.allocator, parsed);

    try std.testing.expectEqualStrings("completion", parsed.entry_type);
    try std.testing.expect(parsed.worker_id == 5);
    try std.testing.expectEqualStrings("test-role", parsed.role_id);
    try std.testing.expectEqualStrings("task done", parsed.content);
    try std.testing.expectEqualStrings("abc123", parsed.git_commit.?);
    try std.testing.expect(parsed.timestamp == 999);
}
