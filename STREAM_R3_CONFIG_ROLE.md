# Stream R3 — Config Role Field

## Your branch
`feat/v012-stream-r3-config-role`

## Your worktree path
`../teammux-stream-r3`

## Read first
1. `CLAUDE.md` — hard rules, build commands, sprint workflow
2. `TECH_DEBT.md` — open and resolved debt items
3. `V012_SPRINT.md` — full sprint spec, Section 3 "stream-R3 — Config Role Field"

---

## Your mission

Add role field support to `engine/src/config.zig` and expose role resolution through new C API functions in `engine/include/teammux.h`.

### Files to modify
- `engine/src/config.zig`
- `engine/include/teammux.h` (additive only)

### WorkerConfig additions

```zig
pub const WorkerConfig = struct {
    id: []const u8,
    name: []const u8,
    agent: []const u8,
    model: []const u8,
    permissions: []const u8,
    role: ?[]const u8,          // new: role id e.g. "frontend-engineer"
    role_path: ?[]const u8,     // resolved at load time, not in TOML
};
```

### Role resolution logic

Search path order (first match wins):
1. `{project_root}/.teammux/roles/{role_id}.toml` — project-local overrides
2. `~/.teammux/roles/{role_id}.toml` — user-level custom roles
3. `{bundled_roles_path}/{role_id}.toml` — Teammux default library

**Bundled roles path** resolved as:
- `{executable_dir}/../Resources/roles/` (macOS app bundle)
- `{executable_dir}/roles/` (development build)

### New functions in config.zig

```zig
pub fn resolveRolePath(
    allocator: Allocator,
    role_id: []const u8,
    project_root: []const u8,
) !?[]u8

pub fn parseRoleDefinition(
    allocator: Allocator,
    role_path: []const u8,
) !RoleDefinition

pub const RoleDefinition = struct {
    id: []const u8,
    name: []const u8,
    division: []const u8,
    emoji: []const u8,
    description: []const u8,
    write_patterns: [][]const u8,
    deny_write_patterns: [][]const u8,
    can_push: bool,
    can_merge: bool,
    trigger_events: [][]const u8,
    mission: []const u8,
    focus: []const u8,
    deliverables: [][]const u8,
    rules: [][]const u8,
    workflow: [][]const u8,
    success_metrics: [][]const u8,
    // memory management
    pub fn deinit(self: *RoleDefinition, allocator: Allocator) void
};
```

### Graceful degradation

If `role` is set but no matching file is found in any search path, log a warning and continue with generic CLAUDE.md. **Never error out.**

### New C API additions to teammux.h

```c
typedef struct {
    const char* id;
    const char* name;
    const char* division;
    const char* emoji;
    const char* description;
    const char** write_patterns;
    uint32_t write_pattern_count;
    const char** deny_write_patterns;
    uint32_t deny_write_pattern_count;
} tm_role_t;

tm_result_t tm_role_resolve(tm_engine_t* engine,
                             const char* role_id,
                             tm_role_t** out_role);
void tm_role_free(tm_role_t* role);
tm_role_t** tm_roles_list(tm_engine_t* engine, uint32_t* count);
void tm_roles_list_free(tm_role_t** roles, uint32_t count);
```

### Tests
- Role field parsing
- All three search path levels
- Missing role graceful degradation
- Search path precedence order
- RoleDefinition parse of each required field

---

## WAIT CHECK

R3 runs in parallel with R1 but depends on R1's format spec being finalised. You can implement the resolution and parsing logic, but confirm R1 has merged before finalising format validation tests against real role files. The main thread orchestrator will coordinate.

## Merge order context

R1/R3 merge first (parallel) → R2 → R4 → R5/R8 (parallel) → R6 → R7

R3 merges in the first batch alongside R1.

---

## Done when
- `cd engine && zig build test` — all tests pass including new role tests
- `config.toml` with `role = "frontend-engineer"` parses without error
- Missing role logs warning and continues (does not panic)
- PR raised from `feat/v012-stream-r3-config-role`

---

## Core rules
- Never modify `src/` (Ghostty upstream)
- All `tm_*` calls go through `EngineClient.swift` only
- No force-unwraps in production code
- `zig build test` must pass before raising PR
- `engine/include/teammux.h` is the authoritative C API contract
- Header changes are additive only — do not remove or rename existing functions
- TECH_DEBT.md updated when new debt is discovered
