# Stream T5 — TD16: Completion History JSONL Persistence

## Your branch
feat/v014-t5-history-persistence

## Your worktree path
../teammux-stream-t5

## Read first
- CLAUDE.md — hard rules, build commands, sprint workflow
- TECH_DEBT.md — TD16 (history not persisted) and TD24 (JSONL unbounded growth) are relevant
- V014_SPRINT.md — full sprint spec, Section 4 has your detailed scope

## Your mission

**Files:** engine/src/history.zig (new), engine/include/teammux.h, engine/src/main.zig, engine/src/commands.zig

**File path:** {project_root}/.teammux/logs/completion_history.jsonl

**HistoryLogger:** append-only writer. Atomic write via temp-file-and-rename. Directory created at engine init if missing.

**Entry format:**
```json
{"type":"completion","worker_id":2,"role_id":"frontend-engineer","summary":"Implemented JWT auth","git_commit":"abc1234","timestamp":1234567890}
{"type":"question","worker_id":3,"role_id":"backend-engineer","question":"Should I use JWT?","timestamp":1234567891}
```

HistoryLogger hooked into commands.zig routing — appends on every /teammux-complete and /teammux-question processed.

**C API:**
```c
typedef struct {
    const char* type;
    uint32_t    worker_id;
    const char* role_id;
    const char* content;
    const char* git_commit;
    uint64_t    timestamp;
} tm_history_entry_t;

tm_history_entry_t** tm_history_load(tm_engine_t* engine, uint32_t* count);
void                 tm_history_free(tm_history_entry_t** entries, uint32_t count);
tm_result_t          tm_history_clear(tm_engine_t* engine);
```

**Tests:** append completion, append question, load round-trip, clear truncates, atomic write (temp rename), missing file handled, malformed line skipped.

## Message type registry (v0.1.4 additions)

Existing types (do not reuse):
- TM_MSG_TASK=0, TM_MSG_INSTRUCTION=1, TM_MSG_CONTEXT=2, TM_MSG_STATUS_REQ=3
- TM_MSG_STATUS_RPT=4, TM_MSG_COMPLETION=5, TM_MSG_ERROR=6, TM_MSG_BROADCAST=7
- TM_MSG_QUESTION=8, TM_MSG_DISPATCH=10, TM_MSG_RESPONSE=11

New in v0.1.4:
- TM_MSG_PEER_QUESTION = 12 (T2)
- TM_MSG_DELEGATION = 13 (T2)
- TM_MSG_PR_READY = 14 (T7)
- TM_MSG_PR_STATUS = 15 (T7)

## Merge order context
Wave 1 (parallel) — you can START NOW, no dependencies.
T1-T7 merge first, then Wave 2 (T8-T12), Wave 3 (T13-T15), T16 last.

## Done when
- zig build test all pass
- completion_history.jsonl written on /teammux-complete and /teammux-question
- tm_history_load returns all entries correctly
- PR raised from feat/v014-t5-history-persistence

## Core rules
- Never modify src/ (Ghostty upstream)
- All tm_* calls go through EngineClient.swift only
- No force-unwraps in production code
- zig build test must pass before raising PR
- engine/include/teammux.h is the authoritative C API contract
- roles/ is local only — no external network fetching
- TECH_DEBT.md updated when new debt discovered
- Message type values: do NOT reuse or skip — check registry above
