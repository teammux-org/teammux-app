import SwiftUI

// MARK: - MessageType

/// Maps to `tm_message_type_t` in teammux.h.
/// TASK=0, INSTRUCTION=1, CONTEXT=2, STATUS_REQ=3,
/// STATUS_RPT=4, COMPLETION=5, ERROR=6, BROADCAST=7
enum MessageType: Int, CaseIterable, Sendable {
    case task        = 0
    case instruction = 1
    case context     = 2
    case statusReq   = 3
    case statusRpt   = 4
    case completion  = 5
    case error       = 6
    case broadcast   = 7

    /// Semantic color for Live Feed badges and message type indicators.
    var color: Color {
        switch self {
        case .task:        return .blue
        case .instruction: return .purple
        case .context:     return .secondary
        case .statusReq:   return .orange
        case .statusRpt:   return .green
        case .completion:  return .green
        case .error:       return .red
        case .broadcast:   return .yellow
        }
    }

    /// Human-readable label shown in the Live Feed and message inspector.
    var label: String {
        switch self {
        case .task:        return "Task"
        case .instruction: return "Instruction"
        case .context:     return "Context"
        case .statusReq:   return "Status Request"
        case .statusRpt:   return "Status Report"
        case .completion:  return "Completion"
        case .error:       return "Error"
        case .broadcast:   return "Broadcast"
        }
    }

    /// The C enum raw value for the FFI boundary.
    var cValue: Int32 {
        Int32(rawValue)
    }

    /// Initialise from the C enum value. Falls back to `.task` for unknown values.
    init(fromCValue value: Int32) {
        self = MessageType(rawValue: Int(value)) ?? .task
    }
}

// MARK: - TeamMessage

/// A single message exchanged on the bus, mirroring `tm_message_t`.
/// Each Swift-side instance gets a stable UUID for SwiftUI list identity
/// independent of the engine's sequence number.
struct TeamMessage: Identifiable, Equatable {
    let id: UUID
    let from: UInt32
    let to: UInt32
    let type: MessageType
    let payload: String
    let timestamp: Date
    let seq: UInt64
    let gitCommit: String?

    init(
        id: UUID = UUID(),
        from: UInt32,
        to: UInt32,
        type: MessageType,
        payload: String,
        timestamp: Date,
        seq: UInt64,
        gitCommit: String? = nil
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.type = type
        self.payload = payload
        self.timestamp = timestamp
        self.seq = seq
        self.gitCommit = gitCommit
    }
}

// MARK: - GitHubPR

/// Mirrors `tm_pr_t` in teammux.h.
struct GitHubPR: Identifiable {
    let number: UInt64
    let url: String
    let title: String
    let state: String

    /// `Identifiable` conformance keyed on PR number.
    var id: UInt64 { number }
}

// MARK: - DiffFile

/// Mirrors `tm_diff_file_t` in teammux.h.
struct DiffFile: Identifiable {
    let id: UUID
    let filePath: String
    let additions: Int
    let deletions: Int
    let patch: String

    init(
        id: UUID = UUID(),
        filePath: String,
        additions: Int,
        deletions: Int,
        patch: String
    ) {
        self.id = id
        self.filePath = filePath
        self.additions = additions
        self.deletions = deletions
        self.patch = patch
    }
}
