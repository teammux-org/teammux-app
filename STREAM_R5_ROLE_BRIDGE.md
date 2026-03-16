# Stream R5 — EngineClient Role Bridge

## Your branch
`feat/v012-stream-r5-role-bridge`

## Your worktree path
`../teammux-stream-r5`

## Read first
1. `CLAUDE.md` — hard rules, build commands, sprint workflow
2. `TECH_DEBT.md` — open and resolved debt items
3. `V012_SPRINT.md` — full sprint spec, Section 3 "stream-R5 — EngineClient Role Bridge"

---

## Your mission

Create the Swift-side bridge for roles and capabilities: new `RoleTypes.swift` model file and EngineClient extensions that wrap the C API role and ownership functions.

### New file
`macos/Sources/Teammux/Models/RoleTypes.swift`

```swift
struct RoleDefinition: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let division: String
    let emoji: String
    let description: String
    let writePatterns: [String]
    let denyWritePatterns: [String]
}

enum RoleDivision: String, CaseIterable, Sendable {
    case engineering, design, product, testing
    case projectManagement = "project-management"
    case strategy, specialized
    var displayName: String { ... }
}
```

### EngineClient.swift additions (MARK: - Roles)

```swift
@Published var availableRoles: [RoleDefinition] = []
@Published var workerRoles: [UInt32: RoleDefinition] = [:]

func loadAvailableRoles()
func roleForWorker(_ workerId: UInt32) -> RoleDefinition?
func checkCapability(workerId: UInt32, filePath: String) -> Bool
```

### Updated spawnWorker signature

```swift
func spawnWorker(
    agentBinary: String,
    agentType: TMAgentType,
    workerName: String,
    taskDescription: String,
    roleId: String?          // new, optional
) -> UInt32
```

### Callback threading
Same `Unmanaged` + `Task @MainActor` pattern as all other EngineClient callbacks.

### Wraps
- `tm_role_resolve` → `func resolveRole(id: String) -> RoleDefinition?`
- `tm_roles_list` → `func loadAvailableRoles()`
- `tm_ownership_check` → `func checkCapability(workerId:filePath:) -> Bool`

### No UI changes
UI is stream-R6's job. This stream only creates the Swift model and EngineClient bridge.

### Tests
- Role loading
- Capability check returns correct bool
- Worker role mapping
- Spawn with and without role ID
- Available roles list non-empty after `loadAvailableRoles()`

---

## WAIT CHECK

**You MUST wait for stream-R4 to be merged into main before implementing.** Pull main and verify `tm_ownership_check`, `tm_role_resolve`, `tm_roles_list` exist in `engine/include/teammux.h` before implementing.

## Merge order context

R1 → R3 → R2 → R4 → **R5**/R8 (parallel) → R6 → R7

R5 merges after R4 (in parallel with R8). R6 depends on R5 being merged.

---

## Done when
- `./build.sh` passes end to end
- `engine.availableRoles` populated on session start
- `engine.checkCapability(workerId:filePath:)` returns correct result
- `engine.spawnWorker(..., roleId: "frontend-engineer")` works
- PR raised from `feat/v012-stream-r5-role-bridge`

---

## Core rules
- Never modify `src/` (Ghostty upstream)
- All `tm_*` calls go through `EngineClient.swift` only
- No force-unwraps in production code
- Swift test suite must pass before raising PR
- `engine/include/teammux.h` is the authoritative C API contract
- TECH_DEBT.md updated when new debt is discovered
