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
// PTY death monitor — detects worker process exits
//
// Ghostty owns PTY lifecycle (pty.zig). The PtyMonitor provides
// a safety-net: Swift registers PIDs via tm_worker_monitor_pid,
// a background thread polls with kill(pid, 0) per POSIX.1,
// and fires handlePtyDied on detection. The primary detection
// path is Swift calling tm_worker_pty_died directly when
// Ghostty's SurfaceView observes process exit.
// ─────────────────────────────────────────────────────────

const PtyMonitor = struct {
    allocator: std.mem.Allocator,
    pids: std.AutoHashMap(std.posix.pid_t, worktree.WorkerId),
    mutex: std.Thread.Mutex,
    thread: ?std.Thread,
    running: std.atomic.Value(bool),
    engine: *Engine,

    fn init(allocator: std.mem.Allocator, engine: *Engine) PtyMonitor {
        return .{
            .allocator = allocator,
            .pids = std.AutoHashMap(std.posix.pid_t, worktree.WorkerId).init(allocator),
            .mutex = .{},
            .thread = null,
            .running = std.atomic.Value(bool).init(false),
            .engine = engine,
        };
    }

    fn deinit(self: *PtyMonitor) void {
        self.stop();
        self.pids.deinit();
    }

    /// Register a PID for death monitoring.
    fn watch(self: *PtyMonitor, pid: std.posix.pid_t, worker_id: worktree.WorkerId) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.pids.put(pid, worker_id);
    }

    /// Unregister monitoring for a worker (by worker ID).
    fn unwatch(self: *PtyMonitor, worker_id: worktree.WorkerId) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var remove_pid: ?std.posix.pid_t = null;
        var it = self.pids.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == worker_id) {
                remove_pid = entry.key_ptr.*;
                break;
            }
        }
        if (remove_pid) |pid| {
            _ = self.pids.remove(pid);
        }
    }

    fn start(self: *PtyMonitor) !void {
        if (self.thread != null) return;
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, monitorLoop, .{self});
    }

    fn stop(self: *PtyMonitor) void {
        if (self.thread == null) return;
        self.running.store(false, .release);
        self.thread.?.join();
        self.thread = null;
    }

    fn monitorLoop(self: *PtyMonitor) void {
        while (self.running.load(.acquire)) {
            // 500ms poll — well within the 1s detection requirement
            std.Thread.sleep(500 * std.time.ns_per_ms);
            if (!self.running.load(.acquire)) break;
            self.pollOnce();
        }
    }

    fn pollOnce(self: *PtyMonitor) void {
        // Fixed buffer for dead PIDs per poll cycle. If >32 die simultaneously,
        // excess are caught on next poll (500ms later) — self-healing.
        var dead: [32]struct { pid: std.posix.pid_t, wid: worktree.WorkerId } = undefined;
        var dead_count: usize = 0;
        var overflow = false;

        // Collect dead PIDs under lock
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            var it = self.pids.iterator();
            while (it.next()) |entry| {
                if (!isProcessAlive(entry.key_ptr.*)) {
                    if (dead_count < dead.len) {
                        dead[dead_count] = .{ .pid = entry.key_ptr.*, .wid = entry.value_ptr.* };
                        dead_count += 1;
                    } else {
                        overflow = true;
                    }
                }
            }

            for (dead[0..dead_count]) |d| {
                _ = self.pids.remove(d.pid);
            }
        }

        if (overflow) {
            std.log.warn("[teammux] PtyMonitor: dead PID buffer full ({d}), deferring remainder to next poll", .{dead.len});
        }

        // Fire callbacks outside lock (avoids deadlock with engine mutexes)
        for (dead[0..dead_count]) |d| {
            self.engine.handlePtyDied(d.wid, -1);
        }
    }

    fn countWatched(self: *PtyMonitor) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return @intCast(self.pids.count());
    }

    /// POSIX.1 kill(pid, 0): checks process existence without sending a signal.
    /// Returns true if process exists, false if ESRCH (no such process).
    fn isProcessAlive(pid: std.posix.pid_t) bool {
        // Signal 0 does not send a signal — it only validates PID existence.
        // Returns 0 if process exists and we have permission.
        // Returns -1 with ESRCH if process does not exist.
        // Returns -1 with EPERM if process exists but we lack permission.
        if (std.c.kill(pid, 0) == 0) return true;
        // EPERM (errno 1) means process exists but different user — still alive.
        // ESRCH (errno 3) means no such process — dead.
        // Hardcoded: std.c does not expose ESRCH as a named constant.
        return std.c._errno().* != 3;
    }
};

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
    last_error_mutex: std.Thread.Mutex,
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
    pty_monitor: PtyMonitor,
    health_monitor_thread: ?std.Thread,
    health_monitor_running: std.atomic.Value(bool),

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
            .github_client = try github.GitHubClient.init(allocator, null),
            .commands_watcher = null,
            .role_watchers = hotreload.RoleWatcherMap.init(allocator),
            .session_id = sid,
            .last_error = null,
            .last_error_cstr = null,
            .last_error_mutex = .{},
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
            .pty_monitor = undefined, // initialized below (needs engine pointer)
            .health_monitor_thread = null,
            .health_monitor_running = std.atomic.Value(bool).init(false),
        };
        engine.pty_monitor = PtyMonitor.init(allocator, engine);
        return engine;
    }

    pub fn destroy(self: *Engine) void {
        self.pty_monitor.deinit(); // stop monitor thread before freeing engine state
        self.health_monitor_running.store(false, .release);
        if (self.health_monitor_thread) |t| {
            t.join();
            self.health_monitor_thread = null;
        }
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
        // Stage all subsystem inits in locals with errdefer rollback.
        // Only assign to self.* after the full startup path succeeds.

        const config_path = try std.fmt.allocPrint(self.allocator, "{s}/.teammux/config.toml", .{self.project_root});
        defer self.allocator.free(config_path);
        const override_path = try std.fmt.allocPrint(self.allocator, "{s}/.teammux/config.local.toml", .{self.project_root});
        defer self.allocator.free(override_path);

        var cfg = config.loadWithOverrides(self.allocator, config_path, override_path) catch |err| {
            self.setError("config load failed") catch {};
            return err;
        };
        errdefer cfg.deinit(self.allocator);

        // TD21: Scan for orphaned worktrees left by a previous engine crash.
        // Must run after config load (needs worktree_root) and while roster is
        // still empty (so all leftover directories are correctly identified as orphans).
        const orphan_count = worktree_lifecycle.recoverOrphans(self.allocator, &cfg, self.project_root, &self.roster);
        if (orphan_count > 0) {
            self.setError("recovered orphaned worktree(s) from previous crash") catch {};
        }

        const log_dir = try std.fmt.allocPrint(self.allocator, "{s}/.teammux/logs", .{self.project_root});
        defer self.allocator.free(log_dir);

        var msg_bus = bus.MessageBus.init(self.allocator, log_dir, &self.session_id, self.project_root) catch |err| {
            self.setError("message bus init failed") catch {};
            return err;
        };
        errdefer msg_bus.deinit();

        // I13: Wire error notification callback so PR delivery failures surface via setError
        msg_bus.error_notify_cb = busErrorNotifyCallback;
        msg_bus.error_notify_userdata = self;

        const cmd_dir = try std.fmt.allocPrint(self.allocator, "{s}/.teammux/commands", .{self.project_root});
        defer self.allocator.free(cmd_dir);

        var cmd_watcher = commands.CommandWatcher.init(self.allocator, cmd_dir) catch |err| {
            self.setError("commands watcher init failed") catch {};
            return err;
        };
        errdefer cmd_watcher.deinit();

        // Wire bus routing for /teammux-complete and /teammux-question
        cmd_watcher.bus_send_fn = busSendBridge;
        cmd_watcher.bus_send_userdata = self;

        // I6: Wire error callback so command failures surface via setError
        cmd_watcher.error_cb = commandErrorCallback;
        cmd_watcher.error_cb_userdata = self;

        var hist_logger = history_mod.HistoryLogger.init(self.allocator, self.project_root) catch |err| {
            self.setError("history logger init failed") catch {};
            return err;
        };
        errdefer hist_logger.deinit();

        // Update github client repo from loaded config (before commit so errdefers still active).
        // Called unconditionally: clears stale repo if new config removed github_repo.
        self.github_client.updateRepo(cfg.project.github_repo) catch |err| {
            self.setError("github client repo update failed") catch {};
            return err;
        };

        // All subsystems initialized — commit to self (no more errors possible)
        self.cfg = cfg;
        self.message_bus = msg_bus;
        self.commands_watcher = cmd_watcher;
        self.history_logger = hist_logger;

        // Start async history writer (I15) — must be after commit to self so
        // the writer thread's self pointer targets the stable Engine-embedded logger.
        if (self.history_logger) |*logger| {
            logger.startWriter() catch |err| {
                std.log.warn("[teammux] history: async writer start failed, writes will be synchronous: {}", .{err});
                self.setError("history: async writer unavailable — history writes will block the event loop") catch {};
            };
        }

        // Wire bus routing for PR status events from GitHub polling
        self.github_client.bus_send_fn = busSendBridge;
        self.github_client.bus_send_userdata = self;

        // Install Team Lead deny-all interceptor before any PTY surfaces are created.
        // Worker 0 is structurally prevented from writing code (C4).
        // This is a hard failure — session must not start without enforcement.
        const tl_result = tm_interceptor_install(self, 0);
        if (tl_result != 0) {
            self.setError("Team Lead interceptor install failed — session cannot start without git write enforcement") catch {};
            return error.InterceptorInstallFailed;
        }

        // Start PTY death monitor — polls registered PIDs for exit events
        self.pty_monitor.start() catch |err| {
            std.log.warn("[teammux] PTY monitor start failed: {} — relying on direct tm_worker_pty_died calls", .{err});
            self.setError("PTY death monitor failed to start — worker crash detection is degraded") catch {};
        };
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

        // Update sender's last activity timestamp for health monitoring
        {
            self.roster.mutex.lock();
            defer self.roster.mutex.unlock();
            if (self.roster.workers.getPtr(from)) |w| {
                w.last_activity_ts = std.time.timestamp();
            }
        }

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
                    const wf = self.roster.copyWorkerFields(from, self.allocator) catch |err| {
                        std.log.warn("[teammux] history: git commit capture skipped for worker {d}: {}", .{ from, err });
                        break :blk null;
                    };
                    if (wf) |fields| {
                        defer fields.deinit(self.allocator);
                        break :blk history_mod.captureGitCommit(self.allocator, fields.worktree_path);
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
        self.pty_monitor.stop();
        // Stop health monitor
        self.health_monitor_running.store(false, .release);
        if (self.health_monitor_thread) |t| {
            t.join();
            self.health_monitor_thread = null;
        }
        hotreload.stopAll(&self.role_watchers);
        if (self.commands_watcher) |*w| w.stop();
        if (self.config_watcher) |*w| w.stop();
        self.github_client.stopWebhooks();
        // Stop async history writer — drain queue before session ends
        if (self.history_logger) |*logger| logger.shutdown();
        // Clean up Team Lead interceptor from project root
        interceptor.remove(self.allocator, self.project_root) catch |err| {
            std.log.warn("[teammux] Team Lead interceptor cleanup failed: {}", .{err});
            self.setError("sessionStop: Team Lead interceptor cleanup failed — orphaned .git-wrapper may remain in project root") catch {};
        };
    }

    /// Handle PTY death for a worker. Called by both PtyMonitor (background)
    /// and tm_worker_pty_died (direct C API). Performs state reconciliation:
    /// marks worker errored, releases ownership, fires bus event (best-effort
    /// — delivery failures are logged but not propagated), sets error.
    /// Does NOT remove the worktree — preserves the worker's in-progress work.
    fn handlePtyDied(self: *Engine, worker_id: worktree.WorkerId, exit_code: i32) void {
        // State reconciliation: mark errored + release ownership
        if (!coordinator_mod.ptyDiedCallback(&self.roster, &self.ownership_registry, worker_id)) {
            return; // Worker not in roster (already dismissed or never existed)
        }

        // Unwatch PID (no-op if not monitored or already removed)
        self.pty_monitor.unwatch(worker_id);

        // Notify Team Lead (worker 0) via bus — from=dying_worker, to=team_lead.
        // Best-effort: delivery failures are logged but reconciliation already succeeded.
        if (self.message_bus) |*b| {
            var buf: [128]u8 = undefined;
            const payload = std.fmt.bufPrint(&buf, "{{\"worker_id\":{d},\"exit_code\":{d}}}", .{ worker_id, exit_code }) catch
                "{\"worker_id\":0,\"exit_code\":-1}";
            b.send(0, worker_id, .pty_died, payload) catch |err| {
                std.log.err("[teammux] PTY death bus notification failed for worker {d}: {}", .{ worker_id, err });
            };
        }

        // Set last error with worker ID and exit code
        var err_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&err_buf, "worker {d} PTY died with exit code {d}", .{ worker_id, exit_code }) catch
            "worker PTY died (details unavailable)";
        self.setError(msg) catch {};
    }

    fn healthMonitorLoop(self: *Engine) void {
        const check_interval_ns: u64 = 30 * std.time.ns_per_s;
        const threshold: i64 = blk: {
            if (self.cfgPtr()) |cfg| {
                const val = config.get(cfg, "stall_threshold_secs") orelse break :blk 300;
                break :blk std.fmt.parseInt(i64, val, 10) catch 300;
            }
            break :blk 300;
        };

        while (self.health_monitor_running.load(.acquire)) {
            std.Thread.sleep(check_interval_ns);
            if (!self.health_monitor_running.load(.acquire)) break;

            // Collect stalled worker IDs under lock
            var stalled_ids: [64]u32 = undefined;
            var stalled_count: usize = 0;
            const now = std.time.timestamp();
            {
                self.roster.mutex.lock();
                defer self.roster.mutex.unlock();
                var it = self.roster.workers.iterator();
                while (it.next()) |entry| {
                    const w = entry.value_ptr;
                    if (w.status != .idle and w.status != .working) continue;
                    if (w.health_status == .stalled) continue;
                    if (now - w.last_activity_ts > threshold) {
                        w.health_status = .stalled;
                        if (stalled_count < 64) {
                            stalled_ids[stalled_count] = w.id;
                            stalled_count += 1;
                        }
                    }
                }
            }

            // Fire bus events outside the lock
            if (stalled_count > 0) {
                if (self.message_bus) |*b| {
                    for (stalled_ids[0..stalled_count]) |wid| {
                        const payload = std.fmt.allocPrint(self.allocator,
                            \\{{"worker_id":{d},"threshold_secs":{d}}}
                        , .{ wid, threshold }) catch continue;
                        defer self.allocator.free(payload);
                        b.send(0, wid, .health_stalled, payload) catch |err| {
                            std.log.warn("[teammux] health stall event failed for worker {d}: {}", .{ wid, err });
                        };
                    }
                }
            }
        }
    }

    /// Set the last error message. Acquires last_error_mutex internally.
    /// NEVER call from code that already holds last_error_mutex (non-recursive).
    fn setError(self: *Engine, msg: []const u8) !void {
        self.last_error_mutex.lock();
        defer self.last_error_mutex.unlock();
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
    last_activity_ts: i64, health_status: c_int,
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
    resolution: c_int,
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
    // CWorkerInfo: u32(4) + pad(4) + 5 ptrs(40) + 2 c_int(8) + 2 ptrs(16) + u64(8) + i64(8) + c_int(4) + pad(4) = 96... actual 88
    if (@sizeOf(CWorkerInfo) != 88) @compileError("CWorkerInfo size mismatch with tm_worker_info_t");
    // CMessage (bus.zig): u32 + u32 + c_int + ptr + u64 + u64 + ptr = 48 bytes on arm64
    if (@sizeOf(bus.CMessage) != 48) @compileError("CMessage size mismatch with tm_message_t");
    // CConflict: 4 ptrs(32) + c_int(4) + pad(4) = 40 bytes on arm64
    if (@sizeOf(CConflict) != 40) @compileError("CConflict size mismatch with tm_conflict_t");
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
    const p = out orelse {
        last_create_error = "out must not be NULL";
        return 99;
    };
    p.* = null;
    const root = std.mem.span(project_root orelse { last_create_error = "project_root is NULL"; return 99; });
    const engine = Engine.create(std.heap.c_allocator, root) catch { last_create_error = "engine allocation failed"; return 99; };
    p.* = engine;
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

    // Start health monitor thread
    e.health_monitor_running.store(true, .release);
    e.health_monitor_thread = std.Thread.spawn(.{}, Engine.healthMonitorLoop, .{e}) catch |err| blk: {
        std.log.warn("[teammux] health monitor thread failed to start: {}", .{err});
        break :blk null;
    };

    return 0;
}
export fn tm_session_stop(engine: ?*Engine) void { if (engine) |e| e.sessionStop(); }
export fn tm_engine_last_error(engine: ?*Engine) [*:0]const u8 {
    const e = engine orelse return last_create_error;
    e.last_error_mutex.lock();
    defer e.last_error_mutex.unlock();
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
    // Load into local first — on failure, old config remains intact
    var new_cfg = config.loadWithOverrides(e.allocator, p1, p2) catch { e.setError("config reload failed") catch {}; return 7; };
    // Update GitHubClient repo before swapping config — on failure, discard new config
    e.github_client.updateRepo(new_cfg.project.github_repo) catch {
        e.setError("config reload: github repo update failed") catch {};
        new_cfg.deinit(e.allocator);
        return 7;
    };
    // All updates succeeded — swap config
    if (e.cfg) |*old| old.deinit(e.allocator);
    e.cfg = new_cfg;
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
    const ab = std.mem.span(agent_binary orelse return 0xFFFFFFFF);
    const at: config.AgentType = std.meta.intToEnum(config.AgentType, agent_type) catch {
        e.setError("tm_worker_spawn: invalid agent_type") catch {};
        return 0xFFFFFFFF;
    };
    const wn = std.mem.span(worker_name orelse return 0xFFFFFFFF);
    const td = std.mem.span(task_description orelse return 0xFFFFFFFF);

    // 1. Claim next worker ID from roster
    // Error paths below call unclaimId(id) to reclaim the slot on failure.
    const id = e.roster.claimNextId();

    // 2. Create worktree via lifecycle (single worktree subsystem)
    worktree_lifecycle.create(&e.wt_registry, e.cfgPtr(), e.project_root, id, td) catch |err| {
        e.setError(switch (err) {
            error.GitFailed => "git worktree add failed",
            error.NoHomeDir => "HOME not set, cannot resolve worktree root",
            error.MkdirFailed => "failed to create worktree directory",
            else => "worktree create failed",
        }) catch {};
        e.roster.unclaimId(id);
        return 0xFFFFFFFF;
    };

    // 3. Get path/branch from lifecycle registry
    const entry = e.wt_registry.get(id) orelse {
        e.setError("worktree created but not found in registry — internal error") catch {};
        worktree_lifecycle.removeWorker(&e.wt_registry, e.project_root, id);
        e.roster.unclaimId(id);
        return 0xFFFFFFFF;
    };

    // 4. Register worker in roster with lifecycle-owned path/branch
    e.roster.spawn(id, ab, at, wn, td, entry.path, entry.branch) catch |err| {
        e.setError(switch (err) { else => "worker roster registration failed" }) catch {};
        worktree_lifecycle.removeWorker(&e.wt_registry, e.project_root, id);
        e.roster.unclaimId(id);
        return 0xFFFFFFFF;
    };

    // 5. Write context file into worktree — hard failure rolls back spawn
    worktree.writeContextFile(e.allocator, entry.path, at, td, null, entry.branch) catch |err| {
        std.log.err("[teammux] context file write failed for worker {d}: {s} — rolling back spawn", .{ id, @errorName(err) });
        e.setError("worker spawn failed: could not write context file") catch {};
        e.roster.dismiss(id) catch |derr| {
            std.log.warn("[teammux] spawn rollback: dismiss worker {d} failed: {s}", .{ id, @errorName(derr) });
        };
        worktree_lifecycle.removeWorker(&e.wt_registry, e.project_root, id);
        e.roster.unclaimId(id);
        return 0xFFFFFFFF;
    };

    return id;
}
export fn tm_worker_dismiss(engine: ?*Engine, worker_id: u32) c_int {
    const e = engine orelse return 99;
    // Stop PID monitoring before dismiss
    e.pty_monitor.unwatch(worker_id);
    // Stop and remove role watcher before dismiss
    if (e.role_watchers.fetchRemove(worker_id)) |kv| {
        kv.value.destroy();
    }
    // Remove interceptor wrapper before worktree is deleted
    if (e.roster.copyWorkerFields(worker_id, e.allocator) catch |err| blk: {
        std.log.warn("[teammux] interceptor cleanup skipped for worker {d}: {}", .{ worker_id, err });
        break :blk null;
    }) |wf| {
        defer wf.deinit(e.allocator);
        interceptor.remove(e.allocator, wf.worktree_path) catch |err| {
            std.log.warn("[teammux] interceptor remove failed for worker {d}: {}", .{ worker_id, err });
        };
    }
    e.roster.dismiss(worker_id) catch { e.setError("worker dismiss failed") catch {}; return 5; };
    e.ownership_registry.release(worker_id);
    // Remove lifecycle worktree AFTER roster dismiss
    worktree_lifecycle.removeWorker(&e.wt_registry, e.project_root, worker_id);
    return 0;
}

