# Teammux — v0.1.4 Sprint Master Spec

**Version:** v0.1.4
**Built on:** v0.1.3 (tagged, shipped)
**Date:** March 2026

---

## 1. Sprint Overview

- **Goal:** Git worktree isolation, fully autonomous Team Lead, persistent sessions, PR lifecycle end-to-end, worker-to-worker messaging, CLAUDE.md context viewer
- **Session structure:** 16 parallel streams + 1 main thread orchestrator
- **Merge order:** T1-T7 (Wave 1, parallel) → T8-T12 (Wave 2, parallel per dependency) → T13-T15 (Wave 3, parallel) → T16 (last)
- **Status:** COMPLETE — all 16 streams merged, v0.1.4 tagged
- **Shipped:** March 2026

---

## 2. Stream Map

| Stream | Worktree              | Branch                                  | Owns                                                | Depends on     | Merges after      |
|--------|-----------------------|-----------------------------------------|-----------------------------------------------------|----------------|-------------------|
| T1     | ../teammux-stream-t1  | feat/v014-t1-worktree-lifecycle         | worktree_lifecycle.zig, C API, config.toml support  | nothing        | Wave 1            |
| T2     | ../teammux-stream-t2  | feat/v014-t2-peer-messaging             | TD15: /teammux-ask relay + /teammux-delegate direct | nothing        | Wave 1            |
| T3     | ../teammux-stream-t3  | feat/v014-t3-interceptor-hardening      | TD19+TD17+push-to-main, exit 126 enforcement        | nothing        | Wave 1            |
| T4     | ../teammux-stream-t4  | feat/v014-t4-hotreload-registry         | TD18: ownership sync + interceptor update           | nothing        | Wave 1            |
| T5     | ../teammux-stream-t5  | feat/v014-t5-history-persistence        | TD16: history.zig, JSONL, C API                     | nothing        | Wave 1            |
| T6     | ../teammux-stream-t6  | feat/v014-t6-lasterror-fix              | TD20: EngineError, lastError clear-at-entry         | nothing        | Wave 1            |
| T7     | ../teammux-stream-t7  | feat/v014-t7-pr-workflow-engine         | /teammux-pr-ready, gh pr create, TM_MSG_PR_READY=14 | nothing        | Wave 1            |
| T8     | ../teammux-stream-t8  | feat/v014-t8-worktree-bridge            | worktree Swift bridge, spawnWorker cwd, branch badge| T1 merged      | after T1          |
| T9     | ../teammux-stream-t9  | feat/v014-t9-peer-bridge                | PeerQuestion + PeerDelegation Swift types, feed     | T2 merged      | after T2          |
| T10    | ../teammux-stream-t10 | feat/v014-t10-history-bridge            | tm_history_load, completionHistory, feed section    | T5 merged      | after T5          |
| T11    | ../teammux-stream-t11 | feat/v014-t11-pr-bridge                 | PREvent Swift types, GitView PR section             | T7 merged      | after T7          |
| T12    | ../teammux-stream-t12 | feat/v014-t12-session-persistence       | SessionState.swift, save/restore, SetupView card    | T8 merged      | after T8          |
| T13    | ../teammux-stream-t13 | feat/v014-t13-context-viewer            | Context sixth tab, ContextView, diff highlight      | T8 merged      | after T8          |
| T14    | ../teammux-stream-t14 | feat/v014-t14-autonomous-dispatch       | fully autonomous Team Lead heuristic dispatch       | T9+T10 merged  | after T9+T10      |
| T15    | ../teammux-stream-t15 | feat/v014-t15-worker-drawer             | WorkerDetailDrawer, branch badge extend, PR status  | T8+T11 merged  | after T8+T11      |
| T16    | ../teammux-stream-t16 | feat/v014-t16-polish                    | integration tests, docs, v0.1.4 shipped             | T13+T14+T15    | last              |

---

## 3. Message Type Registry (v0.1.4 additions)

Existing types (do not reuse):
- TM_MSG_TASK=0, TM_MSG_INSTRUCTION=1, TM_MSG_CONTEXT=2, TM_MSG_STATUS_REQ=3
- TM_MSG_STATUS_RPT=4, TM_MSG_COMPLETION=5, TM_MSG_ERROR=6, TM_MSG_BROADCAST=7
- TM_MSG_QUESTION=8, TM_MSG_DISPATCH=10, TM_MSG_RESPONSE=11

