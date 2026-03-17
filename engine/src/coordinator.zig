const std = @import("std");
const worktree = @import("worktree.zig");
const bus = @import("bus.zig");

// ─────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────

pub const max_history: usize = 100;

pub const DispatchEvent = struct {
    target_worker_id: worktree.WorkerId,
    instruction: []const u8, // heap-allocated, owned
    timestamp: u64,
    delivered: bool,
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
    /// If bus delivery fails, the event is still recorded with delivered=false.
    pub fn dispatchTask(
        self: *Coordinator,
        roster: *worktree.Roster,
        message_bus: *bus.MessageBus,
        worker_id: worktree.WorkerId,
        instruction: []const u8,
    ) !void {
        // Validate worker exists
        if (roster.getWorker(worker_id) == null) return error.WorkerNotFound;

        // Route through bus
        var delivered = true;
        message_bus.send(worker_id, 0, .dispatch, instruction) catch |err| {
            if (err == error.DeliveryFailed) {
                delivered = false;
            } else {
                return err;
            }
        };

        // Record in history
        try self.recordEvent(worker_id, instruction, delivered);
    }

    /// Dispatch a response to a specific worker (e.g. answering a question).
    /// Same flow as dispatchTask but with .response message type.
    pub fn dispatchResponse(
        self: *Coordinator,
        roster: *worktree.Roster,
        message_bus: *bus.MessageBus,
        worker_id: worktree.WorkerId,
        response: []const u8,
    ) !void {
        if (roster.getWorker(worker_id) == null) return error.WorkerNotFound;

        var delivered = true;
        message_bus.send(worker_id, 0, .response, response) catch |err| {
            if (err == error.DeliveryFailed) {
                delivered = false;
            } else {
                return err;
            }
        };

        try self.recordEvent(worker_id, response, delivered);
    }

    /// Get read-only view of dispatch history.
    pub fn getHistory(self: *const Coordinator) []const DispatchEvent {
        return self.history.items;
    }

    fn recordEvent(
        self: *Coordinator,
        worker_id: worktree.WorkerId,
        instruction: []const u8,
        delivered: bool,
    ) !void {
        // Cap at max_history — evict oldest
        if (self.history.items.len >= max_history) {
            self.allocator.free(self.history.items[0].instruction);
            _ = self.history.orderedRemove(0);
        }

        const owned_instruction = try self.allocator.dupe(u8, instruction);
        errdefer self.allocator.free(owned_instruction);

        try self.history.append(self.allocator, .{
            .target_worker_id = worker_id,
            .instruction = owned_instruction,
            .timestamp = @intCast(std.time.timestamp()),
            .delivered = delivered,
        });
    }

    pub const WorkerNotFound = error{WorkerNotFound};
};

// ─────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────

test "coordinator - dispatchTask routes message through bus" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(log_dir);

    var message_bus = try bus.MessageBus.init(alloc, log_dir, "coordtst", log_dir);
    defer message_bus.deinit();

    // Track callback invocations
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
            return 0; // TM_OK
        }
    }.cb;
    message_bus.subscribe(callback, null);

    // Set up roster with one worker
    var roster = worktree.Roster.init(alloc);
    defer roster.deinit();
    try roster.workers.put(1, .{
        .id = 1,
        .name = try alloc.dupe(u8, "alice"),
        .task_description = try alloc.dupe(u8, "task"),
        .branch_name = try alloc.dupe(u8, "branch"),
        .worktree_path = try alloc.dupe(u8, "/tmp/w1"),
        .status = .idle,
        .agent_type = .claude_code,
        .agent_binary = try alloc.dupe(u8, "echo"),
        .model = try alloc.dupe(u8, ""),
        .spawned_at = 0,
    });

    var coord = Coordinator.init(alloc);
    defer coord.deinit();

    try coord.dispatchTask(&roster, &message_bus, 1, "implement auth");

    try std.testing.expect(State.received);
    try std.testing.expect(State.received_type == 10); // dispatch
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
    try roster.workers.put(2, .{
        .id = 2,
        .name = try alloc.dupe(u8, "bob"),
        .task_description = try alloc.dupe(u8, "task"),
        .branch_name = try alloc.dupe(u8, "branch"),
        .worktree_path = try alloc.dupe(u8, "/tmp/w2"),
        .status = .idle,
        .agent_type = .claude_code,
        .agent_binary = try alloc.dupe(u8, "echo"),
        .model = try alloc.dupe(u8, ""),
        .spawned_at = 0,
    });

    var coord = Coordinator.init(alloc);
    defer coord.deinit();

    try coord.dispatchResponse(&roster, &message_bus, 2, "use JWT tokens");

    try std.testing.expect(State.received_type == 11); // response
}

