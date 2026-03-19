## [CRITICAL] Worker spawn creates two independent worktrees and two branch identities

**File:** engine/src/main.zig:383
**Pattern:** registry / coupling
**Description:** `tm_worker_spawn` first creates a worker through `Roster.spawn`, which already runs `git worktree add` and stores a path/branch in the roster. It then immediately calls `worktree_lifecycle.create`, which runs a second `git worktree add` with a different path and branch naming scheme. Swift then mixes both sources: terminals come from `tm_worker_get` / roster state, while `tm_worktree_path` / `tm_worktree_branch` populate `workerWorktrees`, `workerBranches`, the Context tab, and session snapshots. One logical worker therefore ends up with split-brain filesystem and branch state.
**Evidence:**
```zig
engine/src/worktree.zig:71   const wt_path = try std.fmt.allocPrint(..., "{s}/.teammux/worker-{s}", ...)
engine/src/worktree.zig:83   try runGit(self.allocator, project_root, &.{ "worktree", "add", wt_path, "-b", branch });
engine/src/main.zig:387      const id = e.roster.spawn(...)
engine/src/main.zig:393      worktree_lifecycle.create(&e.wt_registry, e.cfgPtr(), e.project_root, id, td) catch |err| {
engine/src/worktree_lifecycle.zig:156 const wt_path = try std.fmt.allocPrint(allocator, "{s}/{d}", .{ root, worker_id });
engine/src/worktree_lifecycle.zig:173 worktree.runGit(allocator, project_path, &.{ "worktree", "add", wt_path, "-b", branch }) catch |err| {
```
**Recommendation:** Collapse worker worktree ownership to a single subsystem. Either make `worktree_lifecycle` the only worktree creator and have the roster reference it, or remove `wt_registry` and derive every Swift/UI API from the roster's one path/branch record.

## [CRITICAL] Team Lead is not structurally prevented from writing code or pushing to main

**File:** macos/Sources/Teammux/RightPane/TeamLeadTerminalView.swift:116
**Pattern:** Team Lead constraint
**Description:** The Team Lead terminal runs plain `claude` in the project root, not in a restricted worktree and without PATH injection for the git wrapper. Separately, the ownership registry defaults to allow when a worker has no rules, and the interceptor API only installs wrappers for roster workers. That means worker `0` is unrestricted by default. The architecture therefore violates the product-level invariant that the Team Lead is structurally prevented from writing code.
**Evidence:**
```swift
macos/Sources/Teammux/RightPane/TeamLeadTerminalView.swift:116 var config = Ghostty.SurfaceConfiguration()
macos/Sources/Teammux/RightPane/TeamLeadTerminalView.swift:117 config.command = "claude"
macos/Sources/Teammux/RightPane/TeamLeadTerminalView.swift:119 config.workingDirectory = root
engine/src/ownership.zig:83  /// 1. No rules for worker → true (default allow, no role = unrestricted)
engine/src/ownership.zig:91  const worker_rules = self.rules.get(worker_id) orelse return true;
engine/src/main.zig:1998     const w = e.roster.getWorker(worker_id) orelse {
```
**Recommendation:** Give the Team Lead its own enforced execution path: dedicated read-only or message-only worktree, mandatory git-wrapper/PATH injection, and engine-side rejection of write-capability and push-to-main operations for worker `0`.

## [IMPORTANT] Hot-reload can invalidate ownership slices while interceptor installation is reading them

**File:** engine/src/main.zig:2003
**Pattern:** concurrency / registry
**Description:** `tm_interceptor_install` borrows the slice returned by `FileOwnershipRegistry.getRules()` and iterates it after the mutex is released. The registry explicitly warns that this slice is invalidated by concurrent rule mutation, and role hot-reload mutates the same worker's rules from its watcher thread through `updateWorkerRules`. The safety comment in `tm_interceptor_install` is therefore false in the presence of hot-reload, creating a stale-pointer / use-after-free window during wrapper rebuilds.
**Evidence:**
```zig
engine/src/ownership.zig:115 /// WARNING: The returned slice is invalidated by concurrent register()
engine/src/ownership.zig:118 pub fn getRules(self: *FileOwnershipRegistry, worker_id: WorkerId) ?[]const PathRule {
engine/src/main.zig:2004     const rules = e.ownership_registry.getRules(worker_id);
engine/src/main.zig:2016     // NOTE: These are pointers into registry-owned memory. Safe because
engine/src/main.zig:2017     // all C API calls are dispatched from the main thread
engine/src/hotreload.zig:228 registry.updateWorkerRules(self.worker_id, role_def.write_patterns, role_def.deny_write_patterns) catch |err| {
```
**Recommendation:** Add a snapshot API that copies rules under the registry lock before use, or hold the lock through the copy into local arrays. Do not iterate registry-owned slices outside the mutex.

## [IMPORTANT] Engine-handled `/teammux-*` commands fail silently and still consume the command file

