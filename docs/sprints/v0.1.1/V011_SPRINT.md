# Teammux — v0.1.1 Sprint Master Spec

**Version:** v0.1.1
**Built on:** v0.1.0 (tagged, shipped)
**Date:** March 2026

---

## 1. Sprint Overview

- **Version:** v0.1.1
- **Built on:** v0.1.0 (tagged, shipped)
- **Goal:** Resolve all v0.1.0 tech debt + ship MergeCoordinator and Team Lead review workflow
- **Session structure:** 5 parallel streams + 1 main thread orchestrator
- **Merge order:** stream-A1 → stream-A2 → stream-B1 → stream-B2 → stream-C1

---

## 2. Stream Map

| Stream | Worktree path | Branch name | Owns | Depends on | Merges after |
|--------|---------------|-------------|------|------------|--------------|
| stream-A1 | ../teammux-stream-a1 | feat/v011-stream-a1-bus-debt | TD1 + TD4 (bus.zig retry + git_commit capture) | nothing | can merge first |
| stream-A2 | ../teammux-stream-a2 | feat/v011-stream-a2-github-debt | TD2 + TD3 (webhook retry + polling fallback) | nothing | can merge first (parallel with A1) |
| stream-B1 | ../teammux-stream-b1 | feat/v011-stream-b1-merge-engine | TD5 (merge.zig + teammux.h additions) | A1 merged (tm_message_cb change must be on main first) | after A1 |
| stream-B2 | ../teammux-stream-b2 | feat/v011-stream-b2-merge-bridge | TD6 (Swift EngineClient tm_merge_* bridge) | B1 merged (needs new header) | after B1 |
| stream-C1 | ../teammux-stream-c1 | feat/v011-stream-c1-review-ui | TD7 (Team Lead review workflow UI) | B2 merged (needs EngineClient additions) | after B2 |

---

## 3. Detailed Scope Per Stream

### stream-A1 — Bus Debt

**TD1: Bus retry**
- tm_message_cb currently returns void — change to tm_result_t
- This is a BREAKING change to engine/include/teammux.h
- Update bus.zig: on callback return TM_ERR_*, retry up to 3 times with exponential backoff: 1s, 2s, 4s
- Update EngineClient.swift: callback signature updated to match
- Update all call sites in EngineClient.swift atomically
- All bus tests updated and passing

**TD4: git_commit capture**
- In bus.zig, before persisting each message to JSONL log, run: `git -C {project_root} rev-parse HEAD`
- Capture stdout, trim whitespace, store as git_commit field
- If git command fails (not a git repo, no commits), store null
- Add test: message logged with non-null git_commit in a git repo

### stream-A2 — GitHub Debt

**TD2: Webhook retry**
- In github.zig, after first gh webhook forward attempt fails: log the failure, wait 5s, retry exactly once
- If second attempt also fails: log and proceed to TD3 fallback
- Add test: mock gh failure, verify retry occurs after 5s

**TD3: Polling fallback**
- After TD2 retry exhausted: spawn a background thread that calls `gh api repos/{repo}/events` every 60s
- Parse response JSON for push/pr events relevant to worker branches
- Fire tm_github_event_cb for each relevant event
- On tm_github_webhooks_stop: terminate polling thread cleanly
- Add test: polling thread starts after webhook failure, stops cleanly on webhooks_stop

### stream-B1 — MergeCoordinator Engine

**New module:** engine/src/merge.zig

**New C API additions to engine/include/teammux.h:**

