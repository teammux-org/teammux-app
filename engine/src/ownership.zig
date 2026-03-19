const std = @import("std");
const worktree = @import("worktree.zig");

pub const WorkerId = worktree.WorkerId;

// ─────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────

pub const PathRule = struct {
    pattern: []const u8, // owned by registry, duped on register
    allow_write: bool, // true = write grant, false = deny_write
};

// ─────────────────────────────────────────────────────────
// FileOwnershipRegistry
// ─────────────────────────────────────────────────────────

pub const FileOwnershipRegistry = struct {
    allocator: std.mem.Allocator,
    rules: std.AutoHashMap(WorkerId, []PathRule),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) FileOwnershipRegistry {
        return .{
            .allocator = allocator,
            .rules = std.AutoHashMap(WorkerId, []PathRule).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *FileOwnershipRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.rules.iterator();
        while (it.next()) |entry| {
            freeRules(self.allocator, entry.value_ptr.*);
        }
        self.rules.deinit();
    }

    /// Register a path pattern for a worker. Patterns are duped and owned
    /// by the registry. Call multiple times to add multiple rules.
    pub fn register(self: *FileOwnershipRegistry, worker_id: WorkerId, pattern: []const u8, allow_write: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const owned_pattern = try self.allocator.dupe(u8, pattern);
        errdefer self.allocator.free(owned_pattern);

        const new_rule = PathRule{ .pattern = owned_pattern, .allow_write = allow_write };

        if (self.rules.getPtr(worker_id)) |existing| {
            const old = existing.*;
            const new_slice = try self.allocator.alloc(PathRule, old.len + 1);
            @memcpy(new_slice[0..old.len], old);
            new_slice[old.len] = new_rule;
            self.allocator.free(old);
            existing.* = new_slice;
        } else {
            const new_slice = try self.allocator.alloc(PathRule, 1);
            errdefer self.allocator.free(new_slice);
            new_slice[0] = new_rule;
            try self.rules.put(worker_id, new_slice);
        }
    }

    /// Release all ownership rules for a worker. Idempotent — safe to call
    /// even if no rules are registered.
    pub fn release(self: *FileOwnershipRegistry, worker_id: WorkerId) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.rules.fetchRemove(worker_id)) |kv| {
            freeRules(self.allocator, kv.value);
        }
    }

    /// Check whether a worker is allowed to write to file_path.
    ///
    /// Precedence:
    /// 1. No rules for worker → true (default allow, no role = unrestricted)
    /// 2. Any deny pattern matches → false (deny wins)
    /// 3. Any write pattern matches → true
    /// 4. Default → false (no explicit allow)
    pub fn check(self: *FileOwnershipRegistry, worker_id: WorkerId, file_path: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const worker_rules = self.rules.get(worker_id) orelse return true;

        const normalized = normalize(file_path);

        // Pass 1: deny rules (allow_write == false) — if any match, deny
        for (worker_rules) |rule| {
            if (!rule.allow_write) {
                if (globMatch(rule.pattern, normalized)) return false;
            }
        }

        // Pass 2: write rules (allow_write == true) — if any match, allow
        for (worker_rules) |rule| {
            if (rule.allow_write) {
                if (globMatch(rule.pattern, normalized)) return true;
            }
        }

        // No explicit allow matched
        return false;
    }

    /// Get rules for a worker (internal, no copy — caller must hold mutex or
    /// ensure single-threaded access). Use copyRules() for thread-safe access.
    fn getRules(self: *FileOwnershipRegistry, worker_id: WorkerId) ?[]const PathRule {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.rules.get(worker_id);
    }

    /// Thread-safe copy of rules for a worker. Returns null if no rules
    /// registered. Returned slice and all pattern strings are owned by the
    /// caller — free with freeRulesCopy().
    pub fn copyRules(self: *FileOwnershipRegistry, worker_id: WorkerId, alloc: std.mem.Allocator) !?[]PathRule {
        self.mutex.lock();
        defer self.mutex.unlock();

        const src = self.rules.get(worker_id) orelse return null;
        if (src.len == 0) {
            // Return a zero-length owned slice so callers can distinguish
            // "has rules but empty" from "no rules at all" (null).
            const empty = try alloc.alloc(PathRule, 0);
            return empty;
        }

        const copy = try alloc.alloc(PathRule, src.len);
        var duped: usize = 0;
        errdefer {
            for (copy[0..duped]) |rule| alloc.free(rule.pattern);
            alloc.free(copy);
        }

        for (src) |rule| {
            copy[duped] = .{
                .pattern = try alloc.dupe(u8, rule.pattern),
                .allow_write = rule.allow_write,
            };
            duped += 1;
        }

        return copy;
    }

    /// Free a rules slice returned by copyRules().
    pub fn freeRulesCopy(alloc: std.mem.Allocator, rules_copy: []PathRule) void {
        for (rules_copy) |rule| alloc.free(rule.pattern);
        alloc.free(rules_copy);
    }

    /// Replace all ownership rules for a worker under lock. Allocates new
    /// rules first — on allocation failure, old rules are preserved unchanged.
    /// On success, old rules are freed and replaced with the new set.
    /// Passing empty write and deny patterns creates an explicit empty rule
    /// set (all writes denied). To make a worker unrestricted, use release().
    pub fn updateWorkerRules(
        self: *FileOwnershipRegistry,
        worker_id: WorkerId,
        write_patterns: []const []const u8,
        deny_patterns: []const []const u8,
    ) !void {
        const total = write_patterns.len + deny_patterns.len;

        // Allocate and populate new rules outside the lock to minimize
        // contention. On failure, nothing is modified.
        const new_rules = try self.allocator.alloc(PathRule, total);
        var duped: usize = 0;
        errdefer {
            for (new_rules[0..duped]) |rule| self.allocator.free(rule.pattern);
            self.allocator.free(new_rules);
        }

        for (write_patterns) |pat| {
            new_rules[duped] = .{
                .pattern = try self.allocator.dupe(u8, pat),
                .allow_write = true,
            };
            duped += 1;
        }
        for (deny_patterns) |pat| {
            new_rules[duped] = .{
                .pattern = try self.allocator.dupe(u8, pat),
                .allow_write = false,
            };
            duped += 1;
        }

        // Swap under lock. Use getOrPut to pre-allocate the map slot
        // BEFORE freeing old rules — if resize fails, old rules are preserved
        // and new rules are freed by errdefer.
        self.mutex.lock();
        defer self.mutex.unlock();

        const gop = try self.rules.getOrPut(worker_id);
        if (gop.found_existing) {
            freeRules(self.allocator, gop.value_ptr.*);
        }
        gop.value_ptr.* = new_rules;
    }

    fn freeRules(allocator: std.mem.Allocator, rules_slice: []PathRule) void {
        for (rules_slice) |rule| {
            allocator.free(rule.pattern);
        }
        allocator.free(rules_slice);
    }
};

