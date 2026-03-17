const std = @import("std");
const worktree = @import("worktree.zig");

pub const WorkerId = worktree.WorkerId;

// ─────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────

const wrapper_dir_name = ".git-wrapper";
const wrapper_file_name = "git";

// ─────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────

/// Write a git wrapper script into {worktree_path}/.git-wrapper/git that
/// intercepts `git add` and blocks denied file patterns. When deny_patterns
/// is empty, writes a minimal pass-through wrapper (zero overhead).
///
/// The wrapper embeds deny patterns as a bash array and the write scope
/// for actionable error messages. The real git binary path is resolved
/// at install time and embedded as an absolute path.
pub fn install(
    allocator: std.mem.Allocator,
    worktree_path: []const u8,
    worker_id: WorkerId,
    role_name: []const u8,
    deny_patterns: []const []const u8,
    write_patterns: []const []const u8,
) !void {
    // Resolve real git binary
    const real_git = try resolveGitBinary(allocator);
    defer allocator.free(real_git);

    // Create .git-wrapper directory
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ worktree_path, wrapper_dir_name });
    defer allocator.free(dir_path);
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Generate wrapper script content
    const script = if (deny_patterns.len == 0)
        try generatePassthroughScript(allocator, real_git)
    else
        try generateInterceptorScript(allocator, real_git, worker_id, role_name, deny_patterns, write_patterns);
    defer allocator.free(script);

    // Write wrapper script
    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, wrapper_file_name });
    defer allocator.free(file_path);
    const file = try std.fs.createFileAbsolute(file_path, .{});
    defer file.close();
    try file.writeAll(script);

    // chmod +x (owner rwx, group rx, other rx = 0o755)
    const file_for_chmod = try std.fs.openFileAbsolute(file_path, .{ .mode = .read_write });
    defer file_for_chmod.close();
    try file_for_chmod.chmod(0o755);
}

/// Remove the .git-wrapper directory from a worktree. Idempotent —
/// safe to call even if no interceptor was installed.
pub fn remove(worktree_path: []const u8) void {
    // Build path to .git-wrapper directory and delete recursively.
    // We can't use allocPrint here without an allocator, so use a
    // stack buffer for the path.
    var buf: [4096]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ worktree_path, wrapper_dir_name }) catch return;
    std.fs.deleteTreeAbsolute(dir_path) catch {};
}

/// Resolve the absolute path to the real git binary by searching PATH.
/// The engine process's PATH does not contain .git-wrapper, so this
/// returns the system git. Returns owned memory that the caller must free.
pub fn resolveGitBinary(allocator: std.mem.Allocator) ![]u8 {
    const path_env = std.posix.getenv("PATH") orelse "/usr/bin:/usr/local/bin";
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fmt.allocPrint(allocator, "{s}/git", .{dir});
        // Check if file exists and is accessible
        std.fs.accessAbsolute(candidate, .{}) catch {
            allocator.free(candidate);
            continue;
        };
        return candidate;
    }
    return error.GitNotFound;
}

/// Returns the interceptor directory path for a worker's worktree,
/// or null if no interceptor is installed (directory doesn't exist).
/// Returns owned memory that the caller must free.
pub fn getInterceptorPath(allocator: std.mem.Allocator, worktree_path: []const u8) !?[]u8 {
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ worktree_path, wrapper_dir_name });
    // Check if the directory exists
    std.fs.accessAbsolute(dir_path, .{}) catch {
        allocator.free(dir_path);
        return null;
    };
    return dir_path;
}

// ─────────────────────────────────────────────────────────
// Script generation
// ─────────────────────────────────────────────────────────

/// Generate a 2-line pass-through wrapper for workers with no restrictions.
fn generatePassthroughScript(allocator: std.mem.Allocator, real_git: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\#!/bin/bash
        \\exec "{s}" "$@"
        \\
    , .{real_git});
}

