## [IMPORTANT] tm_engine_create returns success when the out-parameter is NULL

**File:** engine/src/main.zig:320
**Pattern:** null parameter
**Description:** The public contract says success means `*out` receives a valid engine pointer. The export currently accepts `NULL` for `out`, allocates an engine anyway, returns `TM_OK`, and drops the only handle to that allocation. A plain C caller can therefore get a false-success result and leak the engine immediately.
**Evidence:**
```zig
// On success, writes engine pointer to *out and returns TM_OK.
export fn tm_engine_create(project_root: ?[*:0]const u8, out: ?*?*Engine) c_int {
    if (out) |p| p.* = null;
    const root = std.mem.span(project_root orelse { last_create_error = "project_root is NULL"; return 99; });
    const engine = Engine.create(std.heap.c_allocator, root) catch { last_create_error = "engine allocation failed"; return 99; };
    if (out) |p| p.* = engine;
    return 0;
}
```
**Recommendation:** Reject `NULL` `out` up front, set `last_create_error` to an explicit message such as `"out must not be NULL"`, and return an error code instead of `TM_OK`.

## [IMPORTANT] tm_config_get's documented lifetime does not match the implementation

**File:** engine/include/teammux.h:198
**Pattern:** string lifetime
**Description:** The header promises the returned pointer stays valid until the next `tm_config_reload()`. The implementation actually frees the cached string at the start of every subsequent `tm_config_get()` call. Any caller that stores one config pointer, performs another lookup, and then reads the first pointer will read freed memory. The same API also returns `NULL` for more cases than the header documents (`engine == NULL`, `key == NULL`, config not loaded, allocation failure).
**Evidence:**
```zig
// Returned pointer is valid until the next tm_config_reload. Caller must not free.
const char* tm_config_get(tm_engine_t* engine, const char* key);

export fn tm_config_get(engine: ?*Engine, key: ?[*:0]const u8) ?[*:0]const u8 {
    const e = engine orelse return null;
    if (e.last_config_get_cstr) |old| { e.allocator.free(std.mem.span(old)); e.last_config_get_cstr = null; }
    const k = std.mem.span(key orelse return null);
    ...
}
```
**Recommendation:** Make the contract and implementation agree. Either document the real lifetime as "until the next `tm_config_get`, `tm_config_reload`, or `tm_engine_destroy`", or change the implementation to preserve prior results until reload/destroy.

## [SUGGESTION] EngineClient does not use the NULL-engine error retrieval path for creation failures

**File:** macos/Sources/Teammux/Engine/EngineClient.swift:234
**Pattern:** caller responsibility
**Description:** The C API explicitly supports `tm_engine_last_error(NULL)` for `tm_engine_create()` failures. `EngineClient.create(projectRoot:)` calls `lastEngineError()` in the failure path before `engine` exists, but `lastEngineError()` immediately returns `nil` when `engine` is unset. Swift therefore discards the creation-time diagnostic and falls back to a generic `"tm_engine_create failed (...)"` message.
**Evidence:**
```swift
guard result == TM_OK, let enginePtr = ptr else {
    lastError = lastEngineError() ?? "tm_engine_create failed (\(result.rawValue))"
    Self.logger.error("tm_engine_create failed: \(self.lastError ?? "unknown")")
    return false
}

private func lastEngineError() -> String? {
    guard let engine else { return nil }
    guard let cStr = tm_engine_last_error(engine) else { return nil }
```
**Recommendation:** Add a helper that accepts an optional engine pointer and calls `tm_engine_last_error(nil)` when no engine exists, then use that helper in the `tm_engine_create()` failure path.

## [SUGGESTION] tm_pr_t is bridged into Swift without the ABI size check used for the other audited structs

**File:** engine/src/main.zig:258
**Pattern:** struct layout
**Description:** Swift dereferences `tm_pr_t` fields directly when bridging PR creation results, but `main.zig` does not assert `@sizeOf(CPr)` the way it does for `tm_worker_info_t`, `tm_conflict_t`, `tm_dispatch_event_t`, and `tm_history_entry_t`. That means a future header/layout drift in `tm_pr_t` can compile without tripping the existing ABI guardrail.
**Evidence:**
```zig
const CPr = extern struct {
    pr_number: u64, pr_url: ?[*:0]const u8, title: ?[*:0]const u8,
    state: c_int, diff_url: ?[*:0]const u8, worker_id: u32,
};
comptime {
    if (@sizeOf(CWorkerInfo) != 72) @compileError("CWorkerInfo size mismatch with tm_worker_info_t");
    if (@sizeOf(CConflict) != 32) @compileError("CConflict size mismatch with tm_conflict_t");
    if (@sizeOf(CHistoryEntry) != 48) @compileError("CHistoryEntry size mismatch with tm_history_entry_t");
}
```
**Recommendation:** Add a compile-time `@sizeOf(CPr)` assertion, and consider doing the same for `CDiffFile` / `CDiff` while the ABI audit work is in scope.

## Domain Summary

The Swift boundary is mostly disciplined. I found no `tm_*` confinement violations: a search for `\btm_[a-z_]+\s*\(` under `macos/Sources/Teammux/` returned no direct call sites outside `EngineClient.swift`. The ownership side is also in good shape for the APIs Swift actually uses: `EngineClient.swift` correctly pairs `tm_worker_info_free`, `tm_roster_free`, `tm_pr_free`, `tm_diff_free`, `tm_merge_conflicts_free`, `tm_role_free`, `tm_roles_list_free`, `tm_roles_list_bundled_free`, `tm_dispatch_history_free`, `tm_history_free`, and `tm_free_string` with their corresponding allocators. The main recurring weakness is contract drift at the public boundary: a few NULL/sentinel cases and one string-lifetime rule are stronger or looser in code than the header says, and one directly bridged struct (`tm_pr_t`) lacks the compile-time ABI guard already used for the other high-risk structs.
