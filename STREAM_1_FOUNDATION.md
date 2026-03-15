# Teammux v0.1 — Stream 1: Foundation

**Branch:** `feat/stream1-foundation`  
**Merges into:** `main`  
**Merge order:** FIRST — everything else depends on this  
**Parallel with:** Stream 2 and Stream 3 can begin in parallel after `teammux.h` is committed

---

## Your mission

You are building the foundation that all other streams depend on. Your output has two deliverables:

1. A clean Ghostty fork configured as Teammux — single window, correct bundle identity, correct build output
2. `engine/include/teammux.h` — the complete C API contract that Stream 2 implements and Stream 3 calls

Do not implement any engine logic. Do not build any Swift UI beyond suppressing the default Ghostty window. Define the contract. Make the build work. Everything else follows.

---

## Step 0 — Read first

Read these files before doing anything:
- `CLAUDE.md` (once written — you will write it)
- Ghostty's `build.zig` and `build.zig.zon` — understand the build system you're working with
- `macos/Sources/App/macOS/AppDelegate.swift` — find the default window creation
- `include/ghostty.h` — understand the existing C API pattern you're extending

---

## Step 1 — Fork and rename

### 1.1 Verify starting state
```bash
git log --oneline -5        # confirm clean Ghostty base
git remote -v               # confirm upstream remote exists
```

### 1.2 App bundle identity
Find and update every location where the Ghostty app identity is defined:

**Xcode project / xcconfig files:**
- `PRODUCT_NAME` → `Teammux`
- `PRODUCT_BUNDLE_IDENTIFIER` → `com.teammux.app`
- `MARKETING_VERSION` → `0.1.0`
- `CURRENT_PROJECT_VERSION` → `1`

**Info.plist:**
- `CFBundleName` → `Teammux`
- `CFBundleDisplayName` → `Teammux`
- `CFBundleIdentifier` → `com.teammux.app`
- `CFBundleShortVersionString` → `0.1.0`
- `NSHumanReadableCopyright` → `Copyright © 2026 Teammux Contributors`

**AppDelegate.swift — window title:**
Any hardcoded "Ghostty" strings in window titles → "Teammux"

### 1.3 macOS deployment target
Set `MACOSX_DEPLOYMENT_TARGET = 15.0` in all xcconfig files and the Xcode project.
Apple Silicon only — no Intel target.

---

## Step 2 — Suppress the spurious Ghostty window

The default Ghostty `AppDelegate` opens its own terminal window in `applicationDidFinishLaunching`. Teammux must open exactly ONE window — the Teammux workspace window.

### 2.1 Find the default window creation
In `macos/Sources/App/macOS/AppDelegate.swift`, locate:
- The call that creates the initial Ghostty terminal window
- Any `applicationOpenUntitledFile` or similar methods that create windows

### 2.2 Gate the default window
Add a flag that prevents the default Ghostty window from opening when Teammux's own window management takes over:

```swift
// In AppDelegate — add this property
private var teammuxWindowOpen = false

// Gate the default window creation:
// If teammuxWindowOpen is true, do not create the default Ghostty terminal window
```

### 2.3 Open the Teammux window
In `applicationDidFinishLaunching`, after Ghostty initialization completes, open the Teammux workspace window:

```swift
func openTeammuxWindow() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = "Teammux"
    window.center()
    // ContentView will be wired by Stream 3 — for now show a placeholder
    window.contentViewController = NSHostingController(
        rootView: Text("Teammux loading...").frame(maxWidth: .infinity, maxHeight: .infinity)
    )
    window.makeKeyAndOrderFront(nil)
    teammuxWindowOpen = true
}
```

**Result:** Launching `Teammux.app` opens exactly one window with the title "Teammux". No Ghostty terminal window appears.

---

## Step 3 — Engine directory structure

Create the `engine/` directory at repo root. This is the Zig coordination engine. Stream 2 will implement it — your job is to create the scaffold that builds cleanly.

```
engine/
├── build.zig           ← produces libteammux.a
├── src/
│   ├── main.zig        ← engine entry point (stub for now)
│   ├── worktree.zig    ← stub
│   ├── pty.zig         ← stub
│   ├── bus.zig         ← stub
│   ├── config.zig      ← stub
│   ├── github.zig      ← stub
│   └── commands.zig    ← stub
└── include/
    └── teammux.h       ← THE DELIVERABLE (see Step 4)
```

