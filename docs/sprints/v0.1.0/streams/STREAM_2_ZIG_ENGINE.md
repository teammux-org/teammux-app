# Teammux v0.1 — Stream 2: Zig Engine

**Branch:** `feat/stream2-zig-engine`  
**Merges into:** `main`  
**Merge order:** SECOND — after Stream 1 (requires `teammux.h` to exist)  
**Dependency:** Stream 1 must be merged first. Pull `main` before starting.

---

## Your mission

Implement every function declared in `engine/include/teammux.h`. All logic lives in `engine/src/`. The output is `libteammux.a` — a static library that Swift links directly. No separate process, no IPC socket, no runtime. Direct in-process C API calls.

The engine is the brain of Teammux. It owns:
- Git worktree lifecycle (spawn, dismiss, cleanup)
- PTY ownership (spawn with correct cwd, stdin injection)
- Message bus (guaranteed delivery, ordered, bidirectional)
- TOML config parsing and hot-reload
- GitHub API integration via `gh` CLI
- `/teammux-*` command file watching
- Session-persistent message log

---

## Step 0 — Read first

```bash
git pull origin main          # get Stream 1 output
cat engine/include/teammux.h  # your contract — implement every function
cat CLAUDE.md                 # project context
```

Do not modify `teammux.h`. If you find an issue with the contract, note it in your PR and discuss — but implement what's there.

---

## Step 1 — `engine/src/main.zig` — engine struct and lifecycle

The `tm_engine_t` struct is the central object. All state lives here.

```zig
const std = @import("std");
const worktree = @import("worktree.zig");
const pty = @import("pty.zig");
const bus = @import("bus.zig");
const config = @import("config.zig");
const github = @import("github.zig");
const commands = @import("commands.zig");

pub const Engine = struct {
    allocator: std.mem.Allocator,
    project_root: []const u8,
    config: config.Config,
    roster: worktree.Roster,
    bus: bus.MessageBus,
    github: github.GitHubClient,
    commands_watcher: commands.CommandWatcher,
    last_error: ?[]const u8,

    pub fn create(allocator: std.mem.Allocator, project_root: []const u8) !*Engine { ... }
    pub fn destroy(self: *Engine) void { ... }
    pub fn sessionStart(self: *Engine) !void { ... }
    pub fn sessionStop(self: *Engine) void { ... }
};

// C exports — delegate to Engine methods
export fn tm_engine_create(project_root: [*:0]const u8) ?*Engine { ... }
export fn tm_engine_destroy(engine: *Engine) void { ... }
export fn tm_session_start(engine: *Engine) c_int { ... }
export fn tm_session_stop(engine: *Engine) void { ... }
export fn tm_engine_last_error(engine: *Engine) [*:0]const u8 { ... }
export fn tm_version() [*:0]const u8 { return "0.1.0"; }
```

---

## Step 2 — `engine/src/config.zig` — TOML config + hot-reload

### 2.1 TOML parsing
Use Zig's `std.zig.Tokenizer` or embed a minimal TOML parser. The config schema is simple enough that a hand-rolled parser is appropriate — no external dependencies.

Parse `.teammux/config.toml` into a `Config` struct:

```zig
pub const AgentType = enum { claude_code, codex_cli, custom };

pub const WorkerConfig = struct {
    id: []const u8,
    name: []const u8,
    agent: AgentType,
    model: []const u8,
    permissions: []const u8,
    default_task: []const u8,
};

pub const TeamLeadConfig = struct {
    agent: AgentType,
    model: []const u8,
    permissions: []const u8,
};

pub const ProjectConfig = struct {
    name: []const u8,
    github_repo: ?[]const u8,
};

pub const Config = struct {
    project: ProjectConfig,
    team_lead: TeamLeadConfig,
    workers: []WorkerConfig,
    github_token: ?[]const u8,
    bus_delivery: []const u8,  // "guaranteed" | "observer"
};
```

### 2.2 Hot-reload via kqueue
Use macOS `kqueue` + `kevent` to watch `.teammux/config.toml` for modifications:

```zig
pub fn watchConfig(self: *ConfigWatcher, callback: tm_config_changed_cb, userdata: ?*anyopaque) !void {
    // kqueue setup for VNODE events on config.toml
    // On EVFILT_VNODE with NOTE_WRITE: reload config, call callback
    // Run in dedicated thread
}
```