New in v0.1.4:
- TM_MSG_PEER_QUESTION = 12   (T2 — worker-to-worker question via Team Lead relay)
- TM_MSG_DELEGATION    = 13   (T2 — worker-to-worker task delegation direct)
- TM_MSG_PR_READY      = 14   (T7 — worker signals PR created)
- TM_MSG_PR_STATUS     = 15   (T7 — GitHub webhook PR status change)

---

## 4. Detailed Scope Per Stream

### stream-T1 — Worktree Lifecycle Engine

**Files:** engine/src/worktree_lifecycle.zig (new), engine/include/teammux.h, engine/src/main.zig

**Worktree root resolution:**
1. Check config.toml for `worktree_root = "/custom/path"` key
2. Default: `~/.teammux/worktrees/{SHA256(project_path)}/{worker_id}/`

**C API:**
```c
tm_result_t tm_worktree_create(tm_engine_t* engine,
                                uint32_t worker_id,
                                const char* task_description);
tm_result_t tm_worktree_remove(tm_engine_t* engine, uint32_t worker_id);
const char* tm_worktree_path(tm_engine_t* engine, uint32_t worker_id);
const char* tm_worktree_branch(tm_engine_t* engine, uint32_t worker_id);
```

**Branch naming:** slugify task_description — lowercase, spaces→hyphens, strip non-alphanum, truncate 40 chars, prefix `teammux/`.

**WorktreeRegistry struct:** AutoHashMap(WorkerId, WorktreeEntry) where WorktreeEntry has path and branch as owned strings.

**tm_worktree_create sequence:**
1. Read worktree_root from config or use default
2. mkdir -p {worktree_root}/
3. git worktree add {path} -b {branch} via std.process.Child
4. Store in WorktreeRegistry

**Engine integration:** tm_worker_spawn calls tm_worktree_create first. tm_worker_dismiss calls tm_worktree_remove after.

**Tests:** create/path/branch/remove lifecycle, slugify edge cases, config.toml override, git not found graceful error, worktree already exists handled.

**Done when:**
- zig build test all pass
- tm_worktree_create creates real git worktree on disk
- tm_worktree_path returns correct absolute path
- tm_worktree_branch returns slugified branch name
- config.toml worktree_root override works
- PR raised from feat/v014-t1-worktree-lifecycle

---

### stream-T2 — TD15: Worker-to-Worker Dual-Mode Messaging

**Files:** engine/src/commands.zig, engine/include/teammux.h, engine/src/main.zig, engine/src/bus.zig

**Two new commands:**

`/teammux-ask` (question via Team Lead relay):
- JSON: {"target_worker_id": N, "message": "..."}
- Routes to Team Lead PTY: \n[Teammux] worker-{from} → worker-{target}: {message}\n
- New type: TM_MSG_PEER_QUESTION = 12
- C API: tm_peer_question(engine, from_id, target_id, message)

`/teammux-delegate` (task delegation direct):
- JSON: {"target_worker_id": N, "task": "..."}
- Routes directly to target worker PTY: \n[Teammux] delegated task: {task}\n
- New type: TM_MSG_DELEGATION = 13
- C API: tm_peer_delegate(engine, from_id, target_id, task)

Both use command routing wrapper in main.zig (S5 pattern). Both new types added to bus.zig MessageType enum.

**Tests:** /teammux-ask routes to Team Lead PTY (not target), /teammux-delegate routes to target worker PTY (not Team Lead), invalid target_worker_id returns error, null safety.

**Done when:**
- zig build test all pass
- /teammux-ask message appears in Team Lead PTY only
- /teammux-delegate message appears in target worker PTY only
- PR raised from feat/v014-t2-peer-messaging

---

### stream-T3 — TD19 + TD17 + Push-to-Main Interceptor Hardening

**Files:** engine/src/interceptor.zig only

**Three additions to bash wrapper template:**

TD19 — exit 126: Change `exit 1` to `exit 126` in ALL enforcement blocks (add block, commit -a block). Both blocks updated.

