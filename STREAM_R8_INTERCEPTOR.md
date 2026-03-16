# Stream R8 — Git Command Interceptor

## Your branch
`feat/v012-stream-r8-interceptor`

## Your worktree path
`../teammux-stream-r8`

## Read first
1. `CLAUDE.md` — hard rules, build commands, sprint workflow
2. `TECH_DEBT.md` — open and resolved debt items
3. `V012_SPRINT.md` — full sprint spec, Section 3 "stream-R8 — Git Command Interceptor"

---

## Your mission

Create `engine/src/interceptor.zig` — a PTY-level git command interceptor that enforces write ownership by shadowing the real `git` binary with a wrapper script in each worker's worktree.

### New file
`engine/src/interceptor.zig`

### Approach

At worker spawn time, write a wrapper shell script into the worktree that shadows the real `git` binary. The script intercepts `git add` commands, checks ownership against embedded deny patterns, and either passes through or blocks with a clear error message.

### Preferred approach for v0.1.2 (simpler, no IPC)

Write the deny patterns directly into the wrapper script as a bash array at spawn time. The script does the glob check itself without calling back to the engine.

**Wrapper script written to `{worktree_path}/.git-wrapper/git`:**

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

The script is added to `PATH` for the worker's PTY session by prepending `{worktree_path}/.git-wrapper` to `PATH` in the PTY environment at spawn.

### interceptor.zig responsibilities

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

**`install()`:**
1. Create `{worktree_path}/.git-wrapper/` directory
2. Write the wrapper script with embedded deny patterns
3. `chmod +x` the wrapper
4. The wrapper directory is added to PATH when the PTY environment is set up at spawn

**`remove()`:**
1. Delete `{worktree_path}/.git-wrapper/` directory
2. Called by `tm_worker_dismiss` and `tm_merge_reject`

### New C API additions to teammux.h

```c
tm_result_t tm_interceptor_install(tm_engine_t* engine,
                                    uint32_t worker_id);
tm_result_t tm_interceptor_remove(tm_engine_t* engine,
                                   uint32_t worker_id);
```

Both called automatically at spawn and dismiss — never called by Swift directly.

### PTY environment injection

`pty.zig` (or `worktree.zig`) sets the worker PTY's PATH to include `{worktree_path}/.git-wrapper` prepended to the system PATH. This shadows the real git binary for that session only.

### Handles
- `git add {file}` — checks each file
- `git add .` — blocks if any file in CWD matches deny pattern
- `git add -A` — same as `git add .`
- `git add -u` — checks tracked modified files
- All other git commands — pass through unchanged

### Does NOT handle (out of scope for v0.1.2)
- Direct file writes bypassing git (agent writing files without staging)
- `git commit -a` shorthand (deferred — add to TECH_DEBT as TD12)
- Agents calling git through shell scripts that bypass PATH

### Tests
- Wrapper script written correctly with deny patterns embedded
- `chmod +x` applied
- `git add` of denied file produces correct error message
- `git add` of allowed file passes through
- `git commit`, `git status`, `git log` all pass through unchanged
- `remove()` cleans up wrapper directory
- Worker with no role has pass-through wrapper (no deny patterns)

---

## WAIT CHECK

**You MUST wait for stream-R4 to be merged into main before implementing.** R8 needs the ownership registry to be stable and the role capability data to be available at spawn time. The main thread orchestrator will notify you when R4 is merged. Pull main at that point before starting work.

## Merge order context

R1 → R3 → R2 → R4 → R5/**R8** (parallel) → R6 → R7

R8 merges after R4 (in parallel with R5). R7 depends on R8 being merged.

---

## Done when
- `cd engine && zig build test` — all tests pass
- Worker PTY session has correct PATH with wrapper prepended
- `git add {denied_file}` prints Teammux permission error
- `git add {allowed_file}` passes through silently
- Wrapper removed on dismiss
- PR raised from `feat/v012-stream-r8-interceptor`

---

## Core rules
- Never modify `src/` (Ghostty upstream)
- All `tm_*` calls go through `EngineClient.swift` only
- No force-unwraps in production code
- `zig build test` must pass before raising PR
- `engine/include/teammux.h` is the authoritative C API contract
- Header changes are additive only — do not remove or rename existing functions
- NO direct git operations outside worktree.zig and merge.zig
- TECH_DEBT.md updated when new debt is discovered (add TD12 for `git commit -a` bypass)
