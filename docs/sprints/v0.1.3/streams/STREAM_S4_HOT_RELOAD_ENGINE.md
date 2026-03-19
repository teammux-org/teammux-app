# Stream S4 — TD10: Role Hot-Reload Engine

## Your branch
`feat/v013-stream-s4-hot-reload-engine`

## Your worktree path
`../teammux-stream-s4/`

## Read first
- `CLAUDE.md` — hard rules, build commands, sprint workflow
- `TECH_DEBT.md` — TD10 is your target
- `V013_SPRINT.md` — Section 3, stream-S4 scope

## Your mission

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

## Merge order context
S4 is in **Wave 1** (parallel with S2, S3, S5). No dependencies.
S7 depends on S4 merging first (S7 builds the Swift bridge for hot-reload).

## Done when
- `cd engine && zig build test` all pass
- PR raised from `feat/v013-stream-s4-hot-reload-engine`

## Core rules
- NEVER modify `src/` (Ghostty upstream)
- `engine/include/teammux.h` is the authoritative C API contract
- `zig build test` must pass before raising PR
- TECH_DEBT.md updated when new debt discovered
