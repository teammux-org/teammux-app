const std = @import("std");

// Module imports
pub const config = @import("config.zig");
pub const worktree = @import("worktree.zig");
pub const pty_mod = @import("pty.zig");
pub const bus = @import("bus.zig");
pub const github = @import("github.zig");
pub const commands = @import("commands.zig");
pub const merge = @import("merge.zig");
pub const ownership = @import("ownership.zig");
pub const interceptor = @import("interceptor.zig");
pub const hotreload = @import("hotreload.zig");
pub const coordinator_mod = @import("coordinator.zig");
pub const worktree_lifecycle = @import("worktree_lifecycle.zig");
pub const history_mod = @import("history.zig");

// ─────────────────────────────────────────────────────────
// Engine struct — central state, owns all module instances
// ─────────────────────────────────────────────────────────

pub const Engine = struct {
    allocator: std.mem.Allocator,
    project_root: []const u8,
    cfg: ?config.Config,
    config_watcher: ?config.ConfigWatcher,
    roster: worktree.Roster,
    ownership_registry: ownership.FileOwnershipRegistry,
    merge_coordinator: merge.MergeCoordinator,
    message_bus: ?bus.MessageBus,
    github_client: github.GitHubClient,
    commands_watcher: ?commands.CommandWatcher,
    role_watchers: hotreload.RoleWatcherMap,
    session_id: [8]u8,
    last_error: ?[]const u8,
    last_error_cstr: ?[*:0]u8,
    last_config_get_cstr: ?[*:0]u8,
    next_sub_id: u32,
    roster_callback: ?*const fn (?*const CRoster, ?*anyopaque) callconv(.c) void,
    roster_userdata: ?*anyopaque,
    config_cb: ?*const fn (?*anyopaque) callconv(.c) void,
    config_cb_userdata: ?*anyopaque,
    msg_cb: ?*const fn (?*const bus.CMessage, ?*anyopaque) callconv(.c) c_int,
    msg_cb_userdata: ?*anyopaque,
    coordinator: coordinator_mod.Coordinator,
    wt_registry: worktree_lifecycle.WorktreeRegistry,
    cmd_cb: ?*const fn (?[*:0]const u8, ?[*:0]const u8, ?*anyopaque) callconv(.c) void,
    cmd_cb_userdata: ?*anyopaque,
    last_wt_path_cstr: ?[*:0]u8,
    last_wt_branch_cstr: ?[*:0]u8,
    history_logger: ?history_mod.HistoryLogger,

    pub fn create(allocator: std.mem.Allocator, project_root: []const u8) !*Engine {
        const engine = try allocator.create(Engine);
        var sid: [8]u8 = undefined;
        bus.generateSessionId(&sid);
        engine.* = .{
            .allocator = allocator,
            .project_root = try allocator.dupe(u8, project_root),
            .cfg = null,
            .config_watcher = null,
            .roster = worktree.Roster.init(allocator),
            .ownership_registry = ownership.FileOwnershipRegistry.init(allocator),
            .merge_coordinator = merge.MergeCoordinator.init(allocator),
            .message_bus = null,
            .github_client = github.GitHubClient.init(allocator, null),
            .commands_watcher = null,
            .role_watchers = hotreload.RoleWatcherMap.init(allocator),
            .session_id = sid,
            .last_error = null,
            .last_error_cstr = null,
            .last_config_get_cstr = null,
            .next_sub_id = 1,
            .roster_callback = null,
            .roster_userdata = null,
            .config_cb = null,
            .config_cb_userdata = null,
            .msg_cb = null,
            .msg_cb_userdata = null,
            .coordinator = coordinator_mod.Coordinator.init(allocator),
            .wt_registry = worktree_lifecycle.WorktreeRegistry.init(allocator),
            .cmd_cb = null,
            .cmd_cb_userdata = null,
            .last_wt_path_cstr = null,
            .last_wt_branch_cstr = null,
            .history_logger = null,
        };
        return engine;
    }

    pub fn destroy(self: *Engine) void {
        hotreload.destroyAll(&self.role_watchers);
        if (self.commands_watcher) |*w| w.deinit();
        if (self.config_watcher) |*w| w.deinit();
        if (self.message_bus) |*b| b.deinit();
        if (self.history_logger) |*h| h.deinit();
        self.github_client.deinit();
        self.coordinator.deinit();
        self.merge_coordinator.deinit();
        self.ownership_registry.deinit();
        self.wt_registry.deinit();
        self.roster.deinit();
        if (self.cfg) |*c| c.deinit(self.allocator);
        if (self.last_error) |e| self.allocator.free(e);
        if (self.last_error_cstr) |c| self.allocator.free(std.mem.span(c));
        if (self.last_config_get_cstr) |c| self.allocator.free(std.mem.span(c));
        if (self.last_wt_path_cstr) |c| self.allocator.free(std.mem.span(c));
        if (self.last_wt_branch_cstr) |c| self.allocator.free(std.mem.span(c));
        self.allocator.free(self.project_root);
        self.allocator.destroy(self);
    }

    /// Return a const pointer to the loaded config, or null if no config loaded.
    pub fn cfgPtr(self: *Engine) ?*const config.Config {
        return if (self.cfg) |*c| c else null;
    }

    /// Cache a Zig slice as a sentinel-terminated C string, freeing the previous value.
    /// Returns the cached [*:0]const u8 pointer, or null on allocation failure.
    fn cacheCstr(self: *Engine, slot: *?[*:0]u8, value: []const u8) ?[*:0]const u8 {
        if (slot.*) |old| { self.allocator.free(std.mem.span(old)); slot.* = null; }
        const z = self.allocator.dupeZ(u8, value) catch return null;
        slot.* = z.ptr;
        return z.ptr;
    }

    pub fn sessionStart(self: *Engine) !void {
        const config_path = try std.fmt.allocPrint(self.allocator, "{s}/.teammux/config.toml", .{self.project_root});
        defer self.allocator.free(config_path);
        const override_path = try std.fmt.allocPrint(self.allocator, "{s}/.teammux/config.local.toml", .{self.project_root});
        defer self.allocator.free(override_path);
        self.cfg = config.loadWithOverrides(self.allocator, config_path, override_path) catch |err| {
            self.setError("config load failed") catch {};
            return err;
        };
        if (self.cfg) |cfg| {
            if (cfg.project.github_repo) |repo| {
                self.github_client.deinit();
                self.github_client = github.GitHubClient.init(self.allocator, repo);
            }
        }
        const log_dir = try std.fmt.allocPrint(self.allocator, "{s}/.teammux/logs", .{self.project_root});
        defer self.allocator.free(log_dir);
        self.message_bus = bus.MessageBus.init(self.allocator, log_dir, &self.session_id, self.project_root) catch |err| {
            self.setError("message bus init failed") catch {};
            return err;
        };
        const cmd_dir = try std.fmt.allocPrint(self.allocator, "{s}/.teammux/commands", .{self.project_root});
        defer self.allocator.free(cmd_dir);
        self.commands_watcher = commands.CommandWatcher.init(self.allocator, cmd_dir) catch |err| {
            self.setError("commands watcher init failed") catch {};
            return err;
        };
        // Wire bus routing for /teammux-complete and /teammux-question
        if (self.commands_watcher) |*w| {
            w.bus_send_fn = busSendBridge;
            w.bus_send_userdata = self;
        }
        // Initialize history logger for completion/question persistence (TD16)
        self.history_logger = history_mod.HistoryLogger.init(self.allocator, self.project_root) catch |err| {
            self.setError("history logger init failed") catch {};
            return err;
        };
        // Wire bus routing for PR status events from GitHub polling
        self.github_client.bus_send_fn = busSendBridge;
        self.github_client.bus_send_userdata = self;
    }

    /// Bridge function for MessageBus routing from both CommandWatcher and GitHubClient.
    /// Called by commands.zig for /teammux-complete and /teammux-question, and by
    /// github.zig for TM_MSG_PR_STATUS events from GitHub polling.
    /// Returns 0 on success, 8 (TM_ERR_BUS) on bus failure, 99 (TM_ERR_UNKNOWN) on invalid input.
    fn busSendBridge(to: u32, from: u32, msg_type: c_int, payload: ?[*:0]const u8, userdata: ?*anyopaque) callconv(.c) c_int {
        const self: *Engine = @ptrCast(@alignCast(userdata orelse return 99));
        const msg_enum = std.meta.intToEnum(bus.MessageType, msg_type) catch {
            self.setError("busSendBridge: invalid message type") catch {};
            return 99;
        };
        var b = &(self.message_bus orelse {
            self.setError("busSendBridge: message bus not initialized") catch {};
            return 8;
        });
        const payload_span = std.mem.span(payload orelse {
            self.setError("busSendBridge: payload is NULL") catch {};
            return 8;
        });
        b.send(to, from, msg_enum, payload_span) catch |err| {
            self.setError(if (err == error.DeliveryFailed) "bus message delivery failed after retries exhausted" else "bus message send failed") catch {};
            return 8;
        };

        // History write for command-file path (workers writing /teammux-complete files).
        // The C API path (tm_worker_complete/tm_worker_question) has its own history write.
        if (msg_enum == .completion or msg_enum == .question) {
            if (self.history_logger) |*logger| {
                const content_key: []const u8 = if (msg_enum == .completion) "summary" else "question";
                const content = commands.extractJsonString(payload_span, content_key) orelse blk: {
                    std.log.warn("[teammux] history: missing '{s}' key in payload, recording empty content", .{content_key});
                    break :blk "";
                };
                const git_commit = if (msg_enum == .completion) blk: {
                    if (self.roster.getWorker(from)) |w| {
                        break :blk history_mod.captureGitCommit(self.allocator, w.worktree_path);
                    }
                    break :blk null;
                } else null;
                defer if (git_commit) |gc| self.allocator.free(gc);
                logger.append(.{
                    .entry_type = if (msg_enum == .completion) .completion else .question,
                    .worker_id = from,
                    .role_id = "",
                    .content = content,
                    .git_commit = git_commit,
                    .timestamp = @intCast(std.time.timestamp()),
                }) catch |err| {
                    std.log.err("[teammux] history append failed in busSendBridge: {}", .{err});
                    self.setError("history persistence failed — event delivered to bus but not written to JSONL log") catch {};
                };
            }
        }

        return 0;
    }

    pub fn sessionStop(self: *Engine) void {
        hotreload.stopAll(&self.role_watchers);
        if (self.commands_watcher) |*w| w.stop();
        if (self.config_watcher) |*w| w.stop();
        self.github_client.stopWebhooks();
    }

    fn setError(self: *Engine, msg: []const u8) !void {
        if (self.last_error) |old| {
            self.allocator.free(old);
            self.last_error = null; // Prevent use-after-free if dupe fails
        }
        self.last_error = try self.allocator.dupe(u8, msg);
    }

    fn nextSubId(self: *Engine) u32 {
        const id = self.next_sub_id;
        self.next_sub_id += 1;
        return id;
    }
};

// ─────────────────────────────────────────────────────────
// C-compatible structs matching teammux.h
// ─────────────────────────────────────────────────────────

const CWorkerInfo = extern struct {
    id: u32, name: ?[*:0]const u8, task_description: ?[*:0]const u8,
    branch_name: ?[*:0]const u8, worktree_path: ?[*:0]const u8,
    status: c_int, agent_type: c_int, agent_binary: ?[*:0]const u8,
    model: ?[*:0]const u8, spawned_at: u64,
};
const CRoster = extern struct { workers: ?[*]const CWorkerInfo, count: u32 };
const CPr = extern struct {
    pr_number: u64, pr_url: ?[*:0]const u8, title: ?[*:0]const u8,
    state: c_int, diff_url: ?[*:0]const u8, worker_id: u32,
};
const CDiffFile = extern struct {
    file_path: ?[*:0]const u8, status: c_int,
    additions: i32, deletions: i32, patch: ?[*:0]const u8,
};
const CDiff = extern struct {
    files: ?[*]CDiffFile, count: u32, total_additions: i32, total_deletions: i32,
};
const CConflict = extern struct {
    file_path: ?[*:0]const u8, conflict_type: ?[*:0]const u8,
    ours: ?[*:0]const u8, theirs: ?[*:0]const u8,
};
const CRole = extern struct {
    id: ?[*:0]const u8, name: ?[*:0]const u8, division: ?[*:0]const u8,
    emoji: ?[*:0]const u8, description: ?[*:0]const u8,
    write_patterns: ?[*]?[*:0]const u8, write_pattern_count: u32,
    deny_write_patterns: ?[*]?[*:0]const u8, deny_write_pattern_count: u32,
    can_push: bool, can_merge: bool,
};
const COwnershipEntry = extern struct {
    path_pattern: ?[*:0]const u8,
    worker_id: u32,
    allow_write: bool,
};
const CDispatchEvent = extern struct {
    target_worker_id: u32,
    instruction: ?[*:0]const u8,
    timestamp: u64,
    delivered: bool,
    kind: u8, // 0 = task, 1 = response
};

// Comptime ABI safety: verify extern struct sizes match expected C layout.
// If a field is added/removed in teammux.h without updating Zig, this fails at build time.
comptime {
    // CWorkerInfo: u32(4) + pad(4) + 5 ptrs(40) + 2 c_int(8) + 2 ptrs(16) + u64(8) = 80... actual 72
    if (@sizeOf(CWorkerInfo) != 72) @compileError("CWorkerInfo size mismatch with tm_worker_info_t");
    // CMessage (bus.zig): u32 + u32 + c_int + ptr + u64 + u64 + ptr = 48 bytes on arm64
    if (@sizeOf(bus.CMessage) != 48) @compileError("CMessage size mismatch with tm_message_t");
    // CConflict: 4 ptrs = 32 bytes on arm64
    if (@sizeOf(CConflict) != 32) @compileError("CConflict size mismatch with tm_conflict_t");
    // CRole: 5 ptrs + 2*(ptr + u32) + 2 bools + pad = 72 bytes on arm64
    if (@sizeOf(CRole) != 72) @compileError("CRole size mismatch with tm_role_t");
    // COwnershipEntry: ptr(8) + u32(4) + bool(1) + pad(3) = 16 bytes on arm64
    if (@sizeOf(COwnershipEntry) != 16) @compileError("COwnershipEntry size mismatch with tm_ownership_entry_t");
    // CCompletion: u32(4) + pad(4) + 3 ptrs(24) + u64(8) = 40 bytes on arm64
    if (@sizeOf(CCompletion) != 40) @compileError("CCompletion size mismatch with tm_completion_t");
    // CQuestion: u32(4) + pad(4) + 2 ptrs(16) + u64(8) = 32 bytes on arm64
    if (@sizeOf(CQuestion) != 32) @compileError("CQuestion size mismatch with tm_question_t");
    // CDispatchEvent: u32(4) + pad(4) + ptr(8) + u64(8) + bool(1) + u8(1) + pad(6) = 32 bytes on arm64
    if (@sizeOf(CDispatchEvent) != 32) @compileError("CDispatchEvent size mismatch with tm_dispatch_event_t");
    // CHistoryEntry: ptr(8) + u32(4) + pad(4) + 3 ptrs(24) + u64(8) = 48 bytes on arm64
    if (@sizeOf(CHistoryEntry) != 48) @compileError("CHistoryEntry size mismatch with tm_history_entry_t");
}

var last_create_error: [*:0]const u8 = "no error";

// ─── Engine lifecycle ────────────────────────────────────

export fn tm_engine_create(project_root: ?[*:0]const u8, out: ?*?*Engine) c_int {
    if (out) |p| p.* = null;
    const root = std.mem.span(project_root orelse { last_create_error = "project_root is NULL"; return 99; });
    const engine = Engine.create(std.heap.c_allocator, root) catch { last_create_error = "engine allocation failed"; return 99; };
    if (out) |p| p.* = engine;
    return 0;
}
export fn tm_engine_destroy(engine: ?*Engine) void { if (engine) |e| e.destroy(); }
export fn tm_session_start(engine: ?*Engine) c_int {
    const e = engine orelse return 99;
    // sessionStart sets last_error with specific message before returning
    e.sessionStart() catch |err| return switch (err) {
        error.FileNotFound => 7, // TM_ERR_CONFIG — config file missing
        error.OutOfMemory => 99,
        else => 99,
    };
    return 0;
}
export fn tm_session_stop(engine: ?*Engine) void { if (engine) |e| e.sessionStop(); }
export fn tm_engine_last_error(engine: ?*Engine) [*:0]const u8 {
    const e = engine orelse return last_create_error;
    if (e.last_error_cstr) |old| { e.allocator.free(std.mem.span(old)); e.last_error_cstr = null; }
    if (e.last_error) |err| {
        const z = e.allocator.dupeZ(u8, err) catch return "allocation failed";
        e.last_error_cstr = z.ptr;
        return z.ptr;
    }
    return "no error";
}

// ─── Config ──────────────────────────────────────────────

export fn tm_config_reload(engine: ?*Engine) c_int {
    const e = engine orelse return 99;
    const p1 = std.fmt.allocPrint(e.allocator, "{s}/.teammux/config.toml", .{e.project_root}) catch return 7;
    defer e.allocator.free(p1);
    const p2 = std.fmt.allocPrint(e.allocator, "{s}/.teammux/config.local.toml", .{e.project_root}) catch return 7;
    defer e.allocator.free(p2);
    if (e.cfg) |*old| old.deinit(e.allocator);
    e.cfg = config.loadWithOverrides(e.allocator, p1, p2) catch { e.setError("config reload failed") catch {}; return 7; };
    return 0;
}
export fn tm_config_watch(engine: ?*Engine, callback: ?*const fn (?*anyopaque) callconv(.c) void, userdata: ?*anyopaque) u32 {
    const e = engine orelse return 0;
    e.config_cb = callback; e.config_cb_userdata = userdata;
    return e.nextSubId();
}
export fn tm_config_unwatch(engine: ?*Engine, sub: u32) void {
    _ = sub; const e = engine orelse return; e.config_cb = null; e.config_cb_userdata = null;
}
export fn tm_config_get(engine: ?*Engine, key: ?[*:0]const u8) ?[*:0]const u8 {
    const e = engine orelse return null;
    if (e.last_config_get_cstr) |old| { e.allocator.free(std.mem.span(old)); e.last_config_get_cstr = null; }
    const k = std.mem.span(key orelse return null);
    const cfg = &(e.cfg orelse return null);
    const val = config.get(cfg, k) orelse return null;
    const z = e.allocator.dupeZ(u8, val) catch return null;
    e.last_config_get_cstr = z.ptr;
    return z.ptr;
}

// ─── Worktree ────────────────────────────────────────────

export fn tm_worker_spawn(engine: ?*Engine, agent_binary: ?[*:0]const u8, agent_type: c_int, worker_name: ?[*:0]const u8, task_description: ?[*:0]const u8) u32 {
    const e = engine orelse return 0xFFFFFFFF;
    const td = std.mem.span(task_description orelse return 0xFFFFFFFF);

    const id = e.roster.spawn(e.project_root, std.mem.span(agent_binary orelse return 0xFFFFFFFF), @enumFromInt(agent_type), std.mem.span(worker_name orelse return 0xFFFFFFFF), td) catch |err| {
        e.setError(switch (err) { error.GitFailed => "git worktree add failed", else => "worker spawn failed" }) catch {};
        return 0xFFFFFFFF;
    };

    // Create lifecycle worktree AFTER roster spawn using actual ID — graceful degradation on failure
    worktree_lifecycle.create(&e.wt_registry, e.cfgPtr(), e.project_root, id, td) catch |err| {
        std.log.warn("[teammux] worktree lifecycle create failed for worker {d}: {s}", .{ id, @errorName(err) });
        e.setError("worker spawned but worktree lifecycle create failed") catch {};
    };

    return id;
}
export fn tm_worker_dismiss(engine: ?*Engine, worker_id: u32) c_int {
    const e = engine orelse return 99;
    // Stop and remove role watcher before dismiss
    if (e.role_watchers.fetchRemove(worker_id)) |kv| {
        kv.value.destroy();
    }
    // Remove interceptor wrapper before worktree is deleted
    if (e.roster.getWorker(worker_id)) |w| {
        interceptor.remove(e.allocator, w.worktree_path) catch |err| {
            std.log.warn("[teammux] interceptor remove failed for worker {d}: {}", .{ worker_id, err });
        };
    }
    e.roster.dismiss(e.project_root, worker_id) catch { e.setError("worker dismiss failed") catch {}; return 5; };
    e.ownership_registry.release(worker_id);
    // Remove lifecycle worktree AFTER roster dismiss
    worktree_lifecycle.removeWorker(&e.wt_registry, e.project_root, worker_id);
    return 0;
}

// ─── Worktree lifecycle ──────────────────────────────────

export fn tm_worktree_create(engine: ?*Engine, worker_id: u32, task_description: ?[*:0]const u8) c_int {
    const e = engine orelse return 99;
    const td = std.mem.span(task_description orelse {
        e.setError("tm_worktree_create: task_description must not be NULL") catch {};
        return 7; // TM_ERR_CONFIG
    });
    worktree_lifecycle.create(&e.wt_registry, e.cfgPtr(), e.project_root, worker_id, td) catch |err| {
        e.setError(switch (err) {
            error.GitFailed => "git worktree add failed",
            error.NoHomeDir => "HOME not set, cannot resolve worktree root",
            error.MkdirFailed => "failed to create worktree directory",
            else => "worktree create failed",
        }) catch {};
        return switch (err) {
            error.NoHomeDir, error.MkdirFailed => 7, // TM_ERR_CONFIG
            else => 5, // TM_ERR_WORKTREE
        };
    };
    return 0;
}

export fn tm_worktree_remove(engine: ?*Engine, worker_id: u32) c_int {
    const e = engine orelse return 99;
    worktree_lifecycle.removeWorker(&e.wt_registry, e.project_root, worker_id);
    return 0;
}

export fn tm_worktree_path(engine: ?*Engine, worker_id: u32) ?[*:0]const u8 {
    const e = engine orelse return null;
    const path = worktree_lifecycle.getPath(&e.wt_registry, worker_id) orelse return null;
    return e.cacheCstr(&e.last_wt_path_cstr, path);
}

export fn tm_worktree_branch(engine: ?*Engine, worker_id: u32) ?[*:0]const u8 {
    const e = engine orelse return null;
    const branch = worktree_lifecycle.getBranch(&e.wt_registry, worker_id) orelse return null;
    return e.cacheCstr(&e.last_wt_branch_cstr, branch);
}
export fn tm_roster_get(engine: ?*Engine) ?*CRoster {
    const e = engine orelse return null;
    const alloc = e.allocator;
    const count = e.roster.count();
    const c_roster = alloc.create(CRoster) catch return null;
    const c_workers = alloc.alloc(CWorkerInfo, count) catch { alloc.destroy(c_roster); return null; };
    var idx: usize = 0;
    var it = e.roster.workers.iterator();
    while (it.next()) |entry| {
        c_workers[idx] = fillCWorkerInfo(alloc, entry.value_ptr) catch {
            for (0..idx) |j| freeCWorkerInfo(c_workers[j]);
            alloc.free(c_workers); alloc.destroy(c_roster); return null;
        };
        idx += 1;
    }
    c_roster.* = .{ .workers = c_workers.ptr, .count = count };
    return c_roster;
}
export fn tm_roster_free(roster: ?*CRoster) void {
    if (roster) |r| {
        if (r.workers) |workers| {
            for (0..r.count) |i| freeCWorkerInfo(@constCast(workers)[i]);
            std.heap.c_allocator.free(@constCast(workers)[0..r.count]);
        }
        std.heap.c_allocator.destroy(r);
    }
}
export fn tm_worker_get(engine: ?*Engine, worker_id: u32) ?*CWorkerInfo {
    const e = engine orelse return null;
    const w = e.roster.getWorker(worker_id) orelse return null;
    const info = e.allocator.create(CWorkerInfo) catch return null;
    info.* = fillCWorkerInfo(e.allocator, w) catch { e.allocator.destroy(info); return null; };
    return info;
}
export fn tm_worker_info_free(info: ?*CWorkerInfo) void {
    if (info) |i| { freeCWorkerInfo(i.*); std.heap.c_allocator.destroy(i); }
}
export fn tm_roster_watch(engine: ?*Engine, callback: ?*const fn (?*const CRoster, ?*anyopaque) callconv(.c) void, userdata: ?*anyopaque) u32 {
    const e = engine orelse return 0;
    e.roster_callback = callback; e.roster_userdata = userdata;
    return e.nextSubId();
}
export fn tm_roster_unwatch(engine: ?*Engine, sub: u32) void {
    _ = sub; const e = engine orelse return; e.roster_callback = null; e.roster_userdata = null;
}

