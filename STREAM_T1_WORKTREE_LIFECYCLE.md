# Stream T1 — Worktree Lifecycle Engine

## Your branch
feat/v014-t1-worktree-lifecycle

## Your worktree path
../teammux-stream-t1

## Read first
- CLAUDE.md — hard rules, build commands, sprint workflow
- TECH_DEBT.md — TD21 (dangling worktrees) is new debt you may discover
- V014_SPRINT.md — full sprint spec, Section 4 has your detailed scope

## Your mission

**Files:** engine/src/worktree_lifecycle.zig (new), engine/include/teammux.h, engine/src/main.zig

**Worktree root resolution:**
1. Check config.toml for `worktree_root = "/custom/path"` key
2. Default: `~/.teammux/worktrees/{SHA256(project_path)}/{worker_id}/`

**C API:**
```c
tm_result_t tm_worktree_create(tm_engine_t* engine,
                                uint32_t worker_id,
                                const char* task_description);
tm_result_t tm_worktree_remove(tm_engine_t* engine, uint32_t worker_id);
const char* tm_worktree_path(tm_engine_t* engine, uint32_t worker_id);
const char* tm_worktree_branch(tm_engine_t* engine, uint32_t worker_id);
```

**Branch naming:** slugify task_description — lowercase, spaces to hyphens, strip non-alphanum, truncate 40 chars, prefix `teammux/`.

**WorktreeRegistry struct:** AutoHashMap(WorkerId, WorktreeEntry) where WorktreeEntry has path and branch as owned strings.

**tm_worktree_create sequence:**
1. Read worktree_root from config or use default
2. mkdir -p {worktree_root}/
3. git worktree add {path} -b {branch} via std.process.Child
4. Store in WorktreeRegistry

**Engine integration:** tm_worker_spawn calls tm_worktree_create first. tm_worker_dismiss calls tm_worktree_remove after.

**Tests:** create/path/branch/remove lifecycle, slugify edge cases, config.toml override, git not found graceful error, worktree already exists handled.

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
Wave 1 (parallel) — you can START NOW, no dependencies.
T1-T7 merge first, then Wave 2 (T8-T12), Wave 3 (T13-T15), T16 last.

## Done when
- zig build test all pass
- tm_worktree_create creates real git worktree on disk
- tm_worktree_path returns correct absolute path
- tm_worktree_branch returns slugified branch name
- config.toml worktree_root override works
- PR raised from feat/v014-t1-worktree-lifecycle

## Core rules
- Never modify src/ (Ghostty upstream)
- All tm_* calls go through EngineClient.swift only
- No force-unwraps in production code
- zig build test must pass before raising PR
- engine/include/teammux.h is the authoritative C API contract
- roles/ is local only — no external network fetching
- TECH_DEBT.md updated when new debt discovered
- Message type values: do NOT reuse or skip — check registry above
