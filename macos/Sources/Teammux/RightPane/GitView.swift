import SwiftUI

// MARK: - GitView

/// Right-pane tab showing Git status for all workers.
///
/// Displays a list grouped into "Main branch" and "Active workers" sections.
/// Each worker row shows a status dot, monospaced branch name, and an
/// "Open PR" button placeholder.
struct GitView: View {
    @ObservedObject var engine: EngineClient

    var body: some View {
        Group {
            if engine.roster.isEmpty {
                emptyState
            } else {
                gitList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 32))
                .foregroundColor(.secondary)

            Text("No workers")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Spawn workers to see their branches here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    // MARK: - Git list

    private var gitList: some View {
        List {
            Section("Main branch") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)

                    Text("main")
                        .font(.system(size: 12, design: .monospaced))

                    Spacer()

                    Text("base")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)
                }
            }

            Section("Active workers") {
                ForEach(engine.roster) { worker in
                    GitWorkerRow(worker: worker, engine: engine)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - GitWorkerRow

/// A single row in the Git view showing a worker's branch and PR action.
struct GitWorkerRow: View {
    let worker: WorkerInfo
    @ObservedObject var engine: EngineClient

    @State private var isCreatingPR = false
    @State private var prError: String?
    @State private var lastCreatedPR: GitHubPR?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // Status dot
                Circle()
                    .fill(worker.status.color)
                    .frame(width: 8, height: 8)

                // Branch name
                VStack(alignment: .leading, spacing: 2) {
                    Text(worker.branchName)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(worker.name)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if let pr = lastCreatedPR {
                    Text("PR #\(pr.number)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.green)
                } else {
                    // Open PR button
                    Button(action: {
                        createPR(for: worker)
                    }) {
                        if isCreatingPR {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Open PR")
                                .font(.system(size: 10, weight: .medium))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isCreatingPR)
                }
            }

            if let error = prError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
    }

    private func createPR(for worker: WorkerInfo) {
        isCreatingPR = true
        prError = nil
        Task {
            let title = "\(worker.name): \(worker.taskDescription)"
            let pr = engine.createPR(
                for: worker.id,
                title: String(title.prefix(72)),
                body: "Automated PR from Teammux worker.\n\nTask: \(worker.taskDescription)"
            )
            if let pr {
                lastCreatedPR = pr
            } else {
                prError = engine.lastError ?? "Failed to create pull request"
            }
            isCreatingPR = false
        }
    }
}
