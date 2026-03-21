import SwiftUI
import GhosttyKit

// MARK: - WorkerPaneView

/// Centre pane showing terminal surfaces for worker agents.
///
/// When no workers exist, shows an empty state prompting the user to spawn one.
/// When populated, layers all worker terminals in a ZStack, toggling visibility
/// via opacity and hit-testing based on the active worker selection.
struct WorkerPaneView: View {
    @ObservedObject var engine: EngineClient
    @Binding var activeWorkerId: UInt32?

    var body: some View {
        Group {
            if engine.roster.isEmpty {
                emptyState
            } else {
                workerStack
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 36))
                .foregroundColor(.secondary)

            Text("No workers yet")
                .font(.headline)
                .foregroundColor(.secondary)

            Text(engine.availableRoles.isEmpty
                 ? "Click + to spawn a new teammate"
                 : "Spawn a worker with a role to get started")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Worker terminal stack

    private var workerStack: some View {
        ZStack {
            ForEach(engine.roster) { worker in
                let gen = engine.restartGeneration[worker.id] ?? 0
                WorkerTerminalView(worker: worker, engine: engine)
                    // C4: Generation-based identity forces SwiftUI to destroy
                    // the old NSViewRepresentable and call makeNSView fresh on
                    // restart, spawning a new PTY surface in the same worktree.
                    .id(WorkerSurfaceIdentity(workerId: worker.id, generation: gen))
                    .opacity(activeWorkerId == worker.id ? 1 : 0)
                    .allowsHitTesting(activeWorkerId == worker.id)
            }
        }
    }
}

// MARK: - Surface identity

/// Hashable identity combining worker ID and restart generation.
/// When the generation bumps, SwiftUI treats it as a new view and
/// recreates the underlying WorkerTerminalSurface (C4 PTY respawn).
private struct WorkerSurfaceIdentity: Hashable {
    let workerId: UInt32
    let generation: UInt64
}
