const std = @import("std");
const worktree = @import("worktree.zig");
const bus = @import("bus.zig");
const ownership = @import("ownership.zig");

// ─────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────

pub const max_history: usize = 100;

pub const DispatchKind = enum(u8) {
    task = 0,
    response = 1,
};

pub const DispatchEvent = struct {
    target_worker_id: worktree.WorkerId,
    instruction: []const u8, // heap-allocated, owned by Coordinator
    timestamp: u64,
    delivered: bool,
    kind: DispatchKind,
};

// ─────────────────────────────────────────────────────────
// Coordinator
// ─────────────────────────────────────────────────────────

pub const Coordinator = struct {
    allocator: std.mem.Allocator,
    history: std.ArrayList(DispatchEvent),

    pub fn init(allocator: std.mem.Allocator) Coordinator {
        return .{
            .allocator = allocator,
            .history = .{},
        };
    }

    pub fn deinit(self: *Coordinator) void {
        for (self.history.items) |event| {
            self.allocator.free(event.instruction);
        }
        self.history.deinit(self.allocator);
    }

    /// Dispatch a task instruction to a specific worker.
    /// Validates worker exists in roster, routes through bus, records in history.
    /// If bus delivery fails, the event is recorded with delivered=false
    /// and error.DeliveryFailed is returned so callers can surface the failure.
    pub fn dispatchTask(
        self: *Coordinator,
        roster: *worktree.Roster,
        message_bus: *bus.MessageBus,
        worker_id: worktree.WorkerId,
        instruction: []const u8,
    ) !void {
        try self.dispatchWith(roster, message_bus, worker_id, .dispatch, .task, instruction);
    }

    /// Dispatch a response to a specific worker (e.g. answering a question).
    /// Same semantics as dispatchTask but with .response message type.
    pub fn dispatchResponse(
        self: *Coordinator,
        roster: *worktree.Roster,
        message_bus: *bus.MessageBus,
        worker_id: worktree.WorkerId,
        response: []const u8,
    ) !void {
        try self.dispatchWith(roster, message_bus, worker_id, .response, .response, response);
    }

    /// Get read-only view of dispatch history.
    pub fn getHistory(self: *const Coordinator) []const DispatchEvent {
        return self.history.items;
    }

    fn dispatchWith(
        self: *Coordinator,
        roster: *worktree.Roster,
        message_bus: *bus.MessageBus,
        worker_id: worktree.WorkerId,
        msg_type: bus.MessageType,
        kind: DispatchKind,
        content: []const u8,
    ) !void {
        // Check under lock — roster can be mutated concurrently by spawn/dismiss.
        // TOCTOU: worker could be dismissed between this check and bus.send;
        // acceptable since bus records delivered=false on failure.
        if (!roster.hasWorker(worker_id)) return error.WorkerNotFound;

        var delivered = true;
        message_bus.send(worker_id, 0, msg_type, content) catch |err| {
            if (err == error.DeliveryFailed) {
                std.log.warn("[teammux] dispatch to worker {d} recorded but delivery failed after retries", .{worker_id});
                delivered = false;
            } else {
                return err;
            }
        };

        try self.recordEvent(worker_id, content, delivered, kind);

        // I7: Propagate delivery failure so callers can surface it
        if (!delivered) return error.DeliveryFailed;
    }

    fn recordEvent(
        self: *Coordinator,
        worker_id: worktree.WorkerId,
        content: []const u8,
        delivered: bool,
        kind: DispatchKind,
    ) !void {
        // Cap at max_history — evict oldest (O(n) shift, n capped at 100)
        if (self.history.items.len >= max_history) {
            self.allocator.free(self.history.items[0].instruction);
            _ = self.history.orderedRemove(0);
        }

        const owned = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(owned);

        try self.history.append(self.allocator, .{
            .target_worker_id = worker_id,
            .instruction = owned,
            .timestamp = @intCast(std.time.timestamp()),
            .delivered = delivered,
            .kind = kind,
        });
    }
};

// ─────────────────────────────────────────────────────────
// PTY death state reconciliation
// ─────────────────────────────────────────────────────────

