# Audit Summary — Domain 6: Dead Code & Tech Debt

## Severity Counts
- CRITICAL: 0
- IMPORTANT: 2
- SUGGESTION: 6
- TOTAL: 8

## Top 3 Issues
1. [IMPORTANT] Diff view is wired to a permanently failing engine path — the UI calls `engine.getDiff(for:)`, but `GitHubClient.getDiff()` hard-returns `error.NotImplemented` and `tm_github_get_diff()` still ends in `unreachable` on a future success path — engine/src/main.zig:617
2. [IMPORTANT] Stale PTY C API remains in the authoritative header — `tm_pty_send` and `tm_pty_fd` are documented in `teammux.h`, never bridged from Swift, and implemented as permanent stubs — engine/include/teammux.h:264
3. [SUGGESTION] `worktreeReadyQueue` and `WorktreeReady` are orphaned spawn state — the queue is maintained through spawn and restore, but worker terminals render from `engine.roster` and never consume it — macos/Sources/Teammux/Engine/EngineClient.swift:62

## TD21-TD28 Priority Order
Ordered by recommended sprint and impact:
1. TD25 — Push-to-main block does not parse refspecs (HEAD:main bypasses) — audit-address — small, contained fix that closes a concrete workflow-governance bypass.
2. TD23 — CLAUDE.md rendered as plain text, not true markdown — v0.1.5 — visible every time `ContextView` is used and low-risk to fix.
3. TD27 — Hot-reload repeat within 3s window not detected by onChange — v0.1.5 — active role editing loses repeat-save feedback today.
4. TD26 — PRState and PRStatus model same concept with divergent colors — v0.1.5 — cheap consistency cleanup with immediate UI payoff.
5. TD28 — Diff highlight uses positional comparison, not LCS/Myers diff — v0.1.5 — visible highlight noise, but localized and non-blocking.
6. TD22 — Session restore does not re-establish ownership registry state — v0.2 — real restore bug, but it needs persisted runtime ownership state, not a one-line patch.
7. TD24 — JSONL log grows unbounded across sessions, no rotation — v0.2 — persistence already has O(n) reads and a 10 MB cap, but rotation wants a fuller retention policy.
8. TD21 — Dangling worktrees if engine crashes mid-spawn — v0.2 — worthwhile crash recovery, but broader than the audit-address sprint.

## Recommended Sprint Allocation
- Audit-address sprint: Diff view is wired to a permanently failing engine path; stale PTY C API remains in the authoritative contract; `statusReq` and `statusRpt` are dead protocol values; completion/question and peer-message C APIs have no Swift bridge caller; ownership, worktree, and utility exports have no Swift bridge caller; `githubStatus` is published but never observed; orphaned `worktreeReadyQueue` state and `WorktreeReady` helper; several public Zig helpers only serve their own module and tests; TD25.
- v0.1.5: TD23; TD26; TD27; TD28.
- v0.2 / defer: TD21; TD22; TD24.

## Systemic Patterns
The recurring issue is feature surface landing earlier than the last real consumer. The C header still carries PTY and helper APIs the app does not use, Swift publishes state that no view observes, and reserved or abandoned message types remain in the protocol even after the workflow moved elsewhere. The user-visible regressions cluster around partially shipped paths, especially DiffView and ContextView, while the higher-risk deferred debt sits in crash recovery and persistence lifecycle work.