### 2.3 Hot-reload behavior
On config change:
- Reload `Config` struct atomically (swap pointer under mutex)
- For idle workers: apply new model/settings immediately
- For active workers: queue the update, apply on next idle state
- Call registered `tm_config_changed_cb`

### 2.4 Local override merging
After loading `config.toml`, check for `.teammux/config.local.toml`. If present, merge — local values override base values for matching keys.

---

## Step 3 — `engine/src/worktree.zig` — git worktree lifecycle

### 3.1 Spawn

```zig
pub fn spawn(
    self: *Roster,
    allocator: std.mem.Allocator,
    project_root: []const u8,
    agent_binary: []const u8,
    agent_type: AgentType,
    worker_name: []const u8,
    task_description: []const u8,
) !WorkerId {
    // 1. Generate branch name: {worker-name}/teammux-{task-slug}
    //    task-slug: first 40 chars, lowercase, spaces→hyphens, strip non-alphanumeric
    const branch = try makeBranchName(allocator, worker_name, task_description);

    // 2. Run: git worktree add .teammux/{branch-slug} -b {branch}
    const worktree_path = try std.fmt.allocPrint(
        allocator, "{s}/.teammux/{s}", .{ project_root, slugify(worker_name) }
    );
    try runGit(allocator, project_root, &.{
        "worktree", "add", worktree_path, "-b", branch
    });

    // 3. Write CLAUDE.md or AGENTS.md into worktree root
    try writeContextFile(allocator, worktree_path, agent_type, task_description);

    // 4. Create worker entry in roster
    const worker_id = self.nextId();
    try self.workers.put(worker_id, .{
        .id = worker_id,
        .name = try allocator.dupe(u8, worker_name),
        .task_description = try allocator.dupe(u8, task_description),
        .branch_name = branch,
        .worktree_path = worktree_path,
        .status = .idle,
        .agent_type = agent_type,
        .agent_binary = try allocator.dupe(u8, agent_binary),
        .spawned_at = @intCast(std.time.timestamp()),
    });

    return worker_id;
}
```

### 3.2 Context file writing

```zig
fn writeContextFile(
    allocator: std.mem.Allocator,
    worktree_path: []const u8,
    agent_type: AgentType,
    task_description: []const u8,
) !void {
    // Claude Code → CLAUDE.md
    // All others → AGENTS.md
    const filename = if (agent_type == .claude_code) "CLAUDE.md" else "AGENTS.md";
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ worktree_path, filename });
    defer allocator.free(path);

    const content = try buildContextFileContent(allocator, task_description);
    defer allocator.free(content);

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(content);
}

fn buildContextFileContent(allocator: std.mem.Allocator, task: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\# Teammux Worker Context
        \\
        \\## Your assigned task
        \\{s}
        \\
        \\## How to signal completion
        \\When your task is complete, write this file to signal the Team Lead:
        \\```
        \\echo '{{"status":"complete","summary":"brief description of what you did"}}' > .task_complete.json
        \\```
        \\Then push your branch: `git push origin HEAD`
        \\
        \\## Working context
        \\- You are working in an isolated git worktree on your own branch
        \\- Your changes are fully isolated — you cannot affect other workers
        \\- The Team Lead may send you instructions via this terminal
        \\- Always commit your work before signaling completion
        \\
    , .{task});
}
```

### 3.3 Dismiss

```zig
pub fn dismiss(self: *Roster, worker_id: WorkerId, project_root: []const u8) !void {
    const worker = self.workers.get(worker_id) orelse return error.WorkerNotFound;

    // Terminate PTY gracefully (handled by pty.zig)
    // git worktree remove — force if dirty
    try runGit(allocator, project_root, &.{
        "worktree", "remove", "--force", worker.worktree_path
    });
    // Branch is KEPT on remote. Never auto-delete.

    _ = self.workers.remove(worker_id);
}
```

