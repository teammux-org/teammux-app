# Audit Summary — Domain 4: Reliability & Error Handling

## Severity Counts
- CRITICAL: 1
- IMPORTANT: 5
- SUGGESTION: 1
- TOTAL: 7

## Top 3 Issues
1. [CRITICAL] Command watcher stores a freed commands directory path — the watcher can dereference freed memory as soon as `tm_commands_watch()` starts it — engine/src/main.zig:148
2. [IMPORTANT] last_error is mutated from background threads without synchronization — watcher and polling threads can race `tm_engine_last_error()` and corrupt or stale out user-visible errors — engine/src/main.zig:173
3. [IMPORTANT] sessionStart leaks partial engine state on initialization failure — failed startup leaves partially initialized subsystems attached to the engine with no rollback path — engine/src/main.zig:127

## Recommended Sprint Allocation
- Audit-address sprint: Command watcher stores a freed commands directory path; sessionStart leaks partial engine state on initialization failure; last_error is mutated from background threads without synchronization; Merge cleanup drops git failures silently
- v0.1.5: PR_READY and PR_STATUS delivery failures only log warnings; Swift helper paths can preserve stale lastError despite the 20 cleared API wrappers
- v0.2 / defer: Worktree cleanup forgets orphaned paths before git removal succeeds

## Systemic Patterns
The recurring pattern is best-effort reliability in code paths that actually define system truth. Startup mutates shared engine fields incrementally instead of staging and committing atomically, cleanup helpers often discard git failures after user-visible state has already advanced, and shared error state is treated as a mutable global across threads. That combination makes the system resilient to some transient failures but also makes divergence between UI state, engine state, and filesystem state hard to detect and recover from once something goes wrong.