// ─── PTY (deprecated — Ghostty owns PTY) ─────────────────

export fn tm_pty_send(_: ?*Engine, _: u32, _: ?[*:0]const u8) c_int {
    return 10; // TM_ERR_NOT_IMPLEMENTED — PTY owned by Ghostty SurfaceView
}
export fn tm_pty_fd(_: ?*Engine, _: u32) c_int {
    return -1; // PTY owned by Ghostty SurfaceView
}

// ─── Message bus ─────────────────────────────────────────

export fn tm_message_send(engine: ?*Engine, target_worker_id: u32, msg_type: c_int, payload: ?[*:0]const u8) c_int {
    const e = engine orelse return 99;
    var b = &(e.message_bus orelse return 8);
    b.send(target_worker_id, 0, @enumFromInt(msg_type), std.mem.span(payload orelse return 8)) catch |err| {
        e.setError(if (err == error.DeliveryFailed) "message delivery failed after 4 attempts" else "message send failed") catch {};
        return 8;
    };
    return 0;
}
export fn tm_message_broadcast(engine: ?*Engine, msg_type: c_int, payload: ?[*:0]const u8) c_int {
    const e = engine orelse return 99;
    var b = &(e.message_bus orelse return 8);
    b.broadcast(0, @enumFromInt(msg_type), std.mem.span(payload orelse return 8), &e.roster) catch { e.setError("message broadcast failed") catch {}; return 8; };
    return 0;
}
export fn tm_message_subscribe(engine: ?*Engine, callback: ?*const fn (?*const bus.CMessage, ?*anyopaque) callconv(.c) c_int, userdata: ?*anyopaque) u32 {
    const e = engine orelse return 0;
    e.msg_cb = callback; e.msg_cb_userdata = userdata;
    if (e.message_bus) |*b| b.subscribe(callback, userdata);
    return e.nextSubId();
}
export fn tm_message_unsubscribe(engine: ?*Engine, sub: u32) void {
    _ = sub; const e = engine orelse return;
    e.msg_cb = null; e.msg_cb_userdata = null;
    if (e.message_bus) |*b| b.subscribe(null, null);
}

// ─── GitHub ──────────────────────────────────────────────

export fn tm_github_auth(engine: ?*Engine) c_int {
    const e = engine orelse return 99;
    e.github_client.auth(if (e.cfg) |cfg| cfg.github_token else null) catch {
        e.setError("GitHub auth failed: run `gh auth login` or set [github] token in config.toml") catch {};
        return 3; // TM_ERR_GH_UNAUTH
    };
    return 0;
}
export fn tm_github_is_authed(engine: ?*Engine) bool { return if (engine) |e| e.github_client.isAuthed() else false; }
export fn tm_github_create_pr(engine: ?*Engine, worker_id: u32, title: ?[*:0]const u8, body: ?[*:0]const u8) ?*CPr {
    const e = engine orelse return null;
    const w = e.roster.getWorker(worker_id) orelse {
        e.setError("PR creation failed: worker not found") catch {};
        return null;
    };
    const alloc = e.allocator;
    const title_slice = std.mem.span(title orelse {
        e.setError("PR creation failed: title is NULL") catch {};
        return null;
    });
    const body_slice = std.mem.span(body orelse {
        e.setError("PR creation failed: body is NULL") catch {};
        return null;
    });
    const branch_name = w.branch_name;
    const pr = e.github_client.createPr(alloc, branch_name, title_slice, body_slice) catch {
        e.setError("PR creation failed: gh CLI error") catch {};
        routePrError(e, worker_id, "gh pr create failed");
        return null;
    };

    // Route TM_MSG_PR_READY=14 through bus immediately after creation succeeds.
    // Done before C struct allocation so bus notification is not lost if alloc fails.
    routePrReady(e, worker_id, pr.url, branch_name, title_slice);

    const c_pr = alloc.create(CPr) catch return null;
    const url_z = alloc.dupeZ(u8, pr.url) catch { alloc.destroy(c_pr); return null; };
    const title_z = alloc.dupeZ(u8, pr.title) catch { alloc.free(url_z); alloc.destroy(c_pr); return null; };
    const diff_z = alloc.dupeZ(u8, pr.diff_url) catch { alloc.free(title_z); alloc.free(url_z); alloc.destroy(c_pr); return null; };
    c_pr.* = .{ .pr_number = pr.pr_number, .pr_url = url_z.ptr, .title = title_z.ptr, .state = 0, .diff_url = diff_z.ptr, .worker_id = worker_id };

    alloc.free(pr.url); alloc.free(pr.title); alloc.free(pr.state); alloc.free(pr.diff_url);
    return c_pr;
}

/// Forwarding wrapper for tm_github_create_pr. The branch parameter is unused;
/// the actual branch is resolved from the roster via worker_id.
export fn tm_pr_create(engine: ?*Engine, worker_id: u32, title: ?[*:0]const u8, body: ?[*:0]const u8, _: ?[*:0]const u8) ?*CPr {
    return tm_github_create_pr(engine, worker_id, title, body);
}
export fn tm_pr_free(pr: ?*CPr) void {
    if (pr) |p| { freeNullTerminated(p.pr_url); freeNullTerminated(p.title); freeNullTerminated(p.diff_url); std.heap.c_allocator.destroy(p); }
}
export fn tm_github_merge_pr(engine: ?*Engine, pr_number: u64, strategy: c_int) c_int {
    const e = engine orelse return 99;
    e.github_client.mergePr(e.allocator, pr_number, @enumFromInt(strategy)) catch {
        e.setError("PR merge failed: gh CLI error") catch {};
        return 9; // TM_ERR_GITHUB
    };
    return 0;
}
export fn tm_github_get_diff(engine: ?*Engine, worker_id: u32) ?*CDiff {
    const e = engine orelse return null;
    const w = e.roster.getWorker(worker_id) orelse {
        e.setError("diff failed: worker not found") catch {};
        return null;
    };
    _ = e.github_client.getDiff(e.allocator, w.branch_name) catch {
        // getDiff returns NotImplemented in v0.1 — this is expected
        e.setError("diff view not yet available (v0.2)") catch {};
        return null;
    };
    unreachable; // getDiff always returns error.NotImplemented in v0.1
}
export fn tm_diff_free(diff: ?*CDiff) void { if (diff) |d| std.heap.c_allocator.destroy(d); }
export fn tm_github_webhooks_start(engine: ?*Engine, callback: ?*const fn (?[*:0]const u8, ?[*:0]const u8, ?*anyopaque) callconv(.c) void, userdata: ?*anyopaque) u32 {
    const e = engine orelse return 0;
    e.github_client.startWebhooks(e.allocator, callback, userdata) catch {
        e.setError("webhook forward failed") catch {};
        return 0;
    };
    return e.nextSubId();
}
export fn tm_github_webhooks_stop(engine: ?*Engine, sub: u32) void { _ = sub; if (engine) |e| e.github_client.stopWebhooks(); }

// ─── Commands ────────────────────────────────────────────

// Command routing wrapper — add new /teammux-* command handlers as additional branches below.
fn commandRoutingCallback(command_ptr: ?[*:0]const u8, args_ptr: ?[*:0]const u8, userdata: ?*anyopaque) callconv(.c) void {
    const engine: *Engine = @ptrCast(@alignCast(userdata orelse {
        std.log.warn("[teammux] commandRoutingCallback: null userdata (engine pointer missing)", .{});
        return;
    }));
    const cmd = std.mem.span(command_ptr orelse {
        std.log.warn("[teammux] commandRoutingCallback: null command pointer", .{});
        return;
    });

    if (std.mem.eql(u8, cmd, "/teammux-assign")) {
        handleAssignCommand(engine, args_ptr);
        return;
    }
    if (std.mem.eql(u8, cmd, "/teammux-ask")) {
        handlePeerQuestionCommand(engine, args_ptr);
        return;
    }
    if (std.mem.eql(u8, cmd, "/teammux-delegate")) {
        handleDelegationCommand(engine, args_ptr);
        return;
    }
    if (std.mem.eql(u8, cmd, "/teammux-pr-ready")) {
        handlePrReadyCommand(engine, args_ptr);
        return;
    }

    // Forward unhandled commands to Swift callback
    if (engine.cmd_cb) |cb| cb(command_ptr, args_ptr, engine.cmd_cb_userdata);
}

fn handleAssignCommand(engine: *Engine, args_ptr: ?[*:0]const u8) void {
    const args = std.mem.span(args_ptr orelse {
        std.log.warn("[teammux] /teammux-assign: args is NULL (expected JSON body)", .{});
        return;
    });

    // Parse target_worker_id (integer or string) from JSON
    const id_str = extractJsonStringValue(args, "target_worker_id") orelse
        extractJsonNumber(args, "target_worker_id");
    if (id_str == null) {
        std.log.warn("[teammux] /teammux-assign: missing target_worker_id", .{});
        return;
    }
    const worker_id = std.fmt.parseInt(u32, id_str.?, 10) catch {
        std.log.warn("[teammux] /teammux-assign: invalid target_worker_id", .{});
        return;
    };

    const instruction = extractJsonStringValue(args, "instruction") orelse {
        std.log.warn("[teammux] /teammux-assign: missing instruction", .{});
        return;
    };

    const b = &(engine.message_bus orelse {
        std.log.warn("[teammux] /teammux-assign: message bus not available", .{});
        return;
    });
    engine.coordinator.dispatchTask(&engine.roster, b, worker_id, instruction) catch |err| {
        if (err == error.WorkerNotFound) {
            std.log.warn("[teammux] /teammux-assign: worker {d} not found in roster", .{worker_id});
        } else {
            std.log.warn("[teammux] /teammux-assign: dispatch to worker {d} failed: {s}", .{ worker_id, @errorName(err) });
        }
    };
}

fn handlePeerQuestionCommand(engine: *Engine, args_ptr: ?[*:0]const u8) void {
    const args = std.mem.span(args_ptr orelse {
        std.log.warn("[teammux] /teammux-ask: args is NULL (expected JSON body)", .{});
        return;
    });

    const from_id_str = extractJsonStringValue(args, "worker_id") orelse
        extractJsonNumber(args, "worker_id");
    if (from_id_str == null) {
        std.log.warn("[teammux] /teammux-ask: missing worker_id", .{});
        return;
    }
    const from_id = std.fmt.parseInt(u32, from_id_str.?, 10) catch {
        std.log.warn("[teammux] /teammux-ask: invalid worker_id", .{});
        return;
    };

    const target_id_str = extractJsonStringValue(args, "target_worker_id") orelse
        extractJsonNumber(args, "target_worker_id");
    if (target_id_str == null) {
        std.log.warn("[teammux] /teammux-ask: missing target_worker_id", .{});
        return;
    }
    const target_id = std.fmt.parseInt(u32, target_id_str.?, 10) catch {
        std.log.warn("[teammux] /teammux-ask: invalid target_worker_id", .{});
        return;
    };

    if (from_id == 0) {
        std.log.warn("[teammux] /teammux-ask: Team Lead (worker 0) cannot send peer questions — use tm_dispatch_response", .{});
        return;
    }

    if (from_id == target_id) {
        std.log.warn("[teammux] /teammux-ask: cannot ask yourself (worker {d})", .{from_id});
        return;
    }

    if (engine.roster.getWorker(from_id) == null) {
        std.log.warn("[teammux] /teammux-ask: sender worker {d} not found in roster", .{from_id});
        return;
    }

    if (engine.roster.getWorker(target_id) == null) {
        std.log.warn("[teammux] /teammux-ask: target worker {d} not found in roster", .{target_id});
        return;
    }

    // Validate message field exists (value not needed — we forward raw args as payload)
    _ = extractJsonStringValue(args, "message") orelse {
        std.log.warn("[teammux] /teammux-ask: missing message", .{});
        return;
    };

    var b = &(engine.message_bus orelse {
        std.log.warn("[teammux] /teammux-ask: message bus not available", .{});
        return;
    });
    // Route to Team Lead (worker 0) — Team Lead relays to target
    b.send(0, from_id, .peer_question, args) catch |err| {
        std.log.warn("[teammux] /teammux-ask: bus send failed: {s}", .{@errorName(err)});
        // Notify sender that delivery failed
        b.send(from_id, 0, .err, "\"[Teammux] peer message delivery failed\"") catch {};
    };
}

fn handleDelegationCommand(engine: *Engine, args_ptr: ?[*:0]const u8) void {
    const args = std.mem.span(args_ptr orelse {
        std.log.warn("[teammux] /teammux-delegate: args is NULL (expected JSON body)", .{});
        return;
    });

    const from_id_str = extractJsonStringValue(args, "worker_id") orelse
        extractJsonNumber(args, "worker_id");
    if (from_id_str == null) {
        std.log.warn("[teammux] /teammux-delegate: missing worker_id", .{});
        return;
    }
    const from_id = std.fmt.parseInt(u32, from_id_str.?, 10) catch {
        std.log.warn("[teammux] /teammux-delegate: invalid worker_id", .{});
        return;
    };

    const target_id_str = extractJsonStringValue(args, "target_worker_id") orelse
        extractJsonNumber(args, "target_worker_id");
    if (target_id_str == null) {
        std.log.warn("[teammux] /teammux-delegate: missing target_worker_id", .{});
        return;
    }
    const target_id = std.fmt.parseInt(u32, target_id_str.?, 10) catch {
        std.log.warn("[teammux] /teammux-delegate: invalid target_worker_id", .{});
        return;
    };

    if (from_id == 0) {
        std.log.warn("[teammux] /teammux-delegate: Team Lead (worker 0) cannot delegate — use tm_dispatch_task", .{});
        return;
    }

    if (from_id == target_id) {
        std.log.warn("[teammux] /teammux-delegate: cannot delegate to yourself (worker {d})", .{from_id});
        return;
    }

    if (engine.roster.getWorker(from_id) == null) {
        std.log.warn("[teammux] /teammux-delegate: sender worker {d} not found in roster", .{from_id});
        return;
    }

    if (engine.roster.getWorker(target_id) == null) {
        std.log.warn("[teammux] /teammux-delegate: target worker {d} not found in roster", .{target_id});
        return;
    }

    // Validate task field exists (value not needed — we forward raw args as payload)
    _ = extractJsonStringValue(args, "task") orelse {
        std.log.warn("[teammux] /teammux-delegate: missing task", .{});
        return;
    };

    var b = &(engine.message_bus orelse {
        std.log.warn("[teammux] /teammux-delegate: message bus not available", .{});
        return;
    });
    // Route directly to target worker PTY
    b.send(target_id, from_id, .delegation, args) catch |err| {
        std.log.warn("[teammux] /teammux-delegate: bus send failed: {s}", .{@errorName(err)});
        // Notify sender that delivery failed
        b.send(from_id, 0, .err, "\"[Teammux] peer message delivery failed\"") catch {};
    };
}

/// Handle /teammux-pr-ready command. Parses worker_id, title, and summary from JSON args,
/// then delegates to tm_github_create_pr (which routes TM_MSG_PR_READY on success, TM_MSG_ERROR on failure).
fn handlePrReadyCommand(engine: *Engine, args_ptr: ?[*:0]const u8) void {
    const args = std.mem.span(args_ptr orelse {
        std.log.warn("[teammux] /teammux-pr-ready: args is NULL (expected JSON body)", .{});
        return;
    });

    // Parse worker_id
    const id_str = extractJsonStringValue(args, "worker_id") orelse
        extractJsonNumber(args, "worker_id");
    if (id_str == null) {
        std.log.warn("[teammux] /teammux-pr-ready: missing worker_id", .{});
        return;
    }
    const worker_id = std.fmt.parseInt(u32, id_str.?, 10) catch {
        std.log.warn("[teammux] /teammux-pr-ready: invalid worker_id", .{});
        return;
    };

    const title_val = extractJsonStringValue(args, "title") orelse {
        std.log.warn("[teammux] /teammux-pr-ready: missing title", .{});
        return;
    };
    const summary = extractJsonStringValue(args, "summary") orelse "";

    // Create PR via tm_github_create_pr (which also routes TM_MSG_PR_READY)
    const title_z = engine.allocator.dupeZ(u8, title_val) catch {
        std.log.warn("[teammux] /teammux-pr-ready: alloc failed", .{});
        return;
    };
    defer engine.allocator.free(title_z);
    const summary_z = engine.allocator.dupeZ(u8, summary) catch {
        std.log.warn("[teammux] /teammux-pr-ready: alloc failed", .{});
        return;
    };
    defer engine.allocator.free(summary_z);

    const result = tm_github_create_pr(engine, worker_id, title_z.ptr, summary_z.ptr);
    if (result) |pr| {
        tm_pr_free(pr);
    } else {
        std.log.warn("[teammux] /teammux-pr-ready: PR creation failed for worker {d}", .{worker_id});
    }
}

/// Route TM_MSG_PR_READY=14 through the bus after successful PR creation.
/// Best-effort — the PR already exists on GitHub regardless of bus delivery.
fn routePrReady(engine: *Engine, worker_id: u32, pr_url: []const u8, branch: []const u8, title_slice: []const u8) void {
    var b = &(engine.message_bus orelse {
        std.log.warn("[teammux] routePrReady: bus not initialized, TM_MSG_PR_READY for worker {d} dropped", .{worker_id});
        return;
    });
    // Escape title for safe JSON interpolation (user-controlled input may contain quotes)
    const escaped_title = jsonEscape(engine.allocator, title_slice) catch {
        std.log.warn("[teammux] routePrReady: title escape failed for worker {d}", .{worker_id});
        return;
    };
    defer engine.allocator.free(escaped_title);
    const payload = std.fmt.allocPrint(engine.allocator,
        \\{{"worker_id":{d},"pr_url":"{s}","branch":"{s}","title":"{s}"}}
    , .{ worker_id, pr_url, branch, escaped_title }) catch {
        std.log.warn("[teammux] routePrReady: payload allocation failed for worker {d}", .{worker_id});
        return;
    };
    defer engine.allocator.free(payload);
    b.send(0, worker_id, .pr_ready, payload) catch |err| {
        std.log.warn("[teammux] TM_MSG_PR_READY bus send failed: {s}", .{@errorName(err)});
    };
}

/// Route TM_MSG_ERROR through the bus when PR creation fails.
fn routePrError(engine: *Engine, worker_id: u32, message: []const u8) void {
    var b = &(engine.message_bus orelse {
        std.log.warn("[teammux] routePrError: bus not initialized, TM_MSG_ERROR for worker {d} dropped", .{worker_id});
        return;
    });
    const payload = std.fmt.allocPrint(engine.allocator,
        \\{{"worker_id":{d},"error":"{s}"}}
    , .{ worker_id, message }) catch {
        std.log.warn("[teammux] routePrError: payload allocation failed for worker {d}", .{worker_id});
        return;
    };
    defer engine.allocator.free(payload);
    b.send(0, worker_id, .err, payload) catch |err| {
        std.log.warn("[teammux] TM_MSG_ERROR bus send failed for worker {d}: {s}", .{ worker_id, @errorName(err) });
    };
}

/// Extract a quoted string value for a given key from JSON.
/// Handles: {"key": "value"}. Respects backslash escapes within values.
fn extractJsonStringValue(json: []const u8, key: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, search) orelse return null;
    const after_key = json[key_pos + search.len ..];

    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ':' or after_key[i] == ' ' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}
    if (i >= after_key.len or after_key[i] != '"') return null;
    i += 1; // skip opening quote

    const start = i;
    while (i < after_key.len) : (i += 1) {
        if (after_key[i] == '\\' and i + 1 < after_key.len) {
            i += 1;
            continue;
        }
        if (after_key[i] == '"') break;
    }
    if (i >= after_key.len) return null;
    return after_key[start..i];
}

/// Extract a bare non-negative integer for a given key from JSON.
/// Handles: {"key": 42} (digits only, no quotes).
fn extractJsonNumber(json: []const u8, key: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, search) orelse return null;
    const after_key = json[key_pos + search.len ..];

    // Skip colon and whitespace
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ':' or after_key[i] == ' ' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}
    if (i >= after_key.len) return null;

    // Must start with a digit
    if (!std.ascii.isDigit(after_key[i])) return null;
    const start = i;
    while (i < after_key.len and std.ascii.isDigit(after_key[i])) : (i += 1) {}
    return after_key[start..i];
}

export fn tm_commands_watch(engine: ?*Engine, callback: ?*const fn (?[*:0]const u8, ?[*:0]const u8, ?*anyopaque) callconv(.c) void, userdata: ?*anyopaque) u32 {
    const e = engine orelse return 0;
    // Store Swift callback for forwarding from commandRoutingCallback
    e.cmd_cb = callback;
    e.cmd_cb_userdata = userdata;
    if (e.commands_watcher) |*w| {
        w.start(commandRoutingCallback, e) catch {
            e.setError("commands watcher start failed") catch {};
            return 0;
        };
        return e.nextSubId();
    }
    e.setError("commands watcher not available (call tm_session_start first)") catch {};
    return 0;
}
export fn tm_commands_unwatch(engine: ?*Engine, sub: u32) void {
    _ = sub;
    const e = engine orelse return;
    if (e.commands_watcher) |*w| w.stop();
    e.cmd_cb = null;
    e.cmd_cb_userdata = null;
}

// ─── Coordinator — Team Lead dispatch ────────────────────

export fn tm_dispatch_task(engine: ?*Engine, target_worker_id: u32, instruction: ?[*:0]const u8) c_int {
    const e = engine orelse return 99;
    const b = &(e.message_bus orelse {
        e.setError("tm_dispatch_task: message bus not available (call tm_session_start first)") catch {};
        return 8; // TM_ERR_BUS
    });
    e.coordinator.dispatchTask(&e.roster, b, target_worker_id, std.mem.span(instruction orelse {
        e.setError("tm_dispatch_task: instruction must not be NULL") catch {};
        return 99;
    })) catch |err| {
        if (err == error.WorkerNotFound) {
            e.setError("tm_dispatch_task: worker not found") catch {};
            return 12; // TM_ERR_INVALID_WORKER
        }
        e.setError("tm_dispatch_task: dispatch failed") catch {};
        return 8;
    };
    return 0;
}

export fn tm_dispatch_response(engine: ?*Engine, target_worker_id: u32, response: ?[*:0]const u8) c_int {
    const e = engine orelse return 99;
    const b = &(e.message_bus orelse {
        e.setError("tm_dispatch_response: message bus not available") catch {};
        return 8;
    });
    e.coordinator.dispatchResponse(&e.roster, b, target_worker_id, std.mem.span(response orelse {
        e.setError("tm_dispatch_response: response must not be NULL") catch {};
        return 99;
    })) catch |err| {
        if (err == error.WorkerNotFound) {
            e.setError("tm_dispatch_response: worker not found") catch {};
            return 12; // TM_ERR_INVALID_WORKER
        }
        e.setError("tm_dispatch_response: dispatch failed") catch {};
        return 8;
    };
    return 0;
}

