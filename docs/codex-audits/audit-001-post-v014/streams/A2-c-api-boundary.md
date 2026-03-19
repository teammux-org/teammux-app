# Codex Audit Stream A2 — C API Boundary Safety

## Your Role

You are an expert systems programmer auditing the C API
boundary between a Zig engine and a Swift application.
This is a read-only audit. You MUST NOT modify any source
files, make commits, or run git push. Findings only.

## Mandatory Reading (do all of these first, in parallel)

1. AGENTS.md
2. CLAUDE.md
3. engine/include/teammux.h — read every declaration,
   every comment, every nullable annotation
4. engine/src/main.zig — all export fn implementations
5. macos/Sources/Teammux/Engine/EngineClient.swift —
   every tm_* call site

## Audit Focus

**Nullable pointer contracts:**
- Which tm_* functions can return NULL?
- Is every NULL return documented in the header?
- Does every Swift call site guard against NULL
  (guard let, optional binding)?
- Are there tm_* calls that assume non-NULL return
  without checking?

**String lifetime at the boundary:**
- For every const char* returned from the engine:
  - Is the lifetime documented in the header?
  - Is Swift copying it before the engine could free it?
  - Could the engine free the string between Swift
    receiving the pointer and using it?
  - Specifically audit: tm_worktree_path, tm_worktree_branch,
    tm_interceptor_path, tm_engine_last_error,
    tm_config_get, tm_history_load entries

**Caller responsibility contracts:**
- Which functions require tm_free_string?
- Which require tm_history_free, tm_pr_free,
  tm_conflicts_free?
- Is every caller in EngineClient.swift calling the
  right free function after use?
- Are there any double-free risks (Swift calls free,
  engine also frees on next call)?

**NULL parameter safety in exports:**
- Every export fn in main.zig — does it guard against
  NULL engine pointer?
- Does it guard against NULL string parameters where
  the C contract allows NULL?
- Are there export functions where a NULL parameter
  would cause an immediate crash vs a graceful error?

**tm_* confinement violation check:**
- Search ALL Swift files for direct tm_* calls
- Any tm_* call outside EngineClient.swift is a
  critical violation — report file and line

**Struct layout safety:**
- tm_history_entry_t, tm_conflict_t, tm_pr_t, tm_worker_t
- Are all fields accessed by Swift matching the Zig
  struct layout exactly?
- Any padding or alignment assumptions that could be wrong
  on Apple Silicon?

## Search Commands to Run

  rg "tm_" macos/Sources/Teammux/ --include="*.swift" -l
  rg "tm_[a-z_]+" macos/Sources/Teammux/ --include="*.swift" \
    | grep -v "EngineClient.swift"
  rg "guard let|if let" \
    macos/Sources/Teammux/Engine/EngineClient.swift \
    | grep "tm_"
  rg "tm_free_string|tm_history_free|tm_pr_free|tm_conflicts_free" \
    macos/Sources/Teammux/Engine/EngineClient.swift
  rg "const char\*|nullable|must.*free|must not free" \
    engine/include/teammux.h
  rg "^export fn tm_" engine/src/main.zig

## Output — Two files required

**File 1 — Detailed findings:**
Write to: docs/codex-audits/audit-001-post-v014/FINDINGS-D2-c-api-boundary.md

Use this exact format for each finding:

## [SEVERITY] Short descriptive title

**File:** path/to/file:line_number
**Pattern:** (null contract / string lifetime / caller responsibility /
             null parameter / confinement violation / struct layout)
**Description:** What the issue is and why it matters.
**Evidence:**
  (relevant code snippet, max 10 lines)
**Recommendation:** Specific fix.

Severity: CRITICAL / IMPORTANT / SUGGESTION

At the end write a ## Domain Summary section.

**File 2 — Triage summary:**
Write to: docs/codex-audits/audit-001-post-v014/SUMMARY-D2-c-api-boundary.md

# Audit Summary — Domain 2: C API Boundary Safety

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
    docs/codex-audits/audit-001-post-v014/FINDINGS-D2-c-api-boundary.md \
    docs/codex-audits/audit-001-post-v014/SUMMARY-D2-c-api-boundary.md
  git commit -m "audit(a2): D2 C API boundary — findings + summary"
  git push origin audit/a2-c-api-boundary
  gh pr create \
    --title "Audit A2: C API Boundary findings" \
    --body "Read-only audit. Two files: FINDINGS-D2 + SUMMARY-D2. No code changes." \
    --base main

## Hard Rules

- DO NOT modify any source files under any circumstances
- DO NOT make commits until findings are complete
- DO NOT run git push until both output files are written
- DO NOT switch branches or modify AGENTS.md
