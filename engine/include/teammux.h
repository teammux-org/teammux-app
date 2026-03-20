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
    TM_ERR_ROLE             = 13,
    TM_ERR_OWNERSHIP        = 14,
    TM_ERR_CLEANUP_INCOMPLETE = 15,
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
    // 3 and 4 were status_req/status_rpt — removed (no sender or handler)
    TM_MSG_COMPLETION  = 5,
    TM_MSG_ERROR       = 6,
    TM_MSG_BROADCAST   = 7,
    TM_MSG_QUESTION    = 8,
    TM_MSG_DISPATCH       = 10,  // Team Lead dispatches task to worker
    TM_MSG_RESPONSE       = 11,  // Team Lead responds to worker question
    TM_MSG_PEER_QUESTION  = 12,  // Worker-to-worker question via Team Lead relay
    TM_MSG_DELEGATION     = 13,  // Worker-to-worker task delegation direct
    TM_MSG_PR_READY       = 14,  // Engine signals PR created for worker
    TM_MSG_PR_STATUS      = 15,  // GitHub PR status change (open/closed/merged)
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

typedef enum {
    TM_MERGE_PENDING     = 0,
    TM_MERGE_IN_PROGRESS = 1,
    TM_MERGE_SUCCESS     = 2,
    TM_MERGE_CONFLICT    = 3,
    TM_MERGE_REJECTED    = 4,
} tm_merge_status_e;

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

typedef struct {
    const char*        file_path;
    const char*        conflict_type;
    const char*        ours;
    const char*        theirs;
} tm_conflict_t;

// -----------------------------------------------------------------
// Callbacks
//
// All callbacks are invoked on the engine's internal thread.
// Callers must dispatch to the main thread for UI updates.
// -----------------------------------------------------------------

typedef tm_result_t (*tm_message_cb)(const tm_message_t* message, void* userdata);
typedef void (*tm_roster_changed_cb)(const tm_roster_t* roster, void* userdata);
typedef void (*tm_config_changed_cb)(void* userdata);
typedef void (*tm_github_event_cb)(const char* event_type, const char* payload_json, void* userdata);
typedef void (*tm_command_cb)(const char* command, const char* args_json, void* userdata);

// -----------------------------------------------------------------
// Engine lifecycle
// -----------------------------------------------------------------

// Create engine for a project. project_root must be an absolute path to a git repo.
// out must not be NULL. On success, writes engine pointer to *out and returns TM_OK.
// On failure, returns an error code and *out is set to NULL.
// If out is NULL, returns TM_ERR_UNKNOWN immediately.
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
// Returned pointer is valid only until the next call to tm_config_get,
// tm_config_reload, or tm_engine_destroy. Caller must not free.
// Copy the value immediately if it is needed beyond the next tm_config_get call.
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

// -----------------------------------------------------------------
// Worktree lifecycle
//
// Manages git worktree directories for isolated worker environments.
// Default path: ~/.teammux/worktrees/{SHA256(project_path)}/{worker_id}/
// Configurable via config.toml [project] worktree_root key.
// Not thread-safe — all tm_worktree_* calls must be serialized.
// -----------------------------------------------------------------

// Create a git worktree for a worker. task_description is slugified into
// the branch name (teammux/{worker_id}-{slug}). task_description must not
// be NULL. Returns TM_ERR_CONFIG if task_description is NULL, HOME is unset,
// or worktree directory cannot be created. Returns TM_ERR_WORKTREE on git failure.
tm_result_t tm_worktree_create(tm_engine_t* engine,
                                uint32_t worker_id,
                                const char* task_description);

// Remove a worker's git worktree. Runs git worktree remove --force,
// frees registry entry. Idempotent — safe if worker has no worktree.
tm_result_t tm_worktree_remove(tm_engine_t* engine, uint32_t worker_id);

// Get the absolute path to a worker's worktree directory.
// Returns NULL if worker has no worktree registered.
// Returned string is valid until the next call to tm_worktree_path
// or tm_engine_destroy. Caller must not free. Copy if needed long-term.
const char* tm_worktree_path(tm_engine_t* engine, uint32_t worker_id);

// Get the git branch name for a worker's worktree.
// Returns NULL if worker has no worktree registered.
// Returned string is valid until the next call to tm_worktree_branch
// or tm_engine_destroy. Caller must not free. Copy if needed long-term.
const char* tm_worktree_branch(tm_engine_t* engine, uint32_t worker_id);

