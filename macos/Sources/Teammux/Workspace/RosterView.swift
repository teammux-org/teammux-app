import SwiftUI

// MARK: - RosterView

/// Left pane showing the team roster: Team Lead pinned at top,
/// scrollable list of workers, and a bottom bar with spawn/settings buttons.
struct RosterView: View {
    @ObservedObject var engine: EngineClient
    @Binding var activeWorkerId: UInt32?

    @State private var showSpawnPopover = false

    var body: some View {
        VStack(spacing: 0) {
            // Team Lead — pinned, not scrollable
            TeamLeadRow(
                isActive: activeWorkerId == nil,
                onTap: {
                    activeWorkerId = nil
                }
            )

            Divider()

            // Worker list
            if engine.roster.isEmpty {
                emptyRoster
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(engine.roster) { worker in
                            WorkerRow(
                                worker: worker,
                                isActive: activeWorkerId == worker.id,
                                onTap: {
                                    activeWorkerId = worker.id
                                },
                                onDismiss: {
                                    let success = engine.dismissWorker(worker.id)
                                    if success, activeWorkerId == worker.id {
                                        activeWorkerId = nil
                                    }
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()

            // Bottom bar: spawn + settings
            bottomBar
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Empty roster

    private var emptyRoster: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "person.2.slash")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
            Text("No workers yet")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            Button(action: {
                showSpawnPopover.toggle()
            }) {
                Label("New Worker", systemImage: "plus.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSpawnPopover, arrowEdge: .top) {
                SpawnPopoverView(engine: engine, isPresented: $showSpawnPopover)
            }

            Spacer()

            Button(action: {
                // Placeholder — project settings
            }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Project Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