/// PTY death state reconciliation. Called when a worker's PTY process
/// dies unexpectedly. Marks the worker as errored and releases all
/// ownership entries. Does NOT remove the worktree — preserves the
/// worker's in-progress work for Team Lead inspection.
/// Thread-safe: acquires roster mutex for status mutation.
/// Ownership release is internally mutex-protected.
/// Returns true if worker was found and state updated, false otherwise.
pub fn ptyDiedCallback(
    roster: *worktree.Roster,
    ownership_registry: *ownership.FileOwnershipRegistry,
    worker_id: worktree.WorkerId,
) bool {
    // Acquire roster mutex for thread-safe status mutation.
    // Called from PtyMonitor background thread — must not use getWorker()
    // which returns a raw pointer without lock protection (TD33).
    roster.mutex.lock();
    const w = roster.workers.getPtr(worker_id) orelse {
        roster.mutex.unlock();
        return false;
    };
    w.status = .err;
    w.health_status = .errored;
    roster.mutex.unlock();

    // Release all ownership entries for the dead worker
    // (ownership.release acquires its own mutex internally)
    ownership_registry.release(worker_id);

    // Worktree is intentionally preserved — Team Lead can inspect or salvage work
    return true;
}

// ─────────────────────────────────────────────────────────
// Health monitoring
// ─────────────────────────────────────────────────────────

/// Single pass of health checking: iterate all workers, mark as stalled
/// if last_activity_ts exceeds threshold. Called by the monitor thread
/// and by tests. Does NOT fire bus events — caller is responsible for
/// that (the monitor thread fires TM_MSG_HEALTH_STALLED).
pub fn checkWorkerHealth(roster: *worktree.Roster, stall_threshold_secs: i64) void {
    const now = std.time.timestamp();
    roster.mutex.lock();
    defer roster.mutex.unlock();

    var it = roster.workers.iterator();
    while (it.next()) |entry| {
        const w = entry.value_ptr;
        // Only check active workers (idle or working).
        // Dead workers (status=.err) are skipped — they already have
        // health_status=.errored set by ptyDiedCallback (I12).
        if (w.status != .idle and w.status != .working) continue;
        // Skip already-stalled workers
        if (w.health_status == .stalled) continue;

        if (now - w.last_activity_ts > stall_threshold_secs) {
            w.health_status = .stalled;
        }
    }
}

// ─────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────

pub fn makeTestWorker(alloc: std.mem.Allocator, id: worktree.WorkerId) !worktree.Worker {
    return .{
        .id = id,
        .name = try alloc.dupe(u8, "w"),
        .task_description = try alloc.dupe(u8, "t"),
        .branch_name = try alloc.dupe(u8, "b"),
        .worktree_path = try alloc.dupe(u8, "/tmp/w"),
        .status = .idle,
        .agent_type = .claude_code,
        .agent_binary = try alloc.dupe(u8, "echo"),
        .model = try alloc.dupe(u8, ""),
        .spawned_at = 0,
        .last_activity_ts = std.time.timestamp(),
        .health_status = .healthy,
    };
}

test "coordinator - dispatchTask routes message through bus" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(log_dir);

    var message_bus = try bus.MessageBus.init(alloc, log_dir, "coordtst", log_dir);
    defer message_bus.deinit();

    const State = struct {
        var received: bool = false;
        var received_type: c_int = -1;
        var received_to: u32 = 0;
    };
    State.received = false;
    State.received_type = -1;
    State.received_to = 0;

    const callback = struct {
        fn cb(msg: ?*const bus.CMessage, _: ?*anyopaque) callconv(.c) c_int {
            if (msg) |m| {
                State.received = true;
                State.received_type = m.msg_type;
                State.received_to = m.to;
            }
            return 0;
        }
    }.cb;
    message_bus.subscribe(callback, null);

    var roster = worktree.Roster.init(alloc);
    defer roster.deinit();
    try roster.workers.put(1, try makeTestWorker(alloc, 1));

    var coord = Coordinator.init(alloc);
    defer coord.deinit();

    try coord.dispatchTask(&roster, &message_bus, 1, "implement auth");

    try std.testing.expect(State.received);
    try std.testing.expect(State.received_type == @intFromEnum(bus.MessageType.dispatch));
    try std.testing.expect(State.received_to == 1);
}

test "coordinator - dispatchTask invalid worker returns WorkerNotFound" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(log_dir);

    var message_bus = try bus.MessageBus.init(alloc, log_dir, "coord404", log_dir);
    defer message_bus.deinit();

    var roster = worktree.Roster.init(alloc);
    defer roster.deinit();

    var coord = Coordinator.init(alloc);
    defer coord.deinit();

    try std.testing.expectError(error.WorkerNotFound, coord.dispatchTask(&roster, &message_bus, 99, "nope"));
}

