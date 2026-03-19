# Teammux — v0.1.3 Sprint Master Spec

**Version:** v0.1.3
**Built on:** v0.1.2 (tagged, shipped)
**Date:** March 2026

---

## 1. Sprint Overview

- **Goal:** Close the coordination loop — completion signaling, Team Lead dispatch,
  role hot-reload, interceptor hardening, role selector in setup flow
- **Session structure:** 12 parallel streams + 1 main thread orchestrator
- **Merge order:** S1 (any time) → S2/S3/S4/S5 (Wave 1, parallel) →
  S6/S7/S8/S9 (Wave 2, parallel) → S10/S11 (Wave 3, parallel) → S12 (last)

---

## 2. Stream Map

| Stream | Worktree              | Branch                                  | Owns                                        | Depends on     | Merges after      | Status   |
|--------|-----------------------|-----------------------------------------|---------------------------------------------|----------------|-------------------|----------|
| S1     | ../teammux-stream-s1  | feat/v013-stream-s1-interceptor-fix     | TD12: git commit -a interception            | nothing        | any time          | COMPLETE |
| S2     | ../teammux-stream-s2  | feat/v013-stream-s2-completion-engine   | TD13 engine: TM_MSG_COMPLETION/QUESTION     | nothing        | Wave 1            | COMPLETE |
| S3     | ../teammux-stream-s3  | feat/v013-stream-s3-bundled-roles       | TD14 C API: tm_roles_list_bundled           | nothing        | Wave 1            | COMPLETE |
| S4     | ../teammux-stream-s4  | feat/v013-stream-s4-hot-reload-engine   | TD10: hotreload.zig, kqueue role watcher    | nothing        | Wave 1            | COMPLETE |
| S5     | ../teammux-stream-s5  | feat/v013-stream-s5-coordinator-engine  | coordinator.zig, tm_dispatch_*              | nothing        | Wave 1            | COMPLETE |
| S6     | ../teammux-stream-s6  | feat/v013-stream-s6-completion-bridge   | TD13 Swift: CompletionReport, QuestionRequest| S2 merged     | after S2          | COMPLETE |
| S7     | ../teammux-stream-s7  | feat/v013-stream-s7-hot-reload-bridge   | role hot-reload Swift bridge                | S4 merged      | after S4          | COMPLETE |
| S8     | ../teammux-stream-s8  | feat/v013-stream-s8-coordinator-bridge  | coordinator Swift bridge, dispatchTask      | S5 merged      | after S5          | COMPLETE |
| S9     | ../teammux-stream-s9  | feat/v013-stream-s9-role-selector-ui    | TeamBuilderView role selector (TD14)        | S3 merged      | after S3          | COMPLETE |
| S10    | ../teammux-stream-s10 | feat/v013-stream-s10-completion-ui      | Completion/Question right pane UI           | S6 merged      | after S6          | COMPLETE |
| S11    | ../teammux-stream-s11 | feat/v013-stream-s11-dispatch-ui        | Dispatch tab, DispatchView.swift            | S8 merged      | after S8          | COMPLETE |
| S12    | ../teammux-stream-s12 | feat/v013-stream-s12-polish             | integration tests, docs, polish             | S9+S10+S11     | last              | COMPLETE |

---

## 3. Detailed Scope Per Stream

### stream-S1 — TD12: git commit -a Interceptor Fix

**Files to modify:** `engine/src/interceptor.zig` only

**What changes:**
The bash wrapper currently only intercepts the `add` subcommand. Extend the
subcommand detection block to also handle `commit` with `-a` or `--all` flags.

New bash logic in the wrapper template (inserted after the `add` block):
```bash
elif [[ "$subcmd" == "commit" ]]; then
  for arg in "$@"; do
    case "$arg" in
      -a|--all|-a*)
        if [[ ${#DENY_PATTERNS[@]} -gt 0 ]]; then
          echo "[Teammux] Cannot use 'git commit -a' with write restrictions."
          echo "[Teammux] Stage files explicitly with 'git add' first."
          echo "[Teammux] Your write scope: ${WRITE_PATTERNS[*]}"
          exit 1
        fi
        ;;
    esac
  done
fi
```

