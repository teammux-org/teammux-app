# Audit Summary — Domain 3: Systems Architecture

## Severity Counts
- CRITICAL: 2
- IMPORTANT: 4
- SUGGESTION: 0
- TOTAL: 6

## Top 3 Issues
1. [CRITICAL] Worker spawn creates two independent worktrees and two branch identities — one worker is represented by two physical worktrees and two branch schemes, so Swift surfaces can disagree about the real source of truth — engine/src/main.zig:383
2. [CRITICAL] Team Lead is not structurally prevented from writing code or pushing to main — the Team Lead terminal runs directly in project root without interceptor enforcement, while worker `0` defaults to unrestricted ownership — macos/Sources/Teammux/RightPane/TeamLeadTerminalView.swift:116
3. [IMPORTANT] Hot-reload can invalidate ownership slices while interceptor installation is reading them — the registry advertises borrowed slices, but role-watch mutations happen on a background thread — engine/src/main.zig:2003

## Recommended Sprint Allocation
- Audit-address sprint: Worker spawn creates two independent worktrees and two branch identities; Team Lead is not structurally prevented from writing code or pushing to main; Hot-reload can invalidate ownership slices while interceptor installation is reading them
- v0.1.5: Engine-handled `/teammux-*` commands fail silently and still consume the command file; Dispatch APIs report success even after bus delivery has failed; Unexpected PTY death has no cleanup or state-reconciliation path
- v0.2 / defer: none

## Systemic Patterns
The codebase is not suffering from obvious import cycles or widespread Swift concurrency misuse; the main actor boundary is handled carefully in the audited bridge code. The recurring structural problem is different subsystems each owning part of the same concept without a single enforced source of truth. Worker lifecycle spans roster state, worktree lifecycle state, interceptor state, role-watch state, terminal state, and session persistence, but the coupling lives mostly in `main.zig` and `EngineClient.swift` rather than behind one coherent ownership model. That makes invariants like "one worker, one worktree" and "Team Lead cannot write code" easy to state in docs but easy to violate in the shipped runtime.