test "coordinator - dispatchResponse routes with response type" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(log_dir);

    var message_bus = try bus.MessageBus.init(alloc, log_dir, "coordrsp", log_dir);
    defer message_bus.deinit();

    const State = struct {
        var received_type: c_int = -1;
    };
    State.received_type = -1;

    const callback = struct {
        fn cb(msg: ?*const bus.CMessage, _: ?*anyopaque) callconv(.c) c_int {
            if (msg) |m| State.received_type = m.msg_type;
            return 0;
        }
    }.cb;
    message_bus.subscribe(callback, null);

    var roster = worktree.Roster.init(alloc);
    defer roster.deinit();
    try roster.workers.put(2, try makeTestWorker(alloc, 2));

    var coord = Coordinator.init(alloc);
    defer coord.deinit();

    try coord.dispatchResponse(&roster, &message_bus, 2, "use JWT tokens");

    try std.testing.expect(State.received_type == @intFromEnum(bus.MessageType.response));
}

test "coordinator - history records events with correct kind" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(log_dir);

    var message_bus = try bus.MessageBus.init(alloc, log_dir, "coordhst", log_dir);
    defer message_bus.deinit();

    var roster = worktree.Roster.init(alloc);
    defer roster.deinit();
    try roster.workers.put(1, try makeTestWorker(alloc, 1));

    var coord = Coordinator.init(alloc);
    defer coord.deinit();

    try coord.dispatchTask(&roster, &message_bus, 1, "first task");
    try coord.dispatchResponse(&roster, &message_bus, 1, "use JWT");

    const history = coord.getHistory();
    try std.testing.expect(history.len == 2);
    try std.testing.expectEqualStrings("first task", history[0].instruction);
    try std.testing.expectEqualStrings("use JWT", history[1].instruction);
    try std.testing.expect(history[0].target_worker_id == 1);
    try std.testing.expect(history[0].delivered == true);
    try std.testing.expect(history[0].timestamp > 0);
    try std.testing.expect(history[0].kind == .task);
    try std.testing.expect(history[1].kind == .response);
}

test "coordinator - history capped at 100" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(log_dir);

    var message_bus = try bus.MessageBus.init(alloc, log_dir, "coordcap", log_dir);
    defer message_bus.deinit();

    var roster = worktree.Roster.init(alloc);
    defer roster.deinit();
    try roster.workers.put(1, try makeTestWorker(alloc, 1));

    var coord = Coordinator.init(alloc);
    defer coord.deinit();

    for (0..101) |i| {
        var buf: [32]u8 = undefined;
        const instruction = try std.fmt.bufPrint(&buf, "task-{d}", .{i});
        try coord.dispatchTask(&roster, &message_bus, 1, instruction);
    }

    const history = coord.getHistory();
    try std.testing.expect(history.len == 100);
    try std.testing.expectEqualStrings("task-1", history[0].instruction);
    try std.testing.expectEqualStrings("task-100", history[99].instruction);
}

test "coordinator - deinit frees all history strings" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(log_dir);

    var message_bus = try bus.MessageBus.init(alloc, log_dir, "coordfre", log_dir);
    defer message_bus.deinit();

    var roster = worktree.Roster.init(alloc);
    defer roster.deinit();
    try roster.workers.put(1, try makeTestWorker(alloc, 1));

    // Scope coordinator to verify no leaks (testing allocator detects)
    var coord = Coordinator.init(alloc);
    try coord.dispatchTask(&roster, &message_bus, 1, "leaked?");
    try coord.dispatchTask(&roster, &message_bus, 1, "also leaked?");
    coord.deinit();
    // If deinit fails to free, testing allocator will panic with leak report
}

test "coordinator - delivery failure returns DeliveryFailed and records event (I7)" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(log_dir);

    var message_bus = try bus.MessageBus.init(alloc, log_dir, "coordfai", log_dir);
    defer message_bus.deinit();
    message_bus.retry_delays_ns = .{ 0, 0, 0 }; // no sleep in tests

    const callback = struct {
        fn cb(_: ?*const bus.CMessage, _: ?*anyopaque) callconv(.c) c_int {
            return 8; // always fail
        }
    }.cb;
    message_bus.subscribe(callback, null);

    var roster = worktree.Roster.init(alloc);
    defer roster.deinit();
    try roster.workers.put(1, try makeTestWorker(alloc, 1));

    var coord = Coordinator.init(alloc);
    defer coord.deinit();

    // I7: DeliveryFailed is now propagated to caller
    try std.testing.expectError(error.DeliveryFailed, coord.dispatchTask(&roster, &message_bus, 1, "will fail delivery"));

    // Event still recorded with delivered=false
    const history = coord.getHistory();
    try std.testing.expect(history.len == 1);
    try std.testing.expect(history[0].delivered == false);
    try std.testing.expectEqualStrings("will fail delivery", history[0].instruction);
}