**Also add:** `git commit --all` detection (long flag form). Ensure `-am`
combined short flag (common: `git commit -am "msg"`) is also caught by
checking if any argument starts with `-` and contains both `a` and `m`.

**No C API changes needed.** The wrapper template is in `interceptor.zig`
as a string template — update the template string only.

**Tests:**
- git commit -a with deny patterns → blocked
- git commit --all with deny patterns → blocked
- git commit -am "msg" with deny patterns → blocked
- git commit -m "msg" with deny patterns → passes through (no -a)
- git commit -a with no deny patterns → passes through

**Done when:**
- `cd engine && zig build test` all pass including new tests
- TD12 noted for RESOLVED in TECH_DEBT.md (S12 handles the update)
- PR raised from feat/v013-stream-s1-interceptor-fix

---

### stream-S2 — TD13 Engine: Completion + Question Message Types

**Files to modify:** `engine/include/teammux.h`, `engine/src/main.zig`
**Files to modify:** `engine/src/commands.zig` (route to bus)

**New message types in `tm_message_type_e`:**
```c
TM_MSG_COMPLETION = 8,   // worker signals task complete
TM_MSG_QUESTION   = 9,   // worker requests Team Lead guidance
```

**New C structs in `teammux.h`:**
```c
typedef struct {
    uint32_t    worker_id;
    const char* summary;        // brief completion summary
    const char* git_commit;     // HEAD at time of completion (may be null)
    const char* details;        // optional extended details
    uint64_t    timestamp;
} tm_completion_t;

typedef struct {
    uint32_t    worker_id;
    const char* question;       // the question text
    const char* context;        // optional context from worker
    uint64_t    timestamp;
} tm_question_t;

tm_result_t tm_worker_complete(tm_engine_t* engine,
                                uint32_t worker_id,
                                const char* summary,
                                const char* details);
tm_result_t tm_worker_question(tm_engine_t* engine,
                                uint32_t worker_id,
                                const char* question,
                                const char* context);
void tm_completion_free(tm_completion_t* completion);
void tm_question_free(tm_question_t* question);
```

**commands.zig changes:**
When the command watcher fires a `/teammux-complete` command file, parse
the JSON payload `{"summary": "...", "details": "..."}` and call
`tm_worker_complete` internally. Same for `/teammux-question` with
`{"question": "...", "context": "..."}`.

**main.zig changes:**
`tm_worker_complete` and `tm_worker_question` exports. Each creates a
`tm_message_t` with the new type, routes it through the bus to the
Team Lead worker ID (worker ID 0 = Team Lead convention), and persists
to the JSONL log.

**Tests:**
- Command file `/teammux-complete` parsed and routed to bus
- Message type TM_MSG_COMPLETION in JSONL log
- `/teammux-question` parsed and routed
- Null safety on all pointer fields

**Done when:**
- `cd engine && zig build test` all pass
- PR raised from feat/v013-stream-s2-completion-engine

---

### stream-S3 — TD14 C API: tm_roles_list_bundled

**Files to modify:** `engine/src/config.zig`, `engine/include/teammux.h`,
`engine/src/main.zig`

**Problem:** `tm_roles_list` requires an active engine (session started).
TeamBuilderView runs before sessionStart(). Need a standalone function.

**New C API function:**
```c
tm_role_t** tm_roles_list_bundled(const char* project_root,
                                   uint32_t* count);
void tm_roles_list_bundled_free(tm_role_t** roles, uint32_t count);
```

**config.zig changes:**
New function `listRolesBundled(allocator, project_root) ![]RoleDefinition`
that calls `resolveRolePath` for the bundled search path only (skips
the engine instance requirement). Reuses existing `parseRoleDefinition`
and `listRolesInDir` logic.

**main.zig changes:**
`tm_roles_list_bundled` export — no engine pointer required. Uses a
temporary allocator for the call. Returns same `tm_role_t**` format as
`tm_roles_list` so Swift can reuse the same bridging code.

**Tests:**
- Returns roles without an active engine instance
- Returns same roles as tm_roles_list when both available
- Empty result when bundled path missing (graceful degradation)
- Null project_root handled

**Done when:**
- `cd engine && zig build test` all pass
- PR raised from feat/v013-stream-s3-bundled-roles

---

### stream-S4 — TD10: Role Hot-Reload Engine

