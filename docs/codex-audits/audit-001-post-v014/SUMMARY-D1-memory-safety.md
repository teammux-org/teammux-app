# Audit Summary — Domain 1: Memory Safety

## Severity Counts
- CRITICAL: 2
- IMPORTANT: 4
- SUGGESTION: 1
- TOTAL: 7

## Top 3 Issues
1. [CRITICAL] Failed config reload leaves `e.cfg` pointing at freed storage — a failed `tm_config_reload()` can leave the engine holding a deinitialized config and later double-free it during teardown — engine/src/main.zig:352
2. [CRITICAL] `CommandWatcher` stores a borrowed commands path that `sessionStart` frees — the watcher keeps a dangling `commands_dir` slice and later dereferences it when command watching starts — engine/src/main.zig:148
3. [IMPORTANT] `GitHubClient` keeps a borrowed repo slice across config reloads — reload frees the config-owned repo string while polling and PR paths continue to use it — engine/src/main.zig:136

## Recommended Sprint Allocation
- Audit-address sprint: Failed config reload leaves `e.cfg` pointing at freed storage; `CommandWatcher` stores a borrowed commands path that `sessionStart` frees; `GitHubClient` keeps a borrowed repo slice across config reloads; Ownership rule slices escape the registry lock and can be invalidated mid-read; `Roster.getWorker()` returns raw worker pointers without read-side locking; `tm_config_get()` violates its documented C-string lifetime
- v0.1.5: Config parse cleanup leaks replaced default strings on error paths
- v0.2 / defer: none

## Systemic Patterns
The recurring pattern is lifetime ambiguity: temporary or config-owned slices are stored as if they were long-lived, and internal containers hand out raw pointers/slices without keeping the owning lock held through the copy. Those mistakes become memory-safety bugs once watcher threads and polling threads start reading the same structures concurrently with reload, dismiss, or hot-reload mutations.
