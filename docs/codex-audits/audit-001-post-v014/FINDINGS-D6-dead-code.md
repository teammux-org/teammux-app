## [IMPORTANT] Diff view is wired to a permanently failing engine path

**File:** engine/src/main.zig:617
**Pattern:** unreachable path
**Description:** `DiffView` is live in Swift, but the engine path it calls can never succeed in v0.1.4. `GitHubClient.getDiff()` always returns `error.NotImplemented`, `tm_github_get_diff()` turns that into `NULL`, and the success side ends in `unreachable`. Impact: the diff tab is dead UI today, and a future engine implementation will trap until `tm_github_get_diff()` is updated.
**Evidence:**
```text
engine/src/github.zig:169:    pub fn getDiff(
engine/src/github.zig:179:        return error.NotImplemented;
engine/src/main.zig:617:    unreachable; // getDiff always returns error.NotImplemented in v0.1
macos/Sources/Teammux/Engine/EngineClient.swift:851:        guard let diffPtr = tm_github_get_diff(engine, workerId) else {
macos/Sources/Teammux/RightPane/DiffView.swift:179:            let result = engine.getDiff(for: workerId)
```
**Recommendation:** Either hide or disable the diff UI until the backend exists, or implement the backend and replace the `unreachable` branch with real `tm_diff_t` bridging.

## [IMPORTANT] Stale PTY C API remains in the authoritative contract

**File:** engine/include/teammux.h:264
**Pattern:** dead export
**Description:** The authoritative C contract still advertises `tm_pty_send` and `tm_pty_fd`, but Swift never calls them and the Zig exports are hardcoded nonfunctional because Ghostty owns PTYs. Impact: the header exposes dead, misleading API surface to any future bridge or external client work.
**Evidence:**
```text
engine/include/teammux.h:264:tm_result_t tm_pty_send(tm_engine_t* engine, tm_worker_id_t worker_id, const char* text);
engine/include/teammux.h:268:int         tm_pty_fd(tm_engine_t* engine, tm_worker_id_t worker_id);
engine/src/main.zig:507:export fn tm_pty_send(_: ?*Engine, _: u32, _: ?[*:0]const u8) c_int { return 10; }
engine/src/main.zig:510:export fn tm_pty_fd(_: ?*Engine, _: u32) c_int { return -1; }
rg "tm_pty_(send|fd)" macos/Sources/Teammux/Engine/EngineClient.swift -> no matches
```
**Recommendation:** Remove these declarations and exports, or mark them explicitly as legacy nonfunctional stubs and keep them out of the app bridge.

## [SUGGESTION] Orphaned `worktreeReadyQueue` state and `WorktreeReady` helper

**File:** macos/Sources/Teammux/Engine/EngineClient.swift:38
**Pattern:** dead @Published
**Description:** `WorktreeReady` exists only to feed `worktreeReadyQueue`, and the queue is maintained during spawn, restore, destroy, and dismiss with no consumer anywhere in `macos/`. `WorkerPaneView` renders terminals directly from `engine.roster`, so this published state is dead weight and the queue-fixup code in `restoreSession()` is wasted maintenance.
**Evidence:**
```text
macos/Sources/Teammux/Engine/EngineClient.swift:38:struct WorktreeReady: Identifiable, Equatable, Sendable {
macos/Sources/Teammux/Engine/EngineClient.swift:62:    @Published var worktreeReadyQueue: [WorktreeReady] = []
macos/Sources/Teammux/Engine/EngineClient.swift:393:            worktreeReadyQueue.append(WorktreeReady(
macos/Sources/Teammux/Engine/EngineClient.swift:564:            if let idx = worktreeReadyQueue.firstIndex(where: { $0.id == workerId }) {
macos/Sources/Teammux/Workspace/WorkerPaneView.swift:51:            ForEach(engine.roster) { worker in
```
**Recommendation:** Remove the queue and helper type, or rewire an actual consumer and delete the stale comment claiming `WorkerPaneView` observes it.

## [SUGGESTION] `githubStatus` is published but never observed

**File:** macos/Sources/Teammux/Engine/EngineClient.swift:56
**Pattern:** dead @Published
**Description:** `githubStatus` is mutated during auth and webhook callbacks, but no view or session code reads it. The property is dead observable state; `connectGitHub()` is also unreferenced from Swift, so the EngineClient-specific GitHub status state machine does not affect the app.
**Evidence:**
```text
macos/Sources/Teammux/Engine/EngineClient.swift:56:    @Published var githubStatus: GitHubStatus = .disconnected
macos/Sources/Teammux/Engine/EngineClient.swift:729:    func connectGitHub() -> Bool {
macos/Sources/Teammux/Engine/EngineClient.swift:742:            githubStatus = .error(msg)
macos/Sources/Teammux/Engine/EngineClient.swift:1670:                githubStatus = .connected("engine")
rg "\bgithubStatus\b" macos/Sources/Teammux --glob '*.swift' -> only EngineClient.swift matches
```
**Recommendation:** Remove the property and unused auth-state path, or bind real UI/auth flows to it.