**New file:** `engine/src/hotreload.zig`
**Files to modify:** `engine/include/teammux.h`, `engine/src/main.zig`

**New C API:**
```c
typedef void (*tm_role_changed_cb)(uint32_t worker_id,
                                    const char* new_claude_md,
                                    void* userdata);

tm_result_t tm_role_watch(tm_engine_t* engine,
                           uint32_t worker_id,
                           tm_role_changed_cb callback,
                           void* userdata);
tm_result_t tm_role_unwatch(tm_engine_t* engine,
                             uint32_t worker_id);
```

**hotreload.zig responsibilities:**
- `RoleWatcher` struct: one kqueue watcher per watched worker
- Watches `{role_definition_path}` for NOTE_WRITE, NOTE_DELETE,
  NOTE_RENAME (same re-open-and-re-register pattern as config.zig)
- On change: calls `config.parseRoleDefinition` for updated content,
  calls `worktree.generateRoleClaude` with new role def and existing
  task description, fires callback with new CLAUDE.md content
- Background thread per watcher (same pattern as ConfigWatcher)
- `stop()` signals thread and joins cleanly

**Engine struct additions:**
- `role_watchers: hotreload.RoleWatcherMap` (AutoHashMap(WorkerId, RoleWatcher))
- Initialised in `Engine.create()`, cleaned up in `Engine.destroy()`
- `tm_worker_dismiss` calls `tm_role_unwatch` before dismiss

**Tests:**
- Watcher detects NOTE_WRITE change
- Watcher detects NOTE_RENAME (vim save pattern)
- Callback fires with correct regenerated CLAUDE.md content
- stop() joins thread cleanly
- Watcher removed on worker dismiss

**Done when:**
- `cd engine && zig build test` all pass
- PR raised from feat/v013-stream-s4-hot-reload-engine

---

### stream-S5 — Team Lead Dispatch Engine: coordinator.zig

**New file:** `engine/src/coordinator.zig`
**Files to modify:** `engine/include/teammux.h`, `engine/src/main.zig`,
`engine/src/commands.zig`

**New C API:**
```c
tm_result_t tm_dispatch_task(tm_engine_t* engine,
                              uint32_t target_worker_id,
                              const char* instruction);
tm_result_t tm_dispatch_response(tm_engine_t* engine,
                                  uint32_t target_worker_id,
                                  const char* response);

typedef struct {
    uint32_t    target_worker_id;
    const char* instruction;
    uint64_t    timestamp;
    bool        delivered;
} tm_dispatch_event_t;

tm_dispatch_event_t** tm_dispatch_history(tm_engine_t* engine,
                                           uint32_t* count);
void tm_dispatch_history_free(tm_dispatch_event_t** events,
                               uint32_t count);
```

**coordinator.zig responsibilities:**
- `Coordinator` struct with dispatch history (capped at 100 events)
- `dispatchTask(worker_id, instruction)`:
  1. Validate worker exists in roster
  2. Create `TM_MSG_TASK` message (reuse existing type or add new)
  3. Format: `\n[Teammux] dispatch: {instruction}\n`
  4. Route through bus → fires `tm_message_cb` to Swift
  5. Swift injects into worker PTY via SurfaceView.sendText()
  6. Log to dispatch history
- `dispatchResponse(worker_id, response)`: same flow with
  `\n[Teammux] response: {response}\n`

**commands.zig addition:**
`/teammux-assign` command file format:
```json
{"target_worker_id": 2, "instruction": "refactor the auth module"}
```
When detected, calls `tm_dispatch_task` internally.

**Tests:**
- tm_dispatch_task routes message through bus
- Instruction formatted correctly in PTY injection format
- /teammux-assign command file parsed and dispatched
- History capped at 100 events
- Invalid worker_id returns TM_ERR_UNKNOWN

**Done when:**
- `cd engine && zig build test` all pass
- PR raised from feat/v013-stream-s5-coordinator-engine

---

### stream-S6 — TD13 Swift: Completion + Question Bridge

**Files to modify:** `macos/Sources/Teammux/Engine/EngineClient.swift`
**New file:** `macos/Sources/Teammux/Models/CoordinationTypes.swift`

