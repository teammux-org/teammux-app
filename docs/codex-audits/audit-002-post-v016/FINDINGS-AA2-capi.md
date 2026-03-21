## Finding 2-1: Unchecked enum conversion can crash C API callers
**Severity:** CRITICAL
**File:** engine/src/main.zig:1008
**Description:** `tm_message_send`, `tm_message_broadcast`, and `tm_github_merge_pr` convert C integer arguments to Zig enums with unchecked `@enumFromInt(...)` at [engine/src/main.zig:1008](/Users/akram/Learning/Projects/teammux-audit-aa2/engine/src/main.zig#L1008), [engine/src/main.zig:1027](/Users/akram/Learning/Projects/teammux-audit-aa2/engine/src/main.zig#L1027), and [engine/src/main.zig:1103](/Users/akram/Learning/Projects/teammux-audit-aa2/engine/src/main.zig#L1103). On Zig 0.15.2, invalid runtime enum values panic. C enum parameters are not type-safe at the ABI boundary, so a malformed or stale caller can terminate the process instead of receiving a `tm_result_t` failure.
**Risk:** A bad `tm_message_type_t` or `tm_merge_strategy_t` value from Swift/C code crashes the app at the API boundary. This is a production crash path, not a recoverable contract violation.
**Recommendation:** Replace each `@enumFromInt(...)` in exported C entry points with checked conversion (`std.meta.intToEnum(...) catch { setError(...); return ...; }`). Return a stable `TM_ERR_*` code and set `last_error` for invalid enum values.

## Finding 2-2: PTY death APIs are implemented but missing from the public header
**Severity:** IMPORTANT
**File:** engine/include/teammux.h:238
**Description:** `tm_worker_pty_died` and `tm_worker_monitor_pid` are exported in [engine/src/main.zig:837](/Users/akram/Learning/Projects/teammux-audit-aa2/engine/src/main.zig#L837) and [engine/src/main.zig:850](/Users/akram/Learning/Projects/teammux-audit-aa2/engine/src/main.zig#L850), but `engine/include/teammux.h` does not declare either function in the worker lifecycle section. The header is explicitly the C API source of truth, so these v0.1.6 exports are currently outside the documented/public contract.
**Risk:** Downstream C/Swift consumers cannot legally import or compile against the intended PTY death notification APIs, and the public contract diverges from the actual binary surface. That makes the primary PTY-death path easy to miss and pushes callers onto the slower monitor fallback.
**Recommendation:** Add both declarations to `teammux.h` next to the other worker lifecycle exports, with explicit docs for null handling, worker validation, return codes, and the intended primary-vs-fallback usage.

## Finding 2-3: Conflict-resolution exports collapse Git failures into `TM_ERR_INVALID_WORKER`
**Severity:** IMPORTANT
**File:** engine/src/main.zig:2177
**Description:** `tm_conflict_resolve` maps every `merge_coordinator.resolveConflict(...)` failure to return code `12`, including `error.GitFailed` and invalid-resolution cases at [engine/src/main.zig:2192](/Users/akram/Learning/Projects/teammux-audit-aa2/engine/src/main.zig#L2192). `tm_conflict_finalize` does the same for `merge_coordinator.finalizeMerge(...)`, including `error.GitFailed`, at [engine/src/main.zig:2221](/Users/akram/Learning/Projects/teammux-audit-aa2/engine/src/main.zig#L2221). The header only documents `TM_ERR_INVALID_WORKER` for missing/invalid merge state, not repository failures.
**Risk:** Callers receive the wrong failure class when Git checkout/add/commit fails during conflict handling. UI and diagnostics can mis-handle the error as a roster/precondition problem instead of a repository failure, which hides the real remediation path.
**Recommendation:** Preserve `TM_ERR_INVALID_WORKER` for missing-worker or unmet-merge-precondition cases only. Map Git operation failures to `TM_ERR_WORKTREE` (or another documented result code), and document the invalid-resolution return contract explicitly.

## Finding 2-4: `tm_version()` still reports `0.1.0` in a v0.1.6 audit baseline
**Severity:** IMPORTANT
**File:** engine/src/main.zig:2950
**Description:** The public `tm_version()` export is hard-coded to return `"0.1.0"` at [engine/src/main.zig:2950](/Users/akram/Learning/Projects/teammux-audit-aa2/engine/src/main.zig#L2950), and the test at [engine/src/main.zig:3222](/Users/akram/Learning/Projects/teammux-audit-aa2/engine/src/main.zig#L3222) asserts that stale value. This audit baseline, the sprint docs, and the repo state are all v0.1.6.
**Risk:** Any consumer that displays, logs, gates compatibility, or reports telemetry using `tm_version()` gets a misleading version string. The current test also locks the stale contract in place, so future releases can keep shipping the wrong version unnoticed.
**Recommendation:** Source `tm_version()` from one canonical build/version constant and update the test to assert the real release value rather than a stale literal.
