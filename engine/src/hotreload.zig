const std = @import("std");
const config = @import("config.zig");
const worktree = @import("worktree.zig");
const ownership = @import("ownership.zig");
const interceptor = @import("interceptor.zig");

// ─────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────

pub const RoleChangedCb = *const fn (u32, ?[*:0]const u8, ?*anyopaque) callconv(.c) void;

pub const RoleWatcherMap = std.AutoHashMap(worktree.WorkerId, *RoleWatcher);

// ─────────────────────────────────────────────────────────
// RoleWatcher — kqueue-based file watcher for a single role
// ─────────────────────────────────────────────────────────

pub const RoleWatcher = struct {
    allocator: std.mem.Allocator,
    worker_id: worktree.WorkerId,
    role_id: []const u8,
    role_path: []const u8,
    task_description: []const u8,
    branch_name: []const u8,
    project_root: []const u8, // non-owning — Engine outlives watcher
    worktree_path: []const u8, // owned — worker's worktree for interceptor reinstall
    worker_name: []const u8, // owned — worker name for interceptor reinstall
    ownership_registry: ?*ownership.FileOwnershipRegistry, // non-owning — Engine outlives watcher
    kq: std.posix.fd_t,
    watch_fd: std.posix.fd_t,
    callback: RoleChangedCb,
    userdata: ?*anyopaque,
    thread: ?std.Thread,
    running: std.atomic.Value(bool),

    /// Heap-allocate a new RoleWatcher. All string arguments are copied (owned).
    /// project_root and ownership_registry are stored as non-owning references —
    /// Engine must outlive the watcher. The allocator must be thread-safe
    /// (e.g., c_allocator) — fireCallback uses it on the watcher thread.
    pub fn create(
        allocator: std.mem.Allocator,
        worker_id: worktree.WorkerId,
        role_id: []const u8,
        role_path: []const u8,
        task_description: []const u8,
        branch_name: []const u8,
        project_root: []const u8,
        wt_path: []const u8,
        w_name: []const u8,
        registry: ?*ownership.FileOwnershipRegistry,
        callback: RoleChangedCb,
        userdata: ?*anyopaque,
    ) !*RoleWatcher {
        const owned_role_id = try allocator.dupe(u8, role_id);
        errdefer allocator.free(owned_role_id);
        const owned_role_path = try allocator.dupe(u8, role_path);
        errdefer allocator.free(owned_role_path);
        const owned_task = try allocator.dupe(u8, task_description);
        errdefer allocator.free(owned_task);
        const owned_branch = try allocator.dupe(u8, branch_name);
        errdefer allocator.free(owned_branch);
        const owned_wt_path = try allocator.dupe(u8, wt_path);
        errdefer allocator.free(owned_wt_path);
        const owned_w_name = try allocator.dupe(u8, w_name);
        errdefer allocator.free(owned_w_name);

        const self = try allocator.create(RoleWatcher);
        self.* = .{
            .allocator = allocator,
            .worker_id = worker_id,
            .role_id = owned_role_id,
            .role_path = owned_role_path,
            .task_description = owned_task,
            .branch_name = owned_branch,
            .project_root = project_root,
            .worktree_path = owned_wt_path,
            .worker_name = owned_w_name,
            .ownership_registry = registry,
            .kq = -1,
            .watch_fd = -1,
            .callback = callback,
            .userdata = userdata,
            .thread = null,
            .running = std.atomic.Value(bool).init(false),
        };
        return self;
    }

    /// Open the role file for kqueue watching and spawn the watcher thread.
    /// Returns error.AlreadyStarted if called on a watcher that is already running.
    pub fn start(self: *RoleWatcher) !void {
        if (self.thread != null) return error.AlreadyStarted;

        const file = std.fs.openFileAbsolute(self.role_path, .{}) catch |err| {
            std.log.warn("[teammux] hotreload: cannot open role file '{s}': {}", .{ self.role_path, err });
            return err;
        };
        self.watch_fd = file.handle;
        // Intentionally NOT closing — fd kept open for kqueue; closed by destroy()
        errdefer {
            std.posix.close(self.watch_fd);
            self.watch_fd = -1;
        }

        self.kq = try std.posix.kqueue();
        errdefer {
            std.posix.close(self.kq);
            self.kq = -1;
        }

        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, watchLoop, .{self});
    }

    /// Signal the watcher thread to exit and join it.
    /// The thread exits via its 1-second kevent timeout (same pattern as ConfigWatcher).
    pub fn stop(self: *RoleWatcher) void {
        self.running.store(false, .release);
        // Let the thread exit via its 1-second kevent timeout
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// Stop, close file descriptors, free owned strings (project_root and
    /// ownership_registry are non-owning), destroy self.
    pub fn destroy(self: *RoleWatcher) void {
        self.stop();
        if (self.kq >= 0) {
            std.posix.close(self.kq);
            self.kq = -1;
        }
        if (self.watch_fd >= 0) {
            std.posix.close(self.watch_fd);
            self.watch_fd = -1;
        }
        const allocator = self.allocator;
        allocator.free(self.role_id);
        allocator.free(self.role_path);
        allocator.free(self.task_description);
        allocator.free(self.branch_name);
        allocator.free(self.worktree_path);
        allocator.free(self.worker_name);
        allocator.destroy(self);
    }

    fn watchLoop(self: *RoleWatcher) void {
        while (self.running.load(.acquire)) {
            // Guard: if watch_fd is invalid (after failed re-open), try to recover
            if (self.watch_fd < 0) {
                const new_file = std.fs.openFileAbsolute(self.role_path, .{}) catch {
                    // File still unavailable — back off and retry
                    std.Thread.sleep(500 * std.time.ns_per_ms);
                    continue;
                };
                self.watch_fd = new_file.handle;
            }

            // Register for VNODE events (also monitors ATTRIB for editors that touch attrs on save)
            const changelist = [1]std.posix.Kevent{.{
                .ident = @intCast(self.watch_fd),
                .filter = std.c.EVFILT.VNODE,
                .flags = std.c.EV.ADD | std.c.EV.CLEAR,
                .fflags = std.c.NOTE.WRITE | std.c.NOTE.DELETE | std.c.NOTE.RENAME | std.c.NOTE.ATTRIB,
                .data = 0,
                .udata = 0,
            }};

            var eventlist: [1]std.posix.Kevent = undefined;

            // 1-second timeout so we can check the running flag
            const timeout = std.posix.timespec{ .sec = 1, .nsec = 0 };

            const n = std.posix.kevent(
                self.kq,
                &changelist,
                &eventlist,
                &timeout,
            ) catch |err| {
                // Expected: stop() closed kq to unblock us
                if (!self.running.load(.acquire)) break;
                std.log.err("[teammux] hotreload: kevent failed for worker {d} on role '{s}': {}", .{ self.worker_id, self.role_id, err });
                break;
            };

            if (n > 0) {
                const fflags = eventlist[0].fflags;

                // Handle rename/delete: editor saved via temp file rename (vim pattern)
                if (fflags & std.c.NOTE.DELETE != 0 or fflags & std.c.NOTE.RENAME != 0) {
                    // Close old fd and mark invalid to prevent stale kqueue registration
                    std.posix.close(self.watch_fd);
                    self.watch_fd = -1;
                    // Small delay for rename to complete
                    std.Thread.sleep(100 * std.time.ns_per_ms);

                    const new_file = std.fs.openFileAbsolute(self.role_path, .{}) catch |err| {
                        std.log.warn("[teammux] hotreload: cannot reopen role file '{s}' after rename/delete for worker {d}: {}", .{ self.role_path, self.worker_id, err });
                        // watch_fd stays -1; guard at top of loop will retry with backoff
                        continue;
                    };
                    self.watch_fd = new_file.handle;
                }

                // Re-parse role and fire callback
                self.fireCallback();
            }
        }
    }

    fn fireCallback(self: *RoleWatcher) void {
        // Re-parse the role definition from disk
        var role_def = config.parseRoleDefinition(self.allocator, self.role_path) catch |err| {
            std.log.warn("[teammux] hotreload: failed to parse role '{s}' for worker {d}: {}", .{ self.role_id, self.worker_id, err });
            // Signal parse failure to callback so UI can notify user
            self.callback(self.worker_id, null, self.userdata);
            return;
        };
        defer role_def.deinit(self.allocator);

        // TD18: Update ownership registry and interceptor with new patterns.
        // These two operations are independent — if one fails, the other may
        // still succeed, creating a transient inconsistency that self-heals
        // on the next role file change.
        if (self.ownership_registry) |registry| {
            registry.updateWorkerRules(
                self.worker_id,
                role_def.write_patterns,
                role_def.deny_write_patterns,
            ) catch |err| {
                std.log.warn("[teammux] hotreload: ownership update failed for worker {d}: {}", .{ self.worker_id, err });
            };

            // Reinstall interceptor wrapper with new deny patterns
            if (self.worktree_path.len > 0) {
                interceptor.install(
                    self.allocator,
                    self.worktree_path,
                    self.worker_id,
                    self.worker_name,
                    role_def.deny_write_patterns,
                    role_def.write_patterns,
                ) catch |err| {
                    std.log.warn("[teammux] hotreload: ownership updated but interceptor reinstall failed for worker {d} — git wrapper has stale patterns until next role file change: {}", .{ self.worker_id, err });
                };
            }
        }

        // Regenerate CLAUDE.md content
        const claude_md = worktree.generateRoleClaude(
            self.allocator,
            role_def,
            self.task_description,
            self.branch_name,
        ) catch |err| {
            std.log.warn("[teammux] hotreload: failed to generate CLAUDE.md for worker {d}: {}", .{ self.worker_id, err });
            return;
        };
        defer self.allocator.free(claude_md);

        // Create null-terminated copy for C callback
        const claude_md_z = self.allocator.dupeZ(u8, claude_md) catch {
            std.log.warn("[teammux] hotreload: allocation failed for callback string", .{});
            return;
        };
        defer self.allocator.free(claude_md_z);

        // Fire callback — watcher allocates; memory freed after this call returns
        const ptr: [*:0]const u8 = claude_md_z.ptr;
        self.callback(self.worker_id, ptr, self.userdata);
    }
};

