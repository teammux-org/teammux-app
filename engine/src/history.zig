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

/// Async write queue capacity (I15).
const queue_capacity: usize = 256;

/// Owned copy of a HistoryEntry for the async write queue (I15).
/// All string fields are heap-allocated. Free with deinit().
pub const QueueEntry = struct {
    entry_type: EventKind,
    worker_id: u32,
    role_id: []const u8,
    content: []const u8,
    git_commit: ?[]const u8,
    timestamp: u64,

    pub fn deinit(self: QueueEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.role_id);
        alloc.free(self.content);
        if (self.git_commit) |gc| alloc.free(gc);
    }
};

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
    max_size_bytes: usize,

    // Async write queue (I15) — entries enqueued by callers, drained to disk by background thread.
    queue_entries: [queue_capacity]?QueueEntry = [_]?QueueEntry{null} ** queue_capacity,
    queue_head: usize = 0,
    queue_tail: usize = 0,
    queue_count: usize = 0,
    queue_mutex: std.Thread.Mutex = .{},
    queue_writing: bool = false,
    queue_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    queue_dropped: usize = 0,
    writer_thread: ?std.Thread = null,

    /// Default max file size before rotation: 1 MiB.
    pub const default_max_size_bytes: usize = 1024 * 1024;

    pub fn init(allocator: std.mem.Allocator, project_root: []const u8) !HistoryLogger {
        return initWithConfig(allocator, project_root, default_max_size_bytes);
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, project_root: []const u8, max_size: usize) !HistoryLogger {
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/.teammux/logs", .{project_root});
        errdefer allocator.free(dir_path);

        const file_path = try std.fmt.allocPrint(allocator, "{s}/completion_history.jsonl", .{dir_path});
        errdefer allocator.free(file_path);

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
            .max_size_bytes = max_size,
        };
    }

    pub fn deinit(self: *HistoryLogger) void {
        self.shutdown();
        self.allocator.free(self.file_path);
        self.allocator.free(self.dir_path);
        self.* = undefined;
    }

    /// Append a history entry (I15).
    /// If the async writer is running (startWriter was called), enqueues non-blocking.
    /// Otherwise, writes synchronously via direct file append.
    pub fn append(self: *HistoryLogger, entry: HistoryEntry) !void {
        if (self.writer_thread != null) {
            try self.enqueue(entry);
        } else {
            try self.writeToDisk(entry);
            self.maybeRotate();
        }
    }

    /// Start the background writer thread (I15).
    /// After this call, append() enqueues non-blocking instead of writing synchronously.
    /// Call stopWriter() or shutdown() to drain and stop.
    pub fn startWriter(self: *HistoryLogger) !void {
        if (self.writer_thread != null) return;
        self.queue_stop.store(false, .release);
        self.writer_thread = try std.Thread.spawn(.{}, writerLoop, .{self});
    }

    /// Enqueue an entry to the async write queue. Owned copies of strings are made.
    /// On queue overflow, the oldest entry is dropped.
    fn enqueue(self: *HistoryLogger, entry: HistoryEntry) !void {
        const role_id = try self.allocator.dupe(u8, entry.role_id);
        errdefer self.allocator.free(role_id);
        const content = try self.allocator.dupe(u8, entry.content);
        errdefer self.allocator.free(content);
        const git_commit = if (entry.git_commit) |gc| try self.allocator.dupe(u8, gc) else null;
        errdefer if (git_commit) |gc| self.allocator.free(gc);

        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        if (self.queue_count == queue_capacity) {
            if (self.queue_entries[self.queue_tail]) |oldest| {
                oldest.deinit(self.allocator);
            }
            self.queue_entries[self.queue_tail] = null;
            self.queue_tail = (self.queue_tail + 1) % queue_capacity;
            self.queue_count -= 1;
            self.queue_dropped += 1;
            std.log.warn("[teammux] history: write queue full, dropped oldest entry (total dropped: {d})", .{self.queue_dropped});
        }

        self.queue_entries[self.queue_head] = .{
            .entry_type = entry.entry_type,
            .worker_id = entry.worker_id,
            .role_id = role_id,
            .content = content,
            .git_commit = git_commit,
            .timestamp = entry.timestamp,
        };
        self.queue_head = (self.queue_head + 1) % queue_capacity;
        self.queue_count += 1;
    }

    /// Write a single entry to disk via direct append.
    pub fn writeToDisk(self: *HistoryLogger, entry: HistoryEntry) !void {
        const json_line = try serializeEntry(self.allocator, entry);
        defer self.allocator.free(json_line);

        const file = try std.fs.createFileAbsolute(self.file_path, .{ .truncate = false });
        defer file.close();
        const end_pos = try file.getEndPos();
        try file.seekTo(end_pos);
        try file.writeAll(json_line);
        try file.writeAll("\n");
    }

    /// Check file size and rotate if over limit. Errors are logged, not propagated.
    fn maybeRotate(self: *HistoryLogger) void {
        const stat = std.fs.cwd().statFile(self.file_path) catch return;
        if (stat.size > self.max_size_bytes) {
            self.rotate() catch |err| {
                std.log.warn("[teammux] history: rotation failed: {}", .{err});
            };
        }
    }

    /// Rotate the history file: .jsonl → .1, .1 → .2, discard old .2.
    /// Flushes the async queue first. Missing files are silently skipped.
    /// Keeps at most 2 archive files.
    pub fn rotate(self: *HistoryLogger) !void {
        if (self.writer_thread != null) self.flush();
        var dir = try std.fs.openDirAbsolute(self.dir_path, .{});
        defer dir.close();

        // Delete .2 if exists (discard oldest archive)
        dir.deleteFile("completion_history.jsonl.2") catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        // Rename .1 → .2
        dir.rename("completion_history.jsonl.1", "completion_history.jsonl.2") catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        // Rename .jsonl → .1
        dir.rename("completion_history.jsonl", "completion_history.jsonl.1") catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    /// Block until all enqueued entries are written to disk and no write is in progress.
    pub fn flush(self: *HistoryLogger) void {
        while (true) {
            self.queue_mutex.lock();
            const done = self.queue_count == 0 and !self.queue_writing;
            self.queue_mutex.unlock();
            if (done) return;
            std.Thread.sleep(100_000); // 100µs poll
        }
    }

    /// Stop the background writer: drain remaining entries, join thread.
    /// Idempotent — safe to call multiple times or if writer was never started.
    pub fn shutdown(self: *HistoryLogger) void {
        if (self.writer_thread == null) return;
        self.queue_stop.store(true, .release);
        if (self.writer_thread) |t| {
            t.join();
            self.writer_thread = null;
        }
        // Free any residual entries (shouldn't happen — writer drains before exit)
        for (&self.queue_entries) |*slot| {
            if (slot.*) |e| {
                e.deinit(self.allocator);
                slot.* = null;
            }
        }
    }

    /// Background writer thread: drains the queue to disk, one entry at a time.
    /// Continues processing until queue is empty AND stop flag is set.
    fn writerLoop(self: *HistoryLogger) void {
        while (true) {
            var entry: ?QueueEntry = null;

            self.queue_mutex.lock();
            if (self.queue_count == 0) {
                self.queue_writing = false;
                self.queue_mutex.unlock();
                if (self.queue_stop.load(.acquire)) return;
                std.Thread.sleep(500_000); // 500µs idle poll
                continue;
            }

            // Dequeue one entry
            entry = self.queue_entries[self.queue_tail];
            self.queue_entries[self.queue_tail] = null;
            self.queue_tail = (self.queue_tail + 1) % queue_capacity;
            self.queue_count -= 1;
            self.queue_writing = true;
            self.queue_mutex.unlock();

            if (entry) |e| {
                // Write to disk (no lock held — file I/O is slow)
                self.writeToDisk(.{
                    .entry_type = e.entry_type,
                    .worker_id = e.worker_id,
                    .role_id = e.role_id,
                    .content = e.content,
                    .git_commit = e.git_commit,
                    .timestamp = e.timestamp,
                }) catch |err| {
                    std.log.err("[teammux] history: async write failed: {}", .{err});
                };
                self.maybeRotate();

                // Free owned strings
                e.deinit(self.allocator);

                // Mark write complete
                self.queue_mutex.lock();
                self.queue_writing = false;
                self.queue_mutex.unlock();
            }
        }
    }

    /// Load all history entries from the JSONL file.
    /// If the async writer is running, flushes the queue first.
    /// Malformed lines are skipped with a warning. Missing file returns empty list.
    /// OutOfMemory is propagated (not masked as "malformed").
    pub fn load(self: *HistoryLogger) !std.ArrayList(OwnedHistoryEntry) {
        if (self.writer_thread != null) self.flush();
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
    /// Flushes the async queue first to avoid writing stale entries after truncation.
    /// Missing file is a no-op.
    pub fn clear(self: *HistoryLogger) !void {
        if (self.writer_thread != null) self.flush();
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

test "history - rotation creates archive on size exceeded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    // Use small max_size (64 bytes) to trigger rotation quickly
    var logger = try HistoryLogger.initWithConfig(std.testing.allocator, root, 64);
    defer logger.deinit();

    // First append — file size likely exceeds 64 bytes, triggers rotation
    try logger.append(.{ .entry_type = .completion, .worker_id = 1, .role_id = "role", .content = "entry content exceeding the small size limit", .git_commit = null, .timestamp = 100 });

    // After rotation: .jsonl was renamed to .1, new .jsonl doesn't exist yet (or is empty)
    const archive1_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/completion_history.jsonl.1", .{logger.dir_path});
    defer std.testing.allocator.free(archive1_path);
    const stat1 = try std.fs.cwd().statFile(archive1_path);
    try std.testing.expect(stat1.size > 0);

    // Second append creates new .jsonl
    try logger.append(.{ .entry_type = .completion, .worker_id = 2, .role_id = "", .content = "second entry also exceeding limit", .git_commit = null, .timestamp = 200 });

    // After second rotation: old .1 moved to .2, new content in .1
    const archive2_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/completion_history.jsonl.2", .{logger.dir_path});
    defer std.testing.allocator.free(archive2_path);
    const stat2 = try std.fs.cwd().statFile(archive2_path);
    try std.testing.expect(stat2.size > 0);
}

test "history - rotation keeps at most 2 archives" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var logger = try HistoryLogger.initWithConfig(std.testing.allocator, root, 64);
    defer logger.deinit();

    // Trigger multiple rotations (each entry exceeds 64 bytes)
    for (0..5) |i| {
        try logger.append(.{ .entry_type = .completion, .worker_id = 1, .role_id = "", .content = "entry content long enough to exceed sixty-four bytes limit", .git_commit = null, .timestamp = 100 + @as(u64, @intCast(i)) });
    }

    // .1 and .2 should exist
    const archive1_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/completion_history.jsonl.1", .{logger.dir_path});
    defer std.testing.allocator.free(archive1_path);
    _ = try std.fs.cwd().statFile(archive1_path);

    const archive2_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/completion_history.jsonl.2", .{logger.dir_path});
    defer std.testing.allocator.free(archive2_path);
    _ = try std.fs.cwd().statFile(archive2_path);

    // .3 should NOT exist
    const archive3_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/completion_history.jsonl.3", .{logger.dir_path});
    defer std.testing.allocator.free(archive3_path);
    _ = std.fs.cwd().statFile(archive3_path) catch |err| {
        try std.testing.expect(err == error.FileNotFound);
        return;
    };
    return error.Archive3ShouldNotExist;
}

test "history - rotate on missing file is no-op" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var logger = try HistoryLogger.init(std.testing.allocator, root);
    defer logger.deinit();

    // Rotate with no file should not error
    try logger.rotate();
}

