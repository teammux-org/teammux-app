# Codex Audit Stream A3 — Systems Architecture

## Your Role

You are a senior systems architect reviewing a Zig+Swift
native macOS application for structural issues. This is a
read-only audit. You MUST NOT modify any source files,
make commits, or run git push. Findings only.

## Mandatory Reading (do all of these first, in parallel)

1. AGENTS.md
2. CLAUDE.md
3. docs/TECH_DEBT.md
4. engine/include/teammux.h
5. engine/src/main.zig
6. engine/src/bus.zig
7. engine/src/worktree_lifecycle.zig
8. engine/src/ownership.zig
9. engine/src/hotreload.zig
10. engine/src/commands.zig
11. macos/Sources/Teammux/Engine/EngineClient.swift
12. macos/Sources/Teammux/Models/CoordinationTypes.swift
13. macos/Sources/Teammux/Models/TeamMessage.swift

## Audit Focus

**Module coupling and dependencies:**
- Which engine modules import which other modules?
- Are there circular dependencies?
- Is any module doing work that belongs in another?
- Does main.zig have too much responsibility?
  Should any logic be extracted to dedicated modules?

**Bus message routing correctness:**
- Every TM_MSG_* type (0-15): trace from engine send
  to Swift receive to UI update
- Are there message types sent but never handled in Swift?
- Are there message types handled in Swift but never
  sent by the engine?
- Can a message be silently dropped at any point?
- TM_MSG_ERROR (6): consistently used for all error
  conditions, or are some errors silent?

**PTY lifecycle symmetry:**
- For every PTY spawned: is there a guaranteed dismiss path?
- What happens if the PTY process dies unexpectedly —
  is the engine notified? Does it clean up worktree and
  registry entries?
- Worktree create/dismiss symmetry: if tm_worker_dismiss
  is called but git worktree remove fails, what state remains?
- Are orphaned PTY sessions possible after crash or abnormal exit?

**Registry consistency:**
- FileOwnershipRegistry and WorktreeRegistry: can they
  get out of sync? (worker in one but not the other)
- What is the ordering guarantee between registry update
  and PTY spawn? Can a race exist?
- On session destroy: are all registries cleaned in
  the correct order to avoid use-after-free?

**@MainActor and Sendable correctness (Swift):**
- Are all @Published property updates happening on
  the main actor?
- Are there Sendable violations in CoordinationTypes.swift
  that could cause data races in strict concurrency?
- Is the message callback from the engine (C callback,
  unknown thread) safely dispatched to @MainActor before
  touching @Published properties?

**Team Lead structural constraints:**
- Is Team Lead (worker ID 0) actually prevented from
  writing files at the registry level?
- Is git push to main actually blocked for worker 0's PTY?
- Can the Team Lead role constraint be circumvented
  structurally — not by convention but by API?

## Search Commands to Run

  rg "@import|const .* = @import" engine/src/ --include="*.zig"
  rg "TM_MSG_|MessageType|msg_type" engine/src/ \
    macos/Sources/Teammux/
  rg "bus\.send|bus_send|busSendBridge" engine/src/main.zig
  rg "\.peerQuestion|\.delegation|\.prReady|\.prStatus|\
\.dispatch|\.response|\.completion|\.error" \
    macos/Sources/Teammux/Engine/EngineClient.swift
  rg "DispatchQueue|Task.*MainActor|@MainActor|MainActor\.run" \
    macos/Sources/Teammux/Engine/EngineClient.swift
  rg "Sendable" macos/Sources/Teammux/Models/
  rg "TM_WORKER_TEAM_LEAD|worker_id.*0|== 0" engine/src/

## Output — Two files required

**File 1 — Detailed findings:**
Write to: docs/codex-audits/audit-001-post-v014/FINDINGS-D3-architecture.md

Use this exact format for each finding:

## [SEVERITY] Short descriptive title

**File:** path/to/file:line_number
**Pattern:** (coupling / routing / PTY lifecycle / registry /
             concurrency / Team Lead constraint)
**Description:** What the issue is and why it matters.
**Evidence:**
  (relevant code snippet or grep result, max 10 lines)
**Recommendation:** Specific fix or structural change.

Severity: CRITICAL / IMPORTANT / SUGGESTION

At the end write a ## Domain Summary section.

**File 2 — Triage summary:**
Write to: docs/codex-audits/audit-001-post-v014/SUMMARY-D3-architecture.md

# Audit Summary — Domain 3: Systems Architecture

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
    docs/codex-audits/audit-001-post-v014/FINDINGS-D3-architecture.md \
    docs/codex-audits/audit-001-post-v014/SUMMARY-D3-architecture.md
  git commit -m "audit(a3): D3 architecture — findings + summary"
  git push origin audit/a3-architecture
  gh pr create \
    --title "Audit A3: Architecture findings" \
    --body "Read-only audit. Two files: FINDINGS-D3 + SUMMARY-D3. No code changes." \
    --base main

## Hard Rules

- DO NOT modify any source files under any circumstances
- DO NOT make commits until findings are complete
- DO NOT run git push until both output files are written
- DO NOT switch branches or modify AGENTS.md