// Get current roster snapshot. Returns NULL on failure. Caller must call tm_roster_free().
tm_roster_t*      tm_roster_get(tm_engine_t* engine);
void              tm_roster_free(tm_roster_t* roster);

// Get info for a specific worker. Returns NULL if not found. Caller must call tm_worker_info_free().
tm_worker_info_t* tm_worker_get(tm_engine_t* engine, tm_worker_id_t worker_id);
void              tm_worker_info_free(tm_worker_info_t* info);
tm_subscription_t tm_roster_watch(tm_engine_t* engine, tm_roster_changed_cb callback, void* userdata);
void              tm_roster_unwatch(tm_engine_t* engine, tm_subscription_t sub);

// PTY ownership belongs to Ghostty.
// Teammux does not directly manage PTY file descriptors.

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

// Create a PR and route TM_MSG_PR_READY through the bus.
// Alias for tm_github_create_pr — both functions perform bus routing identically.
// The branch parameter is unused; the actual branch is resolved from the worker's
// roster entry. Retained in the signature for forward compatibility.
// Returns heap-allocated tm_pr_t on success, NULL on failure. Caller must call tm_pr_free().
tm_pr_t* tm_pr_create(tm_engine_t* engine, uint32_t worker_id,
                       const char* title, const char* body,
                       const char* branch);

tm_result_t tm_github_merge_pr(
    tm_engine_t*        engine,
    uint64_t            pr_number,
    tm_merge_strategy_t strategy
);

// Get diff for a pull request via GitHub PR files API. Returns NULL on failure.
// Caller must call tm_diff_free().
tm_diff_t* tm_github_get_diff(tm_engine_t* engine, uint64_t pr_number);
void       tm_diff_free(tm_diff_t* diff);

tm_subscription_t tm_github_webhooks_start(tm_engine_t* engine, tm_github_event_cb callback, void* userdata);
void              tm_github_webhooks_stop(tm_engine_t* engine, tm_subscription_t sub);

// -----------------------------------------------------------------
// Merge coordinator
// -----------------------------------------------------------------

// Approve merge of a worker's branch into main. strategy is "merge", "squash", or "rebase".
// Returns TM_OK on clean success, TM_ERR_CLEANUP_INCOMPLETE if merge succeeded but
// worktree/branch removal failed. Check tm_merge_get_status for merge outcome.
// Returns TM_ERR_INVALID_WORKER if worker not found, TM_ERR_WORKTREE if HEAD is not on main.
tm_result_t tm_merge_approve(tm_engine_t* engine, uint32_t worker_id,
                              const char* strategy);

// Reject a worker's merge: abort any in-progress merge, remove worktree, delete branch.
// Worker is dismissed from roster. Returns TM_OK on success,
// TM_ERR_CLEANUP_INCOMPLETE if worktree/branch removal failed.
// Returns TM_ERR_INVALID_WORKER if worker not found.
tm_result_t tm_merge_reject(tm_engine_t* engine, uint32_t worker_id);

// Get current merge status for a worker. Returns TM_MERGE_PENDING if no merge attempted.
tm_merge_status_e tm_merge_get_status(tm_engine_t* engine,
                                       uint32_t worker_id);

// Get list of conflicts for a worker after a conflicted merge.
// Returns NULL if no conflicts. Caller must call tm_merge_conflicts_free().
tm_conflict_t** tm_merge_conflicts_get(tm_engine_t* engine,
                                        uint32_t worker_id,
                                        uint32_t* count);

// Free conflict list returned by tm_merge_conflicts_get.
void tm_merge_conflicts_free(tm_conflict_t** conflicts, uint32_t count);

// -----------------------------------------------------------------
// Coordinator — Team Lead dispatch
// -----------------------------------------------------------------

// Dispatch a task instruction to a specific worker. The instruction is
// routed through the message bus as TM_MSG_DISPATCH and recorded in
// dispatch history. The event is recorded even if bus delivery fails
// (with delivered=false). Returns TM_ERR_INVALID_WORKER if worker not
// found. Returns TM_ERR_BUS if message bus not initialized.
tm_result_t tm_dispatch_task(tm_engine_t* engine,
                              uint32_t target_worker_id,
                              const char* instruction);

