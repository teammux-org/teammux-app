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
        HStack(spacing: 6) {
            if let role = engine.workerRoles[worker.id] {
                if !role.emoji.isEmpty {
                    Text(role.emoji)
                        .font(.system(size: 16))
                }
                Text(role.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            } else {
                Text(worker.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
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
                    .foregroundColor(prEvent.status.color)
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

    /// Abbreviates a worktree path by replacing the home directory with ~
    /// and showing only the last 3 path components if the path is long.
    private func abbreviatePath(_ path: String) -> String {
        var display = path
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            display = display.replacingOccurrences(of: home, with: "~")
        }
        let components = display.split(separator: "/")
        if components.count > 4 {
            let tail = components.suffix(3).joined(separator: "/")
            return "~/\u{2026}/\(tail)"
        }
        return display
    }
}
