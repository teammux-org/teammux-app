# Stream S12 — Integration Tests + Polish + Docs

## Your branch
`feat/v013-stream-s12-polish`

## Your worktree path
`../teammux-stream-s12/`

## Read first
- `CLAUDE.md` — hard rules, build commands, sprint workflow
- `TECH_DEBT.md` — all TD items to update
- `V013_SPRINT.md` — Section 3, stream-S12 scope (full sprint context)

## Your mission

### Integration tests (engine level)
1. `git commit -a` blocked: spawn worker with deny patterns,
   verify wrapper blocks `git commit -a` (S1 fix)
2. Completion flow: create engine, call `tm_worker_complete`,
   verify TM_MSG_COMPLETION in JSONL log
3. Question flow: call `tm_worker_question`, verify TM_MSG_QUESTION
4. Dispatch flow: call `tm_dispatch_task`, verify message routed to bus
5. Bundled roles: `tm_roles_list_bundled` returns roles without engine

### Polish
- Any small regressions from upstream streams
- RightPane tab bar: ensure Dispatch tab doesn't break existing tab tests
- TeamBuilderView: verify role field in generated config.toml is valid

### Documentation
- TECH_DEBT.md: TD10->RESOLVED (S4), TD11->RESOLVED (S9),
  TD12->RESOLVED (S1), TD13->RESOLVED (S6), TD14->RESOLVED (S9)
- CLAUDE.md: v0.1.3 marked as shipped
- V013_SPRINT.md: all streams marked complete
- Confirm TD15-TD18 with OPEN status

## WAIT CHECK
Confirm S9, S10, AND S11 have all merged to main before starting:
```bash
git pull origin main

# Verify S9 (role selector)
grep "tm_roles_list_bundled" macos/Sources/Teammux/Setup/TeamBuilderView.swift

# Verify S10 (completion UI)
ls macos/Sources/Teammux/RightPane/CompletionCardView.swift

# Verify S11 (dispatch UI)
ls macos/Sources/Teammux/RightPane/DispatchView.swift
```
ALL three checks must pass. If any fail, the upstream stream has not merged — wait.

## Merge order context
S12 is the **last stream** to merge. Depends on S9, S10, and S11 all merging first.
This is the heaviest coordination point in the sprint.

## Done when
- `./build.sh` passes end to end
- All integration tests pass
- All TD items updated correctly (TD10-TD14 RESOLVED, TD15-TD18 OPEN confirmed)
- CLAUDE.md updated: v0.1.3 marked as shipped
- V013_SPRINT.md: all streams marked complete
- PR raised from `feat/v013-stream-s12-polish`

## Core rules
- NEVER modify `src/` (Ghostty upstream)
- ALL `tm_*` calls go through `EngineClient.swift` only
- NO force-unwraps in production code
- `engine/include/teammux.h` is the authoritative C API contract
- `roles/` is local only — no external network fetching ever
- Both `zig build test` AND `./build.sh` must pass before raising PR
- TECH_DEBT.md is the authoritative debt tracker — update it carefully