**WAIT CHECK:** Confirm S2 has merged to main.
```
git pull origin main
grep "TM_MSG_COMPLETION\|TM_MSG_QUESTION\|tm_worker_complete" \
  engine/include/teammux.h
```

**New Swift types (CoordinationTypes.swift):**
```swift
struct CompletionReport: Identifiable, Sendable {
    let id: UUID
    let workerId: UInt32
    let summary: String
    let gitCommit: String?
    let details: String?
    let timestamp: Date
}

struct QuestionRequest: Identifiable, Sendable {
    let id: UUID
    let workerId: UInt32
    let question: String
    let context: String?
    let timestamp: Date
}
```

**EngineClient additions (MARK: - Coordination):**
```swift
@Published var workerCompletions: [UInt32: CompletionReport] = [:]
@Published var workerQuestions: [UInt32: QuestionRequest] = [:]

func acknowledgeCompletion(workerId: UInt32)
func clearQuestion(workerId: UInt32)
```

**Message callback extension:**
When `tm_message_cb` fires with `TM_MSG_COMPLETION` or `TM_MSG_QUESTION`,
parse the payload JSON, bridge to Swift type, update the respective
`@Published` dict on `@MainActor`. Follows existing Unmanaged +
Task @MainActor callback pattern.

**Tests:** CompletionReport field access, QuestionRequest fields,
EngineClient initial state empty, acknowledgement clears entry.

**Done when:**
- `./build.sh` passes
- PR raised from feat/v013-stream-s6-completion-bridge

---

### stream-S7 — Role Hot-Reload Swift Bridge

**Files to modify:** `macos/Sources/Teammux/Engine/EngineClient.swift`,
`macos/Sources/Teammux/Workspace/WorkerTerminalView.swift`

**WAIT CHECK:** Confirm S4 has merged to main.
```
grep "tm_role_watch\|tm_role_unwatch" engine/include/teammux.h
```

**EngineClient additions (MARK: - Role Hot-Reload):**
```swift
@Published var hotReloadedWorkers: Set<UInt32> = []

private func startRoleWatch(workerId: UInt32)
private func stopRoleWatch(workerId: UInt32)
```

`startRoleWatch` calls `tm_role_watch` with a callback that:
1. Receives new CLAUDE.md content as `new_claude_md`
2. Injects it into the worker's PTY via `injectText`:
   `\n[Teammux] role-update: Your role definition has been updated.\n{new_claude_md}\n`
3. Adds workerId to `hotReloadedWorkers` set
4. After 3 seconds, removes from set (transient notification)

`startRoleWatch` called from `spawnWorker` after ownership registration
when roleId is non-nil. `stopRoleWatch` called from `dismissWorker`.

**WorkerTerminalView addition:**
Subtle banner overlay when `engine.hotReloadedWorkers.contains(worker.id)`:
"Role updated — context refreshed" — same pattern as review pending banner.
Auto-dismisses after 3 seconds.

**Tests:** hotReloadedWorkers populated on callback, cleared after timeout.

**Done when:**
- `./build.sh` passes
- PR raised from feat/v013-stream-s7-hot-reload-bridge

---

### stream-S8 — Team Lead Dispatch Swift Bridge

**Files to modify:** `macos/Sources/Teammux/Engine/EngineClient.swift`
**New file:** `macos/Sources/Teammux/Models/CoordinationTypes.swift`
  (coordinate with S6 — if S6 already created this file, extend it)

**WAIT CHECK:** Confirm S5 has merged to main.
```
grep "tm_dispatch_task\|tm_dispatch_response" engine/include/teammux.h
```

**EngineClient additions (MARK: - Coordinator):**
```swift
@Published var dispatchHistory: [DispatchEvent] = []

func dispatchTask(workerId: UInt32, instruction: String) -> Bool
func dispatchResponse(workerId: UInt32, response: String) -> Bool
```

**New Swift type (add to CoordinationTypes.swift):**
```swift
struct DispatchEvent: Identifiable, Sendable {
    let id: UUID
    let targetWorkerId: UInt32
    let instruction: String
    let timestamp: Date
    let delivered: Bool
}
```

Wraps `tm_dispatch_task` and `tm_dispatch_response`. On success, appends
to `dispatchHistory`. History capped at 100 items (trim oldest).

