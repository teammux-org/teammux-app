import SwiftUI
import GhosttyKit
import os

// MARK: - WorkerTerminalView

/// NSViewRepresentable wrapping a Ghostty.SurfaceView for a single worker.
///
/// Creates a terminal surface configured with the worker's agent binary,
/// worktree path, and task description as initial input. Falls back to
/// a plain black NSView if the Ghostty app instance is not available.
struct WorkerTerminalView: NSViewRepresentable {
    private static let logger = Logger(subsystem: "com.teammux.app", category: "WorkerTerminalView")

    @EnvironmentObject var ghosttyApp: Ghostty.App

    let worker: WorkerInfo
    let engine: EngineClient

    func makeNSView(context: Context) -> NSView {
        guard let app = ghosttyApp.app else {
            Self.logger.error("Ghostty app instance is nil — cannot create terminal for worker \(self.worker.id)")
            return makeFallbackView()
        }

        var config = Ghostty.SurfaceConfiguration()
        config.command = worker.agentBinary
        config.workingDirectory = worker.worktreePath

        // Send the task description as initial input so the agent
        // starts working on it immediately.
        if !worker.taskDescription.isEmpty {
            config.initialInput = worker.taskDescription + "\n"
        }

        let surfaceView = Ghostty.SurfaceView(app, baseConfig: config)
        engine.registerSurface(surfaceView, for: worker.id)
        return surfaceView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // SurfaceView manages its own updates internally.
        // No additional update logic needed.
    }

    // MARK: - Fallback

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
