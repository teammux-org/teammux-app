import Foundation
import SwiftUI

// MARK: - CompletionReport

/// A worker's completion signal, bridged from `tm_completion_t` in teammux.h.
/// Delivered via `TM_MSG_COMPLETION` on the message bus.
///
/// The engine does not provide UUIDs — `id` is generated Swift-side for
/// SwiftUI `ForEach` / `Identifiable` conformance.
struct CompletionReport: Identifiable, Equatable, Sendable {
    let id: UUID
    let workerId: UInt32
    let summary: String
    let gitCommit: String?
    let details: String?
    let timestamp: Date

    init(
        id: UUID = UUID(),
        workerId: UInt32,
        summary: String,
        gitCommit: String? = nil,
        details: String? = nil,
        timestamp: Date
    ) {
        self.id = id
        self.workerId = workerId
        self.summary = summary
        self.gitCommit = gitCommit
        self.details = details
        self.timestamp = timestamp
    }
}

// MARK: - QuestionRequest

/// A worker's question to the Team Lead, bridged from `tm_question_t` in teammux.h.
/// Delivered via `TM_MSG_QUESTION` on the message bus.
struct QuestionRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let workerId: UInt32
    let question: String
    let context: String?
    let timestamp: Date

    init(
        id: UUID = UUID(),
        workerId: UInt32,
        question: String,
        context: String? = nil,
        timestamp: Date
    ) {
        self.id = id
        self.workerId = workerId
        self.question = question
        self.context = context
        self.timestamp = timestamp
    }
}

// MARK: - DispatchKind

/// Distinguishes task dispatches from response dispatches.
/// Maps to `tm_dispatch_event_t.kind` in teammux.h (0 = task, 1 = response).
enum DispatchKind: UInt8, Sendable {
    case task = 0
    case response = 1
}

// MARK: - DispatchEvent

/// A Team Lead dispatch event, bridged from `tm_dispatch_event_t` in teammux.h.
/// Records task dispatches and response dispatches to workers.
///
/// The engine does not provide UUIDs — `id` is generated Swift-side for
/// SwiftUI `ForEach` / `Identifiable` conformance.
struct DispatchEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let targetWorkerId: UInt32
    let instruction: String
    let timestamp: Date
    let delivered: Bool
    let kind: DispatchKind

    init(
        id: UUID = UUID(),
        targetWorkerId: UInt32,
        instruction: String,
        timestamp: Date,
        delivered: Bool,
        kind: DispatchKind
    ) {
        self.id = id
        self.targetWorkerId = targetWorkerId
        self.instruction = instruction
        self.timestamp = timestamp
        self.delivered = delivered
        self.kind = kind
    }
}

// MARK: - PeerQuestion

/// A worker-to-worker question routed via Team Lead relay.
/// Delivered via `TM_MSG_PEER_QUESTION` (12) on the message bus.
///
/// Keyed by `fromWorkerId` in `EngineClient.peerQuestions` — only the latest
/// question per sending worker is stored. A second question before relay
/// overwrites the first (latest state wins).
///
/// Payload format from engine: `{"worker_id": N, "target_worker_id": M, "message": "..."}`
struct PeerQuestion: Identifiable, Equatable, Sendable {
    let id: UUID
    let fromWorkerId: UInt32
    let targetWorkerId: UInt32
    let message: String
    let timestamp: Date

    init(
        id: UUID = UUID(),
        fromWorkerId: UInt32,
        targetWorkerId: UInt32,
        message: String,
        timestamp: Date
    ) {
        self.id = id
        self.fromWorkerId = fromWorkerId
        self.targetWorkerId = targetWorkerId
        self.message = message
        self.timestamp = timestamp
    }
}

// MARK: - PeerDelegation

/// A worker-to-worker task delegation routed directly to the target worker.
/// Delivered via `TM_MSG_DELEGATION` (13) on the message bus.
///
/// Stored in `EngineClient.peerDelegations` as an append-only array (cap 100).
/// Displayed as informational cards in LiveFeedView — no action buttons needed
/// because the engine has already routed the delegation to the target worker's PTY.
///
/// Payload format from engine: `{"worker_id": N, "target_worker_id": M, "task": "..."}`
struct PeerDelegation: Identifiable, Equatable, Sendable {
    let id: UUID
    let fromWorkerId: UInt32
    let targetWorkerId: UInt32
    let task: String
    let timestamp: Date

    init(
        id: UUID = UUID(),
        fromWorkerId: UInt32,
        targetWorkerId: UInt32,
        task: String,
        timestamp: Date
    ) {
        self.id = id
        self.fromWorkerId = fromWorkerId
        self.targetWorkerId = targetWorkerId
        self.task = task
        self.timestamp = timestamp
    }
}

// MARK: - HistoryEntryType

/// Discriminator for persisted history entries loaded from the JSONL log.
/// Parsed from the `type` string field in `tm_history_entry_t` ("completion" or "question").
enum HistoryEntryType: String, Sendable {
    case completion
    case question
}

// MARK: - HistoryEntry

/// A persisted history entry loaded from the engine's JSONL completion log.
/// Bridged from `tm_history_entry_t` in teammux.h via `tm_history_load`.
///
/// The engine does not provide UUIDs — `id` is generated Swift-side for
/// SwiftUI `ForEach` / `Identifiable` conformance.
struct HistoryEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let type: HistoryEntryType
    let workerId: UInt32
    let roleId: String?
    let content: String
    let gitCommit: String?
    let timestamp: Date

    init(
        id: UUID = UUID(),
        type: HistoryEntryType,
        workerId: UInt32,
        roleId: String?,
        content: String,
        gitCommit: String? = nil,
        timestamp: Date
    ) {
        self.id = id
        self.type = type
        self.workerId = workerId
        self.roleId = roleId
        self.content = content
        self.gitCommit = gitCommit
        self.timestamp = timestamp
    }
}

// MARK: - PRStatus

/// Status of a GitHub pull request created by a worker.
/// Initially `.open` when created via `TM_MSG_PR_READY` or `createPR()`;
/// updated via the `status` field in `TM_MSG_PR_STATUS` payloads.
/// Distinct from `PRState` in TeamMessage.swift, which maps to the C
/// `tm_pr_state_t` for the GitHub API bridge.
enum PRStatus: String, Sendable, Codable {
    case open
    case merged
    case closed

    var label: String {
        switch self {
        case .open:   return "Open"
        case .merged: return "Merged"
        case .closed: return "Closed"
        }
    }

    var color: SwiftUI.Color {
        switch self {
        case .open:   return .green
        case .merged: return .purple
        case .closed: return .secondary
        }
    }
}

// MARK: - PREvent

/// A pull request created by a worker, populated when `createPR()` succeeds
/// from the UI or when a `TM_MSG_PR_READY` message arrives on the bus.
/// Status updates arrive via `TM_MSG_PR_STATUS`.
///
/// The engine does not provide UUIDs — `id` is generated Swift-side for
/// SwiftUI `ForEach` / `Identifiable` conformance.
struct PREvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let workerId: UInt32
    let branchName: String
    let prUrl: String
    let title: String
    var status: PRStatus
    let timestamp: Date

    init(
        id: UUID = UUID(),
        workerId: UInt32,
        branchName: String,
        prUrl: String,
        title: String,
        status: PRStatus = .open,
        timestamp: Date
    ) {
        self.id = id
        self.workerId = workerId
        self.branchName = branchName
        self.prUrl = prUrl
        self.title = title
        self.status = status
        self.timestamp = timestamp
    }
}