export fn tm_dispatch_history(engine: ?*Engine, count: ?*u32) ?[*]?*CDispatchEvent {
    if (count) |c| c.* = 0;
    const e = engine orelse return null;
    const alloc = std.heap.c_allocator; // must match tm_dispatch_history_free

    const history = e.coordinator.getHistory();
    if (history.len == 0) return null;

    const ptrs = alloc.alloc(?*CDispatchEvent, history.len) catch {
        e.setError("tm_dispatch_history: allocation failed") catch {};
        return null;
    };
    var filled: usize = 0;

    for (history) |event| {
        const entry = alloc.create(CDispatchEvent) catch {
            for (0..filled) |j| freeCDispatchEvent(ptrs[j]);
            alloc.free(ptrs);
            e.setError("tm_dispatch_history: allocation failed") catch {};
            return null;
        };
        const instr_z = alloc.dupeZ(u8, event.instruction) catch {
            alloc.destroy(entry);
            for (0..filled) |j| freeCDispatchEvent(ptrs[j]);
            alloc.free(ptrs);
            e.setError("tm_dispatch_history: allocation failed") catch {};
            return null;
        };
        entry.* = .{
            .target_worker_id = event.target_worker_id,
            .instruction = instr_z.ptr,
            .timestamp = event.timestamp,
            .delivered = event.delivered,
            .kind = @intFromEnum(event.kind),
        };
        ptrs[filled] = entry;
        filled += 1;
    }

    if (count) |c| c.* = @intCast(history.len);
    return ptrs.ptr;
}

export fn tm_dispatch_history_free(events: ?[*]?*CDispatchEvent, count: u32) void {
    const ptrs = events orelse return;
    for (0..count) |i| freeCDispatchEvent(ptrs[i]);
    std.heap.c_allocator.free(ptrs[0..count]);
}

fn freeCDispatchEvent(ptr: ?*CDispatchEvent) void {
    const entry = ptr orelse return;
    freeNullTerminated(entry.instruction);
    std.heap.c_allocator.destroy(entry);
}

// ─── Peer messaging — worker-to-worker ───────────────────

export fn tm_peer_question(engine: ?*Engine, from_id: u32, target_id: u32, message: ?[*:0]const u8) c_int {
    const e = engine orelse return 99; // TM_ERR_UNKNOWN
    const msg = std.mem.span(message orelse {
        e.setError("tm_peer_question: message is NULL") catch {};
        return 99;
    });

    if (from_id == 0) {
        e.setError("tm_peer_question: Team Lead cannot send peer questions") catch {};
        return 12; // TM_ERR_INVALID_WORKER
    }
    if (from_id == target_id) {
        e.setError("tm_peer_question: cannot ask yourself") catch {};
        return 12; // TM_ERR_INVALID_WORKER
    }
    if (e.roster.getWorker(from_id) == null) {
        e.setError("tm_peer_question: sender worker not found") catch {};
        return 12; // TM_ERR_INVALID_WORKER
    }
    if (e.roster.getWorker(target_id) == null) {
        e.setError("tm_peer_question: target worker not found") catch {};
        return 12; // TM_ERR_INVALID_WORKER
    }

    var b = &(e.message_bus orelse {
        e.setError("tm_peer_question: message bus not initialized") catch {};
        return 8; // TM_ERR_BUS
    });

    // Build payload JSON: {"worker_id": from, "target_worker_id": target, "message": "..."}
    const msg_esc = jsonEscape(std.heap.c_allocator, msg) catch {
        e.setError("tm_peer_question: payload allocation failed") catch {};
        return 99;
    };
    defer std.heap.c_allocator.free(msg_esc);

    const payload = std.fmt.allocPrint(std.heap.c_allocator,
        \\{{"worker_id":{d},"target_worker_id":{d},"message":"{s}"}}
    , .{ from_id, target_id, msg_esc }) catch {
        e.setError("tm_peer_question: payload allocation failed") catch {};
        return 99;
    };
    defer std.heap.c_allocator.free(payload);

    // Route to Team Lead (worker 0) — Team Lead relays to target
    b.send(0, from_id, .peer_question, payload) catch |err| {
        e.setError(if (err == error.DeliveryFailed) "peer question delivery failed" else "peer question bus send failed") catch {};
        return 8; // TM_ERR_BUS
    };
    return 0; // TM_OK
}

export fn tm_peer_delegate(engine: ?*Engine, from_id: u32, target_id: u32, task: ?[*:0]const u8) c_int {
    const e = engine orelse return 99; // TM_ERR_UNKNOWN
    const tsk = std.mem.span(task orelse {
        e.setError("tm_peer_delegate: task is NULL") catch {};
        return 99;
    });

    if (from_id == 0) {
        e.setError("tm_peer_delegate: Team Lead cannot delegate via peer messaging") catch {};
        return 12; // TM_ERR_INVALID_WORKER
    }
    if (from_id == target_id) {
        e.setError("tm_peer_delegate: cannot delegate to yourself") catch {};
        return 12; // TM_ERR_INVALID_WORKER
    }
    if (e.roster.getWorker(from_id) == null) {
        e.setError("tm_peer_delegate: sender worker not found") catch {};
        return 12; // TM_ERR_INVALID_WORKER
    }
    if (e.roster.getWorker(target_id) == null) {
        e.setError("tm_peer_delegate: target worker not found") catch {};
        return 12; // TM_ERR_INVALID_WORKER
    }

    var b = &(e.message_bus orelse {
        e.setError("tm_peer_delegate: message bus not initialized") catch {};
        return 8; // TM_ERR_BUS
    });

    // Build payload JSON: {"worker_id": from, "target_worker_id": target, "task": "..."}
    const tsk_esc = jsonEscape(std.heap.c_allocator, tsk) catch {
        e.setError("tm_peer_delegate: payload allocation failed") catch {};
        return 99;
    };
    defer std.heap.c_allocator.free(tsk_esc);

    const payload = std.fmt.allocPrint(std.heap.c_allocator,
        \\{{"worker_id":{d},"target_worker_id":{d},"task":"{s}"}}
    , .{ from_id, target_id, tsk_esc }) catch {
        e.setError("tm_peer_delegate: payload allocation failed") catch {};
        return 99;
    };
    defer std.heap.c_allocator.free(payload);

    // Route directly to target worker PTY
    b.send(target_id, from_id, .delegation, payload) catch |err| {
        e.setError(if (err == error.DeliveryFailed) "delegation delivery failed" else "delegation bus send failed") catch {};
        return 8; // TM_ERR_BUS
    };
    return 0; // TM_OK
}

// ─── Completion + Question signaling ─────────────────────

const CCompletion = extern struct {
    worker_id: u32,
    _pad0: u32 = 0,
    summary: ?[*:0]const u8,
    git_commit: ?[*:0]const u8,
    details: ?[*:0]const u8,
    timestamp: u64,
};

const CQuestion = extern struct {
    worker_id: u32,
    _pad0: u32 = 0,
    question: ?[*:0]const u8,
    context: ?[*:0]const u8,
    timestamp: u64,
};

/// Signal worker completion. Creates TM_MSG_COMPLETION message, routes through
/// bus to Team Lead (worker 0), and persists to JSONL history log (TD16).
export fn tm_worker_complete(engine: ?*Engine, worker_id: u32, summary: ?[*:0]const u8, details: ?[*:0]const u8) c_int {
    const e = engine orelse return 99;
    const sum_str = std.mem.span(summary orelse {
        e.setError("tm_worker_complete: summary must not be NULL") catch {};
        return 99;
    });
    const det_str = if (details) |d| std.mem.span(d) else "";

    // Escape JSON-special characters in user-provided strings
    const sum_esc = jsonEscape(e.allocator, sum_str) catch {
        e.setError("tm_worker_complete: payload allocation failed") catch {};
        return 99;
    };
    defer e.allocator.free(sum_esc);
    const det_esc = jsonEscape(e.allocator, det_str) catch {
        e.setError("tm_worker_complete: payload allocation failed") catch {};
        return 99;
    };
    defer e.allocator.free(det_esc);

    const payload = std.fmt.allocPrint(e.allocator,
        \\{{"worker_id":{d},"summary":"{s}","details":"{s}"}}
    , .{ worker_id, sum_esc, det_esc }) catch {
        e.setError("tm_worker_complete: payload allocation failed") catch {};
        return 99;
    };
    defer e.allocator.free(payload);

    var b = &(e.message_bus orelse {
        e.setError("tm_worker_complete: message bus not initialized (call tm_session_start first)") catch {};
        return 8;
    });

    b.send(0, worker_id, .completion, payload) catch |err| {
        e.setError(if (err == error.DeliveryFailed) "completion delivery failed after retries exhausted" else "completion bus send failed") catch {};
        return 8;
    };

    // History write for C API path (Swift calling tm_worker_complete).
    // The command-file path (busSendBridge) has its own history write.
    if (e.history_logger) |*logger| {
        const git_commit = if (e.roster.getWorker(worker_id)) |w|
            history_mod.captureGitCommit(e.allocator, w.worktree_path)
        else
            null;
        defer if (git_commit) |gc| e.allocator.free(gc);
        logger.append(.{
            .entry_type = .completion,
            .worker_id = worker_id,
            .role_id = "",
            .content = sum_str,
            .git_commit = git_commit,
            .timestamp = @intCast(std.time.timestamp()),
        }) catch |err| {
            std.log.err("[teammux] history append failed in tm_worker_complete: {}", .{err});
            e.setError("tm_worker_complete: history persistence failed — event delivered to bus but not written to JSONL log") catch {};
        };
    }

    return 0;
}

/// Signal worker question. Creates TM_MSG_QUESTION message, routes through
/// bus to Team Lead (worker 0), and persists to JSONL history log (TD16).
export fn tm_worker_question(engine: ?*Engine, worker_id: u32, question: ?[*:0]const u8, ctx: ?[*:0]const u8) c_int {
    const e = engine orelse return 99;
    const q_str = std.mem.span(question orelse {
        e.setError("tm_worker_question: question must not be NULL") catch {};
        return 99;
    });
    const ctx_str = if (ctx) |c| std.mem.span(c) else "";

    const q_esc = jsonEscape(e.allocator, q_str) catch {
        e.setError("tm_worker_question: payload allocation failed") catch {};
        return 99;
    };
    defer e.allocator.free(q_esc);
    const ctx_esc = jsonEscape(e.allocator, ctx_str) catch {
        e.setError("tm_worker_question: payload allocation failed") catch {};
        return 99;
    };
    defer e.allocator.free(ctx_esc);

    const payload = std.fmt.allocPrint(e.allocator,
        \\{{"worker_id":{d},"question":"{s}","context":"{s}"}}
    , .{ worker_id, q_esc, ctx_esc }) catch {
        e.setError("tm_worker_question: payload allocation failed") catch {};
        return 99;
    };
    defer e.allocator.free(payload);

    var b = &(e.message_bus orelse {
        e.setError("tm_worker_question: message bus not initialized (call tm_session_start first)") catch {};
        return 8;
    });

    b.send(0, worker_id, .question, payload) catch |err| {
        e.setError(if (err == error.DeliveryFailed) "question delivery failed after retries exhausted" else "question bus send failed") catch {};
        return 8;
    };

    // History write for C API path (Swift calling tm_worker_question).
    // The command-file path (busSendBridge) has its own history write.
    if (e.history_logger) |*logger| {
        logger.append(.{
            .entry_type = .question,
            .worker_id = worker_id,
            .role_id = "",
            .content = q_str,
            .git_commit = null,
            .timestamp = @intCast(std.time.timestamp()),
        }) catch |err| {
            std.log.err("[teammux] history append failed in tm_worker_question: {}", .{err});
            e.setError("tm_worker_question: history persistence failed — event delivered to bus but not written to JSONL log") catch {};
        };
    }

    return 0;
}

/// Free a heap-allocated tm_completion_t.
export fn tm_completion_free(completion: ?*CCompletion) void {
    if (completion) |c| {
        freeNullTerminated(c.summary);
        freeNullTerminated(c.git_commit);
        freeNullTerminated(c.details);
        std.heap.c_allocator.destroy(c);
    }
}

/// Free a heap-allocated tm_question_t.
export fn tm_question_free(question: ?*CQuestion) void {
    if (question) |q| {
        freeNullTerminated(q.question);
        freeNullTerminated(q.context);
        std.heap.c_allocator.destroy(q);
    }
}

// ─── Completion history persistence (TD16) ───────────────

const CHistoryEntry = extern struct {
    entry_type: ?[*:0]const u8,
    worker_id: u32,
    _pad0: u32 = 0,
    role_id: ?[*:0]const u8,
    content: ?[*:0]const u8,
    git_commit: ?[*:0]const u8,
    timestamp: u64,
};

/// Load all history entries from the JSONL file.
/// Returns heap-allocated array of tm_history_entry_t pointers.
/// Caller must call tm_history_free(). Returns NULL if no entries or error.
export fn tm_history_load(engine: ?*Engine, count: ?*u32) ?[*]?*CHistoryEntry {
    if (count) |c| c.* = 0;
    const e = engine orelse return null;
    var logger = &(e.history_logger orelse return null);
    const alloc = std.heap.c_allocator;

    var entries = logger.load() catch {
        e.setError("tm_history_load: failed to load history") catch {};
        return null;
    };
    defer {
        for (entries.items) |entry| entry.deinit(e.allocator);
        entries.deinit(e.allocator);
    }

    if (entries.items.len == 0) return null;

    const ptrs = alloc.alloc(?*CHistoryEntry, entries.items.len) catch {
        e.setError("tm_history_load: allocation failed") catch {};
        return null;
    };

    for (entries.items, 0..) |entry, i| {
        const c_entry = alloc.create(CHistoryEntry) catch {
            for (0..i) |j| freeCHistoryEntry(ptrs[j]);
            alloc.free(ptrs);
            e.setError("tm_history_load: allocation failed") catch {};
            return null;
        };
        c_entry.* = .{
            .entry_type = allocCStr(alloc, entry.entry_type.toString()) catch {
                alloc.destroy(c_entry);
                for (0..i) |j| freeCHistoryEntry(ptrs[j]);
                alloc.free(ptrs);
                e.setError("tm_history_load: allocation failed") catch {};
                return null;
            },
            .worker_id = entry.worker_id,
            .role_id = allocCStr(alloc, entry.role_id) catch {
                freeNullTerminated(c_entry.entry_type);
                alloc.destroy(c_entry);
                for (0..i) |j| freeCHistoryEntry(ptrs[j]);
                alloc.free(ptrs);
                e.setError("tm_history_load: allocation failed") catch {};
                return null;
            },
            .content = allocCStr(alloc, entry.content) catch {
                freeNullTerminated(c_entry.entry_type);
                freeNullTerminated(c_entry.role_id);
                alloc.destroy(c_entry);
                for (0..i) |j| freeCHistoryEntry(ptrs[j]);
                alloc.free(ptrs);
                e.setError("tm_history_load: allocation failed") catch {};
                return null;
            },
            .git_commit = if (entry.git_commit) |gc| allocCStr(alloc, gc) catch {
                freeNullTerminated(c_entry.entry_type);
                freeNullTerminated(c_entry.role_id);
                freeNullTerminated(c_entry.content);
                alloc.destroy(c_entry);
                for (0..i) |j| freeCHistoryEntry(ptrs[j]);
                alloc.free(ptrs);
                e.setError("tm_history_load: allocation failed") catch {};
                return null;
            } else null,
            .timestamp = entry.timestamp,
        };
        ptrs[i] = c_entry;
    }

    if (count) |c| c.* = @intCast(entries.items.len);
    return ptrs.ptr;
}

/// Free history entries returned by tm_history_load.
export fn tm_history_free(entries: ?[*]?*CHistoryEntry, count: u32) void {
    const ptrs = entries orelse return;
    for (0..count) |i| freeCHistoryEntry(ptrs[i]);
    std.heap.c_allocator.free(ptrs[0..count]);
}

/// Clear all history entries (truncates the JSONL file).
export fn tm_history_clear(engine: ?*Engine) c_int {
    const e = engine orelse return 99;
    var logger = &(e.history_logger orelse {
        e.setError("tm_history_clear: history logger not initialized") catch {};
        return 99;
    });
    logger.clear() catch {
        e.setError("tm_history_clear: failed to clear history") catch {};
        return 99;
    };
    return 0;
}

fn freeCHistoryEntry(entry: ?*CHistoryEntry) void {
    const e = entry orelse return;
    freeNullTerminated(e.entry_type);
    freeNullTerminated(e.role_id);
    freeNullTerminated(e.content);
    freeNullTerminated(e.git_commit);
    std.heap.c_allocator.destroy(e);
}

fn allocCStr(alloc: std.mem.Allocator, s: []const u8) !?[*:0]const u8 {
    const z = try alloc.dupeZ(u8, s);
    return z.ptr;
}

// ─── Merge coordinator ───────────────────────────────────

export fn tm_merge_approve(engine: ?*Engine, worker_id: u32, strategy: ?[*:0]const u8) c_int {
    const e = engine orelse return 99;
    const strat = std.mem.span(strategy orelse "merge");
    _ = e.merge_coordinator.approve(&e.roster, e.project_root, worker_id, strat) catch |err| {
        const code: c_int = switch (err) {
            error.WorkerNotFound => 12, // TM_ERR_INVALID_WORKER
            error.NotOnMain => 5, // TM_ERR_WORKTREE
            error.MergeInProgress => 5,
            else => 99,
        };
        e.setError(switch (err) {
            error.WorkerNotFound => "merge approve failed: worker not found",
            error.NotOnMain => "merge approve failed: HEAD is not on main",
            error.MergeInProgress => "merge approve failed: another merge is in progress",
            else => "merge approve failed",
        }) catch {};
        return code;
    };
    return 0;
}
export fn tm_merge_reject(engine: ?*Engine, worker_id: u32) c_int {
    const e = engine orelse return 99;
    // Stop and remove role watcher before reject
    if (e.role_watchers.fetchRemove(worker_id)) |kv| {
        kv.value.destroy();
    }
    // Remove interceptor wrapper before worktree is deleted
    if (e.roster.getWorker(worker_id)) |w| {
        interceptor.remove(e.allocator, w.worktree_path) catch |err| {
            std.log.warn("[teammux] interceptor remove failed for worker {d}: {}", .{ worker_id, err });
        };
    }
    e.merge_coordinator.reject(&e.roster, e.project_root, worker_id) catch |err| {
        e.setError(if (err == error.WorkerNotFound) "merge reject failed: worker not found" else "merge reject failed") catch {};
        return if (err == error.WorkerNotFound) 12 else 5;
    };
    e.ownership_registry.release(worker_id);
    return 0;
}
export fn tm_merge_get_status(engine: ?*Engine, worker_id: u32) c_int {
    const e = engine orelse return 0; // TM_MERGE_PENDING
    return @intFromEnum(e.merge_coordinator.getStatus(worker_id));
}
export fn tm_merge_conflicts_get(engine: ?*Engine, worker_id: u32, count: ?*u32) ?[*]?*CConflict {
    const e = engine orelse { if (count) |c| c.* = 0; return null; };
    const conflicts = e.merge_coordinator.getConflicts(worker_id) orelse {
        if (count) |c| c.* = 0;
        return null;
    };
    if (conflicts.len == 0) { if (count) |c| c.* = 0; return null; }

    const alloc = e.allocator;
    const ptrs = alloc.alloc(?*CConflict, conflicts.len) catch { if (count) |c| c.* = 0; return null; };
    for (conflicts, 0..) |conf, i| {
        const cc = alloc.create(CConflict) catch {
            for (0..i) |j| freeCConflict(ptrs[j]);
            alloc.free(ptrs); if (count) |c| c.* = 0; return null;
        };
        cc.* = fillCConflict(alloc, conf) catch {
            alloc.destroy(cc);
            for (0..i) |j| freeCConflict(ptrs[j]);
            alloc.free(ptrs); if (count) |c| c.* = 0; return null;
        };
        ptrs[i] = cc;
    }
    if (count) |c| c.* = @intCast(conflicts.len);
    return ptrs.ptr;
}
export fn tm_merge_conflicts_free(conflicts: ?[*]?*CConflict, count: u32) void {
    const ptrs = conflicts orelse return;
    for (0..count) |i| freeCConflict(ptrs[i]);
    std.heap.c_allocator.free(ptrs[0..count]);
}

// ─── Roles ───────────────────────────────────────────────

export fn tm_role_resolve(engine: ?*Engine, role_id: ?[*:0]const u8, out_role: ?*?*CRole) c_int {
    if (out_role) |p| p.* = null;
    const e = engine orelse return 99;
    const out = out_role orelse {
        e.setError("tm_role_resolve: out_role must not be NULL") catch {};
        return 13;
    };
    const rid = std.mem.span(role_id orelse {
        e.setError("tm_role_resolve: role_id must not be NULL") catch {};
        return 13;
    });

    const role_path = config.resolveRolePath(e.allocator, rid, e.project_root) catch |err| {
        if (err == error.OutOfMemory) return 99;
        e.setError("role resolve failed: path search error") catch {};
        return 13;
    };
    if (role_path == null) {
        std.log.warn("[teammux] role '{s}' not found in any search path", .{rid});
        e.setError("role not found in any search path") catch {};
        return 13; // TM_ERR_ROLE
    }
    defer e.allocator.free(role_path.?);

    var role_def = config.parseRoleDefinition(e.allocator, role_path.?) catch |err| {
        const msg = switch (err) {
            error.OutOfMemory => {
                e.setError("role parse failed: out of memory") catch {};
                return 99;
            },
            error.InvalidSyntax => "role parse failed: invalid TOML syntax",
            error.StreamTooLong => "role parse failed: file exceeds 1MB limit",
            else => "role parse failed: file read error",
        };
        std.log.warn("[teammux] failed to parse role '{s}': {s}", .{ rid, msg });
        e.setError(msg) catch {};
        return 13;
    };
    defer role_def.deinit(e.allocator);

    const c_role = fillCRole(e.allocator, &role_def) catch return 99;
    out.* = c_role;
    return 0;
}

export fn tm_role_free(role: ?*CRole) void {
    if (role) |r| {
        freeCRole(r);
        std.heap.c_allocator.destroy(r);
    }
}

