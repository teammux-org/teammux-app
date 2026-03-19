## [CRITICAL] Command watcher stores a freed commands directory path

**File:** engine/src/main.zig:148, engine/src/commands.zig:31
**Pattern:** watcher reliability
**Description:** `sessionStart()` allocates `cmd_dir`, passes the slice into `CommandWatcher.init()`, and then frees it before the watcher is ever started. `CommandWatcher` stores that borrowed slice directly and later uses it in `start()` and `scanAndProcess()`. Once `tm_commands_watch()` runs from Swift callback setup, the watcher dereferences freed memory, which can crash, watch the wrong path, or fail nondeterministically.
**Evidence:**
```zig
const cmd_dir = try std.fmt.allocPrint(self.allocator, "{s}/.teammux/commands", .{self.project_root});
defer self.allocator.free(cmd_dir);
self.commands_watcher = commands.CommandWatcher.init(self.allocator, cmd_dir) catch |err| {
    self.setError("commands watcher init failed") catch {};
    return err;
};

pub fn init(allocator: std.mem.Allocator, commands_dir: []const u8) !CommandWatcher {
    return .{ .allocator = allocator, .commands_dir = commands_dir, ... };
}
```
**Recommendation:** Make `CommandWatcher` own a duped `commands_dir` string and free it in `deinit()`, or move the path storage to an engine-owned field that outlives the watcher.

## [IMPORTANT] sessionStart leaks partial engine state on initialization failure

**File:** engine/src/main.zig:127
**Pattern:** degraded state
**Description:** `sessionStart()` commits subsystem state directly onto `Engine` as it goes. If a later step fails, earlier state is left attached to the engine with no rollback. A retry on the same engine can overwrite `cfg`, `message_bus`, `commands_watcher`, or `history_logger` without deinitializing the previous values first, and even a single failed start leaves the engine in a partially initialized state until full destroy.
**Evidence:**
```zig
self.cfg = config.loadWithOverrides(...) catch |err| { ...; return err; };
self.message_bus = bus.MessageBus.init(...) catch |err| { ...; return err; };
self.commands_watcher = commands.CommandWatcher.init(...) catch |err| { ...; return err; };
self.history_logger = history_mod.HistoryLogger.init(...) catch |err| {
    self.setError("history logger init failed") catch {};
    return err;
};
```
**Recommendation:** Stage startup resources in locals with `errdefer` rollback, then assign to `self` only after the full startup path succeeds.

## [IMPORTANT] last_error is mutated from background threads without synchronization

**File:** engine/src/main.zig:154, engine/src/main.zig:173, engine/src/main.zig:232, macos/Sources/Teammux/Engine/EngineClient.swift:1694
**Pattern:** lastError
**Description:** The engine wires command-watcher and GitHub polling paths to `busSendBridge()`, and that bridge calls `setError()`. Those paths run on background threads, while Swift reads `tm_engine_last_error()` on `@MainActor`. `setError()` frees and replaces `last_error` without any lock, so background error writes can race with foreground reads and with `last_error_cstr` regeneration, producing stale, torn, or use-after-free-prone error state.
**Evidence:**
```zig
w.bus_send_fn = busSendBridge;
w.bus_send_userdata = self;
b.send(to, from, msg_enum, payload_span) catch |err| {
    self.setError(...) catch {};
    return 8;
};
fn setError(self: *Engine, msg: []const u8) !void {
    if (self.last_error) |old| self.allocator.free(old);
    self.last_error = try self.allocator.dupe(u8, msg);
}
```
**Recommendation:** Guard `last_error` and `last_error_cstr` behind a mutex or move to per-call owned error returns so background watcher threads never mutate shared error buffers directly.

## [IMPORTANT] Worktree cleanup forgets orphaned paths before git removal succeeds

**File:** engine/src/worktree_lifecycle.zig:203
**Pattern:** crash recovery
**Description:** `removeWorker()` drops the registry entry before `git worktree remove --force` has succeeded. If git removal fails, or the app crashes after the registry mutation but before the git command completes, the engine has already forgotten the path and branch. Because there is no startup recovery sweep in this shipped code path, the orphaned worktree and branch are left behind with no automatic cleanup.
**Evidence:**
```zig
const kv = registry.entries.fetchRemove(worker_id) orelse return;
const entry = kv.value;

worktree.runGit(registry.allocator, project_path, &.{ "worktree", "remove", "--force", entry.path }) catch |err| {
    std.log.warn("[teammux] lifecycle worktree remove failed for worker {d}: {}", .{ worker_id, err });
};
```
**Recommendation:** Keep registry metadata until git removal succeeds, or persist a pending-cleanup record and sweep abandoned worktrees/branches on next launch.

