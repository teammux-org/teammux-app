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
/// `Ghostty.SurfaceView` to launch the agent. Message bus text
/// injection goes via `SurfaceView.sendText()`, not the engine.
/// A worker whose worktree is ready but whose SurfaceView has not yet been created.
struct WorktreeReady: Identifiable, Equatable, Sendable {
    let id: UInt32  // worker ID, also serves as Identifiable.id
    let worktreePath: String
    let agentBinary: String
    let taskDescription: String
}

@MainActor
final class EngineClient: ObservableObject {

    // MARK: - Logger

    private static let logger = Logger(subsystem: "com.teammux.app", category: "EngineClient")

    // MARK: - Published properties

    @Published var roster: [WorkerInfo] = []
    @Published var messages: [TeamMessage] = []
    @Published var githubStatus: GitHubStatus = .disconnected
    @Published var lastError: String? = nil
    @Published var projectRoot: String? = nil

    /// Workers whose worktree is ready but whose SurfaceView has not
    /// yet been created. `WorkerPaneView` observes this to spawn terminals.
    @Published var worktreeReadyQueue: [WorktreeReady] = []

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

    // MARK: - Private state

    /// Opaque handle to the C engine (`tm_engine_t*`).
    private var engine: OpaquePointer?

    /// Maps worker ID to its SurfaceView reference (stored as AnyObject
    /// to avoid coupling this file to Ghostty types).
    private var surfaceViews: [UInt32: AnyObject] = [:]

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

    /// Register a SurfaceView for a given worker so the message bus
    /// can inject text via `sendText()`.
    func registerSurface(_ surface: AnyObject, for workerId: UInt32) {
        surfaceViews[workerId] = surface
    }

    /// Remove the SurfaceView reference when a worker is dismissed or
    /// its terminal closes.
    func unregisterSurface(for workerId: UInt32) {
        surfaceViews.removeValue(forKey: workerId)
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
    /// Also loads available roles via `loadAvailableRoles()`.
    /// Returns `true` on `TM_OK`.
    func sessionStart() -> Bool {
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
        roster.removeAll()
        messages.removeAll()
        worktreeReadyQueue.removeAll()
        stopMergePolling()
        mergeStatuses.removeAll()
        pendingConflicts.removeAll()
        availableRoles.removeAll()
        workerRoles.removeAll()
        githubStatus = .disconnected
        lastError = nil
    }

    // MARK: - Config

    /// Reload config from disk (`.teammux/config.toml`).
    /// Wraps `tm_config_reload()`.
    func reloadConfig() {
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

        // Query the fresh worker info to get the worktree path
        if let infoPtr = tm_worker_get(engine, workerId) {
            let path = String(cString: infoPtr.pointee.worktree_path)
            let binary = String(cString: infoPtr.pointee.agent_binary)
            let task = String(cString: infoPtr.pointee.task_description)
            tm_worker_info_free(infoPtr)

            worktreeReadyQueue.append(WorktreeReady(
                id: workerId,
                worktreePath: path,
                agentBinary: binary,
                taskDescription: task
            ))
        } else {
            lastError = "Worker \(workerId) spawned but tm_worker_get returned nil"
            Self.logger.error("Worker \(workerId) spawned but tm_worker_get returned nil")
        }

        // Resolve role and register ownership patterns if roleId was provided.
        // Failure here is non-fatal — the worker still operates, just without
        // role-based ownership enforcement.
        if let roleId {
            if let role = resolveRole(id: roleId) {
                registerOwnership(workerId: workerId, role: role)
                workerRoles[workerId] = role
            } else {
                Self.logger.warning("spawnWorker: role '\(roleId)' could not be resolved for worker \(workerId)")
            }
        }

        // Refresh the roster to pick up the new worker
        refreshRoster()

        return workerId
    }

    /// Dismiss (tear down) a worker. Removes worktree, cleans up engine state.
    /// Also unregisters the surface view and removes the cached role.
    /// The engine releases ownership rules internally via `tm_ownership_release`.
    /// Wraps `tm_worker_dismiss()`.
    /// Returns `true` on `TM_OK`.
    func dismissWorker(_ workerId: UInt32) -> Bool {
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("Engine not created")
            return false
        }

        let result = tm_worker_dismiss(engine, workerId)

        guard result == TM_OK else {
            let msg = lastEngineError() ?? "tm_worker_dismiss failed (\(result.rawValue))"
            lastError = msg
            Self.logger.error("dismissWorker failed: \(msg)")
            return false
        }

        unregisterSurface(for: workerId)
        workerRoles.removeValue(forKey: workerId)
        refreshRoster()
        return true
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
                spawnedAt: Date(timeIntervalSince1970: TimeInterval(w.spawned_at))
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
            githubStatus = .error(msg)
            return false
        }

