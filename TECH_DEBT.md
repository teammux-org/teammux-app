# Teammux — Known Technical Debt

## Stream 2 — Zig Engine (v0.1.1 targets)

| ID  | Module     | Issue                              | Stream    | Breaking | Status | Notes                                                        |
|-----|------------|------------------------------------|-----------|----------|--------|--------------------------------------------------------------|
| TD1 | bus.zig    | Message retry not implemented      | stream-A1 | YES      | RESOLVED | tm_message_cb returns tm_result_t, retry 3x with backoff    |
| TD2 | github.zig | Webhook retry after 5s not done    | stream-A2 | NO       | RESOLVED | Retry once after 5s, then polling fallback.                  |
| TD3 | github.zig | 60s polling fallback not done      | stream-A2 | NO       | RESOLVED | Background thread polls gh api every 60s on teammux/* branches. |
| TD4 | bus.zig    | git_commit always null in messages | stream-A1 | NO       | RESOLVED | git -C rev-parse HEAD captured before each message log       |

## Stream 3 — MergeCoordinator + Team Lead Review

| ID  | Module          | Issue                            | Stream    | Breaking | Status |
|-----|-----------------|----------------------------------|-----------|----------|--------|
| TD5 | merge.zig       | MergeCoordinator not implemented | stream-B1 | YES      | RESOLVED |
| TD6 | EngineClient    | tm_merge_* bridge missing        | stream-B2 | NO       | RESOLVED |
| TD7 | GitView.swift   | Team Lead review UI not built    | stream-C1 | NO       | RESOLVED |
| TD8 | ConflictInfo    | conflictType as String not enum  | v0.2 | NO | DEFERRED |

## v0.1.2 — Role Definitions

| ID   | Module                      | Issue                                                              | Stream        | Breaking | Status |
|------|-----------------------------|--------------------------------------------------------------------|---------------|----------|--------|
| TD9  | interceptor.zig             | PTY git wrapper installed but not yet enforced via PATH injection  | stream-R8     | NO       | RESOLVED |
| TD12 | interceptor.zig             | `git commit -a` bypasses interceptor — not intercepted by wrapper  | v0.2          | NO       | DEFERRED |
| TD13 | commands.zig / EngineClient | /teammux-complete and /teammux-question have no Swift-side handlers | stream future | NO       | OPEN   |
| TD14 | TeamBuilderView             | Role picker in setup flow deferred — session not started during setup, engine.availableRoles not populated | v0.2 | NO | OPEN |

## Notes
- TD1 breaking change: tm_message_cb gains a return value. stream-A1 updates engine/include/teammux.h, bus.zig, and EngineClient.swift atomically. No partial states.
- TD5 adds new functions to teammux.h. stream-B1 owns the header changes. stream-B2 consumes them.
- TD8: ConflictInfo.conflictType is a raw String. Deferred to v0.2 — only 2 engine values (content/unknown), displayed as-is in ConflictView. Consider an enum once engine's conflict type vocabulary is stable.
- Merge order: A1 → A2 → B1 → B2 → C1
- TD9: interceptor.zig writes a bash wrapper to {worktree}/.git-wrapper/git that intercepts `git add` and blocks denied files. The wrapper is installed at spawn and removed at dismiss/reject. PATH injection (prepending .git-wrapper to PATH in Ghostty SurfaceConfiguration) is done via tm_interceptor_path — Swift calls this to get the path, then sets it in the PTY environment.
- TD12: `git commit -a` (and `git commit --all`) bypasses the interceptor because the wrapper only intercepts `git add`. A worker using `git commit -a` can stage and commit denied files in a single command. Deferred to v0.2 — add `commit` subcommand interception with `-a`/`--all` flag detection.
- TD13: Worker CLAUDE.md documents /teammux-complete and /teammux-question as coordination commands. The Zig command watcher dispatches them correctly. Swift-side EngineClient handlers that act on these commands are not yet implemented. Add handlers in a future stream once Team Lead coordination workflow is built out.
- TD14: TeamBuilderView (setup flow) currently has no role picker. The setup flow runs before `sessionStart()`, so `engine.availableRoles` is not populated. Role assignment happens in the spawn popover after session start. Deferred to v0.2 — either pre-load roles from bundled TOML files without the engine, or restructure setup to start the engine earlier.

