import Foundation
import SwiftUI

// MARK: - MergeStrategy

/// Maps to `tm_merge_strategy_t` in teammux.h.
/// SQUASH=0, REBASE=1, MERGE=2
enum MergeStrategy: Int, Sendable {
    case squash = 0
    case rebase = 1
    case merge  = 2

    var cValue: Int32 { Int32(rawValue) }
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
@MainActor
final class EngineClient: ObservableObject {

    // MARK: - Published properties

    @Published var roster: [WorkerInfo] = []
    @Published var messages: [TeamMessage] = []
    @Published var githubConnected: Bool = false
    @Published var lastError: String? = nil
    @Published var projectRoot: String? = nil

    /// Workers whose worktree is ready but whose SurfaceView has not
    /// yet been created. `WorkerPaneView` observes this to spawn terminals.
    @Published var worktreeReadyQueue: [(workerId: UInt32, path: String, binary: String, task: String)] = []

    // MARK: - Private state

    /// Opaque handle to the C engine (`tm_engine_t*`).
    private var engine: OpaquePointer?

    /// Maps worker ID to its SurfaceView reference (stored as AnyObject
    /// to avoid coupling this file to Ghostty types).
    private var surfaceViews: [UInt32: AnyObject] = [:]

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
        let slug = String(filtered)
        return slug
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Engine lifecycle

    /// Create the engine for a given project root directory.
    /// Wraps `tm_engine_create()`.
    /// Returns `true` on success, `false` if creation fails.
    func create(projectRoot: String) -> Bool {
        guard engine == nil else {
            lastError = "Engine already created"
            return false
        }

        let ptr = projectRoot.withCString { cRoot in
            tm_engine_create(cRoot)
        }

        guard let ptr else {
            lastError = "tm_engine_create returned nil"
            return false
        }

        engine = ptr
        self.projectRoot = projectRoot
        return true
    }

    /// Start the session (background threads, watchers, etc.).
    /// Wraps `tm_session_start()`. Must be called after `create`.
    /// Returns `true` on `TM_OK`.
    func sessionStart() -> Bool {
        guard let engine else {
            lastError = "Engine not created"
            return false
        }

        let result = tm_session_start(engine)
        guard result == TM_OK else {
            lastError = lastEngineError() ?? "tm_session_start failed (\(result.rawValue))"
            return false
        }

        setupCallbacks()
        return true
    }

    /// Stop the session (tears down background threads).
    /// Wraps `tm_session_stop()`.
    func sessionStop() {
        guard let engine else { return }
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
        githubConnected = false
        lastError = nil
    }

    // MARK: - Config

    /// Reload config from disk (`.teammux/config.toml`).
    /// Wraps `tm_config_reload()`.
    func reloadConfig() {
        guard let engine else {
            lastError = "Engine not created"
            return
        }
        let result = tm_config_reload(engine)
        if result != TM_OK {
            lastError = lastEngineError() ?? "tm_config_reload failed (\(result.rawValue))"
        }
    }

    // MARK: - Workers

    /// Spawn a new worker: creates worktree + branch + CLAUDE.md.
    /// Does NOT create a PTY — the caller must create a Ghostty SurfaceView.
    ///
    /// Returns the new worker ID, or 0 on failure.
    /// Wraps `tm_worker_spawn()`.
    func spawnWorker(
        agentBinary: String,
        agentType: AgentType,
        workerName: String,
        taskDescription: String
    ) -> UInt32 {
        guard let engine else {
            lastError = "Engine not created"
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

        if workerId == 0 {
            lastError = lastEngineError() ?? "tm_worker_spawn failed"
            return 0
        }

        // Query the fresh worker info to get the worktree path
        if let infoPtr = tm_worker_get(engine, workerId) {
            let path = String(cString: infoPtr.pointee.worktree_path)
            let binary = String(cString: infoPtr.pointee.agent_binary)
            let task = String(cString: infoPtr.pointee.task_description)
            tm_worker_info_free(infoPtr)

            worktreeReadyQueue.append((
                workerId: workerId,
                path: path,
                binary: binary,
                task: task
            ))
        }

        // Refresh the roster to pick up the new worker
        refreshRoster()

        return workerId
    }

    /// Dismiss (tear down) a worker. Removes worktree, cleans up engine state.
    /// Also unregisters the surface view.
    /// Wraps `tm_worker_dismiss()`.
    /// Returns `true` on `TM_OK`.
    func dismissWorker(_ workerId: UInt32) -> Bool {
        guard let engine else {
            lastError = "Engine not created"
            return false
        }

        let result = tm_worker_dismiss(engine, workerId)
        unregisterSurface(for: workerId)

        guard result == TM_OK else {
            lastError = lastEngineError() ?? "tm_worker_dismiss failed (\(result.rawValue))"
            return false
        }

        refreshRoster()
        return true
    }

    /// Refresh the published roster from the engine.
    /// Wraps `tm_roster_get()` + `tm_roster_free()`.
    func refreshRoster() {
        guard let engine else { return }
        guard let rosterPtr = tm_roster_get(engine) else { return }

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
            lastError = lastEngineError() ?? "tm_message_send failed (\(result.rawValue))"
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
            lastError = lastEngineError() ?? "tm_message_broadcast failed (\(result.rawValue))"
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
            return false
        }

        let result = tm_github_auth(engine)
        guard result == TM_OK else {
            lastError = lastEngineError() ?? "tm_github_auth failed (\(result.rawValue))"
            return false
        }

        githubConnected = tm_github_is_authed(engine)
        return githubConnected
    }