**File:** engine/src/main.zig:632
**Pattern:** routing
**Description:** `/teammux-assign`, `/teammux-ask`, `/teammux-delegate`, and `/teammux-pr-ready` are intercepted inside the engine before Swift sees them. On missing fields, invalid worker IDs, missing bus state, or similar failures, these handlers mostly just log and return. `commands.zig` then deletes the JSON command file after the callback returns. The Team Lead therefore gets no `TM_MSG_ERROR`, no Swift-visible failure, and no retained artifact for retry or inspection.
**Evidence:**
```zig
engine/src/main.zig:643  if (std.mem.eql(u8, cmd, "/teammux-assign")) { handleAssignCommand(engine, args_ptr); return; }
engine/src/main.zig:739  std.log.warn("[teammux] /teammux-ask: sender worker {d} not found in roster", .{from_id});
engine/src/main.zig:755  std.log.warn("[teammux] /teammux-ask: message bus not available", .{});
engine/src/commands.zig:186 if (self.callback) |cb| {
engine/src/commands.zig:188     cb(parsed.command.ptr, parsed.args.ptr, self.userdata);
engine/src/commands.zig:192 dir.deleteFile(filename) catch |err| {
```
**Recommendation:** Make command handlers return structured success/failure, emit `TM_MSG_ERROR` or a Swift callback on failure, and only delete the command file once the handler reports success.

## [IMPORTANT] Dispatch APIs report success even after bus delivery has failed

**File:** engine/src/coordinator.zig:46
**Pattern:** routing
**Description:** `Coordinator.dispatchTask` and `dispatchResponse` intentionally swallow `error.DeliveryFailed`, record `delivered=false`, and still return success. Swift then treats the dispatch as successful and logs "dispatched". Programmatic callers, including autonomous dispatch, cannot distinguish accepted-but-undelivered instructions from actual delivery unless they separately inspect dispatch history.
**Evidence:**
```zig
engine/src/coordinator.zig:48 /// If bus delivery fails, the event is still recorded with delivered=false
engine/src/coordinator.zig:49 /// and the function returns success in this case
engine/src/coordinator.zig:90 message_bus.send(worker_id, 0, msg_type, content) catch |err| {
engine/src/coordinator.zig:91     if (err == error.DeliveryFailed) {
macos/Sources/Teammux/Engine/EngineClient.swift:1815 guard result == TM_OK else {
macos/Sources/Teammux/Engine/EngineClient.swift:1823 Self.logger.info("dispatchTask: dispatched to worker \(workerId)")
```
**Recommendation:** Return a distinct status for accepted-but-undelivered dispatches, or surface the `delivered` bit synchronously to Swift so callers can fail fast instead of discovering the problem later in history UI.

## [IMPORTANT] Unexpected PTY death has no cleanup or state-reconciliation path

**File:** engine/src/pty.zig:6
**Pattern:** PTY lifecycle
**Description:** The engine explicitly does not own PTY lifecycle, but the Swift worker terminal layer only creates a `Ghostty.SurfaceView` and registers a weak injector closure. There is no exit or teardown callback from the terminal back into the engine. If a worker process or terminal dies unexpectedly, the worker remains in roster/worktree/ownership/watch state until manual dismissal, and later injections just warn and drop text. PTY teardown is therefore not symmetric with spawn.
**Evidence:**
```zig
engine/src/pty.zig:6   // Architecture decision: The Zig engine does NOT own PTY lifecycle.
engine/src/pty.zig:9   // Text injection to worker terminals happens via tm_message_cb callback to Swift
macos/Sources/Teammux/Workspace/WorkerTerminalView.swift:82 let surfaceView = Ghostty.SurfaceView(app, baseConfig: config)
macos/Sources/Teammux/Workspace/WorkerTerminalView.swift:84 engine.registerSurface(surfaceView, for: workerId) { [weak surfaceView] text in
macos/Sources/Teammux/Engine/EngineClient.swift:1684 guard let injector = textInjectors[workerId] else {
macos/Sources/Teammux/Engine/EngineClient.swift:1685     Self.logger.warning("injectText: no injector registered for worker \(workerId)")
```
**Recommendation:** Add a terminal/session exit callback from Ghostty into `EngineClient`, unregister surfaces on view teardown, and introduce an engine path to mark the worker errored or dismiss it when its PTY disappears unexpectedly.

## Domain Summary

The engine import graph is mostly acyclic outside the top-level hub, but `main.zig` has become a systems-integration god object: worker lifecycle, worktree lifecycle, command routing, PR routing, ownership, interceptor installation, hot-reload, and history are all coordinated there. The most damaging consequence is duplicated sources of truth, especially around worker worktrees and Team Lead enforcement. Message-type coverage is otherwise broadly coherent: Swift safely copies callback data and dispatches `@Published` mutations onto `@MainActor`, and the audited model types are consistently `Sendable`. The main architectural gaps are structural invariants not actually enforced at runtime, lifecycle signals that stop at logging, and background threads mutating state that nearby code still assumes is single-threaded.
