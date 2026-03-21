## Finding 7-1: Failed conflict finalization disables git enforcement for an active worker
**Severity:** CRITICAL
**File:** engine/src/main.zig:2207
**Description:** `tm_conflict_finalize()` destroys the role watcher and removes the worker's `.git-wrapper` before it calls `merge_coordinator.finalizeMerge()`. If `finalizeMerge()` returns `error.UnresolvedConflicts` or `error.GitFailed`, the merge stays active and the worker stays in the roster, but the interceptor and watcher are already gone.
**Risk:** A failed finalize attempt leaves an active worker without PATH-based git enforcement. Subsequent `git add`, `git commit -a`, `git stash`, `git apply`, and direct pushes run against the real `git` binary and bypass ownership restrictions and PR-only workflow enforcement until some later reinstall happens.
**Recommendation:** Move role-watcher teardown and interceptor removal into the success path only, after `finalizeMerge()` returns `.success` or `.cleanup_incomplete`. If pre-cleanup is required for branch/worktree deletion, restore the wrapper and watcher whenever finalize returns an error.

## Finding 7-2: finalizeMerge reintroduces raw roster-pointer access on a production path
**Severity:** IMPORTANT
**File:** engine/src/merge.zig:412
**Description:** The new `finalizeMerge()` path calls `roster.getWorker(worker_id)` and mutates `worker.status` directly. `worktree.zig` documents `getWorker()` as an unlocked, test-only helper, and the rest of the merge code was already migrated to `copyWorkerFields()` plus `setWorkerStatus()` to avoid raw roster pointers in production.
**Risk:** Finalize can race with concurrent roster readers or mutations and observe stale or freed worker storage, producing missed status updates, cleanup against invalid paths, or crashes in the conflict-finalization path. This regresses the roster-locking hardening that v0.1.6 introduced elsewhere.
**Recommendation:** Mirror `approve()`/`reject()`: copy `branch_name` and `worktree_path` via `copyWorkerFields()`, then update the worker state through `setWorkerStatus()`. Add a finalize-specific regression test that exercises conflict finalization while roster reads/dismissal are occurring.