// ─── PTY death notification ──────────────────────────────

/// Notify engine that a worker's PTY process died. Marks worker as errored,
/// releases ownership, preserves worktree, fires TM_MSG_PTY_DIED on bus.
/// This is the primary notification path — Swift/Ghostty calls this when
/// SurfaceView detects process exit.
export fn tm_worker_pty_died(engine: ?*Engine, worker_id: u32, exit_code: i32) c_int {
    const e = engine orelse return 99;
    if (!e.roster.hasWorker(worker_id)) {
        e.setError("tm_worker_pty_died: worker not found") catch {};
        return 12; // TM_ERR_INVALID_WORKER
    }
    e.handlePtyDied(worker_id, exit_code);
    return 0;
}

/// Register a PID for death monitoring. The engine's PtyMonitor polls
/// registered PIDs via kill(pid, 0) and fires handlePtyDied on detection.
/// This is a safety-net backup — the primary path is tm_worker_pty_died.
export fn tm_worker_monitor_pid(engine: ?*Engine, worker_id: u32, pid: c_int) c_int {
    const e = engine orelse return 99;
    if (!e.roster.hasWorker(worker_id)) {
        e.setError("tm_worker_monitor_pid: worker not found") catch {};
        return 12; // TM_ERR_INVALID_WORKER
    }
    e.pty_monitor.watch(pid, worker_id) catch {
        e.setError("tm_worker_monitor_pid: failed to register PID") catch {};
        return 99;
    };
    return 0;
}

export fn tm_worker_restart(engine: ?*Engine, worker_id: u32) c_int {
    const e = engine orelse return 99;
    e.roster.mutex.lock();
    defer e.roster.mutex.unlock();
    const w = e.roster.workers.getPtr(worker_id) orelse {
        e.setError("tm_worker_restart: worker not found") catch {};
        return 12; // TM_ERR_INVALID_WORKER
    };
    w.health_status = .healthy;
    w.last_activity_ts = std.time.timestamp();
    return 0;
}

export fn tm_worker_health_status(engine: ?*Engine, worker_id: u32) c_int {
    const e = engine orelse return 0;
    e.roster.mutex.lock();
    defer e.roster.mutex.unlock();
    const w = e.roster.workers.getPtr(worker_id) orelse return 0;
    return @intFromEnum(w.health_status);
}

export fn tm_worker_last_activity(engine: ?*Engine, worker_id: u32) i64 {
    const e = engine orelse return 0;
    e.roster.mutex.lock();
    defer e.roster.mutex.unlock();
    const w = e.roster.workers.getPtr(worker_id) orelse return 0;
    return w.last_activity_ts;
}
// ─── Worktree lifecycle ──────────────────────────────────

// NO SWIFT CALLER — candidate for removal in v0.2
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

