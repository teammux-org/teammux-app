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
