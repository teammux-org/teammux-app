# Stream R2 — Role-Aware Spawn

## Your branch
`feat/v012-stream-r2-role-spawn`

## Your worktree path
`../teammux-stream-r2`

## Read first
1. `CLAUDE.md` — hard rules, build commands, sprint workflow
2. `TECH_DEBT.md` — open and resolved debt items
3. `V012_SPRINT.md` — full sprint spec, Section 3 "stream-R2 — Role-Aware Spawn"

---

## Your mission

Extend `engine/src/worktree.zig` so that when a worker is spawned with a role, the generated CLAUDE.md in the worktree is rich and role-specific instead of generic.

### Files to modify
- `engine/src/worktree.zig`

### writeContextFile extended signature

```zig
pub fn writeContextFile(
    allocator: Allocator,
    worktree_path: []const u8,
    agent_type: config.AgentType,
    task_description: []const u8,
    role_def: ?config.RoleDefinition,  // new param
    branch_name: []const u8,           // new param (already available at call site)
) !void
```

### Generated CLAUDE.md when role_def is non-null

```markdown
# {role.name} — Teammux Worker

## Your role
{role.description}

## Your mission for this task
{task_description}

## What you own in this worktree
**Write access:**
{role.write_patterns as bullet list}

**You must NOT modify (engine will block attempts):**
{role.deny_write_patterns as bullet list}

## Rules (non-negotiable)
{role.rules as numbered list}

## Workflow
{role.workflow as numbered list}

## Definition of done
{role.deliverables as checkbox list}
{role.success_metrics as checkbox list}

## Teammux coordination
- Branch: {branch_name}
- Report completion: /teammux-complete "{brief summary}"
- Request guidance: /teammux-question "{your question}"
- Your changes are isolated — git commands only affect this worktree
```

### Fallback when role_def is null
Existing generic CLAUDE.md behaviour unchanged. No regressions.

### New helper

```zig
fn generateRoleClaude(
    allocator: Allocator,
    role_def: config.RoleDefinition,
    task_description: []const u8,
    branch_name: []const u8,
) ![]u8
```

### Tests
- Generated CLAUDE.md contains all role sections
- Correct branch name present
- Correct deny_write patterns listed
- Fallback to generic when role_def is null
- TOML parse errors handled gracefully

---

## WAIT CHECK

**You MUST wait for stream-R1 to be merged into main before implementing.** R1's role format must be finalised in the repo before R2 can validate its generated output against real role files. The main thread orchestrator will notify you when R1 is merged. Pull main at that point before starting work.

## Merge order context

R1 → R3 → **R2** → R4 → R5/R8 (parallel) → R6 → R7

R2 merges after R1. R4 depends on R2 being merged.

---

## Done when
- `cd engine && zig build test` — all tests pass
- Spawning a worker with `role = "frontend-engineer"` produces a CLAUDE.md with the Frontend Engineer's rules and workflow
- Spawning without a role produces the existing generic CLAUDE.md
- PR raised from `feat/v012-stream-r2-role-spawn`

---

## Core rules
- Never modify `src/` (Ghostty upstream)
- All `tm_*` calls go through `EngineClient.swift` only
- No force-unwraps in production code
- `zig build test` must pass before raising PR
- `engine/include/teammux.h` is the authoritative C API contract
- TECH_DEBT.md updated when new debt is discovered
