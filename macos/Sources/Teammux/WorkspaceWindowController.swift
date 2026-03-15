import AppKit
import SwiftUI
import GhosttyKit

// MARK: - WorkspaceWindowController

/// Manages the single Teammux workspace window.
///
/// Creates an `NSWindow` hosting the SwiftUI `ContentView` tree,
/// injecting `Ghostty.App` and `ProjectManager` as environment objects.
class WorkspaceWindowController: NSWindowController {

    // MARK: - Dependencies

    private let ghosttyApp: Ghostty.App
    private let projectManager: ProjectManager

    // MARK: - Init

    init(ghosttyApp: Ghostty.App, projectManager: ProjectManager) {
        self.ghosttyApp = ghosttyApp
        self.projectManager = projectManager

        let contentView = ContentView()
            .environmentObject(ghosttyApp)
            .environmentObject(projectManager)

        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Teammux"
        window.minSize = NSSize(width: 1100, height: 700)
        window.contentViewController = hostingController
        window.setFrameAutosaveName("TeammuxWorkspaceWindow")
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WorkspaceWindowController does not support NSCoder")
    }
}