test "coordinator - dispatchResponse delivery failure returns DeliveryFailed (I7)" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(log_dir);

    var message_bus = try bus.MessageBus.init(alloc, log_dir, "cordrspf", log_dir);
    defer message_bus.deinit();
    message_bus.retry_delays_ns = .{ 0, 0, 0 }; // no sleep in tests

    const callback = struct {
        fn cb(_: ?*const bus.CMessage, _: ?*anyopaque) callconv(.c) c_int {
            return 8; // always fail
        }
    }.cb;
    message_bus.subscribe(callback, null);

    var roster = worktree.Roster.init(alloc);
    defer roster.deinit();
    try roster.workers.put(2, try makeTestWorker(alloc, 2));

    var coord = Coordinator.init(alloc);
    defer coord.deinit();

    // I7: DeliveryFailed propagated from dispatchResponse too
    try std.testing.expectError(error.DeliveryFailed, coord.dispatchResponse(&roster, &message_bus, 2, "answer will fail"));

    // Event still recorded with delivered=false and response kind
    const history = coord.getHistory();
    try std.testing.expect(history.len == 1);
    try std.testing.expect(history[0].delivered == false);
    try std.testing.expect(history[0].kind == .response);
    try std.testing.expectEqualStrings("answer will fail", history[0].instruction);
}

test "ptyDiedCallback marks worker errored and releases ownership" {
    const alloc = std.testing.allocator;

    var roster = worktree.Roster.init(alloc);
    defer roster.deinit();
    try roster.workers.put(1, try makeTestWorker(alloc, 1));

    var ownership_reg = ownership.FileOwnershipRegistry.init(alloc);
    defer ownership_reg.deinit();
    try ownership_reg.register(1, "src/**/*.zig", true);

    // Preconditions: worker idle, ownership registered
    try std.testing.expect(roster.getWorker(1).?.status == .idle);
    try std.testing.expect(ownership_reg.rules.contains(1));

    // Fire ptyDiedCallback
    const result = ptyDiedCallback(&roster, &ownership_reg, 1);
    try std.testing.expect(result);

    // Worker marked errored (both status and health_status — I12)
    try std.testing.expect(roster.getWorker(1).?.status == .err);
    try std.testing.expect(roster.getWorker(1).?.health_status == .errored);
    // Ownership released
    try std.testing.expect(!ownership_reg.rules.contains(1));
}

test "ptyDiedCallback returns false for missing worker" {
    const alloc = std.testing.allocator;

    var roster = worktree.Roster.init(alloc);
    defer roster.deinit();

    var ownership_reg = ownership.FileOwnershipRegistry.init(alloc);
    defer ownership_reg.deinit();

    const result = ptyDiedCallback(&roster, &ownership_reg, 99);
    try std.testing.expect(!result);
}

test "ptyDiedCallback is idempotent" {
    const alloc = std.testing.allocator;

    var roster = worktree.Roster.init(alloc);
    defer roster.deinit();
    try roster.workers.put(1, try makeTestWorker(alloc, 1));

    var ownership_reg = ownership.FileOwnershipRegistry.init(alloc);
    defer ownership_reg.deinit();

    // Call twice — should be safe
    const r1 = ptyDiedCallback(&roster, &ownership_reg, 1);
    const r2 = ptyDiedCallback(&roster, &ownership_reg, 1);
    try std.testing.expect(r1);
    try std.testing.expect(r2);
    try std.testing.expect(roster.getWorker(1).?.status == .err);
    try std.testing.expect(roster.getWorker(1).?.health_status == .errored);
}

test "ptyDiedCallback preserves worker in roster (does not dismiss)" {
    const alloc = std.testing.allocator;

    var roster = worktree.Roster.init(alloc);
    defer roster.deinit();
    try roster.workers.put(1, try makeTestWorker(alloc, 1));

    var ownership_reg = ownership.FileOwnershipRegistry.init(alloc);
    defer ownership_reg.deinit();

    _ = ptyDiedCallback(&roster, &ownership_reg, 1);

    // Worker should still be in roster (errored but not dismissed)
    try std.testing.expect(roster.getWorker(1) != null);
    try std.testing.expect(roster.count() == 1);
}

test "health monitor - detects stalled worker" {
    const alloc = std.testing.allocator;

    var roster = worktree.Roster.init(alloc);
    defer roster.deinit();

    const worker = try makeTestWorker(alloc, 1);
    try roster.workers.put(1, worker);

    // Set last_activity_ts to 400 seconds ago (threshold is 300)
    {
        roster.mutex.lock();
        defer roster.mutex.unlock();
        if (roster.workers.getPtr(1)) |w| {
            w.last_activity_ts = std.time.timestamp() - 400;
        }
    }

    // Run a single health check pass
    checkWorkerHealth(&roster, 300);

    // Verify worker is now stalled
    {
        roster.mutex.lock();
        defer roster.mutex.unlock();
        const w = roster.workers.getPtr(1).?;
        try std.testing.expect(w.health_status == .stalled);
    }
}

