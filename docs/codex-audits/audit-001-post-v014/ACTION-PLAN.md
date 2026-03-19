# Audit 001 Action Plan — Post v0.1.4

**Generated from:** 6-domain Codex audit, v0.1.4 codebase
**Total findings:** 38 across 6 domains (35 unique after cross-domain deduplication)
**Severity breakdown:** 5 CRITICAL, 20 IMPORTANT, 13 SUGGESTION
**Cross-domain patterns:** 3
**Sprint recommendation:** Audit-address sprint before any v0.1.5 work

---

## Critical Findings (fix before any v0.1.5 work)

### C1. Failed config reload leaves `e.cfg` pointing at freed storage
**Source:** Domain 1 — Memory Safety, engine/src/main.zig:352
**Issue:** `tm_config_reload` destroys the current config before loading the replacement. If `config.loadWithOverrides` fails, `e.cfg` still points at the deinitialized struct. The next config read or final `Engine.destroy()` can then read or free already-freed config strings — a classic use-after-free that can crash the app or corrupt memory during any failed hot-reload.
**Fix:** Load into a temporary `new_cfg`. Only deinit/swap `e.cfg` after the new config is fully loaded. If the reload fails, leave the old config intact.
**Cross-references:** I1 (GitHubClient borrows config-owned repo slice — same config lifetime root cause).

### C2. `CommandWatcher` stores a borrowed commands path that `sessionStart` frees
**Source:** Domain 1 — Memory Safety + Domain 4 — Reliability, engine/src/main.zig:148, engine/src/commands.zig:31
**Issue:** `sessionStart` allocates `cmd_dir`, passes the slice into `CommandWatcher.init`, and immediately frees it with `defer`. `CommandWatcher` only stores the borrowed slice. When `tm_commands_watch` later runs, the watcher dereferences freed memory — this can crash, watch a wrong path, or fail nondeterministically. This is the most immediately dangerous finding in the audit: the watcher is used on every session.
**Fix:** Make `CommandWatcher` own a duped copy of `commands_dir` and free it in `deinit()`, or keep the original allocation alive for the full watcher lifetime.
**Cross-references:** I9 (sessionStart partial state leaks — same function, same pattern of premature cleanup).

### C3. Worker spawn creates two independent worktrees and two branch identities
**Source:** Domain 3 — Architecture, engine/src/main.zig:383
**Issue:** `tm_worker_spawn` creates a worker through `Roster.spawn` (which runs `git worktree add` with one path/branch scheme), then immediately calls `worktree_lifecycle.create` (which runs a second `git worktree add` with a different path/branch scheme). Swift mixes both sources: terminals come from roster state, while `tm_worktree_path`/`tm_worktree_branch` populate workerWorktrees, workerBranches, the Context tab, and session snapshots. One logical worker ends up with split-brain filesystem and branch state.
**Fix:** Collapse worker worktree ownership to a single subsystem. Either make `worktree_lifecycle` the only worktree creator and have the roster reference it, or remove `wt_registry` and derive every Swift/UI API from the roster's one path/branch record.
**Cross-references:** I11 (worktree cleanup forgets orphaned paths — cleanup is complicated by dual ownership).

### C4. Team Lead is not structurally prevented from writing code or pushing to main
**Source:** Domain 3 — Architecture, macos/Sources/Teammux/RightPane/TeamLeadTerminalView.swift:116
**Issue:** The Team Lead terminal runs plain `claude` in the project root, not in a restricted worktree and without PATH injection for the git wrapper. The ownership registry defaults to allow when a worker has no rules, and the interceptor API only installs wrappers for roster workers. Worker 0 is unrestricted by default. This violates the product-level invariant that the Team Lead is structurally prevented from writing code — it is enforced by convention only.
**Fix:** Give the Team Lead its own enforced execution path: dedicated read-only or message-only worktree, mandatory git-wrapper/PATH injection, and engine-side rejection of write-capability and push-to-main operations for worker 0. Also fix TD25 (refspec bypass) as part of the same stream.
**Cross-references:** TD25 (push-to-main refspec bypass — same enforcement gap).

---

## Important Findings (address in audit-address sprint)