### 3.4 Branch naming
```zig
fn makeBranchName(allocator: std.mem.Allocator, worker_name: []const u8, task: []const u8) ![]u8 {
    // Prefix: worker name, lowercased, spaces→hyphens
    // Suffix: first 40 chars of task, same transform
    // Result: "frontend/teammux-implement-auth-middleware"
    const name_slug = try slugify(allocator, worker_name);
    const task_slug = try slugifyTruncate(allocator, task, 40);
    return std.fmt.allocPrint(allocator, "{s}/teammux-{s}", .{ name_slug, task_slug });
}
```

---

## Step 4 — `engine/src/pty.zig` — PTY ownership

### 4.1 Spawn PTY for a worker

```zig
pub const Pty = struct {
    master_fd: std.posix.fd_t,
    slave_fd: std.posix.fd_t,
    child_pid: std.posix.pid_t,

    pub fn spawn(
        allocator: std.mem.Allocator,
        agent_binary: []const u8,
        worktree_path: []const u8,
        env: []const []const u8,
    ) !Pty {
        // posix_openpt → grantpt → unlockpt → ptsname
        // fork → setsid → ioctl(TIOCSCTTY) → execvp(agent_binary)
        // Parent retains master_fd
        // cwd of child = worktree_path
    }
};
```

Key requirements:
- `cwd` of the child process MUST be `worktree_path` — this is what scopes all git commands
- Pass `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_0`, `GIT_CONFIG_VALUE_0` in env to prevent push to main from workers (defense in depth — worktrees already isolate, but belt-and-suspenders)
- Team Lead PTY gets `remote.origin.pushurl = no_push` env var

### 4.2 Task injection

```zig
pub fn sendText(self: *Pty, text: []const u8) !void {
    // Write to master_fd
    // text is written as-is to the PTY stdin
    _ = try std.posix.write(self.master_fd, text);
}
```

Called 2 seconds after PTY spawn to inject the task description (known v0.1 limitation — Phase 2 will use a readiness signal).

### 4.3 Terminate gracefully

```zig
pub fn terminate(self: *Pty) void {
    // SIGTERM → wait 5s → SIGKILL if still running
    std.posix.kill(self.child_pid, std.posix.SIG.TERM) catch {};
    // ... 5s timer + SIGKILL fallback
    std.posix.close(self.master_fd);
    std.posix.close(self.slave_fd);
}
```

---

## Step 5 — `engine/src/bus.zig` — guaranteed delivery message bus

### 5.1 Core data structures

```zig
pub const MessageType = enum(c_int) {
    task = 0,
    instruction = 1,
    context = 2,
    status_req = 3,
    status_rpt = 4,
    completion = 5,
    err = 6,
    broadcast = 7,
};

pub const Message = struct {
    from: WorkerId,
    to: WorkerId,       // 0 = Team Lead
    type: MessageType,
    payload: []const u8, // JSON string
    timestamp: u64,
    seq: u64,           // global sequence number, monotonically increasing
    git_commit: ?[]const u8, // HEAD at time of message
};

pub const MessageBus = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    queues: std.AutoHashMap(WorkerId, std.ArrayList(Message)),
    seq_counter: std.atomic.Value(u64),
    log_file: std.fs.File,
    subscriber: ?tm_message_cb,
    subscriber_userdata: ?*anyopaque,
};
```

### 5.2 Guaranteed delivery

```zig
pub fn send(
    self: *MessageBus,
    to: WorkerId,
    from: WorkerId,
    msg_type: MessageType,
    payload: []const u8,
    pty_map: *PtyMap,
) !void {
    // 1. Assign sequence number atomically
    const seq = self.seq_counter.fetchAdd(1, .monotonic);

    // 2. Build message with current git HEAD
    const commit = try getCurrentGitCommit(self.allocator);
    const msg = Message{
        .from = from, .to = to,
        .type = msg_type, .payload = payload,
        .timestamp = @intCast(std.time.timestamp()),
        .seq = seq, .git_commit = commit,
    };

    // 3. Persist to log immediately (before delivery attempt)
    try self.appendLog(msg);

    // 4. Deliver via PTY stdin injection
    const text = try formatMessageForPty(self.allocator, msg);
    defer self.allocator.free(text);

    // 5. Retry up to 3 times with 1s delay on failure
    var attempts: u8 = 0;
    while (attempts < 3) : (attempts += 1) {
        if (pty_map.send(to, text)) |_| break
        else |_| std.time.sleep(1 * std.time.ns_per_s);
    }
    // If all retries fail: log delivery failure, notify Live Feed
}
```