```c
typedef enum {
    TM_MERGE_PENDING = 0,
    TM_MERGE_IN_PROGRESS = 1,
    TM_MERGE_SUCCESS = 2,
    TM_MERGE_CONFLICT = 3,
    TM_MERGE_REJECTED = 4,
} tm_merge_status_e;

typedef struct {
    const char* file_path;
    const char* conflict_type;
    const char* ours;
    const char* theirs;
} tm_conflict_t;

tm_result_t tm_merge_approve(tm_engine_t* engine, uint32_t worker_id,
                              const char* strategy);
tm_result_t tm_merge_reject(tm_engine_t* engine, uint32_t worker_id);
tm_merge_status_e tm_merge_get_status(tm_engine_t* engine,
                                       uint32_t worker_id);
tm_conflict_t** tm_merge_conflicts_get(tm_engine_t* engine,
                                        uint32_t worker_id,
                                        uint32_t* count);
void tm_merge_conflicts_free(tm_conflict_t** conflicts, uint32_t count);
```

**merge.zig responsibilities:**
- tm_merge_approve: run git merge or git rebase of worker branch into main, detect conflicts, update status
- tm_merge_reject: git worktree remove + git branch -D, update roster status to dismissed
- tm_merge_get_status: return current merge status for worker
- tm_merge_conflicts_get: parse git conflict markers, return structured conflict list
- On merge success: remove worktree, delete branch, notify roster
- All merge operations run via std.process.Child (git CLI)
- Full tests with tmpdir + real git operations

### stream-B2 — MergeCoordinator Swift Bridge

**EngineClient.swift additions:**
- Wrap all 5 new tm_merge_* functions
- `@Published var mergeStatuses: [UInt32: MergeStatus] = [:]`
- `@Published var pendingConflicts: [UInt32: [ConflictInfo]] = [:]`
- `func approveMerge(workerId: UInt32, strategy: MergeStrategy) -> Bool`
- `func rejectMerge(workerId: UInt32) -> Bool`
- `func getMergeStatus(workerId: UInt32) -> MergeStatus`
- Swift enums MergeStatus and MergeStrategy matching C enums
- Swift struct ConflictInfo matching tm_conflict_t
- No UI changes — UI is stream-C1's job
- Tests: EngineClient merge method unit tests

### stream-C1 — Team Lead Review UI

**Worker branch rows — add:**
- Approve button → `engine.approveMerge(workerId, strategy: .merge)`
- Reject button → `engine.rejectMerge(workerId)`
- Merge status indicator (pending/in-progress/success/conflict/rejected)
- Status updates reactively from engine.mergeStatuses

**Conflict resolution view — new ConflictView.swift:**
- Appears when engine.pendingConflicts[workerId] is non-empty
- Lists conflicting files with ours/theirs preview
- Resolve button per conflict (selects ours or theirs)
- "Force merge" option for Team Lead override

**History view additions to GitView.swift:**
- Section("Completed") showing merged worker branches
- Each row: worker name + task + merge timestamp + commit hash
- Reads from engine.messages filtered by completion type

**Team Lead terminal context:**
- When a worker branch is pending review, Team Lead terminal shows a subtle banner: "Worker {name} is ready for review"
- Banner dismissed when approved or rejected

---

## 4. Shared Rules for All Streams

- Never modify src/ (Ghostty upstream)
- All tm_* calls stay in EngineClient.swift only
- No force-unwraps in production code
- Every PR must pass `zig build test` (engine streams) or Swift test suite (Swift streams) before raising PR
- Read engine/include/teammux.h on main before starting — it is the authoritative contract

---

## 5. Known Risks

- TD1 is a breaking API change. stream-A1 must update header, engine, and Swift bridge atomically. If A1 merges without the Swift update, the app will not compile.
- stream-B1 adds new functions to teammux.h. stream-B2 must pull main after B1 merges before implementing the bridge.
- stream-C1 must pull main after B2 merges — it depends on EngineClient additions that do not exist until B2 lands.

---

## 6. Merge Checklist (main thread runs this for each PR)

- [ ] Branch is based on current main (no rebase needed)
- [ ] All tests pass
- [ ] No src/ modifications
- [ ] No force-unwraps (Swift streams)
- [ ] tm_* calls confined to EngineClient.swift (Swift streams)
- [ ] Zero conflicts with main
- [ ] TECH_DEBT.md items marked RESOLVED for completed items
