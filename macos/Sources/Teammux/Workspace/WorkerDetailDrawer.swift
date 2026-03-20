import SwiftUI

// MARK: - WorkerDetailDrawer

/// Collapsible detail panel shown below the roster list in the left sidebar.
/// Displays worker metadata: role, task description, branch, worktree path,
/// spawn timestamp, and PR status when available.
struct WorkerDetailDrawer: View {
    let worker: WorkerInfo
    @ObservedObject var engine: EngineClient

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Role header
            roleHeader

            // Task description
            Text(worker.taskDescription)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // Branch row
            if let branch = engine.workerBranches[worker.id] {
                copyableRow(label: "Branch", value: branch)
            }

            // Path row
            if let path = engine.workerWorktrees[worker.id] {
                copyableRow(label: "Path", value: path, truncate: true)
            }

            // Spawn timestamp
            HStack(spacing: 4) {
                Text("Spawned")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text(worker.spawnedAt, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            // Health status
            Divider()
            healthSection

            // PR status row — only shown when a PR exists for this worker
            if let prEvent = engine.workerPRs[worker.id] {
                Divider()
                prRow(prEvent: prEvent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    // MARK: - Role header

    private var roleHeader: some View {
        let role = engine.workerRoles[worker.id]
        return HStack(spacing: 6) {
            if let emoji = role?.emoji, !emoji.isEmpty {
                Text(emoji)
                    .font(.system(size: 16))
            }
            Text(role?.name ?? worker.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
    }

    // MARK: - Copyable row

    private func copyableRow(label: String, value: String, truncate: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)

            Text(truncate ? abbreviatePath(value) : value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)

            Spacer()

            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy \(label.lowercased())")
        }
    }

    // MARK: - Health section

    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Health")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)

                Circle()
                    .fill(worker.healthStatus.color)
                    .frame(width: 6, height: 6)

                Text(worker.healthStatus.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(worker.healthStatus.color)
            }

            HStack(spacing: 4) {
                Text("Last activity")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text(worker.lastActivityTs, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if worker.healthStatus == .stalled || worker.healthStatus == .errored {
                Button(action: {
                    _ = engine.restartWorker(id: worker.id)
                }) {
                    Label("Restart Worker", systemImage: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.orange)
            }
        }
    }

    // MARK: - PR row

    private func prRow(prEvent: PREvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("PR")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)

                Circle()
                    .fill(prEvent.status.color)
                    .frame(width: 6, height: 6)

                Text(prEvent.status.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(prEvent.status.color)
            }

            Text(prEvent.title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let url = URL(string: prEvent.prUrl) {
                Button(action: {
                    NSWorkspace.shared.open(url)
                }) {
                    Label("Open in GitHub", systemImage: "arrow.up.right.square")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
        }
    }

    // MARK: - Path abbreviation

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.replacingOccurrences(of: home, with: "~")
    }
}
