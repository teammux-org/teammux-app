import Foundation
import SwiftUI
import os

// MARK: - MergeStrategy

/// Maps to `tm_merge_strategy_t` in teammux.h.
enum MergeStrategy: Int, Sendable {
    case squash = 0
    case rebase = 1
    case merge  = 2

    /// Integer value for `tm_github_merge_pr()` (`tm_merge_strategy_t`).
    var cValue: Int32 { Int32(rawValue) }

    /// String value for `tm_merge_approve()` (local merge coordinator).
    var strategyString: String {
        switch self {
        case .squash: return "squash"
        case .rebase: return "rebase"
        case .merge:  return "merge"
        }
    }
}

// MARK: - EngineClient

/// The sole Swift bridge to the Teammux C engine.
///
/// **Every** `tm_*` call goes through this class. No other Swift file
/// should import or invoke C functions from `teammux.h` directly.
///
/// PTY ownership note: Ghostty owns PTYs, not the engine. After
/// `spawnWorker` creates a worktree + branch, Swift creates a
/// `Ghostty.SurfaceView` to launch the agent. Text injection goes
/// via registered injector closures (backed by `SurfaceView.sendText()`).
@MainActor
final class EngineClient: ObservableObject {

    // MARK: - Logger

    private static let logger = Logger(subsystem: "com.teammux.app", category: "EngineClient")

    // MARK: - Published properties

    @Published var roster: [WorkerInfo] = []
    @Published var messages: [TeamMessage] = []
    @Published var lastError: String? = nil
    @Published var projectRoot: String? = nil

    /// Current merge status per worker ID. Updated by polling after `approveMerge`.
    @Published var mergeStatuses: [UInt32: MergeStatus] = [:]

    /// Pending conflicts per worker ID after a conflicted merge.
    @Published var pendingConflicts: [UInt32: [ConflictInfo]] = [:]

    /// All available roles discovered from search paths (project-local, user, bundled).
    /// Populated by `loadAvailableRoles()` during session start.
    @Published var availableRoles: [RoleDefinition] = []

    /// Maps worker ID to the resolved role assigned at spawn time.
    /// Populated by `spawnWorker` when `roleId` is non-nil.
    @Published var workerRoles: [UInt32: RoleDefinition] = [:]

    /// Active completion reports, keyed by worker ID. Only the latest
    /// completion per worker is stored — a second completion before
    /// acknowledgement overwrites the first (latest state wins).
    @Published var workerCompletions: [UInt32: CompletionReport] = [:]

    /// Active questions from workers, keyed by worker ID. Only the latest
    /// question per worker is stored — a second question before clearance
    /// overwrites the first.
    @Published var workerQuestions: [UInt32: QuestionRequest] = [:]

    /// Workers that received a role hot-reload within the last 3 seconds,
    /// mapped to the engine's monotonic reload sequence number. Incrementing
    /// the value on every reload ensures `onChange` fires even for rapid
    /// repeated saves within the 3-second window (TD27).
    @Published var hotReloadedWorkers: [UInt32: UInt64] = [:]

    /// Dispatch history from the Team Lead coordinator. Ordered
    /// chronologically; when more than 100 events exist, the oldest are
    /// trimmed. Updated by `refreshDispatchHistory()` after each dispatch
    /// and available for UI refresh (e.g. when the Dispatch tab appears).
    @Published var dispatchHistory: [DispatchEvent] = []

    /// Absolute worktree path per worker ID. Populated after spawn from
    /// `tm_worktree_path()`. Nil entry means the worker has no dedicated
    /// worktree (graceful degradation — operates from project root).
    @Published var workerWorktrees: [UInt32: String] = [:]

    /// Git branch name per worker ID. Populated after spawn from
    /// `tm_worktree_branch()`. Used by WorkerRow for the branch badge.
    @Published var workerBranches: [UInt32: String] = [:]

    /// Active peer questions from workers, keyed by sending worker ID.
    /// Only the latest question per sender is stored — a second question
    /// before relay overwrites the first (latest state wins).
    @Published var peerQuestions: [UInt32: PeerQuestion] = [:]

    /// Peer delegation events, append-only (cap 100). Displayed as
    /// informational cards in LiveFeedView — the engine has already
    /// routed each delegation to the target worker's PTY.
    @Published var peerDelegations: [PeerDelegation] = []

    /// All history entries loaded from the JSONL log at session start.
    /// Sorted newest-first. Populated once during `sessionStart()` and
    /// not appended to during the session. Cleared on `destroy()`.
    @Published var completionHistory: [HistoryEntry] = []

    /// Active pull requests per worker ID. Populated when a worker signals
    /// PR creation via `TM_MSG_PR_READY` or when `createPR()` succeeds from
    /// the UI. Status updated on `TM_MSG_PR_STATUS`. Keyed by worker ID —
    /// only the latest PR per worker is tracked.
    @Published var workerPRs: [UInt32: PREvent] = [:]

    /// Autonomous dispatch metadata, keyed by worker ID. Only the latest
    /// auto-dispatch per worker is stored — a second auto-dispatch for
    /// the same worker overwrites the previous one (latest state wins).
    /// The actual dispatched task lives in `dispatchHistory`; this dict
    /// tracks which dispatches were triggered autonomously.
    /// Not Codable — ephemeral metadata, not persisted across sessions.
    @Published var autonomousDispatches: [UInt32: AutonomousDispatch] = [:]

    /// Per-worker memory file content loaded from .teammux-memory.md.
    /// Updated on completion signal and on session restore.
    @Published var workerMemory: [UInt32: String] = [:]

    /// Monotonic generation counter per worker. Bumped on restart to force
    /// SwiftUI to destroy and recreate the WorkerTerminalSurface (C4).
    @Published var restartGeneration: [UInt32: UInt64] = [:]

    // MARK: - Private state

    /// Opaque handle to the C engine (`tm_engine_t*`).
    private var engine: OpaquePointer?

    /// Maps worker ID to its SurfaceView reference (stored as AnyObject
    /// to avoid coupling this file to Ghostty types).
    private var surfaceViews: [UInt32: AnyObject] = [:]

    /// Closures that inject text into a worker's PTY via the registered
    /// SurfaceView. Set at registration time so EngineClient never imports
    /// GhosttyKit — the caller captures the concrete SurfaceView type.
    private var textInjectors: [UInt32: (String) -> Void] = [:]

    /// Auto-dismiss tasks for the hot-reload banner. Stored so we can cancel
    /// a previous timer when a new reload fires for the same worker (debounce).
    private var hotReloadTimers: [UInt32: Task<Void, Never>] = [:]

    /// Subscription handles returned by watch/subscribe calls.
    /// Stored so we can unwatch/unsubscribe in teardownCallbacks().
    private var rosterSubscription: UInt32 = 0
    private var messageSubscription: UInt32 = 0
    private var commandSubscription: UInt32 = 0
    private var githubSubscription: UInt32 = 0
    private var configSubscription: UInt32 = 0

    /// Repeating timer that polls merge status for workers with active merges.
    private var mergeStatusTimer: Timer?

    // MARK: - Surface registry

    /// Register a SurfaceView for a given worker so `EngineClient` can
    /// inject text via the provided closure. The caller captures the
    /// concrete SurfaceView type so this file stays decoupled from GhosttyKit.
    func registerSurface(_ surface: AnyObject, for workerId: UInt32, injector: @escaping (String) -> Void) {
        surfaceViews[workerId] = surface
        textInjectors[workerId] = injector
    }

    /// Remove the SurfaceView reference and text injector when a worker
    /// is dismissed or its terminal closes.
    func unregisterSurface(for workerId: UInt32) {
        surfaceViews.removeValue(forKey: workerId)
        textInjectors.removeValue(forKey: workerId)
    }

    /// Retrieve the SurfaceView for a worker, if one is registered.
    func surfaceView(for workerId: UInt32) -> AnyObject? {
        surfaceViews[workerId]
    }

    // MARK: - Utility (static)

    /// Returns the engine library version string.
    /// Wraps `tm_version()`.
    static func version() -> String {
        guard let cStr = tm_version() else { return "unknown" }
        return String(cString: cStr)
    }

    /// Convert a task description into a branch-safe slug.
    /// First 40 characters, lowercased, spaces to hyphens,
    /// non-alphanumeric characters (except hyphens) stripped,
    /// leading/trailing hyphens removed.
    static func slugify(_ input: String) -> String {
        let trimmed = String(input.prefix(40))
        let lowered = trimmed.lowercased()
        let replaced = lowered.map { char -> Character in
            if char == " " { return "-" }
            return char
        }
        let filtered = replaced.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        // Collapse consecutive hyphens
        var slug = String(filtered)
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Engine lifecycle

    /// Create the engine for a given project root directory.
    /// Wraps `tm_engine_create()` which uses an out-param pattern.
    /// Returns `true` on success, `false` if creation fails.
    func create(projectRoot: String) -> Bool {
        lastError = nil
        guard engine == nil else {
            lastError = "Engine already created"
            Self.logger.error("Engine already created")
            return false
        }

        var ptr: OpaquePointer?
        let result = projectRoot.withCString { cRoot in
            tm_engine_create(cRoot, &ptr)
        }

        guard result == TM_OK, let enginePtr = ptr else {
            lastError = lastEngineError() ?? "tm_engine_create failed (\(result.rawValue))"
            Self.logger.error("tm_engine_create failed: \(self.lastError ?? "unknown")")
            return false
        }

        engine = enginePtr
        self.projectRoot = projectRoot
        return true
    }

    /// Start the session (background threads, watchers, etc.).
    /// Wraps `tm_session_start()`. Must be called after `create`.
    /// Also loads available roles and completion history.
    /// Returns `true` on `TM_OK`.
    func sessionStart() -> Bool {
        lastError = nil
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("Engine not created")
            return false
        }

        let result = tm_session_start(engine)
        guard result == TM_OK else {
            let msg = lastEngineError() ?? "tm_session_start failed (\(result.rawValue))"
            lastError = msg
            Self.logger.error("sessionStart failed: \(msg)")
            return false
        }

        setupCallbacks()
        loadAvailableRoles()
        loadAndSeedHistory()
        return true
    }

    /// Stop the session (tears down background threads).
    /// Wraps `tm_session_stop()`.
    func sessionStop() {
        guard let engine else {
            #if DEBUG
            Self.logger.debug("sessionStop called with nil engine — no-op")
            #endif
            return
        }
        teardownCallbacks()
        tm_session_stop(engine)
    }

    /// Stop the session then destroy the engine, releasing all resources.
    /// Wraps `tm_session_stop()` + `tm_engine_destroy()`.
    func destroy() {
        sessionStop()
        if let engine {
            tm_engine_destroy(engine)
        }
        engine = nil
        projectRoot = nil
        surfaceViews.removeAll()
        textInjectors.removeAll()
        roster.removeAll()
        messages.removeAll()
        stopMergePolling()
        mergeStatuses.removeAll()
        pendingConflicts.removeAll()
        availableRoles.removeAll()
        workerRoles.removeAll()
        workerCompletions.removeAll()
        workerQuestions.removeAll()
        for (_, task) in hotReloadTimers { task.cancel() }
        hotReloadTimers.removeAll()
        hotReloadedWorkers.removeAll()
        dispatchHistory.removeAll()
        workerWorktrees.removeAll()
        workerBranches.removeAll()
        peerQuestions.removeAll()
        peerDelegations.removeAll()
        completionHistory.removeAll()
        workerPRs.removeAll()
        autonomousDispatches.removeAll()
        workerMemory.removeAll()
        restartGeneration.removeAll()
        lastError = nil
    }

    // MARK: - Config

