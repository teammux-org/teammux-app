# Stream S10 — Completion + Question Right Pane UI

## Your branch
`feat/v013-stream-s10-completion-ui`

## Your worktree path
`../teammux-stream-s10/`

## Read first
- `CLAUDE.md` — hard rules, build commands, sprint workflow
- `TECH_DEBT.md` — current debt items
- `V013_SPRINT.md` — Section 3, stream-S10 scope

## Your mission

**Files to modify:** `macos/Sources/Teammux/RightPane/LiveFeedView.swift`
**New file:** `macos/Sources/Teammux/RightPane/CompletionCardView.swift`
**New file:** `macos/Sources/Teammux/RightPane/QuestionCardView.swift`

**LiveFeedView elevation:**
The existing message stream remains. Above it, add two new sections
that appear when relevant:

**Completion cards** (when `engine.workerCompletions` is non-empty):
```
+---------------------------------------------+
| Checkmark Frontend Engineer — alice          |
| Implemented auth component                   |
| Commit: abc1234  *  2 mins ago               |
|                     [View Diff] [Dismiss]    |
+---------------------------------------------+
```
"View Diff" switches right pane to Diff tab for that worker.
"Dismiss" calls `engine.acknowledgeCompletion(workerId:)`.

**Question cards** (when `engine.workerQuestions` is non-empty):
```
+---------------------------------------------+
| Question Backend Engineer — bob              |
| Should I use JWT or session tokens?          |
| +------------------------------------------+|
| | Type your response...                    | |
| +------------------------------------------+|
|                    [Dismiss] [Dispatch ->]    |
+---------------------------------------------+
```
"Dispatch" calls `engine.dispatchResponse(workerId:response:)` then
`engine.clearQuestion(workerId:)`.

**Three states per section:** hidden when empty, single card, multiple
cards (scrollable).

## WAIT CHECK
Confirm S6 has merged to main before starting implementation:
```bash
git pull origin main
grep "workerCompletions\|workerQuestions\|CompletionReport" \
  macos/Sources/Teammux/Engine/EngineClient.swift
```
If those symbols are not present, S6 has not merged yet — wait.

## Merge order context
S10 is in **Wave 3**. Depends on S6 merging first.
S12 depends on S10 merging (S12 is the final integration/polish stream).

**Risk:** S11 also modifies `RightPaneView.swift` (tab bar). If S10 and S11
merge close together, watch for tab enum conflicts.

## Done when
- `./build.sh` passes
- Completion cards reactive to engine.workerCompletions
- Question cards reactive to engine.workerQuestions
- All three states handled
- No force-unwraps
- PR raised from `feat/v013-stream-s10-completion-ui`

## Core rules
- NEVER modify `src/` (Ghostty upstream)
- ALL `tm_*` calls go through `EngineClient.swift` only
- NO force-unwraps in production code
- `./build.sh` must pass before raising PR
- TECH_DEBT.md updated when new debt discovered