### 3.1 `engine/build.zig` — produces `libteammux.a`

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "teammux",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib.installHeader(b.path("include/teammux.h"), "teammux.h");
    b.installArtifact(lib);
}
```

### 3.2 `engine/src/main.zig` — stub that compiles

```zig
pub const engine = @import("worktree.zig");

// C API exports — all stubs for now, Stream 2 implements
const c = @cImport(@cInclude("teammux.h"));
```

All other `.zig` files in `src/` are empty stubs:
```zig
// stub — implemented in Stream 2
```

### 3.3 Confirm engine builds
```bash
cd engine && zig build
# Must produce: zig-out/lib/libteammux.a
```

---

## Step 4 — `engine/include/teammux.h` — THE CRITICAL DELIVERABLE

This is the most important file in Stream 1. It is the complete contract between Zig and Swift. Stream 2 implements every function. Stream 3 calls every function. Get it right.

```c
#ifndef TEAMMUX_H
#define TEAMMUX_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ─────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────

typedef struct tm_engine tm_engine_t;
typedef uint32_t tm_worker_id_t;
#define TM_WORKER_TEAM_LEAD 0  // Team Lead always has ID 0

typedef enum {
    TM_OK              = 0,
    TM_ERR_NOT_GIT     = 1,   // project root is not a git repo
    TM_ERR_NO_GH       = 2,   // gh CLI not found
    TM_ERR_GH_UNAUTH   = 3,   // gh CLI not authenticated
    TM_ERR_NO_AGENT    = 4,   // agent binary not found in PATH
    TM_ERR_WORKTREE    = 5,   // git worktree operation failed
    TM_ERR_PTY         = 6,   // PTY spawn failed
    TM_ERR_CONFIG      = 7,   // config parse error
    TM_ERR_BUS         = 8,   // message bus error
    TM_ERR_GITHUB      = 9,   // GitHub API error
    TM_ERR_UNKNOWN     = 99,
} tm_result_t;

typedef enum {
    TM_WORKER_STATUS_IDLE      = 0,
    TM_WORKER_STATUS_WORKING   = 1,
    TM_WORKER_STATUS_COMPLETE  = 2,  // task done, PR ready
    TM_WORKER_STATUS_BLOCKED   = 3,  // needs Team Lead guidance
    TM_WORKER_STATUS_ERROR     = 4,
} tm_worker_status_t;

typedef enum {
    TM_AGENT_CLAUDE_CODE = 0,
    TM_AGENT_CODEX_CLI   = 1,
    TM_AGENT_CUSTOM      = 99,  // any other binary
} tm_agent_type_t;

typedef enum {
    TM_MSG_TASK        = 0,   // Team Lead → worker: assign/update task
    TM_MSG_INSTRUCTION = 1,   // Team Lead → worker: inline instruction
    TM_MSG_CONTEXT     = 2,   // Team Lead → worker: additional context
    TM_MSG_STATUS_REQ  = 3,   // Team Lead → worker: request status report
    TM_MSG_STATUS_RPT  = 4,   // worker → Team Lead: status report
    TM_MSG_COMPLETION  = 5,   // worker → Team Lead: task complete
    TM_MSG_ERROR       = 6,   // worker → Team Lead: blocked/error
    TM_MSG_BROADCAST   = 7,   // Team Lead → all workers
} tm_message_type_t;

typedef enum {
    TM_MERGE_SQUASH = 0,   // squash all commits into one (default)
    TM_MERGE_REBASE = 1,
    TM_MERGE_MERGE  = 2,
} tm_merge_strategy_t;

typedef struct {
    tm_worker_id_t     id;
    const char*        name;           // worker name from config (e.g. "Frontend")
    const char*        task_description;
    const char*        branch_name;    // e.g. "frontend/teammux-implement-auth"
    const char*        worktree_path;  // absolute path to worktree directory
    tm_worker_status_t status;
    tm_agent_type_t    agent_type;
    const char*        agent_binary;   // resolved PATH to agent binary
    uint64_t           spawned_at;     // unix timestamp
} tm_worker_info_t;

typedef struct {
    tm_worker_info_t*  workers;
    uint32_t           count;
} tm_roster_t;

