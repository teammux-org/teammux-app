# Stream S9 — Role Selector UI in TeamBuilderView

## Your branch
`feat/v013-stream-s9-role-selector-ui`

## Your worktree path
`../teammux-stream-s9/`

## Read first
- `CLAUDE.md` — hard rules, build commands, sprint workflow
- `TECH_DEBT.md` — TD11 and TD14 are your targets
- `V013_SPRINT.md` — Section 3, stream-S9 scope

## Your mission

**Files to modify:** `macos/Sources/Teammux/Setup/TeamBuilderView.swift`,
`macos/Sources/Teammux/Setup/SetupView.swift` (if needed for role passing)

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

## WAIT CHECK
Confirm S3 has merged to main before starting implementation:
```bash
git pull origin main
grep "tm_roles_list_bundled" engine/include/teammux.h
```
If that symbol is not present, S3 has not merged yet — wait.

## Merge order context
S9 is in **Wave 2**. Depends on S3 merging first.
S12 depends on S9 merging (S12 is the final integration/polish stream).

## Done when
- `./build.sh` passes
- TD14 noted for RESOLVED
- PR raised from `feat/v013-stream-s9-role-selector-ui`

## Core rules
- NEVER modify `src/` (Ghostty upstream)
- ALL `tm_*` calls go through `EngineClient.swift` only
- NO force-unwraps in production code
- `roles/` is local only — no external network fetching ever
- `./build.sh` must pass before raising PR
- TECH_DEBT.md updated when new debt discovered