export fn tm_roles_list(engine: ?*Engine, count: ?*u32) ?[*]?*CRole {
    if (count) |c| c.* = 0;
    const e = engine orelse return null;
    const alloc = e.allocator;

    // Collect unique role IDs from all search paths (project-local, user, bundled, dev-build)
    var seen = std.StringHashMap(void).init(alloc);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        seen.deinit();
    }
    var role_defs: std.ArrayList(*CRole) = .{};
    var role_defs_transferred = false;
    defer {
        if (!role_defs_transferred) {
            for (role_defs.items) |cr| {
                freeCRole(cr);
                alloc.destroy(cr);
            }
        }
        role_defs.deinit(alloc);
    }

    // Search paths to scan for role directories
    const project_roles = std.fmt.allocPrint(alloc, "{s}/.teammux/roles", .{e.project_root}) catch return null;
    defer alloc.free(project_roles);

    const home_roles = if (std.posix.getenv("HOME")) |home|
        (std.fmt.allocPrint(alloc, "{s}/.teammux/roles", .{home}) catch null)
    else
        null;
    defer if (home_roles) |hr| alloc.free(hr);

    const exe_dir = config.getExeDir(alloc) catch return null;
    defer if (exe_dir) |ed| alloc.free(ed);

    const bundle_roles = if (exe_dir) |ed|
        (std.fmt.allocPrint(alloc, "{s}/../Resources/roles", .{ed}) catch null)
    else
        null;
    defer if (bundle_roles) |br| alloc.free(br);

    const dev_roles = if (exe_dir) |ed|
        (std.fmt.allocPrint(alloc, "{s}/roles", .{ed}) catch null)
    else
        null;
    defer if (dev_roles) |dr| alloc.free(dr);

    const paths = [_]?[]const u8{ project_roles, home_roles, bundle_roles, dev_roles };

    for (paths) |maybe_path| {
        const dir_path = maybe_path orelse continue;
        const role_ids = config.listRolesInDir(alloc, dir_path) catch |err| {
            if (err == error.OutOfMemory) return null;
            std.log.warn("[teammux] roles: failed to list directory '{s}': {s}", .{ dir_path, @errorName(err) });
            continue;
        };
        defer {
            for (role_ids) |rid| alloc.free(rid);
            alloc.free(role_ids);
        }
        for (role_ids) |rid| {
            if (seen.contains(rid)) continue;
            const role_path = config.resolveRolePath(alloc, rid, e.project_root) catch |err| {
                if (err == error.OutOfMemory) return null;
                std.log.warn("[teammux] roles: resolve failed for '{s}': {s}", .{ rid, @errorName(err) });
                continue;
            };
            if (role_path == null) continue;
            defer alloc.free(role_path.?);

            var role_def = config.parseRoleDefinition(alloc, role_path.?) catch |err| {
                if (err == error.OutOfMemory) return null;
                std.log.warn("[teammux] roles: parse failed for '{s}': {s}", .{ rid, @errorName(err) });
                continue;
            };
            defer role_def.deinit(alloc);

            const c_role = fillCRole(alloc, &role_def) catch |err| {
                if (err == error.OutOfMemory) return null;
                continue;
            };
            role_defs.append(alloc, c_role) catch {
                freeCRole(c_role);
                alloc.destroy(c_role);
                return null; // OOM
            };
            const owned_key = alloc.dupe(u8, rid) catch return null;
            seen.put(owned_key, {}) catch {
                alloc.free(owned_key);
                return null; // OOM
            };
        }
    }

    if (role_defs.items.len == 0) return null;

    // Convert to C-compatible array of pointers
    const result = alloc.alloc(?*CRole, role_defs.items.len) catch return null;
    for (role_defs.items, 0..) |ptr, i| {
        result[i] = ptr;
    }
    role_defs_transferred = true;
    if (count) |c| c.* = @intCast(role_defs.items.len);
    return result.ptr;
}

export fn tm_roles_list_free(roles: ?[*]?*CRole, count: u32) void {
    const ptrs = roles orelse return;
    for (0..count) |i| {
        if (ptrs[i]) |r| {
            freeCRole(r);
            std.heap.c_allocator.destroy(r);
        }
    }
    std.heap.c_allocator.free(ptrs[0..count]);
}

export fn tm_roles_list_bundled(project_root: ?[*:0]const u8, count: ?*u32) ?[*]?*CRole {
    const out_count = count orelse return null;
    out_count.* = 0;
    const alloc = std.heap.c_allocator;

    const root: ?[]const u8 = if (project_root) |pr| std.mem.span(pr) else null;

    // Collect unique role IDs from all search paths
    var seen = std.StringHashMap(void).init(alloc);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        seen.deinit();
    }
    var role_defs: std.ArrayList(*CRole) = .{};
    var role_defs_transferred = false;
    defer {
        if (!role_defs_transferred) {
            for (role_defs.items) |cr| {
                freeCRole(cr);
                alloc.destroy(cr);
            }
        }
        role_defs.deinit(alloc);
    }

    // Build search paths — same order as tm_roles_list
    const project_roles: ?[]const u8 = if (root) |r|
        (std.fmt.allocPrint(alloc, "{s}/.teammux/roles", .{r}) catch null)
    else
        null;
    defer if (project_roles) |pr| alloc.free(pr);

    const home_roles = if (std.posix.getenv("HOME")) |home|
        (std.fmt.allocPrint(alloc, "{s}/.teammux/roles", .{home}) catch null)
    else
        null;
    defer if (home_roles) |hr| alloc.free(hr);

    const exe_dir = config.getExeDir(alloc) catch return null;
    defer if (exe_dir) |ed| alloc.free(ed);

    const bundle_roles = if (exe_dir) |ed|
        (std.fmt.allocPrint(alloc, "{s}/../Resources/roles", .{ed}) catch null)
    else
        null;
    defer if (bundle_roles) |br| alloc.free(br);

    const dev_roles = if (exe_dir) |ed|
        (std.fmt.allocPrint(alloc, "{s}/roles", .{ed}) catch null)
    else
        null;
    defer if (dev_roles) |dr| alloc.free(dr);

    const paths = [_]?[]const u8{ project_roles, home_roles, bundle_roles, dev_roles };

    // When project_root is null, pass a nonexistent path to resolveRolePath so
    // its project-local check fails harmlessly and falls through to user/bundled/dev.
    // This relies on /nonexistent not existing on disk. A cleaner alternative would
    // be a resolveRolePath variant accepting optional project_root.
    const resolve_root = root orelse "/nonexistent";

    for (paths) |maybe_path| {
        const dir_path = maybe_path orelse continue;
        const role_ids = config.listRolesInDir(alloc, dir_path) catch |err| {
            if (err == error.OutOfMemory) return null;
            std.log.warn("[teammux] bundled-roles: failed to list directory '{s}': {s}", .{ dir_path, @errorName(err) });
            continue;
        };
        defer {
            for (role_ids) |rid| alloc.free(rid);
            alloc.free(role_ids);
        }
        for (role_ids) |rid| {
            if (seen.contains(rid)) continue;
            const role_path = config.resolveRolePath(alloc, rid, resolve_root) catch |err| {
                if (err == error.OutOfMemory) return null;
                std.log.warn("[teammux] bundled-roles: resolve failed for '{s}': {s}", .{ rid, @errorName(err) });
                continue;
            };
            if (role_path == null) continue;
            defer alloc.free(role_path.?);

            var role_def = config.parseRoleDefinition(alloc, role_path.?) catch |err| {
                if (err == error.OutOfMemory) return null;
                std.log.warn("[teammux] bundled-roles: parse failed for '{s}': {s}", .{ rid, @errorName(err) });
                continue;
            };
            defer role_def.deinit(alloc);

            const c_role = fillCRole(alloc, &role_def) catch return null;
            role_defs.append(alloc, c_role) catch {
                freeCRole(c_role);
                alloc.destroy(c_role);
                return null;
            };
            const owned_key = alloc.dupe(u8, rid) catch return null;
            seen.put(owned_key, {}) catch {
                alloc.free(owned_key);
                return null;
            };
        }
    }

    if (role_defs.items.len == 0) return null;

    const result = alloc.alloc(?*CRole, role_defs.items.len) catch return null;
    for (role_defs.items, 0..) |ptr, i| {
        result[i] = ptr;
    }
    role_defs_transferred = true;
    out_count.* = @intCast(role_defs.items.len);
    return result.ptr;
}

export fn tm_roles_list_bundled_free(roles: ?[*]?*CRole, count: u32) void {
    tm_roles_list_free(roles, count);
}

// ─── File ownership ──────────────────────────────────────

export fn tm_ownership_check(engine: ?*Engine, worker_id: u32, file_path: ?[*:0]const u8, out_allowed: ?*bool) c_int {
    const e = engine orelse return 99;
    const path = std.mem.span(file_path orelse {
        e.setError("tm_ownership_check: file_path must not be NULL") catch {};
        return 14;
    });
    const out = out_allowed orelse {
        e.setError("tm_ownership_check: out_allowed must not be NULL") catch {};
        return 14;
    };
    out.* = e.ownership_registry.check(worker_id, path);
    return 0;
}

export fn tm_ownership_register(engine: ?*Engine, worker_id: u32, path_pattern: ?[*:0]const u8, allow_write: bool) c_int {
    const e = engine orelse return 99;
    const pattern = std.mem.span(path_pattern orelse {
        e.setError("tm_ownership_register: path_pattern must not be NULL") catch {};
        return 14;
    });
    e.ownership_registry.register(worker_id, pattern, allow_write) catch {
        e.setError("tm_ownership_register: allocation failed") catch {};
        return 14; // TM_ERR_OWNERSHIP
    };
    return 0;
}

export fn tm_ownership_release(engine: ?*Engine, worker_id: u32) c_int {
    const e = engine orelse return 99;
    e.ownership_registry.release(worker_id);
    return 0;
}

export fn tm_ownership_get(engine: ?*Engine, worker_id: u32, count: ?*u32) ?[*]?*COwnershipEntry {
    if (count) |c| c.* = 0;
    const e = engine orelse return null;
    const alloc = e.allocator;

    const rules = e.ownership_registry.getRules(worker_id) orelse return null;
    if (rules.len == 0) return null;

    // Note: this is a C-ABI export returning ?[*] — errdefer does not apply.
    // All cleanup must be done manually in each catch block.
    const ptrs = alloc.alloc(?*COwnershipEntry, rules.len) catch {
        e.setError("tm_ownership_get: allocation failed") catch {};
        return null;
    };
    var filled: usize = 0;

    for (rules) |rule| {
        const entry = alloc.create(COwnershipEntry) catch {
            for (0..filled) |j| freeCOwnershipEntry(ptrs[j]);
            alloc.free(ptrs);
            e.setError("tm_ownership_get: allocation failed") catch {};
            return null;
        };
        const pat_z = alloc.dupeZ(u8, rule.pattern) catch {
            alloc.destroy(entry);
            for (0..filled) |j| freeCOwnershipEntry(ptrs[j]);
            alloc.free(ptrs);
            e.setError("tm_ownership_get: allocation failed") catch {};
            return null;
        };
        entry.* = .{
            .path_pattern = pat_z.ptr,
            .worker_id = worker_id,
            .allow_write = rule.allow_write,
        };
        ptrs[filled] = entry;
        filled += 1;
    }

    if (count) |c| c.* = @intCast(rules.len);
    return ptrs.ptr;
}

export fn tm_ownership_free(entries: ?[*]?*COwnershipEntry, count: u32) void {
    const ptrs = entries orelse return;
    for (0..count) |i| freeCOwnershipEntry(ptrs[i]);
    std.heap.c_allocator.free(ptrs[0..count]);
}

fn freeCOwnershipEntry(ptr: ?*COwnershipEntry) void {
    const entry = ptr orelse return;
    freeNullTerminated(entry.path_pattern);
    std.heap.c_allocator.destroy(entry);
}

export fn tm_ownership_update(
    engine: ?*Engine,
    worker_id: u32,
    write_patterns: ?[*]const ?[*:0]const u8,
    write_count: u32,
    deny_patterns: ?[*]const ?[*:0]const u8,
    deny_count: u32,
) c_int {
    const e = engine orelse return 99;

    // Convert C string arrays to Zig slices
    const write_slices = e.allocator.alloc([]const u8, write_count) catch {
        e.setError("tm_ownership_update: allocation failed") catch {};
        return 14; // TM_ERR_OWNERSHIP
    };
    defer e.allocator.free(write_slices);

    const deny_slices = e.allocator.alloc([]const u8, deny_count) catch {
        e.setError("tm_ownership_update: allocation failed") catch {};
        return 14;
    };
    defer e.allocator.free(deny_slices);

    if (write_count > 0) {
        const w_ptrs = write_patterns orelse {
            e.setError("tm_ownership_update: write_patterns NULL with non-zero count") catch {};
            return 14;
        };
        for (0..write_count) |i| {
            write_slices[i] = std.mem.span(w_ptrs[i] orelse {
                e.setError("tm_ownership_update: NULL write pattern") catch {};
                return 14;
            });
        }
    }

    if (deny_count > 0) {
        const d_ptrs = deny_patterns orelse {
            e.setError("tm_ownership_update: deny_patterns NULL with non-zero count") catch {};
            return 14;
        };
        for (0..deny_count) |i| {
            deny_slices[i] = std.mem.span(d_ptrs[i] orelse {
                e.setError("tm_ownership_update: NULL deny pattern") catch {};
                return 14;
            });
        }
    }

    e.ownership_registry.updateWorkerRules(worker_id, write_slices, deny_slices) catch |err| {
        e.setError(switch (err) {
            error.OutOfMemory => "tm_ownership_update: allocation failed (out of memory)",
        }) catch {};
        return 14;
    };
    return 0;
}

// ─── Git interceptor ─────────────────────────────────────

export fn tm_interceptor_install(engine: ?*Engine, worker_id: u32) c_int {
    const e = engine orelse return 99;
    const w = e.roster.getWorker(worker_id) orelse {
        e.setError("tm_interceptor_install: worker not found") catch {};
        return 12; // TM_ERR_INVALID_WORKER
    };

    // Get deny and write patterns from ownership registry
    const rules = e.ownership_registry.getRules(worker_id);

    // Count deny vs write patterns
    var deny_count: usize = 0;
    var write_count: usize = 0;
    if (rules) |r| {
        for (r) |rule| {
            if (rule.allow_write) write_count += 1 else deny_count += 1;
        }
    }

    // Build pattern arrays — copy pattern pointers from registry.
    // NOTE: These are pointers into registry-owned memory. Safe because
    // all C API calls are dispatched from the main thread; no concurrent
    // register/release can occur during this function.
    const deny_pats = e.allocator.alloc([]const u8, deny_count) catch {
        e.setError("tm_interceptor_install: allocation failed") catch {};
        return 5; // TM_ERR_WORKTREE
    };
    defer e.allocator.free(deny_pats);
    const write_pats = e.allocator.alloc([]const u8, write_count) catch {
        e.setError("tm_interceptor_install: allocation failed") catch {};
        return 5; // TM_ERR_WORKTREE
    };
    defer e.allocator.free(write_pats);

    var di: usize = 0;
    var wi: usize = 0;
    if (rules) |r| {
        for (r) |rule| {
            if (rule.allow_write) {
                write_pats[wi] = rule.pattern;
                wi += 1;
            } else {
                deny_pats[di] = rule.pattern;
                di += 1;
            }
        }
    }

    interceptor.install(e.allocator, w.worktree_path, worker_id, w.name, deny_pats, write_pats) catch |err| {
        e.setError(switch (err) {
            error.GitNotFound => "tm_interceptor_install: git binary not found on PATH",
            error.UnsafePattern => "tm_interceptor_install: pattern contains shell metacharacters",
            else => "tm_interceptor_install: failed to install wrapper script",
        }) catch {};
        return 5; // TM_ERR_WORKTREE
    };
    return 0;
}

export fn tm_interceptor_remove(engine: ?*Engine, worker_id: u32) c_int {
    const e = engine orelse return 99;
    const w = e.roster.getWorker(worker_id) orelse {
        e.setError("tm_interceptor_remove: worker not found") catch {};
        return 12; // TM_ERR_INVALID_WORKER
    };
    interceptor.remove(e.allocator, w.worktree_path) catch {
        e.setError("tm_interceptor_remove: failed to remove wrapper") catch {};
        return 5; // TM_ERR_WORKTREE
    };
    return 0;
}

export fn tm_interceptor_path(engine: ?*Engine, worker_id: u32) ?[*:0]const u8 {
    const e = engine orelse return null;
    const w = e.roster.getWorker(worker_id) orelse return null;
    const path = interceptor.getInterceptorPath(std.heap.c_allocator, w.worktree_path) catch {
        e.setError("tm_interceptor_path: filesystem error checking interceptor directory") catch {};
        return null;
    };
    if (path) |p| {
        const z = std.heap.c_allocator.dupeZ(u8, p) catch {
            std.heap.c_allocator.free(p);
            return null;
        };
        std.heap.c_allocator.free(p);
        return z.ptr;
    }
    return null;
}

// ─── Role hot-reload ─────────────────────────────────────

export fn tm_role_watch(engine: ?*Engine, worker_id: u32, role_id: ?[*:0]const u8, callback: ?*const fn (u32, ?[*:0]const u8, ?*anyopaque) callconv(.c) void, userdata: ?*anyopaque) c_int {
    const e = engine orelse return 99;
    const cb = callback orelse {
        // No dedicated TM_ERR_INVALID_ARG; reusing TM_ERR_ROLE for parameter errors
        e.setError("tm_role_watch: callback must not be NULL") catch {};
        return 13;
    };
    const rid = std.mem.span(role_id orelse {
        e.setError("tm_role_watch: role_id must not be NULL") catch {};
        return 13;
    });

    const w = e.roster.getWorker(worker_id) orelse {
        e.setError("tm_role_watch: worker not found") catch {};
        return 12; // TM_ERR_INVALID_WORKER
    };

    const role_path = config.resolveRolePath(e.allocator, rid, e.project_root) catch |err| {
        std.log.warn("[teammux] tm_role_watch: role path resolution failed for '{s}': {}", .{ rid, err });
        e.setError("tm_role_watch: role path resolution failed") catch {};
        return 13;
    };
    if (role_path == null) {
        std.log.warn("[teammux] tm_role_watch: role '{s}' not found in any search path", .{rid});
        e.setError("tm_role_watch: role not found in any search path") catch {};
        return 13; // TM_ERR_ROLE
    }
    defer e.allocator.free(role_path.?);

    if (e.role_watchers.fetchRemove(worker_id)) |kv| {
        kv.value.destroy();
    }

    const watcher = hotreload.RoleWatcher.create(
        e.allocator,
        worker_id,
        rid,
        role_path.?,
        w.task_description,
        w.branch_name,
        e.project_root,
        w.worktree_path,
        w.name,
        &e.ownership_registry,
        cb,
        userdata,
    ) catch |err| {
        std.log.warn("[teammux] tm_role_watch: watcher creation failed for worker {d}: {}", .{ worker_id, err });
        e.setError("tm_role_watch: watcher creation failed") catch {};
        return 99;
    };

    watcher.start() catch |err| {
        watcher.destroy();
        std.log.warn("[teammux] tm_role_watch: watcher start failed for worker {d} role '{s}': {}", .{ worker_id, rid, err });
        e.setError("tm_role_watch: watcher start failed") catch {};
        return 13;
    };

    e.role_watchers.put(worker_id, watcher) catch |err| {
        watcher.destroy();
        std.log.warn("[teammux] tm_role_watch: map insertion failed for worker {d}: {}", .{ worker_id, err });
        e.setError("tm_role_watch: map insertion failed") catch {};
        return 99;
    };

    return 0;
}

export fn tm_role_unwatch(engine: ?*Engine, worker_id: u32) c_int {
    const e = engine orelse return 99;
    if (e.role_watchers.fetchRemove(worker_id)) |kv| {
        kv.value.destroy();
    }
    return 0; // Idempotent — no error if no watcher existed
}

// ─── Utility ─────────────────────────────────────────────

export fn tm_agent_resolve(agent_name: ?[*:0]const u8) ?[*:0]const u8 {
    const name = std.mem.span(agent_name orelse return null);
    const result = github.resolveAgentBinary(std.heap.c_allocator, name) catch return null;
    if (result) |r| { const z = std.heap.c_allocator.dupeZ(u8, r) catch return null; std.heap.c_allocator.free(r); return z.ptr; }
    return null;
}
export fn tm_free_string(str: ?[*:0]const u8) void { if (str) |s| { std.heap.c_allocator.free(std.mem.span(s)); } }
export fn tm_version() [*:0]const u8 { return "0.1.0"; }
export fn tm_result_to_string(result: c_int) [*:0]const u8 {
    return switch (result) {
        0 => "TM_OK", 1 => "TM_ERR_NOT_GIT", 2 => "TM_ERR_NO_GH", 3 => "TM_ERR_GH_UNAUTH",
        4 => "TM_ERR_NO_AGENT", 5 => "TM_ERR_WORKTREE", 6 => "TM_ERR_PTY", 7 => "TM_ERR_CONFIG",
        8 => "TM_ERR_BUS", 9 => "TM_ERR_GITHUB", 10 => "TM_ERR_NOT_IMPLEMENTED",
        11 => "TM_ERR_TIMEOUT", 12 => "TM_ERR_INVALID_WORKER", 13 => "TM_ERR_ROLE",
        14 => "TM_ERR_OWNERSHIP",
        else => "TM_ERR_UNKNOWN",
    };
}

// ─── Helpers ─────────────────────────────────────────────

fn fillCWorkerInfo(alloc: std.mem.Allocator, w: *const worktree.Worker) !CWorkerInfo {
    const name = try alloc.dupeZ(u8, w.name); errdefer alloc.free(name);
    const task = try alloc.dupeZ(u8, w.task_description); errdefer alloc.free(task);
    const branch = try alloc.dupeZ(u8, w.branch_name); errdefer alloc.free(branch);
    const wt_path = try alloc.dupeZ(u8, w.worktree_path); errdefer alloc.free(wt_path);
    const binary = try alloc.dupeZ(u8, w.agent_binary); errdefer alloc.free(binary);
    const model_z = try alloc.dupeZ(u8, w.model);
    return .{ .id = w.id, .name = name.ptr, .task_description = task.ptr, .branch_name = branch.ptr,
        .worktree_path = wt_path.ptr, .status = @intFromEnum(w.status), .agent_type = @intFromEnum(w.agent_type),
        .agent_binary = binary.ptr, .model = model_z.ptr, .spawned_at = w.spawned_at };
}

fn freeCWorkerInfo(info: CWorkerInfo) void {
    freeNullTerminated(info.name); freeNullTerminated(info.task_description);
    freeNullTerminated(info.branch_name); freeNullTerminated(info.worktree_path);
    freeNullTerminated(info.agent_binary); freeNullTerminated(info.model);
}

fn freeNullTerminated(ptr: ?[*:0]const u8) void {
    if (ptr) |p| std.heap.c_allocator.free(std.mem.span(p));
}

/// Escape all JSON-special characters per RFC 8259 for safe interpolation into JSON values.
/// Handles: " \ and all control characters U+0000..U+001F.
/// Caller must free the returned slice.
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

    // Worst case: control chars become \uXXXX (6 bytes each)
    const buf = try allocator.alloc(u8, input.len * 6);
    const hex = "0123456789abcdef";
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
            0x08 => { // \b backspace
                buf[pos] = '\\';
                buf[pos + 1] = 'b';
                pos += 2;
            },
            0x0C => { // \f form feed
                buf[pos] = '\\';
                buf[pos + 1] = 'f';
                pos += 2;
            },
            0x00...0x07, 0x0B, 0x0E...0x1F => {
                // Other control chars: escape as \u00XX
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
    // Shrink to actual size
    if (pos < buf.len) {
        return allocator.realloc(buf, pos) catch {
            return buf[0..pos];
        };
    }
    return buf;
}

fn fillCConflict(alloc: std.mem.Allocator, c: merge.Conflict) !CConflict {
    const fp = try alloc.dupeZ(u8, c.file_path); errdefer alloc.free(fp);
    const ct = try alloc.dupeZ(u8, c.conflict_type); errdefer alloc.free(ct);
    const ours = try alloc.dupeZ(u8, c.ours); errdefer alloc.free(ours);
    const theirs = try alloc.dupeZ(u8, c.theirs);
    return .{ .file_path = fp.ptr, .conflict_type = ct.ptr, .ours = ours.ptr, .theirs = theirs.ptr };
}

fn freeCConflict(ptr: ?*CConflict) void {
    const cc = ptr orelse return;
    freeNullTerminated(cc.file_path); freeNullTerminated(cc.conflict_type);
    freeNullTerminated(cc.ours); freeNullTerminated(cc.theirs);
    std.heap.c_allocator.destroy(cc);
}