**Tests:** dispatchTask returns Bool, history populated, cap enforced.

**Done when:**
- `./build.sh` passes
- PR raised from feat/v013-stream-s8-coordinator-bridge

---

### stream-S9 — Role Selector UI in TeamBuilderView

**Files to modify:** `macos/Sources/Teammux/Setup/TeamBuilderView.swift`,
`macos/Sources/Teammux/Setup/SetupView.swift` (if needed for role passing)

**WAIT CHECK:** Confirm S3 has merged to main.
```
grep "tm_roles_list_bundled" engine/include/teammux.h
```

**What changes:**
TeamBuilderView currently has no engine reference. Add a local role
loading mechanism using `tm_roles_list_bundled` called once on `.onAppear`.

New `@State private var bundledRoles: [RoleDefinition] = []`
New `@State private var rolesLoaded = false`

On `.onAppear`:
```swift
var count: UInt32 = 0
if let rolesPtr = tm_roles_list_bundled(projectRootPath, &count) {
    // bridge same as existing loadAvailableRoles pattern
    bundledRoles = bridgeRolesList(rolesPtr, count)
    tm_roles_list_bundled_free(rolesPtr, count)
    rolesLoaded = true
}
```

Each worker row in TeamBuilderView gains the same role picker used in
SpawnPopoverView — grouped by division, "No role" option, description
on select. Selected role ID stored in `WorkerConfig.roleId`.

`toTOML()` serialization updated to include `role = "frontend-engineer"`
when roleId is set.

