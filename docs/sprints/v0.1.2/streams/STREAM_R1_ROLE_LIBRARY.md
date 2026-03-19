# Stream R1 — Role Library

## Your branch
`feat/v012-stream-r1-role-library`

## Your worktree path
`../teammux-stream-r1`

## Read first
1. `CLAUDE.md` — hard rules, build commands, sprint workflow
2. `TECH_DEBT.md` — open and resolved debt items
3. `V012_SPRINT.md` — full sprint spec, Section 3 "stream-R1 — Role Library"

---

## Your mission

Create the Teammux default role library: 31 role TOML files under a new `roles/` directory at repo root, plus `roles/README.md` documenting the format for community contributions.

### Role TOML format

Every file must have all 8 sections:

```toml
[identity]
id = "frontend-engineer"
name = "Frontend Engineer"
division = "engineering"
emoji = "🎨"
description = "React, Vue, UI implementation, component architecture, Core Web Vitals"

[capabilities]
read = ["**"]
write = ["src/frontend/**", "src/components/**", "src/styles/**", "tests/frontend/**"]
deny_write = ["src/backend/**", "src/api/**", "infrastructure/**"]
can_push = false
can_merge = false

[triggers_on]
events = []

[context]
mission = "Build pixel-perfect, performant UI components that match designs exactly"
focus = "Component architecture, accessibility, performance, design system adherence"
deliverables = [
  "Working components with tests",
  "Storybook entries where applicable",
  "No performance regressions"
]
rules = [
  "Never modify backend or API files",
  "Always write component tests alongside implementation",
  "Follow design system tokens — never hardcode colors or spacing",
  "Check accessibility compliance before marking complete"
]
workflow = [
  "Read the task description and identify affected components",
  "Check existing design system tokens and patterns first",
  "Implement with accessibility in mind from the start",
  "Write tests covering user interactions not just rendering",
  "Verify no performance regressions before marking complete"
]
success_metrics = [
  "Component renders correctly across breakpoints",
  "Tests pass with meaningful coverage",
  "No accessibility violations (WCAG 2.1 AA)",
  "Build passes with no new warnings"
]
```

### Roles to ship (31 total across 7 divisions)

**Engineering (12):** `frontend-engineer`, `backend-engineer`, `fullstack-engineer`, `devops-engineer`, `sre-engineer`, `security-engineer`, `mobile-engineer`, `technical-writer`, `dx-engineer`, `incident-commander`, `embedded-engineer`, `ai-engineer`

**Design (4):** `ui-designer`, `ux-researcher`, `ux-architect`, `brand-guardian`

**Product (3):** `product-manager`, `sprint-prioritizer`, `feedback-synthesizer`

**Testing (4):** `qa-engineer`, `performance-benchmarker`, `accessibility-auditor`, `reality-checker`

**Project Management (3):** `tech-lead`, `staff-engineer`, `engineering-manager`

**Strategy (2):** `systems-architect`, `developer-advocate`

**Specialized (3):** `agents-orchestrator`, `compliance-auditor`, `security-auditor`

### roles/README.md

Must include format reference, field descriptions, example role, and contribution instructions.

### Quality bar

Every role must have all 8 sections populated with substantive content specific to that role. Generic placeholder text is a FAIL. The `deny_write` patterns must be realistic for that role's actual scope.

---

## WAIT CHECK

None — R1 has no dependencies. You can start immediately.

## Merge order context

R1 merges first (parallel with R3). R2 depends on R1 being merged before it can start implementation, as R1's role format must be finalised in the repo before R2 can validate its generated output against real role files.

---

## Done when
- 31 `.toml` files exist under `roles/`, each passing format validation
- `roles/README.md` documents the format completely
- PR raised from `feat/v012-stream-r1-role-library`

---

## Core rules
- Never modify `src/` (Ghostty upstream)
- All `tm_*` calls go through `EngineClient.swift` only
- No force-unwraps in production code
- `engine/include/teammux.h` is the authoritative C API contract
- TECH_DEBT.md updated when new debt is discovered
