# Codex Audit Stream A4 — Reliability & Error Handling

## Your Role

You are a reliability engineer auditing a Zig+Swift system
for silent failures, degraded state handling, and crash
recovery gaps. This is a read-only audit. You MUST NOT
modify any source files, make commits, or run git push.
Findings only.

## Mandatory Reading (do all of these first, in parallel)

1. AGENTS.md
2. CLAUDE.md
3. docs/TECH_DEBT.md
4. engine/include/teammux.h
5. engine/src/main.zig
6. engine/src/history.zig
7. engine/src/commands.zig
8. engine/src/hotreload.zig
9. engine/src/github.zig
10. macos/Sources/Teammux/Engine/EngineClient.swift

## Audit Focus

**Silent failures in the engine:**
- Error returns ignored at the call site
  (result discarded with _ = or not checked)
- Functions returning void that could fail silently
- Any catch |_| swallowing an error without logging
- Bus send failures that don't notify the sender or caller

**Engine degraded state:**
- If sessionStart() fails partway (e.g. config parse
  fails after the Unix socket is open): what state remains?
  Is cleanup complete?
- If tm_worker_spawn succeeds but tm_worktree_create
  fails (graceful degradation path): does the worker
  exist without a worktree? Is this a consistent state?
- If the gh CLI is not installed: does tm_github_create_pr
  fail gracefully with an error message or crash?
- If git is not found: do all git-invoking functions
  (worktree_lifecycle, merge, github, interceptor) fail
  gracefully?

**lastError correctness (Swift):**
- Verify all 20 methods in EngineClient.swift have
  self.lastError = nil at entry (count them)
- Are there any paths where lastError from a previous
  call could contaminate a subsequent call?
- Is lastError thread-safe? Can the engine set it on a
  background thread while Swift reads it on @MainActor?

**Crash recovery:**
- If the app crashes mid-session: what files remain?
  (.tmp files, dangling worktrees, open sockets, lock files)
- Session persistence: if SessionState.save() is called
  and the JSON write fails mid-way, is the session file
  corrupt or absent?
- JSONL history: if the app crashes during the temp-rename
  atomic write, what is the state of completion_history.jsonl?
- Worktrees: if dismiss is called and the app crashes before
  git worktree remove completes, is there cleanup on next launch?

**JSONL history failure modes:**
- What happens if completion_history.jsonl is corrupt?
- What happens if .teammux/logs/ is deleted while running?
- What happens if disk is full during the atomic write?

**Command file watcher reliability:**
- What happens if .teammux/commands/ is deleted while
  the watcher is running?
- Can a malformed command file cause the watcher to
  crash or enter an infinite loop?
- Is there a TOCTOU race between file detection and read?

## Search Commands to Run

  rg "catch \|_\|" engine/src/ --include="*.zig"
  rg "_ = " engine/src/ --include="*.zig"
  rg "std\.log\.warn|std\.log\.err" engine/src/
  rg "self\.lastError = nil" \
    macos/Sources/Teammux/Engine/EngineClient.swift | wc -l
  rg "sessionStart|session_start" engine/src/main.zig
  rg "FileNotFound|error\.Git|error\.Gh|error\.Parse" \
    engine/src/
  rg "\.tmp|rename|atomic" engine/src/history.zig
  rg "deleteFile|dir\.deleteFile" engine/src/commands.zig

## Output — Two files required

**File 1 — Detailed findings:**
Write to: docs/codex-audits/audit-001-post-v014/FINDINGS-D4-reliability.md

Use this exact format for each finding:

## [SEVERITY] Short descriptive title

**File:** path/to/file:line_number
**Pattern:** (silent failure / degraded state / lastError /
             crash recovery / JSONL failure / watcher reliability)
**Description:** What the issue is and why it matters.
**Evidence:**
  (relevant code snippet, max 10 lines)
**Recommendation:** Specific fix.

Severity: CRITICAL / IMPORTANT / SUGGESTION

At the end write a ## Domain Summary section.

**File 2 — Triage summary:**
Write to: docs/codex-audits/audit-001-post-v014/SUMMARY-D4-reliability.md

# Audit Summary — Domain 4: Reliability & Error Handling

## Severity Counts
- CRITICAL: N
- IMPORTANT: N
- SUGGESTION: N
- TOTAL: N

## Top 3 Issues
1. [SEVERITY] Title — one sentence — file:line
2. [SEVERITY] Title — one sentence — file:line
3. [SEVERITY] Title — one sentence — file:line

## Recommended Sprint Allocation
- Audit-address sprint: (list finding titles)
- v0.1.5: (list finding titles)
- v0.2 / defer: (list finding titles)

## Systemic Patterns
One paragraph on recurring patterns.

## When Done — Raise PR

  git add \
    docs/codex-audits/audit-001-post-v014/FINDINGS-D4-reliability.md \
    docs/codex-audits/audit-001-post-v014/SUMMARY-D4-reliability.md
  git commit -m "audit(a4): D4 reliability — findings + summary"
  git push origin audit/a4-reliability
  gh pr create \
    --title "Audit A4: Reliability findings" \
    --body "Read-only audit. Two files: FINDINGS-D4 + SUMMARY-D4. No code changes." \
    --base main

## Hard Rules

- DO NOT modify any source files under any circumstances
- DO NOT make commits until findings are complete
- DO NOT run git push until both output files are written
- DO NOT switch branches or modify AGENTS.md