fn fillCRole(alloc: std.mem.Allocator, rd: *const config.RoleDefinition) !*CRole {
    const c_role = try alloc.create(CRole);
    errdefer alloc.destroy(c_role);

    const id_z = try alloc.dupeZ(u8, rd.id); errdefer alloc.free(id_z);
    const name_z = try alloc.dupeZ(u8, rd.name); errdefer alloc.free(name_z);
    const div_z = try alloc.dupeZ(u8, rd.division); errdefer alloc.free(div_z);
    const emoji_z = try alloc.dupeZ(u8, rd.emoji); errdefer alloc.free(emoji_z);
    const desc_z = try alloc.dupeZ(u8, rd.description); errdefer alloc.free(desc_z);

    const wp = try dupeStringArray(alloc, rd.write_patterns);
    errdefer freeNullTerminatedArray(alloc, wp, @intCast(rd.write_patterns.len));
    const dwp = try dupeStringArray(alloc, rd.deny_write_patterns);
    errdefer freeNullTerminatedArray(alloc, dwp, @intCast(rd.deny_write_patterns.len));

    c_role.* = .{
        .id = id_z.ptr,
        .name = name_z.ptr,
        .division = div_z.ptr,
        .emoji = emoji_z.ptr,
        .description = desc_z.ptr,
        .write_patterns = if (wp.len > 0) wp.ptr else null,
        .write_pattern_count = @intCast(rd.write_patterns.len),
        .deny_write_patterns = if (dwp.len > 0) dwp.ptr else null,
        .deny_write_pattern_count = @intCast(rd.deny_write_patterns.len),
        .can_push = rd.can_push,
        .can_merge = rd.can_merge,
    };
    return c_role;
}

fn freeCRole(role: *CRole) void {
    freeNullTerminated(role.id);
    freeNullTerminated(role.name);
    freeNullTerminated(role.division);
    freeNullTerminated(role.emoji);
    freeNullTerminated(role.description);
    freeNullTerminatedArray(std.heap.c_allocator, if (role.write_patterns) |p| p[0..role.write_pattern_count] else &.{}, role.write_pattern_count);
    freeNullTerminatedArray(std.heap.c_allocator, if (role.deny_write_patterns) |p| p[0..role.deny_write_pattern_count] else &.{}, role.deny_write_pattern_count);
}

fn dupeStringArray(alloc: std.mem.Allocator, strings: [][]const u8) ![]?[*:0]const u8 {
    const result = try alloc.alloc(?[*:0]const u8, strings.len);
    var filled: usize = 0;
    errdefer {
        for (0..filled) |i| freeNullTerminated(result[i]);
        alloc.free(result);
    }
    for (strings, 0..) |s, i| {
        const z = try alloc.dupeZ(u8, s);
        result[i] = z.ptr;
        filled += 1;
    }
    return result;
}

fn freeNullTerminatedArray(alloc: std.mem.Allocator, arr: []?[*:0]const u8, count: u32) void {
    for (0..count) |i| freeNullTerminated(arr[i]);
    if (count > 0) alloc.free(arr);
}

// ─── Tests ───────────────────────────────────────────────

test "version returns 0.1.0" { try std.testing.expectEqualStrings("0.1.0", std.mem.span(tm_version())); }

test "result_to_string maps all codes" {
    try std.testing.expectEqualStrings("TM_OK", std.mem.span(tm_result_to_string(0)));
    try std.testing.expectEqualStrings("TM_ERR_CONFIG", std.mem.span(tm_result_to_string(7)));
    try std.testing.expectEqualStrings("TM_ERR_NOT_IMPLEMENTED", std.mem.span(tm_result_to_string(10)));
    try std.testing.expectEqualStrings("TM_ERR_ROLE", std.mem.span(tm_result_to_string(13)));
    try std.testing.expectEqualStrings("TM_ERR_UNKNOWN", std.mem.span(tm_result_to_string(99)));
}

test "engine create and destroy via C API" {
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, "."); defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root); defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    const result = tm_engine_create(root_z.ptr, &engine_ptr);
    try std.testing.expect(result == 0);
    try std.testing.expect(engine_ptr != null);
    tm_engine_destroy(engine_ptr);
}

test "engine create with null returns error" {
    var engine_ptr: ?*Engine = null;
    try std.testing.expect(tm_engine_create(null, &engine_ptr) == 99);
    try std.testing.expect(engine_ptr == null);
}

test "tm_pty_send returns TM_ERR_NOT_IMPLEMENTED" { try std.testing.expect(tm_pty_send(null, 0, null) == 10); }
test "tm_pty_fd returns -1" { try std.testing.expect(tm_pty_fd(null, 0) == -1); }
test "tm_worker_spawn returns TM_WORKER_INVALID on null engine" { try std.testing.expect(tm_worker_spawn(null, null, 0, null, null) == 0xFFFFFFFF); }

test "tm_merge_approve null engine returns TM_ERR_UNKNOWN" { try std.testing.expect(tm_merge_approve(null, 0, null) == 99); }
test "tm_merge_reject null engine returns TM_ERR_UNKNOWN" { try std.testing.expect(tm_merge_reject(null, 0) == 99); }
test "tm_merge_get_status null engine returns PENDING" { try std.testing.expect(tm_merge_get_status(null, 0) == 0); }
test "tm_merge_conflicts_get null returns null" {
    var count: u32 = 42;
    try std.testing.expect(tm_merge_conflicts_get(null, 0, &count) == null);
    try std.testing.expect(count == 0);
}
test "tm_merge_conflicts_free handles null" { tm_merge_conflicts_free(null, 0); }

// ─── Role API tests ──────────────────────────────────────

test "tm_role_resolve null engine returns TM_ERR_UNKNOWN" {
    try std.testing.expect(tm_role_resolve(null, null, null) == 99);
}

test "tm_role_resolve null role_id returns TM_ERR_ROLE" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);
    try std.testing.expect(tm_role_resolve(engine_ptr, null, null) == 13);
}

test "tm_role_resolve missing role returns TM_ERR_ROLE" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);
    var out_role: ?*CRole = null;
    const role_id = try std.testing.allocator.dupeZ(u8, "nonexistent-role");
    defer std.testing.allocator.free(role_id);
    try std.testing.expect(tm_role_resolve(engine_ptr, role_id.ptr, &out_role) == 13);
    try std.testing.expect(out_role == null);
}

test "tm_role_resolve finds and parses role" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);

    // Create role file in project-local path
    try tmp.dir.makePath(".teammux/roles");
    try tmp.dir.writeFile(.{
        .sub_path = ".teammux/roles/test-resolve.toml",
        .data =
        \\[identity]
        \\id = "test-resolve"
        \\name = "Test Resolve Role"
        \\division = "testing"
        \\emoji = "t"
        \\description = "for testing resolve"
        \\
        \\[capabilities]
        \\write = ["src/**"]
        \\deny_write = ["infra/**"]
        \\can_push = false
        \\can_merge = false
        \\
        \\[triggers_on]
        \\events = []
        \\
        \\[context]
        \\mission = "test"
        \\focus = "test"
        \\deliverables = []
        \\rules = []
        \\workflow = []
        \\success_metrics = []
        ,
    });

    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);

    var out_role: ?*CRole = null;
    const role_id = try std.testing.allocator.dupeZ(u8, "test-resolve");
    defer std.testing.allocator.free(role_id);
    const result = tm_role_resolve(engine_ptr, role_id.ptr, &out_role);
    try std.testing.expect(result == 0);
    try std.testing.expect(out_role != null);
    defer tm_role_free(out_role);

    try std.testing.expectEqualStrings("test-resolve", std.mem.span(out_role.?.id.?));
    try std.testing.expectEqualStrings("Test Resolve Role", std.mem.span(out_role.?.name.?));
    try std.testing.expect(out_role.?.write_pattern_count == 1);
    try std.testing.expect(out_role.?.deny_write_pattern_count == 1);
}

test "tm_role_free handles null" {
    tm_role_free(null);
}

test "tm_roles_list null engine returns null" {
    var count: u32 = 42;
    try std.testing.expect(tm_roles_list(null, &count) == null);
    try std.testing.expect(count == 0);
}

test "tm_roles_list_free handles null" {
    tm_roles_list_free(null, 0);
}

test "tm_roles_list finds roles in project directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);

    try tmp.dir.makePath(".teammux/roles");
    const role_toml =
        \\[identity]
        \\id = "list-role"
        \\name = "List Role"
        \\division = "testing"
        \\emoji = "l"
        \\description = "for listing"
        \\
        \\[capabilities]
        \\write = []
        \\deny_write = []
        \\can_push = false
        \\can_merge = false
        \\
        \\[triggers_on]
        \\events = []
        \\
        \\[context]
        \\mission = "test"
        \\focus = "test"
        \\deliverables = []
        \\rules = []
        \\workflow = []
        \\success_metrics = []
    ;
    try tmp.dir.writeFile(.{ .sub_path = ".teammux/roles/list-role.toml", .data = role_toml });

    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);

    var count: u32 = 0;
    const roles = tm_roles_list(engine_ptr, &count);
    try std.testing.expect(count >= 1);
    try std.testing.expect(roles != null);
    defer tm_roles_list_free(roles, count);

    // Find our role in the list
    var found = false;
    for (0..count) |i| {
        if (roles.?[i]) |r| {
            if (r.id) |id| {
                if (std.mem.eql(u8, std.mem.span(id), "list-role")) {
                    found = true;
                    break;
                }
            }
        }
    }
    try std.testing.expect(found);
}

// ─── Bundled roles API tests ─────────────────────────────

test "tm_roles_list_bundled null count pointer returns null even with roles present" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);

    try tmp.dir.makePath(".teammux/roles");
    try tmp.dir.writeFile(.{
        .sub_path = ".teammux/roles/null-count.toml",
        .data =
        \\[identity]
        \\id = "null-count"
        \\name = "Null Count"
        \\division = "testing"
        \\emoji = "n"
        \\description = "test"
        \\
        \\[capabilities]
        \\write = []
        \\deny_write = []
        \\can_push = false
        \\can_merge = false
        \\
        \\[triggers_on]
        \\events = []
        \\
        \\[context]
        \\mission = "test"
        \\focus = "test"
        \\deliverables = []
        \\rules = []
        \\workflow = []
        \\success_metrics = []
        ,
    });

    // Roles exist but count is null — must return null (caller can't free without count)
    try std.testing.expect(tm_roles_list_bundled(root_z.ptr, null) == null);
}

test "tm_roles_list_bundled null project_root returns null gracefully" {
    var count: u32 = 42;
    // No bundled/dev paths exist in test runner — returns null with count=0
    const result = tm_roles_list_bundled(null, &count);
    if (result) |r| {
        defer tm_roles_list_bundled_free(r, count);
    } else {
        try std.testing.expect(count == 0);
    }
}

test "tm_roles_list_bundled empty roles directory returns null" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);

    try tmp.dir.makePath(".teammux/roles");

    var count: u32 = 42;
    const result = tm_roles_list_bundled(root_z.ptr, &count);
    // Empty directory — no roles found, count should be 0
    if (result) |r| {
        defer tm_roles_list_bundled_free(r, count);
    } else {
        try std.testing.expect(count == 0);
    }
}

test "tm_roles_list_bundled skips malformed TOML gracefully" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);

    try tmp.dir.makePath(".teammux/roles");
    // One valid role
    const valid_toml =
        \\[identity]
        \\id = "valid-role"
        \\name = "Valid"
        \\division = "testing"
        \\emoji = "v"
        \\description = "valid role"
        \\
        \\[capabilities]
        \\write = []
        \\deny_write = []
        \\can_push = false
        \\can_merge = false
        \\
        \\[triggers_on]
        \\events = []
        \\
        \\[context]
        \\mission = "test"
        \\focus = "test"
        \\deliverables = []
        \\rules = []
        \\workflow = []
        \\success_metrics = []
    ;
    try tmp.dir.writeFile(.{ .sub_path = ".teammux/roles/valid-role.toml", .data = valid_toml });
    // One malformed role
    try tmp.dir.writeFile(.{ .sub_path = ".teammux/roles/broken-role.toml", .data = "this is not valid toml {{{{" });

    var count: u32 = 0;
    const roles = tm_roles_list_bundled(root_z.ptr, &count);
    try std.testing.expect(roles != null);
    try std.testing.expect(count >= 1);
    defer tm_roles_list_bundled_free(roles, count);

    // Valid role should still be found despite the broken one
    var found_valid = false;
    for (0..count) |i| {
        if (roles.?[i]) |r| {
            if (r.id) |id| {
                if (std.mem.eql(u8, std.mem.span(id), "valid-role")) {
                    found_valid = true;
                    break;
                }
            }
        }
    }
    try std.testing.expect(found_valid);
}

test "tm_roles_list_bundled finds roles in project directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);

    try tmp.dir.makePath(".teammux/roles");
    const role_toml =
        \\[identity]
        \\id = "bundled-test"
        \\name = "Bundled Test Role"
        \\division = "testing"
        \\emoji = "b"
        \\description = "for bundled listing"
        \\
        \\[capabilities]
        \\write = []
        \\deny_write = []
        \\can_push = false
        \\can_merge = false
        \\
        \\[triggers_on]
        \\events = []
        \\
        \\[context]
        \\mission = "test"
        \\focus = "test"
        \\deliverables = []
        \\rules = []
        \\workflow = []
        \\success_metrics = []
    ;
    try tmp.dir.writeFile(.{ .sub_path = ".teammux/roles/bundled-test.toml", .data = role_toml });

    var count: u32 = 0;
    const roles = tm_roles_list_bundled(root_z.ptr, &count);
    try std.testing.expect(count >= 1);
    try std.testing.expect(roles != null);
    defer tm_roles_list_bundled_free(roles, count);

    var found = false;
    for (0..count) |i| {
        if (roles.?[i]) |r| {
            if (r.id) |id| {
                if (std.mem.eql(u8, std.mem.span(id), "bundled-test")) {
                    found = true;
                    break;
                }
            }
        }
    }
    try std.testing.expect(found);
}

test "tm_roles_list_bundled_free handles null" {
    tm_roles_list_bundled_free(null, 0);
}

test "tm_roles_list_bundled finds multiple roles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);

    try tmp.dir.makePath(".teammux/roles");
    const toml_a =
        \\[identity]
        \\id = "role-a"
        \\name = "Role A"
        \\division = "alpha"
        \\emoji = "a"
        \\description = "first role"
        \\
        \\[capabilities]
        \\write = []
        \\deny_write = []
        \\can_push = false
        \\can_merge = false
        \\
        \\[triggers_on]
        \\events = []
        \\
        \\[context]
        \\mission = "test"
        \\focus = "test"
        \\deliverables = []
        \\rules = []
        \\workflow = []
        \\success_metrics = []
    ;
    const toml_b =
        \\[identity]
        \\id = "role-b"
        \\name = "Role B"
        \\division = "beta"
        \\emoji = "b"
        \\description = "second role"
        \\
        \\[capabilities]
        \\write = ["src/**"]
        \\deny_write = ["infra/**"]
        \\can_push = true
        \\can_merge = false
        \\
        \\[triggers_on]
        \\events = []
        \\
        \\[context]
        \\mission = "test"
        \\focus = "test"
        \\deliverables = []
        \\rules = []
        \\workflow = []
        \\success_metrics = []
    ;
    try tmp.dir.writeFile(.{ .sub_path = ".teammux/roles/role-a.toml", .data = toml_a });
    try tmp.dir.writeFile(.{ .sub_path = ".teammux/roles/role-b.toml", .data = toml_b });

    var count: u32 = 0;
    const roles = tm_roles_list_bundled(root_z.ptr, &count);
    try std.testing.expect(count >= 2);
    try std.testing.expect(roles != null);
    defer tm_roles_list_bundled_free(roles, count);

    var found_a = false;
    var found_b = false;
    for (0..count) |i| {
        if (roles.?[i]) |r| {
            if (r.id) |id| {
                const name = std.mem.span(id);
                if (std.mem.eql(u8, name, "role-a")) found_a = true;
                if (std.mem.eql(u8, name, "role-b")) found_b = true;
            }
        }
    }
    try std.testing.expect(found_a);
    try std.testing.expect(found_b);
}

// ─── Ownership API tests ─────────────────────────────────

test "tm_ownership_check null engine returns TM_ERR_UNKNOWN" {
    try std.testing.expect(tm_ownership_check(null, 0, null, null) == 99);
}

test "tm_ownership_register null engine returns TM_ERR_UNKNOWN" {
    try std.testing.expect(tm_ownership_register(null, 0, null, false) == 99);
}

test "tm_ownership_release null engine returns TM_ERR_UNKNOWN" {
    try std.testing.expect(tm_ownership_release(null, 0) == 99);
}

test "tm_ownership_get null engine returns null" {
    var count: u32 = 42;
    try std.testing.expect(tm_ownership_get(null, 0, &count) == null);
    try std.testing.expect(count == 0);
}

test "tm_ownership_free handles null" {
    tm_ownership_free(null, 0);
}

test "tm_ownership_check null out_allowed returns TM_ERR_OWNERSHIP" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);
    const path_z = try std.testing.allocator.dupeZ(u8, "src/foo.ts");
    defer std.testing.allocator.free(path_z);
    try std.testing.expect(tm_ownership_check(engine_ptr, 1, path_z.ptr, null) == 14);
}

test "tm_ownership_check null file_path returns TM_ERR_OWNERSHIP" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);
    var allowed: bool = false;
    try std.testing.expect(tm_ownership_check(engine_ptr, 1, null, &allowed) == 14);
}

test "tm_ownership_register null pattern returns TM_ERR_OWNERSHIP" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);
    try std.testing.expect(tm_ownership_register(engine_ptr, 1, null, true) == 14);
}

test "tm_ownership full cycle: register → check → release → check" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);

    // Register write + deny patterns
    const write_pat = try std.testing.allocator.dupeZ(u8, "src/frontend/**");
    defer std.testing.allocator.free(write_pat);
    const deny_pat = try std.testing.allocator.dupeZ(u8, "src/backend/**");
    defer std.testing.allocator.free(deny_pat);

    try std.testing.expect(tm_ownership_register(engine_ptr, 1, write_pat.ptr, true) == 0);
    try std.testing.expect(tm_ownership_register(engine_ptr, 1, deny_pat.ptr, false) == 0);

    // Check allowed path
    var allowed: bool = false;
    const allowed_path = try std.testing.allocator.dupeZ(u8, "src/frontend/App.tsx");
    defer std.testing.allocator.free(allowed_path);
    try std.testing.expect(tm_ownership_check(engine_ptr, 1, allowed_path.ptr, &allowed) == 0);
    try std.testing.expect(allowed == true);

    // Check denied path
    const denied_path = try std.testing.allocator.dupeZ(u8, "src/backend/server.ts");
    defer std.testing.allocator.free(denied_path);
    try std.testing.expect(tm_ownership_check(engine_ptr, 1, denied_path.ptr, &allowed) == 0);
    try std.testing.expect(allowed == false);

    // Release
    try std.testing.expect(tm_ownership_release(engine_ptr, 1) == 0);

    // After release, default allow
    try std.testing.expect(tm_ownership_check(engine_ptr, 1, denied_path.ptr, &allowed) == 0);
    try std.testing.expect(allowed == true);
}

test "tm_ownership_get returns correct entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);

    const pat1 = try std.testing.allocator.dupeZ(u8, "src/**");
    defer std.testing.allocator.free(pat1);
    const pat2 = try std.testing.allocator.dupeZ(u8, "infra/**");
    defer std.testing.allocator.free(pat2);

    try std.testing.expect(tm_ownership_register(engine_ptr, 1, pat1.ptr, true) == 0);
    try std.testing.expect(tm_ownership_register(engine_ptr, 1, pat2.ptr, false) == 0);

    var count: u32 = 0;
    const entries = tm_ownership_get(engine_ptr, 1, &count);
    try std.testing.expect(count == 2);
    try std.testing.expect(entries != null);
    defer tm_ownership_free(entries, count);

    // Verify first entry
    try std.testing.expect(entries.?[0] != null);
    try std.testing.expectEqualStrings("src/**", std.mem.span(entries.?[0].?.path_pattern.?));
    try std.testing.expect(entries.?[0].?.worker_id == 1);
    try std.testing.expect(entries.?[0].?.allow_write == true);

    // Verify second entry
    try std.testing.expect(entries.?[1] != null);
    try std.testing.expectEqualStrings("infra/**", std.mem.span(entries.?[1].?.path_pattern.?));
    try std.testing.expect(entries.?[1].?.worker_id == 1);
    try std.testing.expect(entries.?[1].?.allow_write == false);
}

test "tm_ownership_get returns null when no rules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);

    var count: u32 = 42;
    try std.testing.expect(tm_ownership_get(engine_ptr, 99, &count) == null);
    try std.testing.expect(count == 0);
}

test "tm_ownership_update null engine returns TM_ERR_UNKNOWN" {
    try std.testing.expect(tm_ownership_update(null, 0, null, 0, null, 0) == 99);
}

test "tm_ownership_update null write_patterns with non-zero count returns TM_ERR_OWNERSHIP" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);
    try std.testing.expect(tm_ownership_update(engine_ptr, 1, null, 2, null, 0) == 14);
}

test "tm_ownership_update null deny_patterns with non-zero count returns TM_ERR_OWNERSHIP" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);
    try std.testing.expect(tm_ownership_update(engine_ptr, 1, null, 0, null, 2) == 14);
}

test "tm_ownership_update replaces rules and check reflects new state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);

    // Register initial rules via register API
    const write_pat = try std.testing.allocator.dupeZ(u8, "src/frontend/**");
    defer std.testing.allocator.free(write_pat);
    const deny_pat = try std.testing.allocator.dupeZ(u8, "src/backend/**");
    defer std.testing.allocator.free(deny_pat);
    try std.testing.expect(tm_ownership_register(engine_ptr, 1, write_pat.ptr, true) == 0);
    try std.testing.expect(tm_ownership_register(engine_ptr, 1, deny_pat.ptr, false) == 0);

    // Verify initial state
    var allowed: bool = false;
    const frontend_path = try std.testing.allocator.dupeZ(u8, "src/frontend/App.tsx");
    defer std.testing.allocator.free(frontend_path);
    const backend_path = try std.testing.allocator.dupeZ(u8, "src/backend/server.ts");
    defer std.testing.allocator.free(backend_path);
    try std.testing.expect(tm_ownership_check(engine_ptr, 1, frontend_path.ptr, &allowed) == 0);
    try std.testing.expect(allowed == true);
    try std.testing.expect(tm_ownership_check(engine_ptr, 1, backend_path.ptr, &allowed) == 0);
    try std.testing.expect(allowed == false);

    // Update via tm_ownership_update: swap access
    const new_write = try std.testing.allocator.dupeZ(u8, "src/backend/**");
    defer std.testing.allocator.free(new_write);
    const new_deny = try std.testing.allocator.dupeZ(u8, "src/frontend/**");
    defer std.testing.allocator.free(new_deny);
    const w_ptrs = [_]?[*:0]const u8{new_write.ptr};
    const d_ptrs = [_]?[*:0]const u8{new_deny.ptr};
    try std.testing.expect(tm_ownership_update(engine_ptr, 1, &w_ptrs, 1, &d_ptrs, 1) == 0);

    // Verify updated state: frontend now denied, backend now allowed
    try std.testing.expect(tm_ownership_check(engine_ptr, 1, frontend_path.ptr, &allowed) == 0);
    try std.testing.expect(allowed == false);
    try std.testing.expect(tm_ownership_check(engine_ptr, 1, backend_path.ptr, &allowed) == 0);
    try std.testing.expect(allowed == true);
}

