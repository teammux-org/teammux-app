import SwiftUI
import GhosttyKit

// MARK: - ContentView

/// Root view for the Teammux window.
///
/// Routes between the setup flow (when no project is active)
/// and the workspace (when a project is open).
struct ContentView: View {
    @EnvironmentObject var ghosttyApp: Ghostty.App
    @EnvironmentObject var projectManager: ProjectManager

    var body: some View {
        Group {
            if projectManager.hasActiveProject {
                WorkspaceView()
            } else {
                SetupView()
            }
        }
    }
}

// MARK: - WorkspaceView (placeholder)

/// Placeholder for the three-pane workspace layout.
/// Will be replaced by Task 5 (Stream 3).
struct WorkspaceView: View {
    @EnvironmentObject var projectManager: ProjectManager

    var body: some View {
        VStack {
            if let project = projectManager.activeProject {
                Text("Workspace — \(project.name)")
                    .font(.title2)
                    .foregroundColor(.secondary)
            } else {
                Text("Workspace — coming soon")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