/// Generate the full interceptor wrapper script with embedded deny patterns,
/// subcommand detection, bulk-add blocking, and per-file checking.
fn generateInterceptorScript(
    allocator: std.mem.Allocator,
    real_git: []const u8,
    worker_id: WorkerId,
    role_name: []const u8,
    deny_patterns: []const []const u8,
    write_patterns: []const []const u8,
) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 2048);
    errdefer buf.deinit(allocator);

    // Shebang and header
    try buf.appendSlice(allocator, "#!/bin/bash\n");
    try appendFmt(&buf, allocator, "# Teammux git interceptor for worker {d} ({s}) — do not modify\n", .{ worker_id, role_name });

    // Real git path
    try appendFmt(&buf, allocator, "REAL_GIT=\"{s}\"\n", .{real_git});

    // Deny patterns as bash array
    try buf.appendSlice(allocator, "DENY_PATTERNS=(");
    for (deny_patterns, 0..) |pat, i| {
        if (i > 0) try buf.appendSlice(allocator, " ");
        try buf.appendSlice(allocator, "\"");
        try buf.appendSlice(allocator, pat);
        try buf.appendSlice(allocator, "\"");
    }
    try buf.appendSlice(allocator, ")\n");

    // Write scope string for error messages
    try buf.appendSlice(allocator, "WRITE_SCOPE=\"");
    for (write_patterns, 0..) |pat, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, pat);
    }
    if (write_patterns.len == 0) {
        try buf.appendSlice(allocator, "(none defined)");
    }
    try buf.appendSlice(allocator, "\"\n");

    // Role name for error messages
    try appendFmt(&buf, allocator, "ROLE_NAME=\"{s}\"\n", .{role_name});

    try buf.appendSlice(allocator,
        \\
        \\# Detect git subcommand (skip global flags)
        \\subcmd=""
        \\skip_next=false
        \\for arg in "$@"; do
        \\  if $skip_next; then skip_next=false; continue; fi
        \\  case "$arg" in
        \\    -C|-c|--git-dir|--work-tree|--namespace) skip_next=true ;;
        \\    --git-dir=*|--work-tree=*|-C*) ;;
        \\    -*) ;;
        \\    *) subcmd="$arg"; break ;;
        \\  esac
        \\done
        \\
        \\if [[ "$subcmd" == "add" ]]; then
        \\  # Block bulk staging operations
        \\  for arg in "$@"; do
        \\    if [[ "$arg" == "." || "$arg" == "-A" || "$arg" == "--all" || "$arg" == "-u" || "$arg" == "--update" ]]; then
        \\      echo "[Teammux] Cannot stage all files — this worker has write restrictions."
        \\      echo "Use explicit paths: git add <file>"
        \\      echo "Your write scope: $WRITE_SCOPE"
        \\      exit 1
        \\    fi
        \\  done
        \\  # Check individual files against deny patterns
        \\  past_add=false
        \\  for arg in "$@"; do
        \\    case "$arg" in -*) continue ;; esac
        \\    if ! $past_add; then
        \\      [[ "$arg" == "add" ]] && past_add=true
        \\      continue
        \\    fi
        \\    for pattern in "${DENY_PATTERNS[@]}"; do
        \\      if [[ "$arg" == $pattern ]]; then
        \\        echo "[Teammux] Permission denied: $arg is outside your write scope ($ROLE_NAME)"
        \\        echo "Your write scope: $WRITE_SCOPE"
        \\        exit 1
        \\      fi
        \\    done
        \\  done
        \\fi
        \\exec "$REAL_GIT" "$@"
        \\
    );

    return try buf.toOwnedSlice(allocator);
}

/// Helper to append formatted output to an ArrayList.
fn appendFmt(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const formatted = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(formatted);
    try buf.appendSlice(allocator, formatted);
}

// ─────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────

test "interceptor - resolveGitBinary finds git" {
    const git = try resolveGitBinary(std.testing.allocator);
    defer std.testing.allocator.free(git);
    // Must be an absolute path ending in /git
    try std.testing.expect(git.len > 4);
    try std.testing.expect(git[0] == '/');
    try std.testing.expect(std.mem.endsWith(u8, git, "/git"));
}