    /// Reload config from disk (`.teammux/config.toml`).
    /// Wraps `tm_config_reload()`.
    func reloadConfig() {
        lastError = nil
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("Engine not created")
            return
        }
        let result = tm_config_reload(engine)
        if result != TM_OK {
            let msg = lastEngineError() ?? "tm_config_reload failed (\(result.rawValue))"
            lastError = msg
            Self.logger.error("reloadConfig failed: \(msg)")
        }
    }

    // MARK: - Workers

    /// Spawn a new worker: creates worktree + branch + CLAUDE.md.
    /// Does NOT create a PTY — the caller must create a Ghostty SurfaceView.
    ///
    /// When `roleId` is non-nil, resolves the role via `tm_role_resolve`,
    /// registers ownership patterns via `tm_ownership_register`, and caches
    /// the role in `workerRoles`. Role resolution failure logs a warning
    /// but does not fail the spawn.
    ///
    /// Returns the new worker ID, or 0 on failure.
    /// Wraps `tm_worker_spawn()`.
    func spawnWorker(
        agentBinary: String,
        agentType: AgentType,
        workerName: String,
        taskDescription: String,
        roleId: String? = nil
    ) -> UInt32 {
        lastError = nil
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("Engine not created")
            return 0
        }

        let workerId = agentBinary.withCString { cBinary in
            workerName.withCString { cName in
                taskDescription.withCString { cTask in
                    tm_worker_spawn(
                        engine,
                        cBinary,
                        tm_agent_type_t(rawValue: UInt32(agentType.cValue)),
                        cName,
                        cTask
                    )
                }
            }
        }

        if workerId == UInt32.max {  // TM_WORKER_INVALID
            let msg = lastEngineError() ?? "tm_worker_spawn failed"
            lastError = msg
            Self.logger.error("spawnWorker failed: \(msg)")
            return 0  // Return 0 to callers as "failed"
        }

        // Cache worktree path and branch for downstream consumers
        // (session persistence, context viewer, worker detail drawer).
        // The engine creates the worktree internally during tm_worker_spawn.
        // Nil return means no worktree — graceful degradation, worker operates
        // from project root.
        if let cPath = tm_worktree_path(engine, workerId) {
            workerWorktrees[workerId] = String(cString: cPath)
        } else {
            Self.logger.warning("spawnWorker: tm_worktree_path returned nil for worker \(workerId) — operating from project root")
        }
        if let cBranch = tm_worktree_branch(engine, workerId) {
            workerBranches[workerId] = String(cString: cBranch)
        } else {
            Self.logger.warning("spawnWorker: tm_worktree_branch returned nil for worker \(workerId)")
        }

        // Resolve role and register ownership patterns if roleId was provided.
        // Failure here is non-fatal — the worker still operates, just without
        // role-based ownership enforcement. The role is always cached when
        // resolution succeeds (valid metadata for UI), even if ownership
        // registration partially fails (R8 interceptor is the real enforcement).
        if let roleId {
            if let role = resolveRole(id: roleId) {
                let registered = registerOwnership(workerId: workerId, role: role)
                workerRoles[workerId] = role
                startRoleWatch(workerId: workerId)
                if !registered {
                    Self.logger.error("spawnWorker: role '\(roleId)' resolved but ownership registration failed for worker \(workerId) — enforcement degraded")
                }
            } else {
                Self.logger.warning("spawnWorker: role '\(roleId)' could not be resolved for worker \(workerId)")
            }
        }

        // Install git interceptor wrapper. Called unconditionally — the engine
        // reads deny_write patterns from the ownership registry and embeds them
        // in the wrapper script. Workers with no registered deny patterns
        // (including those with no role) get a pass-through wrapper.
        let hasResolvedRole = workerRoles[workerId] != nil
        let interceptResult = tm_interceptor_install(engine, workerId)
        if interceptResult != TM_OK {
            let msg = lastEngineError() ?? "tm_interceptor_install failed (\(interceptResult.rawValue))"
            if hasResolvedRole {
                // Hard failure for role-assigned workers: enforcement is the
                // whole point of roles. Continuing without it silently drops
                // write-scope guarantees.
                lastError = msg
                Self.logger.error("spawnWorker: \(msg) — dismissing worker to avoid degraded enforcement")
                stopRoleWatch(workerId: workerId)
                let dismissResult = tm_worker_dismiss(engine, workerId)
                if dismissResult != TM_OK {
                    let dismissMsg = lastEngineError() ?? "tm_worker_dismiss failed (\(dismissResult.rawValue))"
                    Self.logger.error("spawnWorker: cleanup dismiss failed for worker \(workerId): \(dismissMsg)")
                }
                workerRoles.removeValue(forKey: workerId)
                workerWorktrees.removeValue(forKey: workerId)
                workerBranches.removeValue(forKey: workerId)
                refreshRoster()
                return 0
            }
            Self.logger.warning("spawnWorker: \(msg) — no role assigned, continuing with pass-through")
        }

        // Refresh the roster to pick up the new worker
        refreshRoster()

        // Load any existing memory file for this worker (S13)
        loadWorkerMemory(workerId: workerId)

        return workerId
    }

    /// Dismiss (tear down) a worker. Removes worktree, cleans up engine state.
    /// Also stops role file watching, unregisters the surface view, and removes the cached role.
    /// The engine releases ownership rules internally via `tm_ownership_release`.
    /// Wraps `tm_worker_dismiss()`.
    /// Returns `true` on `TM_OK`.
    func dismissWorker(_ workerId: UInt32) -> Bool {
        lastError = nil
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("Engine not created")
            return false
        }

        stopRoleWatch(workerId: workerId)

        let result = tm_worker_dismiss(engine, workerId)

        guard result == TM_OK else {
            let msg = lastEngineError() ?? "tm_worker_dismiss failed (\(result.rawValue))"
            lastError = msg
            Self.logger.error("dismissWorker failed: \(msg)")
            return false
        }

        unregisterSurface(for: workerId)
        workerRoles.removeValue(forKey: workerId)
        workerWorktrees.removeValue(forKey: workerId)
        workerBranches.removeValue(forKey: workerId)
        workerMemory.removeValue(forKey: workerId)
        restartGeneration.removeValue(forKey: workerId)
        refreshRoster()
        return true
    }

    // MARK: - Worker health

    /// Reset a worker's health status in the engine after Swift-side PTY respawn.
    /// Does NOT manage PTYs — call after creating the new SurfaceView.
    func restartWorker(id: UInt32) -> Bool {
        guard let engine else {
            Self.logger.warning("restartWorker: no engine")
            lastError = "Engine not initialized"
            return false
        }
        lastError = nil
        let result = tm_worker_restart(engine, id)
        if result != TM_OK {
            let msg = String(cString: tm_engine_last_error(engine))
            lastError = msg
            Self.logger.warning("restartWorker(\(id)) failed: \(msg)")
            return false
        }
        refreshRoster()
        return true
    }

    /// Bump the restart generation for a worker, causing SwiftUI to destroy
    /// the old WorkerTerminalSurface and create a fresh one (C4 PTY respawn).
    func bumpRestartGeneration(for workerId: UInt32) {
        restartGeneration[workerId, default: 0] += 1
    }

    // MARK: - Session Restore

    /// Restores workers and state from a previously saved session snapshot.
    ///
    /// For each `WorkerSnapshot`:
    /// 1. Checks that the worktree path still exists on disk — skips with warning if missing
    /// 2. Calls `spawnWorker` normally (engine handles worktree-already-exists gracefully)
    /// 3. Overrides `workerWorktrees` and `workerBranches` caches with saved snapshot values
    ///
    /// Note: the engine assigns fresh worker IDs on spawn — snapshot IDs are not preserved.
    /// An old-to-new ID mapping is built during the worker loop and used to remap
    /// `workerPRs` and `dispatchHistory` entries to the new IDs.
    ///
    /// Completion history is intentionally not restored from the snapshot —
    /// `sessionStart()` reloads it from the authoritative JSONL log.
    ///
    /// After workers: merges snapshot dispatch events into `dispatchHistory` (dedup by
    /// timestamp + remapped targetWorkerId). Populates `workerPRs` from snapshot.
    ///
    /// Returns the number of workers that failed to restore (0 = full success).
    @discardableResult
    func restoreSession(_ snapshot: SessionSnapshot) -> Int {
        let fm = FileManager.default
        var skippedWorkers: [String] = []
        var idMapping: [UInt32: UInt32] = [:]  // old snapshot ID → new engine ID

        // TD22: Role-based ownership is restored correctly — spawnWorker()
        // calls resolveRole() + registerOwnership() when roleId is non-nil
        // and the role TOML is still present on disk, re-registering write
        // and deny patterns from the resolved role definition.
        // Runtime ownership changes made via direct tm_ownership_register()
        // calls (outside the role file) are NOT persisted or restored here.
        // Full registry snapshot deferred to v0.2 (see TECH_DEBT.md TD22).
        for worker in snapshot.workers {
            guard fm.fileExists(atPath: worker.worktreePath) else {
                Self.logger.warning("restoreSession: worktree missing at \(worker.worktreePath) — skipping worker \(worker.id) (\(worker.name))")
                skippedWorkers.append(worker.name)
                continue
            }

            let agentType = AgentType(fromCValue: worker.agentTypeCValue, binaryName: worker.agentBinary)

            let workerId = spawnWorker(
                agentBinary: worker.agentBinary,
                agentType: agentType,
                workerName: worker.name,
                taskDescription: worker.taskDescription,
                roleId: worker.roleId
            )

            guard workerId != 0 else {
                Self.logger.warning("restoreSession: spawnWorker failed for \(worker.name) — skipping")
                skippedWorkers.append(worker.name)
                continue
            }

            idMapping[worker.id] = workerId

            // Override caches with saved snapshot values (do not rely on
            // tm_worktree_path query — use saved paths directly).
            workerWorktrees[workerId] = worker.worktreePath
            workerBranches[workerId] = worker.branchName
        }

        // Merge snapshot dispatch events into dispatchHistory.
        // Remap targetWorkerId from snapshot IDs to new engine IDs.
        // Deduplicate by timestamp + remapped targetWorkerId.
        // Dispatch events are not persisted to JSONL — the snapshot is
        // the only persistence mechanism for these.
        for entry in snapshot.dispatchHistoryEntries {
            let newTargetId = idMapping[entry.targetWorkerId] ?? entry.targetWorkerId

            let isDuplicate = dispatchHistory.contains { existing in
                existing.targetWorkerId == newTargetId
                    && existing.timestamp == entry.timestamp
            }
            guard !isDuplicate else { continue }

            dispatchHistory.append(DispatchEvent(
                targetWorkerId: newTargetId,
                instruction: entry.instruction,
                timestamp: entry.timestamp,
                delivered: entry.delivered,
                kind: entry.kind
            ))
        }

        // Sort dispatch history by timestamp (oldest first) after merge
        dispatchHistory.sort { $0.timestamp < $1.timestamp }

        // Populate workerPRs from snapshot, remapping old IDs to new IDs
        for (key, prSnapshot) in snapshot.workerPRs {
            guard let oldId = UInt32(key) else {
                Self.logger.warning("restoreSession: unparseable workerPR key '\(key)' — skipping PR event")
                continue
            }
            let newId = idMapping[oldId] ?? oldId
            workerPRs[newId] = PREvent(
                workerId: newId,
                branchName: prSnapshot.branchName,
                prUrl: prSnapshot.prUrl,
                title: prSnapshot.title,
                status: prSnapshot.status,
                timestamp: prSnapshot.timestamp
            )
        }

        if !skippedWorkers.isEmpty {
            let names = skippedWorkers.joined(separator: ", ")
            lastError = "Skipped workers with missing worktrees: \(names)"
            Self.logger.warning("restoreSession: skipped \(skippedWorkers.count) workers — \(names)")
        }

        // Load agent memory files for all restored workers (S13)
        loadAllWorkerMemory()

        Self.logger.info("restoreSession: restored \(snapshot.workers.count - skippedWorkers.count)/\(snapshot.workers.count) workers")
        return skippedWorkers.count
    }

    /// C5: Scan for orphaned worktrees and clean them up.
    /// Must be called after session restore so the roster contains restored workers.
    func recoverOrphans() {
        guard let engine else { return }
        let count = tm_recover_orphans(engine)
        if count > 0 {
            Self.logger.info("recoverOrphans: cleaned up \(count) orphaned worktree(s)")
        }
    }

    /// Refresh the published roster from the engine.
    /// Wraps `tm_roster_get()` + `tm_roster_free()`.
    func refreshRoster() {
        guard let engine else { return }
        guard let rosterPtr = tm_roster_get(engine) else {
            Self.logger.warning("tm_roster_get returned nil — roster may be stale")
            return
        }

        var newRoster: [WorkerInfo] = []
        let count = Int(rosterPtr.pointee.count)

        for i in 0..<count {
            let w = rosterPtr.pointee.workers[i]
            let info = WorkerInfo(
                id: w.id,
                name: String(cString: w.name),
                taskDescription: String(cString: w.task_description),
                branchName: String(cString: w.branch_name),
                worktreePath: String(cString: w.worktree_path),
                status: WorkerStatus(fromCValue: Int32(w.status.rawValue)),
                agentType: AgentType(
                    fromCValue: Int32(w.agent_type.rawValue),
                    binaryName: String(cString: w.agent_binary)
                ),
                agentBinary: String(cString: w.agent_binary),
                model: String(cString: w.model),
                spawnedAt: Date(timeIntervalSince1970: TimeInterval(w.spawned_at)),
                lastActivityTs: Date(timeIntervalSince1970: TimeInterval(w.last_activity_ts)),
                healthStatus: HealthStatus(fromCValue: Int32(w.health_status.rawValue))
            )
            newRoster.append(info)
        }

        tm_roster_free(rosterPtr)
        self.roster = newRoster
    }

    // MARK: - Messaging

    /// Send a message to a specific worker on the message bus.
    /// Wraps `tm_message_send()`.
    /// Returns `true` on `TM_OK`.
    func sendMessage(to workerId: UInt32, type: MessageType, payload: String) -> Bool {
        lastError = nil
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("Engine not created")
            return false
        }

        let result = payload.withCString { cPayload in
            tm_message_send(
                engine,
                workerId,
                tm_message_type_t(rawValue: UInt32(type.cValue)),
                cPayload
            )
        }

        guard result == TM_OK else {
            let msg = lastEngineError() ?? "tm_message_send failed (\(result.rawValue))"
            lastError = msg
            Self.logger.error("sendMessage failed: \(msg)")
            return false
        }

        return true
    }

    /// Broadcast a message to all workers on the message bus.
    /// Wraps `tm_message_broadcast()`.
    /// Returns `true` on `TM_OK`.
    func broadcastMessage(type: MessageType, payload: String) -> Bool {
        lastError = nil
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("Engine not created")
            return false
        }

        let result = payload.withCString { cPayload in
            tm_message_broadcast(
                engine,
                tm_message_type_t(rawValue: UInt32(type.cValue)),
                cPayload
            )
        }

        guard result == TM_OK else {
            let msg = lastEngineError() ?? "tm_message_broadcast failed (\(result.rawValue))"
            lastError = msg
            Self.logger.error("broadcastMessage failed: \(msg)")
            return false
        }

        return true
    }

    // MARK: - GitHub

    /// Authenticate with GitHub via the engine's built-in flow.
    /// Wraps `tm_github_auth()`.
    /// Returns `true` on `TM_OK`.
    func connectGitHub() -> Bool {
        lastError = nil
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("Engine not created")
            return false
        }

        let result = tm_github_auth(engine)
        guard result == TM_OK else {
            let msg = lastEngineError() ?? "tm_github_auth failed (\(result.rawValue))"
            lastError = msg
            Self.logger.error("connectGitHub failed: \(msg)")
            return false
        }

        if tm_github_is_authed(engine) {
            return true
        } else {
            let msg = "GitHub auth succeeded but is_authed returned false"
            lastError = msg
            Self.logger.error("\(msg)")
            return false
        }
    }

    /// Create a pull request for a worker's branch.
    /// Wraps `tm_github_create_pr()` + `tm_pr_free()`.
    /// Returns a `GitHubPR` on success, `nil` on failure.
    func createPR(for workerId: UInt32, title: String, body: String) -> GitHubPR? {
        lastError = nil
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("Engine not created")
            return nil
        }

        let prPtr = title.withCString { cTitle in
            body.withCString { cBody in
                tm_github_create_pr(engine, workerId, cTitle, cBody)
            }
        }

        guard let prPtr else {
            let msg = lastEngineError() ?? "tm_github_create_pr failed"
            lastError = msg
            Self.logger.error("createPR failed: \(msg)")
            return nil
        }

        let pr = GitHubPR(
            number: prPtr.pointee.pr_number,
            url: String(cString: prPtr.pointee.pr_url),
            title: String(cString: prPtr.pointee.title),
            state: PRStatus(fromCValue: prPtr.pointee.state.rawValue),
            diffUrl: String(cString: prPtr.pointee.diff_url),
            workerId: prPtr.pointee.worker_id
        )

        tm_pr_free(prPtr)

        // Populate workerPRs so the PR card appears immediately in GitView.
        // A subsequent TM_MSG_PR_READY from the bus will replace this entry.
        let workerInfo = roster.first { $0.id == workerId }
        if workerInfo == nil {
            Self.logger.warning("createPR: worker \(workerId) not found in roster, PR card will lack branch name")
        }
        let prEvent = PREvent(
            id: workerPRs[workerId]?.id ?? UUID(),
            workerId: workerId,
            branchName: workerInfo?.branchName ?? "",
            prUrl: pr.url,
            title: pr.title,
            status: .open,
            timestamp: Date()
        )
        workerPRs[workerId] = prEvent

        return pr
    }

    /// Merge a pull request by PR number.
    /// Wraps `tm_github_merge_pr()`.
    /// Returns `true` on `TM_OK`.
    func mergePR(_ prNumber: UInt64, strategy: MergeStrategy) -> Bool {
        lastError = nil
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("Engine not created")
            return false
        }

        let result = tm_github_merge_pr(
            engine,
            prNumber,
            tm_merge_strategy_t(rawValue: UInt32(strategy.cValue))
        )

        guard result == TM_OK else {
            let msg = lastEngineError() ?? "tm_github_merge_pr failed (\(result.rawValue))"
            lastError = msg
            Self.logger.error("mergePR failed: \(msg)")
            return false
        }

        return true
    }

    /// Get the diff for a worker's PR via GitHub PR files API.
    /// Looks up the PR number from `workerPRs`, then calls `tm_github_get_diff()`.
    /// Returns an array of `DiffFile`, empty on failure or if no PR exists.
    func getDiff(for workerId: UInt32) -> [DiffFile] {
        lastError = nil
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("Engine not created")
            return []
        }

        guard let prEvent = workerPRs[workerId] else {
            // No PR yet is an expected state, not an error — don't set lastError.
            Self.logger.info("getDiff: no PR for worker \(workerId)")
            return []
        }

        guard let prNumber = Self.extractPRNumber(from: prEvent.prUrl) else {
            lastError = "Cannot parse PR number from URL: \(prEvent.prUrl)"
            Self.logger.error("getDiff: cannot parse PR number from \(prEvent.prUrl)")
            return []
        }

        guard let diffPtr = tm_github_get_diff(engine, prNumber) else {
            let msg = lastEngineError() ?? "tm_github_get_diff failed"
            lastError = msg
            Self.logger.error("getDiff failed: \(msg)")
            return []
        }

        var files: [DiffFile] = []
        let count = Int(diffPtr.pointee.count)

        for i in 0..<count {
            let f = diffPtr.pointee.files[i]
            let file = DiffFile(
                filePath: String(cString: f.file_path),
                status: DiffStatus(fromCValue: f.status.rawValue),
                additions: Int(f.additions),
                deletions: Int(f.deletions),
                patch: String(cString: f.patch)
            )
            files.append(file)
        }

        tm_diff_free(diffPtr)
        return files
    }

    /// Extract PR number from a GitHub PR URL (e.g. "https://github.com/owner/repo/pull/42" → 42).
    static func extractPRNumber(from url: String) -> UInt64? {
        guard let range = url.range(of: "/pull/", options: .backwards) else { return nil }
        let after = url[range.upperBound...]
        let digits = after.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        return UInt64(digits)
    }

    // MARK: - Merge Coordinator

    /// Approve merge of a worker's branch into main.
    /// Wraps `tm_merge_approve()`. Returns `true` if the engine accepted the request.
    /// `true` does not mean the merge succeeded — check `getMergeStatus()` for the
    /// outcome, which may be `.inProgress`, `.success`, or `.conflict`.
    func approveMerge(workerId: UInt32, strategy: MergeStrategy) -> Bool {
        lastError = nil
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("Engine not created")
            return false
        }

        let result = strategy.strategyString.withCString { cStrategy in
            tm_merge_approve(engine, workerId, cStrategy)
        }

        if result == TM_ERR_CLEANUP_INCOMPLETE {
            let engineMsg = lastEngineError() ?? "worktree cleanup was incomplete"
            let warning = "Merge succeeded but \(engineMsg). Manual cleanup may be needed."
            lastError = warning
            Self.logger.warning("approveMerge: worker \(workerId) \(warning)")
        } else if result != TM_OK {
            let msg = lastEngineError() ?? "tm_merge_approve failed (\(result.rawValue))"
            lastError = msg
            Self.logger.error("approveMerge failed: \(msg)")
            return false
        }

        let savedWarning = lastError
        let initialStatus = getMergeStatus(workerId: workerId)
        lastError = savedWarning
        mergeStatuses[workerId] = initialStatus
        Self.logger.info("approveMerge: worker \(workerId) initial status: \(initialStatus.label)")
        startMergePolling()
        return true
    }

    /// Reject a worker's merge: abort in-progress merge, remove worktree, delete branch.
    /// The worker remains in the roster with a completed/dismissed status.
    /// Wraps `tm_merge_reject()`. Returns `true` on success (including partial cleanup).
    func rejectMerge(workerId: UInt32) -> Bool {
        lastError = nil
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("Engine not created")
            return false
        }

        let result = tm_merge_reject(engine, workerId)

        if result == TM_ERR_CLEANUP_INCOMPLETE {
            let engineMsg = lastEngineError() ?? "worktree cleanup was incomplete"
            let warning = "Reject succeeded but \(engineMsg). Manual cleanup may be needed."
            lastError = warning
            Self.logger.warning("rejectMerge: worker \(workerId) \(warning)")
        } else if result != TM_OK {
            let msg = lastEngineError() ?? "tm_merge_reject failed (\(result.rawValue))"
            lastError = msg
            Self.logger.error("rejectMerge failed: \(msg)")
            return false
        }

        mergeStatuses[workerId] = .rejected
        pendingConflicts.removeValue(forKey: workerId)
        return true
    }

    /// Get current merge status for a worker.
    /// Wraps `tm_merge_get_status()`.
    /// Returns `.pending` if the engine is not initialized.
    func getMergeStatus(workerId: UInt32) -> MergeStatus {
        lastError = nil
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("getMergeStatus: engine not created")
            return .pending
        }
        let raw = tm_merge_get_status(engine, workerId)
        return MergeStatus(fromCValue: Int32(raw.rawValue))
    }

    /// Get list of conflicts for a worker after a conflicted merge.
    /// Wraps `tm_merge_conflicts_get()` + `tm_merge_conflicts_free()`.
    func getConflicts(workerId: UInt32) -> [ConflictInfo] {
        lastError = nil
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("Engine not created")
            return []
        }

        var count: UInt32 = 0
        guard let conflictsPtr = tm_merge_conflicts_get(engine, workerId, &count) else {
            if let msg = lastEngineError() {
                lastError = msg
                Self.logger.error("getConflicts failed: \(msg)")
            }
            return []
        }

        var conflicts: [ConflictInfo] = []
        for i in 0..<Int(count) {
            guard let ptr = conflictsPtr[i] else { continue }
            let ours: String? = {
                guard let p = ptr.pointee.ours, p.pointee != 0 else { return nil }
                return String(cString: p)
            }()
            let theirs: String? = {
                guard let p = ptr.pointee.theirs, p.pointee != 0 else { return nil }
                return String(cString: p)
            }()
            let conflict = ConflictInfo(
                filePath: String(cString: ptr.pointee.file_path),
                conflictType: ConflictType(rawString: String(cString: ptr.pointee.conflict_type)),
                ours: ours,
                theirs: theirs,
                resolution: ConflictResolution(rawValue: UInt8(ptr.pointee.resolution.rawValue)) ?? .pending
            )
            conflicts.append(conflict)
        }

        tm_merge_conflicts_free(conflictsPtr, count)
        return conflicts
    }

    /// Resolve a single file in a conflicted merge.
    /// Wraps `tm_conflict_resolve()`.
    func resolveConflict(workerId: UInt32, filePath: String, resolution: ConflictResolution) -> Bool {
        lastError = nil
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("Engine not created")
            return false
        }

        let result = filePath.withCString { cPath in
            tm_conflict_resolve(engine, workerId, cPath, tm_resolution_t(rawValue: UInt32(resolution.rawValue)))
        }

        if result != TM_OK {
            let msg = lastEngineError() ?? "tm_conflict_resolve failed (\(result.rawValue))"
            lastError = msg
            Self.logger.error("resolveConflict failed: \(msg)")
            return false
        }

        // Refresh conflicts to update resolution state
        pendingConflicts[workerId] = getConflicts(workerId: workerId)
        return true
    }

    /// Finalize a conflicted merge after all files are resolved.
    /// Wraps `tm_conflict_finalize()`. Returns `true` on success.
    func finalizeMerge(workerId: UInt32) -> Bool {
        lastError = nil
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("Engine not created")
            return false
        }

        let result = tm_conflict_finalize(engine, workerId)

        if result == TM_ERR_CLEANUP_INCOMPLETE {
            let engineMsg = lastEngineError() ?? "worktree cleanup was incomplete"
            let warning = "Merge finalized but \(engineMsg). Manual cleanup may be needed."
            lastError = warning
            Self.logger.warning("finalizeMerge: worker \(workerId) \(warning)")
        } else if result != TM_OK {
            let msg = lastEngineError() ?? "tm_conflict_finalize failed (\(result.rawValue))"
            lastError = msg
            Self.logger.error("finalizeMerge failed: \(msg)")
            return false
        }

        mergeStatuses[workerId] = .success
        pendingConflicts.removeValue(forKey: workerId)
        return true
    }

    // MARK: - Roles

    /// Load all available roles from the engine's search paths
    /// (project-local, user, bundled). Populates `availableRoles`.
    /// Called during `sessionStart()`. Failure logs a warning but
    /// does not prevent session operation.
    /// Wraps `tm_roles_list()` + `tm_roles_list_free()`.
    func loadAvailableRoles() {
        guard let engine else {
            Self.logger.warning("loadAvailableRoles: engine not created")
            return
        }

        var count: UInt32 = 0
        guard let rolesPtr = tm_roles_list(engine, &count) else {
            if let msg = lastEngineError() {
                Self.logger.error("loadAvailableRoles: tm_roles_list failed: \(msg)")
            } else {
                Self.logger.info("loadAvailableRoles: no roles found")
            }
            availableRoles = []
            return
        }

        guard count > 0 else {
            tm_roles_list_free(rolesPtr, count)
            Self.logger.info("loadAvailableRoles: no roles found (count=0)")
            availableRoles = []
            return
        }

        var roles: [RoleDefinition] = []
        for i in 0..<Int(count) {
            guard let rolePtr = rolesPtr[i] else {
                Self.logger.warning("loadAvailableRoles: NULL role at index \(i) — skipping")
                continue
            }
            if let role = Self.bridgeRole(rolePtr) {
                roles.append(role)
            }
        }

        tm_roles_list_free(rolesPtr, count)
        availableRoles = roles
        Self.logger.info("loadAvailableRoles: loaded \(roles.count) roles")
    }

    /// List bundled roles without an active engine session.
    /// Wraps `tm_roles_list_bundled()` + `tm_roles_list_bundled_free()`.
    /// Returns an empty array if no roles are found or if the C API returns NULL.
    /// Pass `nil` for `projectRoot` to skip the project-local (`.teammux/roles/`)
    /// search path; user, bundle, and dev-build paths are still searched.
    /// Safe to call before `create()` or `sessionStart()` — does not require
    /// an engine instance (uses the standalone C API `tm_roles_list_bundled`).
    static func listBundledRoles(projectRoot: String?) -> [RoleDefinition] {
        var count: UInt32 = 0

        let rolesPtr: UnsafeMutablePointer<UnsafeMutablePointer<tm_role_t>?>?
        if let projectRoot {
            rolesPtr = projectRoot.withCString { cRoot in
                tm_roles_list_bundled(cRoot, &count)
            }
        } else {
            rolesPtr = tm_roles_list_bundled(nil, &count)
        }

        guard let rolesPtr else {
            // NULL pointer could mean no roles OR an internal failure (OOM).
            // No engine instance to query for error details.
            logger.warning("listBundledRoles: tm_roles_list_bundled returned NULL — roles may have failed to load")
            return []
        }

        guard count > 0 else {
            tm_roles_list_bundled_free(rolesPtr, count)
            logger.info("listBundledRoles: engine returned empty list")
            return []
        }

        var roles: [RoleDefinition] = []
        for i in 0..<Int(count) {
            guard let rolePtr = rolesPtr[i] else {
                logger.warning("listBundledRoles: NULL role at index \(i) — skipping")
                continue
            }
            if let role = bridgeRole(rolePtr) {
                roles.append(role)
            }
        }

        tm_roles_list_bundled_free(rolesPtr, count)
        logger.info("listBundledRoles: loaded \(roles.count) roles")
        return roles
    }

    /// Look up the role assigned to a worker at spawn time.
    /// Returns `nil` if the worker was spawned without a role.
    func roleForWorker(_ workerId: UInt32) -> RoleDefinition? {
        workerRoles[workerId]
    }

    /// Check whether a worker is allowed to write to `filePath`.
    /// Wraps `tm_ownership_check()`. Returns `true` when no rules are
    /// registered (default allow), or when the path is permitted by the
    /// worker's ownership rules. Deny patterns take precedence over
    /// write patterns (see `tm_ownership_check` in teammux.h).
    ///
    /// On error, defaults to allow because the real enforcement layer is
    /// stream-R8's git interceptor at the PTY level. This is advisory.
    func checkCapability(workerId: UInt32, filePath: String) -> Bool {
        lastError = nil
        guard let engine else {
            lastError = "Capability check unavailable: engine not created"
            Self.logger.error("checkCapability: engine not created — defaulting to allow for '\(filePath)'")
            return true
        }

        var allowed = true
        let result = filePath.withCString { cPath in
            tm_ownership_check(engine, workerId, cPath, &allowed)
        }

        if result != TM_OK {
            let msg = lastEngineError() ?? "tm_ownership_check failed (\(result.rawValue))"
            lastError = "Capability check failed: \(msg)"
            Self.logger.error("checkCapability failed for worker \(workerId), path '\(filePath)': \(msg) — defaulting to allow")
            return true
        }

        return allowed
    }

    /// Get the absolute path to the interceptor directory for a worker.
    /// The caller prepends this to PATH in the worker's PTY environment so
    /// that the wrapper script shadows the real git binary.
    /// Returns `nil` if no interceptor is installed or the worker is not found.
    /// Wraps `tm_interceptor_path()` + `tm_free_string()`.
    func interceptorPath(for workerId: UInt32) -> String? {
        guard let engine else {
            Self.logger.error("interceptorPath: engine not created — worker \(workerId) will have no git interception")
            return nil
        }
        guard let cStr = tm_interceptor_path(engine, workerId) else { return nil }
        let path = String(cString: cStr).trimmingCharacters(in: .whitespacesAndNewlines)
        tm_free_string(cStr)
        return path.isEmpty ? nil : path
    }

    /// Get the interceptor directory path for the Team Lead (worker 0).
    /// Used by TeamLeadTerminalView to inject the deny-all git wrapper
    /// into the Team Lead's PTY PATH.
    func teamLeadInterceptorPath() -> String? {
        return interceptorPath(for: 0)
    }

    // MARK: - Private: Role helpers

    /// Resolve a single role by ID. Returns `nil` if the role cannot be found
    /// or fails to parse.
    /// Wraps `tm_role_resolve()` + `tm_role_free()`.
    private func resolveRole(id: String) -> RoleDefinition? {
        guard let engine else {
            Self.logger.warning("resolveRole: engine not created")
            return nil
        }

        var rolePtr: UnsafeMutablePointer<tm_role_t>?
        let result = id.withCString { cId in
            tm_role_resolve(engine, cId, &rolePtr)
        }

        guard result == TM_OK, let rolePtr else {
            let msg = lastEngineError() ?? "tm_role_resolve failed (\(result.rawValue))"
            Self.logger.error("resolveRole('\(id)') failed: \(msg)")
            return nil
        }

        let role = Self.bridgeRole(rolePtr)
        tm_role_free(rolePtr)
        if role == nil {
            Self.logger.error("resolveRole('\(id)'): bridgeRole returned nil — corrupted role data")
        }
        return role
    }

    /// Bridge a `tm_role_t*` to a Swift `RoleDefinition`.
    /// Extracts string fields, boolean capabilities, and iterates
    /// the `const char**` pattern arrays. Returns `nil` if required
    /// string fields (`id`, `name`, `division`, `emoji`, `description`)
    /// are NULL — defensive guard for pre-session codepath.
    private static func bridgeRole(_ rolePtr: UnsafeMutablePointer<tm_role_t>) -> RoleDefinition? {
        let role = rolePtr.pointee

        guard let idPtr = role.id,
              let namePtr = role.name,
              let divPtr = role.division,
              let emojiPtr = role.emoji,
              let descPtr = role.description else {
            logger.error("bridgeRole: NULL required string field in tm_role_t — skipping")
            return nil
        }

        let roleId = String(cString: idPtr)

        var writePatterns: [String] = []
        if let patternsPtr = role.write_patterns {
            for i in 0..<Int(role.write_pattern_count) {
                if let cStr = patternsPtr[i] {
                    writePatterns.append(String(cString: cStr))
                } else {
                    logger.warning("bridgeRole: NULL write_pattern at index \(i) for role '\(roleId)'")
                }
            }
        }

        var denyWritePatterns: [String] = []
        if let patternsPtr = role.deny_write_patterns {
            for i in 0..<Int(role.deny_write_pattern_count) {
                if let cStr = patternsPtr[i] {
                    denyWritePatterns.append(String(cString: cStr))
                } else {
                    logger.warning("bridgeRole: NULL deny_write_pattern at index \(i) for role '\(roleId)'")
                }
            }
        }

        return RoleDefinition(
            id: roleId,
            name: String(cString: namePtr),
            division: String(cString: divPtr),
            emoji: String(cString: emojiPtr),
            description: String(cString: descPtr),
            writePatterns: writePatterns,
            denyWritePatterns: denyWritePatterns,
            canPush: role.can_push,
            canMerge: role.can_merge
        )
    }

    /// Register all write and deny_write patterns from a role definition
    /// into the engine's ownership registry for a given worker.
    /// Returns `true` only when all patterns registered successfully.
    /// Wraps `tm_ownership_register()`.
    @discardableResult
    private func registerOwnership(workerId: UInt32, role: RoleDefinition) -> Bool {
        guard let engine else {
            Self.logger.error("registerOwnership: engine not created — skipping \(role.writePatterns.count + role.denyWritePatterns.count) patterns for worker \(workerId)")
            return false
        }

        var allSucceeded = true

        for pattern in role.writePatterns {
            pattern.withCString { cPattern in
                let result = tm_ownership_register(engine, workerId, cPattern, true)
                if result != TM_OK {
                    let msg = lastEngineError() ?? "(\(result.rawValue))"
                    Self.logger.warning("registerOwnership: failed to register write pattern '\(pattern)' for worker \(workerId): \(msg)")
                    allSucceeded = false
                }
            }
        }

        for pattern in role.denyWritePatterns {
            pattern.withCString { cPattern in
                let result = tm_ownership_register(engine, workerId, cPattern, false)
                if result != TM_OK {
                    let msg = lastEngineError() ?? "(\(result.rawValue))"
                    Self.logger.warning("registerOwnership: failed to register deny pattern '\(pattern)' for worker \(workerId): \(msg)")
                    allSucceeded = false
                }
            }
        }

        return allSucceeded
    }

    // MARK: - Private: Role Hot-Reload

    /// Start watching the role TOML file for a worker. When the file changes,
    /// the engine regenerates CLAUDE.md and fires the callback with the new
    /// content. The callback injects the updated context into the worker's PTY
    /// and sets a 3-second transient notification in `hotReloadedWorkers`.
    ///
    /// Requires `workerRoles[workerId]` to be set (role ID is read from it).
    /// Wraps `tm_role_watch()`.
    private func startRoleWatch(workerId: UInt32) {
        guard let engine else {
            Self.logger.error("startRoleWatch: engine not created")
            return
        }

        guard let roleId = workerRoles[workerId]?.id else {
            Self.logger.warning("startRoleWatch: no role cached for worker \(workerId)")
            return
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let result = roleId.withCString { cRoleId in
            tm_role_watch(engine, workerId, cRoleId, { cbWorkerId, newClaudeMdPtr, reloadSeq, userdata in
                guard let userdata else {
                    Logger(subsystem: "com.teammux.app", category: "EngineClient")
                        .error("role_changed_cb: nil userdata for worker \(cbWorkerId) — pointer lifecycle bug")
                    return
                }

                // Copy string before crossing thread boundary — pointer is only
                // valid for the duration of this callback (watcher frees after return).
                let newClaudeMd: String? = {
                    guard let ptr = newClaudeMdPtr, ptr.pointee != 0 else { return nil }
                    return String(cString: ptr)
                }()

                let client = Unmanaged<EngineClient>.fromOpaque(userdata).takeUnretainedValue()
                Task { @MainActor in
                    client.handleRoleChanged(workerId: cbWorkerId, newClaudeMd: newClaudeMd, reloadSeq: reloadSeq)
                }
            }, selfPtr)
        }

        if result != TM_OK {
            let msg = lastEngineError() ?? "tm_role_watch failed (\(result.rawValue))"
            lastError = "Role hot-reload unavailable for worker \(workerId): \(msg)"
            Self.logger.error("startRoleWatch: \(msg) for worker \(workerId)")
        }
    }

    /// Stop watching the role file for a worker. Also cancels any pending
    /// dismiss timer and removes the worker from `hotReloadedWorkers`. Idempotent.
    /// Wraps `tm_role_unwatch()`.
    private func stopRoleWatch(workerId: UInt32) {
        hotReloadTimers[workerId]?.cancel()
        hotReloadTimers.removeValue(forKey: workerId)
        hotReloadedWorkers.removeValue(forKey: workerId)

        guard let engine else {
            Self.logger.warning("stopRoleWatch: engine is nil — cannot unwatch for worker \(workerId)")
            return
        }
        let result = tm_role_unwatch(engine, workerId)
        if result != TM_OK {
            let msg = lastEngineError() ?? "tm_role_unwatch failed (\(result.rawValue))"
            Self.logger.warning("stopRoleWatch: \(msg) for worker \(workerId)")
        }
    }

    /// Handle a role-changed callback on `@MainActor`. Injects a role-update
    /// notification with the updated CLAUDE.md content into the worker's PTY
    /// and shows a transient banner. Cancels any previous dismiss timer for
    /// the same worker to debounce rapid file saves.
    private func handleRoleChanged(workerId: UInt32, newClaudeMd: String?, reloadSeq: UInt64) {
        guard let newClaudeMd, !newClaudeMd.isEmpty else {
            let msg = "Role hot-reload failed for worker \(workerId) — the role file may contain syntax errors"
            Self.logger.error("handleRoleChanged: \(msg)")
            lastError = msg
            return
        }

        let text = "\n[Teammux] role-update: Your role definition has been updated.\n\(newClaudeMd)\n"
        injectText(text, for: workerId)

        // Cancel any previous dismiss timer for this worker (debounce rapid saves).
        // Store the engine's reload sequence number — incrementing ensures onChange
        // fires even when the worker is already in the dict (TD27).
        hotReloadTimers[workerId]?.cancel()
        hotReloadedWorkers[workerId] = reloadSeq

        hotReloadTimers[workerId] = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch is CancellationError {
                return
            } catch {
                Self.logger.warning("handleRoleChanged: sleep interrupted: \(error)")
                return
            }
            self.hotReloadedWorkers.removeValue(forKey: workerId)
            self.hotReloadTimers.removeValue(forKey: workerId)
        }
    }

    // MARK: - Private: Callbacks

    /// Register all engine callbacks. Called once after `sessionStart` succeeds.
    ///
    /// Each callback:
    /// 1. Extracts raw values from C structs (safe on any thread).
    /// 2. Gets `EngineClient` via `Unmanaged.passUnretained`.
    /// 3. Dispatches to `@MainActor` via `Task { @MainActor in ... }`.
    /// 4. Updates `@Published` properties on the main thread.
    private func setupCallbacks() {
        guard let engine else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // --- Roster changes ---
        rosterSubscription = tm_roster_watch(engine, { rosterPtr, userdata in
            guard let userdata else {
                Logger(subsystem: "com.teammux.app", category: "EngineClient").warning("roster_watch: nil userdata")
                return
            }
            guard let rosterPtr else {
                Logger(subsystem: "com.teammux.app", category: "EngineClient").warning("roster_watch: nil rosterPtr")
                return
            }

            // Copy all data from the C roster while we are on the callback thread.
            var workers: [WorkerInfo] = []
            let count = Int(rosterPtr.pointee.count)
            for i in 0..<count {
                let w = rosterPtr.pointee.workers[i]
                let info = WorkerInfo(
                    id: w.id,
                    name: String(cString: w.name),
                    taskDescription: String(cString: w.task_description),
                    branchName: String(cString: w.branch_name),
                    worktreePath: String(cString: w.worktree_path),
                    status: WorkerStatus(fromCValue: Int32(w.status.rawValue)),
                    agentType: AgentType(
                        fromCValue: Int32(w.agent_type.rawValue),
                        binaryName: String(cString: w.agent_binary)
                    ),
                    agentBinary: String(cString: w.agent_binary),
                    model: String(cString: w.model),
                    spawnedAt: Date(timeIntervalSince1970: TimeInterval(w.spawned_at)),
                    lastActivityTs: Date(timeIntervalSince1970: TimeInterval(w.last_activity_ts)),
                    healthStatus: HealthStatus(fromCValue: Int32(w.health_status.rawValue))
                )
                workers.append(info)
            }

            let client = Unmanaged<EngineClient>.fromOpaque(userdata).takeUnretainedValue()
            Task { @MainActor in
                client.roster = workers
            }
        }, selfPtr)

        // --- Message subscription ---
        // Callback returns tm_result_t: TM_OK (0) on success, non-zero on failure.
        // On failure the engine retries up to 3 times with exponential backoff.
        messageSubscription = tm_message_subscribe(engine, { messagePtr, userdata -> tm_result_t in
            // Nil guards return TM_OK: these are permanent setup issues (not transient),
            // so retrying would block the engine thread for 7s with no chance of recovery.
            guard let userdata else {
                Logger(subsystem: "com.teammux.app", category: "EngineClient").warning("message_subscribe: nil userdata")
                return TM_OK
            }
            guard let messagePtr else {
                Logger(subsystem: "com.teammux.app", category: "EngineClient").warning("message_subscribe: nil messagePtr")
                return TM_OK
            }

            // Copy all data while on the callback thread — C pointers are
            // only valid for the duration of this callback invocation.
            let rawType = messagePtr.pointee.type.rawValue
            let from = messagePtr.pointee.from
            let to = messagePtr.pointee.to
            let type = MessageType(fromCValue: Int32(rawType))
            let payload = String(cString: messagePtr.pointee.payload)
            let timestamp = Date(timeIntervalSince1970: TimeInterval(messagePtr.pointee.timestamp))
            let seq = messagePtr.pointee.seq
            let gitCommit: String? = {
                let ptr = messagePtr.pointee.git_commit
                guard let ptr, ptr.pointee != 0 else { return nil }
                return String(cString: ptr)
            }()

            let client = Unmanaged<EngineClient>.fromOpaque(userdata).takeUnretainedValue()
            Task { @MainActor in
                let msg = TeamMessage(
                    from: from,
                    to: to,
                    type: type,
                    payload: payload,
                    timestamp: timestamp,
                    seq: seq,
                    gitCommit: gitCommit
                )
                client.messages.append(msg)

                // Route to workerCompletions / workerQuestions / peerQuestions / peerDelegations / workerPRs
                if type == .completion {
                    client.handleCompletionMessage(from: from, payload: payload, timestamp: timestamp, gitCommit: gitCommit)
                } else if type == .question {
                    client.handleQuestionMessage(from: from, payload: payload, timestamp: timestamp)
                } else if type == .peerQuestion {
                    client.handlePeerQuestionMessage(from: from, payload: payload, timestamp: timestamp)
                } else if type == .delegation {
                    client.handleDelegationMessage(from: from, payload: payload, timestamp: timestamp)
                } else if type == .prReady {
                    client.handlePRReadyMessage(payload: payload, timestamp: timestamp)
                } else if type == .prStatus {
                    client.handlePRStatusMessage(payload: payload)
                } else if type == .healthStalled {
                    // Roster refresh picks up the new health_status
                    client.refreshRoster()
                }
            }
            return TM_OK
        }, selfPtr)

        // --- Command interception (/teammux-*) ---
        commandSubscription = tm_commands_watch(engine, { commandPtr, argsPtr, userdata in
            guard let userdata else {
                Logger(subsystem: "com.teammux.app", category: "EngineClient").warning("commands_watch: nil userdata")
                return
            }

            // Copy strings before crossing thread boundary.
            let command: String = {
                guard let commandPtr else { return "" }
                return String(cString: commandPtr)
            }()
            let argsJson: String = {
                guard let argsPtr else { return "{}" }
                return String(cString: argsPtr)
            }()

            let client = Unmanaged<EngineClient>.fromOpaque(userdata).takeUnretainedValue()
            Task { @MainActor in
                client.handleCommand(command, argsJson: argsJson)
            }
        }, selfPtr)

        // --- GitHub webhooks ---
        githubSubscription = tm_github_webhooks_start(engine, { eventTypePtr, payloadPtr, userdata in
            guard let userdata else {
                Logger(subsystem: "com.teammux.app", category: "EngineClient").warning("github_webhooks: nil userdata")
                return
            }

            let eventType: String = {
                guard let eventTypePtr else { return "" }
                return String(cString: eventTypePtr)
            }()
            let payloadJson: String = {
                guard let payloadPtr else { return "{}" }
                return String(cString: payloadPtr)
            }()

            let client = Unmanaged<EngineClient>.fromOpaque(userdata).takeUnretainedValue()
            Task { @MainActor in
                client.handleGitHubEvent(eventType, payload: payloadJson)
            }
        }, selfPtr)

        // --- Config watcher ---
        configSubscription = tm_config_watch(engine, { userdata in
            guard let userdata else {
                Logger(subsystem: "com.teammux.app", category: "EngineClient").warning("config_watch: nil userdata")
                return
            }

            let client = Unmanaged<EngineClient>.fromOpaque(userdata).takeUnretainedValue()
            Task { @MainActor in
                client.reloadConfig()
            }
        }, selfPtr)
    }

    /// Unsubscribe/unwatch all callbacks. Called before `tm_session_stop()`.
    /// Also stops all per-worker role file watches to prevent dangling callbacks.
    private func teardownCallbacks() {
        guard let engine else { return }

        // Stop all role file watches before tearing down other callbacks.
        // Each watch holds a selfPtr that becomes dangling after teardown.
        for workerId in workerRoles.keys {
            let result = tm_role_unwatch(engine, workerId)
            if result != TM_OK {
                let msg = lastEngineError() ?? "tm_role_unwatch failed (\(result.rawValue))"
                Self.logger.warning("teardownCallbacks: \(msg) for worker \(workerId)")
            }
        }
        // Cancel all pending banner dismiss timers.
        for (_, task) in hotReloadTimers { task.cancel() }
        hotReloadTimers.removeAll()

        if rosterSubscription != 0 {
            tm_roster_unwatch(engine, rosterSubscription)
            rosterSubscription = 0
        }
        if messageSubscription != 0 {
            tm_message_unsubscribe(engine, messageSubscription)
            messageSubscription = 0
        }
        if commandSubscription != 0 {
            tm_commands_unwatch(engine, commandSubscription)
            commandSubscription = 0
        }
        if githubSubscription != 0 {
            tm_github_webhooks_stop(engine, githubSubscription)
            githubSubscription = 0
        }
        if configSubscription != 0 {
            tm_config_unwatch(engine, configSubscription)
            configSubscription = 0
        }
    }

    // MARK: - Private: Command handler

    /// Dispatch `/teammux-*` commands received from the engine's
    /// command interception callback.
    private func handleCommand(_ command: String, argsJson: String) {
        let args = parseArgsJson(argsJson)

        switch command {
        case "/teammux-add":
            guard let task = args["task"], !task.isEmpty else {
                lastError = "/teammux-add: missing or empty task"
                Self.logger.error("/teammux-add: missing or empty task")
                return
            }
            let binary = args["binary"] ?? "claude"
            let agentTypeRaw = Int32(args["agent_type"] ?? "0") ?? 0
            let agentType = AgentType(fromCValue: agentTypeRaw)
            let name = args["name"] ?? "Worker"
            let role: String? = {
                guard let r = args["role"], !r.isEmpty else { return nil }
                return r
            }()
            let workerId = spawnWorker(
                agentBinary: binary,
                agentType: agentType,
                workerName: name,
                taskDescription: task,
                roleId: role
            )
            if workerId == 0 {
                Self.logger.error("handleCommand /teammux-add: spawnWorker returned 0")
            }

        case "/teammux-remove":
            if let idStr = args["worker_id"], let workerId = UInt32(idStr) {
                let success = dismissWorker(workerId)
                if !success {
                    Self.logger.error("handleCommand /teammux-remove: dismissWorker failed for \(workerId)")
                }
            } else {
                lastError = "/teammux-remove: missing or invalid worker_id"
                Self.logger.error("/teammux-remove: missing or invalid worker_id")
            }

        case "/teammux-message":
            if let toStr = args["to"],
               let to = UInt32(toStr),
               let typeStr = args["type"],
               let typeRaw = Int(typeStr),
               let type = MessageType(rawValue: typeRaw) {
                let payload = args["payload"] ?? ""
                let success = sendMessage(to: to, type: type, payload: payload)
                if !success {
                    Self.logger.error("handleCommand /teammux-message: sendMessage failed")
                }
            } else {
                lastError = "/teammux-message: missing to, type, or payload"
                Self.logger.error("/teammux-message: missing to, type, or payload")
            }

        case "/teammux-broadcast":
            if let typeStr = args["type"],
               let typeRaw = Int(typeStr),
               let type = MessageType(rawValue: typeRaw) {
                let payload = args["payload"] ?? ""
                let success = broadcastMessage(type: type, payload: payload)
                if !success {
                    Self.logger.error("handleCommand /teammux-broadcast: broadcastMessage failed")
                }
            } else {
                lastError = "/teammux-broadcast: missing type"
                Self.logger.error("/teammux-broadcast: missing type")
            }

        default:
            lastError = "Unknown command: \(command)"
            Self.logger.error("Unknown command: \(command)")
        }
    }

    // MARK: - Private: GitHub event handler

    /// Handle GitHub webhook events (PR status changes, check runs, etc.).
    private func handleGitHubEvent(_ eventType: String, payload: String) {
        switch eventType {
        case "pull_request":
            Self.logger.debug("Received pull_request event")
        default:
            Self.logger.debug("Unhandled GitHub event type: \(eventType)")
        }
    }

    // MARK: - Private: Text injection

    /// Inject text into a worker's PTY via the registered injector closure.
    /// Logs a warning and returns without action if no injector is registered.
    private func injectText(_ text: String, for workerId: UInt32) {
        guard let injector = textInjectors[workerId] else {
            Self.logger.warning("injectText: no injector registered for worker \(workerId)")
            return
        }
        injector(text)
    }

    // MARK: - Private: Helpers

    /// Retrieve the last error string from the engine, if any.
    private func lastEngineError() -> String? {
        guard let engine else { return nil }
        guard let cStr = tm_engine_last_error(engine) else { return nil }
        let str = String(cString: cStr)
        return str.isEmpty ? nil : str
    }

    /// Minimal JSON object parser for command args.
    /// Handles flat `{"key": "value", ...}` objects without pulling in
    /// full `JSONSerialization` (which may fail on non-UTF8 engine output).
    private func parseArgsJson(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8) else { return [:] }
        do {
            if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var result: [String: String] = [:]
                for (key, value) in dict {
                    if let strValue = value as? String {
                        result[key] = strValue
                    } else {
                        result[key] = "\(value)"
                    }
                }
                return result
            }
        } catch {
            lastError = "Failed to parse command args: \(error.localizedDescription)"
            Self.logger.error("Failed to parse command args: \(error.localizedDescription)")
            return [:]
        }
        return [:]
    }

    // MARK: - Private: Merge status polling

    /// Start a 2-second repeating timer to poll merge statuses.
    /// No-op if already running.
    private func startMergePolling() {
        guard mergeStatusTimer == nil else { return }
        mergeStatusTimer = Timer.scheduledTimer(
            withTimeInterval: 2.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pollMergeStatuses()
            }
        }
    }

    /// Stop and invalidate the merge polling timer.
    private func stopMergePolling() {
        mergeStatusTimer?.invalidate()
        mergeStatusTimer = nil
    }

    /// Polls `tm_merge_get_status()` for all workers tracked in `mergeStatuses`.
    /// Updates `mergeStatuses` and `pendingConflicts` @Published properties.
    /// Stops the timer when no tracked worker has `.inProgress` status.
    private func pollMergeStatuses() {
        guard engine != nil else {
            stopMergePolling()
            return
        }

        var hasInProgress = false
        let trackedWorkers = Array(mergeStatuses.keys)
        for workerId in trackedWorkers {
            let status = getMergeStatus(workerId: workerId)
            mergeStatuses[workerId] = status

            if status == .conflict {
                pendingConflicts[workerId] = getConflicts(workerId: workerId)
            } else {
                pendingConflicts.removeValue(forKey: workerId)
            }

            if status == .inProgress {
                hasInProgress = true
            }
        }

        if !hasInProgress {
            stopMergePolling()
        }
    }

    // MARK: - Coordination

    /// Remove the completion report for a worker after the Team Lead acknowledges it.
    /// Idempotent — safe to call if no report exists for the worker.
    func acknowledgeCompletion(workerId: UInt32) {
        if workerCompletions.removeValue(forKey: workerId) == nil {
            Self.logger.warning("acknowledgeCompletion: no active completion for worker \(workerId)")
        }
    }

    /// Remove the question for a worker after the Team Lead dismisses or responds.
    /// Idempotent — safe to call if no question exists for the worker.
    func clearQuestion(workerId: UInt32) {
        if workerQuestions.removeValue(forKey: workerId) == nil {
            Self.logger.warning("clearQuestion: no active question for worker \(workerId)")
        }
    }

    // MARK: - Coordinator

    /// Dispatch a task instruction to a specific worker.
    /// Wraps `tm_dispatch_task()`. Returns `true` if the engine accepted the dispatch.
    /// On failure, sets `lastError` with a diagnostic message.
    /// On success, refreshes `dispatchHistory` from the engine.
    func dispatchTask(workerId: UInt32, instruction: String) -> Bool {
        lastError = nil
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("dispatchTask: engine not created")
            return false
        }

        let result = instruction.withCString { cInstruction in
            tm_dispatch_task(engine, workerId, cInstruction)
        }

        guard result == TM_OK else {
            let msg = lastEngineError() ?? "tm_dispatch_task failed (\(result.rawValue))"
            lastError = msg
            Self.logger.error("dispatchTask failed for worker \(workerId): \(msg)")
            return false
        }

        refreshDispatchHistory()
        Self.logger.info("dispatchTask: dispatched to worker \(workerId)")
        return true
    }

    /// Dispatch a response to a specific worker (e.g. answering a question).
    /// Wraps `tm_dispatch_response()`. Returns `true` if the engine accepted the dispatch.
    /// On failure, sets `lastError` with a diagnostic message.
    /// On success, refreshes `dispatchHistory` from the engine.
    func dispatchResponse(workerId: UInt32, response: String) -> Bool {
        lastError = nil
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("dispatchResponse: engine not created")
            return false
        }

        let result = response.withCString { cResponse in
            tm_dispatch_response(engine, workerId, cResponse)
        }

        guard result == TM_OK else {
            let msg = lastEngineError() ?? "tm_dispatch_response failed (\(result.rawValue))"
            lastError = msg
            Self.logger.error("dispatchResponse failed for worker \(workerId): \(msg)")
            return false
        }

        refreshDispatchHistory()
        Self.logger.info("dispatchResponse: dispatched to worker \(workerId)")
        return true
    }

    /// Refresh `dispatchHistory` from the engine's coordinator.
    /// Wraps `tm_dispatch_history()` (and `tm_dispatch_history_free()` when
    /// the engine returns a non-NULL result). On failure, sets `lastError`.
    /// Called internally after each dispatch; also available for UI refresh
    /// (e.g. when the Dispatch tab appears).
    func refreshDispatchHistory() {
        lastError = nil
        guard let engine else {
            Self.logger.warning("refreshDispatchHistory: engine not created")
            return
        }

        var count: UInt32 = 0
        guard let eventsPtr = tm_dispatch_history(engine, &count) else {
            if let msg = lastEngineError() {
                lastError = msg
                Self.logger.error("refreshDispatchHistory: tm_dispatch_history failed: \(msg)")
            } else {
                Self.logger.info("refreshDispatchHistory: no dispatch history")
            }
            dispatchHistory = []
            return
        }

        guard count > 0 else {
            tm_dispatch_history_free(eventsPtr, count)
            dispatchHistory = []
            return
        }

        var events: [DispatchEvent] = []
        for i in 0..<Int(count) {
            guard let ptr = eventsPtr[i] else {
                Self.logger.warning("refreshDispatchHistory: NULL event at index \(i) of \(count) — skipping")
                continue
            }
            let instruction: String = {
                guard let p = ptr.pointee.instruction, p.pointee != 0 else {
                    Self.logger.warning("refreshDispatchHistory: NULL instruction at index \(i)")
                    return ""
                }
                return String(cString: p)
            }()
            let event = DispatchEvent(
                targetWorkerId: ptr.pointee.target_worker_id,
                instruction: instruction,
                timestamp: Date(timeIntervalSince1970: TimeInterval(ptr.pointee.timestamp)),
                delivered: ptr.pointee.delivered,
                kind: DispatchKind(rawValue: ptr.pointee.kind) ?? .task
            )
            events.append(event)
        }

        tm_dispatch_history_free(eventsPtr, count)

        // Defensive cap — engine caps at 100 internally, but enforce here too.
        if events.count > 100 {
            events = Array(events.suffix(100))
        }

        dispatchHistory = events
    }

    // MARK: - Private: Completion History

    /// Load all history entries from the engine's JSONL log and seed
    /// `workerCompletions` / `workerQuestions` for workers with no live entry.
    /// Called once during `sessionStart()`.
    private func loadAndSeedHistory() {
        let entries = loadCompletionHistory()
        completionHistory = entries

        // Seed workerCompletions from the most recent .completion per worker.
        // Live entries (arriving via message bus) will overwrite these.
        var seenCompletions = Set<UInt32>()
        for entry in entries where entry.type == .completion {
            guard !seenCompletions.contains(entry.workerId) else { continue }
            seenCompletions.insert(entry.workerId)
            if workerCompletions[entry.workerId] == nil {
                workerCompletions[entry.workerId] = CompletionReport(
                    workerId: entry.workerId,
                    summary: entry.content,
                    gitCommit: entry.gitCommit,
                    timestamp: entry.timestamp
                )
            }
        }

        // Seed workerQuestions from the most recent .question per worker.
        var seenQuestions = Set<UInt32>()
        for entry in entries where entry.type == .question {
            guard !seenQuestions.contains(entry.workerId) else { continue }
            seenQuestions.insert(entry.workerId)
            if workerQuestions[entry.workerId] == nil {
                workerQuestions[entry.workerId] = QuestionRequest(
                    workerId: entry.workerId,
                    question: entry.content,
                    timestamp: entry.timestamp
                )
            }
        }

        Self.logger.info("loadAndSeedHistory: loaded \(entries.count) history entries, seeded \(seenCompletions.count) completions and \(seenQuestions.count) questions")
    }

    /// Bridge `tm_history_load` → `[HistoryEntry]`, sorted newest-first.
    /// Returns an empty array when the engine returns NULL (no file or no entries).
    private func loadCompletionHistory() -> [HistoryEntry] {
        guard let engine else {
            Self.logger.warning("loadCompletionHistory: engine not created")
            return []
        }

        var count: UInt32 = 0
        guard let entriesPtr = tm_history_load(engine, &count) else {
            if let msg = lastEngineError() {
                Self.logger.error("loadCompletionHistory: tm_history_load failed: \(msg)")
            }
            return []
        }

        var entries: [HistoryEntry] = []
        for i in 0..<Int(count) {
            guard let ptr = entriesPtr[i] else {
                Self.logger.warning("loadCompletionHistory: NULL entry at index \(i) of \(count) — skipping")
                continue
            }

            let typeStr = String(cString: ptr.pointee.type)
            guard let entryType = HistoryEntryType(rawValue: typeStr) else {
                Self.logger.warning("loadCompletionHistory: unknown entry type '\(typeStr)' at index \(i) — skipping")
                continue
            }

            let roleId: String? = {
                let s = String(cString: ptr.pointee.role_id)
                return s.isEmpty ? nil : s
            }()

            let gitCommit: String? = {
                guard let p = ptr.pointee.git_commit, p.pointee != 0 else { return nil }
                return String(cString: p)
            }()

            let entry = HistoryEntry(
                type: entryType,
                workerId: ptr.pointee.worker_id,
                roleId: roleId,
                content: String(cString: ptr.pointee.content),
                gitCommit: gitCommit,
                timestamp: Date(timeIntervalSince1970: Double(ptr.pointee.timestamp))
            )
            entries.append(entry)
        }

        tm_history_free(entriesPtr, count)

        // Sort newest-first for display
        entries.sort { $0.timestamp > $1.timestamp }
        return entries
    }

    // MARK: - Agent memory (S13)

    /// Append a memory entry for a worker. Constructs a summary string from
    /// the completion report and worker metadata, then delegates to the engine.
    func memoryAppend(workerId: UInt32, completion: CompletionReport) {
        guard let engine else {
            Self.logger.warning("memoryAppend: engine not created")
            return
        }

        // Build summary from available data
        var lines: [String] = []

        // Task description from roster
        if let worker = roster.first(where: { $0.id == workerId }) {
            lines.append("**Task:** \(worker.taskDescription)")
        }

        lines.append("**Summary:** \(completion.summary)")

        if let details = completion.details, !details.isEmpty {
            lines.append("**Details:** \(details)")
        }

        if let commit = completion.gitCommit, !commit.isEmpty {
            lines.append("**Commit:** \(commit)")
        }

        // PR info if available
        if let pr = workerPRs[workerId], !pr.prUrl.isEmpty {
            lines.append("**PR:** \(pr.prUrl)")
        }

        let summary = lines.joined(separator: "\n")

        let result = summary.withCString { cSummary in
            tm_memory_append(engine, workerId, cSummary)
        }
        if result != TM_OK {
            let engineMsg = lastEngineError() ?? "unknown error"
            Self.logger.warning("memoryAppend failed for worker \(workerId): \(engineMsg)")
        } else {
            // Refresh cached memory content
            loadWorkerMemory(workerId: workerId)
        }
    }

    /// Read the memory file content for a worker.
    func memoryRead(workerId: UInt32) -> String? {
        guard let engine else {
            Self.logger.warning("memoryRead: engine not created")
            return nil
        }

        guard let cStr = tm_memory_read(engine, workerId) else {
            // Distinguish "no file" (no last error) from read failure
            if let errMsg = lastEngineError() {
                Self.logger.warning("memoryRead failed for worker \(workerId): \(errMsg)")
            }
            return nil
        }
        let content = String(cString: cStr)
        tm_memory_free(cStr)
        return content.isEmpty ? nil : content
    }

    /// Load memory file for a specific worker and update the published dictionary.
    /// Clears the cached entry if the file no longer exists or is empty.
    func loadWorkerMemory(workerId: UInt32) {
        workerMemory[workerId] = memoryRead(workerId: workerId)
    }

    /// Load memory files for all workers with worktrees.
    private func loadAllWorkerMemory() {
        for (workerId, _) in workerWorktrees {
            loadWorkerMemory(workerId: workerId)
        }
    }

    // MARK: - Private: Coordination handlers

    /// Parse a TM_MSG_COMPLETION payload and update `workerCompletions`.
    /// Payload format: `{"summary": "...", "details": "...", "git_commit": "..."}`
    /// Worker ID comes from the message envelope (`from` field), not the payload.
    private func handleCompletionMessage(from workerId: UInt32, payload: String, timestamp: Date, gitCommit: String?) {
        guard let data = payload.data(using: .utf8) else {
            let msg = "handleCompletionMessage: payload is not valid UTF-8 for worker \(workerId)"
            Self.logger.error("\(msg)")
            lastError = msg
            return
        }

        do {
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let msg = "handleCompletionMessage: payload is not a JSON object for worker \(workerId)"
                Self.logger.error("\(msg)")
                lastError = msg
                return
            }

            guard let summary = dict["summary"] as? String, !summary.isEmpty else {
                let msg = "handleCompletionMessage: missing or empty summary for worker \(workerId)"
                Self.logger.warning("\(msg)")
                lastError = msg
                return
            }
            let details = dict["details"] as? String
            let payloadGitCommit = dict["git_commit"] as? String

            if let existing = workerCompletions[workerId] {
                Self.logger.warning("handleCompletionMessage: overwriting unacknowledged completion for worker \(workerId), previous summary: \(existing.summary)")
            }

            let report = CompletionReport(
                workerId: workerId,
                summary: summary,
                gitCommit: payloadGitCommit ?? gitCommit,
                details: details,
                timestamp: timestamp
            )
            workerCompletions[workerId] = report
            memoryAppend(workerId: workerId, completion: report)
            triggerAutonomousDispatch(for: report)
        } catch {
            let msg = "handleCompletionMessage: JSON parse failed for worker \(workerId): \(error.localizedDescription)"
            Self.logger.error("\(msg)")
            lastError = msg
        }
    }

    /// Parse a TM_MSG_QUESTION payload and update `workerQuestions`.
    /// Payload format: `{"question": "...", "context": "..."}`
    /// Worker ID comes from the message envelope (`from` field), not the payload.
    private func handleQuestionMessage(from workerId: UInt32, payload: String, timestamp: Date) {
        guard let data = payload.data(using: .utf8) else {
            let msg = "handleQuestionMessage: payload is not valid UTF-8 for worker \(workerId)"
            Self.logger.error("\(msg)")
            lastError = msg
            return
        }

        do {
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let msg = "handleQuestionMessage: payload is not a JSON object for worker \(workerId)"
                Self.logger.error("\(msg)")
                lastError = msg
                return
            }

            guard let question = dict["question"] as? String, !question.isEmpty else {
                let msg = "handleQuestionMessage: missing or empty question for worker \(workerId)"
                Self.logger.warning("\(msg)")
                lastError = msg
                return
            }
            let context = dict["context"] as? String

            if let existing = workerQuestions[workerId] {
                Self.logger.warning("handleQuestionMessage: overwriting unanswered question for worker \(workerId), previous question: \(existing.question)")
            }

            let request = QuestionRequest(
                workerId: workerId,
                question: question,
                context: context,
                timestamp: timestamp
            )
            workerQuestions[workerId] = request
        } catch {
            let msg = "handleQuestionMessage: JSON parse failed for worker \(workerId): \(error.localizedDescription)"
            Self.logger.error("\(msg)")
            lastError = msg
        }
    }

    // MARK: - Peer Messaging

    /// Remove the peer question from a specific sending worker after the Team Lead
    /// relays or dismisses it. Idempotent — safe to call if no question exists.
    func clearPeerQuestion(fromWorkerId: UInt32) {
        if peerQuestions.removeValue(forKey: fromWorkerId) == nil {
            Self.logger.warning("clearPeerQuestion: no active peer question from worker \(fromWorkerId)")
        }
    }

    /// Parse a TM_MSG_PEER_QUESTION payload and update `peerQuestions`.
    /// Payload format: `{"worker_id": N, "target_worker_id": M, "message": "..."}`
    /// Worker ID comes from the message envelope (`from` field), consistent with
    /// `handleCompletionMessage` / `handleQuestionMessage`. Payload `worker_id`
    /// is cross-validated but not authoritative.
    private func handlePeerQuestionMessage(from envelopeFrom: UInt32, payload: String, timestamp: Date) {
        guard let data = payload.data(using: .utf8) else {
            let msg = "handlePeerQuestionMessage: payload is not valid UTF-8 for worker \(envelopeFrom)"
            Self.logger.error("\(msg)")
            lastError = msg
            return
        }

        do {
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let msg = "handlePeerQuestionMessage: payload is not a JSON object for worker \(envelopeFrom)"
                Self.logger.error("\(msg)")
                lastError = msg
                return
            }

            // Cross-validate payload worker_id against envelope from
            if let payloadWorkerId = (dict["worker_id"] as? Int).flatMap({ UInt32(exactly: $0) }),
               payloadWorkerId != envelopeFrom {
                Self.logger.warning("handlePeerQuestionMessage: payload worker_id \(payloadWorkerId) does not match envelope from \(envelopeFrom)")
            }

            guard let targetWorkerId = (dict["target_worker_id"] as? Int).flatMap({ UInt32(exactly: $0) }) else {
                let msg = "handlePeerQuestionMessage: missing or invalid target_worker_id for worker \(envelopeFrom)"
                Self.logger.error("\(msg)")
                lastError = msg
                return
            }
            guard let message = dict["message"] as? String, !message.isEmpty else {
                let msg = "handlePeerQuestionMessage: missing or empty message for worker \(envelopeFrom)"
                Self.logger.error("\(msg)")
                lastError = msg
                return
            }

            if let existing = peerQuestions[envelopeFrom] {
                Self.logger.warning("handlePeerQuestionMessage: overwriting unrelayed peer question from worker \(envelopeFrom), previous message: \(existing.message)")
            }

            let question = PeerQuestion(
                fromWorkerId: envelopeFrom,
                targetWorkerId: targetWorkerId,
                message: message,
                timestamp: timestamp
            )
            peerQuestions[envelopeFrom] = question
        } catch {
            let msg = "handlePeerQuestionMessage: JSON parse failed for worker \(envelopeFrom): \(error.localizedDescription)"
            Self.logger.error("\(msg)")
            lastError = msg
        }
    }

    /// Parse a TM_MSG_DELEGATION payload and append to `peerDelegations`.
    /// Payload format: `{"worker_id": N, "target_worker_id": M, "task": "..."}`
    /// Capped at 100 entries — oldest trimmed when exceeding.
    /// Worker ID comes from the message envelope (`from` field), consistent with
    /// other coordination handlers.
    private func handleDelegationMessage(from envelopeFrom: UInt32, payload: String, timestamp: Date) {
        guard let data = payload.data(using: .utf8) else {
            let msg = "handleDelegationMessage: payload is not valid UTF-8 for worker \(envelopeFrom)"
            Self.logger.error("\(msg)")
            lastError = msg
            return
        }

        do {
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let msg = "handleDelegationMessage: payload is not a JSON object for worker \(envelopeFrom)"
                Self.logger.error("\(msg)")
                lastError = msg
                return
            }

            // Cross-validate payload worker_id against envelope from
            if let payloadWorkerId = (dict["worker_id"] as? Int).flatMap({ UInt32(exactly: $0) }),
               payloadWorkerId != envelopeFrom {
                Self.logger.warning("handleDelegationMessage: payload worker_id \(payloadWorkerId) does not match envelope from \(envelopeFrom)")
            }

            guard let targetWorkerId = (dict["target_worker_id"] as? Int).flatMap({ UInt32(exactly: $0) }) else {
                let msg = "handleDelegationMessage: missing or invalid target_worker_id for worker \(envelopeFrom)"
                Self.logger.error("\(msg)")
                lastError = msg
                return
            }
            guard let task = dict["task"] as? String, !task.isEmpty else {
                let msg = "handleDelegationMessage: missing or empty task for worker \(envelopeFrom)"
                Self.logger.error("\(msg)")
                lastError = msg
                return
            }

            let delegation = PeerDelegation(
                fromWorkerId: envelopeFrom,
                targetWorkerId: targetWorkerId,
                task: task,
                timestamp: timestamp
            )
            peerDelegations.append(delegation)

            // Cap at 100 — trim oldest when exceeding
            if peerDelegations.count > 100 {
                peerDelegations.removeFirst(peerDelegations.count - 100)
            }
        } catch {
            let msg = "handleDelegationMessage: JSON parse failed for worker \(envelopeFrom): \(error.localizedDescription)"
            Self.logger.error("\(msg)")
            lastError = msg
        }
    }

    // MARK: - PR Workflow

    /// Parse a TM_MSG_PR_READY payload and upsert into `workerPRs`.
    /// Payload format: Required: `worker_id`, `pr_url`. Optional: `branch`, `title`.
    private func handlePRReadyMessage(payload: String, timestamp: Date) {
        guard let data = payload.data(using: .utf8) else {
            let msg = "handlePRReadyMessage: payload is not valid UTF-8"
            Self.logger.error("\(msg)")
            lastError = msg
            return
        }

        do {
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let msg = "handlePRReadyMessage: payload is not a JSON object"
                Self.logger.error("\(msg)")
                lastError = msg
                return
            }

            guard let workerId: UInt32 = {
                if let id = dict["worker_id"] as? UInt32 { return id }
                if let id = dict["worker_id"] as? Int, id >= 0, id <= Int(UInt32.max) {
                    return UInt32(id)
                }
                return nil
            }() else {
                let msg = "handlePRReadyMessage: missing or invalid worker_id"
                Self.logger.error("\(msg)")
                lastError = msg
                return
            }

            guard let prUrl = dict["pr_url"] as? String, !prUrl.isEmpty else {
                let msg = "handlePRReadyMessage: missing or empty pr_url for worker \(workerId)"
                Self.logger.warning("\(msg)")
                lastError = msg
                return
            }

            let branch = dict["branch"] as? String ?? ""
            if branch.isEmpty {
                Self.logger.warning("handlePRReadyMessage: missing branch for worker \(workerId), PR card will show degraded info")
            }
            let title = dict["title"] as? String ?? ""
            if title.isEmpty {
                Self.logger.warning("handlePRReadyMessage: missing title for worker \(workerId), PR card will show degraded info")
            }

            if let existing = workerPRs[workerId] {
                Self.logger.warning("handlePRReadyMessage: overwriting existing PR for worker \(workerId), previous URL: \(existing.prUrl)")
            }

            let prEvent = PREvent(
                id: workerPRs[workerId]?.id ?? UUID(),
                workerId: workerId,
                branchName: branch,
                prUrl: prUrl,
                title: title,
                status: .open,
                timestamp: timestamp
            )
            workerPRs[workerId] = prEvent
        } catch {
            let msg = "handlePRReadyMessage: JSON parse failed: \(error.localizedDescription)"
            Self.logger.error("\(msg)")
            lastError = msg
        }
    }

    /// Parse a TM_MSG_PR_STATUS payload and update the status on an existing PREvent,
    /// or create a minimal PREvent if none exists yet (e.g. webhook fires before PR_READY).
    /// Payload format: Required: `worker_id`, `status`. Optional: `pr_url`.
    private func handlePRStatusMessage(payload: String) {
        guard let data = payload.data(using: .utf8) else {
            let msg = "handlePRStatusMessage: payload is not valid UTF-8"
            Self.logger.error("\(msg)")
            lastError = msg
            return
        }

        do {
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let msg = "handlePRStatusMessage: payload is not a JSON object"
                Self.logger.error("\(msg)")
                lastError = msg
                return
            }

            guard let workerId: UInt32 = {
                if let id = dict["worker_id"] as? UInt32 { return id }
                if let id = dict["worker_id"] as? Int, id >= 0, id <= Int(UInt32.max) {
                    return UInt32(id)
                }
                return nil
            }() else {
                let msg = "handlePRStatusMessage: missing or invalid worker_id"
                Self.logger.error("\(msg)")
                lastError = msg
                return
            }

            guard let statusStr = dict["status"] as? String,
                  let newStatus = PRStatus(rawValue: statusStr) else {
                let msg = "handlePRStatusMessage: missing or invalid status for worker \(workerId)"
                Self.logger.warning("\(msg)")
                lastError = msg
                return
            }

            if workerPRs[workerId] != nil {
                workerPRs[workerId]?.status = newStatus
            } else {
                // PR_STATUS arrived before PR_READY (possible if webhook fires first).
                // Create a minimal PREvent so the status is not lost.
                let prUrl = dict["pr_url"] as? String ?? ""
                let prEvent = PREvent(
                    workerId: workerId,
                    branchName: "",
                    prUrl: prUrl,
                    title: "",
                    status: newStatus,
                    timestamp: Date()
                )
                workerPRs[workerId] = prEvent
                Self.logger.warning("handlePRStatusMessage: created stub PREvent from status update for worker \(workerId) (status: \(newStatus.rawValue)), PR_READY not yet received — card will show degraded info")
            }
        } catch {
            let msg = "handlePRStatusMessage: JSON parse failed: \(error.localizedDescription)"
            Self.logger.error("\(msg)")
            lastError = msg
        }
    }

    // MARK: - Autonomous Dispatch

    /// Immediately dispatch a follow-up task for a completed worker.
    /// Called inline from `handleCompletionMessage` after
    /// `workerCompletions[workerId]` is set — no human approval step,
    /// no cancel window. Fully autonomous Team Lead behavior.
    ///
    /// Saves and restores `lastError` around the dispatch call so the
    /// autonomous path does not clobber error state from unrelated operations.
    private func triggerAutonomousDispatch(for completion: CompletionReport) {
        let role = workerRoles[completion.workerId]
        let instruction = suggestFollowUp(completion: completion, role: role)

        let now = Date()
        let dispatch = AutonomousDispatch(
            workerId: completion.workerId,
            instruction: instruction,
            triggerSummary: completion.summary,
            timestamp: now
        )

        // Save lastError so the autonomous dispatch path does not clobber
        // error state from a prior manual operation.
        let savedError = lastError

        // Call tm_dispatch_task directly — bypass dispatchTask() to avoid
        // the refreshDispatchHistory() bridge round-trip (I16).
        guard let engine else {
            Self.logger.error("triggerAutonomousDispatch: engine not created")
            lastError = savedError
            return
        }

        let result = instruction.withCString { cInstruction in
            tm_dispatch_task(engine, completion.workerId, cInstruction)
        }

        let success = result == TM_OK
        if success {
            if let existing = autonomousDispatches[completion.workerId] {
                Self.logger.warning("triggerAutonomousDispatch: overwriting prior auto-dispatch for worker \(completion.workerId), previous: \(existing.instruction)")
            }
            autonomousDispatches[completion.workerId] = dispatch

            // Construct DispatchEvent locally instead of bridge reload (I16).
            // delivered is optimistic — the coordinator may have recorded
            // delivered=false if bus retry exhausted (I7). The Dispatch tab
            // calls refreshDispatchHistory() on appear for reconciliation.
            let event = DispatchEvent(
                targetWorkerId: completion.workerId,
                instruction: instruction,
                timestamp: now,
                delivered: true,
                kind: .task
            )
            dispatchHistory.append(event)

            Self.logger.info("triggerAutonomousDispatch: auto-dispatched to worker \(completion.workerId): \(instruction)")
        } else {
            let engineError = lastEngineError() ?? "unknown engine error"
            Self.logger.error("triggerAutonomousDispatch: dispatch failed for worker \(completion.workerId), instruction: \(instruction), error: \(engineError)")
        }

        // Restore lastError — autonomous dispatch should not corrupt
        // user-visible error state from unrelated operations.
        lastError = savedError
    }

    /// Deterministic heuristic for follow-up task suggestion based on
    /// completion summary keywords. No LLM — pure keyword matching.
    /// `role` parameter unused in current implementation; reserved for
    /// future role-aware differentiation.
    private func suggestFollowUp(completion: CompletionReport, role: RoleDefinition?) -> String {
        let summary = completion.summary.lowercased()

        if summary.contains("implement") || summary.contains("built") || summary.contains("added") {
            return "Review the implementation and write tests"
        }
        if summary.contains("fix") || summary.contains("bug") || summary.contains("patch") {
            return "Verify the fix resolves the issue and add a regression test"
        }
        if summary.contains("refactor") || summary.contains("restructure") {
            return "Verify all existing tests pass after the refactor"
        }
        if summary.contains("test") || summary.contains("spec") {
            return "Review test coverage and identify any gaps"
        }
        return "Review the completed work and confirm it meets requirements"
    }

    deinit {
        // Callers must call destroy() before dropping the last reference.
        // We cannot safely call tm_* functions from deinit (non-MainActor context).
        #if DEBUG
        if engine != nil {
            // Can't use assertionFailure in deinit reliably, but this logs the issue
            print("EngineClient deallocated without calling destroy() -- engine handle leaked")
        }
        #endif
    }
}
