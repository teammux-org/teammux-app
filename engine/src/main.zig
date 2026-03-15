const std = @import("std");

// Module imports
pub const config = @import("config.zig");
pub const worktree = @import("worktree.zig");
pub const pty_mod = @import("pty.zig");
pub const bus = @import("bus.zig");
pub const github = @import("github.zig");
pub const commands = @import("commands.zig");

// ─────────────────────────────────────────────────────────
// Engine struct — central state, owns all module instances
// ─────────────────────────────────────────────────────────

pub const Engine = struct {
    allocator: std.mem.Allocator,
    project_root: []const u8,
    cfg: ?config.Config,
    config_watcher: ?config.ConfigWatcher,
    roster: worktree.Roster,
    message_bus: ?bus.MessageBus,
    github_client: github.GitHubClient,
    commands_watcher: ?commands.CommandWatcher,
    session_id: [8]u8,
    last_error: ?[]const u8,
    last_error_cstr: ?[*:0]u8,
    last_config_get_cstr: ?[*:0]u8,
    next_sub_id: u32,
    roster_callback: ?*const fn (?*const CRoster, ?*anyopaque) callconv(.c) void,
    roster_userdata: ?*anyopaque,
    config_cb: ?*const fn (?*anyopaque) callconv(.c) void,
    config_cb_userdata: ?*anyopaque,
    msg_cb: ?*const fn (?*const bus.CMessage, ?*anyopaque) callconv(.c) void,
    msg_cb_userdata: ?*anyopaque,

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
            .message_bus = null,
            .github_client = github.GitHubClient.init(allocator, null),
            .commands_watcher = null,
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
        };
        return engine;
    }

    pub fn destroy(self: *Engine) void {
        if (self.commands_watcher) |*w| w.deinit();
        if (self.config_watcher) |*w| w.deinit();
        if (self.message_bus) |*b| b.deinit();
        self.github_client.deinit();
        self.roster.deinit();
        if (self.cfg) |*c| c.deinit(self.allocator);
        if (self.last_error) |e| self.allocator.free(e);
        if (self.last_error_cstr) |c| self.allocator.free(std.mem.span(c));
        if (self.last_config_get_cstr) |c| self.allocator.free(std.mem.span(c));
        self.allocator.free(self.project_root);
        self.allocator.destroy(self);
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
    }

    pub fn sessionStop(self: *Engine) void {
        if (self.commands_watcher) |*w| w.stop();
        if (self.config_watcher) |*w| w.stop();
        self.github_client.stopWebhooks();
    }

    fn setError(self: *Engine, msg: []const u8) !void {
        if (self.last_error) |old| self.allocator.free(old);
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

// Comptime ABI safety: verify extern struct sizes match expected C layout.
// If a field is added/removed in teammux.h without updating Zig, this fails at build time.
comptime {
    // CWorkerInfo: u32(4) + pad(4) + 5 ptrs(40) + 2 c_int(8) + 2 ptrs(16) + u64(8) = 80... actual 72
    if (@sizeOf(CWorkerInfo) != 72) @compileError("CWorkerInfo size mismatch with tm_worker_info_t");
    // CMessage (bus.zig): u32 + u32 + c_int + ptr + u64 + u64 + ptr = 48 bytes on arm64
    if (@sizeOf(bus.CMessage) != 48) @compileError("CMessage size mismatch with tm_message_t");
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
    const id = e.roster.spawn(e.project_root, std.mem.span(agent_binary orelse return 0xFFFFFFFF), @enumFromInt(agent_type), std.mem.span(worker_name orelse return 0xFFFFFFFF), std.mem.span(task_description orelse return 0xFFFFFFFF)) catch |err| {
        e.setError(switch (err) { error.GitFailed => "git worktree add failed", else => "worker spawn failed" }) catch {};
        return 0xFFFFFFFF;
    };
    return id;
}
export fn tm_worker_dismiss(engine: ?*Engine, worker_id: u32) c_int {
    const e = engine orelse return 99;
    e.roster.dismiss(e.project_root, worker_id) catch { e.setError("worker dismiss failed") catch {}; return 5; };
    return 0;
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
    b.send(target_worker_id, 0, @enumFromInt(msg_type), std.mem.span(payload orelse return 8)) catch { e.setError("message send failed") catch {}; return 8; };
    return 0;
}
export fn tm_message_broadcast(engine: ?*Engine, msg_type: c_int, payload: ?[*:0]const u8) c_int {
    const e = engine orelse return 99;
    var b = &(e.message_bus orelse return 8);
    b.broadcast(0, @enumFromInt(msg_type), std.mem.span(payload orelse return 8), &e.roster) catch { e.setError("message broadcast failed") catch {}; return 8; };
    return 0;
}
export fn tm_message_subscribe(engine: ?*Engine, callback: ?*const fn (?*const bus.CMessage, ?*anyopaque) callconv(.c) void, userdata: ?*anyopaque) u32 {
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
    const pr = e.github_client.createPr(alloc, w.branch_name, std.mem.span(title orelse return null), std.mem.span(body orelse return null)) catch {
        e.setError("PR creation failed: gh CLI error") catch {};
        return null;
    };
    const c_pr = alloc.create(CPr) catch return null;
    const url_z = alloc.dupeZ(u8, pr.url) catch { alloc.destroy(c_pr); return null; };
    const title_z = alloc.dupeZ(u8, pr.title) catch { alloc.free(url_z); alloc.destroy(c_pr); return null; };
    const diff_z = alloc.dupeZ(u8, pr.diff_url) catch { alloc.free(title_z); alloc.free(url_z); alloc.destroy(c_pr); return null; };
    c_pr.* = .{ .pr_number = pr.pr_number, .pr_url = url_z.ptr, .title = title_z.ptr, .state = 0, .diff_url = diff_z.ptr, .worker_id = worker_id };
    alloc.free(pr.url); alloc.free(pr.title); alloc.free(pr.state); alloc.free(pr.diff_url);
    return c_pr;
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

export fn tm_commands_watch(engine: ?*Engine, callback: ?*const fn (?[*:0]const u8, ?[*:0]const u8, ?*anyopaque) callconv(.c) void, userdata: ?*anyopaque) u32 {
    const e = engine orelse return 0;
    if (e.commands_watcher) |*w| { w.start(callback, userdata) catch { e.setError("commands watcher start failed") catch {}; return 0; }; return e.nextSubId(); }
    e.setError("commands watcher not available (call tm_session_start first)") catch {};
    return 0;
}
export fn tm_commands_unwatch(engine: ?*Engine, sub: u32) void { _ = sub; if (engine) |e| { if (e.commands_watcher) |*w| w.stop(); } }

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
        11 => "TM_ERR_TIMEOUT", 12 => "TM_ERR_INVALID_WORKER", else => "TM_ERR_UNKNOWN",
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

// ─── Tests ───────────────────────────────────────────────

test "version returns 0.1.0" { try std.testing.expectEqualStrings("0.1.0", std.mem.span(tm_version())); }

test "result_to_string maps all codes" {
    try std.testing.expectEqualStrings("TM_OK", std.mem.span(tm_result_to_string(0)));
    try std.testing.expectEqualStrings("TM_ERR_CONFIG", std.mem.span(tm_result_to_string(7)));
    try std.testing.expectEqualStrings("TM_ERR_NOT_IMPLEMENTED", std.mem.span(tm_result_to_string(10)));
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

test { _ = config; _ = worktree; _ = pty_mod; _ = bus; _ = github; _ = commands; }