// ─────────────────────────────────────────────────────────
// Path normalization
// ─────────────────────────────────────────────────────────

/// Strip leading "./" from a path for consistent matching.
fn normalize(path: []const u8) []const u8 {
    if (path.len >= 2 and path[0] == '.' and path[1] == '/') {
        return path[2..];
    }
    return path;
}

// ─────────────────────────────────────────────────────────
// Glob matching
// ─────────────────────────────────────────────────────────

/// Match a gitignore-style glob pattern against a file path.
///
/// Supports:
/// - `**` — matches zero or more characters including `/` (any depth)
/// - `*`  — matches zero or more characters excluding `/` (single segment)
/// - `?`  — matches exactly one character excluding `/`
///
/// Both pattern and path are normalized (leading "./" stripped) before matching.
pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    const norm_pattern = normalize(pattern);
    const norm_path = normalize(path);
    return matchHelper(norm_pattern, 0, norm_path, 0);
}

fn matchHelper(pat: []const u8, pi: usize, txt: []const u8, ti: usize) bool {
    // Both exhausted — match
    if (pi == pat.len and ti == txt.len) return true;

    // Pattern exhausted but text remains — no match
    if (pi == pat.len) return false;

    // Check for ** (double star)
    if (pi + 1 < pat.len and pat[pi] == '*' and pat[pi + 1] == '*') {
        // Advance past ** and optional trailing /
        var next_pi = pi + 2;
        if (next_pi < pat.len and pat[next_pi] == '/') next_pi += 1;

        // ** matches zero or more characters including /
        // Try rest of pattern at every position in text
        var pos = ti;
        while (pos <= txt.len) {
            if (matchHelper(pat, next_pi, txt, pos)) return true;
            if (pos == txt.len) break;
            pos += 1;
        }
        return false;
    }

    // Check for * (single star)
    if (pat[pi] == '*') {
        // * matches zero or more non-slash characters
        var pos = ti;
        while (pos <= txt.len) {
            if (matchHelper(pat, pi + 1, txt, pos)) return true;
            if (pos == txt.len or txt[pos] == '/') break;
            pos += 1;
        }
        return false;
    }

    // Text exhausted but pattern remains (and not * or **)
    if (ti == txt.len) return false;

    // ? matches any single non-slash char
    if (pat[pi] == '?' and txt[ti] != '/') {
        return matchHelper(pat, pi + 1, txt, ti + 1);
    }

    // Literal character match
    if (pat[pi] == txt[ti]) {
        return matchHelper(pat, pi + 1, txt, ti + 1);
    }

    return false;
}

