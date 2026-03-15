import SwiftUI
import GhosttyKit

// MARK: - WorkerTerminalView

/// NSViewRepresentable wrapping a Ghostty.SurfaceView for a single worker.
///
/// Creates a terminal surface configured with the worker's agent binary,
/// worktree path, and task description as initial input. Falls back to
/// a plain black NSView if the Ghostty app instance is not available.
struct WorkerTerminalView: NSViewRepresentable {
    @EnvironmentObject var ghosttyApp: Ghostty.App

    let worker: WorkerInfo
    let engine: EngineClient

    func makeNSView(context: Context) -> NSView {
        guard let app = ghosttyApp.app else {
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

    /// Returns a plain black NSView when the Ghostty app is unavailable.
    private func makeFallbackView() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        return view
    }
}