typedef struct {
    tm_worker_id_t     from;
    tm_worker_id_t     to;           // TM_WORKER_TEAM_LEAD for messages to lead
    tm_message_type_t  type;
    const char*        payload;      // JSON string
    uint64_t           timestamp;    // unix timestamp
    uint64_t           seq;          // sequence number (guaranteed ordering)
    const char*        git_commit;   // HEAD commit hash at time of message (nullable)
} tm_message_t;

typedef struct {
    uint64_t           pr_number;
    const char*        pr_url;
    const char*        title;
    const char*        state;        // "open", "closed", "merged"
    const char*        diff_url;
} tm_pr_t;

typedef struct {
    const char*        file_path;
    int32_t            additions;
    int32_t            deletions;
    const char*        patch;        // unified diff string
} tm_diff_file_t;

typedef struct {
    tm_diff_file_t*    files;
    uint32_t           count;
    int32_t            total_additions;
    int32_t            total_deletions;
} tm_diff_t;

// ─────────────────────────────────────────────────────────
// Callbacks
// ─────────────────────────────────────────────────────────

// Called when a message arrives on the bus (worker → Team Lead or broadcast)
typedef void (*tm_message_cb)(const tm_message_t* message, void* userdata);

// Called when the roster changes (worker spawned, dismissed, status changed)
typedef void (*tm_roster_changed_cb)(const tm_roster_t* roster, void* userdata);

// Called when config.toml changes (hot-reload)
typedef void (*tm_config_changed_cb)(void* userdata);

// Called when a GitHub webhook event arrives
typedef void (*tm_github_event_cb)(const char* event_type, const char* payload_json, void* userdata);

// Called when a /teammux-* command is written to .teammux/commands/
typedef void (*tm_command_cb)(const char* command, const char* args_json, void* userdata);

// ─────────────────────────────────────────────────────────
// Engine lifecycle
// ─────────────────────────────────────────────────────────

// Create engine for a project. project_root must be an absolute path.
// Returns NULL on failure. Check tm_engine_last_error() for details.
tm_engine_t* tm_engine_create(const char* project_root);

// Destroy engine and clean up all resources.
// Does NOT remove worktrees — those persist until explicitly dismissed.
void tm_engine_destroy(tm_engine_t* engine);

// Start the engine session (reads config, starts watchers, starts GitHub webhook forward)
tm_result_t tm_session_start(tm_engine_t* engine);

// Stop the engine session cleanly
void tm_session_stop(tm_engine_t* engine);

// Get last error message (human-readable string, valid until next call)
const char* tm_engine_last_error(tm_engine_t* engine);

// ─────────────────────────────────────────────────────────
// Config
// ─────────────────────────────────────────────────────────

// Reload config.toml immediately (also called automatically on file change)
tm_result_t tm_config_reload(tm_engine_t* engine);

// Register callback for config hot-reload events
void tm_config_watch(tm_engine_t* engine, tm_config_changed_cb callback, void* userdata);

// Get a config value by dot-notation key (e.g. "project.name", "team_lead.model")
// Returns NULL if key not found. Caller must not free the returned string.
const char* tm_config_get(tm_engine_t* engine, const char* key);

// ─────────────────────────────────────────────────────────
// Worktree and worker lifecycle
// ─────────────────────────────────────────────────────────

// Spawn a new worker in a new git worktree.
// agent_binary: resolved absolute path to agent CLI
// worker_name: display name (e.g. "Frontend") — used as branch prefix
// task_description: human-readable task
// Returns worker ID on success, 0 on failure.
tm_worker_id_t tm_worker_spawn(
    tm_engine_t* engine,
    const char*  agent_binary,
    tm_agent_type_t agent_type,
    const char*  worker_name,
    const char*  task_description
);

// Dismiss a worker.
// Removes the worktree directory. Branch is KEPT permanently on remote.
// In-progress PTY is terminated gracefully (SIGTERM, then SIGKILL after 5s).
tm_result_t tm_worker_dismiss(tm_engine_t* engine, tm_worker_id_t worker_id);

// Get current roster snapshot. Caller must call tm_roster_free() when done.
tm_roster_t* tm_roster_get(tm_engine_t* engine);
void         tm_roster_free(tm_roster_t* roster);

// Get info for a specific worker. Returns NULL if not found.
// Caller must call tm_worker_info_free() when done.
tm_worker_info_t* tm_worker_get(tm_engine_t* engine, tm_worker_id_t worker_id);
void              tm_worker_info_free(tm_worker_info_t* info);