// ─────────────────────────────────────────────────────────
// RoleWatcherMap lifecycle helpers
// ─────────────────────────────────────────────────────────

/// Stop and destroy all watchers in the map, then deinit the map itself.
/// Uses two-pass shutdown: signal all watchers first, then join all threads.
/// This bounds total shutdown time to ~1 second regardless of watcher count.
pub fn destroyAll(map: *RoleWatcherMap) void {
    // Pass 1: signal all watchers to stop (non-blocking)
    var it1 = map.iterator();
    while (it1.next()) |entry| {
        entry.value_ptr.*.running.store(false, .release);
    }
    // Pass 2: join threads and destroy (each bounded by 1s kevent timeout)
    var it2 = map.iterator();
    while (it2.next()) |entry| {
        entry.value_ptr.*.destroy();
    }
    map.deinit();
}

/// Stop all running watchers without destroying them. Used by sessionStop
/// to pause file watching while preserving watcher state for session restart.
/// Uses two-pass shutdown: signal all, then join all.
pub fn stopAll(map: *RoleWatcherMap) void {
    // Pass 1: signal all watchers to stop (non-blocking)
    var it1 = map.iterator();
    while (it1.next()) |entry| {
        entry.value_ptr.*.running.store(false, .release);
    }
    // Pass 2: join all threads
    var it2 = map.iterator();
    while (it2.next()) |entry| {
        entry.value_ptr.*.stop();
    }
}

