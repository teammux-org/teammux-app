# Stream AA1 — Lifetime & Ownership Safety

## Context

Read these files before doing anything else (in parallel):
- CLAUDE.md
- docs/TECH_DEBT.md
- docs/codex-audits/audit-001-post-v014/ACTION-PLAN.md
  (read findings C1, C2, I1, I9 in full)
- engine/src/main.zig
- engine/src/commands.zig
- engine/include/teammux.h

Then run: cd engine && zig build test
Confirm 356 tests pass before writing any code.

## Your Task

Fix four lifetime and ownership safety bugs. All share
the same root cause: short-lived storage is borrowed
without duplication.

## Fix C1 — Failed config reload use-after-free
**File:** engine/src/main.zig:352
**Problem:** tm_config_reload destroys e.cfg before
loading the replacement. If the reload fails, e.cfg
points at freed memory.
**Fix:**
1. Load new config into a local new_cfg variable
2. Use errdefer new_cfg.deinit() to clean up on failure
3. Only call e.cfg.deinit() and assign e.cfg = new_cfg
   AFTER the new config is fully loaded and validated
4. On any failure: return error, old config remains intact

## Fix C2 — CommandWatcher borrows freed commands path
**File:** engine/src/main.zig:148, engine/src/commands.zig:31
**Problem:** sessionStart allocates cmd_dir, passes it
to CommandWatcher.init, then immediately frees it with
defer. CommandWatcher stores the borrowed slice and
dereferences freed memory on every command poll.
**Fix:**
1. In CommandWatcher.init: dupe the commands_dir slice:
   self.commands_dir = try allocator.dupe(u8, commands_dir)
2. In CommandWatcher.deinit: free self.commands_dir
3. In sessionStart: remove the defer free for cmd_dir —
   CommandWatcher now owns it

## Fix I1 — GitHubClient borrows config-owned repo slice
**File:** engine/src/main.zig:136
**Problem:** GitHubClient.init stores a slice from
cfg.project.github_repo without duping. Config.deinit
frees the string during reload, leaving GitHub operations
with a dangling pointer.
**Fix:**
1. In GitHubClient.init: dupe the repo string:
   self.repo = try allocator.dupe(u8, repo)
2. In GitHubClient.deinit: free self.repo
3. Add GitHubClient.updateRepo(new_repo) for atomic
   reload: dupe new value, free old, swap

## Fix I9 — sessionStart leaks partial state on failure
**File:** engine/src/main.zig:127
**Problem:** sessionStart commits each subsystem to self.*
as it goes. If a later step fails, earlier state is left
attached with no rollback. A retry overwrites without
deinitializing the previous values.
**Fix:**
1. Stage every subsystem init in a local variable:
   var cfg = try Config.load(...)
   errdefer cfg.deinit()
   var bus = try MessageBus.init(...)
   errdefer bus.deinit()
   etc.
2. Only assign to self.* fields at the very end, after
   all subsystems have initialized successfully
3. On failure: errdefer chains clean up all locals

## Commit Sequence

Commit 1: commands.zig — CommandWatcher owns commands_dir (C2)
Commit 2: main.zig — GitHubClient owns repo string (I1)
Commit 3: main.zig — sessionStart staged startup with
           errdefer rollback (I9)
Commit 4: main.zig — config reload atomic swap (C1)

After each commit:
  cd engine && zig build
  cd engine && zig build test
All 356 tests must pass before next commit.

## Definition of Done

- No borrowed short-lived slices in CommandWatcher,
  GitHubClient, or sessionStart startup path
- Config reload leaves old config intact on failure
- All errdefer chains cover partial allocations
- 356 tests passing
- No changes to engine/include/teammux.h
- No changes to macos/

Raise PR from fix/aa1-lifetime-ownership against main.
Do NOT merge. Report back with PR link.