### I1. `GitHubClient` keeps a borrowed repo slice across config reloads
**Source:** Domain 1 — Memory Safety, engine/src/main.zig:136
**Issue:** `GitHubClient.init` stores a slice from `cfg.project.github_repo` without duping it. `Config.deinit()` frees the repo string during reload, leaving GitHub polling, webhook setup, and PR operations with a dangling pointer. Any config reload during an active GitHub session is a latent use-after-free.
**Fix:** Make `GitHubClient` own its `repo` string, free it in `deinit()`, and replace it atomically during reload.
**Cross-references:** C1 (config reload lifetime — same root cause of borrowing config-owned storage).

### I2. Ownership rule slices escape the registry lock and can be invalidated mid-read
**Source:** Domain 1 — Memory Safety + Domain 3 — Architecture, engine/src/ownership.zig:113, engine/src/main.zig:2003
**Issue:** `getRules()` returns a registry-owned slice after dropping the mutex. The function comment warns that concurrent updates invalidate it. `tm_ownership_get` and `tm_interceptor_install` both walk that slice after unlock, while `RoleWatcher.fireCallback` mutates the same worker's rules from its watcher thread. The safety comment in `tm_interceptor_install` claiming main-thread safety is false in the presence of hot-reload.
**Fix:** Replace `getRules()` with a locked copy-out API that duplicates the rules before releasing the mutex, or hold the lock through the consumer iteration.
**Cross-references:** I3 (Roster raw pointers — same pattern of returning internal pointers without lock protection).

### I3. `Roster.getWorker()` returns raw worker pointers without read-side locking
**Source:** Domain 1 — Memory Safety, engine/src/worktree.zig:145
**Issue:** `dismiss()` removes a worker under the roster mutex and frees all owned worker strings, but `getWorker()` returns `workers.getPtr()` with no lock. Background-thread paths such as `CommandWatcher` -> `busSendBridge` dereference worker fields like `worktree_path`, so a concurrent dismiss can race with the read and expose freed memory.
**Fix:** Stop returning raw internal pointers. Add a locked copy API or a `withWorkerLocked` callback so callers copy needed fields while the mutex is held.
**Cross-references:** I2 (ownership slices escape lock — same pattern).

### I4. `tm_config_get()` violates its documented C-string lifetime
**Source:** Domain 1 — Memory Safety + Domain 2 — C API Boundary, engine/src/main.zig:370, engine/include/teammux.h:198
**Issue:** The header promises the returned pointer stays valid until the next `tm_config_reload()`. The implementation frees the cached string at the start of every `tm_config_get()` call. Any caller that stores one config pointer, performs another lookup, and then reads the first pointer will read freed memory.
**Fix:** Either keep config values alive until reload as documented, or tighten the header contract to "valid until the next `tm_config_get()`" and ensure every caller copies immediately.
**Cross-references:** C1 (config reload lifetime — same config boundary).

### I5. tm_engine_create returns success when the out-parameter is NULL
**Source:** Domain 2 — C API Boundary, engine/src/main.zig:320
**Issue:** The export accepts NULL for `out`, allocates an engine anyway, returns `TM_OK`, and drops the only handle to that allocation. A caller gets a false-success result and leaks the engine immediately.
**Fix:** Reject NULL `out` up front, set `last_create_error` to `"out must not be NULL"`, and return an error code.
**Cross-references:** None.

### I6. Engine-handled `/teammux-*` commands fail silently and still consume the command file
**Source:** Domain 3 — Architecture, engine/src/main.zig:632
**Issue:** `/teammux-assign`, `/teammux-ask`, `/teammux-delegate`, and `/teammux-pr-ready` are intercepted inside the engine. On missing fields, invalid worker IDs, or missing bus state, these handlers just log and return. `commands.zig` then deletes the JSON command file after the callback returns. The Team Lead gets no `TM_MSG_ERROR`, no Swift-visible failure, and no retained artifact for retry.
**Fix:** Make command handlers return structured success/failure, emit `TM_MSG_ERROR` on failure, and only delete the command file once the handler reports success.
**Cross-references:** I7 (dispatch APIs swallow failures — same silent-failure pattern), I12 (merge cleanup drops failures — same pattern).

### I7. Dispatch APIs report success even after bus delivery has failed
**Source:** Domain 3 — Architecture, engine/src/coordinator.zig:46
**Issue:** `Coordinator.dispatchTask` and `dispatchResponse` intentionally swallow `error.DeliveryFailed`, record `delivered=false`, and return success. Swift treats the dispatch as successful. Autonomous dispatch cannot distinguish accepted-but-undelivered from actual delivery.
**Fix:** Return a distinct status for accepted-but-undelivered dispatches, or surface the `delivered` bit synchronously to Swift.
**Cross-references:** I6 (silent command failures — same pattern).

