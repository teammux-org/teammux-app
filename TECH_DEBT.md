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
| TD11 | SpawnPopoverView            | Role selector UI (browse/preview bundled roles before spawning)    | S9     | NO       | RESOLVED |
| TD12 | interceptor.zig             | git commit -a bypasses interceptor                                 | S1     | NO       | RESOLVED |
| TD13 | commands.zig / EngineClient | /teammux-complete and /teammux-question have no Swift-side handlers| S2/S6  | NO       | RESOLVED |
| TD14 | TeamBuilderView             | Role picker in setup flow — session not started during setup       | S3/S9  | NO       | RESOLVED |

## v0.1.3 — New debt introduced this sprint

| ID   | Module           | Issue                                               | Target | Breaking | Status |
|------|------------------|-----------------------------------------------------|--------|----------|--------|
| TD15 | coordinator.zig  | Worker-to-worker direct messaging not routed        | v0.2   | NO       | OPEN   |
| TD16 | LiveFeedView     | Completion history not persisted across sessions    | v0.2   | NO       | OPEN   |
| TD17 | interceptor.zig  | git stash / git apply bypass not intercepted        | v0.3   | NO       | OPEN   |
| TD18 | hotreload.zig    | Role hot-reload does not update ownership registry  | v0.2   | NO       | OPEN   |
| TD19 | interceptor.zig  | Interceptor exit code indistinguishable from git errors | v0.2   | NO       | OPEN   |
| TD20 | EngineClient     | lastError is shared mutable state — stale errors from unrelated operations | v0.2 | NO | OPEN |

## Notes
- TD10: Role definition changes after spawn do not update active worker CLAUDE.md. stream-S4 implements kqueue watcher on role TOML, regenerates CLAUDE.md and injects update via message bus on change.
- TD11: SpawnPopoverView role picker only shows roles already loaded by engine. S9 adds pre-session role loading from bundled TOML via tm_roles_list_bundled so TeamBuilderView can show roles before sessionStart().
- TD12: git commit -a and git commit --all stage and commit denied files bypassing the interceptor wrapper. S1 adds commit subcommand interception with -a/--all flag detection.
- TD13: /teammux-complete and /teammux-question are documented in worker CLAUDE.md and dispatched by the Zig command watcher. Swift-side EngineClient handlers that parse payloads and update @Published state are not yet implemented. S2 adds engine message types, S6 adds Swift bridge.
- TD14: TeamBuilderView runs before sessionStart() so engine.availableRoles is empty. S3 adds tm_roles_list_bundled C API, S9 consumes it in TeamBuilderView. TD14 resolved when S9 merges.
- TD15: tm_dispatch_task routes from Team Lead to a specific worker. Worker-to-worker routing (A asks B a question) is not wired. Deferred to v0.2.
- TD16: CompletionReport and QuestionRequest cards in LiveFeedView are ephemeral. Session restart loses history. Persist to JSONL in .teammux/logs/ in v0.2.
- TD17: git stash pop and git apply can restore denied files to the working tree. Not intercepted. Deferred to v0.3 — lower risk than commit bypass.
- TD18: When a role TOML changes, the active worker gets a refreshed CLAUDE.md. The FileOwnershipRegistry is NOT updated — deny patterns in the registry still reflect the original role. Deferred to v0.2.
- TD19: Interceptor wrapper uses exit 1 for both git-add and git-commit blocks. Callers cannot distinguish "Teammux blocked this" from "git itself failed." Use a distinctive exit code (e.g., 126) for interceptor enforcement. Affects both add and commit blocks.
- TD20: EngineClient.lastError is a single @Published String? written by 50+ methods. When one method fails, lastError may still contain an error from a previous unrelated call. Affects GitWorkerRow, DispatchWorkerRow, QuestionCardView, and any future view reading lastError on failure. Fix: return Result<T, Error> from engine methods or clear lastError at method entry. Deferred to v0.2.
- Merge order v0.1.3: S1 (any time) → S2/S3/S4/S5 (parallel) → S6/S7/S8/S9 (parallel wave 2) → S10/S11 (parallel wave 3) → S12 (last)
