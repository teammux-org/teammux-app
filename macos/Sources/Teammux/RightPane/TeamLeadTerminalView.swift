import SwiftUI
import GhosttyKit

// MARK: - TeamLeadTerminalView

/// Right-pane tab displaying the Team Lead's Claude Code terminal.
///
/// Auto-launches a Ghostty surface configured with the `claude` command
/// and the project's root directory. Shows a loading state while the
/// Ghostty app initialises.
struct TeamLeadTerminalView: View {
    @EnvironmentObject var ghosttyApp: Ghostty.App
    @ObservedObject var engine: EngineClient

    var body: some View {
        Group {
            if ghosttyApp.app != nil {
                terminalSurface
            } else {
                loadingState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Terminal surface

    private var terminalSurface: some View {
        TeamLeadSurfaceRepresentable(
            ghosttyApp: ghosttyApp,
            projectRoot: engine.projectRoot
        )
    }

    // MARK: - Loading state

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)

            Text("Starting Team Lead...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - TeamLeadSurfaceRepresentable

/// NSViewRepresentable that creates a Ghostty.SurfaceView for the Team Lead.
/// Configured to run `claude` in the project root directory.
struct TeamLeadSurfaceRepresentable: NSViewRepresentable {
    let ghosttyApp: Ghostty.App
    let projectRoot: String?

    func makeNSView(context: Context) -> NSView {
        guard let app = ghosttyApp.app else {
            return makeFallbackView()
        }

        var config = Ghostty.SurfaceConfiguration()
        config.command = "claude"

        if let root = projectRoot {
            config.workingDirectory = root
        }

        let surfaceView = Ghostty.SurfaceView(app, baseConfig: config)
        return surfaceView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // SurfaceView manages its own lifecycle. No update needed.
    }

    /// Returns a plain black NSView as fallback when the Ghostty app is unavailable.
    private func makeFallbackView() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        return view
    }
}
