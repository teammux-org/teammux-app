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

    // I7: Escape markdown heading markers in summary body to prevent the
    // Swift parser (which splits on "## " at line starts) from creating
    // fake entries. Prepend U+200B (zero-width space) before "## " at
    // each line start.
    const escaped = try escapeSummaryHeadings(allocator, summary);
    defer allocator.free(escaped);

    const entry = try std.fmt.allocPrint(allocator, "## {s}\n{s}\n\n", .{ ts_str, escaped });
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

/// I7: Escape markdown heading markers ("## ") at line starts in memory
/// summary bodies. Prepends U+200B (zero-width space, 3 bytes UTF-8)
/// before "## " at each line start so the Swift parser does not split
/// the summary into fake entries. Returns a new allocation (caller must
/// free). If no escaping is needed, returns a dupe of the original.
fn escapeSummaryHeadings(allocator: std.mem.Allocator, summary: []const u8) ![]u8 {
    if (summary.len == 0) return allocator.dupe(u8, summary);

    const zws = "\xe2\x80\x8b"; // U+200B zero-width space

    // Count lines starting with "## " to determine allocation size.
    var count: usize = 0;
    if (std.mem.startsWith(u8, summary, "## ")) count += 1;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, summary, pos, "\n## ")) |idx| {
        count += 1;
        pos = idx + 4;
    }

    if (count == 0) return allocator.dupe(u8, summary);

    var buf = try allocator.alloc(u8, summary.len + count * zws.len);
    var out: usize = 0;

    // Insert ZWS before first line if it starts with "## "
    if (std.mem.startsWith(u8, summary, "## ")) {
        @memcpy(buf[out..][0..zws.len], zws);
        out += zws.len;
    }

    for (summary, 0..) |c, i| {
        buf[out] = c;
        out += 1;
        // After a newline, check if next line starts with "## "
        if (c == '\n' and i + 3 < summary.len and std.mem.startsWith(u8, summary[i + 1 ..], "## ")) {
            @memcpy(buf[out..][0..zws.len], zws);
            out += zws.len;
        }
    }

    return buf[0..out];
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

test "memory - I7 escapeSummaryHeadings no-op on safe text" {
    const result = try escapeSummaryHeadings(std.testing.allocator, "safe summary\nno headings");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("safe summary\nno headings", result);
}

test "memory - I7 escapeSummaryHeadings escapes ## at first line" {
    const result = try escapeSummaryHeadings(std.testing.allocator, "## Heading\nbody text");
    defer std.testing.allocator.free(result);
    // First 3 bytes should be ZWS
    try std.testing.expect(result.len == "## Heading\nbody text".len + 3);
    try std.testing.expect(result[0] == 0xE2 and result[1] == 0x80 and result[2] == 0x8B);
    try std.testing.expect(std.mem.indexOf(u8, result, "## Heading") != null);
}

test "memory - I7 escapeSummaryHeadings escapes ## after newline" {
    const result = try escapeSummaryHeadings(std.testing.allocator, "line 1\n## Heading\nline 3");
    defer std.testing.allocator.free(result);
    // One ZWS inserted (3 bytes)
    try std.testing.expect(result.len == "line 1\n## Heading\nline 3".len + 3);
    // The "\n## " should now be "\n<ZWS>## "
    try std.testing.expect(std.mem.indexOf(u8, result, "\n\xe2\x80\x8b## Heading") != null);
}

test "memory - I7 escapeSummaryHeadings escapes multiple headings" {
    const input = "## First\nbody\n## Second\nmore";
    const result = try escapeSummaryHeadings(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    // Two ZWS insertions (6 bytes)
    try std.testing.expect(result.len == input.len + 6);
}

test "memory - I7 escapeSummaryHeadings empty input returns empty" {
    const result = try escapeSummaryHeadings(std.testing.allocator, "");
    defer std.testing.allocator.free(result);
    try std.testing.expect(result.len == 0);
}

test "memory - I7 append escapes ## in summary (end-to-end)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    // Summary containing a markdown heading that would corrupt the parser
    try append(std.testing.allocator, root, "Task done\n## Architecture\nRefactored modules", 1711000000);

    const content = try read(std.testing.allocator, root);
    defer if (content) |c| std.testing.allocator.free(c);

    try std.testing.expect(content != null);
    const text = content.?;

    // Should have exactly 1 entry delimiter "## " (the timestamp line).
    // The "## Architecture" in body should be escaped with ZWS.
    var real_delimiters: usize = 0;
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_pos, "\n## ")) |idx| {
        // Check this is NOT preceded by ZWS (which would mean it's an escaped body heading)
        if (idx >= 3 and text[idx - 3] == 0xE2 and text[idx - 2] == 0x80 and text[idx - 1] == 0x8B) {
            // Escaped — not a real delimiter
        } else {
            real_delimiters += 1;
        }
        search_pos = idx + 4;
    }
    // Only 1 real delimiter: the entry timestamp "## 2024-03-21T..."
    try std.testing.expect(real_delimiters == 1);

    // Body content preserved (with ZWS)
    try std.testing.expect(std.mem.indexOf(u8, text, "Architecture") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Refactored modules") != null);
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
