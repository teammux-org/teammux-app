const std = @import("std");

// ─────────────────────────────────────────────────────────
// Agent memory persistence (S13)
//
// Each worker's worktree contains a .teammux-memory.md file
// that accumulates context summaries across task completions.
// Swift constructs the summary string and calls tm_memory_append;
// the engine writes it as a timestamped markdown entry.
//
// File path: {worktree_path}/.teammux-memory.md
// Threading: concurrent access to different workers is safe (separate
// files). Callers must serialize access for the same worker_id.
// ─────────────────────────────────────────────────────────

/// Maximum memory file size for read operations (2 MB).
const max_memory_file_bytes: usize = 2 * 1024 * 1024;

/// File name within the worker's worktree.
pub const memory_filename = ".teammux-memory.md";

/// Append a memory entry to a worker's .teammux-memory.md file.
/// Creates the file with a header if it does not exist.
/// Each entry is a markdown section: `## {ISO 8601 timestamp}\n{summary}\n\n`.
pub fn append(
    allocator: std.mem.Allocator,
    worktree_path: []const u8,
    summary: []const u8,
    timestamp: u64,
) !void {
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ worktree_path, memory_filename });
    defer allocator.free(file_path);

    // Format timestamp as ISO 8601 (UTC)
    const ts_str = try formatTimestamp(allocator, timestamp);
    defer allocator.free(ts_str);

    const entry = try std.fmt.allocPrint(allocator, "## {s}\n{s}\n\n", .{ ts_str, summary });
    defer allocator.free(entry);

    // Open or create the file (no truncate). worktree_path is always absolute.
    const file = std.fs.createFileAbsolute(file_path, .{
        .truncate = false,
    }) catch |err| {
        std.log.warn("[teammux] memory: failed to open {s}: {}", .{ file_path, err });
        return err;
    };
    defer file.close();

    // Check size on the opened handle (avoids TOCTOU race vs separate stat)
    const stat = try file.stat();
    if (stat.size == 0) {
        try file.writeAll("# Agent Memory\n\n");
    }

    try file.seekFromEnd(0);
    try file.writeAll(entry);
}

/// Read the full content of a worker's .teammux-memory.md file.
/// Returns null if the file does not exist.
/// Caller owns the returned slice and must free it.
pub fn read(allocator: std.mem.Allocator, worktree_path: []const u8) !?[]u8 {
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ worktree_path, memory_filename });
    defer allocator.free(file_path);

    return std.fs.cwd().readFileAlloc(allocator, file_path, max_memory_file_bytes) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
}

/// Format a UNIX timestamp as ISO 8601 UTC string (e.g. "2026-03-20T14:30:00Z").
fn formatTimestamp(allocator: std.mem.Allocator, timestamp: u64) ![]u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = timestamp };
    const day = epoch.getDaySeconds();
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    });
}

// ─────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────

test "memory - append creates file with header and entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    try append(std.testing.allocator, root, "Implemented JWT auth\nFiles: src/auth.zig", 1711000000);

    const content = try read(std.testing.allocator, root);
    defer if (content) |c| std.testing.allocator.free(c);

    try std.testing.expect(content != null);
    const text = content.?;
    try std.testing.expect(std.mem.indexOf(u8, text, "# Agent Memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "## 2024-03-21T05:46:40Z") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Implemented JWT auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Files: src/auth.zig") != null);
}

test "memory - append multiple entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    try append(std.testing.allocator, root, "First task done", 1711000000);
    try append(std.testing.allocator, root, "Second task done", 1711003600);

    const content = try read(std.testing.allocator, root);
    defer if (content) |c| std.testing.allocator.free(c);

    try std.testing.expect(content != null);
    const text = content.?;

    // Should have header + 2 entries
    try std.testing.expect(std.mem.indexOf(u8, text, "# Agent Memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "First task done") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Second task done") != null);

    // Count ## headings (should be 2 entry headers)
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, "## ")) |idx| {
        count += 1;
        pos = idx + 3;
    }
    try std.testing.expect(count == 2);
}

test "memory - read returns null for missing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const content = try read(std.testing.allocator, root);
    try std.testing.expect(content == null);
}

test "memory - formatTimestamp produces ISO 8601" {
    // 1711000000 = 2024-03-21T05:46:40Z
    const ts = try formatTimestamp(std.testing.allocator, 1711000000);
    defer std.testing.allocator.free(ts);
    try std.testing.expectEqualStrings("2024-03-21T05:46:40Z", ts);
}

test "memory - formatTimestamp epoch zero" {
    const ts = try formatTimestamp(std.testing.allocator, 0);
    defer std.testing.allocator.free(ts);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", ts);
}

test "memory - append with special characters in summary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    try append(std.testing.allocator, root, "Fixed \"escape\" handling\nFiles: src/parser.zig\nPR: #42", 1711000000);

    const content = try read(std.testing.allocator, root);
    defer if (content) |c| std.testing.allocator.free(c);

    try std.testing.expect(content != null);
    try std.testing.expect(std.mem.indexOf(u8, content.?, "Fixed \"escape\" handling") != null);
    try std.testing.expect(std.mem.indexOf(u8, content.?, "PR: #42") != null);
}

test "memory - append persists across re-reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    try append(std.testing.allocator, root, "Session 1 task", 1711000000);

    // Simulate session restart: read, then append more
    {
        const content = try read(std.testing.allocator, root);
        defer if (content) |c| std.testing.allocator.free(c);
        try std.testing.expect(content != null);
        try std.testing.expect(std.mem.indexOf(u8, content.?, "Session 1 task") != null);
    }

    try append(std.testing.allocator, root, "Session 2 task", 1711086400);

    {
        const content = try read(std.testing.allocator, root);
        defer if (content) |c| std.testing.allocator.free(c);
        try std.testing.expect(content != null);
        try std.testing.expect(std.mem.indexOf(u8, content.?, "Session 1 task") != null);
        try std.testing.expect(std.mem.indexOf(u8, content.?, "Session 2 task") != null);
    }
}

test "memory - empty summary produces valid entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    try append(std.testing.allocator, root, "", 1711000000);

    const content = try read(std.testing.allocator, root);
    defer if (content) |c| std.testing.allocator.free(c);

    try std.testing.expect(content != null);
    try std.testing.expect(std.mem.indexOf(u8, content.?, "# Agent Memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, content.?, "## 2024-03-21T") != null);
}
