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

// NOTE: WorkspaceView is now defined in Workspace/WorkspaceView.swift