// Dispatch a response to a specific worker (e.g. answering a question).
// Routed through the message bus as TM_MSG_RESPONSE and recorded in
// dispatch history. Returns TM_ERR_INVALID_WORKER if worker not found.
// Returns TM_ERR_BUS if message bus not initialized.
tm_result_t tm_dispatch_response(tm_engine_t* engine,
                                  uint32_t target_worker_id,
                                  const char* response);

typedef struct {
    uint32_t    target_worker_id;
    const char* instruction;
    uint64_t    timestamp;
    bool        delivered;
    uint8_t     kind;       // 0 = task dispatch, 1 = response dispatch
} tm_dispatch_event_t;

// Get dispatch history (most recent up to 100 events).
// Returns NULL if no history (*count will be 0).
// Caller must call tm_dispatch_history_free().
tm_dispatch_event_t** tm_dispatch_history(tm_engine_t* engine,
                                           uint32_t* count);
void tm_dispatch_history_free(tm_dispatch_event_t** events,
                               uint32_t count);

// -----------------------------------------------------------------
// /teammux-* command interception
// -----------------------------------------------------------------

tm_subscription_t tm_commands_watch(tm_engine_t* engine, tm_command_cb callback, void* userdata);
void              tm_commands_unwatch(tm_engine_t* engine, tm_subscription_t sub);

// -----------------------------------------------------------------
// Completion + Question signaling
//
// Workers signal completion or ask questions via /teammux-complete
// and /teammux-question command files. The engine routes these
// internally through the message bus (TM_MSG_COMPLETION = 5,
// TM_MSG_QUESTION = 8) to the Team Lead (worker 0).
// -----------------------------------------------------------------

typedef struct {
    uint32_t    worker_id;
    const char* summary;        // brief completion summary
    const char* git_commit;     // HEAD at time of completion (may be null)
    const char* details;        // optional extended details (may be null)
    uint64_t    timestamp;
} tm_completion_t;

typedef struct {
    uint32_t    worker_id;
    const char* question;       // the question text
    const char* context;        // optional context from worker (may be null)
    uint64_t    timestamp;
} tm_question_t;

// Signal worker completion. Creates TM_MSG_COMPLETION message, routes
// through bus to Team Lead (worker 0), persists to JSONL log.
// summary must not be NULL. details may be NULL.
tm_result_t tm_worker_complete(tm_engine_t* engine,
                                uint32_t worker_id,
                                const char* summary,
                                const char* details);

// Signal worker question. Creates TM_MSG_QUESTION message, routes
// through bus to Team Lead (worker 0), persists to JSONL log.
// question must not be NULL. context may be NULL.
tm_result_t tm_worker_question(tm_engine_t* engine,
                                uint32_t worker_id,
                                const char* question,
                                const char* context);

// Free a heap-allocated completion struct.
void tm_completion_free(tm_completion_t* completion);

// Free a heap-allocated question struct.
void tm_question_free(tm_question_t* question);

// -----------------------------------------------------------------
// Peer messaging — worker-to-worker
// -----------------------------------------------------------------

// Send a peer question from one worker to another, routed via Team Lead
// (worker 0). Creates TM_MSG_PEER_QUESTION message, routes through bus
// to Team Lead PTY. Returns TM_ERR_UNKNOWN if engine or message is NULL.
// Returns TM_ERR_INVALID_WORKER if target_id is not in roster or equals
// from_id. Returns TM_ERR_BUS if bus not initialized.
tm_result_t tm_peer_question(tm_engine_t* engine,
                              uint32_t from_id,
                              uint32_t target_id,
                              const char* message);

// Delegate a task directly to a target worker. Creates TM_MSG_DELEGATION
// message, routes through bus directly to target worker PTY.
// Returns TM_ERR_UNKNOWN if engine or task is NULL.
// Returns TM_ERR_INVALID_WORKER if target_id is not in roster or equals
// from_id. Returns TM_ERR_BUS if bus not initialized.
tm_result_t tm_peer_delegate(tm_engine_t* engine,
                              uint32_t from_id,
                              uint32_t target_id,
                              const char* task);

// -----------------------------------------------------------------
// Completion history persistence (TD16)
//
// Persists completion and question events to JSONL file at
// {project_root}/.teammux/logs/completion_history.jsonl.
// Entries are appended on every tm_worker_complete / tm_worker_question
// call and on every /teammux-complete and /teammux-question command file.
// Atomic write via read-rewrite-rename pattern.
// -----------------------------------------------------------------