## [IMPORTANT] Merge cleanup drops git failures silently

**File:** engine/src/merge.zig:136, engine/src/merge.zig:243, engine/src/merge.zig:431
**Pattern:** silent failure
**Description:** After approve and reject flows, merge cleanup uses `runGitIgnoreResult()` for worktree removal and branch deletion. That helper discards allocation failures, spawn failures, exit codes, and stderr with no logging and no state rollback. The merge can be reported as `success` or `rejected` while cleanup silently leaves the worktree or branch behind.
**Evidence:**
```zig
runGitIgnoreResult(self.allocator, project_root, &.{ "worktree", "remove", "--force", wt_path });
runGitIgnoreResult(self.allocator, project_root, &.{ "branch", "-D", branch_name });

fn runGitIgnoreResult(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) void {
    ...
    _ = child.spawnAndWait() catch return;
}
```
**Recommendation:** Log cleanup failures and surface them to the caller, or track cleanup as pending work instead of silently discarding the result.

## [IMPORTANT] PR_READY and PR_STATUS delivery failures only log warnings

**File:** engine/src/main.zig:870, engine/src/main.zig:880, engine/src/github.zig:358
**Pattern:** silent failure
**Description:** PR creation and PR status routing treat bus delivery as best-effort. In the `/teammux-pr-ready` command path, `tm_github_create_pr()` may succeed on GitHub, but if `routePrReady()` cannot allocate or the bus send fails, the handler just frees the returned PR and the UI never learns about it. Polling-driven PR status events have the same problem: failures are logged and dropped, with no retry queue and no caller notification.
**Evidence:**
```zig
const result = tm_github_create_pr(engine, worker_id, title_z.ptr, summary_z.ptr);
if (result) |pr| {
    tm_pr_free(pr);
} else {
    std.log.warn("[teammux] /teammux-pr-ready: PR creation failed for worker {d}", .{worker_id});
}

b.send(0, worker_id, .pr_ready, payload) catch |err| {
    std.log.warn("[teammux] TM_MSG_PR_READY bus send failed: {s}", .{@errorName(err)});
};
```
**Recommendation:** Return a failure to the command path when PR event routing fails, or persist/retry pending PR events until the Team Lead UI has acknowledged them.

## [SUGGESTION] Swift helper paths can preserve stale lastError despite the 20 cleared API wrappers

**File:** macos/Sources/Teammux/Engine/EngineClient.swift:527, macos/Sources/Teammux/Engine/EngineClient.swift:998, macos/Sources/Teammux/Engine/EngineClient.swift:1962
**Pattern:** lastError
**Description:** The audit target of 20 public wrapper methods with `lastError = nil` at entry is satisfied, but several helper paths do not clear it. `restoreSession()` only writes `lastError` on partial failure and leaves old errors visible on success; `loadAvailableRoles()` and `loadCompletionHistory()` call `lastEngineError()` after nullable C APIs without clearing previous UI error state first. This keeps stale errors alive even after later successful helper operations.
**Evidence:**
```swift
func restoreSession(_ snapshot: SessionSnapshot) -> Int {
    let fm = FileManager.default
    var skippedWorkers: [String] = []
    ...
    if !skippedWorkers.isEmpty {
        lastError = "Skipped workers with missing worktrees: \(names)"
    }
}
```
**Recommendation:** Clear `lastError` at entry for user-visible helper flows, or separate transient UI errors from diagnostic logging-only paths.

## Domain Summary

The strongest reliability problems are ownership and lifecycle bugs, not simple missing logs. The command watcher currently has a concrete use-after-free path, startup uses incremental mutation instead of staged commit, and cleanup code frequently treats Git-side failures as best-effort even when that leaves disk state diverged from engine state. I also verified the Swift-side `EngineClient` wrapper count requested by the audit: there are 20 `lastError = nil` entry clears in the public engine-call wrappers, but helper and callback paths still allow stale `lastError` state to persist.

Outside the findings above, a few targeted checks came back better than expected:
- `SessionState.save()` uses `Data.write(..., options: .atomic)`, so a failed save should leave the old session file intact rather than half-written.
- `HistoryLogger.load()` skips malformed JSONL lines with warnings instead of crashing, so corrupt `completion_history.jsonl` degrades to partial history rather than total failure.
- Missing `gh` is handled gracefully for webhook monitoring by falling back to polling, and `tm_github_create_pr()` fails with an error instead of crashing, though the current message is generic.
