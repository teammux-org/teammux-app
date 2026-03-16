# Teammux Role Library

This directory contains the default role definitions shipped with Teammux. Each `.toml` file defines a single role that can be assigned to a worker agent at spawn time.

## TOML Format Reference

Every role file must contain all 4 sections with all fields populated.

### [identity]

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique kebab-case identifier (must match filename without `.toml`) |
| `name` | string | Human-readable display name |
| `division` | string | One of: `engineering`, `design`, `product`, `testing`, `project-management`, `strategy`, `specialized` |
| `emoji` | string | Single emoji for UI display |
| `description` | string | Brief role description covering technologies and focus areas |

### [capabilities]

| Field | Type | Description |
|-------|------|-------------|
| `read` | string[] | Glob patterns for readable paths (typically `["**"]` for full read access) |
| `write` | string[] | Glob patterns for writable paths |
| `deny_write` | string[] | Glob patterns explicitly denied for writing (takes precedence over `write`) |
| `can_push` | bool | Whether the role can push branches to remote |
| `can_merge` | bool | Whether the role can approve and execute merges |

### [triggers_on]

| Field | Type | Description |
|-------|------|-------------|
| `events` | string[] | Engine events that auto-spawn this role (empty for manual-only roles) |

### [context]

| Field | Type | Description |
|-------|------|-------------|
| `mission` | string | One-line mission statement for the role |
| `focus` | string | Key focus areas and concerns |
| `deliverables` | string[] | What this role is expected to produce |
| `rules` | string[] | Non-negotiable constraints (at least 4, role-specific) |
| `workflow` | string[] | Step-by-step workflow for completing tasks (at least 4 steps) |
| `success_metrics` | string[] | How to measure task completion quality (at least 3 metrics) |

## Glob Pattern Syntax

All paths are relative to the project root. Patterns follow gitignore-style semantics:

- `**` matches any directory depth (zero or more levels)
- `*` matches any characters within a single path segment
- `?` matches any single character

Examples:
- `src/frontend/**` — all files under src/frontend/ at any depth
- `**/*.md` — all Markdown files anywhere in the project
- `tests/**` — all files under tests/ at any depth
- `Dockerfile*` — Dockerfile, Dockerfile.dev, Dockerfile.prod, etc.

## Capability Evaluation Order

1. Check `deny_write` patterns first — if any match, access is **denied**
2. Check `write` patterns — if any match, access is **allowed**
3. Default: **denied** (no explicit allow = no access)

`deny_write` always takes precedence over `write`.

## Divisions

| Division | Count | Description |
|----------|-------|-------------|
| `engineering` | 12 | Hands-on code and technical implementation roles |
| `design` | 4 | UI/UX design, research, and brand roles |
| `product` | 3 | Product management and prioritization roles |
| `testing` | 4 | QA, performance, accessibility, and validation roles |
| `project-management` | 3 | Technical leadership and engineering management roles |
| `strategy` | 2 | Architecture and developer advocacy roles |
| `specialized` | 3 | Orchestration, compliance, and security audit roles |

## Role Search Path

When a worker is assigned a role ID, Teammux resolves the role file using this search order (first match wins):

1. `{project_root}/.teammux/roles/{role_id}.toml` — project-local overrides
2. `~/.teammux/roles/{role_id}.toml` — user-level custom roles
3. `{bundled_roles_path}/{role_id}.toml` — this directory (Teammux defaults)

Project-local overrides let teams customize role scopes for their specific codebase structure without modifying the bundled defaults.

## Example Role

See `frontend-engineer.toml` for a complete example with all sections populated.

## Contributing a New Role

1. Create a new `.toml` file in this directory named `{role-id}.toml`
2. Include all 4 sections with all fields — no field may be omitted
3. Ensure `id` matches the filename (without `.toml` extension)
4. Use an existing role in the same division as a reference for scope patterns
5. Write substantive, role-specific content — generic placeholder text will be rejected
6. `deny_write` patterns must realistically reflect what the role should NOT modify
7. Include at least 4 rules, 4 workflow steps, and 3 success metrics
8. Test your role by assigning it to a worker and verifying capability enforcement