### 5.3 Message log persistence

```zig
fn appendLog(self: *MessageBus, msg: Message) !void {
    // Append JSON line to .teammux/logs/{YYYY-MM-DD}-{session-id}.log
    // Format: {"seq":1,"from":1,"to":0,"type":"completion","timestamp":1234567890,
    //          "git_commit":"abc123","payload":{...}}
    self.mutex.lock();
    defer self.mutex.unlock();
    const line = try std.json.stringifyAlloc(self.allocator, msg, .{});
    defer self.allocator.free(line);
    try self.log_file.writeAll(line);
    try self.log_file.writeAll("\n");
}
```

Log file path: `.teammux/logs/{YYYY-MM-DD}-{session-id}.jsonl`  
Session ID: 8-char random hex generated at engine startup.  
Never auto-deleted. Survives session restart.

---

## Step 6 — `engine/src/github.zig` — GitHub API + webhook forward

### 6.1 Auth resolution

```zig
pub fn auth(self: *GitHubClient) !void {
    // Try 1: read from ~/.config/gh/hosts.yml
    if (try self.readGhCliToken()) |token| {
        self.token = token;
        return;
    }
    // Try 2: read from config.toml github_token
    if (self.config_token) |token| {
        self.token = token;
        return;
    }
    // Try 3: OAuth flow (triggers Swift callback to show browser)
    // ... handled by Swift layer via tm_github_auth callback
    return error.Unauthenticated;
}

fn readGhCliToken(self: *GitHubClient) !?[]const u8 {
    // Parse ~/.config/gh/hosts.yml
    // Find oauth_token under github.com entry
    const home = std.posix.getenv("HOME") orelse return null;
    const path = try std.fmt.allocPrint(
        self.allocator, "{s}/.config/gh/hosts.yml", .{home}
    );
    // ... parse YAML (simple enough to hand-parse for this structure)
}
```

### 6.2 GitHub API calls via `gh` CLI

Use `gh` CLI as the HTTP client to avoid managing OAuth token headers manually:

```zig
fn ghApiCall(
    self: *GitHubClient,
    allocator: std.mem.Allocator,
    method: []const u8,
    endpoint: []const u8,
    body: ?[]const u8,
) ![]u8 {
    // Run: gh api --method {method} {endpoint} --input - <<< {body}
    // Returns stdout as JSON string
    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();
    try args.appendSlice(&.{ "gh", "api", "--method", method, endpoint });
    if (body) |b| {
        try args.appendSlice(&.{ "--input", "-" });
        // pipe body to stdin
    }
    return runCommand(allocator, args.items, body);
}
```

### 6.3 PR creation

```zig
pub fn createPr(
    self: *GitHubClient,
    allocator: std.mem.Allocator,
    worker: WorkerInfo,
    title: []const u8,
    body: []const u8,
) !Pr {
    const payload = try std.json.stringifyAlloc(allocator, .{
        .title = title,
        .body = body,
        .head = worker.branch_name,
        .base = "main",
    }, .{});
    defer allocator.free(payload);

    const response = try self.ghApiCall(
        allocator, "POST",
        try std.fmt.allocPrint(allocator, "/repos/{s}/pulls", .{self.repo}),
        payload
    );
    // Parse response JSON → Pr struct
}
```

### 6.4 Webhook forward

```zig
pub fn startWebhookForward(
    self: *GitHubClient,
    allocator: std.mem.Allocator,
    callback: tm_github_event_cb,
    userdata: ?*anyopaque,
) !void {
    // 1. Start local HTTP server on random port
    const port = try self.startLocalServer(callback, userdata);

    // 2. Spawn: gh webhook forward --repo={repo} --events=pull_request,push,check_run
    //           --url=http://localhost:{port}
    const args = &.{
        "gh", "webhook", "forward",
        try std.fmt.allocPrint(allocator, "--repo={s}", .{self.repo}),
        "--events=pull_request,push,check_run",
        try std.fmt.allocPrint(allocator, "--url=http://localhost:{d}", .{port}),
    };
    self.webhook_process = try std.process.Child.init(args, allocator);
    try self.webhook_process.?.spawn();
}
```

