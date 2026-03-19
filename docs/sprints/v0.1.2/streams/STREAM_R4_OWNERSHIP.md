# Stream R4 — FileOwnershipRegistry

## Your branch
`feat/v012-stream-r4-ownership`

## Your worktree path
`../teammux-stream-r4`

## Read first
1. `CLAUDE.md` — hard rules, build commands, sprint workflow
2. `TECH_DEBT.md` — open and resolved debt items
3. `V012_SPRINT.md` — full sprint spec, Section 3 "stream-R4 — FileOwnershipRegistry"

---

## Your mission

Create `engine/src/ownership.zig` — a thread-safe file ownership registry that enforces per-worker write permissions based on role capabilities.

### New file
`engine/src/ownership.zig`

### New C API additions to teammux.h

```c
tm_result_t tm_ownership_check(tm_engine_t* engine,
                                uint32_t worker_id,
                                const char* file_path,
                                bool* out_allowed);
tm_result_t tm_ownership_register(tm_engine_t* engine,
                                   uint32_t worker_id,
                                   const char* path_pattern,
                                   bool allow_write);
tm_result_t tm_ownership_release(tm_engine_t* engine,
                                  uint32_t worker_id);
tm_ownership_entry_t** tm_ownership_get(tm_engine_t* engine,
                                         uint32_t worker_id,
                                         uint32_t* count);
void tm_ownership_free(tm_ownership_entry_t** entries, uint32_t count);

typedef struct {
    const char* path_pattern;
    uint32_t worker_id;
    bool allow_write;
} tm_ownership_entry_t;
```

### ownership.zig core

```zig
pub const PathRule = struct {
    pattern: []const u8,
    allow_write: bool,
};

pub const FileOwnershipRegistry = struct {
    allocator: Allocator,
    rules: AutoHashMap(WorkerId, []PathRule),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: Allocator) FileOwnershipRegistry
    pub fn deinit(self: *FileOwnershipRegistry) void
    pub fn register(self, worker_id, pattern, allow_write) !void
    pub fn release(self, worker_id) void
    pub fn check(self, worker_id, file_path) bool
    pub fn getRules(self, worker_id) ?[]PathRule
};
```

### check() logic

1. Get rules for worker_id. If none: **default allow** (no role = no restrictions).
2. Evaluate deny_write rules first (allow_write=false). If any match: return false.
3. Evaluate write rules (allow_write=true). If any match: return true.
4. Default: return false (deny if no explicit allow).

### Glob matching

Implement `globMatch(pattern, path) bool` supporting:
- `**` (any path segment depth)
- `*` (any single segment)
- `?` (any char)

Follow `.gitignore` glob semantics.

### Integration with spawn/dismiss

- `tm_worker_spawn`: after worktree creation, if role has capabilities, call `ownership.register()` for all write and deny_write patterns
- `tm_worker_dismiss`: call `ownership.release(worker_id)`
- `tm_merge_reject`: call `ownership.release(worker_id)`

### Engine struct addition

```zig
ownership_registry: ownership.FileOwnershipRegistry,
```

Initialised in `Engine.create()`, cleaned up in `Engine.destroy()`.

### Tests
- Glob matching: `**`, `*`, `?`, nested paths, edge cases
- Deny precedence over allow
- Multi-worker isolation (worker A cannot query worker B's rules)
- Spawn populates registry from role capabilities
- Dismiss clears registry entries
- Default allow when no rules registered
- Thread safety under concurrent check calls

---

## WAIT CHECK

**You MUST wait for stream-R2 to be merged into main before implementing.** R4 needs the `config.RoleDefinition` type to be stable before populating the registry at spawn time. The main thread orchestrator will notify you when R2 is merged. Pull main at that point before starting work.

## Merge order context

R1 → R3 → R2 → **R4** → R5/R8 (parallel) → R6 → R7

R4 merges after R2. R5 and R8 both depend on R4 being merged.

---

## Done when
- `cd engine && zig build test` — all tests pass
- `tm_ownership_check` returns correct allow/deny for test cases
- Registry populated correctly from role capabilities at spawn
- PR raised from `feat/v012-stream-r4-ownership`

---

## Core rules
- Never modify `src/` (Ghostty upstream)
- All `tm_*` calls go through `EngineClient.swift` only
- No force-unwraps in production code
- `zig build test` must pass before raising PR
- `engine/include/teammux.h` is the authoritative C API contract
- Header changes are additive only — do not remove or rename existing functions
- TECH_DEBT.md updated when new debt is discovered
