#ifndef TEAMMUX_H
#define TEAMMUX_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// -----------------------------------------------------------------
// Types
// -----------------------------------------------------------------

typedef struct tm_engine tm_engine_t;
typedef uint32_t tm_worker_id_t;
typedef uint32_t tm_subscription_t;

#define TM_WORKER_TEAM_LEAD      0
#define TM_WORKER_INVALID        UINT32_MAX
#define TM_SUBSCRIPTION_INVALID  0

typedef enum {
    TM_OK                   = 0,
    TM_ERR_NOT_GIT          = 1,
    TM_ERR_NO_GH            = 2,
    TM_ERR_GH_UNAUTH        = 3,
    TM_ERR_NO_AGENT         = 4,
    TM_ERR_WORKTREE         = 5,
    TM_ERR_PTY              = 6,
    TM_ERR_CONFIG           = 7,
    TM_ERR_BUS              = 8,
    TM_ERR_GITHUB           = 9,
    TM_ERR_NOT_IMPLEMENTED  = 10,
    TM_ERR_TIMEOUT          = 11,
    TM_ERR_INVALID_WORKER   = 12,
    TM_ERR_UNKNOWN          = 99,
} tm_result_t;

typedef enum {
    TM_WORKER_STATUS_IDLE      = 0,
    TM_WORKER_STATUS_WORKING   = 1,
    TM_WORKER_STATUS_COMPLETE  = 2,
    TM_WORKER_STATUS_BLOCKED   = 3,
    TM_WORKER_STATUS_ERROR     = 4,
} tm_worker_status_t;

typedef enum {
    TM_AGENT_CLAUDE_CODE = 0,
    TM_AGENT_CODEX_CLI   = 1,
    TM_AGENT_CUSTOM      = 99,
} tm_agent_type_t;

typedef enum {
    TM_MSG_TASK        = 0,
    TM_MSG_INSTRUCTION = 1,
    TM_MSG_CONTEXT     = 2,
    TM_MSG_STATUS_REQ  = 3,
    TM_MSG_STATUS_RPT  = 4,
    TM_MSG_COMPLETION  = 5,
    TM_MSG_ERROR       = 6,
    TM_MSG_BROADCAST   = 7,
} tm_message_type_t;

typedef enum {
    TM_MERGE_SQUASH = 0,
    TM_MERGE_REBASE = 1,
    TM_MERGE_MERGE  = 2,
} tm_merge_strategy_t;

typedef enum {
    TM_PR_OPEN   = 0,
    TM_PR_CLOSED = 1,
    TM_PR_MERGED = 2,
} tm_pr_state_t;

typedef enum {
    TM_DIFF_ADDED    = 0,
    TM_DIFF_MODIFIED = 1,
    TM_DIFF_DELETED  = 2,
    TM_DIFF_RENAMED  = 3,
} tm_diff_status_t;

typedef struct {
    tm_worker_id_t     id;
    const char*        name;
    const char*        task_description;
    const char*        branch_name;
    const char*        worktree_path;
    tm_worker_status_t status;
    tm_agent_type_t    agent_type;
    const char*        agent_binary;
    const char*        model;
    uint64_t           spawned_at;
} tm_worker_info_t;

typedef struct {
    const tm_worker_info_t* workers;
    uint32_t                count;
} tm_roster_t;

typedef struct {
    tm_worker_id_t     from;
    tm_worker_id_t     to;
    tm_message_type_t  type;
    const char*        payload;
    uint64_t           timestamp;
    uint64_t           seq;
    const char*        git_commit;
} tm_message_t;

typedef struct {
    uint64_t           pr_number;
    const char*        pr_url;
    const char*        title;
    tm_pr_state_t      state;
    const char*        diff_url;
    tm_worker_id_t     worker_id;
} tm_pr_t;

typedef struct {
    const char*        file_path;
    tm_diff_status_t   status;
    int32_t            additions;
    int32_t            deletions;
    const char*        patch;
} tm_diff_file_t;

typedef struct {
    tm_diff_file_t*    files;
    uint32_t           count;
    int32_t            total_additions;
    int32_t            total_deletions;
} tm_diff_t;

// -----------------------------------------------------------------
// Callbacks
//
// All callbacks are invoked on the engine's internal thread.
// Callers must dispatch to the main thread for UI updates.
// -----------------------------------------------------------------

typedef void (*tm_message_cb)(const tm_message_t* message, void* userdata);
typedef void (*tm_roster_changed_cb)(const tm_roster_t* roster, void* userdata);
typedef void (*tm_config_changed_cb)(void* userdata);
typedef void (*tm_github_event_cb)(const char* event_type, const char* payload_json, void* userdata);
typedef void (*tm_command_cb)(const char* command, const char* args_json, void* userdata);

// -----------------------------------------------------------------
// Engine lifecycle
// -----------------------------------------------------------------

// Create engine for a project. project_root must be an absolute path to a git repo.
// On success, writes engine pointer to *out and returns TM_OK.
// On failure, returns an error code and *out is set to NULL.
tm_result_t  tm_engine_create(const char* project_root, tm_engine_t** out);
void         tm_engine_destroy(tm_engine_t* engine);
tm_result_t  tm_session_start(tm_engine_t* engine);
void         tm_session_stop(tm_engine_t* engine);

