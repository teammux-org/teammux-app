# Stream S1 — TD12: git commit -a Interceptor Fix

## Your branch
`feat/v013-stream-s1-interceptor-fix`

## Your worktree path
`../teammux-stream-s1/`

## Read first
- `CLAUDE.md` — hard rules, build commands, sprint workflow
- `TECH_DEBT.md` — TD12 is your target
- `V013_SPRINT.md` — Section 3, stream-S1 scope

## Your mission

**Files to modify:** `engine/src/interceptor.zig` only

The bash wrapper currently only intercepts the `add` subcommand. Extend the
subcommand detection block to also handle `commit` with `-a` or `--all` flags.

New bash logic in the wrapper template (inserted after the `add` block):
```bash
elif [[ "$subcmd" == "commit" ]]; then
  for arg in "$@"; do
    case "$arg" in
      -a|--all|-a*)
        if [[ ${#DENY_PATTERNS[@]} -gt 0 ]]; then
          echo "[Teammux] Cannot use 'git commit -a' with write restrictions."
          echo "[Teammux] Stage files explicitly with 'git add' first."
          echo "[Teammux] Your write scope: ${WRITE_PATTERNS[*]}"
          exit 1
        fi
        ;;
    esac
  done
fi
```

Also add: `git commit --all` detection (long flag form). Ensure `-am`
combined short flag (common: `git commit -am "msg"`) is also caught by
checking if any argument starts with `-` and contains both `a` and `m`.

No C API changes needed. The wrapper template is in `interceptor.zig`
as a string template — update the template string only.

**Tests:**
- git commit -a with deny patterns -> blocked
- git commit --all with deny patterns -> blocked
- git commit -am "msg" with deny patterns -> blocked
- git commit -m "msg" with deny patterns -> passes through (no -a)
- git commit -a with no deny patterns -> passes through

## Merge order context
S1 can merge **any time** — no dependencies. You are in Wave 0.

## Done when
- `cd engine && zig build test` all pass including new tests
- TD12 noted for RESOLVED in TECH_DEBT.md (S12 handles the actual update)
- PR raised from `feat/v013-stream-s1-interceptor-fix`

## Core rules
- NEVER modify `src/` (Ghostty upstream)
- `engine/include/teammux.h` is the authoritative C API contract
- `zig build test` must pass before raising PR
- TECH_DEBT.md updated when new debt discovered