typedef struct {
    const char* type;           // "completion" or "question"
    uint32_t    worker_id;
    const char* role_id;        // empty string if unknown at engine layer
    const char* content;        // summary (completion) or question text
    const char* git_commit;     // HEAD at event time, may be NULL
    uint64_t    timestamp;
} tm_history_entry_t;

// Load all history entries from the JSONL file.
// Returns heap-allocated array. Returns NULL if no entries or error
// (*count will be 0). Malformed lines are skipped silently.
// Caller must call tm_history_free().
tm_history_entry_t** tm_history_load(tm_engine_t* engine, uint32_t* count);

// Free entries returned by tm_history_load.
void tm_history_free(tm_history_entry_t** entries, uint32_t count);

// Clear all history entries (truncates the JSONL file to zero length).
// Missing file is a no-op (returns TM_OK).
tm_result_t tm_history_clear(tm_engine_t* engine);

// Manually trigger history log rotation (TD24).
// Rotates completion_history.jsonl → .1, .1 → .2, discards old .2.
// Flushes async queue before rotating. Returns TM_OK on success.
tm_result_t tm_history_rotate(tm_engine_t* engine);

// -----------------------------------------------------------------
// Utility
// -----------------------------------------------------------------

// Resolve agent binary path. Returns NULL if not found.
// Returns heap-allocated string. Caller must call tm_free_string().
const char* tm_agent_resolve(const char* agent_name);
void        tm_free_string(const char* str);
const char* tm_version(void);
const char* tm_result_to_string(tm_result_t result);

// -----------------------------------------------------------------
// Role definitions
// -----------------------------------------------------------------

typedef struct {
    const char*  id;
    const char*  name;
    const char*  division;
    const char*  emoji;
    const char*  description;
    const char** write_patterns;
    uint32_t     write_pattern_count;
    const char** deny_write_patterns;
    uint32_t     deny_write_pattern_count;
    bool         can_push;
    bool         can_merge;
} tm_role_t;

// Resolve a role by ID. On success, writes a heap-allocated tm_role_t to *out_role.
// Caller must call tm_role_free(). Returns TM_ERR_ROLE if role_id is NULL, not found
// in any search path, or the role file fails to parse. All string fields in a
// successfully resolved tm_role_t are non-NULL (may be empty strings).
tm_result_t  tm_role_resolve(tm_engine_t* engine, const char* role_id, tm_role_t** out_role);
void         tm_role_free(tm_role_t* role);

// List all available roles from all search paths (project-local, user, bundled).
// Returns heap-allocated array. Returns NULL if no roles found or engine is NULL
// (*count will be 0 in both cases). Caller must call tm_roles_list_free().
tm_role_t**  tm_roles_list(tm_engine_t* engine, uint32_t* count);
void         tm_roles_list_free(tm_role_t** roles, uint32_t count);

// List all available roles without an active engine session.
// Searches project-local (.teammux/roles/), user (~/.teammux/roles/),
// app bundle, and dev-build paths (same order as tm_roles_list).
// Pass NULL for project_root to skip project-local path.
// Returns NULL if no roles found (if count is non-NULL, *count will be 0).
// If count is NULL, always returns NULL.
// Caller must call tm_roles_list_bundled_free().
tm_role_t**  tm_roles_list_bundled(const char* project_root, uint32_t* count);
void         tm_roles_list_bundled_free(tm_role_t** roles, uint32_t count);

// -----------------------------------------------------------------
// File ownership
// -----------------------------------------------------------------

typedef struct {
    const char* path_pattern;
    uint32_t    worker_id;
    bool        allow_write;
} tm_ownership_entry_t;

// Check whether a worker is allowed to write to file_path.
// Writes result to *out_allowed. Returns TM_OK on success.
// When no rules are registered for worker_id, *out_allowed is true (default allow).
// Deny patterns take precedence over write patterns.
tm_result_t tm_ownership_check(tm_engine_t* engine,
                                uint32_t worker_id,
                                const char* file_path,
                                bool* out_allowed);

// Register a path pattern for a worker. allow_write=true for write grants,
// false for deny_write. Call multiple times to add multiple patterns.
tm_result_t tm_ownership_register(tm_engine_t* engine,
                                   uint32_t worker_id,
                                   const char* path_pattern,
                                   bool allow_write);

