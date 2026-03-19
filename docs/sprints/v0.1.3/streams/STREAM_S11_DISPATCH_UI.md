# Stream S11 — Dispatch Tab + DispatchView

## Your branch
`feat/v013-stream-s11-dispatch-ui`

## Your worktree path
`../teammux-stream-s11/`

## Read first
- `CLAUDE.md` — hard rules, build commands, sprint workflow
- `TECH_DEBT.md` — current debt items
- `V013_SPRINT.md` — Section 3, stream-S11 scope

## Your mission

**Files to modify:** `macos/Sources/Teammux/RightPane/RightPaneView.swift`
**New file:** `macos/Sources/Teammux/RightPane/DispatchView.swift`

**Right pane tab bar gains a fifth tab:**
`Team Lead | Git | Diff | Feed | Dispatch`

Custom tab bar update — add `.dispatch` case to `RightTab` enum.

**DispatchView.swift layout:**
Top section — active workers roster (compact):
```
+------------------------------------------------+
| Frontend — alice  [Instruction field] [Send]   |
| Backend — bob     [Instruction field] [Send]   |
+------------------------------------------------+
```
Each row has a `TextField` for the instruction and a dispatch button
calling `engine.dispatchTask(workerId:instruction:)`.

Bottom section — dispatch history:
ForEach `engine.dispatchHistory` (most recent first):
```
-> alice: "refactor the login form"  2 min ago  Checkmark
-> bob:   "use JWT tokens"           5 min ago  Checkmark
```

**Three states:**
- No workers: "No active workers — spawn workers to dispatch tasks"
- Workers, no history: worker rows with empty history
- Workers + history: full view

## WAIT CHECK
Confirm S8 has merged to main before starting implementation:
```bash
git pull origin main
grep "dispatchTask\|dispatchHistory\|DispatchEvent" \
  macos/Sources/Teammux/Engine/EngineClient.swift
```
If those symbols are not present, S8 has not merged yet — wait.

## Merge order context
S11 is in **Wave 3**. Depends on S8 merging first.
S12 depends on S11 merging (S12 is the final integration/polish stream).

**Risk:** S10 also modifies `RightPaneView.swift` (tab bar). S11 should
pull main after S10 merges to avoid conflict on the tab enum.

## Done when
- `./build.sh` passes
- Fifth tab renders in right pane
- Dispatch button calls engine.dispatchTask
- History list populates reactively
- No force-unwraps
- PR raised from `feat/v013-stream-s11-dispatch-ui`

## Core rules
- NEVER modify `src/` (Ghostty upstream)
- ALL `tm_*` calls go through `EngineClient.swift` only
- NO force-unwraps in production code
- `./build.sh` must pass before raising PR
- TECH_DEBT.md updated when new debt discovered
