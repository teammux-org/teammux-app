## [IMPORTANT] Message bus send path spawns `git` for every message

**File:** engine/src/bus.zig:120
**Pattern:** hot path alloc
**Impact:** HIGH
**Description:** `MessageBus.send()` runs `git rev-parse HEAD` before logging and delivery on every bus message, not just completion-related events. That means each dispatch, question, delegation, PR event, and broadcast pays for process spawn, stdout allocation, wait, commit-string duplication, JSON log formatting, and a second payload copy for the C callback. This is the hottest engine path in the audit and it is fully synchronous.
**Evidence:**
```zig
const git_commit = self.captureGitCommit();
defer if (git_commit) |c| self.allocator.free(c);
try self.appendLog(msg);
if (self.subscriber_cb) |cb| {
    var c_msg = try self.toCMessage(msg);
```
```zig
var child = std.process.Child.init(
    &.{ "git", "-C", self.project_root, "rev-parse", "HEAD" },
    self.allocator,
);
child.stdout_behavior = .Pipe;
const result = stdout.readToEndAlloc(self.allocator, 256) catch |err| {
```
**Recommendation:** Stop capturing HEAD in `MessageBus.send()`. Cache the current commit once per session/worktree and invalidate it only after commit/merge operations, or record commit metadata only for message types that actually surface it in the UI/audit log.

## [IMPORTANT] Completion/question history append is O(n) and stays on the delivery path

**File:** engine/src/history.zig:114
**Pattern:** O(n) operation
**Impact:** MEDIUM
**Description:** Each history append reads the entire `completion_history.jsonl`, writes old content plus one new line to a temp file, then renames it into place. This is invoked inline from both `busSendBridge()` and the direct C API completion/question paths, so worker completion latency grows with history size. Inference from the code: a typical small v0.1.4 session likely adds only tens of lines, so this is acceptable short-term, but TD24 leaves the file unbounded and the logger hard-limits reads at 10 MB, so the cost ratchets upward across sessions.
**Evidence:**
```zig
const existing = std.fs.cwd().readFileAlloc(self.allocator, self.file_path, max_history_file_bytes) catch |err| switch (err) {
    error.FileNotFound => blk: {
        heap_allocated = false;
        break :blk "";
    },
    else => return err,
};
if (existing.len > 0) try tmp_file.writeAll(existing);
try tmp_file.writeAll(json_line);
try dir.rename("completion_history.jsonl.tmp", "completion_history.jsonl");
```
**Recommendation:** Keep the history file open in append mode and write new lines directly, using rotation/checkpointing for crash resilience instead of full-file rewrite. If atomic rewrite must stay, rotate aggressively before the file grows large and move the work off the message delivery path.

## [IMPORTANT] Completion handling fans out into multiple `@Published` invalidations and a full dispatch-history reload

**File:** macos/Sources/Teammux/Engine/EngineClient.swift:1459
**Pattern:** SwiftUI redraw
**Impact:** MEDIUM
**Description:** A completion message first appends to `messages`, then parses JSON into `workerCompletions`, then immediately triggers autonomous dispatch, which calls `dispatchTask()`, which synchronously reloads the entire dispatch history from the engine, and finally writes `autonomousDispatches`. `LiveFeedView` and `DispatchView` both observe those collections, so one completion can trigger several independent SwiftUI invalidations and a full bridge round-trip for dispatch history.
**Evidence:**
```swift
client.messages.append(msg)
if type == .completion {
    client.handleCompletionMessage(from: from, payload: payload, timestamp: timestamp, gitCommit: gitCommit)
}
```
```swift
workerCompletions[workerId] = report
triggerAutonomousDispatch(for: report)
...
let success = dispatchTask(workerId: completion.workerId, instruction: instruction)
...
dispatchHistory = events
autonomousDispatches[completion.workerId] = dispatch
```
**Recommendation:** Batch completion-side state into a single update on the main actor, append the newly created dispatch event locally instead of calling `refreshDispatchHistory()` after every autonomous dispatch, and only auto-scroll the feed when the feed tab is visible.

