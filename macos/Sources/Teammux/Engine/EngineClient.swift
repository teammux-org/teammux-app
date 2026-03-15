import Foundation
import OSLog

// Stub — fully implemented in Stream 3
// This file exists to confirm the header bridge compiles
class EngineClient {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.teammux.app",
        category: "EngineClient"
    )

    static func version() -> String {
        guard let ptr = tm_version() else {
            logger.warning("tm_version() returned null")
            return "unknown"
        }
        return String(cString: ptr)
    }
}
