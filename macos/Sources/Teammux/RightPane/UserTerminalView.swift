import SwiftUI
import GhosttyKit
import os

// MARK: - UserTerminalView

/// Right-pane tab displaying the user's own terminal session.
///
/// Creates a Ghostty surface running the user's default shell ($SHELL,
/// falling back to /bin/zsh) in the project root directory. No claude
/// binary injection, no role, no interceptor — the shell runs with the
/// user's standard environment. Follows the same lifecycle as
/// TeamLeadTerminalView (recreated on tab switch).
struct UserTerminalView: View {
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
        UserTerminalSurfaceRepresentable(
            ghosttyApp: ghosttyApp,
            projectRoot: engine.projectRoot
        )
    }

    // MARK: - Loading state

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)

            Text("Starting terminal...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - UserTerminalSurfaceRepresentable

/// NSViewRepresentable that creates a Ghostty.SurfaceView for the user's terminal.
/// Configured to run the user's default shell in the project root directory.
/// No git interceptor or PATH modifications — the shell runs with the user's
/// standard environment.
struct UserTerminalSurfaceRepresentable: NSViewRepresentable {
    private static let logger = Logger(subsystem: "com.teammux.app", category: "UserTerminalSurfaceRepresentable")

    let ghosttyApp: Ghostty.App
    let projectRoot: String?

    func makeNSView(context: Context) -> NSView {
        guard let app = ghosttyApp.app else {
            Self.logger.error("Ghostty app instance is nil — cannot create user terminal surface")
            return makeFallbackView()
        }

        var config = Ghostty.SurfaceConfiguration()

        // Use the user's default shell — no claude injection
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        config.command = shell

        if let root = projectRoot {
            config.workingDirectory = root
        } else {
            Self.logger.warning("engine.projectRoot is nil — user terminal will open in default directory instead of project root")
        }

        Self.logger.info("User terminal surface created: shell=\(shell, privacy: .public) workingDirectory=\(projectRoot ?? "<default>", privacy: .public)")

        let surfaceView = Ghostty.SurfaceView(app, baseConfig: config)
        return surfaceView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // SurfaceView manages its own lifecycle. No update needed.
    }

    private func makeFallbackView() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1.0).cgColor

        let label = NSTextField(labelWithString: "Terminal unavailable — Ghostty has not initialized.")
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
        ])

        return view
    }
}