test "health monitor - healthy worker not stalled" {
    const alloc = std.testing.allocator;

    var roster = worktree.Roster.init(alloc);
    defer roster.deinit();

    const worker = try makeTestWorker(alloc, 1);
    try roster.workers.put(1, worker);

    // Worker was just active (default from makeTestWorker)
    checkWorkerHealth(&roster, 300);

    // Verify worker is still healthy
    {
        roster.mutex.lock();
        defer roster.mutex.unlock();
        const w = roster.workers.getPtr(1).?;
        try std.testing.expect(w.health_status == .healthy);
    }
}

test "health monitor - stalled worker resets on activity" {
    const alloc = std.testing.allocator;

    var roster = worktree.Roster.init(alloc);
    defer roster.deinit();

    const worker = try makeTestWorker(alloc, 1);
    try roster.workers.put(1, worker);

    // Stall the worker
    {
        roster.mutex.lock();
        defer roster.mutex.unlock();
        if (roster.workers.getPtr(1)) |w| {
            w.last_activity_ts = std.time.timestamp() - 400;
        }
    }
    checkWorkerHealth(&roster, 300);

    // Simulate activity — update timestamp and reset health
    {
        roster.mutex.lock();
        defer roster.mutex.unlock();
        if (roster.workers.getPtr(1)) |w| {
            w.last_activity_ts = std.time.timestamp();
            w.health_status = .healthy;
        }
    }

    checkWorkerHealth(&roster, 300);

    {
        roster.mutex.lock();
        defer roster.mutex.unlock();
        const w = roster.workers.getPtr(1).?;
        try std.testing.expect(w.health_status == .healthy);
    }
}

test "health monitor - restart resets stalled worker" {
    const alloc = std.testing.allocator;

    var roster = worktree.Roster.init(alloc);
    defer roster.deinit();

    const worker = try makeTestWorker(alloc, 1);
    try roster.workers.put(1, worker);

    // Stall the worker
    {
        roster.mutex.lock();
        defer roster.mutex.unlock();
        if (roster.workers.getPtr(1)) |w| {
            w.last_activity_ts = std.time.timestamp() - 400;
        }
    }
    checkWorkerHealth(&roster, 300);

    // Verify stalled
    {
        roster.mutex.lock();
        defer roster.mutex.unlock();
        const w = roster.workers.getPtr(1).?;
        try std.testing.expect(w.health_status == .stalled);
    }

    // Simulate restart (same logic as tm_worker_restart)
    {
        roster.mutex.lock();
        defer roster.mutex.unlock();
        if (roster.workers.getPtr(1)) |w| {
            w.health_status = .healthy;
            w.last_activity_ts = std.time.timestamp();
        }
    }

    // Re-check — should stay healthy
    checkWorkerHealth(&roster, 300);
    {
        roster.mutex.lock();
        defer roster.mutex.unlock();
        const w = roster.workers.getPtr(1).?;
        try std.testing.expect(w.health_status == .healthy);
    }
}

test "health monitor - skips completed workers" {
    const alloc = std.testing.allocator;

    var roster = worktree.Roster.init(alloc);
    defer roster.deinit();

    var worker = try makeTestWorker(alloc, 1);
    worker.status = .complete;
    worker.last_activity_ts = std.time.timestamp() - 400;
    try roster.workers.put(1, worker);

    // Completed worker should NOT be stalled even with old timestamp
    checkWorkerHealth(&roster, 300);

    {
        roster.mutex.lock();
        defer roster.mutex.unlock();
        const w = roster.workers.getPtr(1).?;
        try std.testing.expect(w.health_status == .healthy);
    }
}

test "health monitor - skips errored (dead PTY) workers (I12)" {
    const alloc = std.testing.allocator;

    var roster = worktree.Roster.init(alloc);
    defer roster.deinit();

    var worker = try makeTestWorker(alloc, 1);
    worker.status = .err;
    worker.health_status = .errored;
    worker.last_activity_ts = std.time.timestamp() - 400;
    try roster.workers.put(1, worker);

    // Dead worker should NOT be marked stalled — it is already errored
    checkWorkerHealth(&roster, 300);

    {
        roster.mutex.lock();
        defer roster.mutex.unlock();
        const w = roster.workers.getPtr(1).?;
        try std.testing.expect(w.health_status == .errored);
        try std.testing.expect(w.status == .err);
    }
}