### I8. Unexpected PTY death has no cleanup or state-reconciliation path
**Source:** Domain 3 — Architecture, engine/src/pty.zig:6
**Issue:** The engine does not own PTY lifecycle, but the Swift worker terminal layer has no exit callback back into the engine. If a worker process dies unexpectedly, the worker remains in roster/worktree/ownership/watch state until manual dismissal. PTY teardown is not symmetric with spawn.
**Fix:** Add a terminal/session exit callback from Ghostty into `EngineClient`, unregister surfaces on view teardown, and introduce an engine path to mark the worker errored or dismiss it when its PTY disappears.
**Cross-references:** C3 (dual worktree spawn — lifecycle asymmetry compounds cleanup complexity).

### I9. sessionStart leaks partial engine state on initialization failure
**Source:** Domain 4 — Reliability, engine/src/main.zig:127
**Issue:** `sessionStart()` commits subsystem state directly onto `Engine` as it goes. If a later step fails, earlier state is left attached with no rollback. A retry can overwrite `cfg`, `message_bus`, `commands_watcher`, or `history_logger` without deinitializing the previous values.
**Fix:** Stage startup resources in locals with `errdefer` rollback, then assign to `self` only after the full startup path succeeds.
**Cross-references:** C2 (CommandWatcher borrows freed path — same function, specific instance of the partial-commit pattern).

### I10. last_error is mutated from background threads without synchronization
**Source:** Domain 4 — Reliability, engine/src/main.zig:154
**Issue:** Command-watcher and GitHub polling paths call `setError()` from background threads, while Swift reads `tm_engine_last_error()` on `@MainActor`. `setError()` frees and replaces `last_error` without any lock, so background writes can race with foreground reads, producing stale, torn, or use-after-free error state.
**Fix:** Guard `last_error` and `last_error_cstr` behind a mutex, or move to per-call owned error returns so background threads never mutate shared error buffers directly.
**Cross-references:** I2, I3 (same pattern of unprotected shared state across threads).

### I11. Worktree cleanup forgets orphaned paths before git removal succeeds
**Source:** Domain 4 — Reliability, engine/src/worktree_lifecycle.zig:203
**Issue:** `removeWorker()` drops the registry entry before `git worktree remove --force` succeeds. If git removal fails or the app crashes mid-operation, the engine has forgotten the path. No startup recovery sweep exists, so orphaned worktrees and branches persist indefinitely.
**Fix:** Keep registry metadata until git removal succeeds, or persist a pending-cleanup record and sweep abandoned worktrees on next launch.
**Cross-references:** C3 (dual worktrees — cleanup is split across two subsystems), TD21 (dangling worktrees — related crash recovery gap).

### I12. Merge cleanup drops git failures silently
**Source:** Domain 4 — Reliability, engine/src/merge.zig:136
**Issue:** After approve and reject flows, merge cleanup uses `runGitIgnoreResult()` for worktree removal and branch deletion. That helper discards allocation failures, spawn failures, exit codes, and stderr with no logging. The merge can be reported as successful while cleanup silently leaves the worktree or branch behind.
**Fix:** Log cleanup failures and surface them to the caller, or track cleanup as pending work instead of silently discarding the result.
**Cross-references:** I6 (silent command failures — same silent-failure pattern).

### I13. PR_READY and PR_STATUS delivery failures only log warnings
**Source:** Domain 4 — Reliability, engine/src/main.zig:870
**Issue:** PR creation may succeed on GitHub, but if `routePrReady()` cannot allocate or bus send fails, the handler frees the returned PR and the UI never learns about it. Polling-driven PR status events have the same problem: failures are logged and dropped with no retry queue.
**Fix:** Return a failure to the command path when PR event routing fails, or persist/retry pending PR events until the Team Lead UI has acknowledged them.
**Cross-references:** I6, I7 (silent failure pattern across command, dispatch, and PR paths).

