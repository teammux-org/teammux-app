import Foundation

// MARK: - Project

/// Represents a single project tab in the workspace.
/// Each project maps to an independent Teammux engine instance.
/// Uses synthesized `Equatable` so SwiftUI detects changes across all fields.
struct Project: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    let path: URL
    var hasUnseenActivity: Bool

    init(
        id: UUID = UUID(),
        name: String,
        path: URL,
        hasUnseenActivity: Bool = false
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.hasUnseenActivity = hasUnseenActivity
    }
}
