import SwiftUI
import GhosttyKit

// MARK: - WorkspaceView

/// The three-pane workspace layout for a Teammux project.
///
/// Layout (top to bottom):
///   - ProjectTabBar (38px fixed height)
///   - HSplitView with three panes:
///     - Left: RosterView (worker list + spawn button)
///     - Centre: WorkerPaneView (terminal surfaces for workers)
///     - Right: RightPaneView (Team Lead terminal, Git, Diff, Live Feed)
struct WorkspaceView: View {
    @EnvironmentObject var projectManager: ProjectManager
    @EnvironmentObject var ghosttyApp: Ghostty.App

    /// The currently focused worker. `nil` means Team Lead is focused.
    @State private var activeWorkerId: UInt32? = nil

    var body: some View {
        if let engine = projectManager.activeEngine {
            workspaceContent(engine: engine)
        } else {
            emptyState
        }
    }

    // MARK: - Workspace content

    @ViewBuilder
    private func workspaceContent(engine: EngineClient) -> some View {
        VStack(spacing: 0) {
            ProjectTabBar()
                .frame(height: 38)

            HSplitView {
                RosterView(
                    engine: engine,
                    activeWorkerId: $activeWorkerId
                )
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)

                WorkerPaneView(
                    engine: engine,
                    activeWorkerId: $activeWorkerId
                )
                .frame(minWidth: 400)

                RightPaneView(engine: engine)
                    .frame(minWidth: 320, idealWidth: 420)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No active project")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Select or create a project to get started.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
