import Foundation

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