// Register callback for roster changes
void tm_roster_watch(tm_engine_t* engine, tm_roster_changed_cb callback, void* userdata);

// ─────────────────────────────────────────────────────────
// PTY interaction
// ─────────────────────────────────────────────────────────

// Inject text into a worker's PTY stdin (as if typed by the user).
// Used for task injection at spawn and message delivery.
// text is sent as-is. Append "\n" to simulate pressing Enter.
tm_result_t tm_pty_send(tm_engine_t* engine, tm_worker_id_t worker_id, const char* text);

// Get the PTY file descriptor for a worker (used by Ghostty SurfaceView)
int tm_pty_fd(tm_engine_t* engine, tm_worker_id_t worker_id);

// ─────────────────────────────────────────────────────────
// Message bus
// ─────────────────────────────────────────────────────────

// Send a message from Team Lead to a specific worker (guaranteed delivery, ordered).
// payload: JSON string with message content.
tm_result_t tm_message_send(
    tm_engine_t*      engine,
    tm_worker_id_t    target_worker_id,
    tm_message_type_t type,
    const char*       payload
);

// Broadcast a message from Team Lead to all active workers.
tm_result_t tm_message_broadcast(
    tm_engine_t*      engine,
    tm_message_type_t type,
    const char*       payload
);

// Register callback for incoming messages (worker → Team Lead direction)
void tm_message_subscribe(tm_engine_t* engine, tm_message_cb callback, void* userdata);

// ─────────────────────────────────────────────────────────
// GitHub integration
// ─────────────────────────────────────────────────────────

// Attempt GitHub auth. Tries: gh CLI → OAuth flow → config.toml token.
// Returns TM_ERR_GH_UNAUTH if none succeed.
tm_result_t tm_github_auth(tm_engine_t* engine);

// Returns true if GitHub auth is currently valid
bool tm_github_is_authed(tm_engine_t* engine);

// Create a GitHub PR for a worker's branch → main.
// Returns heap-allocated tm_pr_t. Caller must call tm_pr_free().
tm_pr_t* tm_github_create_pr(
    tm_engine_t*   engine,
    tm_worker_id_t worker_id,
    const char*    title,
    const char*    body
);
void tm_pr_free(tm_pr_t* pr);

// Merge a PR. Strategy defaults to TM_MERGE_SQUASH.
// Commit message format: "[teammux] {worker-name}: {task-description}"
tm_result_t tm_github_merge_pr(
    tm_engine_t*        engine,
    uint64_t            pr_number,
    tm_merge_strategy_t strategy
);

// Get the diff for a worker's branch vs main.
// Returns heap-allocated tm_diff_t. Caller must call tm_diff_free().
tm_diff_t* tm_github_get_diff(tm_engine_t* engine, tm_worker_id_t worker_id);
void       tm_diff_free(tm_diff_t* diff);

// Start gh webhook forward for real-time GitHub events.
// Spawns `gh webhook forward` as a subprocess.
// Falls back to 60s polling if gh not available.
tm_result_t tm_github_webhooks_start(tm_engine_t* engine, tm_github_event_cb callback, void* userdata);
void        tm_github_webhooks_stop(tm_engine_t* engine);

// ─────────────────────────────────────────────────────────
// /teammux-* command interception
// ─────────────────────────────────────────────────────────

// Start watching .teammux/commands/ for command files written by Team Lead.
// On new file: parse JSON, call callback, delete file.
tm_result_t tm_commands_watch(tm_engine_t* engine, tm_command_cb callback, void* userdata);

// ─────────────────────────────────────────────────────────
// Utility
// ─────────────────────────────────────────────────────────

// Resolve agent binary path.
// Tries: which {name} → common install paths → returns NULL if not found.
// Returns heap-allocated string. Caller must call tm_free_string().
const char* tm_agent_resolve(const char* agent_name);
void        tm_free_string(const char* str);

// Returns the Teammux engine version string (e.g. "0.1.0")
const char* tm_version(void);

#ifdef __cplusplus
}
#endif

