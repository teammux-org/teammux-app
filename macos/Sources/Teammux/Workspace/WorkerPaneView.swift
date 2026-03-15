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

            Text("Click + to spawn a new teammate")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Worker terminal stack

    private var workerStack: some View {
        ZStack {
            ForEach(engine.roster) { worker in
                WorkerTerminalView(worker: worker)
                    .opacity(activeWorkerId == worker.id ? 1 : 0)
                    .allowsHitTesting(activeWorkerId == worker.id)
            }
        }
    }
}
