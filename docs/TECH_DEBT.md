# Teammux — Known Technical Debt

## v0.1.1 — Resolved

| ID  | Module          | Issue                              | Stream    | Breaking | Status   |
|-----|-----------------|------------------------------------|-----------|----------|----------|
| TD1 | bus.zig         | Message retry not implemented      | stream-A1 | YES      | RESOLVED |
| TD2 | github.zig      | Webhook retry after 5s not done    | stream-A2 | NO       | RESOLVED |
| TD3 | github.zig      | 60s polling fallback not done      | stream-A2 | NO       | RESOLVED |
| TD4 | bus.zig         | git_commit always null in messages | stream-A1 | NO       | RESOLVED |
| TD5 | merge.zig       | MergeCoordinator not implemented   | stream-B1 | YES      | RESOLVED |
| TD6 | EngineClient    | tm_merge_* bridge missing          | stream-B2 | NO       | RESOLVED |
| TD7 | GitView.swift   | Team Lead review UI not built      | stream-C1 | NO       | RESOLVED |
| TD8 | ConflictInfo    | conflictType as String not enum    | stream-R7 | NO       | RESOLVED |

## v0.1.2 — Resolved

| ID  | Module          | Issue                                                             | Stream    | Breaking | Status   |
|-----|-----------------|-------------------------------------------------------------------|-----------|----------|----------|
| TD9 | interceptor.zig | PTY git wrapper installed but PATH injection not wired            | stream-R8 | NO       | RESOLVED |

## v0.1.3 — Resolved

| ID   | Module                      | Issue                                                              | Stream | Breaking | Status   |
|------|-----------------------------|--------------------------------------------------------------------|--------|----------|----------|
| TD10 | hotreload.zig               | Role hot-reload for active workers not implemented                 | S4/S7  | NO       | RESOLVED |
| TD11 | SpawnPopoverView            | Role selector UI deferred                                          | S9     | NO       | RESOLVED |
| TD12 | interceptor.zig             | git commit -a bypasses interceptor                                 | S1     | NO       | RESOLVED |
| TD13 | commands.zig / EngineClient | /teammux-complete and /teammux-question have no Swift-side handlers| S2/S6  | NO       | RESOLVED |
| TD14 | TeamBuilderView             | Role picker in setup flow deferred                                 | S3/S9  | NO       | RESOLVED |

## v0.1.4 — Resolved

| ID   | Module                      | Issue                                                              | Stream | Breaking | Status   |
|------|-----------------------------|--------------------------------------------------------------------|--------|----------|----------|
| TD15 | coordinator.zig             | Worker-to-worker direct messaging not routed                       | T2/T9  | NO       | RESOLVED |
| TD16 | LiveFeedView                | Completion history not persisted across sessions                   | T5/T10 | NO       | RESOLVED |
| TD17 | interceptor.zig             | git stash / git apply bypass not intercepted                       | T3     | NO       | RESOLVED |
| TD18 | hotreload.zig               | Role hot-reload does not update ownership registry                 | T4     | NO       | RESOLVED |
| TD19 | interceptor.zig             | Interceptor exit code indistinguishable from git errors            | T3     | NO       | RESOLVED |
| TD20 | EngineClient                | lastError is shared mutable state — stale errors bleed across calls| T6     | NO       | RESOLVED |

## v0.1.4 — New debt introduced this sprint

| ID   | Module                   | Issue                                                            | Target | Breaking | Status |
|------|--------------------------|------------------------------------------------------------------|--------|----------|--------|
| TD21 | worktree_lifecycle.zig   | Dangling worktrees if engine crashes mid-spawn                   | v0.2   | NO       | OPEN   |
| TD22 | SessionState.swift       | Session restore does not re-establish ownership registry state   | v0.2   | NO       | OPEN   |
| TD23 | ContextView.swift        | CLAUDE.md rendered as plain text, not true markdown              | v0.1.5 | NO       | OPEN   |
| TD24 | history.zig              | JSONL log grows unbounded across sessions, no rotation           | v0.2   | NO       | OPEN   |
| TD25 | interceptor.zig          | Push-to-main block does not parse refspecs (HEAD:main bypasses)  | AA3    | NO       | RESOLVED |
| TD26 | TeamMessage / CoordTypes | PRState and PRStatus model same concept with divergent colors    | v0.1.5 | NO       | OPEN   |
| TD27 | ContextView.swift        | Hot-reload repeat within 3s window not detected by onChange      | v0.1.5 | NO       | OPEN   |
| TD28 | ContextView.swift        | Diff highlight uses positional comparison, not LCS/Myers diff   | v0.1.5 | NO       | OPEN   |
## Audit-address sprint — New debt introduced

