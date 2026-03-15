// Teammux coordination engine — entry point
// All functions are stubs for Stream 1. Stream 2 implements the real logic.
// Stubs return TM_ERR_NOT_IMPLEMENTED (10) to force callers to handle errors.

const std = @import("std");

// Module imports — stubs for now, Stream 2 implements
pub const worktree = @import("worktree.zig");
pub const pty = @import("pty.zig");
pub const bus = @import("bus.zig");
pub const config = @import("config.zig");
pub const github = @import("github.zig");
pub const commands = @import("commands.zig");

// Error codes matching teammux.h
const TM_ERR_NOT_IMPLEMENTED: c_int = 10;

// Opaque engine type
const Engine = struct {
    project_root: [*c]const u8,
};

// Thread-local last error for tm_engine_create failure reporting
var last_create_error: [*c]const u8 = "engine not yet implemented (stub)";

// ------------------------------------------------------------------
// Engine lifecycle
// ------------------------------------------------------------------

export fn tm_engine_create(project_root: [*c]const u8, out: ?*?*Engine) c_int {
    _ = project_root;
    if (out) |p| {
        p.* = null;
    }
    last_create_error = "engine not yet implemented (stub)";
    return TM_ERR_NOT_IMPLEMENTED;
}

export fn tm_engine_destroy(engine: ?*Engine) void {
    _ = engine;
}

export fn tm_session_start(engine: ?*Engine) c_int {
    _ = engine;
    return TM_ERR_NOT_IMPLEMENTED;
}

export fn tm_session_stop(engine: ?*Engine) void {
    _ = engine;
}

export fn tm_engine_last_error(engine: ?*Engine) [*c]const u8 {
    _ = engine;
    return last_create_error;
}

// ------------------------------------------------------------------
// Config
// ------------------------------------------------------------------

export fn tm_config_reload(engine: ?*Engine) c_int {
    _ = engine;
    return TM_ERR_NOT_IMPLEMENTED;
}

export fn tm_config_watch(engine: ?*Engine, callback: ?*const anyopaque, userdata: ?*anyopaque) u32 {
    _ = engine;
    _ = callback;
    _ = userdata;
    return 0;
}

export fn tm_config_unwatch(engine: ?*Engine, sub: u32) void {
    _ = engine;
    _ = sub;
}

export fn tm_config_get(engine: ?*Engine, key: [*c]const u8) [*c]const u8 {
    _ = engine;
    _ = key;
    return null;
}

// ------------------------------------------------------------------
// Worktree and worker lifecycle
// ------------------------------------------------------------------

export fn tm_worker_spawn(
    engine: ?*Engine,
    agent_binary: [*c]const u8,
    agent_type: c_int,
    worker_name: [*c]const u8,
    task_description: [*c]const u8,
) u32 {
    _ = engine;
    _ = agent_binary;
    _ = agent_type;
    _ = worker_name;
    _ = task_description;
    return 0xFFFFFFFF; // TM_WORKER_INVALID
}

export fn tm_worker_dismiss(engine: ?*Engine, worker_id: u32) c_int {
    _ = engine;
    _ = worker_id;
    return TM_ERR_NOT_IMPLEMENTED;
}

export fn tm_roster_get(engine: ?*Engine) ?*anyopaque {
    _ = engine;
    return null;
}

export fn tm_roster_free(roster: ?*anyopaque) void {
    _ = roster;
}

export fn tm_worker_get(engine: ?*Engine, worker_id: u32) ?*anyopaque {
    _ = engine;
    _ = worker_id;
    return null;
}

export fn tm_worker_info_free(info: ?*anyopaque) void {
    _ = info;
}

export fn tm_roster_watch(engine: ?*Engine, callback: ?*const anyopaque, userdata: ?*anyopaque) u32 {
    _ = engine;
    _ = callback;
    _ = userdata;
    return 0;
}

