import Foundation

// Stub — fully implemented in Stream 3
// This file exists to confirm the header bridge compiles
class EngineClient {
    static func version() -> String {
        return String(cString: tm_version())
    }
}
