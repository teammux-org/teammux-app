# Stream S5 — Team Lead Dispatch Engine: coordinator.zig

## Your branch
`feat/v013-stream-s5-coordinator-engine`

## Your worktree path
`../teammux-stream-s5/`

## Read first
- `CLAUDE.md` — hard rules, build commands, sprint workflow
- `TECH_DEBT.md` — current debt items
- `V013_SPRINT.md` — Section 3, stream-S5 scope

## Your mission

**New file:** `engine/src/coordinator.zig`
**Files to modify:** `engine/include/teammux.h`, `engine/src/main.zig`, `engine/src/commands.zig`

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
  4. Route through bus -> fires `tm_message_cb` to Swift
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

## Merge order context
S5 is in **Wave 1** (parallel with S2, S3, S4). No dependencies.
S8 depends on S5 merging first (S8 builds the Swift bridge for coordinator).

## Done when
- `cd engine && zig build test` all pass
- PR raised from `feat/v013-stream-s5-coordinator-engine`

## Core rules
- NEVER modify `src/` (Ghostty upstream)
- NO direct git operations outside worktree.zig, merge.zig, interceptor.zig, coordinator.zig
- `engine/include/teammux.h` is the authoritative C API contract
- `zig build test` must pass before raising PR
- TECH_DEBT.md updated when new debt discovered
