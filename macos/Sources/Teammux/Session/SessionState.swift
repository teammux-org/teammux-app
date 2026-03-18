import Foundation
import CryptoKit
import os

// MARK: - WorkerSnapshot

/// Codable snapshot of a single worker for session persistence.
/// All fields are `let` — this is a frozen point-in-time capture.
struct WorkerSnapshot: Codable {
    let id: UInt32
    let name: String
    let roleId: String?
    let taskDescription: String
    let worktreePath: String
    let branchName: String
    let agentBinary: String
    let agentTypeCValue: Int32
}

// MARK: - HistoryEntrySnapshot

/// Codable snapshot of a completion/question history entry.
struct HistoryEntrySnapshot: Codable {
    let type: HistoryEntryType
    let workerId: UInt32
    let roleId: String?
    let content: String
    let gitCommit: String?
    let timestamp: Date
}

// MARK: - DispatchEventSnapshot

/// Codable snapshot of a dispatch event.
struct DispatchEventSnapshot: Codable {
    let targetWorkerId: UInt32
    let instruction: String
    let timestamp: Date
    let delivered: Bool
    let kind: DispatchKind
}

// MARK: - PREventSnapshot

/// Codable snapshot of a PR event.
struct PREventSnapshot: Codable {
    let workerId: UInt32
    let branchName: String
    let prUrl: String
    let title: String
    let status: PRStatus
    let timestamp: Date
}

// MARK: - SessionSnapshot

/// Top-level session snapshot. Contains all five persisted items:
/// roster, worktree paths, completion history, dispatch history, PR signals.
struct SessionSnapshot: Codable {
    let projectPath: String
    let timestamp: Date
    let workers: [WorkerSnapshot]
    let completionHistoryEntries: [HistoryEntrySnapshot]
    let dispatchHistoryEntries: [DispatchEventSnapshot]
    let workerPRs: [String: PREventSnapshot]
}

// MARK: - SessionState

/// Manages session persistence: save, load, and delete session snapshots.
///
/// Persistence path: `~/.teammux/sessions/{SHA256(projectPath)}.json`
///
/// Save is triggered by `applicationWillResignActive` and `applicationWillTerminate`.
/// Load is triggered by `SetupView` on project selection.
enum SessionState {

    private static let logger = Logger(subsystem: "com.teammux.app", category: "SessionState")

    // MARK: - Path computation

    /// Returns the directory for session files: `~/.teammux/sessions/`.
    private static var sessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".teammux")
            .appendingPathComponent("sessions")
    }

    /// Computes the session file path for a given project path.
    /// Uses SHA256 of the project path string as filename.
    static func sessionFilePath(for projectPath: String) -> URL {
        let hash = sha256Hex(projectPath)
        return sessionsDirectory.appendingPathComponent("\(hash).json")
    }

    /// SHA256 hex digest of a string.
    private static func sha256Hex(_ input: String) -> String {
        let data = Data(input.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Save

    /// Snapshots the current engine state and writes it to disk.
    /// Non-fatal on failure — logs a warning and returns.
    @MainActor
    static func save(engine: EngineClient, projectPath: String) {
        guard engine.projectRoot != nil else {
            logger.info("save: no active session for project, skipping")
            return
        }

        // Snapshot workers from roster + cached worktree/branch/role data
        let workerSnapshots: [WorkerSnapshot] = engine.roster.map { worker in
            WorkerSnapshot(
                id: worker.id,
                name: worker.name,
                roleId: engine.workerRoles[worker.id]?.id,
                taskDescription: worker.taskDescription,
                worktreePath: engine.workerWorktrees[worker.id] ?? worker.worktreePath,
                branchName: engine.workerBranches[worker.id] ?? worker.branchName,
                agentBinary: worker.agentBinary,
                agentTypeCValue: worker.agentType.cValue
            )
        }

        // Snapshot completion history
        let historySnapshots: [HistoryEntrySnapshot] = engine.completionHistory.map { entry in
            HistoryEntrySnapshot(
                type: entry.type,
                workerId: entry.workerId,
                roleId: entry.roleId,
                content: entry.content,
                gitCommit: entry.gitCommit,
                timestamp: entry.timestamp
            )
        }

        // Snapshot dispatch history
        let dispatchSnapshots: [DispatchEventSnapshot] = engine.dispatchHistory.map { event in
            DispatchEventSnapshot(
                targetWorkerId: event.targetWorkerId,
                instruction: event.instruction,
                timestamp: event.timestamp,
                delivered: event.delivered,
                kind: event.kind
            )
        }

        // Snapshot PR events
        var prSnapshots: [String: PREventSnapshot] = [:]
        for (workerId, pr) in engine.workerPRs {
            prSnapshots[String(workerId)] = PREventSnapshot(
                workerId: pr.workerId,
                branchName: pr.branchName,
                prUrl: pr.prUrl,
                title: pr.title,
                status: pr.status,
                timestamp: pr.timestamp
            )
        }

        let snapshot = SessionSnapshot(
            projectPath: projectPath,
            timestamp: Date(),
            workers: workerSnapshots,
            completionHistoryEntries: historySnapshots,
            dispatchHistoryEntries: dispatchSnapshots,
            workerPRs: prSnapshots
        )

        do {
            let fm = FileManager.default
            let dir = sessionsDirectory
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)

            let filePath = sessionFilePath(for: projectPath)
            try data.write(to: filePath, options: .atomic)
            logger.info("save: session saved to \(filePath.path) (\(workerSnapshots.count) workers)")
        } catch {
            logger.warning("save: failed to write session file — \(error.localizedDescription)")
        }
    }

    // MARK: - Load

    /// Loads a session snapshot from disk for the given project path.
    /// Returns `nil` if no session file exists or if the file is corrupt.
    static func load(projectPath: String) -> SessionSnapshot? {
        let filePath = sessionFilePath(for: projectPath)
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: filePath)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(SessionSnapshot.self, from: data)
            logger.info("load: session loaded from \(filePath.path) (\(snapshot.workers.count) workers)")
            return snapshot
        } catch {
            logger.warning("load: failed to decode session file at \(filePath.path) — \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Delete

    /// Removes the session file for the given project path.
    /// Non-fatal on failure — logs a warning and returns.
    static func delete(projectPath: String) {
        let filePath = sessionFilePath(for: projectPath)
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: filePath)
            logger.info("delete: session file removed at \(filePath.path)")
        } catch {
            logger.warning("delete: failed to remove session file at \(filePath.path) — \(error.localizedDescription)")
        }
    }
}
