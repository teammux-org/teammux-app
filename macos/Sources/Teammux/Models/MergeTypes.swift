import SwiftUI
import os

// MARK: - MergeStatus

/// Maps to `tm_merge_status_e` in teammux.h. Raw values mirror the C enum ordinals.
enum MergeStatus: Int, CaseIterable, Sendable {
    case pending    = 0
    case inProgress = 1
    case success    = 2
    case conflict   = 3
    case rejected   = 4

    private static let logger = Logger(subsystem: "com.teammux.app", category: "MergeStatus")

    var color: Color {
        switch self {
        case .pending:    return .secondary
        case .inProgress: return .orange
        case .success:    return .green
        case .conflict:   return .red
        case .rejected:   return .secondary
        }
    }

    var label: String {
        switch self {
        case .pending:    return "Pending"
        case .inProgress: return "In Progress"
        case .success:    return "Success"
        case .conflict:   return "Conflict"
        case .rejected:   return "Rejected"
        }
    }

    /// Initialise from the C enum value. Falls back to `.pending` for unknown values.
    init(fromCValue value: Int32) {
        if let known = MergeStatus(rawValue: Int(value)) {
            self = known
        } else {
            #if DEBUG
            assertionFailure("Unknown MergeStatus C value: \(value)")
            #endif
            Self.logger.warning("Unknown MergeStatus C value: \(value), defaulting to .pending")
            self = .pending
        }
    }
}

// MARK: - ConflictType

/// Type-safe conflict classification from the engine's `tm_conflict_t.conflict_type` string.
/// Currently the engine produces "content" and "unknown"; any unrecognised value maps to `.unknown`.
enum ConflictType: String, Sendable {
    case content = "content"
    case unknown = "unknown"

    init(rawString: String) {
        self = ConflictType(rawValue: rawString) ?? .unknown
    }

    var displayName: String {
        switch self {
        case .content: return "Content conflict"
        case .unknown: return "Unknown conflict"
        }
    }
}

// MARK: - ConflictInfo

/// Mirrors `tm_conflict_t` in teammux.h.
/// `ours` and `theirs` are nullable — the engine may set them to NULL for certain conflict types.
struct ConflictInfo: Identifiable, Equatable, Sendable {
    let id: UUID
    let filePath: String
    let conflictType: ConflictType
    let ours: String?
    let theirs: String?

    init(
        id: UUID = UUID(),
        filePath: String,
        conflictType: ConflictType,
        ours: String? = nil,
        theirs: String? = nil
    ) {
        self.id = id
        self.filePath = filePath
        self.conflictType = conflictType
        self.ours = ours
        self.theirs = theirs
    }
}
