# Stream T16 — Integration Tests + Docs + v0.1.4 Shipped

## Your branch
feat/v014-t16-polish

## Your worktree path
../teammux-stream-t16

## Read first
- CLAUDE.md — hard rules, build commands, sprint workflow
- TECH_DEBT.md — TD15-TD20 should be RESOLVED, TD21-TD24 remain OPEN
- V014_SPRINT.md — full sprint spec, Section 4 has your detailed scope

## WAIT CHECK
You MUST confirm T13, T14, AND T15 have ALL been merged to main before starting implementation.
All 15 prior streams must be merged. Run:
```
git pull origin main
git log --oneline -20
```
Verify all 15 stream merge commits are present.

## Your mission

**Integration tests (engine level):**
1. Worktree create/path/branch/remove end-to-end with real git
2. /teammux-ask routes to Team Lead PTY only (not target worker)
3. /teammux-delegate routes directly to target worker PTY only
4. /teammux-pr-ready triggers gh pr create (mocked), PR URL in bus
5. JSONL append + load round-trip survives between engine inits
6. exit 126 on all four enforcement types (add, commit-a, stash-pop, push-main)
7. TD18: ownership registry and interceptor wrapper both updated after mock hot-reload
8. config.toml worktree_root override respected

**Documentation:**
- TECH_DEBT.md: TD15-TD20 RESOLVED (verify each is actually complete before marking), TD21-TD24 OPEN confirmed
- CLAUDE.md: v0.1.4 marked as shipped
- V014_SPRINT.md: all 16 streams marked complete

## Message type registry (v0.1.4 additions)

Existing types (do not reuse):
- TM_MSG_TASK=0, TM_MSG_INSTRUCTION=1, TM_MSG_CONTEXT=2, TM_MSG_STATUS_REQ=3
- TM_MSG_STATUS_RPT=4, TM_MSG_COMPLETION=5, TM_MSG_ERROR=6, TM_MSG_BROADCAST=7
- TM_MSG_QUESTION=8, TM_MSG_DISPATCH=10, TM_MSG_RESPONSE=11

New in v0.1.4:
- TM_MSG_PEER_QUESTION = 12 (T2)
- TM_MSG_DELEGATION = 13 (T2)
- TM_MSG_PR_READY = 14 (T7)
- TM_MSG_PR_STATUS = 15 (T7)

## Merge order context
T16 merges LAST — after all 15 other streams.

## Done when
- ./build.sh passes end to end
- zig build test all pass (report count)
- All 8 integration tests pass
- TECH_DEBT.md final state correct
- PR raised from feat/v014-t16-polish

## Core rules
- Never modify src/ (Ghostty upstream)
- All tm_* calls go through EngineClient.swift only
- No force-unwraps in production code
- zig build test AND ./build.sh must pass before raising PR
- engine/include/teammux.h is the authoritative C API contract
- roles/ is local only — no external network fetching
- TECH_DEBT.md updated when new debt discovered
- Message type values: do NOT reuse or skip — check registry above