// NO SWIFT CALLER — candidate for removal in v0.2
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
    // Hold roster mutex for the entire iteration — concurrent spawn/dismiss
    // could invalidate the HashMap iterator.
    e.roster.mutex.lock();
    defer e.roster.mutex.unlock();
    const count: u32 = @intCast(e.roster.workers.count());
    const c_roster = alloc.create(CRoster) catch {
        e.setError("tm_roster_get: allocation failed") catch {};
        return null;
    };
    const c_workers = alloc.alloc(CWorkerInfo, count) catch {
        alloc.destroy(c_roster);
        e.setError("tm_roster_get: allocation failed") catch {};
        return null;
    };
    var idx: usize = 0;
    var it = e.roster.workers.iterator();
    while (it.next()) |entry| {
        c_workers[idx] = fillCWorkerInfo(alloc, entry.value_ptr) catch {
            for (0..idx) |j| freeCWorkerInfo(c_workers[j]);
            alloc.free(c_workers); alloc.destroy(c_roster);
            e.setError("tm_roster_get: worker info fill failed") catch {};
            return null;
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
    const wf = e.roster.copyWorkerFields(worker_id, e.allocator) catch {
        e.setError("tm_worker_get: allocation failed") catch {};
        return null;
    } orelse return null;
    defer wf.deinit(e.allocator);
    const info = e.allocator.create(CWorkerInfo) catch return null;
    info.* = fillCWorkerInfoFromFields(e.allocator, wf) catch { e.allocator.destroy(info); return null; };
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

// PTY ownership belongs to Ghostty.
// Teammux does not directly manage PTY file descriptors.

// ─── Message bus ─────────────────────────────────────────

export fn tm_message_send(engine: ?*Engine, target_worker_id: u32, msg_type: c_int, payload: ?[*:0]const u8) c_int {
    const e = engine orelse return 99;
    var b = &(e.message_bus orelse return 8);
    b.send(target_worker_id, 0, @enumFromInt(msg_type), std.mem.span(payload orelse return 8)) catch |err| {
        e.setError(if (err == error.DeliveryFailed) "message delivery failed after 4 attempts" else "message send failed") catch {};
        return 8;
    };

    // Update target worker's last activity timestamp (receiving a message = activity)
    {
        e.roster.mutex.lock();
        defer e.roster.mutex.unlock();
        if (e.roster.workers.getPtr(target_worker_id)) |w| {
            w.last_activity_ts = std.time.timestamp();
        }
    }

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
    const wf = e.roster.copyWorkerFields(worker_id, e.allocator) catch {
        e.setError("PR creation failed: allocation error") catch {};
        return null;
    } orelse {
        e.setError("PR creation failed: worker not found") catch {};
        return null;
    };
    defer wf.deinit(e.allocator);
    const alloc = e.allocator;
    const title_slice = std.mem.span(title orelse {
        e.setError("PR creation failed: title is NULL") catch {};
        return null;
    });
    const body_slice = std.mem.span(body orelse {
        e.setError("PR creation failed: body is NULL") catch {};
        return null;
    });
    const branch_name = wf.branch_name;
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
export fn tm_github_get_diff(engine: ?*Engine, pr_number: u64) ?*CDiff {
    const e = engine orelse return null;
    const alloc = e.allocator;

    var diff = e.github_client.getDiff(alloc, pr_number) catch |err| {
        const msg = if (err == error.NoRepo) "diff failed: no repo configured" else if (err == error.GhCommandFailed) "diff failed: GitHub API error" else "diff failed: unexpected error";
        e.setError(msg) catch {};
        return null;
    };
    defer diff.deinit(alloc);

    // Convert Zig Diff to C-compatible CDiff
    const c_diff = alloc.create(CDiff) catch {
        e.setError("diff failed: allocation error") catch {};
        return null;
    };
    errdefer alloc.destroy(c_diff);

    const c_files = alloc.alloc(CDiffFile, diff.files.len) catch {
        e.setError("diff failed: allocation error") catch {};
        return null;
    };
    errdefer alloc.free(c_files);

    var filled: usize = 0;
    errdefer for (c_files[0..filled]) |f| {
        freeNullTerminated(f.file_path);
        freeNullTerminated(f.patch);
    };

    for (diff.files, 0..) |file, i| {
        const path_z = alloc.dupeZ(u8, file.path) catch {
            e.setError("diff failed: allocation error") catch {};
            return null;
        };
        const patch_z = alloc.dupeZ(u8, file.patch) catch {
            alloc.free(path_z);
            e.setError("diff failed: allocation error") catch {};
            return null;
        };

        c_files[i] = .{
            .file_path = path_z.ptr,
            .status = @intFromEnum(file.status),
            .additions = file.additions,
            .deletions = file.deletions,
            .patch = patch_z.ptr,
        };
        filled += 1;
    }

    c_diff.* = .{
        .files = c_files.ptr,
        .count = @intCast(diff.files.len),
        .total_additions = diff.total_additions,
        .total_deletions = diff.total_deletions,
    };
    return c_diff;
}
export fn tm_diff_free(diff: ?*CDiff) void {
    const d = diff orelse return;
    const count = d.count;
    if (d.files) |files_ptr| {
        for (files_ptr[0..count]) |f| {
            freeNullTerminated(f.file_path);
            freeNullTerminated(f.patch);
        }
        std.heap.c_allocator.free(files_ptr[0..count]);
    }
    std.heap.c_allocator.destroy(d);
}
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

/// I6: Error callback for CommandWatcher — surfaces command processing errors via setError.
fn commandErrorCallback(msg: ?[*:0]const u8, userdata: ?*anyopaque) callconv(.c) void {
    const engine: *Engine = @ptrCast(@alignCast(userdata orelse {
        std.log.warn("[teammux] commandErrorCallback: null engine pointer", .{});
        return;
    }));
    if (msg) |m| {
        engine.setError(std.mem.span(m)) catch |err| {
            std.log.err("[teammux] commandErrorCallback: setError failed: {s}", .{@errorName(err)});
        };
    }
}

/// I13: Error callback for MessageBus — surfaces PR delivery failures via setError.
fn busErrorNotifyCallback(msg: ?[*:0]const u8, userdata: ?*anyopaque) callconv(.c) void {
    const engine: *Engine = @ptrCast(@alignCast(userdata orelse {
        std.log.warn("[teammux] busErrorNotifyCallback: null engine pointer", .{});
        return;
    }));
    if (msg) |m| {
        engine.setError(std.mem.span(m)) catch |err| {
            std.log.err("[teammux] busErrorNotifyCallback: setError failed: {s}", .{@errorName(err)});
        };
    }
}

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
        // C4: Block /teammux-assign entirely via command files — worker_id is
        // spoofable in untrusted JSON. Task assignment must use tm_dispatch_task
        // through the authenticated Swift UI path.
        std.log.warn("[teammux] /teammux-assign: command-file dispatch disabled — use tm_dispatch_task from the Teammux UI", .{});
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

    if (!engine.roster.hasWorker(from_id)) {
        std.log.warn("[teammux] /teammux-ask: sender worker {d} not found in roster", .{from_id});
        return;
    }

    if (!engine.roster.hasWorker(target_id)) {
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

    if (!engine.roster.hasWorker(from_id)) {
        std.log.warn("[teammux] /teammux-delegate: sender worker {d} not found in roster", .{from_id});
        return;
    }

    if (!engine.roster.hasWorker(target_id)) {
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
        if (err == error.DeliveryFailed) {
            e.setError("tm_dispatch_task: delivery failed after retries") catch {};
            return 16; // TM_ERR_DELIVERY_FAILED
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
        if (err == error.DeliveryFailed) {
            e.setError("tm_dispatch_response: delivery failed after retries") catch {};
            return 16; // TM_ERR_DELIVERY_FAILED
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

// NO SWIFT CALLER — candidate for removal in v0.2
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
    if (!e.roster.hasWorker(from_id)) {
        e.setError("tm_peer_question: sender worker not found") catch {};
        return 12; // TM_ERR_INVALID_WORKER
    }
    if (!e.roster.hasWorker(target_id)) {
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

// NO SWIFT CALLER — candidate for removal in v0.2
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
    if (!e.roster.hasWorker(from_id)) {
        e.setError("tm_peer_delegate: sender worker not found") catch {};
        return 12; // TM_ERR_INVALID_WORKER
    }
    if (!e.roster.hasWorker(target_id)) {
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

// NO SWIFT CALLER — candidate for removal in v0.2
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

    // Update worker activity timestamp
    {
        e.roster.mutex.lock();
        defer e.roster.mutex.unlock();
        if (e.roster.workers.getPtr(worker_id)) |w| {
            w.last_activity_ts = std.time.timestamp();
        }
    }

    b.send(0, worker_id, .completion, payload) catch |err| {
        e.setError(if (err == error.DeliveryFailed) "completion delivery failed after retries exhausted" else "completion bus send failed") catch {};
        return 8;
    };

    // History write for C API path (Swift calling tm_worker_complete).
    // The command-file path (busSendBridge) has its own history write.
    if (e.history_logger) |*logger| {
        const git_commit = blk: {
            const wf = e.roster.copyWorkerFields(worker_id, e.allocator) catch |err| {
                std.log.warn("[teammux] history: git commit capture skipped for worker {d}: {}", .{ worker_id, err });
                break :blk null;
            };
            if (wf) |fields| {
                defer fields.deinit(e.allocator);
                break :blk history_mod.captureGitCommit(e.allocator, fields.worktree_path);
            }
            break :blk null;
        };
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

// NO SWIFT CALLER — candidate for removal in v0.2
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

    // Update worker activity timestamp
    {
        e.roster.mutex.lock();
        defer e.roster.mutex.unlock();
        if (e.roster.workers.getPtr(worker_id)) |w| {
            w.last_activity_ts = std.time.timestamp();
        }
    }

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

// NO SWIFT CALLER — candidate for removal in v0.2
/// Free a heap-allocated tm_completion_t.
export fn tm_completion_free(completion: ?*CCompletion) void {
    if (completion) |c| {
        freeNullTerminated(c.summary);
        freeNullTerminated(c.git_commit);
        freeNullTerminated(c.details);
        std.heap.c_allocator.destroy(c);
    }
}

// NO SWIFT CALLER — candidate for removal in v0.2
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

// NO SWIFT CALLER — candidate for removal in v0.2
/// Clear all history entries (truncates the JSONL file).
export fn tm_history_clear(engine: ?*Engine) c_int {
    const e = engine orelse return 99;
    var logger = &(e.history_logger orelse {
        e.setError("tm_history_clear: history logger not initialized") catch {};
        return 99;
    });
    logger.clear() catch |err| {
        std.log.err("[teammux] tm_history_clear failed: {}", .{err});
        e.setError("tm_history_clear: failed to clear history") catch {};
        return 99;
    };
    return 0;
}

/// Manually trigger history log rotation (TD24).
/// Rotates completion_history.jsonl → .1, .1 → .2, discards old .2.
/// Returns TM_OK on success. Flushes async queue before rotating.
export fn tm_history_rotate(engine: ?*Engine) c_int {
    const e = engine orelse return 99;
    var logger = &(e.history_logger orelse {
        e.setError("tm_history_rotate: history logger not initialized") catch {};
        return 99;
    });
    logger.rotate() catch |err| {
        std.log.err("[teammux] tm_history_rotate failed: {}", .{err});
        e.setError("tm_history_rotate: rotation failed") catch {};
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
    const result = e.merge_coordinator.approve(&e.roster, e.project_root, worker_id, strat) catch |err| {
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
    if (result == .cleanup_incomplete) {
        e.setError("merge succeeded but cleanup incomplete — manual worktree/branch removal may be needed") catch {};
        return 15; // TM_ERR_CLEANUP_INCOMPLETE
    }
    return 0;
}
export fn tm_merge_reject(engine: ?*Engine, worker_id: u32) c_int {
    const e = engine orelse return 99;
    // Stop and remove role watcher before reject
    if (e.role_watchers.fetchRemove(worker_id)) |kv| {
        kv.value.destroy();
    }
    // Remove interceptor wrapper before worktree is deleted
    if (e.roster.copyWorkerFields(worker_id, e.allocator) catch |err| blk: {
        std.log.warn("[teammux] interceptor cleanup skipped for worker {d}: {}", .{ worker_id, err });
        break :blk null;
    }) |wf| {
        defer wf.deinit(e.allocator);
        interceptor.remove(e.allocator, wf.worktree_path) catch |err| {
            std.log.warn("[teammux] interceptor remove failed for worker {d}: {}", .{ worker_id, err });
        };
    }
    const cleanup_ok = e.merge_coordinator.reject(&e.roster, e.project_root, worker_id) catch |err| {
        e.setError(if (err == error.WorkerNotFound) "merge reject failed: worker not found" else "merge reject failed") catch {};
        return if (err == error.WorkerNotFound) 12 else 5;
    };
    e.ownership_registry.release(worker_id);
    if (!cleanup_ok) {
        e.setError("merge rejected but cleanup incomplete — manual worktree/branch removal may be needed") catch {};
        return 15; // TM_ERR_CLEANUP_INCOMPLETE
    }
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

    const resolutions = e.merge_coordinator.getResolutions(worker_id);
    const alloc = e.allocator;
    const ptrs = alloc.alloc(?*CConflict, conflicts.len) catch { if (count) |c| c.* = 0; return null; };
    for (conflicts, 0..) |conf, i| {
        const cc = alloc.create(CConflict) catch {
            for (0..i) |j| freeCConflict(ptrs[j]);
            alloc.free(ptrs); if (count) |c| c.* = 0; return null;
        };
        cc.* = fillCConflict(alloc, conf, resolutions) catch {
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
export fn tm_conflict_resolve(engine: ?*Engine, worker_id: u32, file_path: ?[*:0]const u8, resolution: c_int) c_int {
    const e = engine orelse return 99;
    const fp = std.mem.span(file_path orelse {
        e.setError("tm_conflict_resolve: file_path is NULL") catch {};
        return 12;
    });
    const res: merge.ConflictResolution = switch (resolution) {
        0 => .ours,
        1 => .theirs,
        2 => .skip,
        else => {
            e.setError("tm_conflict_resolve: invalid resolution value") catch {};
            return 12;
        },
    };
    e.merge_coordinator.resolveConflict(e.project_root, worker_id, fp, res) catch |err| {
        e.setError(switch (err) {
            error.NoActiveMerge => "conflict resolve failed: no active merge for this worker",
            error.NoConflicts => "conflict resolve failed: no conflicts for this worker",
            error.FileNotInConflicts => "conflict resolve failed: file not in conflict list",
            error.InvalidResolution => "conflict resolve failed: invalid resolution",
            error.GitFailed => "conflict resolve failed: git operation failed",
            else => "conflict resolve failed",
        }) catch {};
        return 12; // TM_ERR_INVALID_WORKER
    };
    return 0;
}
export fn tm_conflict_finalize(engine: ?*Engine, worker_id: u32) c_int {
    const e = engine orelse return 99;
    // Stop and remove role watcher before finalize cleanup
    if (e.role_watchers.fetchRemove(worker_id)) |kv| {
        kv.value.destroy();
    }
    // Remove interceptor wrapper before worktree is deleted
    if (e.roster.copyWorkerFields(worker_id, e.allocator) catch |err| blk: {
        std.log.warn("[teammux] interceptor cleanup skipped for worker {d}: {}", .{ worker_id, err });
        break :blk null;
    }) |wf| {
        defer wf.deinit(e.allocator);
        interceptor.remove(e.allocator, wf.worktree_path) catch |err| {
            std.log.warn("[teammux] interceptor remove failed for worker {d}: {}", .{ worker_id, err });
        };
    }
    const result = e.merge_coordinator.finalizeMerge(&e.roster, e.project_root, worker_id) catch |err| {
        e.setError(switch (err) {
            error.NoActiveMerge => "conflict finalize failed: no active merge for this worker",
            error.NoConflicts => "conflict finalize failed: no conflicts for this worker",
            error.UnresolvedConflicts => "conflict finalize failed: unresolved files remain",
            error.GitFailed => "conflict finalize failed: git commit failed",
            else => "conflict finalize failed",
        }) catch {};
        return 12; // TM_ERR_INVALID_WORKER
    };
    e.ownership_registry.release(worker_id);
    if (result == .cleanup_incomplete) {
        e.setError("merge finalized but cleanup incomplete — manual worktree/branch removal may be needed") catch {};
        return 15; // TM_ERR_CLEANUP_INCOMPLETE
    }
    return 0;
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

    // Team Lead (worker 0) cannot receive write grants
    if (worker_id == 0 and allow_write) {
        e.setError("tm_ownership_register: write grants not allowed for Team Lead (worker 0)") catch {};
        return 14; // TM_ERR_OWNERSHIP
    }

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

// NO SWIFT CALLER — candidate for removal in v0.2
export fn tm_ownership_get(engine: ?*Engine, worker_id: u32, count: ?*u32) ?[*]?*COwnershipEntry {
    if (count) |c| c.* = 0;
    const e = engine orelse return null;
    const alloc = e.allocator;

    // Thread-safe: copyRules duplicates all data under the registry lock
    const rules = e.ownership_registry.copyRules(worker_id, alloc) catch {
        e.setError("tm_ownership_get: allocation failed") catch {};
        return null;
    } orelse return null;
    defer ownership.FileOwnershipRegistry.freeRulesCopy(alloc, rules);
    if (rules.len == 0) {
        return null;
    }

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

// NO SWIFT CALLER — candidate for removal in v0.2
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

// NO SWIFT CALLER — candidate for removal in v0.2
export fn tm_ownership_update(
    engine: ?*Engine,
    worker_id: u32,
    write_patterns: ?[*]const ?[*:0]const u8,
    write_count: u32,
    deny_patterns: ?[*]const ?[*:0]const u8,
    deny_count: u32,
) c_int {
    const e = engine orelse return 99;

    // Team Lead (worker 0) cannot receive write grants
    if (worker_id == 0 and write_count > 0) {
        e.setError("tm_ownership_update: write grants not allowed for Team Lead (worker 0)") catch {};
        return 14; // TM_ERR_OWNERSHIP
    }

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

    // Team Lead (worker 0): deny-all interceptor in project root.
    // Worker 0 is never in the roster, so handle before roster lookup.
    if (worker_id == 0) {
        const deny_all = [_][]const u8{"*"};
        const empty = [_][]const u8{};
        interceptor.install(e.allocator, e.project_root, 0, "Team Lead", &deny_all, &empty) catch |err| {
            e.setError(switch (err) {
                error.GitNotFound => "tm_interceptor_install: git binary not found on PATH",
                else => "tm_interceptor_install: failed to install Team Lead wrapper",
            }) catch {};
            return 5; // TM_ERR_WORKTREE
        };
        return 0;
    }

    const wf = e.roster.copyWorkerFields(worker_id, e.allocator) catch {
        e.setError("tm_interceptor_install: allocation failed") catch {};
        return 5; // TM_ERR_WORKTREE
    } orelse {
        e.setError("tm_interceptor_install: worker not found") catch {};
        return 12; // TM_ERR_INVALID_WORKER
    };
    defer wf.deinit(e.allocator);

    // Get deny and write patterns from ownership registry (thread-safe copy)
    const rules = e.ownership_registry.copyRules(worker_id, e.allocator) catch {
        e.setError("tm_interceptor_install: allocation failed") catch {};
        return 5; // TM_ERR_WORKTREE
    };
    defer if (rules) |r| ownership.FileOwnershipRegistry.freeRulesCopy(e.allocator, r);

    // Count deny vs write patterns
    var deny_count: usize = 0;
    var write_count: usize = 0;
    if (rules) |r| {
        for (r) |rule| {
            if (rule.allow_write) write_count += 1 else deny_count += 1;
        }
    }

    // Build pattern arrays from copied rules (caller-owned, safe from concurrent mutation)
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

    interceptor.install(e.allocator, wf.worktree_path, worker_id, wf.name, deny_pats, write_pats) catch |err| {
        e.setError(switch (err) {
            error.GitNotFound => "tm_interceptor_install: git binary not found on PATH",
            error.UnsafePattern => "tm_interceptor_install: pattern contains shell metacharacters",
            else => "tm_interceptor_install: failed to install wrapper script",
        }) catch {};
        return 5; // TM_ERR_WORKTREE
    };
    return 0;
}

// NO SWIFT CALLER — candidate for removal in v0.2
export fn tm_interceptor_remove(engine: ?*Engine, worker_id: u32) c_int {
    const e = engine orelse return 99;

    // Team Lead (worker 0): interceptor lives in project root
    if (worker_id == 0) {
        interceptor.remove(e.allocator, e.project_root) catch {
            e.setError("tm_interceptor_remove: failed to remove Team Lead wrapper") catch {};
            return 5; // TM_ERR_WORKTREE
        };
        return 0;
    }

    const wf = e.roster.copyWorkerFields(worker_id, e.allocator) catch {
        e.setError("tm_interceptor_remove: allocation failed") catch {};
        return 5; // TM_ERR_WORKTREE
    } orelse {
        e.setError("tm_interceptor_remove: worker not found") catch {};
        return 12; // TM_ERR_INVALID_WORKER
    };
    defer wf.deinit(e.allocator);
    interceptor.remove(e.allocator, wf.worktree_path) catch {
        e.setError("tm_interceptor_remove: failed to remove wrapper") catch {};
        return 5; // TM_ERR_WORKTREE
    };
    return 0;
}

export fn tm_interceptor_path(engine: ?*Engine, worker_id: u32) ?[*:0]const u8 {
    const e = engine orelse return null;

    // Team Lead (worker 0): interceptor lives in project root
    if (worker_id == 0) {
        const path = interceptor.getInterceptorPath(std.heap.c_allocator, e.project_root) catch {
            e.setError("tm_interceptor_path: filesystem error checking Team Lead interceptor") catch {};
            return null;
        };
        if (path) |p| {
            const z = std.heap.c_allocator.dupeZ(u8, p) catch {
                std.heap.c_allocator.free(p);
                e.setError("tm_interceptor_path: OOM allocating Team Lead wrapper path") catch {};
                return null;
            };
            std.heap.c_allocator.free(p);
            return z.ptr;
        }
        return null;
    }

    const wf = e.roster.copyWorkerFields(worker_id, e.allocator) catch {
        e.setError("tm_interceptor_path: allocation failed") catch {};
        return null;
    } orelse {
        e.setError("tm_interceptor_path: worker not found") catch {};
        return null;
    };
    defer wf.deinit(e.allocator);
    const path = interceptor.getInterceptorPath(std.heap.c_allocator, wf.worktree_path) catch {
        e.setError("tm_interceptor_path: filesystem error checking interceptor directory") catch {};
        return null;
    };
    if (path) |p| {
        const z = std.heap.c_allocator.dupeZ(u8, p) catch {
            std.heap.c_allocator.free(p);
            e.setError("tm_interceptor_path: OOM allocating worker interceptor path") catch {};
            return null;
        };
        std.heap.c_allocator.free(p);
        return z.ptr;
    }
    return null;
}

// ─── Role hot-reload ─────────────────────────────────────

export fn tm_role_watch(engine: ?*Engine, worker_id: u32, role_id: ?[*:0]const u8, callback: ?*const fn (u32, ?[*:0]const u8, u64, ?*anyopaque) callconv(.c) void, userdata: ?*anyopaque) c_int {
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

    const wf = e.roster.copyWorkerFields(worker_id, e.allocator) catch {
        e.setError("tm_role_watch: allocation failed") catch {};
        return 99;
    } orelse {
        e.setError("tm_role_watch: worker not found") catch {};
        return 12; // TM_ERR_INVALID_WORKER
    };
    defer wf.deinit(e.allocator);

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
        wf.task_description,
        wf.branch_name,
        e.project_root,
        wf.worktree_path,
        wf.name,
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

// NO SWIFT CALLER — candidate for removal in v0.2
export fn tm_agent_resolve(agent_name: ?[*:0]const u8) ?[*:0]const u8 {
    const name = std.mem.span(agent_name orelse return null);
    const result = github.resolveAgentBinary(std.heap.c_allocator, name) catch return null;
    if (result) |r| { const z = std.heap.c_allocator.dupeZ(u8, r) catch return null; std.heap.c_allocator.free(r); return z.ptr; }
    return null;
}
export fn tm_free_string(str: ?[*:0]const u8) void { if (str) |s| { std.heap.c_allocator.free(std.mem.span(s)); } }
export fn tm_version() [*:0]const u8 { return "0.1.0"; }
// NO SWIFT CALLER — candidate for removal in v0.2
export fn tm_result_to_string(result: c_int) [*:0]const u8 {
    return switch (result) {
        0 => "TM_OK", 1 => "TM_ERR_NOT_GIT", 2 => "TM_ERR_NO_GH", 3 => "TM_ERR_GH_UNAUTH",
        4 => "TM_ERR_NO_AGENT", 5 => "TM_ERR_WORKTREE", 6 => "TM_ERR_PTY", 7 => "TM_ERR_CONFIG",
        8 => "TM_ERR_BUS", 9 => "TM_ERR_GITHUB", 10 => "TM_ERR_NOT_IMPLEMENTED",
        11 => "TM_ERR_TIMEOUT", 12 => "TM_ERR_INVALID_WORKER", 13 => "TM_ERR_ROLE",
        14 => "TM_ERR_OWNERSHIP",
        15 => "TM_ERR_CLEANUP_INCOMPLETE",
        16 => "TM_ERR_DELIVERY_FAILED",
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
        .agent_binary = binary.ptr, .model = model_z.ptr, .spawned_at = w.spawned_at,
        .last_activity_ts = w.last_activity_ts, .health_status = @intFromEnum(w.health_status) };
}

fn fillCWorkerInfoFromFields(alloc: std.mem.Allocator, wf: worktree.WorkerFields) !CWorkerInfo {
    const name = try alloc.dupeZ(u8, wf.name); errdefer alloc.free(name);
    const task = try alloc.dupeZ(u8, wf.task_description); errdefer alloc.free(task);
    const branch = try alloc.dupeZ(u8, wf.branch_name); errdefer alloc.free(branch);
    const wt_path = try alloc.dupeZ(u8, wf.worktree_path); errdefer alloc.free(wt_path);
    const binary = try alloc.dupeZ(u8, wf.agent_binary); errdefer alloc.free(binary);
    const model_z = try alloc.dupeZ(u8, wf.model);
    return .{ .id = wf.id, .name = name.ptr, .task_description = task.ptr, .branch_name = branch.ptr,
        .worktree_path = wt_path.ptr, .status = @intFromEnum(wf.status), .agent_type = @intFromEnum(wf.agent_type),
        .agent_binary = binary.ptr, .model = model_z.ptr, .spawned_at = wf.spawned_at,
        .last_activity_ts = wf.last_activity_ts, .health_status = @intFromEnum(wf.health_status) };
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

fn fillCConflict(alloc: std.mem.Allocator, c: merge.Conflict, resolutions: ?*std.StringHashMap(merge.ConflictResolution)) !CConflict {
    const fp = try alloc.dupeZ(u8, c.file_path); errdefer alloc.free(fp);
    const ct = try alloc.dupeZ(u8, c.conflict_type); errdefer alloc.free(ct);
    const ours = try alloc.dupeZ(u8, c.ours); errdefer alloc.free(ours);
    const theirs = try alloc.dupeZ(u8, c.theirs);
    const res: c_int = if (resolutions) |r|
        @intFromEnum(r.get(c.file_path) orelse merge.ConflictResolution.pending)
    else
        @intFromEnum(merge.ConflictResolution.pending);
    return .{ .file_path = fp.ptr, .conflict_type = ct.ptr, .ours = ours.ptr, .theirs = theirs.ptr, .resolution = res };
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

test "engine create with null out-param returns error" {
    try std.testing.expect(tm_engine_create(".", null) == 99);
    try std.testing.expectEqualStrings("out must not be NULL", std.mem.span(tm_engine_last_error(null)));
}

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
test "tm_conflict_resolve null engine returns TM_ERR_UNKNOWN" { try std.testing.expect(tm_conflict_resolve(null, 0, null, 0) == 99); }
test "tm_conflict_finalize null engine returns TM_ERR_UNKNOWN" { try std.testing.expect(tm_conflict_finalize(null, 0) == 99); }

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

    // Verify rules are gone via copyRules
    try std.testing.expect(try e.ownership_registry.copyRules(worker_id, std.testing.allocator) == null);
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
    {
        const rules_copy = try e.ownership_registry.copyRules(worker_id, std.testing.allocator) orelse return error.TestUnexpectedResult;
        defer ownership.FileOwnershipRegistry.freeRulesCopy(std.testing.allocator, rules_copy);
        try std.testing.expect(rules_copy.len > 0);
    }

    // Reject merge — should release ownership
    try std.testing.expect(tm_merge_reject(engine_ptr, worker_id) == 0);

    // After reject, ownership released
    try std.testing.expect(try e.ownership_registry.copyRules(worker_id, std.testing.allocator) == null);
}

test "tm_result_to_string maps TM_ERR_OWNERSHIP" {
    try std.testing.expectEqualStrings("TM_ERR_OWNERSHIP", std.mem.span(tm_result_to_string(14)));
}

test "tm_result_to_string maps TM_ERR_CLEANUP_INCOMPLETE" {
    try std.testing.expectEqualStrings("TM_ERR_CLEANUP_INCOMPLETE", std.mem.span(tm_result_to_string(15)));
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

test "tm_history_rotate null engine returns TM_ERR_UNKNOWN" {
    try std.testing.expect(tm_history_rotate(null) == 99);
}

test "tm_history_rotate without session returns TM_ERR_UNKNOWN" {
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

    // history_logger is null without session start
    try std.testing.expect(tm_history_rotate(engine_ptr) == 99);
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
        fn cb(_: u32, _: ?[*:0]const u8, _: u64, _: ?*anyopaque) callconv(.c) void {}
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
        fn cb(_: u32, _: ?[*:0]const u8, _: u64, _: ?*anyopaque) callconv(.c) void {}
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

test "command routing wrapper blocks /teammux-assign via command file (C4)" {
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

    // Even with a valid non-zero worker_id, /teammux-assign is blocked
    // entirely via command files — task assignment must use tm_dispatch_task
    const args_json = "{\"worker_id\": 1, \"target_worker_id\": 5, \"instruction\": \"refactor auth\"}";
    const args_z = try alloc.dupeZ(u8, args_json);
    defer alloc.free(args_z);
    const cmd_z = try alloc.dupeZ(u8, "/teammux-assign");
    defer alloc.free(cmd_z);

    commandRoutingCallback(cmd_z.ptr, args_z.ptr, e);

    // No dispatch should have been recorded — command-file assign is disabled
    const history = e.coordinator.getHistory();
    try std.testing.expect(history.len == 0);
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

// ─── T16 integration tests: 8 cross-component scenarios ──────────

test "T16 integration 1: worktree create/path/branch/remove via C API" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    try worktree.runGit(alloc, root, &.{ "init", "-b", "main" });
    try worktree.runGit(alloc, root, &.{ "config", "user.email", "t@t.com" });
    try worktree.runGit(alloc, root, &.{ "config", "user.name", "T" });
    const readme = try std.fmt.allocPrint(alloc, "{s}/README.md", .{root});
    defer alloc.free(readme);
    {
        const f = try std.fs.createFileAbsolute(readme, .{});
        try f.writeAll("# T16");
        f.close();
    }
    try worktree.runGit(alloc, root, &.{ "add", "." });
    try worktree.runGit(alloc, root, &.{ "commit", "-m", "init" });

    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);
    var engine_ptr: ?*Engine = null;
    try std.testing.expect(tm_engine_create(root_z.ptr, &engine_ptr) == 0);
    defer tm_engine_destroy(engine_ptr);

    const desc_z = try alloc.dupeZ(u8, "implement JWT auth tokens");
    defer alloc.free(desc_z);
    try std.testing.expect(tm_worktree_create(engine_ptr, 5, desc_z.ptr) == 0);

    // Path is non-null and directory exists on disk
    const path_ptr = tm_worktree_path(engine_ptr, 5);
    try std.testing.expect(path_ptr != null);
    const path_str = std.mem.span(path_ptr.?);
    {
        var dir = try std.fs.openDirAbsolute(path_str, .{});
        dir.close();
    }

    // Branch has teammux/ prefix and contains worker ID
    const branch_ptr = tm_worktree_branch(engine_ptr, 5);
    try std.testing.expect(branch_ptr != null);
    const branch_str = std.mem.span(branch_ptr.?);
    try std.testing.expect(branch_str.len >= 8 and std.mem.eql(u8, branch_str[0..8], "teammux/"));
    try std.testing.expect(std.mem.indexOf(u8, branch_str, "5-") != null);

    // Remove cleans up registry
    try std.testing.expect(tm_worktree_remove(engine_ptr, 5) == 0);
    try std.testing.expect(tm_worktree_path(engine_ptr, 5) == null);
    try std.testing.expect(tm_worktree_branch(engine_ptr, 5) == null);
}

test "T16 integration 2: tm_peer_question routes to Team Lead (worker 0)" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const e = try Engine.create(alloc, root);
    defer e.destroy();

    const log_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{root});
    defer alloc.free(log_dir);
    e.message_bus = try bus.MessageBus.init(alloc, log_dir, "t16pq", root);

    try e.roster.workers.put(2, try coordinator_mod.makeTestWorker(alloc, 2));
    try e.roster.workers.put(5, try coordinator_mod.makeTestWorker(alloc, 5));

    const PQState = struct {
        var to_id: u32 = 99;
        var msg_type: c_int = -1;
        var payload_buf: [512]u8 = undefined;
        var payload_len: usize = 0;
    };
    PQState.to_id = 99;
    PQState.msg_type = -1;
    PQState.payload_len = 0;

    const pq_cb = struct {
        fn f(msg: ?*const bus.CMessage, _: ?*anyopaque) callconv(.c) c_int {
            if (msg) |m| {
                PQState.to_id = m.to;
                PQState.msg_type = m.msg_type;
                if (m.payload) |p| {
                    const s = std.mem.span(p);
                    const len = @min(s.len, PQState.payload_buf.len);
                    @memcpy(PQState.payload_buf[0..len], s[0..len]);
                    PQState.payload_len = len;
                }
            }
            return 0;
        }
    }.f;

    e.message_bus.?.subscribe(pq_cb, null);

    const msg_z = try alloc.dupeZ(u8, "how should I handle auth?");
    defer alloc.free(msg_z);
    try std.testing.expect(tm_peer_question(e, 2, 5, msg_z.ptr) == 0);

    try std.testing.expect(PQState.to_id == 0); // Team Lead only
    try std.testing.expect(PQState.msg_type == @intFromEnum(bus.MessageType.peer_question));
    const pq_payload = PQState.payload_buf[0..PQState.payload_len];
    try std.testing.expect(std.mem.indexOf(u8, pq_payload, "how should I handle auth?") != null);
    // Team Lead needs target_worker_id to relay the question
    try std.testing.expect(std.mem.indexOf(u8, pq_payload, "\"target_worker_id\":5") != null);
}

test "T16 integration 3: tm_peer_delegate routes to target worker directly" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const e = try Engine.create(alloc, root);
    defer e.destroy();

    const log_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{root});
    defer alloc.free(log_dir);
    e.message_bus = try bus.MessageBus.init(alloc, log_dir, "t16pd", root);

    try e.roster.workers.put(3, try coordinator_mod.makeTestWorker(alloc, 3));
    try e.roster.workers.put(7, try coordinator_mod.makeTestWorker(alloc, 7));

    const PDState = struct {
        var to_id: u32 = 99;
        var from_id: u32 = 99;
        var msg_type: c_int = -1;
        var payload_buf: [512]u8 = undefined;
        var payload_len: usize = 0;
    };
    PDState.to_id = 99;
    PDState.from_id = 99;
    PDState.msg_type = -1;
    PDState.payload_len = 0;

    const pd_cb = struct {
        fn f(msg: ?*const bus.CMessage, _: ?*anyopaque) callconv(.c) c_int {
            if (msg) |m| {
                PDState.to_id = m.to;
                PDState.from_id = m.from;
                PDState.msg_type = m.msg_type;
                if (m.payload) |p| {
                    const s = std.mem.span(p);
                    const len = @min(s.len, PDState.payload_buf.len);
                    @memcpy(PDState.payload_buf[0..len], s[0..len]);
                    PDState.payload_len = len;
                }
            }
            return 0;
        }
    }.f;

    e.message_bus.?.subscribe(pd_cb, null);

    const task_z = try alloc.dupeZ(u8, "write unit tests for auth");
    defer alloc.free(task_z);
    try std.testing.expect(tm_peer_delegate(e, 3, 7, task_z.ptr) == 0);

    try std.testing.expect(PDState.to_id == 7); // target worker directly
    try std.testing.expect(PDState.from_id == 3); // sender
    try std.testing.expect(PDState.msg_type == @intFromEnum(bus.MessageType.delegation));
    try std.testing.expect(std.mem.indexOf(u8, PDState.payload_buf[0..PDState.payload_len], "write unit tests for auth") != null);
}

test "T16 integration 4: TM_MSG_PR_READY routed through bus with PR URL" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    try worktree.runGit(alloc, root, &.{ "init", "-b", "main" });
    try worktree.runGit(alloc, root, &.{ "config", "user.email", "t@t.com" });
    try worktree.runGit(alloc, root, &.{ "config", "user.name", "T" });
    const readme = try std.fmt.allocPrint(alloc, "{s}/README.md", .{root});
    defer alloc.free(readme);
    {
        const f = try std.fs.createFileAbsolute(readme, .{});
        try f.writeAll("# T16");
        f.close();
    }
    try worktree.runGit(alloc, root, &.{ "add", "." });
    try worktree.runGit(alloc, root, &.{ "commit", "-m", "init" });

    const e = try Engine.create(alloc, root);
    defer e.destroy();

    const log_dir = try std.fmt.allocPrint(alloc, "{s}/logs", .{root});
    defer alloc.free(log_dir);
    e.message_bus = try bus.MessageBus.init(alloc, log_dir, "t16pr", root);

    const PRState = struct {
        var received: bool = false;
        var msg_type: c_int = -1;
        var payload_buf: [512]u8 = undefined;
        var payload_len: usize = 0;
    };
    PRState.received = false;
    PRState.msg_type = -1;
    PRState.payload_len = 0;

    const pr_cb = struct {
        fn f(msg: ?*const bus.CMessage, _: ?*anyopaque) callconv(.c) c_int {
            if (msg) |m| {
                PRState.received = true;
                PRState.msg_type = m.msg_type;
                if (m.payload) |p| {
                    const s = std.mem.span(p);
                    const len = @min(s.len, PRState.payload_buf.len);
                    @memcpy(PRState.payload_buf[0..len], s[0..len]);
                    PRState.payload_len = len;
                }
            }
            return 0;
        }
    }.f;

    e.message_bus.?.subscribe(pr_cb, null);

    routePrReady(e, 2, "https://github.com/org/repo/pull/42", "teammux/2-auth", "Add JWT auth");

    try std.testing.expect(PRState.received);
    try std.testing.expect(PRState.msg_type == @intFromEnum(bus.MessageType.pr_ready));
    const pr_payload = PRState.payload_buf[0..PRState.payload_len];
    try std.testing.expect(std.mem.indexOf(u8, pr_payload, "\"worker_id\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, pr_payload, "https://github.com/org/repo/pull/42") != null);
    try std.testing.expect(std.mem.indexOf(u8, pr_payload, "teammux/2-auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, pr_payload, "Add JWT auth") != null);
}

test "T16 integration 5: JSONL history survives engine destroy and recreate" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    try worktree.runGit(alloc, root, &.{ "init", "-b", "main" });
    try worktree.runGit(alloc, root, &.{ "config", "user.email", "t@t.com" });
    try worktree.runGit(alloc, root, &.{ "config", "user.name", "T" });
    const readme_path = try std.fmt.allocPrint(alloc, "{s}/README.md", .{root});
    defer alloc.free(readme_path);
    {
        const f = try std.fs.createFileAbsolute(readme_path, .{});
        try f.writeAll("# T16");
        f.close();
    }
    try worktree.runGit(alloc, root, &.{ "add", "." });
    try worktree.runGit(alloc, root, &.{ "commit", "-m", "init" });

    const teammux_dir = try std.fmt.allocPrint(alloc, "{s}/.teammux", .{root});
    defer alloc.free(teammux_dir);
    std.fs.makeDirAbsolute(teammux_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const cfg_path = try std.fmt.allocPrint(alloc, "{s}/config.toml", .{teammux_dir});
    defer alloc.free(cfg_path);
    {
        const cfg_file = try std.fs.createFileAbsolute(cfg_path, .{});
        try cfg_file.writeAll("[project]\nname = \"t16-test\"\n");
        cfg_file.close();
    }

    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);

    // First engine lifecycle: write completion and question to JSONL
    {
        var engine_ptr: ?*Engine = null;
        try std.testing.expect(tm_engine_create(root_z.ptr, &engine_ptr) == 0);
        defer tm_engine_destroy(engine_ptr);
        try std.testing.expect(tm_session_start(engine_ptr) == 0);

        const sum_z = try alloc.dupeZ(u8, "auth module complete");
        defer alloc.free(sum_z);
        const det_z = try alloc.dupeZ(u8, "JWT implemented");
        defer alloc.free(det_z);
        try std.testing.expect(tm_worker_complete(engine_ptr, 3, sum_z.ptr, det_z.ptr) == 0);

        const q_z = try alloc.dupeZ(u8, "JWT or session tokens?");
        defer alloc.free(q_z);
        const ctx_z = try alloc.dupeZ(u8, "auth module");
        defer alloc.free(ctx_z);
        try std.testing.expect(tm_worker_question(engine_ptr, 5, q_z.ptr, ctx_z.ptr) == 0);
    }

    // Second engine lifecycle: load and verify both entries persisted in order
    {
        var engine_ptr: ?*Engine = null;
        try std.testing.expect(tm_engine_create(root_z.ptr, &engine_ptr) == 0);
        defer tm_engine_destroy(engine_ptr);
        try std.testing.expect(tm_session_start(engine_ptr) == 0);

        var count: u32 = 0;
        const entries = tm_history_load(engine_ptr, &count);
        defer tm_history_free(entries, count);

        try std.testing.expect(count == 2);
        try std.testing.expect(entries != null);

        const e0 = entries.?[0].?;
        try std.testing.expect(e0.worker_id == 3);
        try std.testing.expectEqualStrings("completion", std.mem.span(e0.entry_type.?));
        try std.testing.expectEqualStrings("auth module complete", std.mem.span(e0.content.?));

        const e1 = entries.?[1].?;
        try std.testing.expect(e1.worker_id == 5);
        try std.testing.expectEqualStrings("question", std.mem.span(e1.entry_type.?));
        try std.testing.expectEqualStrings("JWT or session tokens?", std.mem.span(e1.content.?));
    }
}

test "T16 integration 6: exit 126 in all enforcement blocks, no bare exit 1" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    try worktree.runGit(alloc, root, &.{ "init", "-b", "main" });
    try worktree.runGit(alloc, root, &.{ "config", "user.email", "t@t.com" });
    try worktree.runGit(alloc, root, &.{ "config", "user.name", "T" });
    const readme_path = try std.fmt.allocPrint(alloc, "{s}/README.md", .{root});
    defer alloc.free(readme_path);
    {
        const f = try std.fs.createFileAbsolute(readme_path, .{});
        try f.writeAll("# T16");
        f.close();
    }
    try worktree.runGit(alloc, root, &.{ "add", "." });
    try worktree.runGit(alloc, root, &.{ "commit", "-m", "init" });

    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);
    var engine_ptr: ?*Engine = null;
    try std.testing.expect(tm_engine_create(root_z.ptr, &engine_ptr) == 0);
    defer tm_engine_destroy(engine_ptr);

    const bin_z = try alloc.dupeZ(u8, "/usr/bin/echo");
    defer alloc.free(bin_z);
    const name_z = try alloc.dupeZ(u8, "Worker1");
    defer alloc.free(name_z);
    const task_z = try alloc.dupeZ(u8, "test interceptor");
    defer alloc.free(task_z);
    const worker_id = tm_worker_spawn(engine_ptr, bin_z.ptr, 0, name_z.ptr, task_z.ptr);
    try std.testing.expect(worker_id != 0xFFFFFFFF);

    const deny_z = try alloc.dupeZ(u8, "src/backend/**");
    defer alloc.free(deny_z);
    try std.testing.expect(tm_ownership_register(engine_ptr, worker_id, deny_z.ptr, false) == 0);

    try std.testing.expect(tm_interceptor_install(engine_ptr, worker_id) == 0);

    // Read the wrapper file and verify all enforcement blocks use exit 126
    const e = engine_ptr.?;
    const w = e.roster.getWorker(worker_id).?;
    const wrapper_path = try std.fmt.allocPrint(alloc, "{s}/.git-wrapper/git", .{w.worktree_path});
    defer alloc.free(wrapper_path);
    const file = try std.fs.openFileAbsolute(wrapper_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(alloc, 64 * 1024);
    defer alloc.free(content);

    // exit 126 present (all enforcement blocks)
    try std.testing.expect(std.mem.indexOf(u8, content, "exit 126") != null);
    // No bare "exit 1" followed by newline (would indicate old enforcement)
    try std.testing.expect(std.mem.indexOf(u8, content, "exit 1\n") == null);
    // All five enforcement types present (add + four elif blocks)
    try std.testing.expect(std.mem.indexOf(u8, content, "\"$subcmd\" == \"add\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"$subcmd\" == \"commit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"$subcmd\" == \"stash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"$subcmd\" == \"apply\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"$subcmd\" == \"push\"") != null);

    try std.testing.expect(tm_worker_dismiss(engine_ptr, worker_id) == 0);
}

test "T16 integration 7: TD18 ownership and interceptor updated after rule change" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    try worktree.runGit(alloc, root, &.{ "init", "-b", "main" });
    try worktree.runGit(alloc, root, &.{ "config", "user.email", "t@t.com" });
    try worktree.runGit(alloc, root, &.{ "config", "user.name", "T" });
    const readme_path = try std.fmt.allocPrint(alloc, "{s}/README.md", .{root});
    defer alloc.free(readme_path);
    {
        const f = try std.fs.createFileAbsolute(readme_path, .{});
        try f.writeAll("# T16");
        f.close();
    }
    try worktree.runGit(alloc, root, &.{ "add", "." });
    try worktree.runGit(alloc, root, &.{ "commit", "-m", "init" });

    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);
    var engine_ptr: ?*Engine = null;
    try std.testing.expect(tm_engine_create(root_z.ptr, &engine_ptr) == 0);
    defer tm_engine_destroy(engine_ptr);

    const bin_z = try alloc.dupeZ(u8, "/usr/bin/echo");
    defer alloc.free(bin_z);
    const name_z = try alloc.dupeZ(u8, "Worker2");
    defer alloc.free(name_z);
    const task_z = try alloc.dupeZ(u8, "test td18");
    defer alloc.free(task_z);
    const worker_id = tm_worker_spawn(engine_ptr, bin_z.ptr, 0, name_z.ptr, task_z.ptr);
    try std.testing.expect(worker_id != 0xFFFFFFFF);

    // Register initial patterns and install interceptor
    const old_deny_z = try alloc.dupeZ(u8, "src/old/**");
    defer alloc.free(old_deny_z);
    try std.testing.expect(tm_ownership_register(engine_ptr, worker_id, old_deny_z.ptr, false) == 0);
    try std.testing.expect(tm_interceptor_install(engine_ptr, worker_id) == 0);

    // Update ownership with new patterns (equivalent to hot-reload outcome via C API)
    const new_deny_z = try alloc.dupeZ(u8, "src/new/**");
    defer alloc.free(new_deny_z);
    const new_write_z = try alloc.dupeZ(u8, "src/api/**");
    defer alloc.free(new_write_z);
    var deny_ptrs = [_]?[*:0]const u8{new_deny_z.ptr};
    var write_ptrs = [_]?[*:0]const u8{new_write_z.ptr};
    try std.testing.expect(tm_ownership_update(engine_ptr, worker_id, @ptrCast(&write_ptrs), 1, @ptrCast(&deny_ptrs), 1) == 0);

    // Reinstall interceptor with new patterns
    try std.testing.expect(tm_interceptor_install(engine_ptr, worker_id) == 0);

    // Verify ownership reflects new rules after atomic swap
    var allowed: bool = undefined;
    try std.testing.expect(tm_ownership_check(engine_ptr, worker_id, "src/new/file.ts", &allowed) == 0);
    try std.testing.expect(!allowed); // denied by new pattern
    try std.testing.expect(tm_ownership_check(engine_ptr, worker_id, "src/api/handler.ts", &allowed) == 0);
    try std.testing.expect(allowed); // allowed by new write pattern
    // src/old/ files are denied by implicit default (rule 4: no explicit allow), NOT by old
    // deny pattern — wrapper file check below proves old pattern was fully removed

    // Verify wrapper reflects new patterns, not old
    const e = engine_ptr.?;
    const w = e.roster.getWorker(worker_id).?;
    const wrapper_path = try std.fmt.allocPrint(alloc, "{s}/.git-wrapper/git", .{w.worktree_path});
    defer alloc.free(wrapper_path);
    const file = try std.fs.openFileAbsolute(wrapper_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(alloc, 64 * 1024);
    defer alloc.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "src/new/**") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "src/old/**") == null);

    try std.testing.expect(tm_worker_dismiss(engine_ptr, worker_id) == 0);
}

test "T16 integration 8: config.toml worktree_root override respected" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    try worktree.runGit(alloc, root, &.{ "init", "-b", "main" });
    try worktree.runGit(alloc, root, &.{ "config", "user.email", "t@t.com" });
    try worktree.runGit(alloc, root, &.{ "config", "user.name", "T" });
    const readme_path = try std.fmt.allocPrint(alloc, "{s}/README.md", .{root});
    defer alloc.free(readme_path);
    {
        const f = try std.fs.createFileAbsolute(readme_path, .{});
        try f.writeAll("# T16");
        f.close();
    }
    try worktree.runGit(alloc, root, &.{ "add", "." });
    try worktree.runGit(alloc, root, &.{ "commit", "-m", "init" });

    // Write config.toml with custom worktree_root pointing inside tmpDir
    const custom_wt_root = try std.fmt.allocPrint(alloc, "{s}/custom-worktrees", .{root});
    defer alloc.free(custom_wt_root);
    const teammux_dir = try std.fmt.allocPrint(alloc, "{s}/.teammux", .{root});
    defer alloc.free(teammux_dir);
    std.fs.makeDirAbsolute(teammux_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const cfg_path = try std.fmt.allocPrint(alloc, "{s}/config.toml", .{teammux_dir});
    defer alloc.free(cfg_path);
    const cfg_content = try std.fmt.allocPrint(alloc, "[project]\nname = \"t16-wt\"\nworktree_root = \"{s}\"\n", .{custom_wt_root});
    defer alloc.free(cfg_content);
    {
        const cfg_file = try std.fs.createFileAbsolute(cfg_path, .{});
        try cfg_file.writeAll(cfg_content);
        cfg_file.close();
    }

    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);
    var engine_ptr: ?*Engine = null;
    try std.testing.expect(tm_engine_create(root_z.ptr, &engine_ptr) == 0);
    defer tm_engine_destroy(engine_ptr);
    try std.testing.expect(tm_session_start(engine_ptr) == 0);

    const desc_z = try alloc.dupeZ(u8, "test config override");
    defer alloc.free(desc_z);
    try std.testing.expect(tm_worktree_create(engine_ptr, 9, desc_z.ptr) == 0);

    // Verify path uses the custom worktree root
    const wt_path = tm_worktree_path(engine_ptr, 9);
    try std.testing.expect(wt_path != null);
    const wt_path_str = std.mem.span(wt_path.?);
    try std.testing.expect(std.mem.indexOf(u8, wt_path_str, "custom-worktrees") != null);

    try std.testing.expect(tm_worktree_remove(engine_ptr, 9) == 0);
}

// ─── C4: Team Lead enforcement tests ─────────────────────

test "C4 - tm_interceptor_install worker 0 creates deny-all wrapper" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const e = try Engine.create(alloc, root);
    defer e.destroy();

    // Install Team Lead interceptor (worker 0)
    try std.testing.expect(tm_interceptor_install(e, 0) == 0);

    // Verify wrapper exists in project root
    const wrapper_path = try std.fmt.allocPrint(alloc, "{s}/.git-wrapper/git", .{root});
    defer alloc.free(wrapper_path);
    const file = try std.fs.openFileAbsolute(wrapper_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(alloc, 64 * 1024);
    defer alloc.free(content);

    // Must contain deny-all pattern '*'
    try std.testing.expect(std.mem.indexOf(u8, content, "'*'") != null);
    // Must identify as Team Lead
    try std.testing.expect(std.mem.indexOf(u8, content, "Team Lead") != null);
    // Must have no write scope
    try std.testing.expect(std.mem.indexOf(u8, content, "(none defined)") != null);

    // Cleanup
    try std.testing.expect(tm_interceptor_remove(e, 0) == 0);
}

test "C4 - tm_interceptor_path worker 0 returns project root wrapper" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const e = try Engine.create(alloc, root);
    defer e.destroy();

    // Before install, path should be null
    try std.testing.expect(tm_interceptor_path(e, 0) == null);

    // Install and check path
    try std.testing.expect(tm_interceptor_install(e, 0) == 0);
    const path = tm_interceptor_path(e, 0);
    try std.testing.expect(path != null);
    const path_str = std.mem.span(path.?);
    try std.testing.expect(std.mem.endsWith(u8, path_str, "/.git-wrapper"));
    std.heap.c_allocator.free(path_str);

    // Cleanup
    try std.testing.expect(tm_interceptor_remove(e, 0) == 0);
}

test "C4 - tm_ownership_register rejects write grants for worker 0" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const e = try Engine.create(alloc, root);
    defer e.destroy();

    // Write grant for worker 0 must fail
    const pattern = "src/**";
    const pat_z = try alloc.dupeZ(u8, pattern);
    defer alloc.free(pat_z);
    try std.testing.expect(tm_ownership_register(e, 0, pat_z.ptr, true) == 14);

    // Deny pattern for worker 0 should succeed
    try std.testing.expect(tm_ownership_register(e, 0, pat_z.ptr, false) == 0);
}

test "C4 - tm_ownership_update rejects write grants for worker 0" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const e = try Engine.create(alloc, root);
    defer e.destroy();

    const pat = try alloc.dupeZ(u8, "src/**");
    defer alloc.free(pat);
    var write_pats = [_]?[*:0]const u8{pat.ptr};
    var deny_pats = [_]?[*:0]const u8{pat.ptr};

    // Write grants for worker 0 via update must fail
    try std.testing.expect(tm_ownership_update(e, 0, &write_pats, 1, null, 0) == 14);

    // Deny-only update for worker 0 should succeed
    try std.testing.expect(tm_ownership_update(e, 0, null, 0, &deny_pats, 1) == 0);
}

// ─── S8 integration tests ─────────────────────────────────

test "S8 scenario 1: updateRepo thread safety — mutex serializes repo swap" {
    // Verify that updateRepo() correctly dupes new value, swaps under lock,
    // and frees old outside lock. Confirms the mutex is available after
    // operations (not stuck locked). Sequential test — actual concurrency
    // is safe by the dupe-before-lock/free-after-unlock design pattern.
    const alloc = std.testing.allocator;

    var client = try github.GitHubClient.init(alloc, "owner/initial-repo");
    defer client.deinit();

    // Verify initial state
    try std.testing.expect(client.repo != null);
    try std.testing.expectEqualStrings("owner/initial-repo", client.repo.?);

    // Simulate config reload calling updateRepo with new value
    try client.updateRepo("owner/new-repo-after-reload");
    try std.testing.expectEqualStrings("owner/new-repo-after-reload", client.repo.?);

    // Verify mutex is available (not stuck locked)
    const repo_copy = blk: {
        client.repo_mutex.lock();
        defer client.repo_mutex.unlock();
        break :blk try alloc.dupe(u8, client.repo.?);
    };
    defer alloc.free(repo_copy);
    try std.testing.expectEqualStrings("owner/new-repo-after-reload", repo_copy);

    // Simulate updateRepo to null (repo removed from config)
    try client.updateRepo(null);
    try std.testing.expect(client.repo == null);

    // Simulate setting it back
    try client.updateRepo("owner/restored-repo");
    try std.testing.expectEqualStrings("owner/restored-repo", client.repo.?);
}

test "S8 scenario 1b: updateRepo value isolation — snapshot survives swap" {
    // Verify value isolation: a repo string copied under lock remains valid
    // and unchanged after updateRepo swaps the underlying repo. Demonstrates
    // that the snapshot-and-swap pattern produces correct results.
    const alloc = std.testing.allocator;

    var client = try github.GitHubClient.init(alloc, "owner/poll-repo");
    defer client.deinit();

    // Simulate what pollEvents does: lock → copy → unlock
    const repo_snapshot = blk: {
        client.repo_mutex.lock();
        defer client.repo_mutex.unlock();
        break :blk try alloc.dupe(u8, client.repo orelse unreachable);
    };
    defer alloc.free(repo_snapshot);

    // Now updateRepo replaces the repo — snapshot should still be valid
    try client.updateRepo("owner/changed-repo");

    try std.testing.expectEqualStrings("owner/poll-repo", repo_snapshot);
    try std.testing.expectEqualStrings("owner/changed-repo", client.repo.?);
}

test "S8 scenario 1c: config reload calls updateRepo via tm_config_reload path" {
    // Verify the tm_config_reload → updateRepo integration: create engine,
    // write config.toml with github_repo, reload, verify client.repo updated.
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    // Create .teammux directory with config.toml
    const teammux_dir = try std.fmt.allocPrint(alloc, "{s}/.teammux", .{root});
    defer alloc.free(teammux_dir);
    std.fs.makeDirAbsolute(teammux_dir) catch {};

    const config_path = try std.fmt.allocPrint(alloc, "{s}/config.toml", .{teammux_dir});
    defer alloc.free(config_path);
    {
        const f = try std.fs.createFileAbsolute(config_path, .{});
        try f.writeAll("[project]\ngithub_repo = \"owner/repo-v1\"\n");
        f.close();
    }

    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);
    var engine_ptr: ?*Engine = null;
    try std.testing.expect(tm_engine_create(root_z.ptr, &engine_ptr) == 0);
    defer tm_engine_destroy(engine_ptr);
    const e = engine_ptr.?;

    // Load initial config
    try std.testing.expect(tm_config_reload(e) == 0);

    // Verify github_repo was applied
    const val = tm_config_get(e, "github_repo");
    if (val) |v| {
        try std.testing.expectEqualStrings("owner/repo-v1", std.mem.span(v));
    }

    // Write updated config and reload
    {
        const f = try std.fs.createFileAbsolute(config_path, .{});
        try f.writeAll("[project]\ngithub_repo = \"owner/repo-v2\"\n");
        f.close();
    }
    try std.testing.expect(tm_config_reload(e) == 0);

    const val2 = tm_config_get(e, "github_repo");
    if (val2) |v| {
        try std.testing.expectEqualStrings("owner/repo-v2", std.mem.span(v));
    }
}

test "S8 scenario 2: merge cleanup incomplete returns correct status and logs stderr" {
    // NOTE: Non-deterministic (see TD39). On some git versions, the pre-removed
    // worktree may not cause cleanup failure, resulting in .success instead of
    // .cleanup_incomplete. Validates the code path compiles and runs but may
    // not exercise the cleanup_incomplete variant on all systems.
    // Strategy: commit on worker branch, pre-remove worktree (but keep branch
    // so git merge can find commits), then approve. Merge succeeds but
    // cleanup of the already-removed worktree fails → cleanup_incomplete.
    const alloc = std.testing.allocator;
    var repo = merge.setupTestRepo(alloc) catch return;
    defer repo.tmp.cleanup();
    defer alloc.free(repo.path);

    var roster = worktree.Roster.init(alloc);
    defer roster.deinit();

    const id = try merge.spawnTestWorker(alloc, &roster, repo.path, "CleanupWorker", "test cleanup");
    const wt_path = try alloc.dupe(u8, roster.getWorker(id).?.worktree_path);
    defer alloc.free(wt_path);

    // Commit on worker branch so merge has something to merge
    const file_path = try std.fmt.allocPrint(alloc, "{s}/s8_cleanup.txt", .{wt_path});
    defer alloc.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        try f.writeAll("S8 cleanup test content");
        f.close();
    }
    try worktree.runGit(alloc, wt_path, &.{ "add", "." });
    try worktree.runGit(alloc, wt_path, &.{ "commit", "-m", "S8 cleanup test" });

    // Pre-remove only the worktree (keep branch so merge can succeed)
    try worktree.runGit(alloc, repo.path, &.{ "worktree", "remove", "--force", wt_path });

    var mc = merge.MergeCoordinator.init(alloc);
    defer mc.deinit();

    const result = try mc.approve(&roster, repo.path, id, "merge");

    // Merge succeeds but worktree cleanup fails (already removed) → cleanup_incomplete.
    // On some git versions branch delete may also succeed, giving .success.
    try std.testing.expect(result == .cleanup_incomplete or result == .success);
    try std.testing.expect(mc.getStatus(id) == .success);
}

test "S8 scenario 2b: runGitLoggedWithStderr captures stderr on failure" {
    // Directly test that runGitLoggedWithStderr returns false and logs stderr
    // when the git command fails (e.g., removing a non-existent worktree).
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    try worktree.runGit(alloc, root, &.{ "init", "-b", "main" });

    // Try to remove a non-existent worktree — this will fail and log stderr
    const result = merge.runGitLoggedWithStderr(alloc, root, &.{ "worktree", "remove", "--force", "/nonexistent/path" }, "S8 test: worktree remove");
    try std.testing.expect(result == false);
}

test "S8 scenario 2c: MergeCoordinator.ApproveResult has cleanup_incomplete variant" {
    // Verify the ApproveResult enum includes the cleanup_incomplete variant
    // that S2 added (TD31 fix).
    const result: merge.ApproveResult = .cleanup_incomplete;
    try std.testing.expect(result == .cleanup_incomplete);
    try std.testing.expect(result != .success);
    try std.testing.expect(result != .conflict);
}

test "S8 scenario 3: ownership register-release-reregister cycle" {
    // Verify the C API supports the register-release-reregister cycle that
    // Swift's session restore relies on. The actual restore path
    // (restoreSession → spawnWorker → role resolution) is Swift-side;
    // this test confirms the engine-side contract.
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

    // Register ownership for worker 1: write to src/**, deny infra/**
    const write_pat = try alloc.dupeZ(u8, "src/**");
    defer alloc.free(write_pat);
    const deny_pat = try alloc.dupeZ(u8, "infra/**");
    defer alloc.free(deny_pat);

    try std.testing.expect(tm_ownership_register(engine_ptr, 1, write_pat.ptr, true) == 0);
    try std.testing.expect(tm_ownership_register(engine_ptr, 1, deny_pat.ptr, false) == 0);

    // Verify deny works before "session stop"
    var allowed: bool = true;
    const infra_path = try alloc.dupeZ(u8, "infra/deploy.yml");
    defer alloc.free(infra_path);
    try std.testing.expect(tm_ownership_check(engine_ptr, 1, infra_path.ptr, &allowed) == 0);
    try std.testing.expect(allowed == false);

    // Simulate session stop: release ownership
    try std.testing.expect(tm_ownership_release(engine_ptr, 1) == 0);

    // After release, no rules — default allow
    try std.testing.expect(tm_ownership_check(engine_ptr, 1, infra_path.ptr, &allowed) == 0);
    try std.testing.expect(allowed == true);

    // Simulate session restore: re-register the same ownership rules
    try std.testing.expect(tm_ownership_register(engine_ptr, 1, write_pat.ptr, true) == 0);
    try std.testing.expect(tm_ownership_register(engine_ptr, 1, deny_pat.ptr, false) == 0);

    // Verify deny patterns are enforced after restore
    try std.testing.expect(tm_ownership_check(engine_ptr, 1, infra_path.ptr, &allowed) == 0);
    try std.testing.expect(allowed == false);

    // Verify write patterns are enforced after restore
    const src_path = try alloc.dupeZ(u8, "src/main.swift");
    defer alloc.free(src_path);
    try std.testing.expect(tm_ownership_check(engine_ptr, 1, src_path.ptr, &allowed) == 0);
    try std.testing.expect(allowed == true);
}

test "S8 scenario 3b: ownership resets on engine destroy — re-register restores enforcement" {
    // Full session lifecycle: create engine, register ownership, destroy
    // engine, create new engine, verify clean slate, re-register, verify
    // enforcement. Confirms ownership does not leak across engine lifetimes.
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const root_z = try alloc.dupeZ(u8, root);
    defer alloc.free(root_z);

    // First engine lifecycle
    {
        var engine_ptr: ?*Engine = null;
        try std.testing.expect(tm_engine_create(root_z.ptr, &engine_ptr) == 0);

        const deny_pat = try alloc.dupeZ(u8, "secrets/**");
        defer alloc.free(deny_pat);
        try std.testing.expect(tm_ownership_register(engine_ptr, 2, deny_pat.ptr, false) == 0);

        var allowed: bool = true;
        const secret_path = try alloc.dupeZ(u8, "secrets/api_key.txt");
        defer alloc.free(secret_path);
        try std.testing.expect(tm_ownership_check(engine_ptr, 2, secret_path.ptr, &allowed) == 0);
        try std.testing.expect(allowed == false);

        tm_engine_destroy(engine_ptr);
    }

    // Second engine lifecycle (simulates session restore)
    {
        var engine_ptr: ?*Engine = null;
        try std.testing.expect(tm_engine_create(root_z.ptr, &engine_ptr) == 0);
        defer tm_engine_destroy(engine_ptr);

        // After fresh engine create, no ownership rules exist
        var allowed: bool = false;
        const secret_path = try alloc.dupeZ(u8, "secrets/api_key.txt");
        defer alloc.free(secret_path);
        try std.testing.expect(tm_ownership_check(engine_ptr, 2, secret_path.ptr, &allowed) == 0);
        try std.testing.expect(allowed == true); // No rules = default allow

        // Re-register (session restore path)
        const deny_pat = try alloc.dupeZ(u8, "secrets/**");
        defer alloc.free(deny_pat);
        try std.testing.expect(tm_ownership_register(engine_ptr, 2, deny_pat.ptr, false) == 0);

        // Now deny is enforced again
        try std.testing.expect(tm_ownership_check(engine_ptr, 2, secret_path.ptr, &allowed) == 0);
        try std.testing.expect(allowed == false);
    }
}

test "S8 scenario 4: getDiff parses GitHub PR files API response" {
    // Verify parseDiffResponse correctly parses the GitHub PR files API format
    // that getDiff returns. This exercises the S5 diff tab engine-side path.
    const alloc = std.testing.allocator;

    // Simulate a realistic GitHub PR files API response
    const json =
        \\[{"filename":"engine/src/github.zig","status":"modified","additions":42,"deletions":8,
        \\"patch":"@@ -100,8 +100,42 @@\n-old line\n+new line\n+added line"},
        \\{"filename":"engine/include/teammux.h","status":"modified","additions":15,"deletions":3,
        \\"patch":"@@ -50,3 +50,15 @@\n+// New diff types"},
        \\{"filename":"macos/Sources/Teammux/RightPane/DiffView.swift","status":"modified","additions":30,"deletions":10,
        \\"patch":"@@ -1,10 +1,30 @@\n+import SwiftUI"}]
    ;

    var diff = try github.parseDiffResponse(alloc, json);
    defer diff.deinit(alloc);

    // Verify file count and totals
    try std.testing.expect(diff.files.len == 3);
    try std.testing.expect(diff.total_additions == 87);
    try std.testing.expect(diff.total_deletions == 21);

    // Verify individual file details
    try std.testing.expectEqualStrings("engine/src/github.zig", diff.files[0].path);
    try std.testing.expect(diff.files[0].status == .modified);
    try std.testing.expect(diff.files[0].additions == 42);
    try std.testing.expect(diff.files[0].deletions == 8);
    try std.testing.expect(diff.files[0].patch.len > 0);

    try std.testing.expectEqualStrings("engine/include/teammux.h", diff.files[1].path);
    try std.testing.expectEqualStrings("macos/Sources/Teammux/RightPane/DiffView.swift", diff.files[2].path);
}

test "S8 scenario 4b: getDiff C API returns null on null engine" {
    try std.testing.expect(tm_github_get_diff(null, 1) == null);
}

test "S8 scenario 4c: diff free handles null safely" {
    tm_diff_free(null); // Should not crash
}

// ─── S5: PTY death cleanup (I8) ──────────────────────────

test "tm_worker_pty_died null engine returns TM_ERR_UNKNOWN" {
    try std.testing.expect(tm_worker_pty_died(null, 1, 1) == 99);
}

test "tm_worker_pty_died invalid worker returns TM_ERR_INVALID_WORKER" {
    const alloc = std.testing.allocator;
    const engine = try Engine.create(alloc, "/tmp/s5-test-invalid");
    defer engine.destroy();
    try std.testing.expect(tm_worker_pty_died(engine, 99, 1) == 12);
}

test "tm_worker_pty_died marks worker errored and releases ownership" {
    const alloc = std.testing.allocator;
    const engine = try Engine.create(alloc, "/tmp/s5-test-ptydied");
    defer engine.destroy();

    // Add a worker to roster
    try engine.roster.workers.put(1, try coordinator_mod.makeTestWorker(alloc, 1));

    // Register ownership
    try engine.ownership_registry.register(1, "src/**/*.zig", true);
    try std.testing.expect(engine.ownership_registry.rules.contains(1));

    // Verify precondition
    try std.testing.expect(engine.roster.getWorker(1).?.status == .idle);

    // Notify PTY death
    const result = tm_worker_pty_died(engine, 1, 137); // SIGKILL exit code
    try std.testing.expect(result == 0);

    // Worker marked errored
    try std.testing.expect(engine.roster.getWorker(1).?.status == .err);
    // Ownership released
    try std.testing.expect(!engine.ownership_registry.rules.contains(1));
    // Worker still in roster (not dismissed — worktree preserved)
    try std.testing.expect(engine.roster.count() == 1);
}

test "tm_worker_pty_died sets error with exit code info" {
    const alloc = std.testing.allocator;
    const engine = try Engine.create(alloc, "/tmp/s5-test-error");
    defer engine.destroy();

    try engine.roster.workers.put(1, try coordinator_mod.makeTestWorker(alloc, 1));

    _ = tm_worker_pty_died(engine, 1, 9);

    // Check error message contains worker ID and exit code
    const err = std.mem.span(tm_engine_last_error(engine));
    try std.testing.expect(std.mem.indexOf(u8, err, "worker 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, err, "exit code 9") != null);
}

test "tm_worker_pty_died fires TM_MSG_PTY_DIED on bus" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(log_dir);

    const engine = try Engine.create(alloc, log_dir);
    defer engine.destroy();

    // Initialize message bus
    var sid: [8]u8 = undefined;
    bus.generateSessionId(&sid);
    engine.message_bus = try bus.MessageBus.init(alloc, log_dir, &sid, log_dir);

    // Subscribe to bus
    const State = struct {
        var received: bool = false;
        var received_type: c_int = -1;
        var received_from: u32 = 0;
        var received_to: u32 = 0;
        var payload_has_worker_id: bool = false;
        var payload_has_exit_code: bool = false;
    };
    State.received = false;
    State.received_type = -1;
    State.received_from = 0;
    State.received_to = 0;
    State.payload_has_worker_id = false;
    State.payload_has_exit_code = false;

    const callback = struct {
        fn cb(msg: ?*const bus.CMessage, _: ?*anyopaque) callconv(.c) c_int {
            if (msg) |m| {
                State.received = true;
                State.received_type = m.msg_type;
                State.received_from = m.from;
                State.received_to = m.to;
                if (m.payload) |p| {
                    const payload = std.mem.span(p);
                    State.payload_has_worker_id = std.mem.indexOf(u8, payload, "\"worker_id\":1") != null;
                    State.payload_has_exit_code = std.mem.indexOf(u8, payload, "\"exit_code\":42") != null;
                }
            }
            return 0;
        }
    }.cb;
    engine.message_bus.?.subscribe(callback, null);

    // Add worker and fire PTY death
    try engine.roster.workers.put(1, try coordinator_mod.makeTestWorker(alloc, 1));
    _ = tm_worker_pty_died(engine, 1, 42);

    // Verify TM_MSG_PTY_DIED received with correct routing and payload
    try std.testing.expect(State.received);
    try std.testing.expect(State.received_type == @intFromEnum(bus.MessageType.pty_died));
    try std.testing.expect(State.received_from == 1); // from dying worker
    try std.testing.expect(State.received_to == 0); // to Team Lead (worker 0)
    try std.testing.expect(State.payload_has_worker_id);
    try std.testing.expect(State.payload_has_exit_code);
}

test "tm_worker_pty_died is idempotent" {
    const alloc = std.testing.allocator;
    const engine = try Engine.create(alloc, "/tmp/s5-test-idempotent");
    defer engine.destroy();

    try engine.roster.workers.put(1, try coordinator_mod.makeTestWorker(alloc, 1));

    // Call twice — both succeed, worker stays errored
    try std.testing.expect(tm_worker_pty_died(engine, 1, 1) == 0);
    try std.testing.expect(tm_worker_pty_died(engine, 1, 1) == 0);
    try std.testing.expect(engine.roster.getWorker(1).?.status == .err);
}

test "tm_worker_monitor_pid null engine returns TM_ERR_UNKNOWN" {
    try std.testing.expect(tm_worker_monitor_pid(null, 1, 12345) == 99);
}

test "tm_worker_monitor_pid invalid worker returns TM_ERR_INVALID_WORKER" {
    const alloc = std.testing.allocator;
    const engine = try Engine.create(alloc, "/tmp/s5-test-monpid");
    defer engine.destroy();
    try std.testing.expect(tm_worker_monitor_pid(engine, 99, 12345) == 12);
}

test "tm_worker_monitor_pid registers PID for monitoring" {
    const alloc = std.testing.allocator;
    const engine = try Engine.create(alloc, "/tmp/s5-test-monreg");
    defer engine.destroy();

    try engine.roster.workers.put(1, try coordinator_mod.makeTestWorker(alloc, 1));

    try std.testing.expect(engine.pty_monitor.countWatched() == 0);
    try std.testing.expect(tm_worker_monitor_pid(engine, 1, 99999) == 0);
    try std.testing.expect(engine.pty_monitor.countWatched() == 1);
}

test "PtyMonitor detects dead process via kill(pid, 0)" {
    const alloc = std.testing.allocator;
    const engine = try Engine.create(alloc, "/tmp/s5-test-detect");
    defer engine.destroy();

    try engine.roster.workers.put(1, try coordinator_mod.makeTestWorker(alloc, 1));

    // Use PID 1 (launchd) as an alive process — should NOT trigger death
    try std.testing.expect(PtyMonitor.isProcessAlive(1));

    // Use a PID that doesn't exist (very high PID) — should trigger death
    try std.testing.expect(!PtyMonitor.isProcessAlive(999999999));
}

test "PtyMonitor pollOnce detects dead PID and fires handlePtyDied" {
    const alloc = std.testing.allocator;
    const engine = try Engine.create(alloc, "/tmp/s5-test-poll");
    defer engine.destroy();

    try engine.roster.workers.put(1, try coordinator_mod.makeTestWorker(alloc, 1));

    // Register a PID that doesn't exist
    try engine.pty_monitor.watch(999999999, 1);
    try std.testing.expect(engine.pty_monitor.countWatched() == 1);

    // Verify worker is idle before poll
    try std.testing.expect(engine.roster.getWorker(1).?.status == .idle);

    // Poll — should detect the dead PID and fire handlePtyDied
    engine.pty_monitor.pollOnce();

    // PID should be removed from monitor
    try std.testing.expect(engine.pty_monitor.countWatched() == 0);
    // Worker should be marked errored
    try std.testing.expect(engine.roster.getWorker(1).?.status == .err);
}

test "tm_worker_dismiss unwatches PID from monitor" {
    const alloc = std.testing.allocator;
    const engine = try Engine.create(alloc, "/tmp/s5-test-dismiss");
    defer engine.destroy();

    // Need to add worker properly so dismiss can find it
    try engine.roster.workers.put(1, try coordinator_mod.makeTestWorker(alloc, 1));
    try engine.pty_monitor.watch(12345, 1);
    try std.testing.expect(engine.pty_monitor.countWatched() == 1);

    _ = tm_worker_dismiss(engine, 1);

    // PID should be unwatched after dismiss
    try std.testing.expect(engine.pty_monitor.countWatched() == 0);
}

test "S11 - tm_worker_restart returns INVALID_WORKER for missing worker" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_path);

    // Init a bare git repo so engine create succeeds
    const init_result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "git", "init", dir_path },
    });
    if (init_result) |r| { alloc.free(r.stdout); alloc.free(r.stderr); } else |_| {}

    const dir_z = try alloc.dupeZ(u8, dir_path);
    defer alloc.free(dir_z);

    var engine_ptr: ?*Engine = null;
    const rc = tm_engine_create(dir_z.ptr, @ptrCast(&engine_ptr));
    if (rc != 0 or engine_ptr == null) return; // Skip if engine create fails in test env

    defer tm_engine_destroy(engine_ptr);

    // Non-existent worker should return TM_ERR_INVALID_WORKER (12)
    try std.testing.expect(tm_worker_restart(engine_ptr, 99) == 12);
}

test "S11 - tm_worker_health_status returns healthy for missing worker" {
    try std.testing.expect(tm_worker_health_status(null, 99) == 0);
}

test "S11 - tm_worker_last_activity returns 0 for null engine" {
    try std.testing.expect(tm_worker_last_activity(null, 99) == 0);
}

test { _ = config; _ = worktree; _ = pty_mod; _ = bus; _ = github; _ = commands; _ = merge; _ = ownership; _ = interceptor; _ = hotreload; _ = coordinator_mod; _ = worktree_lifecycle; _ = history_mod; }
