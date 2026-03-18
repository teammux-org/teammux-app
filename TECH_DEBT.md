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

## v0.1.4 — Current sprint targets

| ID   | Module                      | Issue                                                              | Stream | Breaking | Status |
|------|-----------------------------|--------------------------------------------------------------------|--------|----------|--------|
| TD15 | coordinator.zig             | Worker-to-worker direct messaging not routed                       | T2/T9  | NO       | OPEN   |
| TD16 | LiveFeedView                | Completion history not persisted across sessions                   | T5/T10 | NO       | OPEN   |
| TD17 | interceptor.zig             | git stash / git apply bypass not intercepted                       | T3     | NO       | OPEN   |
| TD18 | hotreload.zig               | Role hot-reload does not update ownership registry                 | T4     | NO       | OPEN   |
| TD19 | interceptor.zig             | Interceptor exit code indistinguishable from git errors            | T3     | NO       | OPEN   |
| TD20 | EngineClient                | lastError is shared mutable state — stale errors bleed across calls| T6     | NO       | OPEN   |

## v0.1.4 — New debt introduced this sprint

| ID   | Module                   | Issue                                                            | Target | Breaking | Status |
|------|--------------------------|------------------------------------------------------------------|--------|----------|--------|
| TD21 | worktree_lifecycle.zig   | Dangling worktrees if engine crashes mid-spawn                   | v0.2   | NO       | OPEN   |
| TD22 | SessionState.swift       | Session restore does not re-establish ownership registry state   | v0.2   | NO       | OPEN   |
| TD23 | ContextView.swift        | CLAUDE.md rendered as plain text, not true markdown              | v0.1.5 | NO       | OPEN   |
| TD24 | history.zig              | JSONL log grows unbounded across sessions, no rotation           | v0.2   | NO       | OPEN   |
| TD25 | interceptor.zig          | Push-to-main block does not parse refspecs (HEAD:main bypasses)  | v0.2   | NO       | OPEN   |
| TD26 | TeamMessage / CoordTypes | PRState and PRStatus model same concept with divergent colors    | v0.1.5 | NO       | OPEN   |
| TD27 | ContextView.swift        | Hot-reload repeat within 3s window not detected by onChange      | v0.1.5 | NO       | OPEN   |
| TD28 | ContextView.swift        | Diff highlight uses positional comparison, not LCS/Myers diff   | v0.1.5 | NO       | OPEN   |

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
- Merge order v0.1.4: T1-T7 (parallel Wave 1) → T8-T12 (Wave 2, each waits on specific Wave 1 dep) → T13-T15 (Wave 3) → T16 (last)
- Message type enum v0.1.4 additions: TM_MSG_PEER_QUESTION=12, TM_MSG_DELEGATION=13, TM_MSG_PR_READY=14, TM_MSG_PR_STATUS=15
- Worktree root: defaults to ~/.teammux/worktrees/{SHA256(project_path)}/{worker_id}/. Configurable via config.toml key worktree_root.
