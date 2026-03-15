import Foundation

// MARK: - Project

/// Represents a single project tab in the workspace.
/// Each project maps to an independent Teammux engine instance.
/// Equality is by `id` only so tab identity is stable across name/path changes.
struct Project: Identifiable, Equatable {
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

    static func == (lhs: Project, rhs: Project) -> Bool {
        lhs.id == rhs.id
    }
}