test "history - load after rotation returns only current file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    // Use large max_size so auto-rotation doesn't trigger
    var logger = try HistoryLogger.init(std.testing.allocator, root);
    defer logger.deinit();

    // Append first entry
    try logger.append(.{ .entry_type = .completion, .worker_id = 1, .role_id = "", .content = "old entry", .git_commit = null, .timestamp = 100 });

    // Manually rotate — moves .jsonl to .1
    try logger.rotate();

    // Append second entry — goes to fresh .jsonl
    try logger.append(.{ .entry_type = .question, .worker_id = 2, .role_id = "", .content = "new entry", .git_commit = null, .timestamp = 200 });

    // Load should only return entries from current .jsonl, not archives
    var entries = try logger.load();
    defer {
        for (entries.items) |e| e.deinit(std.testing.allocator);
        entries.deinit(std.testing.allocator);
    }

    try std.testing.expect(entries.items.len == 1);
    try std.testing.expect(entries.items[0].worker_id == 2);
}

test "history - manual rotate triggers correctly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    // Use large max_size so automatic rotation won't trigger
    var logger = try HistoryLogger.init(std.testing.allocator, root);
    defer logger.deinit();

    try logger.append(.{ .entry_type = .completion, .worker_id = 1, .role_id = "", .content = "entry before manual rotate", .git_commit = null, .timestamp = 100 });

    // Manually trigger rotation
    try logger.rotate();

    // Archive .1 should exist with the entry
    const archive1_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/completion_history.jsonl.1", .{logger.dir_path});
    defer std.testing.allocator.free(archive1_path);
    const stat1 = try std.fs.cwd().statFile(archive1_path);
    try std.testing.expect(stat1.size > 0);

    // Load should return empty (current file was rotated away)
    var entries = try logger.load();
    defer entries.deinit(std.testing.allocator);
    try std.testing.expect(entries.items.len == 0);
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

