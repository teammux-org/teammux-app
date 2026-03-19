# Codex Audit Stream A5 — Performance

## Your Role

You are a performance engineer auditing a Zig+Swift system
for hot-path inefficiencies, unnecessary allocations, and
scalability concerns. This is a read-only audit. You MUST
NOT modify any source files, make commits, or run git push.
Findings only.

## Mandatory Reading (do all of these first, in parallel)

1. AGENTS.md
2. CLAUDE.md
3. engine/src/bus.zig
4. engine/src/history.zig
5. engine/src/commands.zig
6. engine/src/ownership.zig
7. engine/src/main.zig — focus on busSendBridge and
   all message routing paths
8. engine/src/interceptor.zig
9. macos/Sources/Teammux/Engine/EngineClient.swift —
   focus on message callback and all @Published updates
10. macos/Sources/Teammux/RightPane/LiveFeedView.swift

## Audit Focus

**Hot path allocations:**
- The full bus message routing path: every allocation
  between a worker writing a command file and the Swift
  UI updating
- busSendBridge in main.zig: called on every message —
  any per-call heap allocations that could be amortized?
- JSON payload construction in handlers: allocPrint on
  every call — could payloads be stack-allocated for
  small fixed-size payloads?

**Command file watcher loop:**
- How often does it poll? Is the interval appropriate
  for interactive use?
- Does it allocate on every poll iteration even when
  no files are present?
- Is kqueue used for file change detection or is it a
  sleep-based polling loop?

**history.zig O(n) append:**
- The atomic write pattern reads entire
  completion_history.jsonl, appends one line, writes all
- This is O(n) per append — at what file size does this
  become a problem?
- How many completions would a typical v0.1.4 session
  generate? Is this currently acceptable or a real risk?

**Ownership registry hot path:**
- FileOwnershipRegistry.checkCapability is called before
  every file write by an agent — how expensive is it?
- Is the mutex held during the entire check or just
  during the HashMap lookup?
- With 10 workers and 100 files each, what is the
  worst-case registry size? Is AutoHashMap appropriate?

**Swift @Published update frequency:**
- How many @Published properties does EngineClient have?
- Which ones update on every incoming message?
- Each @Published update triggers SwiftUI diff on all
  observers — are there batching opportunities?
- Does autonomousDispatches update on every completion
  and trigger a full LiveFeedView redraw?

**String allocations in the Swift bridge:**
- How many String(cString:) calls happen per message?
  Each allocates on the Swift heap.
- Are there repeated String(cString:) calls for the
  same C string in the same function call?

**Interceptor wrapper generation:**
- generateInterceptorScript creates a large multiline
  string — when is this called?
- Is it called more than necessary (e.g. on every
  hot-reload even if deny patterns haven't changed)?

## Search Commands to Run

  rg "allocPrint|\.alloc\b|\.dupe\b" \
    engine/src/bus.zig engine/src/main.zig
  rg "sleep|poll|kqueue|inotify|NOTE_WRITE|NOTE_RENAME" \
    engine/src/commands.zig engine/src/hotreload.zig
  rg "@Published" \
    macos/Sources/Teammux/Engine/EngineClient.swift | wc -l
  rg "String(cString:|String(bytes:" \
    macos/Sources/Teammux/Engine/EngineClient.swift
  rg "Mutex|mutex|\.lock\(\)|\.unlock\(\)" \
    engine/src/ownership.zig
  rg "generateInterceptorScript|pub fn install" \
    engine/src/interceptor.zig engine/src/hotreload.zig \
    engine/src/main.zig
  rg "completion_history|history_logger" engine/src/main.zig

## Output — Two files required

**File 1 — Detailed findings:**
Write to: docs/codex-audits/audit-001-post-v014/FINDINGS-D5-performance.md

Use this exact format for each finding:

## [SEVERITY] Short descriptive title

**File:** path/to/file:line_number
**Pattern:** (hot path alloc / O(n) operation / mutex contention /
             SwiftUI redraw / string alloc / interceptor regen)
**Impact:** HIGH / MEDIUM / LOW (based on call frequency × cost)
**Description:** What the issue is and why it matters.
**Evidence:**
  (relevant code snippet, max 10 lines)
**Recommendation:** Specific fix or optimization.

Severity: CRITICAL / IMPORTANT / SUGGESTION

At the end write a ## Domain Summary section.

**File 2 — Triage summary:**
Write to: docs/codex-audits/audit-001-post-v014/SUMMARY-D5-performance.md

# Audit Summary — Domain 5: Performance

## Severity Counts
- CRITICAL: N
- IMPORTANT: N
- SUGGESTION: N
- TOTAL: N

## Top 3 Issues
1. [SEVERITY/IMPACT] Title — one sentence — file:line
2. [SEVERITY/IMPACT] Title — one sentence — file:line
3. [SEVERITY/IMPACT] Title — one sentence — file:line

## Recommended Sprint Allocation
- Audit-address sprint: (list finding titles)
- v0.1.5: (list finding titles)
- v0.2 / defer: (list finding titles)

## Systemic Patterns
One paragraph on recurring patterns.

## When Done — Raise PR

  git add \
    docs/codex-audits/audit-001-post-v014/FINDINGS-D5-performance.md \
    docs/codex-audits/audit-001-post-v014/SUMMARY-D5-performance.md
  git commit -m "audit(a5): D5 performance — findings + summary"
  git push origin audit/a5-performance
  gh pr create \
    --title "Audit A5: Performance findings" \
    --body "Read-only audit. Two files: FINDINGS-D5 + SUMMARY-D5. No code changes." \
    --base main

## Hard Rules

- DO NOT modify any source files under any circumstances
- DO NOT make commits until findings are complete
- DO NOT run git push until both output files are written
- DO NOT switch branches or modify AGENTS.md