// ─────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────

fn writeTestRole(alloc: std.mem.Allocator, dir: std.fs.Dir, filename: []const u8, role_name: []const u8) !void {
    const content = try std.fmt.allocPrint(alloc,
        \\[identity]
        \\id = "test-role"
        \\name = "{s}"
        \\division = "testing"
        \\description = "A test role"
        \\
        \\[context]
        \\mission = "Test mission"
    , .{role_name});
    defer alloc.free(content);
    const file = try dir.createFile(filename, .{});
    defer file.close();
    try file.writeAll(content);
}

test "hotreload - RoleWatcher create and destroy without start" {
    const alloc = std.testing.allocator;
    const watcher = try RoleWatcher.create(
        alloc,
        1,
        "test-role",
        "/tmp/nonexistent.toml",
        "test task",
        "test-branch",
        "/tmp",
        "",
        "",
        null,
        &struct {
            fn cb(_: u32, _: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) void {}
        }.cb,
        null,
    );
    // Destroy without ever starting — must not crash or leak
    watcher.destroy();
}

test "hotreload - watcher detects NOTE_WRITE" {
    const alloc = std.testing.allocator;

    // Create a temp directory and role file
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);

    try writeTestRole(alloc, tmp.dir, "test-role.toml", "Original Role");

    const role_path = try std.fmt.allocPrint(alloc, "{s}/test-role.toml", .{tmp_path});
    defer alloc.free(role_path);

    // Shared state for callback verification
    var callback_fired = std.atomic.Value(bool).init(false);

    const watcher = try RoleWatcher.create(
        alloc,
        1,
        "test-role",
        role_path,
        "test task",
        "test-branch",
        tmp_path,
        "",
        "",
        null,
        &struct {
            fn cb(_: u32, content: ?[*:0]const u8, ud: ?*anyopaque) callconv(.c) void {
                if (content) |c| {
                    const s = std.mem.span(c);
                    // Verify the regenerated content contains the updated role name
                    if (std.mem.indexOf(u8, s, "Updated Role") != null) {
                        const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(ud));
                        flag.store(true, .release);
                    }
                }
            }
        }.cb,
        @ptrCast(&callback_fired),
    );
    defer watcher.destroy();

    try watcher.start();

    // Give watcher thread time to register with kqueue
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Write updated role file (NOTE_WRITE trigger)
    try writeTestRole(alloc, tmp.dir, "test-role.toml", "Updated Role");

    // Wait for callback (up to 3 seconds)
    var waited: usize = 0;
    while (waited < 30) : (waited += 1) {
        if (callback_fired.load(.acquire)) break;
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    try std.testing.expect(callback_fired.load(.acquire));
}

