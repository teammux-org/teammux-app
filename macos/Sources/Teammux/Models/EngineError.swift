import Foundation

/// Typed error cases for EngineClient operations.
///
/// Provides structured error information instead of raw strings.
/// Used alongside `EngineClient.lastError` for backwards compatibility
/// while enabling future migration to `Result<T, EngineError>`.
enum EngineError: LocalizedError {
    case engineNotStarted
    case workerNotFound(UInt32)
    case dispatchFailed(String)
    case mergeFailed(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .engineNotStarted: return "Engine not started"
        case .workerNotFound(let id): return "Worker \(id) not found"
        case .dispatchFailed(let msg): return "Dispatch failed: \(msg)"
        case .mergeFailed(let msg): return "Merge failed: \(msg)"
        case .unknown(let msg): return msg
        }
    }
}