        if tm_github_is_authed(engine) {
            githubStatus = .connected("engine")
            return true
        } else {
            let msg = "GitHub auth succeeded but is_authed returned false"
            lastError = msg
            Self.logger.error("\(msg)")
            githubStatus = .error(msg)
            return false
        }
    }

    /// Create a pull request for a worker's branch.
    /// Wraps `tm_github_create_pr()` + `tm_pr_free()`.
    /// Returns a `GitHubPR` on success, `nil` on failure.
    func createPR(for workerId: UInt32, title: String, body: String) -> GitHubPR? {
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
            state: PRState(fromCValue: prPtr.pointee.state.rawValue),
            diffUrl: String(cString: prPtr.pointee.diff_url),
            workerId: prPtr.pointee.worker_id
        )

        tm_pr_free(prPtr)
        return pr
    }

    /// Merge a pull request by PR number.
    /// Wraps `tm_github_merge_pr()`.
    /// Returns `true` on `TM_OK`.
    func mergePR(_ prNumber: UInt64, strategy: MergeStrategy) -> Bool {
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

    /// Get the diff for a worker's branch vs main.
    /// Wraps `tm_github_get_diff()` + `tm_diff_free()`.
    /// Returns an array of `DiffFile`, empty on failure.
    func getDiff(for workerId: UInt32) -> [DiffFile] {
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("Engine not created")
            return []
        }

        guard let diffPtr = tm_github_get_diff(engine, workerId) else {
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

    // MARK: - Merge Coordinator

    /// Approve merge of a worker's branch into main.
    /// Wraps `tm_merge_approve()`. Returns `true` if the engine accepted the request.
    /// `true` does not mean the merge succeeded — check `getMergeStatus()` for the
    /// outcome, which may be `.inProgress`, `.success`, or `.conflict`.
    func approveMerge(workerId: UInt32, strategy: MergeStrategy) -> Bool {
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("Engine not created")
            return false
        }

        let result = strategy.strategyString.withCString { cStrategy in
            tm_merge_approve(engine, workerId, cStrategy)
        }

        guard result == TM_OK else {
            let msg = lastEngineError() ?? "tm_merge_approve failed (\(result.rawValue))"
            lastError = msg
            Self.logger.error("approveMerge failed: \(msg)")
            return false
        }

        let initialStatus = getMergeStatus(workerId: workerId)
        mergeStatuses[workerId] = initialStatus
        Self.logger.info("approveMerge: worker \(workerId) initial status: \(initialStatus.label)")
        startMergePolling()
        return true
    }

    /// Reject a worker's merge: abort in-progress merge, remove worktree, delete branch.
    /// The worker remains in the roster with a completed/dismissed status.
    /// Wraps `tm_merge_reject()`. Returns `true` on `TM_OK`.
    func rejectMerge(workerId: UInt32) -> Bool {
        guard let engine else {
            lastError = "Engine not created"
            Self.logger.error("Engine not created")
            return false
        }

        let result = tm_merge_reject(engine, workerId)

        guard result == TM_OK else {
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
                conflictType: String(cString: ptr.pointee.conflict_type),
                ours: ours,
                theirs: theirs
            )
            conflicts.append(conflict)
        }

        tm_merge_conflicts_free(conflictsPtr, count)
        return conflicts
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
            roles.append(bridgeRole(rolePtr))
        }

        tm_roles_list_free(rolesPtr, count)
        availableRoles = roles
        Self.logger.info("loadAvailableRoles: loaded \(roles.count) roles")
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

        let role = bridgeRole(rolePtr)
        tm_role_free(rolePtr)
        return role
    }

    /// Bridge a `tm_role_t*` to a Swift `RoleDefinition`.
    /// Extracts string fields, boolean capabilities, and iterates
    /// the `const char**` pattern arrays.
    private func bridgeRole(_ rolePtr: UnsafeMutablePointer<tm_role_t>) -> RoleDefinition {
        let role = rolePtr.pointee
        let roleId = String(cString: role.id)

        var writePatterns: [String] = []
        if let patternsPtr = role.write_patterns {
            for i in 0..<Int(role.write_pattern_count) {
                if let cStr = patternsPtr[i] {
                    writePatterns.append(String(cString: cStr))
                } else {
                    Self.logger.warning("bridgeRole: NULL write_pattern at index \(i) for role '\(roleId)'")
                }
            }
        }

        var denyWritePatterns: [String] = []
        if let patternsPtr = role.deny_write_patterns {
            for i in 0..<Int(role.deny_write_pattern_count) {
                if let cStr = patternsPtr[i] {
                    denyWritePatterns.append(String(cString: cStr))
                } else {
                    Self.logger.warning("bridgeRole: NULL deny_write_pattern at index \(i) for role '\(roleId)'")
                }
            }
        }

        return RoleDefinition(
            id: roleId,
            name: String(cString: role.name),
            division: String(cString: role.division),
            emoji: String(cString: role.emoji),
            description: String(cString: role.description),
            writePatterns: writePatterns,
            denyWritePatterns: denyWritePatterns,
            canPush: role.can_push,
            canMerge: role.can_merge
        )
    }

    /// Register all write and deny_write patterns from a role definition
    /// into the engine's ownership registry for a given worker.
    /// Wraps `tm_ownership_register()`.
    private func registerOwnership(workerId: UInt32, role: RoleDefinition) {
        guard let engine else {
            Self.logger.error("registerOwnership: engine not created — skipping \(role.writePatterns.count + role.denyWritePatterns.count) patterns for worker \(workerId)")
            return
        }

        for pattern in role.writePatterns {
            pattern.withCString { cPattern in
                let result = tm_ownership_register(engine, workerId, cPattern, true)
                if result != TM_OK {
                    Self.logger.warning("registerOwnership: failed to register write pattern '\(pattern)' for worker \(workerId)")
                }
            }
        }

        for pattern in role.denyWritePatterns {
            pattern.withCString { cPattern in
                let result = tm_ownership_register(engine, workerId, cPattern, false)
                if result != TM_OK {
                    Self.logger.warning("registerOwnership: failed to register deny pattern '\(pattern)' for worker \(workerId)")
                }
            }
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
                    spawnedAt: Date(timeIntervalSince1970: TimeInterval(w.spawned_at))
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

            // Copy all string data while on the callback thread.
            let from = messagePtr.pointee.from
            let to = messagePtr.pointee.to
            let type = MessageType(fromCValue: Int32(messagePtr.pointee.type.rawValue))
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
    private func teardownCallbacks() {
        guard let engine else { return }
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
            // Refresh auth status in case a PR event indicates changes
            guard let engine else {
                Self.logger.warning("handleGitHubEvent: engine is nil during pull_request event")
                return
            }
            if tm_github_is_authed(engine) {
                githubStatus = .connected("engine")
            } else {
                githubStatus = .disconnected
            }
        default:
            Self.logger.debug("Unhandled GitHub event type: \(eventType)")
        }
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