## [SUGGESTION] `statusReq` and `statusRpt` are dead protocol values

**File:** macos/Sources/Teammux/Models/TeamMessage.swift:15
**Pattern:** unreachable path
**Description:** `TM_MSG_STATUS_REQ` and `TM_MSG_STATUS_RPT` exist in the C enum, the Zig bus enum, and Swift `MessageType`, but repo-wide search finds no sender, no callback branch, and no UI flow that can generate them. Impact: dead message protocol surface that adds cases, labels, and colors without a producer.
**Evidence:**
```text
engine/include/teammux.h:60:    TM_MSG_STATUS_REQ  = 3,
engine/include/teammux.h:61:    TM_MSG_STATUS_RPT  = 4,
engine/src/bus.zig:12:    status_req = 3,
engine/src/bus.zig:13:    status_rpt = 4,
macos/Sources/Teammux/Models/TeamMessage.swift:15:    case statusReq    = 3
macos/Sources/Teammux/Models/TeamMessage.swift:16:    case statusRpt    = 4
```
**Recommendation:** Remove the cases, or document them as reserved values and keep them out of the active UI/bridge protocol.

## [SUGGESTION] Completion/question and peer-message C APIs have no Swift bridge caller

**File:** engine/src/main.zig:1090
**Pattern:** dead export
**Description:** `tm_peer_question`, `tm_peer_delegate`, `tm_worker_complete`, `tm_worker_question`, `tm_completion_free`, and `tm_question_free` are exported and declared in `teammux.h`, but `EngineClient.swift` never calls them. The app uses command-file routing (`/teammux-complete`, `/teammux-question`, `/teammux-ask`, `/teammux-delegate`) instead, so these exports are parallel unused surface from the shipped app's perspective.
**Evidence:**
```text
engine/src/main.zig:1090:export fn tm_peer_question(engine: ?*Engine, from_id: u32, target_id: u32, message: ?[*:0]const u8) c_int {
engine/src/main.zig:1142:export fn tm_peer_delegate(engine: ?*Engine, from_id: u32, target_id: u32, task: ?[*:0]const u8) c_int {
engine/src/main.zig:1215:export fn tm_worker_complete(engine: ?*Engine, worker_id: u32, summary: ?[*:0]const u8, details: ?[*:0]const u8) c_int {
engine/src/main.zig:1279:export fn tm_worker_question(engine: ?*Engine, worker_id: u32, question: ?[*:0]const u8, ctx: ?[*:0]const u8) c_int {
engine/src/main.zig:1336:export fn tm_completion_free(completion: ?*CCompletion) void {
engine/src/main.zig:1346:export fn tm_question_free(question: ?*CQuestion) void {
rg "tm_(peer_question|peer_delegate|worker_complete|worker_question|completion_free|question_free)" macos/Sources/Teammux/Engine/EngineClient.swift -> no matches
```
**Recommendation:** Bridge these APIs from Swift if they are intended first-class surface, or document and remove them from the app-facing contract if command-file routing is the only shipped path.

## [SUGGESTION] Ownership, worktree, and utility exports have no Swift bridge caller

**File:** engine/src/main.zig:370
**Pattern:** dead export
**Description:** `tm_config_get`, `tm_worktree_create`, `tm_worktree_remove`, `tm_history_clear`, `tm_ownership_get`, `tm_ownership_free`, `tm_ownership_update`, `tm_interceptor_remove`, `tm_agent_resolve`, `tm_result_to_string`, and the duplicate alias `tm_pr_create` are all exported but unused by `EngineClient.swift`. Impact: the header is materially larger than the bridge actually supports, which obscures the real engine-to-Swift boundary.
**Evidence:**
```text
engine/src/main.zig:370:export fn tm_config_get(engine: ?*Engine, key: ?[*:0]const u8) ?[*:0]const u8 {
engine/src/main.zig:421:export fn tm_worktree_create(engine: ?*Engine, worker_id: u32, task_description: ?[*:0]const u8) c_int {
engine/src/main.zig:1451:export fn tm_history_clear(engine: ?*Engine) c_int {
engine/src/main.zig:1881:export fn tm_ownership_get(engine: ?*Engine, worker_id: u32, count: ?*u32) ?[*]?*COwnershipEntry {
engine/src/main.zig:1936:export fn tm_ownership_update(
engine/src/main.zig:2167:export fn tm_agent_resolve(agent_name: ?[*:0]const u8) ?[*:0]const u8 {
rg "tm_(config_get|worktree_create|worktree_remove|history_clear|ownership_get|ownership_free|ownership_update|interceptor_remove|agent_resolve|result_to_string|pr_create)" macos/Sources/Teammux/Engine/EngineClient.swift -> no matches
```
**Recommendation:** Prune this surface, or explicitly label it as external-only so the app bridge stays aligned with the real API contract.