### I14. Message bus send path spawns `git` for every message
**Source:** Domain 5 — Performance, engine/src/bus.zig:120
**Issue:** `MessageBus.send()` runs `git rev-parse HEAD` synchronously before logging and delivery on every bus message — not just completion-related events. Every dispatch, question, delegation, PR event, and broadcast pays for process spawn, stdout allocation, wait, commit-string duplication, and JSON log formatting. This is the hottest engine path and it is fully synchronous.
**Fix:** Cache the current commit once per session/worktree and invalidate only after commit/merge operations, or record commit metadata only for message types that actually surface it in the UI/audit log.
**Cross-references:** I15 (O(n) history append — compounds per-message cost on the same delivery path).

### I15. Completion/question history append is O(n) and stays on the delivery path
**Source:** Domain 5 — Performance, engine/src/history.zig:114
**Issue:** Each history append reads the entire `completion_history.jsonl`, writes old content plus one new line to a temp file, then renames. This is invoked inline from `busSendBridge()`. Worker completion latency grows with history size. The logger hard-limits reads at 10 MB, so the cost ratchets upward across sessions.
**Fix:** Keep the history file open in append mode and write new lines directly, using rotation/checkpointing for crash resilience instead of full-file rewrite.
**Cross-references:** I14 (bus git spawn — same delivery path), TD24 (unbounded JSONL — rotation would address both).

### I16. Completion handling fans out into multiple `@Published` invalidations
**Source:** Domain 5 — Performance, macos/Sources/Teammux/Engine/EngineClient.swift:1459
**Issue:** A completion message appends to `messages`, parses JSON into `workerCompletions`, triggers autonomous dispatch which calls `dispatchTask()`, which synchronously reloads the entire dispatch history from the engine, then writes `autonomousDispatches`. `LiveFeedView` and `DispatchView` both observe those collections, so one completion triggers several independent SwiftUI invalidations and a full bridge round-trip.
**Fix:** Batch completion-side state into a single update on the main actor. Append the newly created dispatch event locally instead of calling `refreshDispatchHistory()` after every autonomous dispatch.
**Cross-references:** None.

### I17. Diff view is wired to a permanently failing engine path
**Source:** Domain 6 — Dead Code & Tech Debt, engine/src/main.zig:617
**Issue:** `DiffView` is live in Swift, but `GitHubClient.getDiff()` always returns `error.NotImplemented` and the success branch in `tm_github_get_diff()` ends in `unreachable`. The diff tab is dead UI, and a future engine implementation will trap until the export is updated.
**Fix:** Either hide/disable the diff UI until the backend exists, or implement the backend and replace the `unreachable` with real bridging.
**Cross-references:** None.

### I18. Stale PTY C API remains in the authoritative header
**Source:** Domain 6 — Dead Code & Tech Debt, engine/include/teammux.h:264
**Issue:** `tm_pty_send` and `tm_pty_fd` are documented in the header but never called from Swift. The Zig exports are hardcoded nonfunctional because Ghostty owns PTYs. The header exposes dead, misleading API surface.
**Fix:** Remove these declarations and exports, or mark them explicitly as legacy nonfunctional stubs.
**Cross-references:** S11, S12 (other dead API surface in the header).

---

## Suggestions (v0.1.5 or defer)

### S1. Config parse cleanup leaks replaced default strings on error paths
**Source:** Domain 1 — Memory Safety, engine/src/config.zig:124
**Issue:** `errdefer` block only frees replacement strings when flags are false, so any later parse failure leaks the current replacement.
**Fix:** Always free the current pointer in `errdefer`, or stage replacements in temporaries.

### S2. EngineClient does not use the NULL-engine error retrieval path for creation failures
**Source:** Domain 2 — C API Boundary, macos/Sources/Teammux/Engine/EngineClient.swift:234
**Issue:** `lastEngineError()` returns nil when engine is unset, so creation-time diagnostics are lost.
**Fix:** Add a helper that calls `tm_engine_last_error(nil)` when no engine exists.

### S3. tm_pr_t is bridged without the ABI size check used for other structs
**Source:** Domain 2 — C API Boundary, engine/src/main.zig:258
**Issue:** `CPr` lacks a compile-time `@sizeOf` assertion, unlike `CWorkerInfo`, `CConflict`, and `CHistoryEntry`.
**Fix:** Add a `@sizeOf(CPr)` assertion in the comptime block.

### S4. Swift helper paths can preserve stale lastError
**Source:** Domain 4 — Reliability, macos/Sources/Teammux/Engine/EngineClient.swift:527
**Issue:** Several helper paths do not clear `lastError` at entry, keeping stale errors visible after successful operations.
**Fix:** Clear `lastError` at entry for user-visible helper flows.