    /// Create a pull request for a worker's branch.
    /// Wraps `tm_github_create_pr()` + `tm_pr_free()`.
    /// Returns a `GitHubPR` on success, `nil` on failure.
    func createPR(for workerId: UInt32, title: String, body: String) -> GitHubPR? {
        guard let engine else {
            lastError = "Engine not created"
            return nil
        }

        let prPtr = title.withCString { cTitle in
            body.withCString { cBody in
                tm_github_create_pr(engine, workerId, cTitle, cBody)
            }
        }

        guard let prPtr else {
            lastError = lastEngineError() ?? "tm_github_create_pr failed"
            return nil
        }

        let pr = GitHubPR(
            number: prPtr.pointee.pr_number,
            url: String(cString: prPtr.pointee.pr_url),
            title: String(cString: prPtr.pointee.title),
            state: String(cString: prPtr.pointee.state)
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
            return false
        }

        let result = tm_github_merge_pr(
            engine,
            prNumber,
            tm_merge_strategy_t(rawValue: UInt32(strategy.cValue))
        )

        guard result == TM_OK else {
            lastError = lastEngineError() ?? "tm_github_merge_pr failed (\(result.rawValue))"
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
            return []
        }

        guard let diffPtr = tm_github_get_diff(engine, workerId) else {
            lastError = lastEngineError() ?? "tm_github_get_diff failed"
            return []
        }

        var files: [DiffFile] = []
        let count = Int(diffPtr.pointee.count)

        for i in 0..<count {
            let f = diffPtr.pointee.files[i]
            let file = DiffFile(
                filePath: String(cString: f.file_path),
                additions: Int(f.additions),
                deletions: Int(f.deletions),
                patch: String(cString: f.patch)
            )
            files.append(file)
        }

        tm_diff_free(diffPtr)
        return files
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
        tm_roster_watch(engine, { rosterPtr, userdata in
            guard let userdata, let rosterPtr else { return }

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
        tm_message_subscribe(engine, { messagePtr, userdata in
            guard let userdata, let messagePtr else { return }

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
        }, selfPtr)

        // --- Command interception (/teammux-*) ---
        tm_commands_watch(engine, { commandPtr, argsPtr, userdata in
            guard let userdata else { return }

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
        tm_github_webhooks_start(engine, { eventTypePtr, payloadPtr, userdata in
            guard let userdata else { return }

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
        tm_config_watch(engine, { userdata in
            guard let userdata else { return }

            let client = Unmanaged<EngineClient>.fromOpaque(userdata).takeUnretainedValue()
            Task { @MainActor in
                client.reloadConfig()
            }
        }, selfPtr)
    }

    // MARK: - Private: Command handler

    /// Dispatch `/teammux-*` commands received from the engine's
    /// command interception callback.
    private func handleCommand(_ command: String, argsJson: String) {
        let args = parseArgsJson(argsJson)

        switch command {
        case "/teammux-add":
            let binary = args["binary"] ?? "claude"
            let agentTypeRaw = Int32(args["agent_type"] ?? "0") ?? 0
            let agentType = AgentType(fromCValue: agentTypeRaw)
            let name = args["name"] ?? "Worker"
            let task = args["task"] ?? ""
            _ = spawnWorker(
                agentBinary: binary,
                agentType: agentType,
                workerName: name,
                taskDescription: task
            )

        case "/teammux-remove":
            if let idStr = args["worker_id"], let workerId = UInt32(idStr) {
                _ = dismissWorker(workerId)
            } else {
                lastError = "/teammux-remove: missing or invalid worker_id"
            }

        case "/teammux-message":
            if let toStr = args["to"],
               let to = UInt32(toStr),
               let typeStr = args["type"],
               let typeRaw = Int(typeStr),
               let type = MessageType(rawValue: typeRaw) {
                let payload = args["payload"] ?? ""
                _ = sendMessage(to: to, type: type, payload: payload)
            } else {
                lastError = "/teammux-message: missing to, type, or payload"
            }

        case "/teammux-broadcast":
            if let typeStr = args["type"],
               let typeRaw = Int(typeStr),
               let type = MessageType(rawValue: typeRaw) {
                let payload = args["payload"] ?? ""
                _ = broadcastMessage(type: type, payload: payload)
            } else {
                lastError = "/teammux-broadcast: missing type"
            }

        default:
            lastError = "Unknown command: \(command)"
        }
    }

    // MARK: - Private: GitHub event handler

    /// Handle GitHub webhook events (PR status changes, check runs, etc.).
    private func handleGitHubEvent(_ eventType: String, payload: String) {
        switch eventType {
        case "pull_request":
            // Refresh auth status in case a PR event indicates changes
            if let engine {
                githubConnected = tm_github_is_authed(engine)
            }
        default:
            break
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
            // Fall through — return empty dict
        }
        return [:]
    }

    deinit {
        // Safety: if someone drops the last reference without calling destroy(),
        // clean up the engine handle. Note: deinit is not @MainActor-isolated,
        // so we only call the C teardown functions which are thread-safe.
        if let engine {
            tm_session_stop(engine)
            tm_engine_destroy(engine)
        }
    }
}