test "hotreload - watcher detects NOTE_RENAME (vim save pattern)" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);

    try writeTestRole(alloc, tmp.dir, "test-role.toml", "Original Role");

    const role_path = try std.fmt.allocPrint(alloc, "{s}/test-role.toml", .{tmp_path});
    defer alloc.free(role_path);

    var callback_fired = std.atomic.Value(bool).init(false);

    const watcher = try RoleWatcher.create(
        alloc,
        2,
        "test-role",
        role_path,
        "vim rename task",
        "feat/vim-test",
        tmp_path,
        "",
        "",
        null,
        &struct {
            fn cb(_: u32, content: ?[*:0]const u8, ud: ?*anyopaque) callconv(.c) void {
                if (content) |c| {
                    const s = std.mem.span(c);
                    if (std.mem.indexOf(u8, s, "Vim Saved Role") != null) {
                        const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(ud));
                        flag.store(true, .release);
                    }
                }
            }
        }.cb,
        @ptrCast(&callback_fired),
    );
    defer watcher.destroy();

    try watcher.start();

    // Give watcher thread time to register
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Simulate vim save: rename old → backup, write new file at original path
    tmp.dir.rename("test-role.toml", "test-role.toml~") catch {};
    try writeTestRole(alloc, tmp.dir, "test-role.toml", "Vim Saved Role");

    // Wait for callback (up to 5 seconds — rename needs 100ms sleep + re-open)
    var waited: usize = 0;
    while (waited < 50) : (waited += 1) {
        if (callback_fired.load(.acquire)) break;
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    try std.testing.expect(callback_fired.load(.acquire));
}