Fallback: if `gh webhook forward` returns non-zero exit or is unavailable, silently switch to 60s polling using `gh api /repos/{repo}/pulls`.

---

## Step 7 — `engine/src/commands.zig` — /teammux-* command watcher

```zig
pub fn watch(
    self: *CommandWatcher,
    project_root: []const u8,
    callback: tm_command_cb,
    userdata: ?*anyopaque,
) !void {
    // Watch .teammux/commands/ directory via kqueue EVFILT_VNODE NOTE_WRITE
    // On new file detected:
    //   1. Read file contents (JSON)
    //   2. Parse: {"command": "/teammux-add", "args": {...}}
    //   3. Call callback(command, args_json, userdata)
    //   4. Delete file after processing
    // Run in dedicated background thread
}
```

Command file format (written by Team Lead's CLAUDE.md skill):
```json
{
  "command": "/teammux-add",
  "args": {
    "task": "implement the payment flow",
    "agent": "claude-code",
    "model": "claude-sonnet-4-6"
  }
}
```

---

## Step 8 — `engine/src/main.zig` — all C exports wired up

Complete the export of every function in `teammux.h`. Each export is a thin wrapper that calls into the appropriate module:

```zig
export fn tm_worker_spawn(
    engine: *Engine,
    agent_binary: [*:0]const u8,
    agent_type: c_int,
    worker_name: [*:0]const u8,
    task_description: [*:0]const u8,
) u32 {
    const id = engine.roster.spawn(
        engine.allocator,
        engine.project_root,
        std.mem.span(agent_binary),
        @enumFromInt(agent_type),
        std.mem.span(worker_name),
        std.mem.span(task_description),
    ) catch |err| {
        engine.setError(err);
        return 0;
    };
    return @intCast(id);
}

export fn tm_pty_send(engine: *Engine, worker_id: u32, text: [*:0]const u8) c_int {
    engine.pty_map.send(@intCast(worker_id), std.mem.span(text)) catch |err| {
        engine.setError(err);
        return @intFromEnum(TmResult.err_pty);
    };
    return @intFromEnum(TmResult.ok);
}

// ... all other exports follow the same pattern
```

---

## Step 9 — Tests

All tests live alongside the source files in `engine/src/`. Use Zig's built-in test framework.

### Required test coverage

**worktree.zig tests:**
- `test "branch name from worker name and task"` — verify slug format
- `test "context file is CLAUDE.md for claude_code agent"`
- `test "context file is AGENTS.md for codex_cli agent"`
- `test "worktree spawn creates directory"` — tempdir + real git init
- `test "worktree dismiss removes directory keeps branch"` — tempdir integration test

**config.zig tests:**
- `test "parse minimal config.toml"`
- `test "local override merges correctly"`
- `test "missing optional fields use defaults"`

**bus.zig tests:**
- `test "messages are assigned monotonically increasing seq numbers"`
- `test "log file is created and contains valid JSONL"`
- `test "broadcast sends to all active workers"`
- `test "delivery failure is logged not silently dropped"`

**commands.zig tests:**
- `test "command file is parsed and callback fired"`
- `test "command file is deleted after processing"`

**Run all tests:**
```bash
cd engine && zig build test
```

Target: all tests pass. Zero failures.

---

## Definition of done — Stream 2

- [ ] `cd engine && zig build` produces `libteammux.a` without errors
- [ ] `cd engine && zig build test` — all tests pass
- [ ] Every function in `teammux.h` has a corresponding `export fn` in `main.zig`
- [ ] `tm_worker_spawn` creates a real git worktree in a temp test directory
- [ ] `tm_pty_send` writes to PTY master fd successfully
- [ ] `tm_config_reload` parses the test config without error
- [ ] `tm_github_auth` reads token from `~/.config/gh/hosts.yml` when present
- [ ] Message log file created at `.teammux/logs/` with correct JSONL format
- [ ] All five open questions from the spec are reflected in the implementation

**Commit message:** `feat: stream 2 — Zig engine, libteammux.a, full C API implementation`

**Open a PR from `feat/stream2-zig-engine` into `main`. Do not merge — report back.**
