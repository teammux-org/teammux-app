# Codex Audit Stream A1 — Memory Safety

## Your Role

You are an expert Zig memory safety auditor performing a
deep static analysis of the Teammux engine. This is a
read-only audit. You MUST NOT modify any source files,
make commits, or run git push. Findings only.

## Mandatory Reading (do all of these first, in parallel)

1. AGENTS.md — project overview and hard constraints
2. CLAUDE.md — conventions and rules
3. engine/include/teammux.h — C API contract
4. docs/TECH_DEBT.md — known debt
5. engine/src/main.zig
6. engine/src/worktree_lifecycle.zig
7. engine/src/ownership.zig
8. engine/src/bus.zig
9. engine/src/history.zig
10. engine/src/hotreload.zig
11. engine/src/interceptor.zig
12. engine/src/commands.zig
13. engine/src/merge.zig
14. engine/src/github.zig
15. engine/src/worktree.zig
16. engine/src/config.zig

Then run: cd engine && zig build test
Confirm 356 tests pass before proceeding.
If the build runner crashes transiently, retry once.

## Audit Focus

Investigate every one of these patterns across ALL engine files:

**Memory leaks:**
- Heap allocations (allocator.alloc, allocator.dupe,
  allocator.create, ArrayList.init, AutoHashMap.init)
  without a matching free/deinit in all exit paths
- Structs with init() that lack deinit() or where deinit
  is not called on all exit paths
- Slices returned from functions — is the caller responsible
  for freeing, and is this documented?

**Use-after-free:**
- Pointers or slices stored after the owning allocation
  has been freed
- C strings (const char*) returned to Swift that may be
  freed by the engine before Swift copies them
- Any slice pointing into a freed ArrayList or HashMap value

**Double-free:**
- Values freed in both a success path and an error path
- Values freed in both a function body and a deferred block
- Pointers freed in both a child struct deinit and a parent
  struct deinit

**Ownership confusion:**
- Strings duped on store vs borrowed — is ownership clear
  at every callsite?
- AutoHashMap entries: when an entry is removed or
  overwritten, is the old value freed?
- WorktreeRegistry, FileOwnershipRegistry, HistoryLogger,
  RoleWatcher — trace full lifecycle for all owned strings

**errdefer correctness:**
- Partial allocation sequences — if step 3 of 5 fails,
  are steps 1 and 2 properly cleaned up?
- errdefer blocks that free a value that may not have
  been fully initialized yet

**C API boundary lifetime:**
- lastError string: allocated, returned to Swift as
  const char*, freed when? Can Swift hold a dangling pointer?
- lastConfigGetStr: same analysis
- cacheCstr pattern: is the cached string freed before
  reallocating? Can two callers race on it?
- Any const char* return value not documented as
  caller-must-not-free in the header

## Search Commands to Run

  rg "allocator\.(alloc|dupe|create|dupeZ)" engine/src/
  rg "allocator\.free|allocator\.destroy|\.deinit\(\)" engine/src/
  rg "errdefer" engine/src/
  rg "const char\*" engine/include/teammux.h
  rg "lastError|cacheCstr|last_error" engine/src/main.zig
  rg "\.put\b|\.remove\b|\.getOrPut\b" engine/src/
  rg "return.*\[\]|return.*Ptr|return.*ptr" engine/src/

## Output — Two files required

**File 1 — Detailed findings:**
Write to: docs/codex-audits/audit-001-post-v014/FINDINGS-D1-memory-safety.md

Use this exact format for each finding:

## [SEVERITY] Short descriptive title

**File:** path/to/file.zig:line_number
**Pattern:** (leak / use-after-free / double-free / ownership / errdefer / C boundary)
**Description:** What the issue is and why it matters.
**Evidence:**
  (relevant code snippet, max 10 lines)
**Recommendation:** Specific fix.

Severity: CRITICAL / IMPORTANT / SUGGESTION

At the end of FINDINGS write a ## Domain Summary section:
- Total findings by severity
- Top 3 most critical issues
- Any patterns suggesting systemic issues

**File 2 — Triage summary:**
Write to: docs/codex-audits/audit-001-post-v014/SUMMARY-D1-memory-safety.md

Use this exact structure:

# Audit Summary — Domain 1: Memory Safety

## Severity Counts
- CRITICAL: N
- IMPORTANT: N
- SUGGESTION: N
- TOTAL: N

## Top 3 Issues
1. [SEVERITY] Title — one sentence description — file:line
2. [SEVERITY] Title — one sentence description — file:line
3. [SEVERITY] Title — one sentence description — file:line

## Recommended Sprint Allocation
- Audit-address sprint: (list finding titles)
- v0.1.5: (list finding titles)
- v0.2 / defer: (list finding titles)

## Systemic Patterns
One paragraph: any recurring patterns suggesting a
systemic issue rather than isolated bugs.

## When Done — Raise PR

  git add \
    docs/codex-audits/audit-001-post-v014/FINDINGS-D1-memory-safety.md \
    docs/codex-audits/audit-001-post-v014/SUMMARY-D1-memory-safety.md
  git commit -m "audit(a1): D1 memory safety — findings + summary"
  git push origin audit/a1-memory-safety
  gh pr create \
    --title "Audit A1: Memory Safety findings" \
    --body "Read-only audit. Two files: FINDINGS-D1 + SUMMARY-D1. No code changes." \
    --base main

## Hard Rules

- DO NOT modify any source files under any circumstances
- DO NOT make commits until findings are complete
- DO NOT run git push until both output files are written
- DO NOT switch branches or modify AGENTS.md