test "hotreload - callback receives correct CLAUDE.md content" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);

    try writeTestRole(alloc, tmp.dir, "test-role.toml", "Content Check Role");

    const role_path = try std.fmt.allocPrint(alloc, "{s}/test-role.toml", .{tmp_path});
    defer alloc.free(role_path);

    // Store the callback content for verification
    const CallbackState = struct {
        fired: std.atomic.Value(bool),
        has_role_name: std.atomic.Value(bool),
        has_task: std.atomic.Value(bool),
        has_branch: std.atomic.Value(bool),
        has_mission: std.atomic.Value(bool),
    };
    var state = CallbackState{
        .fired = std.atomic.Value(bool).init(false),
        .has_role_name = std.atomic.Value(bool).init(false),
        .has_task = std.atomic.Value(bool).init(false),
        .has_branch = std.atomic.Value(bool).init(false),
        .has_mission = std.atomic.Value(bool).init(false),
    };

    const watcher = try RoleWatcher.create(
        alloc,
        3,
        "test-role",
        role_path,
        "implement feature X",
        "feat/feature-x",
        tmp_path,
        "",
        "",
        null,
        &struct {
            fn cb(_: u32, content: ?[*:0]const u8, ud: ?*anyopaque) callconv(.c) void {
                const s_ptr: *CallbackState = @ptrCast(@alignCast(ud));
                if (content) |c| {
                    const s = std.mem.span(c);
                    if (std.mem.indexOf(u8, s, "Content Check Role") != null)
                        s_ptr.has_role_name.store(true, .release);
                    if (std.mem.indexOf(u8, s, "implement feature X") != null)
                        s_ptr.has_task.store(true, .release);
                    if (std.mem.indexOf(u8, s, "feat/feature-x") != null)
                        s_ptr.has_branch.store(true, .release);
                    if (std.mem.indexOf(u8, s, "Test mission") != null)
                        s_ptr.has_mission.store(true, .release);
                    s_ptr.fired.store(true, .release);
                }
            }
        }.cb,
        @ptrCast(&state),
    );
    defer watcher.destroy();

    try watcher.start();
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Trigger a write
    try writeTestRole(alloc, tmp.dir, "test-role.toml", "Content Check Role");

    var waited: usize = 0;
    while (waited < 30) : (waited += 1) {
        if (state.fired.load(.acquire)) break;
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    try std.testing.expect(state.fired.load(.acquire));
    try std.testing.expect(state.has_role_name.load(.acquire));
    try std.testing.expect(state.has_task.load(.acquire));
    try std.testing.expect(state.has_branch.load(.acquire));
    try std.testing.expect(state.has_mission.load(.acquire));
}

test "hotreload - stop joins thread cleanly" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);

    try writeTestRole(alloc, tmp.dir, "test-role.toml", "Stop Test");

    const role_path = try std.fmt.allocPrint(alloc, "{s}/test-role.toml", .{tmp_path});
    defer alloc.free(role_path);

    const watcher = try RoleWatcher.create(
        alloc,
        4,
        "test-role",
        role_path,
        "stop test task",
        "test-branch",
        tmp_path,
        "",
        "",
        null,
        &struct {
            fn cb(_: u32, _: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) void {}
        }.cb,
        null,
    );

    try watcher.start();

    // Verify thread is running
    try std.testing.expect(watcher.thread != null);
    try std.testing.expect(watcher.running.load(.acquire));

    // Stop should join the thread without hanging
    watcher.stop();

    try std.testing.expect(watcher.thread == null);
    try std.testing.expect(!watcher.running.load(.acquire));

    // Clean up
    watcher.destroy();
}

test "hotreload - destroyAll cleans up map" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);

    try writeTestRole(alloc, tmp.dir, "role-a.toml", "Role A");
    try writeTestRole(alloc, tmp.dir, "role-b.toml", "Role B");

    const path_a = try std.fmt.allocPrint(alloc, "{s}/role-a.toml", .{tmp_path});
    defer alloc.free(path_a);
    const path_b = try std.fmt.allocPrint(alloc, "{s}/role-b.toml", .{tmp_path});
    defer alloc.free(path_b);

    const noop_cb = &struct {
        fn cb(_: u32, _: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) void {}
    }.cb;

    var map = RoleWatcherMap.init(alloc);

    const w1 = try RoleWatcher.create(alloc, 1, "role-a", path_a, "task a", "branch-a", tmp_path, "", "", null, noop_cb, null);
    try w1.start();
    try map.put(1, w1);

    const w2 = try RoleWatcher.create(alloc, 2, "role-b", path_b, "task b", "branch-b", tmp_path, "", "", null, noop_cb, null);
    try w2.start();
    try map.put(2, w2);

    try std.testing.expect(map.count() == 2);

    // destroyAll should stop all threads, free all watchers, and deinit the map
    destroyAll(&map);
}

// ─────────────────────────────────────────────────────────
// Tests — TD18: ownership + interceptor sync on hot-reload
// ─────────────────────────────────────────────────────────