test "tm_ownership_update with zero counts and null patterns succeeds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);
    try std.testing.expect(tm_ownership_update(engine_ptr, 1, null, 0, null, 0) == 0);
}

test "tm_worker_dismiss releases ownership" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);
    const e = engine_ptr.?;

    // Set up a git repo so spawn/dismiss works
    try worktree.runGit(std.testing.allocator, root, &.{ "init", "-b", "main" });
    try worktree.runGit(std.testing.allocator, root, &.{ "config", "user.email", "test@test.com" });
    try worktree.runGit(std.testing.allocator, root, &.{ "config", "user.name", "Test" });
    const readme_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/README.md", .{root});
    defer std.testing.allocator.free(readme_path);
    const readme = try std.fs.createFileAbsolute(readme_path, .{});
    try readme.writeAll("# Test");
    readme.close();
    try worktree.runGit(std.testing.allocator, root, &.{ "add", "." });
    try worktree.runGit(std.testing.allocator, root, &.{ "commit", "-m", "initial" });

    // Spawn a worker
    const name_z = try std.testing.allocator.dupeZ(u8, "/usr/bin/echo");
    defer std.testing.allocator.free(name_z);
    const worker_z = try std.testing.allocator.dupeZ(u8, "TestWorker");
    defer std.testing.allocator.free(worker_z);
    const task_z = try std.testing.allocator.dupeZ(u8, "test task");
    defer std.testing.allocator.free(task_z);

    const worker_id = tm_worker_spawn(engine_ptr, name_z.ptr, 0, worker_z.ptr, task_z.ptr);
    try std.testing.expect(worker_id != 0xFFFFFFFF);

    // Register ownership rules for this worker
    const pat = try std.testing.allocator.dupeZ(u8, "src/**");
    defer std.testing.allocator.free(pat);
    try std.testing.expect(tm_ownership_register(engine_ptr, worker_id, pat.ptr, true) == 0);

    // Verify rules exist
    var allowed: bool = false;
    const check_path = try std.testing.allocator.dupeZ(u8, "src/foo.ts");
    defer std.testing.allocator.free(check_path);
    try std.testing.expect(tm_ownership_check(engine_ptr, worker_id, check_path.ptr, &allowed) == 0);
    try std.testing.expect(allowed == true);

    // Dismiss worker — should release ownership
    try std.testing.expect(tm_worker_dismiss(engine_ptr, worker_id) == 0);

    // After dismiss, ownership released → default allow
    // Need to check on a fresh engine call (worker no longer in roster but registry is separate)
    try std.testing.expect(tm_ownership_check(engine_ptr, worker_id, check_path.ptr, &allowed) == 0);
    try std.testing.expect(allowed == true);

    // Verify rules are gone via getRules
    try std.testing.expect(e.ownership_registry.getRules(worker_id) == null);
}

test "tm_merge_reject releases ownership" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);
    const e = engine_ptr.?;

    // Set up a git repo so spawn works
    try worktree.runGit(std.testing.allocator, root, &.{ "init", "-b", "main" });
    try worktree.runGit(std.testing.allocator, root, &.{ "config", "user.email", "test@test.com" });
    try worktree.runGit(std.testing.allocator, root, &.{ "config", "user.name", "Test" });
    const readme_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/README.md", .{root});
    defer std.testing.allocator.free(readme_path);
    const readme = try std.fs.createFileAbsolute(readme_path, .{});
    try readme.writeAll("# Test");
    readme.close();
    try worktree.runGit(std.testing.allocator, root, &.{ "add", "." });
    try worktree.runGit(std.testing.allocator, root, &.{ "commit", "-m", "initial" });

    // Spawn a worker
    const name_z = try std.testing.allocator.dupeZ(u8, "/usr/bin/echo");
    defer std.testing.allocator.free(name_z);
    const worker_z = try std.testing.allocator.dupeZ(u8, "RejectWorker");
    defer std.testing.allocator.free(worker_z);
    const task_z = try std.testing.allocator.dupeZ(u8, "test reject");
    defer std.testing.allocator.free(task_z);

    const worker_id = tm_worker_spawn(engine_ptr, name_z.ptr, 0, worker_z.ptr, task_z.ptr);
    try std.testing.expect(worker_id != 0xFFFFFFFF);

    // Register ownership rules
    const pat = try std.testing.allocator.dupeZ(u8, "src/**");
    defer std.testing.allocator.free(pat);
    try std.testing.expect(tm_ownership_register(engine_ptr, worker_id, pat.ptr, true) == 0);

    // Verify rules exist
    try std.testing.expect(e.ownership_registry.getRules(worker_id) != null);

    // Reject merge — should release ownership
    try std.testing.expect(tm_merge_reject(engine_ptr, worker_id) == 0);

    // After reject, ownership released
    try std.testing.expect(e.ownership_registry.getRules(worker_id) == null);
}

test "tm_result_to_string maps TM_ERR_OWNERSHIP" {
    try std.testing.expectEqualStrings("TM_ERR_OWNERSHIP", std.mem.span(tm_result_to_string(14)));
}

test "tm_interceptor_install null engine returns TM_ERR_UNKNOWN" {
    try std.testing.expect(tm_interceptor_install(null, 0) == 99);
}

test "tm_interceptor_remove null engine returns TM_ERR_UNKNOWN" {
    try std.testing.expect(tm_interceptor_remove(null, 0) == 99);
}

test "tm_interceptor_path null engine returns null" {
    try std.testing.expect(tm_interceptor_path(null, 0) == null);
}

test "tm_interceptor_install creates wrapper and dismiss removes it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);

    // Set up a git repo
    try worktree.runGit(std.testing.allocator, root, &.{ "init", "-b", "main" });
    try worktree.runGit(std.testing.allocator, root, &.{ "config", "user.email", "test@test.com" });
    try worktree.runGit(std.testing.allocator, root, &.{ "config", "user.name", "Test" });
    const readme_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/README.md", .{root});
    defer std.testing.allocator.free(readme_path);
    const readme = try std.fs.createFileAbsolute(readme_path, .{});
    try readme.writeAll("# Test");
    readme.close();
    try worktree.runGit(std.testing.allocator, root, &.{ "add", "." });
    try worktree.runGit(std.testing.allocator, root, &.{ "commit", "-m", "initial" });

    // Spawn a worker
    const name_z = try std.testing.allocator.dupeZ(u8, "/usr/bin/echo");
    defer std.testing.allocator.free(name_z);
    const worker_z = try std.testing.allocator.dupeZ(u8, "Worker1");
    defer std.testing.allocator.free(worker_z);
    const task_z = try std.testing.allocator.dupeZ(u8, "test task");
    defer std.testing.allocator.free(task_z);

    const worker_id = tm_worker_spawn(engine_ptr, name_z.ptr, 0, worker_z.ptr, task_z.ptr);
    try std.testing.expect(worker_id != 0xFFFFFFFF);

    // Register deny patterns
    const deny_pat = try std.testing.allocator.dupeZ(u8, "src/backend/**");
    defer std.testing.allocator.free(deny_pat);
    try std.testing.expect(tm_ownership_register(engine_ptr, worker_id, deny_pat.ptr, false) == 0);
    const write_pat = try std.testing.allocator.dupeZ(u8, "src/frontend/**");
    defer std.testing.allocator.free(write_pat);
    try std.testing.expect(tm_ownership_register(engine_ptr, worker_id, write_pat.ptr, true) == 0);

    // Install interceptor
    try std.testing.expect(tm_interceptor_install(engine_ptr, worker_id) == 0);

    // Verify interceptor path is returned
    const ipath = tm_interceptor_path(engine_ptr, worker_id);
    try std.testing.expect(ipath != null);
    const ipath_str = std.mem.span(ipath.?);
    try std.testing.expect(std.mem.endsWith(u8, ipath_str, "/.git-wrapper"));
    tm_free_string(ipath);

    // Verify wrapper file exists with deny patterns
    const e = engine_ptr.?;
    const w = e.roster.getWorker(worker_id).?;
    const wrapper_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.git-wrapper/git", .{w.worktree_path});
    defer std.testing.allocator.free(wrapper_path);
    const file = try std.fs.openFileAbsolute(wrapper_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(std.testing.allocator, 64 * 1024);
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "src/backend/**") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "src/frontend/**") != null);

    // Dismiss — should remove wrapper
    const wt_path_copy = try std.testing.allocator.dupe(u8, w.worktree_path);
    defer std.testing.allocator.free(wt_path_copy);
    try std.testing.expect(tm_worker_dismiss(engine_ptr, worker_id) == 0);

    // After dismiss, interceptor path should return null (worker gone)
    try std.testing.expect(tm_interceptor_path(engine_ptr, worker_id) == null);
}

test "tm_interceptor_install no patterns creates pass-through" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);

    // Set up a git repo
    try worktree.runGit(std.testing.allocator, root, &.{ "init", "-b", "main" });
    try worktree.runGit(std.testing.allocator, root, &.{ "config", "user.email", "test@test.com" });
    try worktree.runGit(std.testing.allocator, root, &.{ "config", "user.name", "Test" });
    const readme_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/README.md", .{root});
    defer std.testing.allocator.free(readme_path);
    const readme = try std.fs.createFileAbsolute(readme_path, .{});
    try readme.writeAll("# Test");
    readme.close();
    try worktree.runGit(std.testing.allocator, root, &.{ "add", "." });
    try worktree.runGit(std.testing.allocator, root, &.{ "commit", "-m", "initial" });

    // Spawn a worker with NO ownership rules
    const name_z = try std.testing.allocator.dupeZ(u8, "/usr/bin/echo");
    defer std.testing.allocator.free(name_z);
    const worker_z = try std.testing.allocator.dupeZ(u8, "Worker4");
    defer std.testing.allocator.free(worker_z);
    const task_z = try std.testing.allocator.dupeZ(u8, "test task");
    defer std.testing.allocator.free(task_z);

    const worker_id = tm_worker_spawn(engine_ptr, name_z.ptr, 0, worker_z.ptr, task_z.ptr);
    try std.testing.expect(worker_id != 0xFFFFFFFF);

    // Install interceptor with no patterns — should create pass-through
    try std.testing.expect(tm_interceptor_install(engine_ptr, worker_id) == 0);

    // Verify wrapper is pass-through (no DENY_PATTERNS)
    const e = engine_ptr.?;
    const w = e.roster.getWorker(worker_id).?;
    const wrapper_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.git-wrapper/git", .{w.worktree_path});
    defer std.testing.allocator.free(wrapper_path);
    const file = try std.fs.openFileAbsolute(wrapper_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(std.testing.allocator, 64 * 1024);
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "DENY_PATTERNS") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "exec \"") != null);
}

test "tm_interceptor_install invalid worker returns TM_ERR_INVALID_WORKER" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);

    // Worker 999 does not exist
    try std.testing.expect(tm_interceptor_install(engine_ptr, 999) == 12);
}

test "tm_interceptor_remove invalid worker returns TM_ERR_INVALID_WORKER" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);

    // Worker 999 does not exist
    try std.testing.expect(tm_interceptor_remove(engine_ptr, 999) == 12);
}

test "tm_merge_reject removes interceptor wrapper" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);

    // Set up a git repo
    try worktree.runGit(std.testing.allocator, root, &.{ "init", "-b", "main" });
    try worktree.runGit(std.testing.allocator, root, &.{ "config", "user.email", "test@test.com" });
    try worktree.runGit(std.testing.allocator, root, &.{ "config", "user.name", "Test" });
    const readme_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/README.md", .{root});
    defer std.testing.allocator.free(readme_path);
    const readme = try std.fs.createFileAbsolute(readme_path, .{});
    try readme.writeAll("# Test");
    readme.close();
    try worktree.runGit(std.testing.allocator, root, &.{ "add", "." });
    try worktree.runGit(std.testing.allocator, root, &.{ "commit", "-m", "initial" });

    // Spawn a worker
    const name_z = try std.testing.allocator.dupeZ(u8, "/usr/bin/echo");
    defer std.testing.allocator.free(name_z);
    const worker_z = try std.testing.allocator.dupeZ(u8, "WorkerA");
    defer std.testing.allocator.free(worker_z);
    const task_z = try std.testing.allocator.dupeZ(u8, "test reject");
    defer std.testing.allocator.free(task_z);

    const worker_id = tm_worker_spawn(engine_ptr, name_z.ptr, 0, worker_z.ptr, task_z.ptr);
    try std.testing.expect(worker_id != 0xFFFFFFFF);

    // Register ownership and install interceptor
    const pat = try std.testing.allocator.dupeZ(u8, "src/**");
    defer std.testing.allocator.free(pat);
    try std.testing.expect(tm_ownership_register(engine_ptr, worker_id, pat.ptr, false) == 0);
    try std.testing.expect(tm_interceptor_install(engine_ptr, worker_id) == 0);

    // Verify interceptor is installed
    try std.testing.expect(tm_interceptor_path(engine_ptr, worker_id) != null);
    tm_free_string(tm_interceptor_path(engine_ptr, worker_id));

    // Reject merge — should remove interceptor and ownership
    try std.testing.expect(tm_merge_reject(engine_ptr, worker_id) == 0);

    // After reject, worker is gone so interceptor path returns null
    try std.testing.expect(tm_interceptor_path(engine_ptr, worker_id) == null);
}

// ─── Completion + Question signal tests ──────────────────

test "tm_worker_complete null engine returns TM_ERR_UNKNOWN" {
    try std.testing.expect(tm_worker_complete(null, 1, "done", null) == 99);
}

test "tm_worker_complete null summary returns TM_ERR_UNKNOWN" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);

    var engine_ptr: ?*Engine = null;
    try std.testing.expect(tm_engine_create(root_z.ptr, &engine_ptr) == 0);
    defer tm_engine_destroy(engine_ptr);

    try std.testing.expect(tm_worker_complete(engine_ptr, 1, null, null) == 99);
}

test "tm_worker_question null engine returns TM_ERR_UNKNOWN" {
    try std.testing.expect(tm_worker_question(null, 1, "help?", null) == 99);
}

test "tm_worker_question null question returns TM_ERR_UNKNOWN" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);

    var engine_ptr: ?*Engine = null;
    try std.testing.expect(tm_engine_create(root_z.ptr, &engine_ptr) == 0);
    defer tm_engine_destroy(engine_ptr);

    try std.testing.expect(tm_worker_question(engine_ptr, 1, null, null) == 99);
}

test "tm_completion_free handles null" { tm_completion_free(null); }
test "tm_question_free handles null" { tm_question_free(null); }

test "jsonEscape escapes quotes and backslashes" {
    const alloc = std.testing.allocator;
    const e1 = try jsonEscape(alloc, "done \"finally\"");
    defer alloc.free(e1);
    try std.testing.expectEqualStrings("done \\\"finally\\\"", e1);

    const e2 = try jsonEscape(alloc, "path\\to\\file");
    defer alloc.free(e2);
    try std.testing.expectEqualStrings("path\\\\to\\\\file", e2);

    const e3 = try jsonEscape(alloc, "line1\nline2\ttab");
    defer alloc.free(e3);
    try std.testing.expectEqualStrings("line1\\nline2\\ttab", e3);
}

test "jsonEscape escapes all JSON control characters (RFC 8259)" {
    const alloc = std.testing.allocator;

    const e1 = try jsonEscape(alloc, "a\x08b\x0Cc");
    defer alloc.free(e1);
    try std.testing.expectEqualStrings("a\\bb\\fc", e1);

    const e2 = try jsonEscape(alloc, "a\x01b\x1Fc");
    defer alloc.free(e2);
    try std.testing.expectEqualStrings("a\\u0001b\\u001fc", e2);

    const e3 = try jsonEscape(alloc, "a\x00b");
    defer alloc.free(e3);
    try std.testing.expectEqualStrings("a\\u0000b", e3);
}

test "jsonEscape fast path for clean strings" {
    const alloc = std.testing.allocator;
    const e = try jsonEscape(alloc, "no special chars");
    defer alloc.free(e);
    try std.testing.expectEqualStrings("no special chars", e);
}

test "jsonEscape empty string" {
    const alloc = std.testing.allocator;
    const e = try jsonEscape(alloc, "");
    defer alloc.free(e);
    try std.testing.expectEqualStrings("", e);
}

test "tm_worker_complete escapes quotes in summary" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    worktree.runGit(alloc, root, &.{ "init", "-b", "main" }) catch return;
    worktree.runGit(alloc, root, &.{ "config", "user.email", "test@test.com" }) catch return;
    worktree.runGit(alloc, root, &.{ "config", "user.name", "Test" }) catch return;
    const readme_path = try std.fmt.allocPrint(alloc, "{s}/README.md", .{root});
    defer alloc.free(readme_path);
    const readme = try std.fs.createFileAbsolute(readme_path, .{});
    try readme.writeAll("# Test");
    readme.close();
    worktree.runGit(alloc, root, &.{ "add", "." }) catch return;
    worktree.runGit(alloc, root, &.{ "commit", "-m", "initial" }) catch return;

    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);
    var engine_ptr: ?*Engine = null;
    try std.testing.expect(tm_engine_create(root_z.ptr, &engine_ptr) == 0);
    defer tm_engine_destroy(engine_ptr);

    const teammux_dir = try std.fmt.allocPrint(alloc, "{s}/.teammux", .{root});
    defer alloc.free(teammux_dir);
    std.fs.makeDirAbsolute(teammux_dir) catch {};
    const cfg_path = try std.fmt.allocPrint(alloc, "{s}/config.toml", .{teammux_dir});
    defer alloc.free(cfg_path);
    const cfg_file = try std.fs.createFileAbsolute(cfg_path, .{});
    try cfg_file.writeAll("[project]\nname = \"test\"\n");
    cfg_file.close();

    try std.testing.expect(tm_session_start(engine_ptr) == 0);

    const sum_z = try alloc.dupeZ(u8, "done \"finally\"");
    defer alloc.free(sum_z);
    try std.testing.expect(tm_worker_complete(engine_ptr, 1, sum_z.ptr, null) == 0);

    const e = engine_ptr.?;
    const log_path = e.message_bus.?.log_path;
    e.message_bus.?.log_file.?.close();
    e.message_bus.?.log_file = null;

    const log_content = try std.fs.cwd().openFile(log_path, .{});
    defer log_content.close();
    const content = try log_content.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "done \\\"finally\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "done \"finally\"") == null);
}

test "tm_worker_complete routes completion to JSONL log" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    worktree.runGit(alloc, root, &.{ "init", "-b", "main" }) catch return;
    worktree.runGit(alloc, root, &.{ "config", "user.email", "test@test.com" }) catch return;
    worktree.runGit(alloc, root, &.{ "config", "user.name", "Test" }) catch return;
    const readme_path = try std.fmt.allocPrint(alloc, "{s}/README.md", .{root});
    defer alloc.free(readme_path);
    const readme = try std.fs.createFileAbsolute(readme_path, .{});
    try readme.writeAll("# Test");
    readme.close();
    worktree.runGit(alloc, root, &.{ "add", "." }) catch return;
    worktree.runGit(alloc, root, &.{ "commit", "-m", "initial" }) catch return;

    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);
    var engine_ptr: ?*Engine = null;
    try std.testing.expect(tm_engine_create(root_z.ptr, &engine_ptr) == 0);
    defer tm_engine_destroy(engine_ptr);

    const teammux_dir = try std.fmt.allocPrint(alloc, "{s}/.teammux", .{root});
    defer alloc.free(teammux_dir);
    std.fs.makeDirAbsolute(teammux_dir) catch {};
    const cfg_path = try std.fmt.allocPrint(alloc, "{s}/config.toml", .{teammux_dir});
    defer alloc.free(cfg_path);
    const cfg_file = try std.fs.createFileAbsolute(cfg_path, .{});
    try cfg_file.writeAll("[project]\nname = \"test\"\n");
    cfg_file.close();

    try std.testing.expect(tm_session_start(engine_ptr) == 0);

    const summary_z = try alloc.dupeZ(u8, "auth module done");
    defer alloc.free(summary_z);
    const details_z = try alloc.dupeZ(u8, "JWT implementation complete");
    defer alloc.free(details_z);
    try std.testing.expect(tm_worker_complete(engine_ptr, 3, summary_z.ptr, details_z.ptr) == 0);

    const e = engine_ptr.?;
    const log_path = e.message_bus.?.log_path;
    e.message_bus.?.log_file.?.close();
    e.message_bus.?.log_file = null;

    const log_content = try std.fs.cwd().openFile(log_path, .{});
    defer log_content.close();
    const content = try log_content.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "\"type\":\"completion\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"from\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"to\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "auth module done") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "JWT implementation complete") != null);
}

test "tm_worker_question routes question to JSONL log" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    worktree.runGit(alloc, root, &.{ "init", "-b", "main" }) catch return;
    worktree.runGit(alloc, root, &.{ "config", "user.email", "test@test.com" }) catch return;
    worktree.runGit(alloc, root, &.{ "config", "user.name", "Test" }) catch return;
    const readme_path = try std.fmt.allocPrint(alloc, "{s}/README.md", .{root});
    defer alloc.free(readme_path);
    const readme = try std.fs.createFileAbsolute(readme_path, .{});
    try readme.writeAll("# Test");
    readme.close();
    worktree.runGit(alloc, root, &.{ "add", "." }) catch return;
    worktree.runGit(alloc, root, &.{ "commit", "-m", "initial" }) catch return;

    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);
    var engine_ptr: ?*Engine = null;
    try std.testing.expect(tm_engine_create(root_z.ptr, &engine_ptr) == 0);
    defer tm_engine_destroy(engine_ptr);

    const teammux_dir = try std.fmt.allocPrint(alloc, "{s}/.teammux", .{root});
    defer alloc.free(teammux_dir);
    std.fs.makeDirAbsolute(teammux_dir) catch {};
    const cfg_path = try std.fmt.allocPrint(alloc, "{s}/config.toml", .{teammux_dir});
    defer alloc.free(cfg_path);
    const cfg_file = try std.fs.createFileAbsolute(cfg_path, .{});
    try cfg_file.writeAll("[project]\nname = \"test\"\n");
    cfg_file.close();

    try std.testing.expect(tm_session_start(engine_ptr) == 0);

    const q_z = try alloc.dupeZ(u8, "JWT or session tokens?");
    defer alloc.free(q_z);
    const ctx_z = try alloc.dupeZ(u8, "auth module design");
    defer alloc.free(ctx_z);
    try std.testing.expect(tm_worker_question(engine_ptr, 5, q_z.ptr, ctx_z.ptr) == 0);

    const e = engine_ptr.?;
    const log_path = e.message_bus.?.log_path;
    e.message_bus.?.log_file.?.close();
    e.message_bus.?.log_file = null;

    const log_content = try std.fs.cwd().openFile(log_path, .{});
    defer log_content.close();
    const content = try log_content.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "\"type\":\"question\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"from\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"to\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "JWT or session tokens?") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "auth module design") != null);
}

