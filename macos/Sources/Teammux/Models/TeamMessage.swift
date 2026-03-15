import SwiftUI
import os

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

    private static let logger = Logger(subsystem: "com.teammux.app", category: "MessageType")

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
        if let known = MessageType(rawValue: Int(value)) {
            self = known
        } else {
            #if DEBUG
            assertionFailure("Unknown MessageType C value: \(value)")
            #endif
            Self.logger.warning("Unknown MessageType C value: \(value), defaulting to .task")
            self = .task
        }
    }
}

// MARK: - TeamMessage

/// A single message exchanged on the bus, mirroring `tm_message_t`.
/// Each Swift-side instance gets a stable UUID for SwiftUI list identity
/// independent of the engine's sequence number.
struct TeamMessage: Identifiable, Equatable, Sendable {
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

// MARK: - PRState

/// Type-safe representation of a GitHub PR's state.
/// Maps to `tm_pr_state_t` in teammux.h: TM_PR_OPEN=0, TM_PR_CLOSED=1, TM_PR_MERGED=2
enum PRState: Sendable {
    case open, closed, merged
    case unknown

    /// Initialise from the C enum raw value (`tm_pr_state_t`).
    init(fromCValue value: UInt32) {
        switch value {
        case 0: self = .open
        case 1: self = .closed
        case 2: self = .merged
        default: self = .unknown
        }
    }

    /// Legacy initialiser from string (used in tests / fallback).
    init(from string: String) {
        switch string.lowercased() {
        case "open":   self = .open
        case "closed": self = .closed
        case "merged": self = .merged
        default:       self = .unknown
        }
    }

    var label: String {
        switch self {
        case .open: return "Open"
        case .closed: return "Closed"
        case .merged: return "Merged"
        case .unknown: return "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .open: return .green
        case .closed: return .red
        case .merged: return .purple
        case .unknown: return .secondary
        }
    }
}

/// Mirrors `tm_pr_t` in teammux.h.
struct GitHubPR: Identifiable, Sendable {
    let number: UInt64
    let url: String
    let title: String
    let state: PRState
    let diffUrl: String
    let workerId: UInt32

    /// `Identifiable` conformance keyed on PR number.
    var id: UInt64 { number }
}

// MARK: - DiffStatus

/// Maps to `tm_diff_status_t` in teammux.h.
/// TM_DIFF_ADDED=0, TM_DIFF_MODIFIED=1, TM_DIFF_DELETED=2, TM_DIFF_RENAMED=3
enum DiffStatus: Int, Sendable {
    case added = 0
    case modified = 1
    case deleted = 2
    case renamed = 3

    private static let logger = Logger(subsystem: "com.teammux.app", category: "DiffStatus")

    /// Initialise from the C enum raw value (`tm_diff_status_t`).
    init(fromCValue value: UInt32) {
        if let known = DiffStatus(rawValue: Int(value)) {
            self = known
        } else {
            #if DEBUG
            assertionFailure("Unknown DiffStatus C value: \(value)")
            #endif
            Self.logger.warning("Unknown DiffStatus C value: \(value), defaulting to .modified")
            self = .modified
        }
    }

    var label: String {
        switch self {
        case .added: return "Added"
        case .modified: return "Modified"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        }
    }

    var color: Color {
        switch self {
        case .added: return .green
        case .modified: return .orange
        case .deleted: return .red
        case .renamed: return .blue
        }
    }
}

// MARK: - DiffFile

/// Mirrors `tm_diff_file_t` in teammux.h.
struct DiffFile: Identifiable, Equatable, Sendable {
    let id: UUID
    let filePath: String
    let status: DiffStatus
    let additions: Int
    let deletions: Int
    let patch: String

    init(
        id: UUID = UUID(),
        filePath: String,
        status: DiffStatus = .modified,
        additions: Int,
        deletions: Int,
        patch: String
    ) {
        self.id = id
        self.filePath = filePath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.patch = patch
    }
}
