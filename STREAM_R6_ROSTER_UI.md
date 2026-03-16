# Stream R6 — Roster UI Role Display

## Your branch
`feat/v012-stream-r6-roster-ui`

## Your worktree path
`../teammux-stream-r6`

## Read first
1. `CLAUDE.md` — hard rules, build commands, sprint workflow
2. `TECH_DEBT.md` — open and resolved debt items
3. `V012_SPRINT.md` — full sprint spec, Section 3 "stream-R6 — Roster UI Role Display"

---

## Your mission

Add role display and selection UI to the worker roster, spawn popover, and team builder views.

### Files to modify
- `macos/Sources/Teammux/Workspace/WorkerRow.swift`
- `macos/Sources/Teammux/Workspace/SpawnPopoverView.swift`
- `macos/Sources/Teammux/Setup/TeamBuilderView.swift`

### WorkerRow.swift additions
- Role emoji badge (e.g. `🎨`) displayed before worker name
- Role name in secondary text below task description
- Capability indicator: subtle `lock.fill` SF Symbol if worker has `denyWritePatterns` — `.help` tooltip on hover listing restricted paths

### SpawnPopoverView.swift additions
- Role picker `Menu` showing all roles from `engine.availableRoles` grouped by division with dividers
- Selecting a role: sets `selectedRoleId`, shows role description in secondary text below picker
- "No role (generic)" option at top for backwards compatibility
- Role emoji shown in menu item alongside role name

### TeamBuilderView.swift additions
- Same role picker added to each worker row in team builder
- Division grouping header labels in picker

### Three states for role picker
- **Loading:** `ProgressView` while `engine.availableRoles` is empty
- **Loaded:** full picker with all roles
- **Error:** "No roles available" with retry button

### No EngineClient changes
Consumes `engine.availableRoles` and `engine.workerRoles` from stream-R5. Does not modify EngineClient.

### Tests
- Role picker renders all available roles grouped by division
- Selecting a role updates `selectedRoleId`
- "No role" option present and selectable
- WorkerRow shows emoji + role name for workers with roles
- WorkerRow shows no badge for workers without roles

---

## WAIT CHECK

**You MUST wait for stream-R5 to be merged into main before implementing.** Pull main and verify `engine.availableRoles` and `engine.workerRoles` exist in EngineClient before implementing.

## Merge order context

R1 → R3 → R2 → R4 → R5/R8 (parallel) → **R6** → R7

R6 merges after R5. R7 depends on R6 being merged.

---

## Done when
- `./build.sh` passes end to end
- Spawn popover shows role picker with all 31 roles
- Worker rows show role emoji and name
- PR raised from `feat/v012-stream-r6-roster-ui`

---

## Core rules
- Never modify `src/` (Ghostty upstream)
- All `tm_*` calls go through `EngineClient.swift` only
- No force-unwraps in production code
- Swift test suite must pass before raising PR
- `engine/include/teammux.h` is the authoritative C API contract
- TECH_DEBT.md updated when new debt is discovered
