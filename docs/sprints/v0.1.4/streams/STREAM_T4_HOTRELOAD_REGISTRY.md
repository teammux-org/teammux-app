# Stream T4 — TD18: Hot-Reload Updates Ownership Registry

## Your branch
feat/v014-t4-hotreload-registry

## Your worktree path
../teammux-stream-t4

## Read first
- CLAUDE.md — hard rules, build commands, sprint workflow
- TECH_DEBT.md — TD18 is your target (ownership sync + interceptor update)
- V014_SPRINT.md — full sprint spec, Section 4 has your detailed scope

## Your mission

**Files:** engine/src/hotreload.zig, engine/src/ownership.zig, engine/include/teammux.h, engine/src/main.zig

**New ownership.zig function:**
```zig
pub fn updateWorkerRules(self: *OwnershipRegistry,
    allocator: std.mem.Allocator,
    worker_id: WorkerId,
    write_patterns: []const []const u8,
    deny_patterns: []const []const u8) !void
```
Atomically replaces all rules for that worker — removes old entries, inserts new ones.

**hotreload.zig callback extension:** After generateRoleClaude succeeds, re-parse the updated role TOML with parseRoleDefinition, call ownership.updateWorkerRules with new patterns, then call tm_interceptor_install with new deny patterns to update the bash wrapper. Registry and PTY enforcement updated atomically.

**New C API:**
```c
tm_result_t tm_ownership_update(tm_engine_t* engine,
                                  uint32_t worker_id,
                                  const char** write_patterns, uint32_t write_count,
                                  const char** deny_patterns, uint32_t deny_count);
```

**Tests:** registry reflects updated deny patterns after mock hot-reload, old patterns removed, new interceptor wrapper contains new patterns, registry and wrapper consistent, failed parse does not corrupt registry.

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
- ownership registry updated atomically on hot-reload
- interceptor wrapper regenerated with new deny patterns
- PR raised from feat/v014-t4-hotreload-registry

## Core rules
- Never modify src/ (Ghostty upstream)
- All tm_* calls go through EngineClient.swift only
- No force-unwraps in production code
- zig build test must pass before raising PR
- engine/include/teammux.h is the authoritative C API contract
- roles/ is local only — no external network fetching
- TECH_DEBT.md updated when new debt discovered
- Message type values: do NOT reuse or skip — check registry above