fn writeTestRoleWithPatterns(
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    filename: []const u8,
    role_name: []const u8,
    write_pats: []const []const u8,
    deny_pats: []const []const u8,
) !void {
    var buf = try std.ArrayList(u8).initCapacity(alloc, 512);
    defer buf.deinit(alloc);

    try buf.appendSlice(alloc, "[identity]\nid = \"test-role\"\nname = \"");
    try buf.appendSlice(alloc, role_name);
    try buf.appendSlice(alloc, "\"\ndivision = \"testing\"\ndescription = \"A test role\"\n\n[capabilities]\nwrite = [");
    for (write_pats, 0..) |p, i| {
        if (i > 0) try buf.appendSlice(alloc, ", ");
        try buf.appendSlice(alloc, "\"");
        try buf.appendSlice(alloc, p);
        try buf.appendSlice(alloc, "\"");
    }
    try buf.appendSlice(alloc, "]\ndeny_write = [");
    for (deny_pats, 0..) |p, i| {
        if (i > 0) try buf.appendSlice(alloc, ", ");
        try buf.appendSlice(alloc, "\"");
        try buf.appendSlice(alloc, p);
        try buf.appendSlice(alloc, "\"");
    }
    try buf.appendSlice(alloc, "]\n\n[context]\nmission = \"Test mission\"\n");

    const file = try dir.createFile(filename, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

test "hotreload TD18 - ownership registry updated on role change" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);

    // Initial role: frontend patterns
    const initial_write = [_][]const u8{ "src/frontend/**", "tests/**" };
    const initial_deny = [_][]const u8{"src/backend/**"};
    try writeTestRoleWithPatterns(alloc, tmp.dir, "test-role.toml", "Frontend", &initial_write, &initial_deny);

    const role_path = try std.fmt.allocPrint(alloc, "{s}/test-role.toml", .{tmp_path});
    defer alloc.free(role_path);

    // Set up ownership registry with initial rules matching the role file
    var registry = ownership.FileOwnershipRegistry.init(alloc);
    defer registry.deinit();
    try registry.register(1, "src/frontend/**", true);
    try registry.register(1, "tests/**", true);
    try registry.register(1, "src/backend/**", false);

    var callback_fired = std.atomic.Value(bool).init(false);

    const watcher = try RoleWatcher.create(
        alloc,
        1,
        "test-role",
        role_path,
        "test task",
        "test-branch",
        tmp_path,
        tmp_path, // worktree_path = tmp dir for interceptor install
        "Test Worker",
        &registry,
        &struct {
            fn cb(_: u32, content: ?[*:0]const u8, ud: ?*anyopaque) callconv(.c) void {
                if (content != null) {
                    const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(ud));
                    flag.store(true, .release);
                }
            }
        }.cb,
        @ptrCast(&callback_fired),
    );
    defer watcher.destroy();

    try watcher.start();
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Update role: swap patterns — backend write, frontend deny
    const new_write = [_][]const u8{"src/backend/**"};
    const new_deny = [_][]const u8{ "src/frontend/**", "infrastructure/**" };
    try writeTestRoleWithPatterns(alloc, tmp.dir, "test-role.toml", "Backend", &new_write, &new_deny);

    // Wait for callback
    var waited: usize = 0;
    while (waited < 30) : (waited += 1) {
        if (callback_fired.load(.acquire)) break;
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
    try std.testing.expect(callback_fired.load(.acquire));

    // Verify registry reflects NEW patterns
    const rules = try registry.copyRules(1, std.testing.allocator) orelse return error.TestUnexpectedResult;
    defer ownership.FileOwnershipRegistry.freeRulesCopy(std.testing.allocator, rules);
    try std.testing.expect(rules.len == 3); // 1 write + 2 deny

    // New write pattern works
    try std.testing.expect(registry.check(1, "src/backend/server.ts"));

    // Old write pattern now denied
    try std.testing.expect(!registry.check(1, "src/frontend/App.tsx"));

    // New deny pattern works
    try std.testing.expect(!registry.check(1, "infrastructure/main.tf"));
}