test "interceptor - install creates wrapper with deny patterns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    const deny = [_][]const u8{ "src/backend/**", "infrastructure/**" };
    const write = [_][]const u8{ "src/frontend/**", "tests/**" };

    try install(std.testing.allocator, path, 42, "Frontend Engineer", &deny, &write);

    // Verify wrapper file exists
    const wrapper_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.git-wrapper/git", .{path});
    defer std.testing.allocator.free(wrapper_path);
    const file = try std.fs.openFileAbsolute(wrapper_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(std.testing.allocator, 64 * 1024);
    defer std.testing.allocator.free(content);

    // Check shebang
    try std.testing.expect(std.mem.startsWith(u8, content, "#!/bin/bash\n"));
    // Check deny patterns are embedded
    try std.testing.expect(std.mem.indexOf(u8, content, "src/backend/**") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "infrastructure/**") != null);
    // Check write scope
    try std.testing.expect(std.mem.indexOf(u8, content, "src/frontend/**, tests/**") != null);
    // Check role name
    try std.testing.expect(std.mem.indexOf(u8, content, "Frontend Engineer") != null);
    // Check worker id
    try std.testing.expect(std.mem.indexOf(u8, content, "worker 42") != null);
    // Check bulk-add blocking
    try std.testing.expect(std.mem.indexOf(u8, content, "Cannot stage all files") != null);
    // Check subcommand detection
    try std.testing.expect(std.mem.indexOf(u8, content, "subcmd=") != null);
    // Check real git path is absolute
    try std.testing.expect(std.mem.indexOf(u8, content, "REAL_GIT=\"/") != null);
}

test "interceptor - install sets executable permission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    const deny = [_][]const u8{"src/backend/**"};
    const write = [_][]const u8{"src/frontend/**"};

    try install(std.testing.allocator, path, 1, "test", &deny, &write);

    const wrapper_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.git-wrapper/git", .{path});
    defer std.testing.allocator.free(wrapper_path);

    const file = try std.fs.openFileAbsolute(wrapper_path, .{});
    defer file.close();
    const stat = try file.stat();
    // Check owner execute bit (0o100)
    try std.testing.expect(stat.mode & 0o100 != 0);
}

test "interceptor - no role produces pass-through wrapper" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    const empty_deny = [_][]const u8{};
    const empty_write = [_][]const u8{};

    try install(std.testing.allocator, path, 1, "", &empty_deny, &empty_write);

    const wrapper_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.git-wrapper/git", .{path});
    defer std.testing.allocator.free(wrapper_path);
    const file = try std.fs.openFileAbsolute(wrapper_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(std.testing.allocator, 64 * 1024);
    defer std.testing.allocator.free(content);

    // Pass-through: shebang + exec, no DENY_PATTERNS, no subcommand detection
    try std.testing.expect(std.mem.startsWith(u8, content, "#!/bin/bash\n"));
    try std.testing.expect(std.mem.indexOf(u8, content, "exec \"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "DENY_PATTERNS") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "subcmd") == null);

    // Should be exactly 2 lines (shebang + exec)
    var line_count: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) line_count += 1;
    }
    try std.testing.expect(line_count == 2);
}

test "interceptor - remove deletes wrapper directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    const deny = [_][]const u8{"src/**"};
    const write = [_][]const u8{"tests/**"};

    try install(std.testing.allocator, path, 1, "test", &deny, &write);

    // Verify it exists
    const dir_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.git-wrapper", .{path});
    defer std.testing.allocator.free(dir_path);
    _ = try std.fs.openDirAbsolute(dir_path, .{});

    // Remove
    remove(path);

    // Verify it's gone
    std.fs.accessAbsolute(dir_path, .{}) catch |err| {
        try std.testing.expect(err == error.FileNotFound);
        return;
    };
    return error.TestUnexpectedResult;
}

test "interceptor - remove on non-existent directory is safe" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    // Should not error
    remove(path);
}

test "interceptor - getInterceptorPath returns path when installed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    const empty = [_][]const u8{};
    try install(std.testing.allocator, path, 1, "", &empty, &empty);

    const result = try getInterceptorPath(std.testing.allocator, path);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expect(std.mem.endsWith(u8, result.?, "/.git-wrapper"));
}

test "interceptor - getInterceptorPath returns null when not installed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    const result = try getInterceptorPath(std.testing.allocator, path);
    try std.testing.expect(result == null);
}

test "interceptor - wrapper contains bulk-add blocking for all variants" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    const deny = [_][]const u8{"src/**"};
    const write = [_][]const u8{"tests/**"};
    try install(std.testing.allocator, path, 1, "test", &deny, &write);

    const wrapper_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.git-wrapper/git", .{path});
    defer std.testing.allocator.free(wrapper_path);
    const file = try std.fs.openFileAbsolute(wrapper_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(std.testing.allocator, 64 * 1024);
    defer std.testing.allocator.free(content);

    // All bulk-add variants must be blocked
    try std.testing.expect(std.mem.indexOf(u8, content, "\".\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"-A\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"--all\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"-u\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"--update\"") != null);
}

test "interceptor - empty write patterns shows none defined" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    const deny = [_][]const u8{"src/**"};
    const empty_write = [_][]const u8{};
    try install(std.testing.allocator, path, 1, "test", &deny, &empty_write);

    const wrapper_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.git-wrapper/git", .{path});
    defer std.testing.allocator.free(wrapper_path);
    const file = try std.fs.openFileAbsolute(wrapper_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(std.testing.allocator, 64 * 1024);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "(none defined)") != null);
}
