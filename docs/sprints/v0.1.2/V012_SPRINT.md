# Teammux — v0.1.2 Sprint Master Spec

**Version:** v0.1.2
**Built on:** v0.1.1 (tagged, shipped)
**Date:** March 2026

---

## 1. Sprint Overview

- **Goal:** Role definitions as first-class citizens — rich worker context at spawn,
  capability contracts enforced by the engine, PTY-level write enforcement,
  30+ role library shipping with Teammux by default
- **Session structure:** 8 parallel streams + 1 main thread orchestrator
- **Merge order:** R1 → R3 → R2 → R4 → R5/R8 (parallel) → R6 → R7

---

## 2. Stream Map

| Stream    | Worktree              | Branch                            | Owns                                      | Depends on      | Merges after        | Status   |
|-----------|-----------------------|-----------------------------------|-------------------------------------------|-----------------|---------------------|----------|
| stream-R1 | ../teammux-stream-r1  | feat/v012-stream-r1-role-library  | 31 role TOML files + roles/README.md      | nothing         | first (parallel R3) | MERGED   |
| stream-R3 | ../teammux-stream-r3  | feat/v012-stream-r3-config-role   | config.zig role field + validation        | R1 format spec  | first (parallel R1) | MERGED   |
| stream-R2 | ../teammux-stream-r2  | feat/v012-stream-r2-role-spawn    | worktree.zig rich CLAUDE.md generation    | R1 merged       | after R1            | MERGED   |
| stream-R4 | ../teammux-stream-r4  | feat/v012-stream-r4-ownership     | ownership.zig + teammux.h additions       | R2 merged       | after R2            | MERGED   |
| stream-R5 | ../teammux-stream-r5  | feat/v012-stream-r5-role-bridge   | EngineClient role + capability bridge     | R4 merged       | after R4            | MERGED   |
| stream-R8 | ../teammux-stream-r8  | feat/v012-stream-r8-interceptor   | interceptor.zig + PTY git enforcement     | R4 merged       | after R4 (par. R5)  | MERGED   |
| stream-R6 | ../teammux-stream-r6  | feat/v012-stream-r6-roster-ui     | roster role badges + spawn role picker    | R5 merged       | after R5            | MERGED   |
| stream-R7 | ../teammux-stream-r7  | feat/v012-stream-r7-polish        | TD8 resolution + integration polish       | R6 + R8 merged  | last                | PR RAISED |

---

## 3. Detailed Scope Per Stream

### stream-R1 — Role Library

**New directory:** `roles/` at repo root

**Role TOML format** — every file must have all sections:
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

**Roles to ship (31 total across 7 divisions):**

Engineering (12): `frontend-engineer`, `backend-engineer`, `fullstack-engineer`,
`devops-engineer`, `sre-engineer`, `security-engineer`, `mobile-engineer`,
`technical-writer`, `dx-engineer`, `incident-commander`, `embedded-engineer`,
`ai-engineer`

Design (4): `ui-designer`, `ux-researcher`, `ux-architect`, `brand-guardian`

Product (3): `product-manager`, `sprint-prioritizer`, `feedback-synthesizer`

Testing (4): `qa-engineer`, `performance-benchmarker`, `accessibility-auditor`,
`reality-checker`

Project Management (3): `tech-lead`, `staff-engineer`, `engineering-manager`

Strategy (2): `systems-architect`, `developer-advocate`

Specialized (3): `agents-orchestrator`, `compliance-auditor`, `security-auditor`

**Also ships:** `roles/README.md` documenting the TOML format spec for community
contributions. Must include format reference, field descriptions, example role,
and contribution instructions.

**Quality bar:** Every role must have all 8 sections populated with substantive
content specific to that role. Generic placeholder text is a FAIL. The
`deny_write` patterns must be realistic for that role's actual scope.

**Done when:**
- 31 `.toml` files exist under `roles/` each passing format validation
- `roles/README.md` documents the format completely
- PR raised from feat/v012-stream-r1-role-library

---

### stream-R3 — Config Role Field

**Files to modify:** `engine/src/config.zig`, `engine/include/teammux.h`
(additive only on header)

