import SwiftUI

// MARK: - WorkerStatus

/// Maps to `tm_worker_status_t` in teammux.h.
/// IDLE=0, WORKING=1, COMPLETE=2, BLOCKED=3, ERROR=4
enum WorkerStatus: Int, CaseIterable, Sendable {
    case idle     = 0
    case working  = 1
    case complete = 2
    case blocked  = 3
    case error    = 4

    /// Semantic color for roster status dots and badges.
    var color: Color {
        switch self {
        case .idle:     return .secondary
        case .working:  return .orange
        case .complete: return .green
        case .blocked:  return .yellow
        case .error:    return .red
        }
    }

    /// Human-readable label for UI display.
    var label: String {
        switch self {
        case .idle:     return "Idle"
        case .working:  return "Working"
        case .complete: return "Complete"
        case .blocked:  return "Blocked"
        case .error:    return "Error"
        }
    }

    /// Initialise from the C enum value. Falls back to `.idle` for unknown values.
    init(fromCValue value: Int32) {
        self = WorkerStatus(rawValue: Int(value)) ?? .idle
    }
}

// MARK: - AgentType

/// Maps to `tm_agent_type_t` in teammux.h.
/// CLAUDE_CODE=0, CODEX_CLI=1, CUSTOM=99
enum AgentType: Equatable, Hashable, Sendable {
    case claudeCode
    case codexCli
    case custom(String)

    /// Human-readable name for pickers and roster rows.
    var displayName: String {
        switch self {
        case .claudeCode:       return "Claude Code"
        case .codexCli:         return "Codex CLI"
        case .custom(let name): return name.isEmpty ? "Custom Agent" : name
        }
    }

    /// Resolve to the binary name expected on PATH.
    func resolvedBinary() -> String {
        switch self {
        case .claudeCode:       return "claude"
        case .codexCli:         return "codex"
        case .custom(let name): return name
        }
    }

    /// The C enum raw value used across the FFI boundary.
    var cValue: Int32 {
        switch self {
        case .claudeCode: return 0
        case .codexCli:   return 1
        case .custom:     return 99
        }
    }

    /// Initialise from the C enum value and an optional binary name for custom agents.
    init(fromCValue value: Int32, binaryName: String? = nil) {
        switch value {
        case 0:  self = .claudeCode
        case 1:  self = .codexCli
        default: self = .custom(binaryName ?? "")
        }
    }
}

// MARK: - WorkerInfo

/// A snapshot of a single worker's state, mirroring `tm_worker_info_t`.
/// Equality is by `id` only so SwiftUI list diffing keys on the worker identity
/// rather than every mutable field.
struct WorkerInfo: Identifiable, Equatable {
    let id: UInt32
    let name: String
    let taskDescription: String
    let branchName: String
    let worktreePath: String
    var status: WorkerStatus
    let agentType: AgentType
    let agentBinary: String
    let spawnedAt: Date

    static func == (lhs: WorkerInfo, rhs: WorkerInfo) -> Bool {
        lhs.id == rhs.id
    }
}
