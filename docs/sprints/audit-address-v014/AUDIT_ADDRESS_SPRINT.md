# Audit-Address Sprint — Post Audit 001

**Status:** In Progress
**Based on:** docs/codex-audits/audit-001-post-v014/ACTION-PLAN.md
**Fixing:** 4 CRITICAL + 12 IMPORTANT findings + TD25

## Stream Registry

| Stream | Branch | Owns | Complexity |
|--------|--------|------|------------|
| AA1 | fix/aa1-lifetime-ownership | C1, C2, I1, I9 | complex |
| AA2 | fix/aa2-concurrency-locking | I2, I3, I10 | complex |
| AA3 | fix/aa3-architecture-teamlead | C3, C4, TD25 | complex |
| AA4 | fix/aa4-capi-silent-failures | I4, I5, I12 | medium |
| AA5 | fix/aa5-performance-hotpath | I14, I16 | medium |
| AA6 | fix/aa6-dead-code-pruning | I17, I18, S8-S13 | medium |

## Merge Order (when PRs arrive)

AA6 → AA5 → AA4 → AA2 → AA1 → AA3

AA3 last — most invasive (worktree unification + Team Lead).
AA6 first — Swift+cleanup, lowest conflict risk.

## Key Files Per Stream

- AA1: engine/src/main.zig, engine/src/commands.zig
- AA2: engine/src/ownership.zig, engine/src/worktree.zig,
       engine/src/main.zig
- AA3: engine/src/main.zig, engine/src/worktree_lifecycle.zig,
       engine/src/worktree.zig, engine/src/interceptor.zig,
       macos/Sources/Teammux/RightPane/TeamLeadTerminalView.swift
- AA4: engine/src/main.zig, engine/src/merge.zig,
       engine/include/teammux.h
- AA5: engine/src/bus.zig, engine/src/main.zig,
       macos/Sources/Teammux/Engine/EngineClient.swift
- AA6: engine/src/main.zig, engine/include/teammux.h,
       macos/Sources/Teammux/Engine/EngineClient.swift,
       macos/Sources/Teammux/Models/TeamMessage.swift,
       macos/Sources/Teammux/RightPane/DiffView.swift,
       macos/Sources/Teammux/RightPane/RightPaneView.swift

## References

- Full finding details: docs/codex-audits/audit-001-post-v014/ACTION-PLAN.md
- Audit findings: docs/codex-audits/audit-001-post-v014/FINDINGS-D*.md
