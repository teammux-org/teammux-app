import SwiftUI
import GhosttyKit
import os

// MARK: - WorkerTerminalView

/// SwiftUI wrapper that composes the terminal surface with overlay banners.
///
/// Observes `engine.hotReloadedWorkers` to show a transient "role updated"
/// banner when the worker's role TOML file changes. The banner auto-dismisses
/// after 3 seconds (managed by EngineClient).
struct WorkerTerminalView: View {
    let worker: WorkerInfo
    @ObservedObject var engine: EngineClient

    var body: some View {
        WorkerTerminalSurface(worker: worker, engine: engine)
            .overlay(alignment: .top) {
                if engine.hotReloadedWorkers[worker.id] != nil {
                    hotReloadBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 8)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: engine.hotReloadedWorkers[worker.id])
    }

    // MARK: - Hot-reload banner

    private var hotReloadBanner: some View {
        Text("\u{21BB} Role updated — context refreshed")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - WorkerTerminalSurface

/// NSViewRepresentable wrapping a Ghostty.SurfaceView for a single worker.
///
/// Creates a terminal surface configured with the worker's agent binary,
/// worktree path, and task description as initial input. Falls back to
/// a plain black NSView if the Ghostty app instance is not available.
private struct WorkerTerminalSurface: NSViewRepresentable {
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

        // Prepend interceptor wrapper directory to PATH so the git
        // wrapper script shadows the real git binary in this PTY session.
        if let interceptorDir = engine.interceptorPath(for: worker.id) {
            let existingPath = config.environmentVariables["PATH"]
                ?? ProcessInfo.processInfo.environment["PATH"]
                ?? "/usr/bin:/usr/local/bin"
            config.environmentVariables["PATH"] = "\(interceptorDir):\(existingPath)"
        } else {
            Self.logger.warning("No interceptor path for worker \(worker.id) — git interception will not be active")
        }

        // Send the task description as initial input so the agent
        // starts working on it immediately — but only on first spawn.
        // On restart (generation > 0), the worker resumes in the same
        // worktree with existing context; re-injecting would cause
        // duplicate work (C4).
        let isRestart = (engine.restartGeneration[worker.id] ?? 0) > 0
        if !worker.taskDescription.isEmpty && !isRestart {
            config.initialInput = worker.taskDescription + "\n"
        }

        let surfaceView = Ghostty.SurfaceView(app, baseConfig: config)
        let workerId = worker.id
        engine.registerSurface(surfaceView, for: workerId) { [weak surfaceView] text in
            guard let surface = surfaceView else {
                Logger(subsystem: "com.teammux.app", category: "WorkerTerminalView")
                    .warning("injector: surfaceView deallocated for worker \(workerId) — text not injected")
                return
            }
            guard let model = surface.surfaceModel else {
                Logger(subsystem: "com.teammux.app", category: "WorkerTerminalView")
                    .warning("injector: surfaceModel is nil for worker \(workerId) — text not injected")
                return
            }
            model.sendText(text)
        }
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