test "coordinator - history records events correctly" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(log_dir);

    var message_bus = try bus.MessageBus.init(alloc, log_dir, "coordhst", log_dir);
    defer message_bus.deinit();

    var roster = worktree.Roster.init(alloc);
    defer roster.deinit();
    try roster.workers.put(1, .{
        .id = 1,
        .name = try alloc.dupe(u8, "w"),
        .task_description = try alloc.dupe(u8, "t"),
        .branch_name = try alloc.dupe(u8, "b"),
        .worktree_path = try alloc.dupe(u8, "/tmp/w"),
        .status = .idle,
        .agent_type = .claude_code,
        .agent_binary = try alloc.dupe(u8, "echo"),
        .model = try alloc.dupe(u8, ""),
        .spawned_at = 0,
    });

    var coord = Coordinator.init(alloc);
    defer coord.deinit();

    try coord.dispatchTask(&roster, &message_bus, 1, "first task");
    try coord.dispatchTask(&roster, &message_bus, 1, "second task");

    const history = coord.getHistory();
    try std.testing.expect(history.len == 2);
    try std.testing.expectEqualStrings("first task", history[0].instruction);
    try std.testing.expectEqualStrings("second task", history[1].instruction);
    try std.testing.expect(history[0].target_worker_id == 1);
    try std.testing.expect(history[0].delivered == true);
    try std.testing.expect(history[0].timestamp > 0);
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
    try roster.workers.put(1, .{
        .id = 1,
        .name = try alloc.dupe(u8, "w"),
        .task_description = try alloc.dupe(u8, "t"),
        .branch_name = try alloc.dupe(u8, "b"),
        .worktree_path = try alloc.dupe(u8, "/tmp/w"),
        .status = .idle,
        .agent_type = .claude_code,
        .agent_binary = try alloc.dupe(u8, "echo"),
        .model = try alloc.dupe(u8, ""),
        .spawned_at = 0,
    });

    var coord = Coordinator.init(alloc);
    defer coord.deinit();

    // Add 101 events
    for (0..101) |i| {
        var buf: [32]u8 = undefined;
        const instruction = try std.fmt.bufPrint(&buf, "task-{d}", .{i});
        try coord.dispatchTask(&roster, &message_bus, 1, instruction);
    }

    const history = coord.getHistory();
    try std.testing.expect(history.len == 100);
    // Oldest event (task-0) should be evicted; first is task-1
    try std.testing.expectEqualStrings("task-1", history[0].instruction);
    // Newest is task-100
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
    try roster.workers.put(1, .{
        .id = 1,
        .name = try alloc.dupe(u8, "w"),
        .task_description = try alloc.dupe(u8, "t"),
        .branch_name = try alloc.dupe(u8, "b"),
        .worktree_path = try alloc.dupe(u8, "/tmp/w"),
        .status = .idle,
        .agent_type = .claude_code,
        .agent_binary = try alloc.dupe(u8, "echo"),
        .model = try alloc.dupe(u8, ""),
        .spawned_at = 0,
    });

    // Scope coordinator to verify no leaks (testing allocator detects)
    var coord = Coordinator.init(alloc);
    try coord.dispatchTask(&roster, &message_bus, 1, "leaked?");
    try coord.dispatchTask(&roster, &message_bus, 1, "also leaked?");
    coord.deinit();
    // If deinit fails to free, testing allocator will panic with leak report
}