**WorkerConfig additions:**
```zig
pub const WorkerConfig = struct {
    id: []const u8,
    name: []const u8,
    agent: []const u8,
    model: []const u8,
    permissions: []const u8,
    role: ?[]const u8,          // ← new: role id e.g. "frontend-engineer"
    role_path: ?[]const u8,     // ← resolved at load time, not in TOML
};
```

**Role resolution logic:**
Search path order (first match wins):
1. `{project_root}/.teammux/roles/{role_id}.toml` — project-local overrides
2. `~/.teammux/roles/{role_id}.toml` — user-level custom roles
3. `{bundled_roles_path}/{role_id}.toml` — Teammux default library

**Bundled roles path** resolved as:
- `{executable_dir}/../Resources/roles/` (macOS app bundle)
- `{executable_dir}/roles/` (development build)

**New functions in config.zig:**
```zig
pub fn resolveRolePath(
    allocator: Allocator,
    role_id: []const u8,
    project_root: []const u8,
) !?[]u8

pub fn parseRoleDefinition(
    allocator: Allocator,
    role_path: []const u8,
) !RoleDefinition

pub const RoleDefinition = struct {
    id: []const u8,
    name: []const u8,
    division: []const u8,
    emoji: []const u8,
    description: []const u8,
    write_patterns: [][]const u8,
    deny_write_patterns: [][]const u8,
    can_push: bool,
    can_merge: bool,
    trigger_events: [][]const u8,
    mission: []const u8,
    focus: []const u8,
    deliverables: [][]const u8,
    rules: [][]const u8,
    workflow: [][]const u8,
    success_metrics: [][]const u8,
    // memory management
    pub fn deinit(self: *RoleDefinition, allocator: Allocator) void
};
```

**Graceful degradation:** If `role` is set but no matching file is found in any
search path, log a warning and continue with generic CLAUDE.md. Never error out.

**New C API additions to teammux.h:**
```c
typedef struct {
    const char* id;
    const char* name;
    const char* division;
    const char* emoji;
    const char* description;
    const char** write_patterns;
    uint32_t write_pattern_count;
    const char** deny_write_patterns;
    uint32_t deny_write_pattern_count;
} tm_role_t;

tm_result_t tm_role_resolve(tm_engine_t* engine,
                             const char* role_id,
                             tm_role_t** out_role);
void tm_role_free(tm_role_t* role);
tm_role_t** tm_roles_list(tm_engine_t* engine, uint32_t* count);
void tm_roles_list_free(tm_role_t** roles, uint32_t count);
```

**Tests:** role field parsing, all three search path levels, missing role
graceful degradation, search path precedence order, RoleDefinition parse
of each required field.

**Done when:**
- `cd engine && zig build test` — all tests pass including new role tests
- config.toml with `role = "frontend-engineer"` parses without error
- Missing role logs warning and continues (does not panic)
- PR raised from feat/v012-stream-r3-config-role

---

### stream-R2 — Role-Aware Spawn

**Files to modify:** `engine/src/worktree.zig`

**writeContextFile extended:**
```zig
pub fn writeContextFile(
    allocator: Allocator,
    worktree_path: []const u8,
    agent_type: config.AgentType,
    task_description: []const u8,
    role_def: ?config.RoleDefinition,  // ← new param
    branch_name: []const u8,           // ← new param (already available at call site)
) !void
```

**Generated CLAUDE.md when role_def is non-null:**
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

**Fallback when role_def is null:** existing generic CLAUDE.md behaviour
unchanged. No regressions.

**New helper:**
```zig
fn generateRoleClaude(
    allocator: Allocator,
    role_def: config.RoleDefinition,
    task_description: []const u8,
    branch_name: []const u8,
) ![]u8
```

**Tests:** generated CLAUDE.md contains all role sections, correct
branch name, correct deny_write patterns listed, fallback to generic
when role_def is null, TOML parse errors handled gracefully.

**WAIT CHECK:** Confirm stream-R1 has merged before implementing.
R1's role format must be finalised in the repo before R2 can validate
its generated output against real role files.

**Done when:**
- `cd engine && zig build test` — all tests pass
- Spawning a worker with `role = "frontend-engineer"` produces a
  CLAUDE.md with the Frontend Engineer's rules and workflow
- Spawning without a role produces the existing generic CLAUDE.md
- PR raised from feat/v012-stream-r2-role-spawn

---

### stream-R4 — FileOwnershipRegistry

**New file:** `engine/src/ownership.zig`

