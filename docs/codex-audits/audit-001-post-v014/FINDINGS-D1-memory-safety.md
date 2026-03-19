## [CRITICAL] Failed config reload leaves `e.cfg` pointing at freed storage

**File:** engine/src/main.zig:352
**Pattern:** use-after-free
**Description:** `tm_config_reload` destroys the current config before it knows a replacement exists. If `config.loadWithOverrides` fails, `e.cfg` still points at the deinitialized struct. The next config read or final `Engine.destroy()` can then read or free already-freed config strings.
**Evidence:**
```zig
if (e.cfg) |*old| old.deinit(e.allocator);
e.cfg = config.loadWithOverrides(e.allocator, p1, p2) catch {
    e.setError("config reload failed") catch {};
    return 7;
};
```
**Recommendation:** Load into a temporary `new_cfg`, and only deinit/swap `e.cfg` after the new config is fully loaded. If the reload fails, leave the old config intact.

## [CRITICAL] `CommandWatcher` stores a borrowed commands path that `sessionStart` frees

**File:** engine/src/main.zig:148
**Pattern:** use-after-free
**Description:** `sessionStart` allocates `cmd_dir`, passes it into `CommandWatcher.init`, and frees it on scope exit. `CommandWatcher` only stores the slice, so `tm_commands_watch` later calls `openDirAbsolute(self.commands_dir)` on a dangling pointer.
**Evidence:**
```zig
const cmd_dir = try std.fmt.allocPrint(self.allocator, "{s}/.teammux/commands", .{self.project_root});
defer self.allocator.free(cmd_dir);
self.commands_watcher = commands.CommandWatcher.init(self.allocator, cmd_dir) catch |err| {
    self.setError("commands watcher init failed") catch {};
    return err;
};
```
**Recommendation:** Make `CommandWatcher` own a duped copy of `commands_dir` and free it in `deinit()`, or keep the original allocation alive for the full watcher lifetime.

## [IMPORTANT] `GitHubClient` keeps a borrowed repo slice across config reloads

**File:** engine/src/main.zig:136
**Pattern:** ownership
**Description:** `sessionStart` initializes `GitHubClient` with `cfg.project.github_repo`, but `GitHubClient.init` just stores that slice. `Config.deinit()` later frees the repo string during reload, leaving GitHub polling, webhook setup, and PR operations with a dangling `repo` pointer.
**Evidence:**
```zig
if (self.cfg) |cfg| {
    if (cfg.project.github_repo) |repo| {
        self.github_client.deinit();
        self.github_client = github.GitHubClient.init(self.allocator, repo);
    }
}
```
**Recommendation:** Make `GitHubClient` own its `repo` string, free it in `deinit()`, and replace it atomically during reload instead of borrowing config-owned memory.

## [IMPORTANT] Ownership rule slices escape the registry lock and can be invalidated mid-read

**File:** engine/src/ownership.zig:113
**Pattern:** use-after-free
**Description:** `getRules()` returns a registry-owned slice after dropping the mutex, and the function comment already states concurrent updates invalidate it. `tm_ownership_get` and `tm_interceptor_install` both walk that slice after unlock, while `RoleWatcher.fireCallback` can call `updateWorkerRules()` on its watcher thread and free/reallocate the same backing storage.
**Evidence:**
```zig
/// WARNING: The returned slice is invalidated by concurrent register()
/// or release() calls on the same worker_id. Callers must copy the data
/// out before releasing the lock on their side.
pub fn getRules(self: *FileOwnershipRegistry, worker_id: WorkerId) ?[]const PathRule {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.rules.get(worker_id);
}
```
**Recommendation:** Replace `getRules()` with a locked copy-out API that duplicates the rules (or at least the pattern strings) before releasing the mutex.

## [IMPORTANT] `Roster.getWorker()` returns raw worker pointers without read-side locking

**File:** engine/src/worktree.zig:145
**Pattern:** use-after-free
**Description:** `dismiss()` removes a worker under the roster mutex and frees all owned worker strings, but `getWorker()` returns `workers.getPtr()` with no lock at all. That pointer is dereferenced from background-thread paths such as `CommandWatcher` -> `busSendBridge` when completion history tries to read `w.worktree_path`, so a concurrent dismiss can race with the read and expose freed memory.
**Evidence:**
```zig
self.mutex.lock();
defer self.mutex.unlock();
const kv = self.workers.fetchRemove(worker_id) orelse return error.WorkerNotFound;
...
self.allocator.free(worker.worktree_path);
...
pub fn getWorker(self: *Roster, worker_id: WorkerId) ?*Worker {
    return self.workers.getPtr(worker_id);
}
```
**Recommendation:** Stop returning raw internal pointers. Add a locked copy API (or a `withWorkerLocked` callback) so callers copy the needed fields while the mutex is held.

## [IMPORTANT] `tm_config_get()` violates its documented C-string lifetime

**File:** engine/src/main.zig:370
**Pattern:** C boundary
**Description:** The header says the returned pointer stays valid until the next `tm_config_reload()`. The implementation frees the previous cached string at the start of every `tm_config_get()`, so a caller that keeps one config pointer across a second lookup gets a dangling pointer even though the API contract says that should be safe.
**Evidence:**
```zig
if (e.last_config_get_cstr) |old| { e.allocator.free(std.mem.span(old)); e.last_config_get_cstr = null; }
const k = std.mem.span(key orelse return null);
const cfg = &(e.cfg orelse return null);
const val = config.get(cfg, k) orelse return null;
const z = e.allocator.dupeZ(u8, val) catch return null;
e.last_config_get_cstr = z.ptr;
return z.ptr;
```
**Recommendation:** Either keep config values alive until reload as documented, or tighten the header contract to “valid until the next `tm_config_get()`” and ensure every caller copies immediately.

## [SUGGESTION] Config parse cleanup leaks replaced default strings on error paths

**File:** engine/src/config.zig:124
**Pattern:** leak
**Description:** `parse()` frees `tl_model`, `tl_permissions`, and `bus_delivery` before replacing them, then flips `replaced_*` flags. The `errdefer` block only frees those fields when the flags are false, so any later parse failure leaks the current replacement strings. This is limited to parse-error paths.
**Evidence:**
```zig
errdefer {
    if (!replaced_tl_model) allocator.free(tl_model);
    if (!replaced_tl_permissions) allocator.free(tl_permissions);
    if (!replaced_bus_delivery) allocator.free(bus_delivery);
}
...
allocator.free(tl_model);
replaced_tl_model = true;
tl_model = try allocator.dupe(u8, val);
```
**Recommendation:** Always free the current pointer in `errdefer`, or stage replacements in temporaries and commit them only after the parse succeeds.

## Domain Summary
- Total findings by severity: CRITICAL 2, IMPORTANT 4, SUGGESTION 1
- Top 3 most critical issues: Failed config reload leaves `e.cfg` pointing at freed storage; `CommandWatcher` stores a borrowed commands path that `sessionStart` frees; `GitHubClient` keeps a borrowed repo slice across config reloads
- Any patterns suggesting systemic issues: Several engine components mix borrowed slices and owned allocations without a single, enforced ownership policy. The same pattern appears again with read APIs returning raw internal pointers or slices after dropping a lock, while watcher threads mutate those containers concurrently. The result is a cluster of avoidable lifetime bugs at module boundaries rather than one isolated defect.