#endif // TEAMMUX_H
```

---

## Step 5 — Wire engine into the Xcode build

The Swift layer needs to link `libteammux.a` and import `teammux.h`.

### 5.1 Copy built library
Add to `build.sh`:
```bash
echo "[1/3] Building Zig engine..."
cd engine && zig build -Doptimize=ReleaseFast
cp zig-out/lib/libteammux.a ../macos/Resources/libteammux.a
cd ..
```

### 5.2 Xcode linker settings
In the Xcode project (or xcconfig):
- Add `macos/Resources/libteammux.a` to "Link Binary With Libraries"
- Add `engine/include` to "Header Search Paths"
- Add `-lteammux` to "Other Linker Flags"

### 5.3 Create Swift bridge header
Create `macos/Sources/Teammux/Engine/teammux-bridge.h`:
```c
#import "teammux.h"
```

Add to Xcode target's "Objective-C Bridging Header" setting:
`macos/Sources/Teammux/Engine/teammux-bridge.h`

### 5.4 Verify Swift can see the types
Create a minimal `macos/Sources/Teammux/Engine/EngineClient.swift` stub:
```swift
import Foundation

// Stub — fully implemented in Stream 3
// This file exists to confirm the header bridge compiles
class EngineClient {
    static func version() -> String {
        return String(cString: tm_version())
    }
}
```

The build must succeed with `EngineClient.version()` callable.

---

## Step 6 — Write CLAUDE.md

Write `CLAUDE.md` at repo root. This is the living context file for all future Claude Code sessions on this repo.

```markdown
# Teammux

Native macOS application for coordinating teams of AI coding agents.

## Stack
- Swift + SwiftUI + AppKit — UI layer (macos/)
- Zig — coordination engine (engine/) → libteammux.a
- Ghostty fork — terminal rendering (src/ — DO NOT MODIFY)
- C API boundary — engine/include/teammux.h

## Architecture rules
- engine/ contains all coordination logic. Swift calls it via teammux.h only.
- src/ is Ghostty upstream. Never modify files in src/.
- macos/Sources/Teammux/ is the Teammux Swift layer.
- All Swift → Zig calls go through macos/Sources/Teammux/Engine/EngineClient.swift only.
- No direct tm_* calls outside EngineClient.swift.

## Build
./build.sh          — full build (engine + app)
cd engine && zig build   — engine only
xcodebuild ...      — app only (requires libteammux.a in macos/Resources/)

## Key files
- engine/include/teammux.h     — C API contract (source of truth)
- .teammux/config.toml         — project team configuration (per user project)
- CLAUDE.md                    — this file

## Zig version
Pinned to build.zig.zon. Never update independently — sync with Ghostty upstream.

## macOS target
macOS 15 Sequoia, Apple Silicon only.
Bundle: com.teammux.app
```

---

## Step 7 — Write .gitignore

```gitignore
# Zig build outputs
.zig-cache/
zig-out/

# macOS
.DS_Store
*.xcuserstate
xcuserdata/
DerivedData/

# Xcode
*.xcworkspace/xcuserdata/

# Teammux project artifacts (written per user project, not this repo)
.teammux/worker-*/
.teammux/config.local.toml
.teammux/commands/
.teammux/logs/

# Build outputs
macos/Resources/libteammux.a
macos/build/

# Secrets
*.pem
*.key
```

---

## Step 8 — Write build.sh

```bash
#!/bin/bash
set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Teammux build"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "[1/3] Building Zig engine (libteammux)..."
cd engine
zig build -Doptimize=ReleaseFast
cp zig-out/lib/libteammux.a ../macos/Resources/libteammux.a
echo "      → libteammux.a copied to macos/Resources/"
cd ..

echo ""
echo "[2/3] Building Ghostty + Teammux app..."
zig build

echo ""
echo "[3/3] Build complete."
echo "      → App: zig-out/Teammux.app"
echo "      → Launch: open zig-out/Teammux.app"
echo ""
```

```bash
chmod +x build.sh
```

---

## Definition of done — Stream 1

- [ ] `open zig-out/Teammux.app` opens exactly ONE window titled "Teammux"
- [ ] No Ghostty terminal window appears on launch
- [ ] App bundle shows `com.teammux.app` in About
- [ ] `cd engine && zig build` produces `zig-out/lib/libteammux.a` without errors
- [ ] Swift target compiles with `tm_version()` callable — confirms header bridge works
- [ ] `./build.sh` runs without errors end to end
- [ ] `CLAUDE.md` written at repo root
- [ ] `.gitignore` written at repo root
- [ ] `engine/include/teammux.h` committed with all types and function signatures

**Commit message:** `feat: stream 1 — foundation, app identity, engine scaffold, teammux.h`

**Open a PR from `feat/stream1-foundation` into `main`. Do not merge — report back.**