## [SUGGESTION] Live feed message storage is unbounded while the UI renders the full array

**File:** macos/Sources/Teammux/RightPane/LiveFeedView.swift:279
**Pattern:** SwiftUI redraw
**Impact:** MEDIUM
**Description:** `EngineClient.messages` is append-only for the life of the session, but `LiveFeedView` renders the whole collection and auto-scrolls on every count change. Other coordination surfaces are capped (`peerDelegations` and `dispatchHistory` both stop at 100), but the main feed is not. Long sessions will therefore grow both memory use and diff work even though the UI only needs the recent window most of the time.
**Evidence:**
```swift
@Published var messages: [TeamMessage] = []
...
client.messages.append(msg)
...
ForEach(engine.messages) { message in
    LiveFeedRow(message: message, engine: engine)
}
```
**Recommendation:** Cap the in-memory feed, or split it into a recent in-memory window plus persisted/archive history. If older messages must remain accessible, page them separately instead of keeping the full session resident in the observed array.

## [SUGGESTION] JSON key scanning allocates short search strings on the heap in common paths

**File:** engine/src/commands.zig:253
**Pattern:** string alloc
**Impact:** LOW
**Description:** The lightweight JSON helpers allocate a temporary `"key"` string on `std.heap.page_allocator` for every lookup. These helpers are used in command parsing, history parsing, and the completion/question history write path (`busSendBridge()` calls `commands.extractJsonString`). Each allocation is small, but they are pure overhead in hot code and easy to remove because the key lengths are tiny and fixed.
**Evidence:**
```zig
const search = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\"", .{key}) catch return null;
defer std.heap.page_allocator.free(search);
const key_pos = std.mem.indexOf(u8, json, search) orelse return null;
```
**Recommendation:** Replace these helpers with stack-buffer versions (`std.fmt.bufPrint`) like `extractJsonStringValue()` / `extractJsonUint64()`, or switch the hot message paths to a minimal token scanner that never allocates for key lookup.

## [SUGGESTION] Role hot-reload always regenerates the interceptor wrapper, even for metadata-only edits

**File:** engine/src/hotreload.zig:236
**Pattern:** interceptor regen
**Impact:** LOW
**Description:** Every role file change reparses the role, updates ownership, resolves the real git binary again, regenerates the full wrapper script, and rewrites it to disk. That is fine for infrequent edits, but it is unnecessary when the edit only changes non-enforcement fields such as role description, mission text, or other CLAUDE.md content.
**Evidence:**
```zig
if (self.worktree_path.len > 0) {
    interceptor.install(
        self.allocator,
        self.worktree_path,
        self.worker_id,
        self.worker_name,
        role_def.deny_write_patterns,
        role_def.write_patterns,
    ) catch |err| {
```
**Recommendation:** Compare the old and new write/deny pattern sets before reinstalling. If the enforcement set is unchanged, skip `interceptor.install()` and only regenerate the worker-facing CLAUDE.md payload.

## Domain Summary

The highest-cost performance issue is the message bus itself: every message synchronously spawns `git`, allocates log/callback payload copies, and then crosses into Swift where common message types are reparsed and often trigger multiple `@Published` mutations. Completion handling amplifies that cost because it also persists history with an O(n) rewrite and, on the Swift side, can force a full dispatch-history refresh immediately after the message lands.

The command watcher is in better shape than expected. It uses `kqueue`, not a sleep-based polling loop, and the idle watcher path does not allocate per iteration; the only steady-state cost there is the one-second `kevent` timeout used to make shutdown responsive. The ownership registry path is also not a current hotspot in the audited message path: `tm_ownership_check()` exists, but current call sites are limited, so its mutex-held linear scan is more of a future scaling concern than an immediate v0.1.4 bottleneck.
