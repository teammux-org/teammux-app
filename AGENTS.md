# Teammux — Codex Agent Instructions

## Project Overview

Teammux is a native macOS ADE (AI Development Environment)
for coordinating teams of AI coding agents. A fork of
Ghostty 1.3.0 — a GPU-accelerated terminal emulator —
extended with a multi-agent coordination engine.

**Stack:**
- Engine: Zig (coordination engine, built as libteammux.a)
- UI: Swift + SwiftUI + AppKit (macOS 15 Sequoia, Apple Silicon)
- Terminal rendering: Ghostty fork (Zig + Metal)
- C API boundary: engine/include/teammux.h
- Bundle: com.teammux.app

**Build:**
```bash
./build.sh                   # full build
cd engine && zig build       # engine only
cd engine && zig build test  # engine tests (475 passing baseline)
rg <pattern> engine/src/     # always prefer rg over grep
```

Note: Zig 0.15.2 (nightly). Build runner may crash
transiently — retry once before treating as a code issue.

**Key directories:**
```
engine/src/                          — Zig coordination engine
engine/include/teammux.h             — C API (source of truth)
macos/Sources/Teammux/Engine/        — EngineClient.swift (sole tm_* caller)
macos/Sources/Teammux/RightPane/     — all right pane views
macos/Sources/Teammux/Workspace/     — roster, worker drawer
macos/Sources/Teammux/Setup/         — session state, setup flow
docs/codex-audits/                   — audit specs and output
docs/TECH_DEBT.md                    — known debt registry
src/                                 — Ghostty upstream (DO NOT TOUCH)
```

**Authoritative docs to read before any task:**
- CLAUDE.md — project rules, conventions, hard constraints
- docs/TECH_DEBT.md — open and resolved tech debt
- engine/include/teammux.h — C API contract

---

## Core Conventions

- ALL tm_* C API calls confined to EngineClient.swift exclusively
- No raw POSIX PTY shortcuts — Ghostty native PTY infrastructure only
- Engine memory: manual Zig allocator, owned strings duped on store,
  errdefer on partial allocations
- Swift: @MainActor on EngineClient, no force-unwraps in production
- C API strings: check header comment for caller-must-free vs
  engine-owned lifetime — never assume
- No src/ modifications (Ghostty upstream)

---

## What Codex MUST NOT Do

- DO NOT modify any source files (*.zig, *.swift, *.h, *.toml)
- DO NOT modify src/ under any circumstances
- DO NOT modify CLAUDE.md, AGENTS.md, README.md, or LICENSE
- DO NOT modify docs/TECH_DEBT.md or sprint specs
- DO NOT make commits to source files
- DO NOT run git push on source branches
- DO NOT run git checkout or switch branches
- DO NOT install dependencies or modify build configuration

**EXCEPTION — audit output files are explicitly PERMITTED:**
Files written to docs/codex-audits/audit-002-post-v016/ may
be committed and pushed. This is the intended workflow.
The restrictions above apply to all source files only.

---

## Current State (v0.1.6)

Engine tests: 475 passing, 0 failures.
Active operation: audit-002-post-v016

Key modules introduced or significantly changed in v0.1.6:
- engine/src/memory.zig — agent memory (NEW)
- engine/src/history.zig — JSONL rotation + async write queue
- engine/src/worktree_lifecycle.zig — crash recovery, atomic cleanup
- engine/src/coordinator.zig — health monitor, PTY death callback
- engine/src/bus.zig — retry logic, delivery failure paths
- engine/src/commands.zig — error response on silent failures
- engine/src/merge.zig — per-file conflict resolution
- engine/src/main.zig — PtyMonitor, tm_worker_restart, memory exports
- macos/.../RightPane/PaneIconRail.swift — vertical icon rail (NEW)
- macos/.../RightPane/UserTerminalView.swift — user PTY pane (NEW)
- macos/.../RightPane/ContextView.swift — memory timeline added
- macos/.../RightPane/GitView.swift — ConflictView per-file resolution

Known open debt (do not re-flag as new findings):
- TD22: Runtime ownership changes not persisted (v0.2)
- TD39: cleanup_incomplete test non-deterministic (v0.2)
- Any TD items marked OPEN with target v0.2 in TECH_DEBT.md

---

## Audit-002 Instructions (AA1-AA7)

You are one of 7 parallel read-only audit streams for
audit-002-post-v016. Read the full audit spec before
starting your domain:

  docs/codex-audits/audit-002-post-v016/AUDIT-002-SPEC.md

### Severity definitions

**CRITICAL:** Data loss, memory corruption, crash, security
issue, or incorrect behaviour in production. Must fix before
next release.

**IMPORTANT:** Degrades reliability, maintainability, or
correctness in non-critical paths. Fix in next sprint.

**SUGGESTION:** Code quality, style, minor improvement.
Can be deferred or declined.

### Output format

**FINDINGS-AA{N}-{domain}.md** — one finding per issue:
```
## Finding {N}-{seq}: {short title}
**Severity:** CRITICAL | IMPORTANT | SUGGESTION
**File:** {filepath}:{line}
**Description:** what the issue is
**Risk:** what can go wrong
**Recommendation:** specific fix
```

**SUMMARY-AA{N}-{domain}.md** — executive summary:
```
## Domain
## Files Reviewed
## Finding Counts (Critical / Important / Suggestion)
## Top 3 Findings
## Overall Health Assessment
```

### Output location

All output files must be written to:
```
docs/codex-audits/audit-002-post-v016/
```

Commit and push your FINDINGS and SUMMARY files when done.
Do not commit anything else.

---

## Key Architectural Facts for Auditors

- Worker ID 0 = Team Lead. Deny-all interceptor. Never in roster.
- PTY ownership belongs to Ghostty. Engine never touches PTY fds.
- TM_ERR_CLEANUP_INCOMPLETE (15): partial success — merge/reject
  succeeded, cleanup failed. Not a hard error.
- TM_ERR_DELIVERY_FAILED (16): dispatch delivery failure.
- TM_MSG_PTY_DIED (17): worker PTY process died.
- TM_MSG_HEALTH_STALLED (18): worker stall threshold exceeded.
- TM_ERR_PTY (6): RESERVED — no function returns this anymore.
- 15 exports marked DEPRECATED in header (TD29) — no Swift callers.
  Do not flag these as new findings.
- PtyMonitor: background thread polls PIDs via kill(pid,0) every
  500ms as safety-net. Primary path: Swift calls tm_worker_pty_died.
- History async queue: 256-slot ring buffer. Background thread drains
  to disk. Delivery path enqueues non-blocking.
- recoverOrphans: runs at sessionStart, scans worktree root for
  numeric dirs not in roster, removes them via git commands.