| ID   | Module                   | Issue                                                                              | Target | Breaking | Status |
|------|--------------------------|------------------------------------------------------------------------------------|--------|----------|--------|
| TD29 | teammux.h                | 15 dead C exports have no deprecation annotation in the header                     | v0.2   | NO       | OPEN   |
| TD30 | teammux.h                | TM_ERR_PTY (6) is defined but no function returns it after PTY removal             | v0.2   | NO       | OPEN   |
| TD31 | EngineClient.swift       | approveMerge/rejectMerge treat TM_ERR_CLEANUP_INCOMPLETE as hard failure           | v0.1.5 | NO       | RESOLVED |
| TD32 | merge.zig                | runGitLogged captures exit code but not git stderr for cleanup failure diagnostics  | v0.1.5 | NO       | RESOLVED |
| TD33 | merge.zig / coordinator.zig | getWorker() returns raw pointer without lock in production paths                | v0.2   | NO       | OPEN   |
| TD34 | main.zig (tm_roster_get) | Roster iteration uses raw pointers without holding roster mutex                    | v0.2   | NO       | OPEN   |
| TD35 | worktree.zig             | Roster.claimNextId leaks ID slot when subsequent spawn step fails                  | v0.2   | NO       | OPEN   |
| TD36 | main.zig                 | tm_interceptor_path worker 0 OOM returns null without setError                     | v0.1.5 | NO       | OPEN   |
| TD37 | main.zig                 | sessionStop Team Lead interceptor cleanup failure not surfaced                     | v0.1.5 | NO       | OPEN   |

## v0.1.5 S2 — New debt introduced (TD31/TD32 fix)

| ID   | Module                   | Issue                                                                              | Target | Breaking | Status |
|------|--------------------------|------------------------------------------------------------------------------------|--------|----------|--------|
| TD38 | GitView / ConflictView   | UI callers don't surface CLEANUP_INCOMPLETE warning — lastError only checked on !success | v0.1.5 | NO       | OPEN   |
| TD39 | merge.zig (test)         | cleanup_incomplete integration test is non-deterministic — accepts both outcomes    | v0.2   | NO       | OPEN   |