export fn tm_roster_unwatch(engine: ?*Engine, sub: u32) void {
    _ = engine;
    _ = sub;
}

// ------------------------------------------------------------------
// PTY interaction
// ------------------------------------------------------------------

export fn tm_pty_send(engine: ?*Engine, worker_id: u32, text: [*c]const u8) c_int {
    _ = engine;
    _ = worker_id;
    _ = text;
    return TM_ERR_NOT_IMPLEMENTED;
}

export fn tm_pty_fd(engine: ?*Engine, worker_id: u32) c_int {
    _ = engine;
    _ = worker_id;
    return -1;
}

// ------------------------------------------------------------------
// Message bus
// ------------------------------------------------------------------

export fn tm_message_send(engine: ?*Engine, target_worker_id: u32, msg_type: c_int, payload: [*c]const u8) c_int {
    _ = engine;
    _ = target_worker_id;
    _ = msg_type;
    _ = payload;
    return TM_ERR_NOT_IMPLEMENTED;
}

export fn tm_message_broadcast(engine: ?*Engine, msg_type: c_int, payload: [*c]const u8) c_int {
    _ = engine;
    _ = msg_type;
    _ = payload;
    return TM_ERR_NOT_IMPLEMENTED;
}

export fn tm_message_subscribe(engine: ?*Engine, callback: ?*const anyopaque, userdata: ?*anyopaque) u32 {
    _ = engine;
    _ = callback;
    _ = userdata;
    return 0;
}

export fn tm_message_unsubscribe(engine: ?*Engine, sub: u32) void {
    _ = engine;
    _ = sub;
}

// ------------------------------------------------------------------
// GitHub integration
// ------------------------------------------------------------------

export fn tm_github_auth(engine: ?*Engine) c_int {
    _ = engine;
    return TM_ERR_NOT_IMPLEMENTED;
}

export fn tm_github_is_authed(engine: ?*Engine) bool {
    _ = engine;
    return false;
}

export fn tm_github_create_pr(engine: ?*Engine, worker_id: u32, title: [*c]const u8, body: [*c]const u8) ?*anyopaque {
    _ = engine;
    _ = worker_id;
    _ = title;
    _ = body;
    return null;
}

export fn tm_pr_free(pr: ?*anyopaque) void {
    _ = pr;
}

export fn tm_github_merge_pr(engine: ?*Engine, pr_number: u64, strategy: c_int) c_int {
    _ = engine;
    _ = pr_number;
    _ = strategy;
    return TM_ERR_NOT_IMPLEMENTED;
}

export fn tm_github_get_diff(engine: ?*Engine, worker_id: u32) ?*anyopaque {
    _ = engine;
    _ = worker_id;
    return null;
}

export fn tm_diff_free(diff: ?*anyopaque) void {
    _ = diff;
}

export fn tm_github_webhooks_start(engine: ?*Engine, callback: ?*const anyopaque, userdata: ?*anyopaque) u32 {
    _ = engine;
    _ = callback;
    _ = userdata;
    return 0;
}

export fn tm_github_webhooks_stop(engine: ?*Engine, sub: u32) void {
    _ = engine;
    _ = sub;
}

// ------------------------------------------------------------------
// /teammux-* command interception
// ------------------------------------------------------------------

export fn tm_commands_watch(engine: ?*Engine, callback: ?*const anyopaque, userdata: ?*anyopaque) u32 {
    _ = engine;
    _ = callback;
    _ = userdata;
    return 0;
}

export fn tm_commands_unwatch(engine: ?*Engine, sub: u32) void {
    _ = engine;
    _ = sub;
}

// ------------------------------------------------------------------
// Utility
// ------------------------------------------------------------------

export fn tm_agent_resolve(agent_name: [*c]const u8) [*c]const u8 {
    _ = agent_name;
    return null;
}

export fn tm_free_string(str: [*c]const u8) void {
    _ = str;
}

export fn tm_version() [*c]const u8 {
    return "0.1.0";
}
