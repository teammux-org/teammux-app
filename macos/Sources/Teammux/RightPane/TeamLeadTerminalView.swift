import SwiftUI
import GhosttyKit
import os

// MARK: - TeamLeadTerminalView

/// Right-pane tab displaying the Team Lead's Claude Code terminal.
///
/// Auto-launches a Ghostty surface configured with the `claude` command
/// and the project's root directory. Shows a loading state while the
/// Ghostty app initialises.
struct TeamLeadTerminalView: View {
    @EnvironmentObject var ghosttyApp: Ghostty.App
    @ObservedObject var engine: EngineClient
    @Binding var activeTab: RightTab

    /// Workers whose merge status is .pending — these need Team Lead review.
    private var pendingWorkers: [WorkerInfo] {
        engine.roster.filter { engine.mergeStatuses[$0.id] == .pending }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if ghosttyApp.app != nil {
                    terminalSurface
                } else {
                    loadingState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !pendingWorkers.isEmpty {
                reviewBanner
            }
        }
    }

    // MARK: - Review pending banner

    private var reviewBanner: some View {
        Button(action: {
            activeTab = .git
        }) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 10))

                Text(bannerText)
                    .font(.system(size: 11, weight: .medium))

                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    private var bannerText: String {
        let count = pendingWorkers.count
        if count == 1, let worker = pendingWorkers.first {
            return "Worker \(worker.name) is ready for review"
        }
        return "\(count) workers ready for review"
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
    private static let logger = Logger(subsystem: "com.teammux.app", category: "TeamLeadSurfaceRepresentable")

    let ghosttyApp: Ghostty.App
    let projectRoot: String?

    func makeNSView(context: Context) -> NSView {
        guard let app = ghosttyApp.app else {
            Self.logger.error("Ghostty app instance is nil — cannot create Team Lead terminal surface")
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

    /// Returns an error NSView when the Ghostty app is unavailable,
    /// with a centered label explaining the issue.
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