// Release all ownership rules for a worker. Idempotent.
// Called automatically by tm_worker_dismiss and tm_merge_reject.
tm_result_t tm_ownership_release(tm_engine_t* engine,
                                  uint32_t worker_id);

// Get all ownership entries for a worker. Returns heap-allocated array.
// Returns NULL if no rules registered (*count will be 0).
// Caller must call tm_ownership_free().
tm_ownership_entry_t** tm_ownership_get(tm_engine_t* engine,
                                         uint32_t worker_id,
                                         uint32_t* count);

// Free entries returned by tm_ownership_get.
void tm_ownership_free(tm_ownership_entry_t** entries, uint32_t count);

// Replace all ownership rules for a worker in a single locked swap.
// On allocation failure, old rules are preserved unchanged. Does NOT
// reinstall the interceptor — callers must call tm_interceptor_install
// separately if needed. Provides C API access to the same operation
// that hot-reload performs internally via the Zig struct directly.
tm_result_t tm_ownership_update(tm_engine_t* engine,
                                  uint32_t worker_id,
                                  const char** write_patterns, uint32_t write_count,
                                  const char** deny_patterns, uint32_t deny_count);

// -----------------------------------------------------------------
// Git interceptor
// -----------------------------------------------------------------

// Install a git wrapper script into the worker's worktree that intercepts
// `git add` and blocks files matching deny patterns. Reads deny and write
// patterns from rules previously registered via tm_ownership_register().
// If no deny patterns are registered, installs a pass-through wrapper.
// Returns TM_ERR_WORKTREE if pattern contains shell metacharacters or
// git binary cannot be found on PATH.
tm_result_t tm_interceptor_install(tm_engine_t* engine, uint32_t worker_id);

// Remove the git wrapper script from the worker's worktree.
// The interceptor is automatically cleaned up by tm_worker_dismiss and
// tm_merge_reject. This function is available for explicit removal.
// Idempotent — safe to call even if no interceptor was installed.
tm_result_t tm_interceptor_remove(tm_engine_t* engine, uint32_t worker_id);

// Get the absolute path to the interceptor directory for a worker.
// Returns NULL if no interceptor is installed or worker not found.
// Caller prepends this path to PATH when launching the worker's PTY.
// Returned string must be freed with tm_free_string().
const char* tm_interceptor_path(tm_engine_t* engine, uint32_t worker_id);

// -----------------------------------------------------------------
// Role hot-reload
// -----------------------------------------------------------------

// Callback fired when a watched role TOML file changes.
// new_claude_md is the regenerated CLAUDE.md content, or NULL if the role
// file failed to parse (syntax error, unreadable, etc.).
// reload_seq is a monotonically increasing counter per worker, incremented
// on every file-change event (including parse failures). Callers can use
// this to detect rapid repeated saves within the same notification window.
//
// THREADING: Invoked on a per-watcher background thread (NOT the engine's
// internal thread). Callbacks for different workers may fire concurrently.
// Caller must dispatch to the main thread for UI updates and must not
// call back into tm_role_watch/tm_role_unwatch from within the callback.
//
// Memory ownership: allocated by the watcher, freed immediately after
// callback returns. Pointer is valid only for the duration of this call.
// Caller must copy if the content is needed beyond callback scope.
typedef void (*tm_role_changed_cb)(uint32_t worker_id,
                                    const char* new_claude_md,
                                    uint64_t reload_seq,
                                    void* userdata);

// Start watching the role TOML file for a worker. When the file changes
// (write, rename, delete+recreate, attribute change), the engine re-parses
// the role definition, regenerates CLAUDE.md, and fires the callback with
// the new content.
// role_id is resolved to a file path via the standard search order.
// callback and role_id must not be NULL; returns TM_ERR_ROLE if either is NULL.
// Returns TM_ERR_ROLE if role_id cannot be resolved.
// Returns TM_ERR_INVALID_WORKER if worker_id is not in the roster.
tm_result_t tm_role_watch(tm_engine_t* engine,
                           uint32_t worker_id,
                           const char* role_id,
                           tm_role_changed_cb callback,
                           void* userdata);

// Stop watching the role file for a worker. Idempotent — safe to call
// even if no watcher was registered. Called automatically by tm_worker_dismiss.
tm_result_t tm_role_unwatch(tm_engine_t* engine,
                             uint32_t worker_id);

#ifdef __cplusplus
}
#endif

#endif // TEAMMUX_H
