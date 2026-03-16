# Stream R7 — Polish + TD8

## Your branch
`feat/v012-stream-r7-polish`

## Your worktree path
`../teammux-stream-r7`

## Read first
1. `CLAUDE.md` — hard rules, build commands, sprint workflow
2. `TECH_DEBT.md` — open and resolved debt items
3. `V012_SPRINT.md` — full sprint spec, Section 3 "stream-R7 — Polish + TD8"

---

## Your mission

Resolve TD8 (ConflictType enum), add role-aware integration polish, and update sprint documentation to mark v0.1.2 as shipped.

### TD8 resolution

Add `ConflictType` enum to `macos/Sources/Teammux/Models/MergeTypes.swift`:

```swift
enum ConflictType: String, Sendable {
    case content = "content"
    case unknown = "unknown"

    init(rawString: String) {
        self = ConflictType(rawValue: rawString) ?? .unknown
    }

    var displayName: String {
        switch self {
        case .content: return "Content conflict"
        case .unknown: return "Unknown conflict"
        }
    }
}
```

- `ConflictInfo.conflictType` changed from `String` to `ConflictType`
- `ConflictView.swift` updated to use `conflict.conflictType.displayName`
- All existing tests updated

### Integration polish (role-aware improvements)

- ConflictView header updated: "Merge conflict in {worker.name}'s {role.emoji} {role.name} branch" when role is available
- WorkerPaneView empty state: "Spawn a worker with a role to get started" when `engine.availableRoles` is non-empty
- Any small regressions identified during sprint documented and fixed

### Documentation updates

- `CLAUDE.md` version history: v0.1.2 marked as shipped
- `TECH_DEBT.md`: TD8 → RESOLVED, TD9 → RESOLVED (from R8)
- `V012_SPRINT.md`: all items marked complete in stream map

---

## WAIT CHECK

**You MUST wait for BOTH stream-R6 AND stream-R8 to be merged into main before implementing.** R7 depends on both. The main thread orchestrator will notify you when both are merged. Pull main at that point before starting work.

## Merge order context

R1 → R3 → R2 → R4 → R5/R8 (parallel) → R6 → **R7**

R7 merges last. It is the final stream in the sprint.

---

## Done when
- `./build.sh` passes end to end
- `ConflictInfo.conflictType` is `ConflictType` enum not `String`
- ConflictView header shows role name when available
- TECH_DEBT.md TD8 and TD9 both RESOLVED
- PR raised from `feat/v012-stream-r7-polish`

---

## Core rules
- Never modify `src/` (Ghostty upstream)
- All `tm_*` calls go through `EngineClient.swift` only
- No force-unwraps in production code
- Swift test suite must pass before raising PR
- `engine/include/teammux.h` is the authoritative C API contract
- TECH_DEBT.md updated when new debt is discovered
