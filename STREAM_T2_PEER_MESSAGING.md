# Stream T2 — TD15: Worker-to-Worker Dual-Mode Messaging

## Your branch
feat/v014-t2-peer-messaging

## Your worktree path
../teammux-stream-t2

## Read first
- CLAUDE.md — hard rules, build commands, sprint workflow
- TECH_DEBT.md — TD15 is your target (worker-to-worker messaging)
- V014_SPRINT.md — full sprint spec, Section 4 has your detailed scope

## Your mission

**Files:** engine/src/commands.zig, engine/include/teammux.h, engine/src/main.zig, engine/src/bus.zig

**Two new commands:**

`/teammux-ask` (question via Team Lead relay):
- JSON: {"target_worker_id": N, "message": "..."}
- Routes to Team Lead PTY: \n[Teammux] worker-{from} → worker-{target}: {message}\n
- New type: TM_MSG_PEER_QUESTION = 12
- C API: tm_peer_question(engine, from_id, target_id, message)

`/teammux-delegate` (task delegation direct):
- JSON: {"target_worker_id": N, "task": "..."}
- Routes directly to target worker PTY: \n[Teammux] delegated task: {task}\n
- New type: TM_MSG_DELEGATION = 13
- C API: tm_peer_delegate(engine, from_id, target_id, task)

Both use command routing wrapper in main.zig (S5 pattern). Both new types added to bus.zig MessageType enum.

**Tests:** /teammux-ask routes to Team Lead PTY (not target), /teammux-delegate routes to target worker PTY (not Team Lead), invalid target_worker_id returns error, null safety.

## Message type registry (v0.1.4 additions)

Existing types (do not reuse):
- TM_MSG_TASK=0, TM_MSG_INSTRUCTION=1, TM_MSG_CONTEXT=2, TM_MSG_STATUS_REQ=3
- TM_MSG_STATUS_RPT=4, TM_MSG_COMPLETION=5, TM_MSG_ERROR=6, TM_MSG_BROADCAST=7
- TM_MSG_QUESTION=8, TM_MSG_DISPATCH=10, TM_MSG_RESPONSE=11

New in v0.1.4:
- TM_MSG_PEER_QUESTION = 12 (T2 — YOU OWN THIS)
- TM_MSG_DELEGATION = 13 (T2 — YOU OWN THIS)
- TM_MSG_PR_READY = 14 (T7)
- TM_MSG_PR_STATUS = 15 (T7)

## Merge order context
Wave 1 (parallel) — you can START NOW, no dependencies.
T1-T7 merge first, then Wave 2 (T8-T12), Wave 3 (T13-T15), T16 last.
Note: T2 and T7 both add message type values. Any stream touching the enum must pull main after both T2 and T7 merge.

## Done when
- zig build test all pass
- /teammux-ask message appears in Team Lead PTY only
- /teammux-delegate message appears in target worker PTY only
- PR raised from feat/v014-t2-peer-messaging

## Core rules
- Never modify src/ (Ghostty upstream)
- All tm_* calls go through EngineClient.swift only
- No force-unwraps in production code
- zig build test must pass before raising PR
- engine/include/teammux.h is the authoritative C API contract
- roles/ is local only — no external network fetching
- TECH_DEBT.md updated when new debt discovered
- Message type values: do NOT reuse or skip — check registry above
