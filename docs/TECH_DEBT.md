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

## v0.1.4 — Open debt (target updated to v0.1.6)

| ID   | Module                   | Issue                                                            | Target | Breaking | Status  |
|------|--------------------------|------------------------------------------------------------------|--------|----------|---------|
| TD21 | worktree_lifecycle.zig   | Dangling worktrees if engine crashes mid-spawn                   | v0.1.6 | NO       | OPEN    |
| TD22 | SessionState.swift       | Session restore does not re-establish ownership registry state   | v0.2   | NO       | PARTIAL |
| TD24 | history.zig              | JSONL log grows unbounded across sessions, no rotation           | v0.1.6 | NO       | OPEN    |

## v0.1.5 — Resolved

| ID   | Module                   | Issue                                                         | Stream | Breaking | Status   |
|------|--------------------------|---------------------------------------------------------------|--------|----------|----------|
| TD23 | ContextView.swift        | CLAUDE.md rendered as plain text, not true markdown           | S6     | NO       | RESOLVED |
| TD25 | interceptor.zig          | Push-to-main block does not parse refspecs                    | AA3    | NO       | RESOLVED |
| TD26 | TeamMessage / CoordTypes | PRState and PRStatus model same concept with divergent colors  | S6     | NO       | RESOLVED |
| TD27 | ContextView.swift        | Hot-reload repeat within 3s window not detected by onChange   | S6     | NO       | RESOLVED |
| TD28 | ContextView.swift        | Diff highlight uses positional comparison, not LCS/Myers diff | S6     | NO       | RESOLVED |
| TD31 | EngineClient.swift       | approveMerge/rejectMerge treat CLEANUP_INCOMPLETE as failure  | S2     | NO       | RESOLVED |
| TD32 | merge.zig                | runGitLogged does not capture stderr for diagnostics          | S2     | NO       | RESOLVED |
| TD36 | main.zig                 | tm_interceptor_path worker 0 OOM returns null without setError| S3     | NO       | RESOLVED |
| TD37 | main.zig                 | sessionStop TL interceptor cleanup failure not surfaced       | S3     | NO       | RESOLVED |

## Audit-address sprint — Open debt (target updated to v0.1.6)

| ID   | Module                      | Issue                                                                              | Target | Breaking | Status |
|------|-----------------------------|------------------------------------------------------------------------------------|--------|----------|--------|
| TD29 | teammux.h                   | 15 dead C exports have no deprecation annotation in the header                     | v0.1.6 | NO       | OPEN   |
| TD30 | teammux.h                   | TM_ERR_PTY (6) is defined but no function returns it after PTY removal             | v0.1.6 | NO       | OPEN   |
| TD33 | merge.zig / coordinator.zig | getWorker() returns raw pointer without lock in production paths                   | v0.1.6 | NO       | OPEN   |
| TD34 | main.zig (tm_roster_get)    | Roster iteration uses raw pointers without holding roster mutex                    | v0.1.6 | NO       | OPEN   |
| TD35 | worktree.zig                | Roster.claimNextId leaks ID slot when subsequent spawn step fails                  | v0.1.6 | NO       | OPEN   |

## v0.1.5 S2 — Open debt (target updated to v0.1.6)

| ID   | Module                   | Issue                                                                                    | Target | Breaking | Status |
|------|--------------------------|------------------------------------------------------------------------------------------|--------|----------|--------|
| TD38 | GitView / ConflictView   | UI callers don't surface CLEANUP_INCOMPLETE warning — lastError only checked on !success | v0.1.6 | NO       | OPEN   |
| TD39 | merge.zig (test)         | cleanup_incomplete integration test is non-deterministic                                  | v0.2   | NO       | OPEN   |

## v0.1.5 S5 — Open debt (target updated to v0.1.6)

| ID   | Module                   | Issue                                                                              | Target | Breaking | Status |
|------|--------------------------|------------------------------------------------------------------------------------|--------|----------|--------|
| TD40 | github.zig               | getDiff limited to 100 files (no pagination), 1 MiB buffer cap                    | v0.1.6 | NO       | OPEN   |
| TD41 | DiffView.swift           | loadDiff calls engine.getDiff synchronously on MainActor, blocking UI              | v0.1.6 | NO       | OPEN   |

## v0.1.5 S6 — Open debt (target updated to v0.1.6)

| ID   | Module                   | Issue                                                                              | Target | Breaking | Status |
|------|--------------------------|------------------------------------------------------------------------------------|--------|----------|--------|
| TD42 | ContextView.swift        | LCS changedLineIndices has no unit tests                                           | v0.1.6 | NO       | OPEN   |
| TD43 | hotreload.zig            | reload_count value never asserted in Zig tests                                     | v0.1.6 | NO       | OPEN   |
| TD44 | ContextView.swift        | LCS DP table uses O(m*n) memory — two-row optimization deferred                    | v0.1.6 | NO       | OPEN   |

