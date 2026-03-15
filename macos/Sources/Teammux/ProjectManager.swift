import Foundation
import SwiftUI
import os

// MARK: - ProjectManager

/// Manages the set of open projects (tabs) in the Teammux workspace.
///
/// Each project maps to an independent `EngineClient` instance.
/// The active project determines which pane content is shown.
@MainActor
final class ProjectManager: ObservableObject {

    // MARK: - Logger

    private static let logger = Logger(subsystem: "com.teammux.app", category: "ProjectManager")

    // MARK: - Published state

    @Published private(set) var projects: [Project] = []
    @Published var activeProjectId: UUID?

    // MARK: - Computed properties

    /// The currently selected project, if any.
    var activeProject: Project? {
        guard let activeProjectId else { return nil }
        return projects.first { $0.id == activeProjectId }
    }

    /// The engine for the currently selected project, if any.
    var activeEngine: EngineClient? {
        guard let activeProjectId else { return nil }
        return engines[activeProjectId]
    }

    /// True when at least one project is open and selected.
    var hasActiveProject: Bool {
        activeProject != nil
    }

    // MARK: - Private state

    /// One engine per project, keyed by project id.
    private var engines: [UUID: EngineClient] = [:]

    // MARK: - UserDefaults key

    private static let recentsKey = "com.teammux.recentProjects"

    // MARK: - Project management

    /// Create and register a new project from a name and directory path.
    /// Returns the newly created `Project`.
    @discardableResult
    func addProject(name: String, path: URL) -> Project {
        let project = Project(name: name, path: path)
        projects.append(project)
        activeProjectId = project.id

        // Create an engine for this project
        let engine = EngineClient()
        engines[project.id] = engine

        // Record in recents
        var recents = loadRecents()
        recents.removeAll { $0 == path }
        recents.insert(path, at: 0)
        // Keep at most 10 recents
        if recents.count > 10 {
            recents = Array(recents.prefix(10))
        }
        saveRecents(recents)

        return project
    }

    /// Switch the active project to the given id.
    func activate(_ projectId: UUID) {
        guard projects.contains(where: { $0.id == projectId }) else { return }
        activeProjectId = projectId
    }

    /// Close a project, tearing down its engine.
    func closeProject(_ projectId: UUID) {
        if let engine = engines[projectId] {
            engine.destroy()
        }
        engines.removeValue(forKey: projectId)
        projects.removeAll { $0.id == projectId }

        // If we closed the active project, activate the first remaining one
        if activeProjectId == projectId {
            activeProjectId = projects.first?.id
        }
    }

    /// Present an NSOpenPanel for the user to choose a new project directory.
    func openNewProject() {
        let panel = NSOpenPanel()
        panel.title = "Select Project Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            let gitDir = url.appendingPathComponent(".git")
            guard FileManager.default.fileExists(atPath: gitDir.path) else {
                Self.logger.warning("openNewProject: \(url.path) is not a git repository")
                let alert = NSAlert()
                alert.messageText = "Not a Git Repository"
                alert.informativeText = "\(url.lastPathComponent) does not appear to be a git repository. Teammux requires a git repo to manage agent worktrees."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
            _ = addProject(name: url.lastPathComponent, path: url)
        }
    }

    /// Retrieve the engine for a specific project id.
    func engine(for projectId: UUID) -> EngineClient? {
        engines[projectId]
    }

    // MARK: - Recents

    /// Load the list of recently opened project URLs from UserDefaults.
    func loadRecents() -> [URL] {
        guard let bookmarks = UserDefaults.standard.array(forKey: Self.recentsKey) as? [String] else {
            return []
        }
        return bookmarks.compactMap { URL(fileURLWithPath: $0) }
    }

    /// Persist the recents list to UserDefaults.
    private func saveRecents(_ urls: [URL]) {
        let paths = urls.map { $0.path }
        UserDefaults.standard.set(paths, forKey: Self.recentsKey)
    }
}