test "tm_worker_complete with null details succeeds" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    worktree.runGit(alloc, root, &.{ "init", "-b", "main" }) catch return;
    worktree.runGit(alloc, root, &.{ "config", "user.email", "test@test.com" }) catch return;
    worktree.runGit(alloc, root, &.{ "config", "user.name", "Test" }) catch return;
    const readme_path = try std.fmt.allocPrint(alloc, "{s}/README.md", .{root});
    defer alloc.free(readme_path);
    const readme = try std.fs.createFileAbsolute(readme_path, .{});
    try readme.writeAll("# Test");
    readme.close();
    worktree.runGit(alloc, root, &.{ "add", "." }) catch return;
    worktree.runGit(alloc, root, &.{ "commit", "-m", "initial" }) catch return;

    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);
    var engine_ptr: ?*Engine = null;
    try std.testing.expect(tm_engine_create(root_z.ptr, &engine_ptr) == 0);
    defer tm_engine_destroy(engine_ptr);

    const teammux_dir = try std.fmt.allocPrint(alloc, "{s}/.teammux", .{root});
    defer alloc.free(teammux_dir);
    std.fs.makeDirAbsolute(teammux_dir) catch {};
    const cfg_path = try std.fmt.allocPrint(alloc, "{s}/config.toml", .{teammux_dir});
    defer alloc.free(cfg_path);
    const cfg_file = try std.fs.createFileAbsolute(cfg_path, .{});
    try cfg_file.writeAll("[project]\nname = \"test\"\n");
    cfg_file.close();

    try std.testing.expect(tm_session_start(engine_ptr) == 0);

    const summary_z = try alloc.dupeZ(u8, "task finished");
    defer alloc.free(summary_z);
    try std.testing.expect(tm_worker_complete(engine_ptr, 1, summary_z.ptr, null) == 0);
}

// ─── Completion history C API tests (TD16) ───────────────

test "tm_history_load null engine returns null" {
    var count: u32 = 99;
    try std.testing.expect(tm_history_load(null, &count) == null);
    try std.testing.expect(count == 0);
}

test "tm_history_clear null engine returns TM_ERR_UNKNOWN" {
    try std.testing.expect(tm_history_clear(null) == 99);
}

test "tm_history_free handles null" {
    tm_history_free(null, 0);
}

test "tm_worker_complete persists to history JSONL via C API" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    worktree.runGit(alloc, root, &.{ "init", "-b", "main" }) catch return;
    worktree.runGit(alloc, root, &.{ "config", "user.email", "test@test.com" }) catch return;
    worktree.runGit(alloc, root, &.{ "config", "user.name", "Test" }) catch return;
    const readme_path = try std.fmt.allocPrint(alloc, "{s}/README.md", .{root});
    defer alloc.free(readme_path);
    {
        const readme = try std.fs.createFileAbsolute(readme_path, .{});
        try readme.writeAll("# Test");
        readme.close();
    }
    worktree.runGit(alloc, root, &.{ "add", "." }) catch return;
    worktree.runGit(alloc, root, &.{ "commit", "-m", "initial" }) catch return;

    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);
    var engine_ptr: ?*Engine = null;
    try std.testing.expect(tm_engine_create(root_z.ptr, &engine_ptr) == 0);
    defer tm_engine_destroy(engine_ptr);

    const teammux_dir = try std.fmt.allocPrint(alloc, "{s}/.teammux", .{root});
    defer alloc.free(teammux_dir);
    std.fs.makeDirAbsolute(teammux_dir) catch {};
    const cfg_path = try std.fmt.allocPrint(alloc, "{s}/config.toml", .{teammux_dir});
    defer alloc.free(cfg_path);
    {
        const cfg_file = try std.fs.createFileAbsolute(cfg_path, .{});
        try cfg_file.writeAll("[project]\nname = \"test\"\n");
        cfg_file.close();
    }

    try std.testing.expect(tm_session_start(engine_ptr) == 0);

    const summary_z = try alloc.dupeZ(u8, "auth module done");
    defer alloc.free(summary_z);
    const details_z = try alloc.dupeZ(u8, "JWT complete");
    defer alloc.free(details_z);
    try std.testing.expect(tm_worker_complete(engine_ptr, 3, summary_z.ptr, details_z.ptr) == 0);

    // Load via C API
    var count: u32 = 0;
    const entries = tm_history_load(engine_ptr, &count);
    defer tm_history_free(entries, count);

    try std.testing.expect(count == 1);
    try std.testing.expect(entries != null);
    const entry = entries.?[0].?;
    try std.testing.expectEqualStrings("completion", std.mem.span(entry.entry_type.?));
    try std.testing.expect(entry.worker_id == 3);
    try std.testing.expectEqualStrings("auth module done", std.mem.span(entry.content.?));
    try std.testing.expect(entry.timestamp > 0);
}

test "tm_worker_question persists to history JSONL via C API" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    worktree.runGit(alloc, root, &.{ "init", "-b", "main" }) catch return;
    worktree.runGit(alloc, root, &.{ "config", "user.email", "test@test.com" }) catch return;
    worktree.runGit(alloc, root, &.{ "config", "user.name", "Test" }) catch return;
    const readme_path = try std.fmt.allocPrint(alloc, "{s}/README.md", .{root});
    defer alloc.free(readme_path);
    {
        const readme = try std.fs.createFileAbsolute(readme_path, .{});
        try readme.writeAll("# Test");
        readme.close();
    }
    worktree.runGit(alloc, root, &.{ "add", "." }) catch return;
    worktree.runGit(alloc, root, &.{ "commit", "-m", "initial" }) catch return;

    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);
    var engine_ptr: ?*Engine = null;
    try std.testing.expect(tm_engine_create(root_z.ptr, &engine_ptr) == 0);
    defer tm_engine_destroy(engine_ptr);

    const teammux_dir = try std.fmt.allocPrint(alloc, "{s}/.teammux", .{root});
    defer alloc.free(teammux_dir);
    std.fs.makeDirAbsolute(teammux_dir) catch {};
    const cfg_path = try std.fmt.allocPrint(alloc, "{s}/config.toml", .{teammux_dir});
    defer alloc.free(cfg_path);
    {
        const cfg_file = try std.fs.createFileAbsolute(cfg_path, .{});
        try cfg_file.writeAll("[project]\nname = \"test\"\n");
        cfg_file.close();
    }

    try std.testing.expect(tm_session_start(engine_ptr) == 0);

    const q_z = try alloc.dupeZ(u8, "JWT or session tokens?");
    defer alloc.free(q_z);
    const ctx_z = try alloc.dupeZ(u8, "auth module");
    defer alloc.free(ctx_z);
    try std.testing.expect(tm_worker_question(engine_ptr, 5, q_z.ptr, ctx_z.ptr) == 0);

    // Load via C API
    var count: u32 = 0;
    const entries = tm_history_load(engine_ptr, &count);
    defer tm_history_free(entries, count);

    try std.testing.expect(count == 1);
    try std.testing.expect(entries != null);
    const entry = entries.?[0].?;
    try std.testing.expectEqualStrings("question", std.mem.span(entry.entry_type.?));
    try std.testing.expect(entry.worker_id == 5);
    try std.testing.expectEqualStrings("JWT or session tokens?", std.mem.span(entry.content.?));
    try std.testing.expect(entry.git_commit == null);
    try std.testing.expect(entry.timestamp > 0);
}

test "tm_history_clear clears and load returns empty" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    worktree.runGit(alloc, root, &.{ "init", "-b", "main" }) catch return;
    worktree.runGit(alloc, root, &.{ "config", "user.email", "test@test.com" }) catch return;
    worktree.runGit(alloc, root, &.{ "config", "user.name", "Test" }) catch return;
    const readme_path = try std.fmt.allocPrint(alloc, "{s}/README.md", .{root});
    defer alloc.free(readme_path);
    {
        const readme = try std.fs.createFileAbsolute(readme_path, .{});
        try readme.writeAll("# Test");
        readme.close();
    }
    worktree.runGit(alloc, root, &.{ "add", "." }) catch return;
    worktree.runGit(alloc, root, &.{ "commit", "-m", "initial" }) catch return;

    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);
    var engine_ptr: ?*Engine = null;
    try std.testing.expect(tm_engine_create(root_z.ptr, &engine_ptr) == 0);
    defer tm_engine_destroy(engine_ptr);

    const teammux_dir = try std.fmt.allocPrint(alloc, "{s}/.teammux", .{root});
    defer alloc.free(teammux_dir);
    std.fs.makeDirAbsolute(teammux_dir) catch {};
    const cfg_path = try std.fmt.allocPrint(alloc, "{s}/config.toml", .{teammux_dir});
    defer alloc.free(cfg_path);
    {
        const cfg_file = try std.fs.createFileAbsolute(cfg_path, .{});
        try cfg_file.writeAll("[project]\nname = \"test\"\n");
        cfg_file.close();
    }

    try std.testing.expect(tm_session_start(engine_ptr) == 0);

    // Write a completion
    const summary_z = try alloc.dupeZ(u8, "task done");
    defer alloc.free(summary_z);
    try std.testing.expect(tm_worker_complete(engine_ptr, 1, summary_z.ptr, null) == 0);

    // Verify it's there
    {
        var count: u32 = 0;
        const entries = tm_history_load(engine_ptr, &count);
        defer tm_history_free(entries, count);
        try std.testing.expect(count == 1);
    }

    // Clear
    try std.testing.expect(tm_history_clear(engine_ptr) == 0);

    // Verify empty
    {
        var count: u32 = 0;
        const entries = tm_history_load(engine_ptr, &count);
        defer tm_history_free(entries, count);
        try std.testing.expect(count == 0);
        try std.testing.expect(entries == null);
    }
}

// ─── Role hot-reload C API tests ─────────────────────────

test "tm_role_watch null engine returns TM_ERR_UNKNOWN" {
    try std.testing.expect(tm_role_watch(null, 0, null, null, null) == 99);
}

test "tm_role_unwatch null engine returns TM_ERR_UNKNOWN" {
    try std.testing.expect(tm_role_unwatch(null, 0) == 99);
}

test "tm_role_watch null callback returns TM_ERR_ROLE" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);

    const role_z = try std.testing.allocator.dupeZ(u8, "test-role");
    defer std.testing.allocator.free(role_z);
    // null callback → TM_ERR_ROLE (13)
    try std.testing.expect(tm_role_watch(engine_ptr, 1, role_z.ptr, null, null) == 13);
}

test "tm_role_watch null role_id returns TM_ERR_ROLE" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);

    const noop_cb = &struct {
        fn cb(_: u32, _: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) void {}
    }.cb;
    // null role_id → TM_ERR_ROLE (13)
    try std.testing.expect(tm_role_watch(engine_ptr, 1, null, noop_cb, null) == 13);
}

test "tm_role_watch invalid worker_id returns TM_ERR_INVALID_WORKER" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);

    const noop_cb = &struct {
        fn cb(_: u32, _: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) void {}
    }.cb;
    const role_z = try std.testing.allocator.dupeZ(u8, "test-role");
    defer std.testing.allocator.free(role_z);
    // worker 999 not in roster → TM_ERR_INVALID_WORKER (12)
    try std.testing.expect(tm_role_watch(engine_ptr, 999, role_z.ptr, noop_cb, null) == 12);
}

test "tm_role_unwatch idempotent on missing worker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const root_z = try std.testing.allocator.dupeZ(u8, root);
    defer std.testing.allocator.free(root_z);
    var engine_ptr: ?*Engine = null;
    _ = tm_engine_create(root_z.ptr, &engine_ptr);
    defer tm_engine_destroy(engine_ptr);

    // unwatch on nonexistent watcher → TM_OK (idempotent)
    try std.testing.expect(tm_role_unwatch(engine_ptr, 999) == 0);
}

// ─── Coordinator C API tests ─────────────────────────────

test "tm_dispatch_task null engine returns TM_ERR_UNKNOWN" {
    try std.testing.expect(tm_dispatch_task(null, 0, null) == 99);
}

test "tm_dispatch_response null engine returns TM_ERR_UNKNOWN" {
    try std.testing.expect(tm_dispatch_response(null, 0, null) == 99);
}

test "tm_dispatch_history null engine returns null with count 0" {
    var count: u32 = 42;
    try std.testing.expect(tm_dispatch_history(null, &count) == null);
    try std.testing.expect(count == 0);
}

test "tm_dispatch_history_free handles null" {
    tm_dispatch_history_free(null, 0);
}

test "command routing wrapper routes /teammux-assign to coordinator" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const e = try Engine.create(alloc, root);
    defer e.destroy();

    const log_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{root});
    defer alloc.free(log_dir);
    e.message_bus = try bus.MessageBus.init(alloc, log_dir, "wraptest", root);

    // Add a worker to the roster
    try e.roster.workers.put(5, try coordinator_mod.makeTestWorker(alloc, 5));

    const args_json = "{\"target_worker_id\": 5, \"instruction\": \"refactor auth\"}";
    const args_z = try alloc.dupeZ(u8, args_json);
    defer alloc.free(args_z);
    const cmd_z = try alloc.dupeZ(u8, "/teammux-assign");
    defer alloc.free(cmd_z);

    commandRoutingCallback(cmd_z.ptr, args_z.ptr, e);

    const history = e.coordinator.getHistory();
    try std.testing.expect(history.len == 1);
    try std.testing.expectEqualStrings("refactor auth", history[0].instruction);
    try std.testing.expect(history[0].target_worker_id == 5);
}

test "command routing wrapper forwards unknown commands to Swift callback" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const e = try Engine.create(alloc, root);
    defer e.destroy();

    const State = struct {
        var forwarded: bool = false;
        var forwarded_cmd: [64]u8 = undefined;
        var forwarded_len: usize = 0;
    };
    State.forwarded = false;
    State.forwarded_len = 0;

    const swift_callback = struct {
        fn cb(cmd: ?[*:0]const u8, _: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) void {
            if (cmd) |c| {
                const slice = std.mem.span(c);
                State.forwarded = true;
                @memcpy(State.forwarded_cmd[0..slice.len], slice);
                State.forwarded_len = slice.len;
            }
        }
    }.cb;

    e.cmd_cb = swift_callback;
    e.cmd_cb_userdata = null;

    const cmd_z = try alloc.dupeZ(u8, "/teammux-status");
    defer alloc.free(cmd_z);
    const args_z = try alloc.dupeZ(u8, "{}");
    defer alloc.free(args_z);

    commandRoutingCallback(cmd_z.ptr, args_z.ptr, e);

    try std.testing.expect(State.forwarded);
    try std.testing.expectEqualStrings("/teammux-status", State.forwarded_cmd[0..State.forwarded_len]);
}

// ─── Peer messaging tests ────────────────────────────────

test "/teammux-ask routes to Team Lead PTY (worker 0), not target" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const e = try Engine.create(alloc, root);
    defer e.destroy();

    const log_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{root});
    defer alloc.free(log_dir);
    e.message_bus = try bus.MessageBus.init(alloc, log_dir, "asktest1", root);

    // Add workers: sender (2) and target (5)
    try e.roster.workers.put(2, try coordinator_mod.makeTestWorker(alloc, 2));
    try e.roster.workers.put(5, try coordinator_mod.makeTestWorker(alloc, 5));

    const BusState = struct {
        var called: bool = false;
        var to_id: u32 = 99;
        var from_id: u32 = 99;
        var msg_type: c_int = -1;
        var payload_buf: [512]u8 = undefined;
        var payload_len: usize = 0;
    };
    BusState.called = false;
    BusState.to_id = 99;
    BusState.from_id = 99;
    BusState.msg_type = -1;
    BusState.payload_len = 0;

    const cb = struct {
        fn f(msg: ?*const bus.CMessage, _: ?*anyopaque) callconv(.c) c_int {
            if (msg) |m| {
                BusState.called = true;
                BusState.to_id = m.to;
                BusState.from_id = m.from;
                BusState.msg_type = m.msg_type;
                if (m.payload) |p| {
                    const slice = std.mem.span(p);
                    const len = @min(slice.len, BusState.payload_buf.len);
                    @memcpy(BusState.payload_buf[0..len], slice[0..len]);
                    BusState.payload_len = len;
                }
            }
            return 0;
        }
    }.f;

    e.message_bus.?.subscribe(cb, null);

    const args_json = "{\"worker_id\": 2, \"target_worker_id\": 5, \"message\": \"how should I handle auth?\"}";
    const args_z = try alloc.dupeZ(u8, args_json);
    defer alloc.free(args_z);
    const cmd_z = try alloc.dupeZ(u8, "/teammux-ask");
    defer alloc.free(cmd_z);

    commandRoutingCallback(cmd_z.ptr, args_z.ptr, e);

    try std.testing.expect(BusState.called);
    try std.testing.expect(BusState.to_id == 0); // Team Lead
    try std.testing.expect(BusState.from_id == 2); // sender
    try std.testing.expect(BusState.msg_type == @intFromEnum(bus.MessageType.peer_question));
    // Verify payload contains the message text
    try std.testing.expect(std.mem.indexOf(u8, BusState.payload_buf[0..BusState.payload_len], "how should I handle auth?") != null);
}

test "/teammux-delegate routes directly to target worker PTY" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const e = try Engine.create(alloc, root);
    defer e.destroy();

    const log_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{root});
    defer alloc.free(log_dir);
    e.message_bus = try bus.MessageBus.init(alloc, log_dir, "deltest1", root);

    // Add workers: sender (3) and target (7)
    try e.roster.workers.put(3, try coordinator_mod.makeTestWorker(alloc, 3));
    try e.roster.workers.put(7, try coordinator_mod.makeTestWorker(alloc, 7));

    const BusState = struct {
        var called: bool = false;
        var to_id: u32 = 99;
        var from_id: u32 = 99;
        var msg_type: c_int = -1;
        var payload_buf: [512]u8 = undefined;
        var payload_len: usize = 0;
    };
    BusState.called = false;
    BusState.to_id = 99;
    BusState.from_id = 99;
    BusState.msg_type = -1;
    BusState.payload_len = 0;

    const cb = struct {
        fn f(msg: ?*const bus.CMessage, _: ?*anyopaque) callconv(.c) c_int {
            if (msg) |m| {
                BusState.called = true;
                BusState.to_id = m.to;
                BusState.from_id = m.from;
                BusState.msg_type = m.msg_type;
                if (m.payload) |p| {
                    const slice = std.mem.span(p);
                    const len = @min(slice.len, BusState.payload_buf.len);
                    @memcpy(BusState.payload_buf[0..len], slice[0..len]);
                    BusState.payload_len = len;
                }
            }
            return 0;
        }
    }.f;

    e.message_bus.?.subscribe(cb, null);

    const args_json = "{\"worker_id\": 3, \"target_worker_id\": 7, \"task\": \"write unit tests for auth\"}";
    const args_z = try alloc.dupeZ(u8, args_json);
    defer alloc.free(args_z);
    const cmd_z = try alloc.dupeZ(u8, "/teammux-delegate");
    defer alloc.free(cmd_z);

    commandRoutingCallback(cmd_z.ptr, args_z.ptr, e);

    try std.testing.expect(BusState.called);
    try std.testing.expect(BusState.to_id == 7); // target worker directly
    try std.testing.expect(BusState.from_id == 3); // sender
    try std.testing.expect(BusState.msg_type == @intFromEnum(bus.MessageType.delegation));
    // Verify payload contains the task text
    try std.testing.expect(std.mem.indexOf(u8, BusState.payload_buf[0..BusState.payload_len], "write unit tests for auth") != null);
}

test "/teammux-ask invalid target_worker_id does not send" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const e = try Engine.create(alloc, root);
    defer e.destroy();

    const log_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{root});
    defer alloc.free(log_dir);
    e.message_bus = try bus.MessageBus.init(alloc, log_dir, "askbad1", root);

    // Only add sender (2), target (99) does NOT exist
    try e.roster.workers.put(2, try coordinator_mod.makeTestWorker(alloc, 2));

    const BusState = struct {
        var called: bool = false;
    };
    BusState.called = false;

    const cb = struct {
        fn f(_: ?*const bus.CMessage, _: ?*anyopaque) callconv(.c) c_int {
            BusState.called = true;
            return 0;
        }
    }.f;

    e.message_bus.?.subscribe(cb, null);

    const args_json = "{\"worker_id\": 2, \"target_worker_id\": 99, \"message\": \"hello\"}";
    const args_z = try alloc.dupeZ(u8, args_json);
    defer alloc.free(args_z);
    const cmd_z = try alloc.dupeZ(u8, "/teammux-ask");
    defer alloc.free(cmd_z);

    commandRoutingCallback(cmd_z.ptr, args_z.ptr, e);

    // Bus should NOT have been called — target not in roster
    try std.testing.expect(!BusState.called);
}

test "/teammux-ask self-targeting does not send" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const e = try Engine.create(alloc, root);
    defer e.destroy();

    const log_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{root});
    defer alloc.free(log_dir);
    e.message_bus = try bus.MessageBus.init(alloc, log_dir, "selfask", root);

    try e.roster.workers.put(2, try coordinator_mod.makeTestWorker(alloc, 2));

    const BusState = struct {
        var called: bool = false;
    };
    BusState.called = false;

    const cb = struct {
        fn f(_: ?*const bus.CMessage, _: ?*anyopaque) callconv(.c) c_int {
            BusState.called = true;
            return 0;
        }
    }.f;

    e.message_bus.?.subscribe(cb, null);

    // from_id == target_id == 2
    const args_json = "{\"worker_id\": 2, \"target_worker_id\": 2, \"message\": \"talking to myself\"}";
    const args_z = try alloc.dupeZ(u8, args_json);
    defer alloc.free(args_z);
    const cmd_z = try alloc.dupeZ(u8, "/teammux-ask");
    defer alloc.free(cmd_z);

    commandRoutingCallback(cmd_z.ptr, args_z.ptr, e);

    try std.testing.expect(!BusState.called);
}

test "/teammux-ask null args does not crash" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const e = try Engine.create(alloc, root);
    defer e.destroy();

    const cmd_z = try alloc.dupeZ(u8, "/teammux-ask");
    defer alloc.free(cmd_z);

    // Pass null args — should log warning and return, not crash
    commandRoutingCallback(cmd_z.ptr, null, e);
}

test "/teammux-delegate invalid target_worker_id does not send" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const e = try Engine.create(alloc, root);
    defer e.destroy();

    const log_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{root});
    defer alloc.free(log_dir);
    e.message_bus = try bus.MessageBus.init(alloc, log_dir, "delbad1", root);

    try e.roster.workers.put(3, try coordinator_mod.makeTestWorker(alloc, 3));

    const BusState = struct {
        var called: bool = false;
    };
    BusState.called = false;

    const cb = struct {
        fn f(_: ?*const bus.CMessage, _: ?*anyopaque) callconv(.c) c_int {
            BusState.called = true;
            return 0;
        }
    }.f;

    e.message_bus.?.subscribe(cb, null);

    const args_json = "{\"worker_id\": 3, \"target_worker_id\": 99, \"task\": \"missing worker\"}";
    const args_z = try alloc.dupeZ(u8, args_json);
    defer alloc.free(args_z);
    const cmd_z = try alloc.dupeZ(u8, "/teammux-delegate");
    defer alloc.free(cmd_z);

    commandRoutingCallback(cmd_z.ptr, args_z.ptr, e);

    try std.testing.expect(!BusState.called);
}

test "/teammux-delegate self-targeting does not send" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const e = try Engine.create(alloc, root);
    defer e.destroy();

    const log_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{root});
    defer alloc.free(log_dir);
    e.message_bus = try bus.MessageBus.init(alloc, log_dir, "delself", root);

    try e.roster.workers.put(3, try coordinator_mod.makeTestWorker(alloc, 3));

    const BusState = struct {
        var called: bool = false;
    };
    BusState.called = false;

    const cb = struct {
        fn f(_: ?*const bus.CMessage, _: ?*anyopaque) callconv(.c) c_int {
            BusState.called = true;
            return 0;
        }
    }.f;

    e.message_bus.?.subscribe(cb, null);

    const args_json = "{\"worker_id\": 3, \"target_worker_id\": 3, \"task\": \"self delegate\"}";
    const args_z = try alloc.dupeZ(u8, args_json);
    defer alloc.free(args_z);
    const cmd_z = try alloc.dupeZ(u8, "/teammux-delegate");
    defer alloc.free(cmd_z);

    commandRoutingCallback(cmd_z.ptr, args_z.ptr, e);

    try std.testing.expect(!BusState.called);
}