// ─────────────────────────────────────────────────────────
// Tests — Glob matching
// ─────────────────────────────────────────────────────────

test "glob - ** matches empty string" {
    try std.testing.expect(globMatch("**", ""));
}

test "glob - ** matches any depth" {
    try std.testing.expect(globMatch("**", "anything/at/all"));
}

test "glob - src/** matches nested path" {
    try std.testing.expect(globMatch("src/**", "src/foo/bar.ts"));
}

test "glob - src/** matches immediate child" {
    try std.testing.expect(globMatch("src/**", "src/foo"));
}

test "glob - * matches single segment" {
    try std.testing.expect(globMatch("src/*", "src/foo"));
}

test "glob - * does not cross slash" {
    try std.testing.expect(!globMatch("src/*", "src/foo/bar"));
}

test "glob - *.ts matches file in root" {
    try std.testing.expect(globMatch("*.ts", "foo.ts"));
}

test "glob - *.ts does not match nested file" {
    try std.testing.expect(!globMatch("*.ts", "src/foo.ts"));
}

test "glob - **/*.ts matches nested file" {
    try std.testing.expect(globMatch("**/*.ts", "src/foo.ts"));
}

test "glob - **/*.ts matches deeply nested file" {
    try std.testing.expect(globMatch("**/*.ts", "src/a/b/c/foo.ts"));
}

test "glob - src/**/test matches zero segments" {
    try std.testing.expect(globMatch("src/**/test", "src/test"));
}

test "glob - src/**/test matches multiple segments" {
    try std.testing.expect(globMatch("src/**/test", "src/a/b/test"));
}

test "glob - ? matches single character" {
    try std.testing.expect(globMatch("src/?oo", "src/foo"));
}

test "glob - ? does not match extra characters" {
    try std.testing.expect(!globMatch("src/?oo", "src/fooo"));
}

test "glob - ? does not match slash" {
    try std.testing.expect(!globMatch("src/?", "src/"));
}

test "glob - leading ./ normalization on path" {
    try std.testing.expect(globMatch("src/**", "./src/foo"));
}

test "glob - leading ./ normalization on pattern" {
    try std.testing.expect(globMatch("./src/**", "src/foo"));
}

test "glob - exact path match" {
    try std.testing.expect(globMatch("README.md", "README.md"));
}

test "glob - exact path no match" {
    try std.testing.expect(!globMatch("README.md", "src/README.md"));
}

test "glob - empty pattern matches empty path" {
    try std.testing.expect(globMatch("", ""));
}

test "glob - empty pattern does not match non-empty path" {
    try std.testing.expect(!globMatch("", "foo"));
}

test "glob - pattern with trailing slash" {
    try std.testing.expect(globMatch("src/*/", "src/foo/"));
}

test "glob - src/** does not match bare src" {
    try std.testing.expect(!globMatch("src/**", "src"));
}

test "glob - **/* matches any file" {
    try std.testing.expect(globMatch("**/*", "src/foo.ts"));
    try std.testing.expect(globMatch("**/*", "foo.ts"));
}