## [SUGGESTION] Several public Zig helpers only serve their own module and tests

**File:** engine/src/commands.zig:235
**Pattern:** dead zig fn
**Description:** Representative helpers `parseCommandJson`, `parseRoleContent`, `readGhCliToken`, `resolveGitBinary`, `parseConflictMarkers`, `globMatch`, `makeBranch`, `slugifyTask`, `resolveWorktreeRoot`, and `hashProjectPath` are `pub fn` even though repo-wide references stay inside their defining module, plus same-file tests. In Zig, same-file tests can call private functions, so this public visibility is unnecessary surface area.
**Evidence:**
```text
engine/src/commands.zig:152:        const parsed = parseCommandJson(self.allocator, content) catch |err| {
engine/src/commands.zig:235:pub fn parseCommandJson(allocator: std.mem.Allocator, content: []const u8) !ParsedCommand {
engine/src/github.zig:90:        if (try readGhCliToken(self.allocator)) |token| {
engine/src/github.zig:479:pub fn readGhCliToken(allocator: std.mem.Allocator) !?[]const u8 {
engine/src/worktree_lifecycle.zig:98:pub fn resolveWorktreeRoot(
engine/src/worktree_lifecycle.zig:152:    const root = try resolveWorktreeRoot(allocator, cfg, project_path);
```
**Recommendation:** Make these helpers module-private unless a cross-module consumer is intentionally planned and documented.

## Tech Debt Assessment: TD21 — Dangling worktrees if engine crashes mid-spawn

**Current impact:** latent risk
**Fix complexity:** days
**Recommended sprint:** v0.2
**Rationale:** The current registry is in-memory only, so crash recovery needs a startup reconciliation pass across git worktrees and on-disk directories, not just a local cleanup tweak.

## Tech Debt Assessment: TD22 — Session restore does not re-establish ownership registry state

**Current impact:** observable bug
**Fix complexity:** days
**Recommended sprint:** v0.2
**Rationale:** Session persistence stores only `roleId`, worktree path, and branch, so runtime ownership mutations are silently lost on restore and need persisted registry state or a replay log.

## Tech Debt Assessment: TD23 — CLAUDE.md rendered as plain text, not true markdown

**Current impact:** cosmetic
**Fix complexity:** hours
**Recommended sprint:** v0.1.5
**Rationale:** The rendering gap is obvious in `ContextView`, but the fix is localized to presentation and does not require engine changes.

## Tech Debt Assessment: TD24 — JSONL log grows unbounded across sessions, no rotation

**Current impact:** latent risk
**Fix complexity:** days
**Recommended sprint:** v0.2
**Rationale:** `HistoryLogger.append()` rereads the entire file on every write and both append/load cap reads at 10 MB, so rotation should be designed alongside persistence semantics rather than patched ad hoc.

## Tech Debt Assessment: TD25 — Push-to-main block does not parse refspecs (HEAD:main bypasses)

**Current impact:** observable bug
**Fix complexity:** hours
**Recommended sprint:** audit-address
**Rationale:** The shell wrapper already intercepts push, and extending it from literal token matching to destination-ref parsing is a contained fix that closes a real workflow-governance bypass.

## Tech Debt Assessment: TD26 — PRState and PRStatus model same concept with divergent colors

**Current impact:** cosmetic
**Fix complexity:** hours
**Recommended sprint:** v0.1.5
**Rationale:** This is localized model and UI cleanup with low blast radius and direct consistency payoff.

## Tech Debt Assessment: TD27 — Hot-reload repeat within 3s window not detected by onChange

**Current impact:** observable bug
**Fix complexity:** days
**Recommended sprint:** v0.1.5
**Rationale:** The bug is user-visible during rapid role editing, but the fix wants a real reload counter or timestamp from the engine rather than more Swift-side workarounds.

## Tech Debt Assessment: TD28 — Diff highlight uses positional comparison, not LCS/Myers diff

**Current impact:** cosmetic
**Fix complexity:** hours
**Recommended sprint:** v0.1.5
**Rationale:** The highlight noise is visible but isolated to `ContextView`, so it fits a normal UI cleanup sprint.

## Domain Summary

The dominant pattern is surface-area drift. The authoritative C header, Zig exports, and Swift observable state have grown beyond what the macOS app actually consumes: I found 19 exported `tm_*` functions with no Swift bridge caller, 2 dead `@Published` state paths, and 2 message protocol values with no producer. By contrast, I did not find dead structs or enums in `CoordinationTypes.swift` or `TeamMessage.swift`; those model files are broadly referenced. The biggest user-visible problem is not the dead code itself, but the live Diff tab remaining wired to a backend that is intentionally not implemented.