**Three states:** loading (ProgressView), loaded (picker), error ("Roles
unavailable — you can assign roles after launch").

**Tests:** bundledRoles populated without engine, TOML serialization
includes role field, no-role option serializes correctly.

**Done when:**
- `./build.sh` passes
- TD14 noted for RESOLVED
- PR raised from feat/v013-stream-s9-role-selector-ui

---

### stream-S10 — Completion + Question Right Pane UI

**Files to modify:** `macos/Sources/Teammux/RightPane/LiveFeedView.swift`
**New file:** `macos/Sources/Teammux/RightPane/CompletionCardView.swift`
**New file:** `macos/Sources/Teammux/RightPane/QuestionCardView.swift`

**WAIT CHECK:** Confirm S6 has merged to main.
```
grep "workerCompletions\|workerQuestions\|CompletionReport" \
  macos/Sources/Teammux/Engine/EngineClient.swift
```

**LiveFeedView elevation:**
The existing message stream remains. Above it, add two new sections
that appear when relevant:

**Completion cards** (when `engine.workerCompletions` is non-empty):
```
┌─────────────────────────────────────────┐
│ ✅ Frontend Engineer — alice            │
│ Implemented auth component              │
│ Commit: abc1234  •  2 mins ago          │
│                    [View Diff] [Dismiss] │
└─────────────────────────────────────────┘
```
"View Diff" switches right pane to Diff tab for that worker.
"Dismiss" calls `engine.acknowledgeCompletion(workerId:)`.

**Question cards** (when `engine.workerQuestions` is non-empty):
```
┌─────────────────────────────────────────┐
│ ❓ Backend Engineer — bob              │
│ Should I use JWT or session tokens?    │
│ ┌─────────────────────────────────────┐ │
│ │ Type your response...               │ │
│ └─────────────────────────────────────┘ │
│                   [Dismiss] [Dispatch ↗]│
└─────────────────────────────────────────┘
```
"Dispatch" calls `engine.dispatchResponse(workerId:response:)` then
`engine.clearQuestion(workerId:)`.

**Three states per section:** hidden when empty, single card, multiple
cards (scrollable).

**Done when:**
- `./build.sh` passes
- Completion cards reactive to engine.workerCompletions
- Question cards reactive to engine.workerQuestions
- All three states handled
- No force-unwraps
- PR raised from feat/v013-stream-s10-completion-ui

---

### stream-S11 — Dispatch Tab + DispatchView

**Files to modify:** `macos/Sources/Teammux/RightPane/RightPaneView.swift`
**New file:** `macos/Sources/Teammux/RightPane/DispatchView.swift`

**WAIT CHECK:** Confirm S8 has merged to main.
```
grep "dispatchTask\|dispatchHistory\|DispatchEvent" \
  macos/Sources/Teammux/Engine/EngineClient.swift
```

**Right pane tab bar gains a fifth tab:**
`Team Lead | Git | Diff | Feed | Dispatch`

Custom tab bar update — add `.dispatch` case to `RightTab` enum.

**DispatchView.swift layout:**
Top section — active workers roster (compact):
```
┌──────────────────────────────────────────────┐
│ 🎨 Frontend — alice  [Instruction field] [↗] │
│ 🏗️  Backend — bob    [Instruction field] [↗] │
└──────────────────────────────────────────────┘
```
Each row has a `TextField` for the instruction and a dispatch button
calling `engine.dispatchTask(workerId:instruction:)`.

Bottom section — dispatch history:
ForEach `engine.dispatchHistory` (most recent first):
```
→ alice: "refactor the login form"  2 min ago  ✓
→ bob:   "use JWT tokens"           5 min ago  ✓
```

**Three states:**
- No workers: "No active workers — spawn workers to dispatch tasks"
- Workers, no history: worker rows with empty history
- Workers + history: full view

**Done when:**
- `./build.sh` passes
- Fifth tab renders in right pane
- Dispatch button calls engine.dispatchTask
- History list populates reactively
- No force-unwraps
- PR raised from feat/v013-stream-s11-dispatch-ui

---

### stream-S12 — Integration Tests + Polish + Docs

**WAIT CHECK:** Confirm S9, S10, AND S11 have all merged to main.

**Integration tests (engine level):**
1. `git commit -a` blocked: spawn worker with deny patterns,
   verify wrapper blocks `git commit -a` (S1 fix)
2. Completion flow: create engine, call `tm_worker_complete`,
   verify TM_MSG_COMPLETION in JSONL log
3. Question flow: call `tm_worker_question`, verify TM_MSG_QUESTION
4. Dispatch flow: call `tm_dispatch_task`, verify message routed to bus
5. Bundled roles: `tm_roles_list_bundled` returns roles without engine

**Polish:**
- Any small regressions from upstream streams
- RightPane tab bar: ensure Dispatch tab doesn't break existing tab tests
- TeamBuilderView: verify role field in generated config.toml is valid

**Documentation:**
- TECH_DEBT.md: TD10→RESOLVED (S4), TD11→RESOLVED (S9),
  TD12→RESOLVED (S1), TD13→RESOLVED (S6), TD14→RESOLVED (S9)
- CLAUDE.md: v0.1.3 marked as shipped
- V013_SPRINT.md: all streams marked complete
- Add TD15-TD18 with OPEN status confirmed

**Done when:**
- `./build.sh` passes end to end
- All integration tests pass
- All TD items updated correctly
- PR raised from feat/v013-stream-s12-polish

---

## 4. Shared Rules for All Streams

- Never modify `src/` (Ghostty upstream)
- All `tm_*` calls go through `EngineClient.swift` only
- No force-unwraps in production code
- `zig build test` must pass before raising PR (engine streams)
- Swift build must pass before raising PR (Swift streams)
- `engine/include/teammux.h` is the authoritative C API contract
- `roles/` is local only — no external network fetching ever
- TECH_DEBT.md updated when new debt discovered

---

## 5. Known Risks

- S2 adds new message type enum values — any stream consuming
  `tm_message_type_e` (S6, S8) must pull main after S2 merges
  to avoid enum mismatch
- S6 and S8 both create/extend `CoordinationTypes.swift` — coordinate
  so S8 extends the file S6 creates rather than duplicating it
- S10 and S11 both modify `RightPaneView.swift` (tab bar) — S11
  must pull main after S10 merges to avoid conflict on the tab enum
- S12 is the heaviest coordination point — wait for S9, S10, AND S11
  before starting implementation

---

## 6. Merge Checklist (main thread runs for each PR)

- [ ] Branch based on current main (merge-base check passes)
- [ ] All tests pass (zig build test or Swift build)
- [ ] No src/ modifications
- [ ] No force-unwraps (Swift streams)
- [ ] tm_* calls confined to EngineClient.swift (Swift streams)
- [ ] Zero conflicts with main
- [ ] TECH_DEBT.md updated for items resolved or newly discovered
- [ ] No external network calls in roles/ loading logic (S3, S9)
```













































































































































