// ─────────────────────────────────────────────────────────
// Tests — Registry operations
// ─────────────────────────────────────────────────────────

test "registry - default allow when no rules" {
    var reg = FileOwnershipRegistry.init(std.testing.allocator);
    defer reg.deinit();

    // No rules registered — should allow
    try std.testing.expect(reg.check(1, "src/anything.ts"));
}

test "registry - write pattern allows matching path" {
    var reg = FileOwnershipRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.register(1, "src/frontend/**", true);
    try std.testing.expect(reg.check(1, "src/frontend/App.tsx"));
}

test "registry - deny pattern blocks matching path" {
    var reg = FileOwnershipRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.register(1, "src/frontend/**", true);
    try reg.register(1, "src/backend/**", false);
    try std.testing.expect(!reg.check(1, "src/backend/server.ts"));
}

test "registry - deny precedence over write" {
    var reg = FileOwnershipRegistry.init(std.testing.allocator);
    defer reg.deinit();

    // Both ** (write) and src/backend/** (deny) match src/backend/foo.ts
    try reg.register(1, "**", true);
    try reg.register(1, "src/backend/**", false);
    try std.testing.expect(!reg.check(1, "src/backend/foo.ts"));
    // But non-denied path should still be allowed
    try std.testing.expect(reg.check(1, "src/frontend/bar.ts"));
}

test "registry - no match returns false (implicit deny)" {
    var reg = FileOwnershipRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.register(1, "src/frontend/**", true);
    // Path outside any write pattern — implicit deny
    try std.testing.expect(!reg.check(1, "src/backend/foo.ts"));
}

test "registry - multi-worker isolation" {
    var reg = FileOwnershipRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.register(1, "src/frontend/**", true);
    try reg.register(2, "src/backend/**", true);

    // Worker 1 can access frontend, not backend
    try std.testing.expect(reg.check(1, "src/frontend/App.tsx"));
    try std.testing.expect(!reg.check(1, "src/backend/server.ts"));

    // Worker 2 can access backend, not frontend
    try std.testing.expect(reg.check(2, "src/backend/server.ts"));
    try std.testing.expect(!reg.check(2, "src/frontend/App.tsx"));
}

test "registry - release clears rules" {
    var reg = FileOwnershipRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.register(1, "src/**", true);
    try std.testing.expect(reg.check(1, "src/foo.ts"));

    reg.release(1);

    // After release, default allow (no rules)
    try std.testing.expect(reg.check(1, "src/foo.ts"));
    try std.testing.expect(reg.check(1, "anything/at/all"));
}

test "registry - double release is idempotent" {
    var reg = FileOwnershipRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.register(1, "src/**", true);
    reg.release(1);
    reg.release(1); // should not crash
}

test "registry - register multiple patterns for same worker" {
    var reg = FileOwnershipRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.register(1, "src/frontend/**", true);
    try reg.register(1, "tests/frontend/**", true);
    try reg.register(1, "src/backend/**", false);

    try std.testing.expect(reg.check(1, "src/frontend/App.tsx"));
    try std.testing.expect(reg.check(1, "tests/frontend/App.test.tsx"));
    try std.testing.expect(!reg.check(1, "src/backend/server.ts"));
}

test "registry - copyRules returns registered rules" {
    var reg = FileOwnershipRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.register(1, "src/**", true);
    try reg.register(1, "infra/**", false);

    const rules = try reg.copyRules(1, std.testing.allocator) orelse return error.TestUnexpectedResult;
    defer FileOwnershipRegistry.freeRulesCopy(std.testing.allocator, rules);
    try std.testing.expect(rules.len == 2);
    try std.testing.expectEqualStrings("src/**", rules[0].pattern);
    try std.testing.expect(rules[0].allow_write == true);
    try std.testing.expectEqualStrings("infra/**", rules[1].pattern);
    try std.testing.expect(rules[1].allow_write == false);
}

test "registry - copyRules returns null when no rules" {
    var reg = FileOwnershipRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try std.testing.expect(try reg.copyRules(99, std.testing.allocator) == null);
}

