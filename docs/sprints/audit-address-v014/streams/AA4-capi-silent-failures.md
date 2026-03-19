# Stream AA4 — C API Contracts & Silent Failures

## Context

Read these files before doing anything else (in parallel):
- CLAUDE.md
- docs/TECH_DEBT.md
- docs/codex-audits/audit-001-post-v014/ACTION-PLAN.md
  (read findings I4, I5, I12 in full)
- engine/src/main.zig
- engine/src/merge.zig
- engine/include/teammux.h
- macos/Sources/Teammux/Engine/EngineClient.swift
  (check for any stored tm_config_get results)

Then run: cd engine && zig build test
Confirm 356 tests pass before writing any code.

## Your Task

Three focused contract-alignment and silent-failure fixes.

## Fix I5 — tm_engine_create succeeds with NULL out-param
**File:** engine/src/main.zig:320
**Fix:** At the very start of export fn tm_engine_create,
before any allocation:
  if (out == null) {
      setCreateError("out must not be NULL");
      return @intFromEnum(TmResult.err_unknown);
  }
One guard, zero allocation on this path.

## Fix I4 — tm_config_get violates documented lifetime
**File:** engine/src/main.zig:370,
          engine/include/teammux.h:198

First: search EngineClient.swift for any stored
tm_config_get results across multiple calls:
  rg "tm_config_get" macos/Sources/Teammux/ \
    --include="*.swift"

Then choose and implement ONE of:
- Option A (align impl to contract): Keep cached string
  alive until tm_config_reload or Engine.destroy only.
  Do not free at start of each tm_config_get call.
- Option B (tighten contract): Update header comment to
  "valid only until the next call to tm_config_get".
  Only valid if no Swift caller stores the result.

Implement whichever option is safer given the Swift audit.
Update the header to match the implementation exactly.

## Fix I12 — Merge cleanup drops git failures silently
**File:** engine/src/merge.zig:136
**Fix:**
1. Replace runGitIgnoreResult() in cleanup paths with
   logged versions: log a warning with the operation name
   and error on failure
2. Track whether cleanup succeeded (worktree removed,
   branch deleted)
3. Return a partial-success indication to the caller when
   cleanup is incomplete — use TM_ERR_CLEANUP_INCOMPLETE
   or equivalent, surfacing it through the C API so Swift
   can inform the user that manual cleanup may be needed

## Commit Sequence

Commit 1: main.zig — I5 NULL out-param guard
Commit 2: main.zig + teammux.h — I4 config_get lifetime fix
Commit 3: merge.zig — I12 cleanup failure logging

After each commit:
  cd engine && zig build
  cd engine && zig build test
All 356 tests must pass.

## Definition of Done

- tm_engine_create rejects NULL out-param immediately
- tm_config_get lifetime contract matches implementation
- Merge cleanup failures logged and surfaced to caller
- Header updated to match implementation exactly
- 356 tests passing

Raise PR from fix/aa4-capi-silent-failures against main.
Do NOT merge. Report back with PR link.