TD17 — stash/apply interception: New block after commit block:
```bash
elif [[ "$subcmd" == "stash" ]]; then
  for arg in "$@"; do
    case "$arg" in
      pop|apply)
        if [[ ${#DENY_PATTERNS[@]} -gt 0 ]]; then
          echo "[Teammux] Cannot $arg stash with write restrictions."
          echo "[Teammux] Your write scope: $WRITE_SCOPE"
          exit 126
        fi
        ;;
    esac
  done
elif [[ "$subcmd" == "apply" ]]; then
  if [[ ${#DENY_PATTERNS[@]} -gt 0 ]]; then
    echo "[Teammux] Cannot git apply with write restrictions."
    echo "[Teammux] Your write scope: $WRITE_SCOPE"
    exit 126
  fi
fi
```

Push-to-main block: New block detecting git push targeting main:
```bash
elif [[ "$subcmd" == "push" ]]; then
  for arg in "$@"; do
    case "$arg" in
      main|master)
        echo "[Teammux] Cannot push directly to main."
        echo "[Teammux] Use /teammux-pr-ready to signal task completion."
        exit 126
        ;;
    esac
  done
fi
```
git push origin teammux/* passes through. Bare git push with no remote/branch passes through (tracking branch safety deferred).

**Tests:** exit 126 on add enforcement, exit 126 on commit -a enforcement, git stash pop blocked, git stash apply blocked, git apply blocked, git push main blocked, git push origin teammux/worker-2 passes, git stash push passes.

**Done when:**
- zig build test all pass, all new tests present
- All enforcement blocks use exit 126
- stash/apply/push-main blocked correctly
- PR raised from feat/v014-t3-interceptor-hardening

---

### stream-T4 — TD18: Hot-Reload Updates Ownership Registry

**Files:** engine/src/hotreload.zig, engine/src/ownership.zig, engine/include/teammux.h, engine/src/main.zig

**New ownership.zig function:**
```zig
pub fn updateWorkerRules(self: *OwnershipRegistry,
    allocator: std.mem.Allocator,
    worker_id: WorkerId,
    write_patterns: []const []const u8,
    deny_patterns: []const []const u8) !void
```
Atomically replaces all rules for that worker — removes old entries, inserts new ones.

**hotreload.zig callback extension:** After generateRoleClaude succeeds, re-parse the updated role TOML with parseRoleDefinition, call ownership.updateWorkerRules with new patterns, then call tm_interceptor_install with new deny patterns to update the bash wrapper. Registry and PTY enforcement updated atomically.

**New C API:**
```c
tm_result_t tm_ownership_update(tm_engine_t* engine,
                                  uint32_t worker_id,
                                  const char** write_patterns, uint32_t write_count,
                                  const char** deny_patterns, uint32_t deny_count);
```

**Tests:** registry reflects updated deny patterns after mock hot-reload, old patterns removed, new interceptor wrapper contains new patterns, registry and wrapper consistent, failed parse does not corrupt registry.

**Done when:**
- zig build test all pass
- ownership registry updated atomically on hot-reload
- interceptor wrapper regenerated with new deny patterns
- PR raised from feat/v014-t4-hotreload-registry

---

### stream-T5 — TD16: Completion History JSONL Persistence

**Files:** engine/src/history.zig (new), engine/include/teammux.h, engine/src/main.zig, engine/src/commands.zig

**File path:** {project_root}/.teammux/logs/completion_history.jsonl

**HistoryLogger:** append-only writer. Atomic write via temp-file-and-rename. Directory created at engine init if missing.

**Entry format:**
```json
{"type":"completion","worker_id":2,"role_id":"frontend-engineer","summary":"Implemented JWT auth","git_commit":"abc1234","timestamp":1234567890}
{"type":"question","worker_id":3,"role_id":"backend-engineer","question":"Should I use JWT?","timestamp":1234567891}
```

HistoryLogger hooked into commands.zig routing — appends on every /teammux-complete and /teammux-question processed.

**C API:**
```c
typedef struct {
    const char* type;
    uint32_t    worker_id;
    const char* role_id;
    const char* content;
    const char* git_commit;
    uint64_t    timestamp;
} tm_history_entry_t;

tm_history_entry_t** tm_history_load(tm_engine_t* engine, uint32_t* count);
void                 tm_history_free(tm_history_entry_t** entries, uint32_t count);
tm_result_t          tm_history_clear(tm_engine_t* engine);
```

**Tests:** append completion, append question, load round-trip, clear truncates, atomic write (temp rename), missing file handled, malformed line skipped.

**Done when:**
- zig build test all pass
- completion_history.jsonl written on /teammux-complete and /teammux-question
- tm_history_load returns all entries correctly
- PR raised from feat/v014-t5-history-persistence

---

### stream-T6 — TD20: EngineClient lastError Refactor

**Files:** macos/Sources/Teammux/Models/EngineError.swift (new), macos/Sources/Teammux/Engine/EngineClient.swift, macos/Sources/Teammux/RightPane/DispatchView.swift, macos/Sources/Teammux/RightPane/GitView.swift, macos/Sources/Teammux/RightPane/QuestionCardView.swift

**New EngineError.swift:**
```swift
enum EngineError: LocalizedError {
    case engineNotStarted
    case workerNotFound(UInt32)
    case dispatchFailed(String)
    case mergeFailed(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .engineNotStarted: return "Engine not started"
        case .workerNotFound(let id): return "Worker \(id) not found"
        case .dispatchFailed(let msg): return "Dispatch failed: \(msg)"
        case .mergeFailed(let msg): return "Merge failed: \(msg)"
        case .unknown(let msg): return msg
        }
    }
}
```

**EngineClient fix:** At entry of every method that sets lastError, add `self.lastError = nil`. Guarantees lastError is always fresh. Bool return type preserved — no method signature changes.

**View fixes:** DispatchView DispatchWorkerRow, GitView, QuestionCardView — add @State private var operationError: String? cleared at operation start. Read engine.lastError immediately after the call returns false and store locally. Do NOT rely on reading lastError after any async boundary.

**Tests:** operationError cleared on retry, stale error from previous call does not persist, multiple rapid calls each see fresh lastError.

**Done when:**
- ./build.sh passes
- All methods that set lastError clear it at entry
- View local error states cleared correctly on retry
- PR raised from feat/v014-t6-lasterror-fix

---

### stream-T7 — PR Creation Workflow Engine

**Files:** engine/src/commands.zig, engine/src/github.zig, engine/include/teammux.h, engine/src/main.zig

**New command `/teammux-pr-ready`:**
JSON: {"title": "...", "summary": "...", "branch": "teammux/worker-2-auth"}

Engine action:
1. Parse command file
2. Call: gh pr create --base main --head {branch} --title "{title}" --body "{summary}" --json url
3. Parse JSON stdout for url field
4. Route TM_MSG_PR_READY=14 through bus with payload: {"worker_id": N, "pr_url": "...", "branch": "...", "title": "..."}

On gh failure: route TM_MSG_ERROR with failure message.

**github.zig extension:** Existing webhook polling extended to detect PR status changes on teammux/* branches. On open/merged/closed status change: route TM_MSG_PR_STATUS=15 with payload: {"pr_url": "...", "status": "merged"|"closed"|"open", "worker_id": N}.

**New C API:**
```c
tm_result_t tm_pr_create(tm_engine_t* engine,
                          uint32_t worker_id,
                          const char* title,
                          const char* body,
                          const char* branch);
```

**Tests:** command file parsed correctly, gh args formatted correctly (mocked), PR URL extracted from JSON, bus routing with correct message type, webhook status change detected.

**Done when:**
- zig build test all pass
- /teammux-pr-ready triggers gh pr create (mocked in tests)
- PR URL appears in bus message payload
- Webhook PR status changes route TM_MSG_PR_STATUS
- PR raised from feat/v014-t7-pr-workflow-engine

---

### stream-T8 — Worktree Lifecycle Swift Bridge

**WAIT CHECK:** Confirm T1 merged:
```
git pull origin main
grep 'tm_worktree_create\|tm_worktree_path\|tm_worktree_branch' \
  engine/include/teammux.h
```

**Files:** macos/Sources/Teammux/Engine/EngineClient.swift, macos/Sources/Teammux/Workspace/WorkerRow.swift

**EngineClient additions (MARK: - Worktree Lifecycle):**
```swift
@Published var workerWorktrees: [UInt32: String] = [:]
@Published var workerBranches: [UInt32: String] = [:]
```

spawnWorker: call tm_worktree_create before tm_worker_spawn. Pass worktree path to SurfaceConfiguration.workingDirectory. On failure: log warning, spawn continues in project root (graceful degradation). Cache path and branch.

dismissWorker: call tm_worktree_remove after PTY closes. Remove from both dicts.

destroy(): removeAll() on both dicts.

**WorkerRow branch badge:** Below task description text:
```swift
if let branch = engine.workerBranches[worker.id] {
    Text(branch)
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .onTapGesture { NSPasteboard.general.setString(branch, forType: .string) }
}
```

**Done when:**
- ./build.sh passes
- spawnWorker calls tm_worktree_create, PTY cwd set to worktree
- dismissWorker calls tm_worktree_remove
- Branch badge visible in WorkerRow
- PR raised from feat/v014-t8-worktree-bridge

---

### stream-T9 — TD15 Swift Bridge: Peer Messaging

**WAIT CHECK:** Confirm T2 merged:
```
grep 'TM_MSG_PEER_QUESTION\|TM_MSG_DELEGATION\|tm_peer_question' \
  engine/include/teammux.h
```

**Files:** macos/Sources/Teammux/Models/CoordinationTypes.swift (extend), macos/Sources/Teammux/Engine/EngineClient.swift, macos/Sources/Teammux/RightPane/LiveFeedView.swift

**New types in CoordinationTypes.swift:**
```swift
struct PeerQuestion: Identifiable, Sendable {
    let id: UUID
    let fromWorkerId: UInt32
    let targetWorkerId: UInt32
    let message: String
    let timestamp: Date
}

struct PeerDelegation: Identifiable, Sendable {
    let id: UUID
    let fromWorkerId: UInt32
    let targetWorkerId: UInt32
    let task: String
    let timestamp: Date
}
```

**EngineClient additions (MARK: - Peer Messaging):**
```swift
@Published var peerQuestions: [UInt32: PeerQuestion] = [:]
@Published var peerDelegations: [PeerDelegation] = []

func clearPeerQuestion(fromWorkerId: UInt32)
```

Message callback handles TM_MSG_PEER_QUESTION and TM_MSG_DELEGATION.

**LiveFeedView peer question cards:** "🔀 Worker {from} → Worker {target}: {message}" with Relay button (calls engine.dispatchTask(workerId: targetWorkerId, instruction: message)) and Dismiss button (calls engine.clearPeerQuestion). Delegations appended to dispatchHistory with "📤 Delegated" label.

**Done when:**
- ./build.sh passes
- peerQuestions populated on TM_MSG_PEER_QUESTION
- Peer question cards visible in Feed tab
- Relay button calls dispatchTask correctly
- PR raised from feat/v014-t9-peer-bridge

---

### stream-T10 — TD16 Swift Bridge: Completion History

**WAIT CHECK:** Confirm T5 merged:
```
grep 'tm_history_load\|tm_history_free\|tm_history_entry_t' \
  engine/include/teammux.h
```

**Files:** macos/Sources/Teammux/Models/CoordinationTypes.swift (extend), macos/Sources/Teammux/Engine/EngineClient.swift, macos/Sources/Teammux/RightPane/LiveFeedView.swift

**New type in CoordinationTypes.swift:**
```swift
enum HistoryEntryType: String, Sendable, Codable { case completion, question }

struct HistoryEntry: Identifiable, Sendable {
    let id: UUID
    let type: HistoryEntryType
    let workerId: UInt32
    let roleId: String?
    let content: String
    let gitCommit: String?
    let timestamp: Date
}
```

**EngineClient additions (MARK: - Completion History):**
```swift
@Published var completionHistory: [HistoryEntry] = []
```

In sessionStart: call tm_history_load after engine init, bridge to [HistoryEntry], merge with live entries (live takes precedence for same worker).

**LiveFeedView history section:** Below active cards — "Show history (N)" toggle button. When expanded: ForEach completionHistory entries in greyed-out card style (.opacity(0.6)), sorted newest-first, max 50 shown with "Show more" if longer.

**Done when:**
- ./build.sh passes
- completionHistory populated from JSONL on sessionStart
- History section appears in LiveFeedView with correct toggle
- PR raised from feat/v014-t10-history-bridge

---

### stream-T11 — PR Workflow Swift Bridge

**WAIT CHECK:** Confirm T7 merged:
```
grep 'TM_MSG_PR_READY\|TM_MSG_PR_STATUS\|tm_pr_create' \
  engine/include/teammux.h
```

**Files:** macos/Sources/Teammux/Models/CoordinationTypes.swift (extend), macos/Sources/Teammux/Engine/EngineClient.swift, macos/Sources/Teammux/RightPane/GitView.swift

**New types in CoordinationTypes.swift:**
```swift
enum PRStatus: String, Sendable, Codable { case open, merged, closed }

struct PREvent: Identifiable, Sendable {
    let id: UUID
    let workerId: UInt32
    let branchName: String
    let prUrl: String
    let title: String
    var status: PRStatus
    let timestamp: Date
}
```

**EngineClient additions (MARK: - PR Workflow):**
```swift
@Published var workerPRs: [UInt32: PREvent] = [:]
```

Handles TM_MSG_PR_READY (creates PREvent) and TM_MSG_PR_STATUS (updates status on existing PREvent).

**GitView PR section:** At top of Git tab when workerPRs non-empty. Per-worker PR card showing: status badge (green/purple/grey), title, branch name, Approve button (engine.approveMerge), Reject button (engine.rejectMerge), "Open in GitHub" link (NSWorkspace.shared.open). Section hidden when workerPRs is empty.

**Done when:**
- ./build.sh passes
- workerPRs populated on TM_MSG_PR_READY
- Status updated on TM_MSG_PR_STATUS
- PR section appears in Git tab
- Approve/Reject wired to existing MergeCoordinator flow
- PR raised from feat/v014-t11-pr-bridge

---

### stream-T12 — Persistent Session State

**WAIT CHECK:** Confirm T8 merged:
```
grep 'workerWorktrees\|workerBranches\|tm_worktree_path' \
  macos/Sources/Teammux/Engine/EngineClient.swift
```

**New file:** macos/Sources/Teammux/Session/SessionState.swift

**Snapshot types (all Codable):**
```swift
struct WorkerSnapshot: Codable {
    let id: UInt32; let name: String; let roleId: String?
    let taskDescription: String; let worktreePath: String; let branchName: String
}
struct SessionSnapshot: Codable {
    let projectPath: String; let timestamp: Date
    let workers: [WorkerSnapshot]
    let completionHistoryEntries: [HistoryEntrySnapshot]
    let dispatchHistoryEntries: [DispatchEventSnapshot]
    let workerPRs: [String: PREventSnapshot]
}
```

**Persistence path:** ~/.teammux/sessions/{SHA256(projectPath)}.json

**Save triggers:** applicationWillResignActive + applicationWillTerminate via AppDelegate. Encodes current engine state.

**Load trigger:** SetupView project selection. If session file exists, show "Restore previous session" card: N workers, last saved timestamp, role list. "Restore" button and "Start fresh" button.

**Restore sequence:** For each WorkerSnapshot, call spawnWorker with worktreePath override parameter (skips tm_worktree_create, uses saved path). If worktree path missing on disk: skip worker, show warning banner. Load completion and dispatch history into engine.

**Done when:**
- ./build.sh passes
- Session saved on app resign/terminate
- SetupView shows restore card when session exists
- Workers restored with correct roles and worktree paths
- Missing worktrees skipped with warning
- PR raised from feat/v014-t12-session-persistence

---

### stream-T13 — Worker CLAUDE.md Context Viewer

**WAIT CHECK:** Confirm T8 merged:
```
grep 'workerWorktrees' \
  macos/Sources/Teammux/Engine/EngineClient.swift
```

**Files:** macos/Sources/Teammux/RightPane/RightPaneView.swift, macos/Sources/Teammux/RightPane/ContextView.swift (new)

**RightTab addition:** case context. Tab bar: Team Lead | Git | Diff | Feed | Dispatch | Context. Icon: doc.text.fill. 6 tabs total.

**ContextView.swift:**
- Reads {worktreePath}/CLAUDE.md via FileManager.default.contents(atPath:) → String
- Renders in ScrollView, monospace font size 11
- Section headers (## prefix) rendered bold
- Refresh button: re-reads from disk
- Auto-refresh: when engine.hotReloadedWorkers.contains(selectedWorkerId), auto-refresh + show "↻ Updated" badge 3 seconds
- Live diff highlight: on hot-reload, compare old content with new, highlight changed lines with yellow background for 2 seconds before settling
- Edit button: NSWorkspace.shared.open(URL(fileURLWithPath: roleDefinitionPath)) — role TOML path resolved from role library
- Empty state: "Select a worker to view their CLAUDE.md context" when no worker selected or worktree path unavailable

**Done when:**
- ./build.sh passes
- Sixth Context tab renders in right pane
- CLAUDE.md content displayed for selected worker
- Auto-refresh on hot-reload with changed line highlight
- Edit button opens role TOML in default editor
- PR raised from feat/v014-t13-context-viewer

---

### stream-T14 — Fully Autonomous Team Lead Dispatch

**WAIT CHECK:** Confirm T9 AND T10 have both merged:
```
grep 'peerQuestions\|clearPeerQuestion' \
  macos/Sources/Teammux/Engine/EngineClient.swift
grep 'completionHistory' \
  macos/Sources/Teammux/Engine/EngineClient.swift
```

**Files:** macos/Sources/Teammux/Models/CoordinationTypes.swift (extend), macos/Sources/Teammux/Engine/EngineClient.swift, macos/Sources/Teammux/RightPane/DispatchView.swift

**New type in CoordinationTypes.swift:**
```swift
struct AutonomousDispatch: Identifiable, Sendable {
    let id: UUID
    let workerId: UInt32
    let instruction: String
    let triggerSummary: String
    let timestamp: Date
}
```

**EngineClient additions (MARK: - Autonomous Dispatch):**
```swift
@Published var autonomousDispatches: [UInt32: AutonomousDispatch] = [:]

private func triggerAutonomousDispatch(for completion: CompletionReport)
private func suggestFollowUp(completion: CompletionReport, role: RoleDefinition?) -> String
```

suggestFollowUp heuristics (deterministic, no LLM):
- "implement"/"built"/"added" → "Review the implementation and write tests"
- "fix"/"bug"/"patch" → "Verify the fix resolves the issue and add a regression test"
- "refactor"/"restructure" → "Verify all existing tests pass after the refactor"
- "test"/"spec" → "Review test coverage and identify any gaps"
- fallback → "Review the completed work and confirm it meets requirements"

triggerAutonomousDispatch called immediately when workerCompletions[workerId] is set (in handleCompletionMessage). No human step, no cancel window per confirmed design. Calls engine.dispatchTask immediately.

**DispatchView history:** Auto-dispatches shown with "🤖 Auto" badge in .secondary color alongside manual dispatches.

**Done when:**
- ./build.sh passes
- On completion signal, follow-up dispatched immediately
- 🤖 Auto badge visible in DispatchView history
- No human approval step
- PR raised from feat/v014-t14-autonomous-dispatch

---

### stream-T15 — Worker Detail Drawer + Branch Badge Extension

**WAIT CHECK:** Confirm T8 AND T11 have both merged:
```
grep 'workerWorktrees\|workerBranches' \
  macos/Sources/Teammux/Engine/EngineClient.swift
grep 'workerPRs' \
  macos/Sources/Teammux/Engine/EngineClient.swift
```

**Files:** macos/Sources/Teammux/Workspace/WorkerPaneView.swift, macos/Sources/Teammux/Workspace/WorkerDetailDrawer.swift (new)

**WorkerPaneView additions:**
```swift
@State private var selectedDrawerWorkerId: UInt32?
```
Single click on WorkerRow toggles drawer (click same worker = collapse).

**WorkerDetailDrawer.swift:**
Layout (VStack in a collapsible section):
- Role emoji + name (large)
- Full task description (wrapping text)
- Branch row: label + monospace branch name + Copy button (NSPasteboard)
- Path row: label + truncated path + Copy button
- Spawned: relative timestamp
- PR row (if engine.workerPRs[workerId] exists): status badge + title + "Open in GitHub" button

Animation: .easeInOut(duration: 0.2) on open/close.

**Done when:**
- ./build.sh passes
- Drawer opens on worker row click, collapses on second click
- Branch name and path both copyable
- PR status shown when PR exists for worker
- PR raised from feat/v014-t15-worker-drawer

---

### stream-T16 — Integration Tests + Docs + v0.1.4 Shipped

**WAIT CHECK:** Confirm T13, T14, AND T15 have all merged.

**Integration tests (engine level):**
1. Worktree create/path/branch/remove end-to-end with real git
2. /teammux-ask routes to Team Lead PTY only (not target worker)
3. /teammux-delegate routes directly to target worker PTY only
4. /teammux-pr-ready triggers gh pr create (mocked), PR URL in bus
5. JSONL append + load round-trip survives between engine inits
6. exit 126 on all four enforcement types (add, commit-a, stash-pop, push-main)
7. TD18: ownership registry and interceptor wrapper both updated after mock hot-reload
8. config.toml worktree_root override respected

**Documentation:**
- TECH_DEBT.md: TD15-TD20 RESOLVED (verify each is actually complete before marking), TD21-TD24 OPEN confirmed
- CLAUDE.md: v0.1.4 marked as shipped
- V014_SPRINT.md: all 16 streams marked complete

**Done when:**
- ./build.sh passes end to end
- zig build test all pass (report count)
- All 8 integration tests pass
- TECH_DEBT.md final state correct
- PR raised from feat/v014-t16-polish

---

## 5. Shared Rules for All Streams

- Never modify src/ (Ghostty upstream)
- All tm_* calls go through EngineClient.swift only — no exceptions
- No force-unwraps in production code
- zig build test must pass before raising PR (engine streams)
- ./build.sh must pass before raising PR (Swift streams)
- engine/include/teammux.h is the authoritative C API contract
- roles/ is local only — no external network fetching ever
- TECH_DEBT.md updated when new debt discovered during implementation
- Message type values: do NOT reuse or skip values — check registry in Section 3

---

## 6. Known Risks and Coordination Points

- T2 and T7 both add message type values — T2 owns 12+13, T7 owns 14+15. Any stream touching the enum must pull main after both T2 and T7 merge
- T9, T10, T11 all extend CoordinationTypes.swift — each must pull main before implementing to avoid recreating sections already added by prior merges
- T13 adds sixth RightTab case — T15 also touches RightPaneView. T15 must pull main after T13 merges to avoid tab bar conflict
- T14 calls engine.dispatchTask which is defined in T8's wave — T14 must confirm T8 has merged before implementing
- T12 adds worktreePath parameter to spawnWorker — any stream calling spawnWorker must pull main after T8 merges

---

## 7. Merge Checklist (main thread runs for each PR)

- [ ] Branch based on current main (merge-base check passes)
- [ ] All tests pass (zig build test or ./build.sh)
- [ ] No src/ modifications
- [ ] No force-unwraps (Swift streams)
- [ ] tm_* calls confined to EngineClient.swift (Swift streams)
- [ ] Zero conflicts with main
- [ ] TECH_DEBT.md updated for items resolved or newly discovered
- [ ] No external network calls in roles/ loading logic
- [ ] Message type values consistent with Section 3 registry

---

## 8. Stream Completion Status

| Stream | Branch                            | Status   | Merged |
|--------|-----------------------------------|----------|--------|
| T1     | feat/v014-t1-worktree-lifecycle   | COMPLETE | YES    |
| T2     | feat/v014-t2-peer-messaging       | COMPLETE | YES    |
| T3     | feat/v014-t3-interceptor-hardening| COMPLETE | YES    |
| T4     | feat/v014-t4-hotreload-registry   | COMPLETE | YES    |
| T5     | feat/v014-t5-history-persistence  | COMPLETE | YES    |
| T6     | feat/v014-t6-lasterror-fix        | COMPLETE | YES    |
| T7     | feat/v014-t7-pr-workflow-engine   | COMPLETE | YES    |
| T8     | feat/v014-t8-worktree-bridge      | COMPLETE | YES    |
| T9     | feat/v014-t9-peer-bridge          | COMPLETE | YES    |
| T10    | feat/v014-t10-history-bridge      | COMPLETE | YES    |
| T11    | feat/v014-t11-pr-bridge           | COMPLETE | YES    |
| T12    | feat/v014-t12-session-persistence | COMPLETE | YES    |
| T13    | feat/v014-t13-context-viewer      | COMPLETE | YES    |
| T14    | feat/v014-t14-autonomous-dispatch | COMPLETE | YES    |
| T15    | feat/v014-t15-worker-drawer       | COMPLETE | YES    |
| T16    | feat/v014-t16-polish              | COMPLETE | PR     |

**Tech debt resolved:** TD15-TD20 (6 items)
**Tech debt open:** TD21-TD28 (8 items, deferred to v0.1.5/v0.2)
**Engine tests:** 356 passing (14 files)
**Tag:** v0.1.4