**New C API additions to teammux.h:**
```c
tm_result_t tm_ownership_check(tm_engine_t* engine,
                                uint32_t worker_id,
                                const char* file_path,
                                bool* out_allowed);
tm_result_t tm_ownership_register(tm_engine_t* engine,
                                   uint32_t worker_id,
                                   const char* path_pattern,
                                   bool allow_write);
tm_result_t tm_ownership_release(tm_engine_t* engine,
                                  uint32_t worker_id);
tm_ownership_entry_t** tm_ownership_get(tm_engine_t* engine,
                                         uint32_t worker_id,
                                         uint32_t* count);
void tm_ownership_free(tm_ownership_entry_t** entries, uint32_t count);

typedef struct {
    const char* path_pattern;
    uint32_t worker_id;
    bool allow_write;
} tm_ownership_entry_t;
```

**ownership.zig core:**
```zig
pub const PathRule = struct {
    pattern: []const u8,
    allow_write: bool,
};

pub const FileOwnershipRegistry = struct {
    allocator: Allocator,
    rules: AutoHashMap(WorkerId, []PathRule),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: Allocator) FileOwnershipRegistry
    pub fn deinit(self: *FileOwnershipRegistry) void
    pub fn register(self, worker_id, pattern, allow_write) !void
    pub fn release(self, worker_id) void
    pub fn check(self, worker_id, file_path) bool
    pub fn getRules(self, worker_id) ?[]PathRule
};
```

**check() logic:**
1. Get rules for worker_id. If none: default allow (no role = no restrictions).
2. Evaluate deny_write rules first (allow_write=false). If any match: return false.
3. Evaluate write rules (allow_write=true). If any match: return true.
4. Default: return false (deny if no explicit allow).

**Glob matching:** implement `globMatch(pattern, path) bool` supporting
`**` (any path segment depth), `*` (any single segment), `?` (any char).
Follow the same patterns used in `.gitignore` glob semantics.

**Integration with spawn/dismiss:**
- `tm_worker_spawn`: after worktree creation, if role has capabilities,
  call `ownership.register()` for all write and deny_write patterns
- `tm_worker_dismiss`: call `ownership.release(worker_id)`
- `tm_merge_reject`: call `ownership.release(worker_id)`

**Engine struct addition:**
```zig
ownership_registry: ownership.FileOwnershipRegistry,
```
Initialised in `Engine.create()`, cleaned up in `Engine.destroy()`.