### S5. Live feed message storage is unbounded while the UI renders the full array
**Source:** Domain 5 — Performance, macos/Sources/Teammux/RightPane/LiveFeedView.swift:279
**Issue:** `messages` is append-only for the session life but the UI renders the whole collection.
**Fix:** Cap the in-memory feed or split into recent window plus persisted archive.

### S6. JSON key scanning allocates short search strings on the heap
**Source:** Domain 5 — Performance, engine/src/commands.zig:253
**Issue:** JSON helpers allocate a temporary key string on `page_allocator` for every lookup.
**Fix:** Replace with `std.fmt.bufPrint` using a stack buffer.

### S7. Role hot-reload always regenerates the interceptor wrapper
**Source:** Domain 5 — Performance, engine/src/hotreload.zig:236
**Issue:** Every role file change regenerates the wrapper script even for metadata-only edits.
**Fix:** Compare old and new write/deny pattern sets before reinstalling.

### S8. Orphaned `worktreeReadyQueue` state and `WorktreeReady` helper
**Source:** Domain 6 — Dead Code, macos/Sources/Teammux/Engine/EngineClient.swift:38
**Issue:** Queue is maintained through spawn and restore but has no consumer — terminals render from `engine.roster`.
**Fix:** Remove the queue and helper type.

### S9. `githubStatus` is published but never observed
**Source:** Domain 6 — Dead Code, macos/Sources/Teammux/Engine/EngineClient.swift:56
**Issue:** Mutated during auth and webhook callbacks but no view reads it.
**Fix:** Remove the property and unused auth-state path.

### S10. `statusReq` and `statusRpt` are dead protocol values
**Source:** Domain 6 — Dead Code, macos/Sources/Teammux/Models/TeamMessage.swift:15
**Issue:** Defined in C enum, Zig bus, and Swift `MessageType` but no sender or handler exists.
**Fix:** Remove the cases or document as reserved.

### S11. Completion/question and peer-message C APIs have no Swift bridge caller
**Source:** Domain 6 — Dead Code, engine/src/main.zig:1090
**Issue:** `tm_peer_question`, `tm_peer_delegate`, `tm_worker_complete`, `tm_worker_question`, `tm_completion_free`, `tm_question_free` are exported but never called from Swift — the app uses command-file routing instead.
**Fix:** Bridge from Swift or remove from the app-facing contract.

### S12. Ownership, worktree, and utility exports have no Swift bridge caller
**Source:** Domain 6 — Dead Code, engine/src/main.zig:370
**Issue:** `tm_config_get`, `tm_worktree_create`, `tm_worktree_remove`, `tm_history_clear`, `tm_ownership_get`, `tm_ownership_free`, `tm_ownership_update`, `tm_interceptor_remove`, `tm_agent_resolve`, `tm_result_to_string` are exported but unused.
**Fix:** Prune or explicitly label as external-only.

### S13. Several public Zig helpers only serve their own module and tests
**Source:** Domain 6 — Dead Code, engine/src/commands.zig:235
**Issue:** Helpers like `parseCommandJson`, `readGhCliToken`, `resolveGitBinary`, `globMatch`, etc. are `pub fn` but only called from their defining module and tests. Zig tests can call private functions.
**Fix:** Make module-private unless a cross-module consumer is planned.

---

## Tech Debt Priority Order (TD21-TD28)

### Audit-Address Sprint
- TD25: Push-to-main block does not parse refspecs (HEAD:main bypasses) — contained fix that closes a concrete workflow-governance bypass, pairs with C4 Team Lead enforcement

### v0.1.5
- TD23: CLAUDE.md rendered as plain text, not true markdown — visible every time ContextView is used, low-risk fix
- TD27: Hot-reload repeat within 3s window not detected by onChange — active role editing loses repeat-save feedback
- TD26: PRState and PRStatus model same concept with divergent colors — cheap consistency cleanup with immediate UI payoff
- TD28: Diff highlight uses positional comparison, not LCS/Myers diff — visible highlight noise, localized and non-blocking

### v0.2 / Defer
- TD22: Session restore does not re-establish ownership registry state — real restore bug but needs persisted runtime ownership state
- TD24: JSONL log grows unbounded across sessions, no rotation — O(n) reads capped at 10 MB, rotation needs fuller retention policy
- TD21: Dangling worktrees if engine crashes mid-spawn — worthwhile crash recovery but needs startup reconciliation pass

