# Stream S2 — TD13 Engine: Completion + Question Message Types

## Your branch
`feat/v013-stream-s2-completion-engine`

## Your worktree path
`../teammux-stream-s2/`

## Read first
- `CLAUDE.md` — hard rules, build commands, sprint workflow
- `TECH_DEBT.md` — TD13 is your target (engine half)
- `V013_SPRINT.md` — Section 3, stream-S2 scope

## Your mission

**Files to modify:** `engine/include/teammux.h`, `engine/src/main.zig`, `engine/src/commands.zig`

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

## Merge order context
S2 is in **Wave 1** (parallel with S3, S4, S5). No dependencies.
S6 depends on S2 merging first (S6 builds the Swift bridge for your engine types).

## Done when
- `cd engine && zig build test` all pass
- PR raised from `feat/v013-stream-s2-completion-engine`

## Core rules
- NEVER modify `src/` (Ghostty upstream)
- `engine/include/teammux.h` is the authoritative C API contract
- `zig build test` must pass before raising PR
- TECH_DEBT.md updated when new debt discovered