**Tests:**
- glob matching: `**`, `*`, `?`, nested paths, edge cases
- deny precedence over allow
- multi-worker isolation (worker A cannot query worker B's rules)
- spawn populates registry from role capabilities
- dismiss clears registry entries
- default allow when no rules registered
- thread safety under concurrent check calls

**WAIT CHECK:** Confirm stream-R2 has merged. R4 needs the
`config.RoleDefinition` type to be stable before populating
the registry at spawn time.

**Done when:**
- `cd engine && zig build test` — all tests pass
- `tm_ownership_check` returns correct allow/deny for test cases
- Registry populated correctly from role capabilities at spawn
- PR raised from feat/v012-stream-r4-ownership

---

### stream-R5 — EngineClient Role Bridge

**New file:** `macos/Sources/Teammux/Models/RoleTypes.swift`
```swift
struct RoleDefinition: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let division: String
    let emoji: String
    let description: String
    let writePatterns: [String]
    let denyWritePatterns: [String]
}

enum RoleDivision: String, CaseIterable, Sendable {
    case engineering, design, product, testing
    case projectManagement = "project-management"
    case strategy, specialized
    var displayName: String { ... }
}
```

**EngineClient.swift additions (MARK: - Roles):**
```swift
@Published var availableRoles: [RoleDefinition] = []
@Published var workerRoles: [UInt32: RoleDefinition] = [:]

func loadAvailableRoles()
func roleForWorker(_ workerId: UInt32) -> RoleDefinition?
func checkCapability(workerId: UInt32, filePath: String) -> Bool
```

**Updated spawnWorker signature:**
```swift
func spawnWorker(
    agentBinary: String,
    agentType: TMAgentType,
    workerName: String,
    taskDescription: String,
    roleId: String?          // ← new, optional
) -> UInt32
```

**Callback threading:** same Unmanaged + Task @MainActor pattern
as all other EngineClient callbacks.

**Wraps:**
- `tm_role_resolve` → `func resolveRole(id: String) -> RoleDefinition?`
- `tm_roles_list` → `func loadAvailableRoles()`
- `tm_ownership_check` → `func checkCapability(workerId:filePath:) -> Bool`

**No UI changes** — UI is stream-R6's job.

**Tests:** role loading, capability check returns correct bool,
worker role mapping, spawn with and without role ID, available
roles list non-empty after loadAvailableRoles().

**WAIT CHECK:** Confirm stream-R4 has merged. Pull main and
verify `tm_ownership_check`, `tm_role_resolve`, `tm_roles_list`
exist in `engine/include/teammux.h` before implementing.

**Done when:**
- `./build.sh` passes end to end
- `engine.availableRoles` populated on session start
- `engine.checkCapability(workerId:filePath:)` returns correct result
- `engine.spawnWorker(..., roleId: "frontend-engineer")` works
- PR raised from feat/v012-stream-r5-role-bridge

---

### stream-R8 — Git Command Interceptor

**New file:** `engine/src/interceptor.zig`

**Approach:** At worker spawn time, write a wrapper shell script into
the worktree that shadows the real `git` binary. The script intercepts
`git add` commands, checks ownership, and either passes through or
blocks with a clear error message.

**Wrapper script written to `{worktree_path}/.git-wrapper/git`:**
```bash
#!/bin/bash
# Teammux git interceptor — do not modify
REAL_GIT=$(which -a git | grep -v "$(dirname "$0")" | head -1)

if [[ "$1" == "add" ]]; then
  # Extract files from args, send to ownership check socket
  # Blocked files get a clear error, allowed files pass through
  exec "$REAL_GIT" "$@"
else
  exec "$REAL_GIT" "$@"
fi
```

The wrapper communicates with the engine via a lightweight Unix domain
socket per worker session (or via environment variable injection
pointing to a check endpoint). The engine's interceptor module
handles the check requests.

**Simpler alternative (preferred for v0.1.2):** Instead of a socket,
write the deny patterns directly into the wrapper script as a bash
array at spawn time. The script does the glob check itself without
calling back to the engine. This removes the IPC complexity entirely.
```bash
#!/bin/bash
# Teammux git interceptor for worker {worker_id} ({role_name})
REAL_GIT=$(which -a git | grep -v "$(dirname "$0")" | head -1)
DENY_PATTERNS=("src/backend/**" "src/api/**" "infrastructure/**")

if [[ "$1" == "add" ]]; then
  shift
  for file in "$@"; do
    for pattern in "${DENY_PATTERNS[@]}"; do
      if [[ "$file" == $pattern ]]; then
        echo "[Teammux] permission denied: $file is outside your write scope (${role_name})"
        echo "[Teammux] You own: ${write_patterns_joined}"
        exit 1
      fi
    done
  done
fi
exec "$REAL_GIT" "$@"
```

The script is added to `PATH` for the worker's PTY session by setting
`GIT_EXEC_PATH` or prepending to `PATH` in the PTY environment at spawn.

**interceptor.zig responsibilities:**
```zig
pub fn install(
    allocator: Allocator,
    worktree_path: []const u8,
    worker_id: WorkerId,
    role_name: []const u8,
    deny_patterns: []const []const u8,
    write_patterns: []const []const u8,
) !void

pub fn remove(
    allocator: Allocator,
    worktree_path: []const u8,
) !void
```

`install()`:
1. Create `{worktree_path}/.git-wrapper/` directory
2. Write the wrapper script with embedded deny patterns
3. `chmod +x` the wrapper
4. The wrapper directory is added to PATH when the PTY environment
   is set up at spawn

`remove()`:
1. Delete `{worktree_path}/.git-wrapper/` directory
2. Called by `tm_worker_dismiss` and `tm_merge_reject`

**New C API additions to teammux.h:**
```c
tm_result_t tm_interceptor_install(tm_engine_t* engine,
                                    uint32_t worker_id);
tm_result_t tm_interceptor_remove(tm_engine_t* engine,
                                   uint32_t worker_id);
```

Both called automatically at spawn and dismiss — never called by Swift directly.

**PTY environment injection:** `pty.zig` (or `worktree.zig`) sets the
worker PTY's PATH to include `{worktree_path}/.git-wrapper` prepended
to the system PATH. This shadows the real git binary for that session only.

**Handles:**
- `git add {file}` — checks each file
- `git add .` — blocks if any file in CWD matches deny pattern
- `git add -A` — same as `git add .`
- `git add -u` — checks tracked modified files
- All other git commands — pass through unchanged

**Does NOT handle (out of scope for v0.1.2):**
- Direct file writes bypassing git (agent writing files without staging)
- `git commit -a` shorthand (deferred — add to TECH_DEBT as TD12)
- Agents calling git through shell scripts that bypass PATH

**Tests:**
- Wrapper script written correctly with deny patterns embedded
- chmod+x applied
- git add of denied file produces correct error message
- git add of allowed file passes through
- git commit, git status, git log all pass through unchanged
- remove() cleans up wrapper directory
- Worker with no role has pass-through wrapper (no deny patterns)

**WAIT CHECK:** Confirm stream-R4 has merged. R8 needs the
ownership registry to be stable and the role capability data
to be available at spawn time.

**Done when:**
- `cd engine && zig build test` — all tests pass
- Worker PTY session has correct PATH with wrapper prepended
- `git add {denied_file}` prints Teammux permission error
- `git add {allowed_file}` passes through silently
- Wrapper removed on dismiss
- PR raised from feat/v012-stream-r8-interceptor

---

### stream-R6 — Roster UI Role Display

**Files to modify:**
- `macos/Sources/Teammux/Workspace/WorkerRow.swift`
- `macos/Sources/Teammux/Workspace/SpawnPopoverView.swift`
- `macos/Sources/Teammux/Setup/TeamBuilderView.swift`

**WorkerRow.swift additions:**
- Role emoji badge (`🎨`) displayed before worker name
- Role name in secondary text below task description
- Capability indicator: subtle `lock.fill` SF Symbol if worker has
  `denyWritePatterns` — `.help` tooltip on hover listing restricted paths

**SpawnPopoverView.swift additions:**
- Role picker `Menu` showing all roles from `engine.availableRoles`
  grouped by division with dividers
- Selecting a role: sets `selectedRoleId`, shows role description
  in secondary text below picker
- "No role (generic)" option at top for backwards compatibility
- Role emoji shown in menu item alongside role name

**TeamBuilderView.swift additions:**
- Same role picker added to each worker row in team builder
- Division grouping header labels in picker

**Three states for role picker:**
- Loading: `ProgressView` while `engine.availableRoles` is empty
- Loaded: full picker with all roles
- Error: "No roles available" with retry button

**No EngineClient changes** — consumes `engine.availableRoles` and
`engine.workerRoles` from stream-R5.

**WAIT CHECK:** Confirm stream-R5 has merged. Pull main and
verify `engine.availableRoles` and `engine.workerRoles` exist
in EngineClient before implementing.

**Tests:**
- Role picker renders all available roles grouped by division
- Selecting a role updates `selectedRoleId`
- "No role" option present and selectable
- WorkerRow shows emoji + role name for workers with roles
- WorkerRow shows no badge for workers without roles

**Done when:**
- `./build.sh` passes end to end
- Spawn popover shows role picker with all 31 roles
- Worker rows show role emoji and name
- PR raised from feat/v012-stream-r6-roster-ui

---

### stream-R7 — Polish + TD8

**TD8 resolution:**
- `ConflictType` enum added to `macos/Sources/Teammux/Models/MergeTypes.swift`:
```swift
enum ConflictType: String, Sendable {
    case content = "content"
    case unknown = "unknown"

    init(rawString: String) {
        self = ConflictType(rawValue: rawString) ?? .unknown
    }

    var displayName: String {
        switch self {
        case .content: return "Content conflict"
        case .unknown: return "Unknown conflict"
        }
    }
}
```
- `ConflictInfo.conflictType` changed from `String` to `ConflictType`
- `ConflictView.swift` updated to use `conflict.conflictType.displayName`
- All existing tests updated

**Integration polish (role-aware improvements):**
- ConflictView header updated: "Merge conflict in {worker.name}'s
  {role.emoji} {role.name} branch" when role is available
- WorkerPaneView empty state: "Spawn a worker with a role to get started"
  when `engine.availableRoles` is non-empty
- Any small regressions identified during sprint documented and fixed

**Documentation updates:**
- `CLAUDE.md` version history: v0.1.2 marked as shipped
- `TECH_DEBT.md`: TD8 → RESOLVED, TD9 → RESOLVED (from R8)
- `V012_SPRINT.md`: all items marked complete in stream map

**WAIT CHECK:** Confirm stream-R6 AND stream-R8 have both merged
before implementing. R7 depends on both.

**Done when:**
- `./build.sh` passes end to end
- `ConflictInfo.conflictType` is `ConflictType` enum not `String`
- ConflictView header shows role name when available
- TECH_DEBT.md TD8 and TD9 both RESOLVED
- PR raised from feat/v012-stream-r7-polish

---

## 4. Shared Rules for All Streams

- Never modify `src/` (Ghostty upstream)
- All `tm_*` calls go through `EngineClient.swift` only
- No force-unwraps in production code
- `zig build test` must pass before raising PR (engine streams)
- Swift test suite must pass before raising PR (Swift streams)
- `engine/include/teammux.h` is the authoritative C API contract
- TECH_DEBT.md updated when new debt is discovered

---

## 5. Known Risks

- R1 and R3 run in parallel but R3 depends on R1's format being
  finalised. R3 should implement role ID validation only after
  confirming R1 has merged (or coordinate directly on format).
- R4 adds new functions to `teammux.h`. R5 and R8 must pull main
  after R4 merges before implementing.
- R8 PTY PATH injection must be tested against real Claude Code
  sessions to confirm the wrapper is picked up correctly. The
  `GIT_EXEC_PATH` vs PATH prepend approach may need adjustment
  based on how Claude Code invokes git.
- 31 role files is substantial content. R1 quality bar is high —
  generic placeholder content is a FAIL at review.
- R7 merges last and depends on both R6 and R8. If either is
  delayed, R7 waits.

---

## 6. Merge Checklist (main thread runs for each PR)

- [ ] Branch based on current main (merge-base check passes)
- [ ] All tests pass (zig build test or Swift suite)
- [ ] No src/ modifications
- [ ] No force-unwraps (Swift streams)
- [ ] tm_* calls confined to EngineClient.swift (Swift streams)
- [ ] Zero conflicts with main
- [ ] TECH_DEBT.md updated for any items resolved or added
- [ ] Role TOML files (R1): all 8 sections present, no placeholder content
- [ ] Capability patterns (R4/R8): deny_write takes precedence over write
```

---

Now the main thread setup meta-prompt. Once you confirm the three documents look correct, send this to Claude Code main thread:

---
```
Read CLAUDE.md, TECH_DEBT.md, and V012_SPRINT.md fully
before doing anything else.

You are the main thread orchestrator for v0.1.2.
No feature code in this session. Setup, coordination,
PR reviews, and merges only.

## Task 1 — Update repo docs

Three files need updating on main before worktrees are created.
Make these changes, then commit and push together.

1. Replace CLAUDE.md at repo root with the updated version
   provided in V012_SPRINT.md context. Key changes:
   - Hard rules section replacing architecture rules
   - V012_SPRINT.md added to key documents
   - v0.1.2 added to version history

2. Replace TECH_DEBT.md with the updated version that:
   - Moves TD1-TD7 to a "v0.1.1 — Resolved" section
   - TD8 stays OPEN (resolved in stream-R7 this sprint)
   - Adds TD9, TD10, TD11 as v0.1.2 targets
   - Adds new TD12 (git commit -a bypass, deferred from R8 scope)

3. Create V012_SPRINT.md at repo root with the complete
   sprint spec (provided separately).

Stage, commit, and push:
git add CLAUDE.md TECH_DEBT.md V012_SPRINT.md
git commit -m "docs: v0.1.2 sprint setup — updated CLAUDE.md, TECH_DEBT.md, V012_SPRINT.md"
git push origin main

Report the commit hash.

## Task 2 — Create 8 stream objective files

Create these 8 files at repo root before creating worktrees.
Each is a self-contained briefing for its stream's Claude Code
session. Follow the format of V011's stream files exactly.

Files to create:
- STREAM_R1_ROLE_LIBRARY.md
- STREAM_R2_ROLE_SPAWN.md
- STREAM_R3_CONFIG_ROLE.md
- STREAM_R4_OWNERSHIP.md
- STREAM_R5_ROLE_BRIDGE.md
- STREAM_R6_ROSTER_UI.md
- STREAM_R7_POLISH.md
- STREAM_R8_INTERCEPTOR.md

Each file must contain:
- Your branch name
- Your worktree path
- Read first (CLAUDE.md + TECH_DEBT.md + V012_SPRINT.md +
  your specific section in V012_SPRINT.md)
- Your mission (exact scope from V012_SPRINT.md)
- Your WAIT CHECK if applicable (which stream must merge first)
- Merge order context
- Done when (exact definition of done from V012_SPRINT.md)
- Core rules

Stage, commit, push all 8 stream files together:
git add STREAM_R1_ROLE_LIBRARY.md STREAM_R2_ROLE_SPAWN.md \
        STREAM_R3_CONFIG_ROLE.md STREAM_R4_OWNERSHIP.md \
        STREAM_R5_ROLE_BRIDGE.md STREAM_R6_ROSTER_UI.md \
        STREAM_R7_POLISH.md STREAM_R8_INTERCEPTOR.md
git commit -m "docs: v0.1.2 stream objective files — 8 streams"
git push origin main

Report the commit hash.

## Task 3 — Create 8 git worktrees

git worktree add ../teammux-stream-r1 -b feat/v012-stream-r1-role-library
git worktree add ../teammux-stream-r2 -b feat/v012-stream-r2-role-spawn
git worktree add ../teammux-stream-r3 -b feat/v012-stream-r3-config-role
git worktree add ../teammux-stream-r4 -b feat/v012-stream-r4-ownership
git worktree add ../teammux-stream-r5 -b feat/v012-stream-r5-role-bridge
git worktree add ../teammux-stream-r6 -b feat/v012-stream-r6-roster-ui
git worktree add ../teammux-stream-r7 -b feat/v012-stream-r7-polish
git worktree add ../teammux-stream-r8 -b feat/v012-stream-r8-interceptor

Confirm:
git worktree list

## Task 4 — Populate each worktree

Copy shared docs + stream-specific file into each worktree:

cp CLAUDE.md TECH_DEBT.md V012_SPRINT.md ../teammux-stream-r1/
cp STREAM_R1_ROLE_LIBRARY.md ../teammux-stream-r1/

cp CLAUDE.md TECH_DEBT.md V012_SPRINT.md ../teammux-stream-r2/
cp STREAM_R2_ROLE_SPAWN.md ../teammux-stream-r2/

cp CLAUDE.md TECH_DEBT.md V012_SPRINT.md ../teammux-stream-r3/
cp STREAM_R3_CONFIG_ROLE.md ../teammux-stream-r3/

cp CLAUDE.md TECH_DEBT.md V012_SPRINT.md ../teammux-stream-r4/
cp STREAM_R4_OWNERSHIP.md ../teammux-stream-r4/

cp CLAUDE.md TECH_DEBT.md V012_SPRINT.md ../teammux-stream-r5/
cp STREAM_R5_ROLE_BRIDGE.md ../teammux-stream-r5/

cp CLAUDE.md TECH_DEBT.md V012_SPRINT.md ../teammux-stream-r6/
cp STREAM_R6_ROSTER_UI.md ../teammux-stream-r6/

cp CLAUDE.md TECH_DEBT.md V012_SPRINT.md ../teammux-stream-r7/
cp STREAM_R7_POLISH.md ../teammux-stream-r7/

cp CLAUDE.md TECH_DEBT.md V012_SPRINT.md ../teammux-stream-r8/
cp STREAM_R8_INTERCEPTOR.md ../teammux-stream-r8/

## Task 5 — Verify and report

git worktree list
ls ../teammux-stream-r1/
ls ../teammux-stream-r2/
ls ../teammux-stream-r3/
ls ../teammux-stream-r4/
ls ../teammux-stream-r5/
ls ../teammux-stream-r6/
ls ../teammux-stream-r7/
ls ../teammux-stream-r8/

Report:
- Both commit hashes (Task 1 and Task 2)
- git worktree list output (all 8 + main)
- Each worktree ls confirms CLAUDE.md + TECH_DEBT.md +
  V012_SPRINT.md + stream-specific file present
- Ready for 8 parallel stream sessions

Do not start any feature implementation.
Setup and documentation only.
Report back when all 5 tasks complete.
