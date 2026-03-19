# Stream T7 — PR Creation Workflow Engine

## Your branch
feat/v014-t7-pr-workflow-engine

## Your worktree path
../teammux-stream-t7

## Read first
- CLAUDE.md — hard rules, build commands, sprint workflow
- TECH_DEBT.md — no specific TD, but new message types TM_MSG_PR_READY=14 and TM_MSG_PR_STATUS=15
- V014_SPRINT.md — full sprint spec, Section 4 has your detailed scope

## Your mission

**Files:** engine/src/commands.zig, engine/src/github.zig, engine/include/teammux.h, engine/src/main.zig

**New command `/teammux-pr-ready`:**
JSON: {"title": "...", "summary": "...", "branch": "teammux/worker-2-auth"}

Engine action:
1. Parse command file
2. Call: gh pr create --base main --head {branch} --title "{title}" --body "{summary}" --json url
3. Parse JSON stdout for url field
4. Route TM_MSG_PR_READY=14 through bus with payload: {"worker_id": N, "pr_url": "...", "branch": "...", "title": "..."}

On gh failure: route TM_MSG_ERROR with failure message.

**github.zig extension:** Existing webhook polling extended to detect PR status changes on teammux/* branches. On open/merged/closed status change: route TM_MSG_PR_STATUS=15 with payload: {"pr_url": "...", "status": "merged"|"closed"|"open", "worker_id": N}.

**New C API:**
```c
tm_result_t tm_pr_create(tm_engine_t* engine,
                          uint32_t worker_id,
                          const char* title,
                          const char* body,
                          const char* branch);
```

**Tests:** command file parsed correctly, gh args formatted correctly (mocked), PR URL extracted from JSON, bus routing with correct message type, webhook status change detected.

## Message type registry (v0.1.4 additions)

Existing types (do not reuse):
- TM_MSG_TASK=0, TM_MSG_INSTRUCTION=1, TM_MSG_CONTEXT=2, TM_MSG_STATUS_REQ=3
- TM_MSG_STATUS_RPT=4, TM_MSG_COMPLETION=5, TM_MSG_ERROR=6, TM_MSG_BROADCAST=7
- TM_MSG_QUESTION=8, TM_MSG_DISPATCH=10, TM_MSG_RESPONSE=11

New in v0.1.4:
- TM_MSG_PEER_QUESTION = 12 (T2)
- TM_MSG_DELEGATION = 13 (T2)
- TM_MSG_PR_READY = 14 (T7 — YOU OWN THIS)
- TM_MSG_PR_STATUS = 15 (T7 — YOU OWN THIS)

## Merge order context
Wave 1 (parallel) — you can START NOW, no dependencies.
T1-T7 merge first, then Wave 2 (T8-T12), Wave 3 (T13-T15), T16 last.
Note: T2 and T7 both add message type values. Any stream touching the enum must pull main after both T2 and T7 merge.

## Done when
- zig build test all pass
- /teammux-pr-ready triggers gh pr create (mocked in tests)
- PR URL appears in bus message payload
- Webhook PR status changes route TM_MSG_PR_STATUS
- PR raised from feat/v014-t7-pr-workflow-engine

## Core rules
- Never modify src/ (Ghostty upstream)
- All tm_* calls go through EngineClient.swift only
- No force-unwraps in production code
- zig build test must pass before raising PR
- engine/include/teammux.h is the authoritative C API contract
- roles/ is local only — no external network fetching
- TECH_DEBT.md updated when new debt discovered
- Message type values: do NOT reuse or skip — check registry above