test "hotreload TD18 - interceptor wrapper regenerated with new patterns" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);

    // Initial role with deny patterns
    const initial_write = [_][]const u8{"src/**"};
    const initial_deny = [_][]const u8{"infra/**"};
    try writeTestRoleWithPatterns(alloc, tmp.dir, "test-role.toml", "Initial", &initial_write, &initial_deny);

    const role_path = try std.fmt.allocPrint(alloc, "{s}/test-role.toml", .{tmp_path});
    defer alloc.free(role_path);

    var registry = ownership.FileOwnershipRegistry.init(alloc);
    defer registry.deinit();
    try registry.register(1, "src/**", true);
    try registry.register(1, "infra/**", false);

    var callback_fired = std.atomic.Value(bool).init(false);

    const watcher = try RoleWatcher.create(
        alloc,
        1,
        "test-role",
        role_path,
        "test task",
        "test-branch",
        tmp_path,
        tmp_path,
        "Test Worker",
        &registry,
        &struct {
            fn cb(_: u32, content: ?[*:0]const u8, ud: ?*anyopaque) callconv(.c) void {
                if (content != null) {
                    const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(ud));
                    flag.store(true, .release);
                }
            }
        }.cb,
        @ptrCast(&callback_fired),
    );
    defer watcher.destroy();

    try watcher.start();
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Update role with different deny patterns
    const new_write = [_][]const u8{"tests/**"};
    const new_deny = [_][]const u8{"docs/**"};
    try writeTestRoleWithPatterns(alloc, tmp.dir, "test-role.toml", "Updated", &new_write, &new_deny);

    // Wait for callback
    var waited: usize = 0;
    while (waited < 30) : (waited += 1) {
        if (callback_fired.load(.acquire)) break;
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
    try std.testing.expect(callback_fired.load(.acquire));

    // Verify interceptor wrapper was regenerated — read the wrapper script
    const wrapper_path = try std.fmt.allocPrint(alloc, "{s}/.git-wrapper/git", .{tmp_path});
    defer alloc.free(wrapper_path);
    const file = try std.fs.openFileAbsolute(wrapper_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(alloc, 64 * 1024);
    defer alloc.free(content);

    // New deny pattern present in wrapper
    try std.testing.expect(std.mem.indexOf(u8, content, "'docs/**'") != null);
    // Old deny pattern NOT present
    try std.testing.expect(std.mem.indexOf(u8, content, "'infra/**'") == null);
}

test "hotreload TD18 - failed parse does not corrupt registry" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);

    // Start with valid role
    const write = [_][]const u8{"src/**"};
    const deny = [_][]const u8{"infra/**"};
    try writeTestRoleWithPatterns(alloc, tmp.dir, "test-role.toml", "Valid", &write, &deny);

    const role_path = try std.fmt.allocPrint(alloc, "{s}/test-role.toml", .{tmp_path});
    defer alloc.free(role_path);

    var registry = ownership.FileOwnershipRegistry.init(alloc);
    defer registry.deinit();
    try registry.register(1, "src/**", true);
    try registry.register(1, "infra/**", false);

    var callback_fired = std.atomic.Value(bool).init(false);

    const watcher = try RoleWatcher.create(
        alloc,
        1,
        "test-role",
        role_path,
        "test task",
        "test-branch",
        tmp_path,
        tmp_path,
        "Test Worker",
        &registry,
        &struct {
            fn cb(_: u32, _: ?[*:0]const u8, ud: ?*anyopaque) callconv(.c) void {
                // Fires for both success (non-null) and failure (null)
                const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(ud));
                flag.store(true, .release);
            }
        }.cb,
        @ptrCast(&callback_fired),
    );
    defer watcher.destroy();

    try watcher.start();
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Write INVALID TOML — missing required identity.id field
    {
        const invalid = try tmp.dir.createFile("test-role.toml", .{});
        defer invalid.close();
        try invalid.writeAll("this is not valid toml\n");
    }

    // Wait for callback to fire (parse failure sends null)
    var waited: usize = 0;
    while (waited < 30) : (waited += 1) {
        if (callback_fired.load(.acquire)) break;
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
    try std.testing.expect(callback_fired.load(.acquire));

    // Registry must be UNCHANGED — old rules preserved
    const rules = try registry.copyRules(1, std.testing.allocator) orelse return error.TestUnexpectedResult;
    defer ownership.FileOwnershipRegistry.freeRulesCopy(std.testing.allocator, rules);
    try std.testing.expect(rules.len == 2);
    try std.testing.expect(registry.check(1, "src/foo.ts"));
    try std.testing.expect(!registry.check(1, "infra/main.tf"));
}