test "registry - realistic frontend engineer role" {
    var reg = FileOwnershipRegistry.init(std.testing.allocator);
    defer reg.deinit();

    // Register patterns matching the frontend-engineer role
    try reg.register(1, "src/frontend/**", true);
    try reg.register(1, "src/components/**", true);
    try reg.register(1, "src/styles/**", true);
    try reg.register(1, "tests/frontend/**", true);
    try reg.register(1, "src/backend/**", false);
    try reg.register(1, "src/api/**", false);
    try reg.register(1, "infrastructure/**", false);

    // Allowed paths
    try std.testing.expect(reg.check(1, "src/frontend/App.tsx"));
    try std.testing.expect(reg.check(1, "src/components/Button.tsx"));
    try std.testing.expect(reg.check(1, "src/styles/theme.css"));
    try std.testing.expect(reg.check(1, "tests/frontend/App.test.tsx"));

    // Denied paths
    try std.testing.expect(!reg.check(1, "src/backend/server.ts"));
    try std.testing.expect(!reg.check(1, "src/api/routes.ts"));
    try std.testing.expect(!reg.check(1, "infrastructure/terraform.tf"));

    // Implicit deny — not in any write pattern
    try std.testing.expect(!reg.check(1, "README.md"));
    try std.testing.expect(!reg.check(1, "package.json"));
}

// ─────────────────────────────────────────────────────────
// Tests — Thread safety
// ─────────────────────────────────────────────────────────

test "registry - concurrent check calls" {
    var reg = FileOwnershipRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.register(1, "src/**", true);
    try reg.register(1, "infra/**", false);

    const num_threads = 8;
    var threads: [num_threads]std.Thread = undefined;
    var started: usize = 0;

    for (0..num_threads) |i| {
        threads[i] = std.Thread.spawn(.{}, struct {
            fn run(r: *FileOwnershipRegistry) void {
                // Each thread does many check calls
                for (0..100) |_| {
                    const allowed = r.check(1, "src/foo.ts");
                    std.debug.assert(allowed == true);
                    const denied = r.check(1, "infra/main.tf");
                    std.debug.assert(denied == false);
                }
            }
        }.run, .{&reg}) catch |err| {
            std.log.warn("thread spawn failed: {}", .{err});
            break;
        };
        started += 1;
    }

    for (threads[0..started]) |t| t.join();
}

// ─────────────────────────────────────────────────────────
// Tests — updateWorkerRules
// ─────────────────────────────────────────────────────────

test "updateWorkerRules - replaces existing rules" {
    var reg = FileOwnershipRegistry.init(std.testing.allocator);
    defer reg.deinit();

    // Register initial rules
    try reg.register(1, "src/frontend/**", true);
    try reg.register(1, "src/backend/**", false);
    try std.testing.expect(reg.check(1, "src/frontend/App.tsx"));
    try std.testing.expect(!reg.check(1, "src/backend/server.ts"));

    // Update: swap frontend/backend access
    const new_write = [_][]const u8{"src/backend/**"};
    const new_deny = [_][]const u8{"src/frontend/**"};
    try reg.updateWorkerRules(1, &new_write, &new_deny);

    // Old rules gone, new rules active
    try std.testing.expect(!reg.check(1, "src/frontend/App.tsx")); // now denied
    try std.testing.expect(reg.check(1, "src/backend/server.ts")); // now allowed
}

test "updateWorkerRules - old patterns removed" {
    var reg = FileOwnershipRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.register(1, "src/**", true);
    try reg.register(1, "infra/**", false);

    {
        const rules_before = try reg.copyRules(1, std.testing.allocator) orelse return error.TestUnexpectedResult;
        defer FileOwnershipRegistry.freeRulesCopy(std.testing.allocator, rules_before);
        try std.testing.expect(rules_before.len == 2);
    }

    // Update with completely different patterns
    const new_write = [_][]const u8{"tests/**"};
    const new_deny = [_][]const u8{"docs/**"};
    try reg.updateWorkerRules(1, &new_write, &new_deny);

    const rules_after = try reg.copyRules(1, std.testing.allocator) orelse return error.TestUnexpectedResult;
    defer FileOwnershipRegistry.freeRulesCopy(std.testing.allocator, rules_after);
    try std.testing.expect(rules_after.len == 2);
    try std.testing.expectEqualStrings("tests/**", rules_after[0].pattern);
    try std.testing.expect(rules_after[0].allow_write == true);
    try std.testing.expectEqualStrings("docs/**", rules_after[1].pattern);
    try std.testing.expect(rules_after[1].allow_write == false);

    // Old patterns no longer match
    try std.testing.expect(!reg.check(1, "src/foo.ts"));
    try std.testing.expect(!reg.check(1, "infra/main.tf"));
}