// Get last error message. Valid until next API call on the same engine.
// Can be called with NULL engine to get the last creation error.
const char*  tm_engine_last_error(tm_engine_t* engine);

// -----------------------------------------------------------------
// Config
// -----------------------------------------------------------------

tm_result_t      tm_config_reload(tm_engine_t* engine);
// Returns TM_SUBSCRIPTION_INVALID (0) on failure.
tm_subscription_t tm_config_watch(tm_engine_t* engine, tm_config_changed_cb callback, void* userdata);
void              tm_config_unwatch(tm_engine_t* engine, tm_subscription_t sub);

// Get a config value by dot-notation key. Returns NULL if not found.
// Returned pointer is valid until the next tm_config_reload. Caller must not free.
const char* tm_config_get(tm_engine_t* engine, const char* key);

// -----------------------------------------------------------------
// Worktree and worker lifecycle
// -----------------------------------------------------------------

// Spawn a new worker. Returns worker ID on success, TM_WORKER_INVALID on failure.
tm_worker_id_t tm_worker_spawn(
    tm_engine_t*    engine,
    const char*     agent_binary,
    tm_agent_type_t agent_type,
    const char*     worker_name,
    const char*     task_description
);

tm_result_t       tm_worker_dismiss(tm_engine_t* engine, tm_worker_id_t worker_id);

// Get current roster snapshot. Returns NULL on failure. Caller must call tm_roster_free().
tm_roster_t*      tm_roster_get(tm_engine_t* engine);
void              tm_roster_free(tm_roster_t* roster);

// Get info for a specific worker. Returns NULL if not found. Caller must call tm_worker_info_free().
tm_worker_info_t* tm_worker_get(tm_engine_t* engine, tm_worker_id_t worker_id);
void              tm_worker_info_free(tm_worker_info_t* info);
tm_subscription_t tm_roster_watch(tm_engine_t* engine, tm_roster_changed_cb callback, void* userdata);
void              tm_roster_unwatch(tm_engine_t* engine, tm_subscription_t sub);

// -----------------------------------------------------------------
// PTY interaction
// -----------------------------------------------------------------

tm_result_t tm_pty_send(tm_engine_t* engine, tm_worker_id_t worker_id, const char* text);

// Get the PTY file descriptor for a worker (used by Ghostty SurfaceView).
// Returns -1 on failure or if worker not found.
int         tm_pty_fd(tm_engine_t* engine, tm_worker_id_t worker_id);

// -----------------------------------------------------------------
// Message bus
// -----------------------------------------------------------------

tm_result_t tm_message_send(
    tm_engine_t*      engine,
    tm_worker_id_t    target_worker_id,
    tm_message_type_t type,
    const char*       payload
);

tm_result_t tm_message_broadcast(
    tm_engine_t*      engine,
    tm_message_type_t type,
    const char*       payload
);

tm_subscription_t tm_message_subscribe(tm_engine_t* engine, tm_message_cb callback, void* userdata);
void              tm_message_unsubscribe(tm_engine_t* engine, tm_subscription_t sub);

// -----------------------------------------------------------------
// GitHub integration
// -----------------------------------------------------------------

tm_result_t tm_github_auth(tm_engine_t* engine);
bool        tm_github_is_authed(tm_engine_t* engine);

// Create a GitHub PR. Returns heap-allocated tm_pr_t on success, NULL on failure.
// Caller must call tm_pr_free().
tm_pr_t* tm_github_create_pr(
    tm_engine_t*   engine,
    tm_worker_id_t worker_id,
    const char*    title,
    const char*    body
);
void tm_pr_free(tm_pr_t* pr);

tm_result_t tm_github_merge_pr(
    tm_engine_t*        engine,
    uint64_t            pr_number,
    tm_merge_strategy_t strategy
);

// Get diff for a worker's branch vs main. Returns NULL on failure.
// Caller must call tm_diff_free().
tm_diff_t* tm_github_get_diff(tm_engine_t* engine, tm_worker_id_t worker_id);
void       tm_diff_free(tm_diff_t* diff);

tm_subscription_t tm_github_webhooks_start(tm_engine_t* engine, tm_github_event_cb callback, void* userdata);
void              tm_github_webhooks_stop(tm_engine_t* engine, tm_subscription_t sub);

// -----------------------------------------------------------------
// /teammux-* command interception
// -----------------------------------------------------------------

tm_subscription_t tm_commands_watch(tm_engine_t* engine, tm_command_cb callback, void* userdata);
void              tm_commands_unwatch(tm_engine_t* engine, tm_subscription_t sub);

// -----------------------------------------------------------------
// Utility
// -----------------------------------------------------------------

// Resolve agent binary path. Returns NULL if not found.
// Returns heap-allocated string. Caller must call tm_free_string().
const char* tm_agent_resolve(const char* agent_name);
void        tm_free_string(const char* str);
const char* tm_version(void);

// tm_result_to_string — converts tm_result_t to human-readable string.
// Will be implemented in Stream 2.

#ifdef __cplusplus
}
#endif

#endif // TEAMMUX_H
