# Stream S3 — TD14 C API: tm_roles_list_bundled

## Your branch
`feat/v013-stream-s3-bundled-roles`

## Your worktree path
`../teammux-stream-s3/`

## Read first
- `CLAUDE.md` — hard rules, build commands, sprint workflow
- `TECH_DEBT.md` — TD14 is your target (C API half)
- `V013_SPRINT.md` — Section 3, stream-S3 scope

## Your mission

**Files to modify:** `engine/src/config.zig`, `engine/include/teammux.h`, `engine/src/main.zig`

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

## Merge order context
S3 is in **Wave 1** (parallel with S2, S4, S5). No dependencies.
S9 depends on S3 merging first (S9 consumes `tm_roles_list_bundled` in TeamBuilderView).

## Done when
- `cd engine && zig build test` all pass
- PR raised from `feat/v013-stream-s3-bundled-roles`

## Core rules
- NEVER modify `src/` (Ghostty upstream)
- `engine/include/teammux.h` is the authoritative C API contract
- `roles/` is local only — no external network fetching ever
- `zig build test` must pass before raising PR
- TECH_DEBT.md updated when new debt discovered
