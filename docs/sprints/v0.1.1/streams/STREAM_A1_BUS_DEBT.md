# Teammux v0.1.1 — Stream A1: Bus Debt

## Your branch
feat/v011-stream-a1-bus-debt

## Your worktree
../teammux-stream-a1

## Read first
Read V011_SPRINT.md Section 3 (stream-A1) and TECH_DEBT.md
(TD1 and TD4) before doing anything else.
Read engine/include/teammux.h on main — authoritative contract.
Read engine/src/bus.zig — your primary file.

## Your mission
Resolve TD1 and TD4 from TECH_DEBT.md.

### TD1 — Bus retry (BREAKING CHANGE)
Change tm_message_cb return type from void to tm_result_t
in engine/include/teammux.h. This is a breaking API change.
You must update all three of these atomically in one PR:
1. engine/include/teammux.h — change callback signature
2. engine/src/bus.zig — read return value, retry on TM_ERR_*
3. macos/Sources/Teammux/Engine/EngineClient.swift — update
   C callback signature and all call sites

Retry logic: up to 3 attempts, exponential backoff 1s → 2s → 4s.
After 3 failures: mark message as FAILED in log, fire callback
with failure status, do not retry further.

### TD4 — git_commit capture
In bus.zig, before writing each message to JSONL log:
run git -C {project_root} rev-parse HEAD as subprocess.
Capture stdout, trim whitespace, store as git_commit field.
On failure (not a git repo, no commits yet): store null.
This is a one-function addition — do not over-engineer it.

## Merge order
You MAY merge as soon as your PR passes review.
stream-B1 depends on your tm_message_cb change being on main.
Merge promptly after approval — do not leave the PR open.

## Done when
- cd engine && zig build test — all tests pass, new tests added
  for retry logic and git_commit capture
- tm_message_cb signature change consistent across header,
  engine, and Swift bridge
- EngineClient.swift compiles with updated callback signature
- ./build.sh passes end to end
- PR raised, all checks pass

## Core rules
- Never modify src/
- Only you touch EngineClient.swift in this sprint —
  no other stream modifies it until after you merge
- No force-unwraps
