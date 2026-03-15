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

#define TM_WORKER_TEAM_LEAD 0
#define TM_WORKER_INVALID   UINT32_MAX

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
    TM_ERR_TIMEOUT          = 10,
    TM_ERR_INVALID_WORKER   = 11,
    TM_ERR_UNKNOWN          = 99,
    TM_ERR_NOT_IMPLEMENTED  = 100,
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
    const char*        model;
    const char*        task_description;
    const char*        branch_name;
    const char*        worktree_path;
    tm_worker_status_t status;
    tm_agent_type_t    agent_type;
    const char*        agent_binary;
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
    int32_t            additions;
    int32_t            deletions;
    const char*        patch;
    tm_diff_status_t   status;
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
// Threading: all callbacks are invoked on the engine's internal
// thread. Callers MUST dispatch to the main thread for UI updates.
//
// Lifetime: callbacks remain registered until unsubscribed via the
// returned tm_subscription_t, or until tm_engine_destroy. Callers
// MUST unsubscribe before deallocating userdata.
// -----------------------------------------------------------------

typedef void (*tm_message_cb)(const tm_message_t* message, void* userdata);
typedef void (*tm_roster_changed_cb)(const tm_roster_t* roster, void* userdata);
typedef void (*tm_config_changed_cb)(tm_engine_t* engine, void* userdata);
typedef void (*tm_github_event_cb)(const char* event_type, const char* payload_json, void* userdata);
typedef void (*tm_command_cb)(const char* command, const char* args_json, void* userdata);

// -----------------------------------------------------------------
// Engine lifecycle
// -----------------------------------------------------------------

// Create engine for a project. project_root must be an absolute path to a git repo.
// On success, writes engine to *out and returns TM_OK.
// On failure, returns an error code and *out is set to NULL.
tm_result_t  tm_engine_create(const char* project_root, tm_engine_t** out);

void         tm_engine_destroy(tm_engine_t* engine);
tm_result_t  tm_session_start(tm_engine_t* engine);
void         tm_session_stop(tm_engine_t* engine);

// Get last error message. Valid until next API call on the same engine.
// Safe to call with NULL engine (returns global last error from tm_engine_create).
const char*  tm_engine_last_error(tm_engine_t* engine);

// -----------------------------------------------------------------
// Config
// -----------------------------------------------------------------

tm_result_t      tm_config_reload(tm_engine_t* engine);
tm_subscription_t tm_config_watch(tm_engine_t* engine, tm_config_changed_cb callback, void* userdata);
void             tm_config_unwatch(tm_engine_t* engine, tm_subscription_t sub);

// Get a config value by dot-notation key (e.g. "project.name", "team_lead.model").
// Returns NULL if key not found. Returned pointer is valid until next tm_config_reload.
const char*      tm_config_get(tm_engine_t* engine, const char* key);

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
tm_roster_t*      tm_roster_get(tm_engine_t* engine);
void              tm_roster_free(tm_roster_t* roster);
tm_worker_info_t* tm_worker_get(tm_engine_t* engine, tm_worker_id_t worker_id);
void              tm_worker_info_free(tm_worker_info_t* info);
tm_subscription_t tm_roster_watch(tm_engine_t* engine, tm_roster_changed_cb callback, void* userdata);
void              tm_roster_unwatch(tm_engine_t* engine, tm_subscription_t sub);

// -----------------------------------------------------------------
// PTY interaction
// -----------------------------------------------------------------

tm_result_t tm_pty_send(tm_engine_t* engine, tm_worker_id_t worker_id, const char* text);
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

// Broadcast a message to all active workers. Uses the given message type.
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

tm_diff_t* tm_github_get_diff(tm_engine_t* engine, tm_worker_id_t worker_id);
void       tm_diff_free(tm_diff_t* diff);

tm_result_t tm_github_webhooks_start(tm_engine_t* engine, tm_github_event_cb callback, void* userdata);
void        tm_github_webhooks_stop(tm_engine_t* engine);

// -----------------------------------------------------------------
// /teammux-* command interception
// -----------------------------------------------------------------

tm_subscription_t tm_commands_watch(tm_engine_t* engine, tm_command_cb callback, void* userdata);
void              tm_commands_unwatch(tm_engine_t* engine, tm_subscription_t sub);

// -----------------------------------------------------------------
// Utility
// -----------------------------------------------------------------

const char* tm_agent_resolve(const char* agent_name);
void        tm_free_string(const char* str);
const char* tm_version(void);
const char* tm_result_to_string(tm_result_t result);

#ifdef __cplusplus
}
#endif

#endif // TEAMMUX_H