test "updateWorkerRules - creates rules for new worker" {
    var reg = FileOwnershipRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try std.testing.expect(try reg.copyRules(42, std.testing.allocator) == null);

    const write = [_][]const u8{"src/**"};
    const deny = [_][]const u8{"vendor/**"};
    try reg.updateWorkerRules(42, &write, &deny);

    const rules = try reg.copyRules(42, std.testing.allocator) orelse return error.TestUnexpectedResult;
    defer FileOwnershipRegistry.freeRulesCopy(std.testing.allocator, rules);
    try std.testing.expect(rules.len == 2);
    try std.testing.expect(reg.check(42, "src/main.zig"));
    try std.testing.expect(!reg.check(42, "vendor/lib.zig"));
}

test "updateWorkerRules - empty patterns denies all writes" {
    var reg = FileOwnershipRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.register(1, "src/**", true);
    try reg.register(1, "infra/**", false);

    // Update with no patterns — explicit empty rule set (deny-all,
    // unlike no-rules default-allow from release())
    const empty = [_][]const u8{};
    try reg.updateWorkerRules(1, &empty, &empty);

    const rules = try reg.copyRules(1, std.testing.allocator) orelse return error.TestUnexpectedResult;
    defer FileOwnershipRegistry.freeRulesCopy(std.testing.allocator, rules);
    try std.testing.expect(rules.len == 0);
    // Empty rule set means implicit deny for all paths
    try std.testing.expect(!reg.check(1, "src/anything.ts"));
    try std.testing.expect(!reg.check(1, "any/path/at/all"));
}

test "updateWorkerRules - does not affect other workers" {
    var reg = FileOwnershipRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.register(1, "src/frontend/**", true);
    try reg.register(2, "src/backend/**", true);

    const new_write = [_][]const u8{"tests/**"};
    const new_deny = [_][]const u8{"src/**"};
    try reg.updateWorkerRules(1, &new_write, &new_deny);

    // Worker 1 updated
    try std.testing.expect(!reg.check(1, "src/frontend/App.tsx"));
    try std.testing.expect(reg.check(1, "tests/foo.test.ts"));

    // Worker 2 unchanged
    try std.testing.expect(reg.check(2, "src/backend/server.ts"));
}

test "updateWorkerRules - concurrent update and check" {
    var reg = FileOwnershipRegistry.init(std.testing.allocator);
    defer reg.deinit();

    const initial_write = [_][]const u8{"src/**"};
    const initial_deny = [_][]const u8{"infra/**"};
    try reg.updateWorkerRules(1, &initial_write, &initial_deny);

    const num_threads = 4;
    var threads: [num_threads]std.Thread = undefined;
    var started: usize = 0;

    // Spawn threads that check while main thread updates
    for (0..num_threads) |i| {
        threads[i] = std.Thread.spawn(.{}, struct {
            fn run(r: *FileOwnershipRegistry) void {
                for (0..50) |_| {
                    // check() must not crash regardless of concurrent updates
                    _ = r.check(1, "src/foo.ts");
                    _ = r.check(1, "infra/main.tf");
                }
            }
        }.run, .{&reg}) catch |err| {
            std.log.warn("thread spawn failed: {}", .{err});
            break;
        };
        started += 1;
    }

    // Perform updates concurrently with checks
    for (0..10) |_| {
        const w = [_][]const u8{"src/**"};
        const d = [_][]const u8{"infra/**"};
        reg.updateWorkerRules(1, &w, &d) catch |err| {
            std.debug.panic("updateWorkerRules failed unexpectedly: {}", .{err});
        };
    }

    for (threads[0..started]) |t| t.join();
}