## Notes
- TD15: Worker-to-worker messaging ships in two modes — questions route via Team Lead relay (/teammux-ask), task delegation routes direct (/teammux-delegate). T2 adds engine routing, T9 adds Swift bridge and feed cards.
- TD16: CompletionReport and QuestionRequest cards ephemeral across sessions. T5 adds history.zig JSONL persistence, T10 adds Swift bridge loading on sessionStart with collapsible history section in LiveFeedView.
- TD17: git stash pop and git apply can restore denied files. T3 adds interception alongside exit 126 fix (TD19) and push-to-main block.
- TD18: Role TOML hot-reload updates CLAUDE.md but not FileOwnershipRegistry. T4 extends hotreload.zig callback to call ownership_update and re-installs interceptor with new deny patterns atomically.
- TD19: Interceptor wrapper uses exit 1 for enforcement — indistinguishable from real git errors. T3 changes all enforcement blocks to exit 126 (POSIX reserved for "command cannot execute").
- TD20: EngineClient.lastError written by 50+ methods — stale errors bleed. T6 adds clear at method entry (minimal correct fix). Full Result<T, EngineError> migration deferred to future sprint.
- TD21: tm_worktree_create creates directory and branch. On engine crash mid-spawn, worktree directory and branch may be left on disk. Recovery scan at engine init deferred from v0.2 → v0.1.6.
- TD22: PARTIALLY RESOLVED (v0.1.5-S4). Role-based ownership is correctly restored on session restore. Remaining gap: runtime ownership changes via direct tm_ownership_register (outside role file) not persisted. Full registry snapshot deferred to v0.2.
- TD23: RESOLVED (v0.1.5-S6). ContextView now uses AttributedString(markdown:) with header-to-bold pre-processing and fenced code block preservation.
- TD24: completion_history.jsonl is append-only and grows across all sessions. Log rotation (max size, archive old entries) deferred from v0.2 → v0.1.6.
- TD25: RESOLVED (AA3). Refspec syntax patterns now intercepted.
- TD26: RESOLVED (v0.1.5-S6). Unified to single PRStatus type with color property.
- TD27: RESOLVED (v0.1.5-S6). Engine exposes reload_count (u64). Swift stores per-worker reload sequence in dictionary.
- TD28: RESOLVED (v0.1.5-S6). LCS-based diff highlight via changedLineIndices.
- TD29: 15 dead exports in main.zig marked in code but header (teammux.h) still declares them without deprecation annotation. Target moved v0.2 → v0.1.6.
- TD30: TM_ERR_PTY=6 defined but no function returns it. Target moved v0.2 → v0.1.6.
- TD31: RESOLVED (v0.1.5-S2). CLEANUP_INCOMPLETE treated as partial success.
- TD32: RESOLVED (v0.1.5-S2). Cleanup commands capture stderr via runGitLoggedWithStderr.
- TD33: merge.zig/coordinator.zig getWorker() raw pointer calls without lock. Target moved v0.2 → v0.1.6. Migrate to copyWorkerFields/hasWorker.
- TD34: tm_roster_get iterates without mutex. Target moved v0.2 → v0.1.6.
- TD35: claimNextId leaks ID slot on spawn failure. Target moved v0.2 → v0.1.6.
- TD36: RESOLVED (v0.1.5-S3). setError on OOM for worker 0 interceptor path.
- TD37: RESOLVED (v0.1.5-S3). setError on sessionStop interceptor cleanup failure.
- TD38: UI callers never display CLEANUP_INCOMPLETE warning — only checked on !success path. GitView.approveMerge, rejectMerge, PREventCard.approveMerge, rejectMerge, ConflictView.forceMerge all affected. Target moved v0.2 → v0.1.6.
- TD39: merge.zig cleanup_incomplete test non-deterministic. Remains v0.2.
- TD40: getDiff uses ?per_page=100 without --paginate. PRs >100 files silently truncated. runGhCommand caps at 1 MiB. Target moved v0.2 → v0.1.6.
- TD41: DiffView.loadDiff wraps getDiff in Task { @MainActor in } — blocks main thread 1-5s during gh subprocess. Target moved v0.2 → v0.1.6.
- TD42: changedLineIndices has no unit tests. Target moved v0.2 → v0.1.6.
- TD43: reload_count value never asserted in Zig tests. Target moved v0.2 → v0.1.6.
- TD44: LCS DP table O(m*n) memory. Two-row optimization deferred. Target moved v0.2 → v0.1.6.
- updateRepo TODO(AA2): RESOLVED (v0.1.5-S1). repo_mutex added to GitHubClient.
- Merge order v0.1.4: T1-T7 (parallel Wave 1) → T8-T12 (Wave 2) → T13-T15 (Wave 3) → T16 (last)
- Message type enum v0.1.4 additions: TM_MSG_PEER_QUESTION=12, TM_MSG_DELEGATION=13, TM_MSG_PR_READY=14, TM_MSG_PR_STATUS=15
- Worktree root: defaults to ~/.teammux/worktrees/{SHA256(project_path)}/{worker_id}/. Configurable via config.toml key worktree_root.