test "history - async queue drain on shutdown" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    {
        var logger = try HistoryLogger.init(std.testing.allocator, root);
        try logger.startWriter();
        for (0..10) |i| {
            try logger.append(.{ .entry_type = .completion, .worker_id = @intCast(i), .role_id = "", .content = "async entry", .git_commit = null, .timestamp = 100 + @as(u64, @intCast(i)) });
        }
        // deinit calls shutdown which drains the queue
        logger.deinit();
    }

    // Reopen and verify all entries were written
    {
        var logger = try HistoryLogger.init(std.testing.allocator, root);
        defer logger.deinit();
        var entries = try logger.load();
        defer {
            for (entries.items) |e| e.deinit(std.testing.allocator);
            entries.deinit(std.testing.allocator);
        }
        try std.testing.expect(entries.items.len == 10);
    }
}

test "history - async flush drains queue before load" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var logger = try HistoryLogger.init(std.testing.allocator, root);
    defer logger.deinit();

    try logger.startWriter();
    try logger.append(.{ .entry_type = .completion, .worker_id = 1, .role_id = "", .content = "async test", .git_commit = null, .timestamp = 100 });

    // load() auto-flushes when writer is running
    var entries = try logger.load();
    defer {
        for (entries.items) |e| e.deinit(std.testing.allocator);
        entries.deinit(std.testing.allocator);
    }
    try std.testing.expect(entries.items.len == 1);
    try std.testing.expectEqualStrings("async test", entries.items[0].content);
}