test "/teammux-delegate null args does not crash" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const e = try Engine.create(alloc, root);
    defer e.destroy();

    const cmd_z = try alloc.dupeZ(u8, "/teammux-delegate");
    defer alloc.free(cmd_z);

    commandRoutingCallback(cmd_z.ptr, null, e);
}

test "tm_peer_question and tm_peer_delegate C API return correct codes" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const e = try Engine.create(alloc, root);
    defer e.destroy();

    const log_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{root});
    defer alloc.free(log_dir);
    e.message_bus = try bus.MessageBus.init(alloc, log_dir, "capitest", root);

    try e.roster.workers.put(2, try coordinator_mod.makeTestWorker(alloc, 2));
    try e.roster.workers.put(5, try coordinator_mod.makeTestWorker(alloc, 5));

    // Null engine
    try std.testing.expect(tm_peer_question(null, 2, 5, "hello") == 99);
    try std.testing.expect(tm_peer_delegate(null, 2, 5, "task") == 99);

    // Null message/task
    try std.testing.expect(tm_peer_question(e, 2, 5, null) == 99);
    try std.testing.expect(tm_peer_delegate(e, 2, 5, null) == 99);

    // Team Lead (from_id == 0) rejected
    try std.testing.expect(tm_peer_question(e, 0, 5, "nope") == 12); // TM_ERR_INVALID_WORKER
    try std.testing.expect(tm_peer_delegate(e, 0, 5, "nope") == 12);

    // Self-targeting
    try std.testing.expect(tm_peer_question(e, 2, 2, "self") == 12); // TM_ERR_INVALID_WORKER
    try std.testing.expect(tm_peer_delegate(e, 2, 2, "self") == 12);

    // Sender not in roster
    try std.testing.expect(tm_peer_question(e, 88, 5, "ghost") == 12);
    try std.testing.expect(tm_peer_delegate(e, 88, 5, "ghost") == 12);

    // Target not in roster
    try std.testing.expect(tm_peer_question(e, 2, 99, "missing") == 12);
    try std.testing.expect(tm_peer_delegate(e, 2, 99, "missing") == 12);

    // Valid calls — should succeed
    const msg_z = try alloc.dupeZ(u8, "how do I handle auth?");
    defer alloc.free(msg_z);
    try std.testing.expect(tm_peer_question(e, 2, 5, msg_z.ptr) == 0); // TM_OK

    const task_z = try alloc.dupeZ(u8, "write auth tests");
    defer alloc.free(task_z);
    try std.testing.expect(tm_peer_delegate(e, 2, 5, task_z.ptr) == 0); // TM_OK
}

test "/teammux-ask from_id not in roster does not send" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const e = try Engine.create(alloc, root);
    defer e.destroy();

    const log_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{root});
    defer alloc.free(log_dir);
    e.message_bus = try bus.MessageBus.init(alloc, log_dir, "askfrom", root);

    // Only target (5) in roster — sender (88) is NOT
    try e.roster.workers.put(5, try coordinator_mod.makeTestWorker(alloc, 5));

    const BusState = struct {
        var called: bool = false;
    };
    BusState.called = false;

    const cb = struct {
        fn f(_: ?*const bus.CMessage, _: ?*anyopaque) callconv(.c) c_int {
            BusState.called = true;
            return 0;
        }
    }.f;

    e.message_bus.?.subscribe(cb, null);

    const args_json = "{\"worker_id\": 88, \"target_worker_id\": 5, \"message\": \"ghost sender\"}";
    const args_z = try alloc.dupeZ(u8, args_json);
    defer alloc.free(args_z);
    const cmd_z = try alloc.dupeZ(u8, "/teammux-ask");
    defer alloc.free(cmd_z);

    commandRoutingCallback(cmd_z.ptr, args_z.ptr, e);

    try std.testing.expect(!BusState.called);
}

test "/teammux-ask from Team Lead (worker 0) rejected" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const e = try Engine.create(alloc, root);
    defer e.destroy();

    const log_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{root});
    defer alloc.free(log_dir);
    e.message_bus = try bus.MessageBus.init(alloc, log_dir, "asktl01", root);

    try e.roster.workers.put(5, try coordinator_mod.makeTestWorker(alloc, 5));

    const BusState = struct {
        var called: bool = false;
    };
    BusState.called = false;

    const cb = struct {
        fn f(_: ?*const bus.CMessage, _: ?*anyopaque) callconv(.c) c_int {
            BusState.called = true;
            return 0;
        }
    }.f;

    e.message_bus.?.subscribe(cb, null);

    // from_id == 0 (Team Lead) should be rejected
    const args_json = "{\"worker_id\": 0, \"target_worker_id\": 5, \"message\": \"Team Lead trying peer ask\"}";
    const args_z = try alloc.dupeZ(u8, args_json);
    defer alloc.free(args_z);
    const cmd_z = try alloc.dupeZ(u8, "/teammux-ask");
    defer alloc.free(cmd_z);

    commandRoutingCallback(cmd_z.ptr, args_z.ptr, e);

    try std.testing.expect(!BusState.called);
}

test "/teammux-ask bus send failure injects error to sender PTY" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const e = try Engine.create(alloc, root);
    defer e.destroy();

    const log_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{root});
    defer alloc.free(log_dir);
    e.message_bus = try bus.MessageBus.init(alloc, log_dir, "askfail", root);
    e.message_bus.?.retry_delays_ns = .{ 0, 0, 0 }; // no sleep in tests

    try e.roster.workers.put(2, try coordinator_mod.makeTestWorker(alloc, 2));
    try e.roster.workers.put(5, try coordinator_mod.makeTestWorker(alloc, 5));

    const BusState = struct {
        var call_count: u32 = 0;
        var error_to: u32 = 99;
        var error_msg_type: c_int = -1;
    };
    BusState.call_count = 0;
    BusState.error_to = 99;
    BusState.error_msg_type = -1;

    const cb = struct {
        fn f(msg: ?*const bus.CMessage, _: ?*anyopaque) callconv(.c) c_int {
            BusState.call_count += 1;
            if (msg) |m| {
                // First message is the peer_question — fail it
                if (m.msg_type == @intFromEnum(bus.MessageType.peer_question)) {
                    return 8; // TM_ERR_BUS — force failure
                }
                // Second message should be the error notification to sender
                if (m.msg_type == @intFromEnum(bus.MessageType.err)) {
                    BusState.error_to = m.to;
                    BusState.error_msg_type = m.msg_type;
                }
            }
            return 0;
        }
    }.f;

    e.message_bus.?.subscribe(cb, null);

    const args_json = "{\"worker_id\": 2, \"target_worker_id\": 5, \"message\": \"will fail\"}";
    const args_z = try alloc.dupeZ(u8, args_json);
    defer alloc.free(args_z);
    const cmd_z = try alloc.dupeZ(u8, "/teammux-ask");
    defer alloc.free(cmd_z);

    commandRoutingCallback(cmd_z.ptr, args_z.ptr, e);

    // Error notification should have been sent to the sender (worker 2)
    try std.testing.expect(BusState.error_to == 2);
    try std.testing.expect(BusState.error_msg_type == @intFromEnum(bus.MessageType.err));
}

// ─── JSON helper tests ───────────────────────────────────

test "extractJsonStringValue extracts quoted value" {
    const result = extractJsonStringValue("{\"instruction\": \"refactor auth\"}", "instruction");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("refactor auth", result.?);
}

test "extractJsonStringValue returns null for missing key" {
    try std.testing.expect(extractJsonStringValue("{\"foo\": \"bar\"}", "instruction") == null);
}

test "extractJsonStringValue handles escaped quotes" {
    const result = extractJsonStringValue("{\"msg\": \"use \\\"JWT\\\" tokens\"}", "msg");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("use \\\"JWT\\\" tokens", result.?);
}

test "extractJsonNumber extracts bare integer" {
    const result = extractJsonNumber("{\"target_worker_id\": 42}", "target_worker_id");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("42", result.?);
}

test "extractJsonNumber returns null for quoted value" {
    try std.testing.expect(extractJsonNumber("{\"id\": \"5\"}", "id") == null);
}

test "extractJsonNumber returns null for missing key" {
    try std.testing.expect(extractJsonNumber("{\"foo\": 1}", "id") == null);
}

test "extractJsonNumber handles no space after colon" {
    const result = extractJsonNumber("{\"id\":7}", "id");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("7", result.?);
}

// ─── Dispatch history round-trip test ────────────────────

test "tm_dispatch_history round-trip returns correct events" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const e = try Engine.create(alloc, root);
    defer e.destroy();

    const log_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{root});
    defer alloc.free(log_dir);
    e.message_bus = try bus.MessageBus.init(alloc, log_dir, "histtest", root);

    try e.roster.workers.put(3, try coordinator_mod.makeTestWorker(alloc, 3));

    try e.coordinator.dispatchTask(&e.roster, &(e.message_bus.?), 3, "round-trip test");

    var count: u32 = 0;
    const events = tm_dispatch_history(e, &count);
    try std.testing.expect(events != null);
    try std.testing.expect(count == 1);

    const event = events.?[0].?;
    try std.testing.expect(event.target_worker_id == 3);
    try std.testing.expectEqualStrings("round-trip test", std.mem.span(event.instruction.?));
    try std.testing.expect(event.delivered == true);
    try std.testing.expect(event.kind == 0); // task

    // Free must not crash — uses c_allocator which matches tm_dispatch_history
    tm_dispatch_history_free(events, count);
}

// ─── S12 integration tests ──────────────────────────────
// Cross-stream integration tests verifying that components from
// different v0.1.3 streams work correctly together through the C API.

test "S12 integration: tm_interceptor_install blocks git commit -a (S1 fix)" {
    // Verifies S1 (interceptor.zig commit -a fix) works through the
    // full C API path: tm_ownership_register → tm_interceptor_install →
    // generated wrapper script contains commit -a blocking logic.
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);

    // Set up git repo
    worktree.runGit(alloc, root, &.{ "init", "-b", "main" }) catch return;
    worktree.runGit(alloc, root, &.{ "config", "user.email", "test@test.com" }) catch return;
    worktree.runGit(alloc, root, &.{ "config", "user.name", "Test" }) catch return;
    const readme_path = try std.fmt.allocPrint(alloc, "{s}/README.md", .{root});
    defer alloc.free(readme_path);
    const readme = try std.fs.createFileAbsolute(readme_path, .{});
    try readme.writeAll("# Test");
    readme.close();
    worktree.runGit(alloc, root, &.{ "add", "." }) catch return;
    worktree.runGit(alloc, root, &.{ "commit", "-m", "initial" }) catch return;

    var engine_ptr: ?*Engine = null;
    try std.testing.expect(tm_engine_create(root_z.ptr, &engine_ptr) == 0);
    defer tm_engine_destroy(engine_ptr);

    // Spawn worker
    const binary_z = try alloc.dupeZ(u8, "/usr/bin/echo");
    defer alloc.free(binary_z);
    const name_z = try alloc.dupeZ(u8, "FrontendEngineer");
    defer alloc.free(name_z);
    const task_z = try alloc.dupeZ(u8, "build login form");
    defer alloc.free(task_z);

    const worker_id = tm_worker_spawn(engine_ptr, binary_z.ptr, 0, name_z.ptr, task_z.ptr);
    try std.testing.expect(worker_id != 0xFFFFFFFF);

    // Register deny patterns (worker cannot write to backend)
    const deny_z = try alloc.dupeZ(u8, "src/backend/**");
    defer alloc.free(deny_z);
    try std.testing.expect(tm_ownership_register(engine_ptr, worker_id, deny_z.ptr, false) == 0);
    const write_z = try alloc.dupeZ(u8, "src/frontend/**");
    defer alloc.free(write_z);
    try std.testing.expect(tm_ownership_register(engine_ptr, worker_id, write_z.ptr, true) == 0);

    // Install interceptor via C API
    try std.testing.expect(tm_interceptor_install(engine_ptr, worker_id) == 0);

    // Read generated wrapper script
    const e = engine_ptr.?;
    const w = e.roster.getWorker(worker_id).?;
    const wrapper_path = try std.fmt.allocPrint(alloc, "{s}/.git-wrapper/git", .{w.worktree_path});
    defer alloc.free(wrapper_path);
    const file = try std.fs.openFileAbsolute(wrapper_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(alloc, 64 * 1024);
    defer alloc.free(content);

    // S1 fix: commit -a interception must be present
    try std.testing.expect(std.mem.indexOf(u8, content, "\"$subcmd\" == \"commit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "-a|--all|-a*)") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "Cannot use 'git commit -a'") != null);
    // Deny patterns embedded
    try std.testing.expect(std.mem.indexOf(u8, content, "src/backend/**") != null);
    // Write scope in error message
    try std.testing.expect(std.mem.indexOf(u8, content, "src/frontend/**") != null);
    // git add bulk blocking also present
    try std.testing.expect(std.mem.indexOf(u8, content, "Cannot stage all files") != null);
}

test "S12 integration: tm_dispatch_task routes through bus to subscriber (S5 path)" {
    // Verifies the full dispatch path: tm_dispatch_task C API export →
    // coordinator.dispatchTask → message bus → subscriber callback.
    // This is the S5 (coordinator engine) path through the C API boundary.
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const e = try Engine.create(alloc, root);
    defer e.destroy();

    // Set up message bus
    const log_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{root});
    defer alloc.free(log_dir);
    e.message_bus = try bus.MessageBus.init(alloc, log_dir, "s12disp", root);

    // Subscribe to bus — verify dispatch message is received
    const State = struct {
        var received: bool = false;
        var received_to: u32 = 0;
        var received_type: c_int = -1;
    };
    State.received = false;
    State.received_to = 0;
    State.received_type = -1;

    const callback = struct {
        fn cb(msg: ?*const bus.CMessage, _: ?*anyopaque) callconv(.c) c_int {
            if (msg) |m| {
                State.received = true;
                State.received_to = m.to;
                State.received_type = m.msg_type;
            }
            return 0;
        }
    }.cb;
    e.message_bus.?.subscribe(callback, null);

    // Add worker to roster
    try e.roster.workers.put(7, try coordinator_mod.makeTestWorker(alloc, 7));

    // Dispatch via C API (same path Swift's EngineClient.dispatchTask calls)
    const instruction_z = try alloc.dupeZ(u8, "refactor the auth module");
    defer alloc.free(instruction_z);
    try std.testing.expect(tm_dispatch_task(e, 7, instruction_z.ptr) == 0);

    // Bus subscriber received the dispatch message
    try std.testing.expect(State.received);
    try std.testing.expect(State.received_to == 7);
    try std.testing.expect(State.received_type == @intFromEnum(bus.MessageType.dispatch));

    // Coordinator history recorded
    const history = e.coordinator.getHistory();
    try std.testing.expect(history.len == 1);
    try std.testing.expectEqualStrings("refactor the auth module", history[0].instruction);
    try std.testing.expect(history[0].target_worker_id == 7);
    try std.testing.expect(history[0].delivered == true);
    try std.testing.expect(history[0].kind == .task);

    // Invalid worker returns TM_ERR_INVALID_WORKER
    try std.testing.expect(tm_dispatch_task(e, 999, instruction_z.ptr) == 12);
}

// ─── T7 tests: PR workflow ────────────────────────────────

test "tm_pr_create null engine returns null" {
    try std.testing.expect(tm_pr_create(null, 0, null, null, null) == null);
}

test "tm_github_create_pr null engine returns null" {
    try std.testing.expect(tm_github_create_pr(null, 0, null, null) == null);
}

test "command routing wrapper routes /teammux-pr-ready" {
    const e = Engine.create(std.testing.allocator, "/tmp") catch return;
    defer e.destroy();

    // Start session to initialize bus
    e.sessionStart() catch {};

    const PrState = struct {
        var command_forwarded: bool = false;
    };
    PrState.command_forwarded = false;

    const swift_cb = struct {
        fn cb(_: ?[*:0]const u8, _: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) void {
            PrState.command_forwarded = true;
        }
    }.cb;
    e.cmd_cb = swift_cb;

    // /teammux-pr-ready should be handled internally, NOT forwarded to Swift
    const cmd_z = std.testing.allocator.dupeZ(u8, "/teammux-pr-ready") catch return;
    defer std.testing.allocator.free(cmd_z);
    const args_z = std.testing.allocator.dupeZ(u8, "{\"worker_id\": 1, \"title\": \"test PR\", \"summary\": \"summary\"}") catch return;
    defer std.testing.allocator.free(args_z);

    commandRoutingCallback(cmd_z.ptr, args_z.ptr, e);

    // Should NOT have been forwarded to Swift callback
    try std.testing.expect(!PrState.command_forwarded);
}

test "command routing wrapper still forwards unknown commands" {
    const e = Engine.create(std.testing.allocator, "/tmp") catch return;
    defer e.destroy();

    const FwdState = struct {
        var forwarded: bool = false;
    };
    FwdState.forwarded = false;

    const swift_cb = struct {
        fn cb(_: ?[*:0]const u8, _: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) void {
            FwdState.forwarded = true;
        }
    }.cb;
    e.cmd_cb = swift_cb;

    const cmd_z = std.testing.allocator.dupeZ(u8, "/teammux-unknown") catch return;
    defer std.testing.allocator.free(cmd_z);
    const args_z = std.testing.allocator.dupeZ(u8, "{}") catch return;
    defer std.testing.allocator.free(args_z);

    commandRoutingCallback(cmd_z.ptr, args_z.ptr, e);
    try std.testing.expect(FwdState.forwarded);
}

test "routePrReady sends TM_MSG_PR_READY to bus" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(project_root);

    // Init git repo for bus git_commit
    worktree.runGit(alloc, project_root, &.{ "init", "-b", "main" }) catch {};
    worktree.runGit(alloc, project_root, &.{ "config", "user.email", "t@t.com" }) catch {};
    worktree.runGit(alloc, project_root, &.{ "config", "user.name", "T" }) catch {};
    const readme = try std.fmt.allocPrint(alloc, "{s}/README.md", .{project_root});
    defer alloc.free(readme);
    {
        const f = try std.fs.createFileAbsolute(readme, .{});
        try f.writeAll("#");
        f.close();
    }
    worktree.runGit(alloc, project_root, &.{ "add", "." }) catch {};
    worktree.runGit(alloc, project_root, &.{ "commit", "-m", "init" }) catch {};

    const e = Engine.create(alloc, project_root) catch return;
    defer e.destroy();
    e.sessionStart() catch return;

    const State = struct {
        var received: bool = false;
        var msg_type: c_int = -1;
        var payload_buf: [512]u8 = undefined;
        var payload_len: usize = 0;
    };
    State.received = false;
    State.msg_type = -1;
    State.payload_len = 0;

    const cb = struct {
        fn f(msg: ?*const bus.CMessage, _: ?*anyopaque) callconv(.c) c_int {
            if (msg) |m| {
                State.received = true;
                State.msg_type = m.msg_type;
                if (m.payload) |p| {
                    const s = std.mem.span(p);
                    const len = @min(s.len, State.payload_buf.len);
                    @memcpy(State.payload_buf[0..len], s[0..len]);
                    State.payload_len = len;
                }
            }
            return 0;
        }
    }.f;

    if (e.message_bus) |*b| b.subscribe(cb, null);

    routePrReady(e, 2, "https://github.com/o/r/pull/1", "teammux/2-implement-auth", "Add auth");

    try std.testing.expect(State.received);
    try std.testing.expect(State.msg_type == @intFromEnum(bus.MessageType.pr_ready));
    const payload_slice = State.payload_buf[0..State.payload_len];
    try std.testing.expect(std.mem.indexOf(u8, payload_slice, "\"worker_id\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload_slice, "https://github.com/o/r/pull/1") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload_slice, "teammux/2-implement-auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload_slice, "Add auth") != null);
}

test "routePrError sends TM_MSG_ERROR to bus" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(project_root);

    worktree.runGit(alloc, project_root, &.{ "init", "-b", "main" }) catch {};
    worktree.runGit(alloc, project_root, &.{ "config", "user.email", "t@t.com" }) catch {};
    worktree.runGit(alloc, project_root, &.{ "config", "user.name", "T" }) catch {};
    const readme = try std.fmt.allocPrint(alloc, "{s}/README.md", .{project_root});
    defer alloc.free(readme);
    {
        const f = try std.fs.createFileAbsolute(readme, .{});
        try f.writeAll("#");
        f.close();
    }
    worktree.runGit(alloc, project_root, &.{ "add", "." }) catch {};
    worktree.runGit(alloc, project_root, &.{ "commit", "-m", "init" }) catch {};

    const e = Engine.create(alloc, project_root) catch return;
    defer e.destroy();
    e.sessionStart() catch return;

    const ErrState = struct {
        var received: bool = false;
        var msg_type: c_int = -1;
    };
    ErrState.received = false;
    ErrState.msg_type = -1;

    const cb = struct {
        fn f(msg: ?*const bus.CMessage, _: ?*anyopaque) callconv(.c) c_int {
            if (msg) |m| {
                ErrState.received = true;
                ErrState.msg_type = m.msg_type;
            }
            return 0;
        }
    }.f;

    if (e.message_bus) |*b| b.subscribe(cb, null);

    routePrError(e, 3, "gh pr create failed");

    try std.testing.expect(ErrState.received);
    try std.testing.expect(ErrState.msg_type == @intFromEnum(bus.MessageType.err));
}

test "/teammux-pr-ready with null args does not crash" {
    const e = Engine.create(std.testing.allocator, "/tmp") catch return;
    defer e.destroy();

    const cmd_z = std.testing.allocator.dupeZ(u8, "/teammux-pr-ready") catch return;
    defer std.testing.allocator.free(cmd_z);

    // Null args — should return cleanly without crashing
    commandRoutingCallback(cmd_z.ptr, null, e);
}

test "/teammux-pr-ready missing worker_id does not crash" {
    const e = Engine.create(std.testing.allocator, "/tmp") catch return;
    defer e.destroy();

    const cmd_z = std.testing.allocator.dupeZ(u8, "/teammux-pr-ready") catch return;
    defer std.testing.allocator.free(cmd_z);
    const args_z = std.testing.allocator.dupeZ(u8, "{\"title\": \"test\"}") catch return;
    defer std.testing.allocator.free(args_z);

    commandRoutingCallback(cmd_z.ptr, args_z.ptr, e);
}

test "/teammux-pr-ready non-numeric worker_id does not crash" {
    const e = Engine.create(std.testing.allocator, "/tmp") catch return;
    defer e.destroy();

    const cmd_z = std.testing.allocator.dupeZ(u8, "/teammux-pr-ready") catch return;
    defer std.testing.allocator.free(cmd_z);
    const args_z = std.testing.allocator.dupeZ(u8, "{\"worker_id\": \"abc\", \"title\": \"test\"}") catch return;
    defer std.testing.allocator.free(args_z);

    commandRoutingCallback(cmd_z.ptr, args_z.ptr, e);
}

test "/teammux-pr-ready missing title does not crash" {
    const e = Engine.create(std.testing.allocator, "/tmp") catch return;
    defer e.destroy();

    const cmd_z = std.testing.allocator.dupeZ(u8, "/teammux-pr-ready") catch return;
    defer std.testing.allocator.free(cmd_z);
    const args_z = std.testing.allocator.dupeZ(u8, "{\"worker_id\": 1}") catch return;
    defer std.testing.allocator.free(args_z);

    commandRoutingCallback(cmd_z.ptr, args_z.ptr, e);
}

test { _ = config; _ = worktree; _ = pty_mod; _ = bus; _ = github; _ = commands; _ = merge; _ = ownership; _ = interceptor; _ = hotreload; _ = coordinator_mod; }
