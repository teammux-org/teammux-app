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