---

## Audit-Address Sprint Scope

**Recommended stream count:** 6 streams
**Total items:** 4 CRITICAL + 12 IMPORTANT + 6 SUGGESTION + 1 TD = 23 items

| Stream | Finding IDs | Domain Focus | Estimated Complexity |
|--------|-------------|--------------|----------------------|
| AA1 | C1, C2, I1, I9 | Memory Safety — lifetime & ownership fixes in main.zig/sessionStart | complex |
| AA2 | I2, I3, I10 | Concurrency — mutex discipline across ownership, roster, last_error | complex |
| AA3 | C3, C4, TD25 | Architecture — worktree unification, Team Lead enforcement, refspec | complex |
| AA4 | I4, I5, I12 | C API & Silent Failures — contract alignment, merge cleanup surfacing | medium |
| AA5 | I14, I16 | Performance — bus git caching, completion @Published batching | medium |
| AA6 | I17, I18, S8, S9, S10, S11, S12, S13 | Dead Code Pruning — diff view, stale APIs, unused state | medium |

### Stream Descriptions

**AA1 — Lifetime & Ownership Safety:** Fix the two CRITICALs (config reload use-after-free, CommandWatcher freed path), the GitHubClient borrowed slice, and sessionStart partial-state leak. All are in `main.zig` or its direct callers, share the root cause of borrowing short-lived storage, and can be fixed in one coherent pass through the session lifecycle.

**AA2 — Concurrency & Locking:** Replace `getRules()` with a copy-out API, add read-side locking to `Roster.getWorker()`, and protect `last_error` with a mutex. All three are the same pattern (returning or mutating shared state without adequate synchronization) and need a consistent locking strategy.

**AA3 — Architecture & Team Lead:** Collapse dual worktree creation to a single subsystem, add structural enforcement for Team Lead (read-only worktree, interceptor PATH injection, engine-side rejection for worker 0), and fix TD25 refspec parsing. These are the largest structural changes and should be reviewed together.

**AA4 — C API Contracts & Silent Failures:** Fix `tm_config_get` lifetime documentation vs implementation, reject NULL `out` in `tm_engine_create`, and surface merge cleanup failures. These are focused contract-alignment fixes.

**AA5 — Performance Hot Path:** Cache git HEAD instead of spawning per-message, and batch completion-side `@Published` updates. Both are on the message delivery critical path.

**AA6 — Dead Code Pruning:** Disable/remove the non-functional diff tab, remove stale PTY API, prune dead `@Published` properties, dead protocol values, and unused C exports. This is a cleanup sweep with low risk.

---

## Cross-Domain Patterns

Issues that appeared in multiple domains — same root cause surfaced by different auditors:

- **Pattern: Borrowed commands path freed by sessionStart**
  Appears in: Domain 1 (C2: CommandWatcher stores borrowed commands path) + Domain 4 (CRITICAL: Command watcher stores freed commands directory path)
  Root cause: `sessionStart` allocates `cmd_dir` with `defer free`, but `CommandWatcher.init` only borrows the slice without duping.
  Single fix covers: both findings — make `CommandWatcher` own a duped copy.

- **Pattern: tm_config_get lifetime mismatch between header and implementation**
  Appears in: Domain 1 (I4: tm_config_get violates documented C-string lifetime) + Domain 2 (IMPORTANT: tm_config_get documented lifetime does not match implementation)
  Root cause: Header says "valid until next reload", implementation frees on next `tm_config_get()` call.
  Single fix covers: both findings — align contract and implementation.

- **Pattern: Registry-owned slices escape the mutex and are invalidated by concurrent mutation**
  Appears in: Domain 1 (I2: Ownership rule slices escape the registry lock) + Domain 3 (IMPORTANT: Hot-reload can invalidate ownership slices while interceptor is reading them)
  Root cause: `getRules()` returns internal slice after dropping mutex; hot-reload mutates the same data from its watcher thread.
  Single fix covers: both findings — replace with locked copy-out API.

---

## AGENTS.md Fix Required

Add this clarification to the "What Codex MUST NOT Do" section in AGENTS.md:

  NOTE: Audit output files in docs/codex-audits/ are
  explicitly PERMITTED to be committed and pushed.
  The restrictions above apply to source files only
  (*.zig, *.swift, *.h, *.toml, *.md in repo root).
