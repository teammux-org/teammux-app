## Finding 4-1: Raw markdown headings in memory summaries corrupt entry boundaries
**Severity:** IMPORTANT
**File:** engine/src/memory.zig:38
**Description:** `append()` writes the completion summary verbatim under a `## {timestamp}` header. Any summary line that itself begins with `## ` is serialized identically to a real entry boundary, and the Swift parser splits entries solely on lines with that prefix. A body line starting with `# ` is also dropped entirely by the parser's header-skip path. Because the summary comes from free-form agent output, markdown headings are a realistic input.
**Risk:** The memory timeline can split one completion into multiple fake entries or silently drop heading lines, so the user sees misleading agent memory even though the underlying file write succeeded.
**Recommendation:** Encode the body so it cannot be mistaken for structural markdown, for example by storing a structured format, prefixing/escaping body lines, or wrapping the summary in a fenced block. Add a round-trip test with embedded `##` and `#` headings.

## Finding 4-2: Automatic history rotation can hide the newest persisted entry from reload
**Severity:** IMPORTANT
**File:** engine/src/history.zig:159
**Description:** `append()` writes the new JSONL record first and only then calls `maybeRotate()`. When that write pushes the file over `max_size_bytes`, `rotateInner()` immediately renames `completion_history.jsonl` to `.1`. `load()` only reads the active `.jsonl` file, so after a size-triggering append the newest persisted entry lives only in the archive and is no longer returned by `tm_history_load` until another append recreates the active file.
**Risk:** After a restart, the app can show empty or truncated completion/question history even though the most recent event was written successfully and still exists on disk in `.1`.
**Recommendation:** Decide rotation before writing by comparing `current_size + next_entry_size` against `max_size_bytes`, or make `load()` merge `.1`/`.2` when rebuilding history.

## Finding 4-3: Relative `worktree_root` overrides are handled inconsistently and break downstream path assumptions
**Severity:** IMPORTANT
**File:** engine/src/worktree_lifecycle.zig:106
**Description:** `resolveWorktreeRoot()` returns the configured override unchanged, including relative paths. `create()` then makes that path relative to the process working directory, but `git -C {project_path} worktree add {relative_path}` resolves the worktree relative to the project root instead. The registry stores the relative path unchanged, while downstream code in `memory.zig`, `worktree.zig`, and `interceptor.zig` uses absolute-only filesystem APIs on `worktree_path`. `recoverOrphans()` also scans relative roots from the process cwd instead of the project root.
**Risk:** A relative `worktree_root` can create worktrees in one location, scan another location for orphan recovery, and fail later when context, interceptor, or memory files are written. That turns a valid-looking config override into broken worker lifecycle behavior.
**Recommendation:** Normalize `worktree_root` to an absolute path before it enters the registry, preferably relative to `project_path`, or reject non-absolute overrides during config load and document that requirement. Add tests for relative overrides if support is intended.

## Finding 4-4: Branch-only cleanup failures are not actually recoverable on the next startup
**Severity:** IMPORTANT
**File:** engine/src/worktree_lifecycle.zig:232
**Description:** `removeWorker()` keeps the registry entry in memory when either cleanup step fails, with the comment that startup recovery will retry later. That is only true if the worktree directory still exists. If `git worktree remove --force` succeeds but `git branch -D` fails, the directory is already gone and `recoverOrphans()` will never revisit that worker because it only scans numeric directories under the worktree root.
**Risk:** Stale `teammux/{id}-*` branches can survive across restarts without any automatic retry path. Over time that leaves branch clutter and can block a future spawn if the same branch name is generated again.
**Recommendation:** Make startup recovery enumerate leftover `teammux/{id}-*` branches independently of directory presence, or persist/surface a cleanup-incomplete state so callers can retry branch deletion explicitly.
