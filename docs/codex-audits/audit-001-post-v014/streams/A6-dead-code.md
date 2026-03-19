# Codex Audit Stream A6 — Dead Code & Tech Debt

## Your Role

You are a codebase auditor identifying unused code,
unreachable paths, and providing a prioritized assessment
of open tech debt items TD21-TD28. This is a read-only
audit. You MUST NOT modify any source files, make commits,
or run git push. Findings only.

## Mandatory Reading (do all of these first, in parallel)

1. AGENTS.md
2. CLAUDE.md
3. docs/TECH_DEBT.md — read every TD21-TD28 entry carefully
4. engine/include/teammux.h — every exported function
5. engine/src/main.zig — all export fn declarations
6. macos/Sources/Teammux/Engine/EngineClient.swift —
   every tm_* call
7. macos/Sources/Teammux/Models/CoordinationTypes.swift
8. macos/Sources/Teammux/Models/TeamMessage.swift

## Audit Focus

**Exported C API functions never called from Swift:**
- List every export fn in main.zig
- Cross-reference against every tm_* call in EngineClient.swift
- Any exported function with no Swift caller is dead API surface
- Note: some exports may be intentional future API —
  flag but do not assume all dead exports are bugs

**Zig functions and structs never referenced:**
- pub fn defined in engine/src/ but never called from
  main.zig or any other module
- Structs defined but never instantiated
- pub fn that could be private fn (unexported)

**Swift @Published properties never observed in any view:**
- Every @Published var in EngineClient.swift
- For each: search ALL view files (.swift in macos/) for
  any reference to that property name
- Any @Published with zero view observers is dead weight
  (still may be used in EngineClient internally — check)

**Swift types never used:**
- CoordinationTypes.swift: any struct or enum never
  referenced in views or EngineClient
- TeamMessage.swift: any MessageType case never matched
  in the EngineClient message callback switch

**Unreachable code paths:**
- Switch statements with cases that can never be reached
  given the message type registry (values 0-15 defined)
- Error handling branches that can never trigger given
  the actual error types a function can return

**TD21-TD28 impact assessment:**
For each open tech debt item in docs/TECH_DEBT.md, provide:
- Actual current impact (observable bug / latent risk / cosmetic)
- Estimated fix complexity (hours / days)
- Recommended priority sprint
- Whether it should be in the audit-address sprint,
  v0.1.5, or deferred to v0.2

## Search Commands to Run

  # All exported engine functions
  rg "^export fn tm_" engine/src/main.zig | sort

  # All Swift tm_* calls (deduplicated)
  rg "tm_[a-z_]+" \
    macos/Sources/Teammux/Engine/EngineClient.swift \
    -o | sort | uniq

  # All @Published properties
  rg "@Published var" \
    macos/Sources/Teammux/Engine/EngineClient.swift

  # For each property name found above, search views:
  rg "<property_name>" macos/Sources/Teammux/ \
    --include="*.swift" -l

  # All pub fn in engine
  rg "^pub fn " engine/src/ --include="*.zig" -l

  # MessageType cases
  rg "case [a-z]" \
    macos/Sources/Teammux/Models/TeamMessage.swift

  # Message callback switch in EngineClient
  rg "\.peerQuestion|\.delegation|\.prReady|\.prStatus|\
\.dispatch|\.response|\.completion|\.question|\.error|\
\.task|\.instruction|\.context|\.statusRequest|\
\.statusReport|\.broadcast" \
    macos/Sources/Teammux/Engine/EngineClient.swift

## Output — Two files required

**File 1 — Detailed findings:**
Write to: docs/codex-audits/audit-001-post-v014/FINDINGS-D6-dead-code.md

Use this exact format for code findings:

## [SEVERITY] Short descriptive title

**File:** path/to/file:line_number
**Pattern:** (dead export / dead zig fn / dead @Published /
             dead Swift type / unreachable path)
**Description:** Why this is dead and what the impact is.
**Evidence:**
  (relevant code snippet or grep result, max 10 lines)
**Recommendation:** Remove / make private / document as intentional.

Severity: CRITICAL / IMPORTANT / SUGGESTION

For tech debt items use this format:

## Tech Debt Assessment: TD{N} — {title}

**Current impact:** (observable bug / latent risk / cosmetic)
**Fix complexity:** (hours / days)
**Recommended sprint:** (audit-address / v0.1.5 / v0.2)
**Rationale:** One sentence.

At the end write a ## Domain Summary section.

**File 2 — Triage summary:**
Write to: docs/codex-audits/audit-001-post-v014/SUMMARY-D6-dead-code.md

# Audit Summary — Domain 6: Dead Code & Tech Debt

## Severity Counts
- CRITICAL: N
- IMPORTANT: N
- SUGGESTION: N
- TOTAL: N

## Top 3 Issues
1. [SEVERITY] Title — one sentence — file:line
2. [SEVERITY] Title — one sentence — file:line
3. [SEVERITY] Title — one sentence — file:line

## TD21-TD28 Priority Order
Ordered by recommended sprint and impact:
1. TD{N} — {title} — audit-address — (one sentence why)
2. TD{N} — {title} — v0.1.5 — (one sentence why)
... etc

## Recommended Sprint Allocation
- Audit-address sprint: (list finding titles + TD items)
- v0.1.5: (list finding titles + TD items)
- v0.2 / defer: (list finding titles + TD items)

## Systemic Patterns
One paragraph on recurring patterns.

## When Done — Raise PR

  git add \
    docs/codex-audits/audit-001-post-v014/FINDINGS-D6-dead-code.md \
    docs/codex-audits/audit-001-post-v014/SUMMARY-D6-dead-code.md
  git commit -m "audit(a6): D6 dead code and tech debt — findings + summary"
  git push origin audit/a6-dead-code
  gh pr create \
    --title "Audit A6: Dead Code & Tech Debt findings" \
    --body "Read-only audit. Two files: FINDINGS-D6 + SUMMARY-D6. No code changes." \
    --base main

## Hard Rules

- DO NOT modify any source files under any circumstances
- DO NOT make commits until findings are complete
- DO NOT run git push until both output files are written
- DO NOT switch branches or modify AGENTS.md
