# Stream AA2 — Concurrency & Locking

## Context

Read these files before doing anything else (in parallel):
- CLAUDE.md
- docs/TECH_DEBT.md
- docs/codex-audits/audit-001-post-v014/ACTION-PLAN.md
  (read findings I2, I3, I10 in full)
- engine/src/ownership.zig
- engine/src/worktree.zig
- engine/src/main.zig
- engine/include/teammux.h

Then run: cd engine && zig build test
Confirm 356 tests pass before writing any code.

## Your Task

Fix three unprotected shared state bugs. All are the
same pattern: internal data returned or mutated without
adequate mutex protection.

## Fix I2 — Ownership slices escape registry lock
**File:** engine/src/ownership.zig:113,
          engine/src/main.zig:2003
**Problem:** getRules() returns a registry-owned slice
after releasing the mutex. Concurrent hot-reload mutates
the same data from its watcher thread.
**Fix:**
1. Add a new pub fn copyRules(worker_id, allocator):
   - Lock mutex
   - Duplicate the rules slice and all pattern strings
     into caller-owned memory
   - Unlock
   - Return the copy (caller must free)
2. Replace all getRules() callers (tm_ownership_get,
   tm_interceptor_install) with copyRules()
3. Remove or make private the original getRules()

## Fix I3 — Roster.getWorker returns raw pointer without lock
**File:** engine/src/worktree.zig:145
**Problem:** getWorker() returns workers.getPtr() with no
lock. A concurrent dismiss frees worker strings while a
background thread (CommandWatcher -> busSendBridge) reads
the same worker's fields.
**Fix:**
1. Add a pub fn copyWorkerFields(id) ?WorkerFields where
   WorkerFields is a plain struct of owned copies of needed
   fields (worktree_path, branch_name, name, task_description)
2. copyWorkerFields holds the mutex during the copy
3. Caller frees the owned strings after use
4. Update all getWorker() call sites in main.zig to use
   copyWorkerFields or withWorkerLocked pattern

## Fix I10 — last_error mutated from background threads
**File:** engine/src/main.zig:154
**Problem:** CommandWatcher and GitHub polling call
setError() from background threads while Swift reads
tm_engine_last_error() on @MainActor. No mutex protects
last_error or last_error_cstr.
**Fix:**
1. Add a Mutex field to Engine struct: last_error_mutex
2. In setError(): acquire mutex before freeing and
   replacing last_error_cstr, release after
3. In tm_engine_last_error(): acquire mutex before
   reading last_error_cstr, release after
4. Initialize mutex in Engine.create(), deinit in
   Engine.destroy()

## Commit Sequence

Commit 1: ownership.zig — copyRules copy-out API,
           update all callers (I2)
Commit 2: worktree.zig — copyWorkerFields locked API,
           update all callers in main.zig (I3)
Commit 3: main.zig — last_error mutex protection (I10)

After each commit:
  cd engine && zig build
  cd engine && zig build test
All 356 tests must pass before next commit.

## Definition of Done

- No registry-owned slice returned after mutex release
- No raw internal worker pointer returned without lock
- last_error reads and writes both hold the mutex
- All callers updated to new APIs
- 356 tests passing
- No changes to public teammux.h API contracts
- No changes to macos/

Raise PR from fix/aa2-concurrency-locking against main.
Do NOT merge. Report back with PR link.
