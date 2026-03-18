import Foundation

/// Typed error cases for EngineClient operations.
///
/// Provides structured error information instead of raw strings.
/// Currently unused — defined as scaffolding for a future migration
/// from `EngineClient.lastError: String?` to `Result<T, EngineError>`.
enum EngineError: LocalizedError, Sendable {
    case engineNotCreated
    case workerNotFound(UInt32)
    case dispatchFailed(String)
    case mergeFailed(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .engineNotCreated: return "Engine not created"
        case .workerNotFound(let id): return "Worker \(id) not found"
        case .dispatchFailed(let msg): return "Dispatch failed: \(msg)"
        case .mergeFailed(let msg): return "Merge failed: \(msg)"
        case .unknown(let msg): return msg
        }
    }
}