## Notes
- TD15: Worker-to-worker messaging ships in two modes — questions route via Team Lead relay (/teammux-ask), task delegation routes direct (/teammux-delegate). T2 adds engine routing, T9 adds Swift bridge and feed cards.
- TD16: CompletionReport and QuestionRequest cards ephemeral across sessions. T5 adds history.zig JSONL persistence, T10 adds Swift bridge loading on sessionStart with collapsible history section in LiveFeedView.
- TD17: git stash pop and git apply can restore denied files. T3 adds interception alongside exit 126 fix (TD19) and push-to-main block.
- TD18: Role TOML hot-reload updates CLAUDE.md but not FileOwnershipRegistry. T4 extends hotreload.zig callback to call ownership_update and re-installs interceptor with new deny patterns atomically.
- TD19: Interceptor wrapper uses exit 1 for enforcement — indistinguishable from real git errors. T3 changes all enforcement blocks to exit 126 (POSIX reserved for "command cannot execute").
- TD20: EngineClient.lastError written by 50+ methods — stale errors bleed. T6 adds clear at method entry (minimal correct fix). Full Result<T, EngineError> migration deferred to future sprint.
- TD21: tm_worktree_create creates directory and branch. On engine crash mid-spawn, worktree directory and branch may be left on disk. Recovery scan at engine init deferred to v0.2.
- TD22: SessionState.swift restores worker roster and spawns workers into existing worktrees. FileOwnershipRegistry is rebuilt at spawn time from the role definition — but deny patterns from any runtime ownership changes (direct tm_ownership_register calls) are lost. Full registry snapshot deferred to v0.2.
- TD23: ContextView renders CLAUDE.md as plain text with bold section headers (## prefix detection). True markdown rendering with a SwiftUI-compatible renderer deferred to v0.1.5 to avoid adding a dependency.
- TD24: completion_history.jsonl is append-only and grows across all sessions. Log rotation (max size, archive old entries) deferred to v0.2. Risk is low for initial usage.
- TD25: Push-to-main interceptor matches literal "main"/"master" tokens in $@. Refspec syntax (git push origin HEAD:main, refs/heads/feature:refs/heads/master) bypasses the check. Defense-in-depth only — workers operate in isolated worktrees on teammux/* branches. Full refspec destination parsing deferred to v0.2.
- TD26: PRState (TeamMessage.swift, maps to tm_pr_state_t) and PRStatus (CoordinationTypes.swift, bus message workflow) both represent PR lifecycle state. PRState.closed is red, PRStatus.closed is grey. Unify into one type with consistent colors in v0.1.5.
- TD27: ContextView observes hotReloadedWorkers via onChange, but Set.insert on an already-present element is a no-op — the Set doesn't mutate, so onChange doesn't fire. Rapid saves within the 3-second hot-reload window only show the first change. Fix requires engine to expose a reload counter or timestamp per worker. Refresh button works as manual workaround.
- TD28: applyDiffHighlight compares old and new lines by positional index. An insertion near the top marks all subsequent shifted lines as changed. LCS-based diff would highlight only truly changed lines. Acceptable for a 2-second transient highlight but visually noisy on insertions/deletions.
- TD29: AA6 marked 15 exports in main.zig with "NO SWIFT CALLER — candidate for removal in v0.2" but the authoritative header (teammux.h) still declares them without any deprecation annotation. Add matching comments in the header so consumers of the C API are aware. Exports: tm_worktree_create, tm_worktree_remove, tm_peer_question, tm_peer_delegate, tm_worker_complete, tm_worker_question, tm_completion_free, tm_question_free, tm_history_clear, tm_ownership_get, tm_ownership_free, tm_ownership_update, tm_interceptor_remove, tm_agent_resolve, tm_result_to_string.
- TD30: AA6 removed tm_pty_send and tm_pty_fd (I18). TM_ERR_PTY=6 remains in tm_result_t and tm_result_to_string but is no longer returned by any function. Remove or mark as reserved in v0.2.
- TD31: EngineClient.swift approveMerge (line 895) and rejectMerge (line 922) use `guard result == TM_OK` which treats TM_ERR_CLEANUP_INCOMPLETE (15) as total failure. The merge/reject itself succeeded — only worktree/branch cleanup failed. Swift should treat code 15 as partial success (return true, log warning, let user know manual cleanup may be needed). Introduced by AA4 fix I12.
- TD32: runGitLogged in merge.zig calls runGitCapture which sets stderr_behavior = .Ignore. Cleanup failure logs show operation name and exit code but not git's actual error message (e.g. "fatal: '/path' is not a working tree"). Adding stderr capture would improve debuggability for users told to do manual cleanup. Low priority — current logging is a major improvement over the previous silent discard.
- TD33: merge.zig approve/reject (lines 84, 143, 219) and coordinator.zig dispatchTask (line 87) call roster.getWorker() without lock protection. Same race as audit finding I3 — concurrent dismiss can free worker strings while these functions read them. Line 143 is a write through the raw pointer (status mutation). AA2 stream scoped I3 fix to main.zig callers only. Migrate these to copyWorkerFields/hasWorker in v0.2.
- TD34: tm_roster_get iterates e.roster.workers via .iterator() and passes entry.value_ptr (raw internal pointer) to fillCWorkerInfo without holding the roster mutex. A concurrent dismiss during iteration can free worker strings mid-copy. Either hold the mutex for the full iteration or copy all workers via copyWorkerFields first.
- TD35: Roster.claimNextId() permanently increments next_id. If worktree_lifecycle.create or roster.spawn fails afterward, the ID slot is consumed with no worker registered. Over repeated failures, IDs increment without bound and gaps appear in the sequence. Fix: add an unclaimId() method or defer ID claim until after worktree creation succeeds. Low risk — IDs are u32, gaps are cosmetic.
- TD36: tm_interceptor_path for worker 0 calls std.heap.c_allocator.dupeZ. On OOM, it frees the path and returns null without calling setError. Swift interprets null as "no interceptor installed" rather than "allocation failed", masking the root cause. Fix: add setError before returning null.
- TD37: sessionStop calls interceptor.remove for the Team Lead wrapper. On failure, the error is logged via std.log.warn but not stored via setError. The orphaned .git-wrapper directory in project root can interfere with manual git usage after the app exits. Fix: call setError so Swift can surface a notification, or retry cleanup.
- TD38: S2 TD31 fix sets lastError on the CLEANUP_INCOMPLETE path (code 15) so the UI can surface it, but GitView.approveMerge (line 411), GitView.rejectMerge (line 422), GitView PREventCard.approveMerge (line 562), PREventCard.rejectMerge (line 576), and ConflictView.forceMerge (line 128) all only read lastError inside `if !success`. Since code 15 returns true, the warning is never displayed. Fix: check lastError on the success path too and show it as a non-fatal banner/toast.
- TD39: merge.zig test "approve returns cleanup_incomplete when worktree already removed" (line ~810) asserts `result == .cleanup_incomplete or result == .success`. The pre-removed worktree may or may not cause branch delete to also fail, making the test non-deterministic. It does not reliably exercise the cleanup_incomplete return path. Fix: also pre-delete the branch before approve to guarantee cleanup failure, or split into two deterministic tests.
- Merge order v0.1.4: T1-T7 (parallel Wave 1) → T8-T12 (Wave 2, each waits on specific Wave 1 dep) → T13-T15 (Wave 3) → T16 (last)
- Message type enum v0.1.4 additions: TM_MSG_PEER_QUESTION=12, TM_MSG_DELEGATION=13, TM_MSG_PR_READY=14, TM_MSG_PR_STATUS=15
- Worktree root: defaults to ~/.teammux/worktrees/{SHA256(project_path)}/{worker_id}/. Configurable via config.toml key worktree_root.
