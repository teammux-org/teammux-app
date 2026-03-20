import SwiftUI

// MARK: - ConflictView

/// Sheet view displaying merge conflicts for a worker's branch.
///
/// Shows each conflicting file with its type, ours/theirs content previews,
/// and per-file resolution buttons (Accept Ours / Accept Theirs / Skip).
/// The Team Lead resolves each file individually, then clicks "Finalize Merge"
/// once all files are resolved.
struct ConflictView: View {
    let worker: WorkerInfo
    @ObservedObject var engine: EngineClient
    @Environment(\.dismiss) var dismiss

    @State private var isActionInFlight = false
    @State private var actionError: String?
    @State private var cleanupWarning: String?

    private var conflicts: [ConflictInfo] {
        engine.pendingConflicts[worker.id] ?? []
    }

    /// True when all files have resolution ours or theirs.
    private var allResolved: Bool {
        let c = conflicts
        return !c.isEmpty && c.allSatisfy { $0.resolution.isResolved }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conflictList
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)

            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline)

                Text(worker.branchName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("\(conflicts.count) file\(conflicts.count == 1 ? "" : "s")")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    private var headerTitle: String {
        if let role = engine.workerRoles[worker.id] {
            return "Merge conflict in \(worker.name)'s \(role.emoji) \(role.name) branch"
        }
        return "Merge conflict in \(worker.name)'s branch"
    }

    // MARK: - Conflict list

    private var conflictList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(conflicts) { conflict in
                    ConflictFileRow(
                        conflict: conflict,
                        workerId: worker.id,
                        engine: engine
                    )
                }
            }
            .padding()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            if let error = actionError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .lineLimit(2)
            }

            if let warning = cleanupWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                Button(action: finalizeMerge) {
                    if isActionInFlight {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Finalize Merge", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .disabled(isActionInFlight || !allResolved)
                .help(allResolved ? "Complete the merge" : "Resolve all files first")

                Button(action: reject) {
                    Label("Reject", systemImage: "xmark.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isActionInFlight)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .disabled(isActionInFlight)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func finalizeMerge() {
        isActionInFlight = true
        actionError = nil
        cleanupWarning = nil
        Task { @MainActor in
            let success = engine.finalizeMerge(workerId: worker.id)
            if success {
                if let warning = engine.lastError {
                    cleanupWarning = warning
                } else {
                    dismiss()
                }
            } else {
                actionError = engine.lastError ?? "Finalize merge failed"
            }
            isActionInFlight = false
        }
    }

    private func reject() {
        isActionInFlight = true
        actionError = nil
        cleanupWarning = nil
        Task { @MainActor in
            let success = engine.rejectMerge(workerId: worker.id)
            if success {
                if let warning = engine.lastError {
                    cleanupWarning = warning
                } else {
                    dismiss()
                }
            } else {
                actionError = engine.lastError ?? "Reject failed"
            }
            isActionInFlight = false
        }
    }
}

// MARK: - ConflictFileRow

/// A single conflict entry showing file path, conflict type, resolution badge,
/// ours/theirs content previews, and per-file resolution buttons.
struct ConflictFileRow: View {
    let conflict: ConflictInfo
    let workerId: UInt32
    @ObservedObject var engine: EngineClient

    @State private var isResolving = false
    @State private var resolveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // File path, conflict type, and resolution badge
            HStack(spacing: 8) {
                Image(systemName: conflict.resolution.isResolved ? "checkmark.circle.fill" : "doc.text")
                    .font(.system(size: 10))
                    .foregroundColor(conflict.resolution.isResolved ? .green : .red)

                Text(conflict.filePath)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                // Resolution badge
                Text(conflict.resolution.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(conflict.resolution.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(conflict.resolution.color.opacity(0.12))
                    .cornerRadius(4)

                Text(conflict.conflictType.displayName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(4)
            }

            // Ours preview
            if let ours = conflict.ours, !ours.isEmpty {
                conflictPreview(label: "ours (main)", content: ours, color: .green)
            }

            // Theirs preview
            if let theirs = conflict.theirs, !theirs.isEmpty {
                conflictPreview(label: "theirs (worker)", content: theirs, color: .blue)
            }

            // Resolution buttons
            HStack(spacing: 8) {
                Button(action: { resolve(.ours) }) {
                    Label("Accept Ours", systemImage: "arrow.left.circle")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.green)
                .disabled(isResolving || conflict.resolution == .ours)

                Button(action: { resolve(.theirs) }) {
                    Label("Accept Theirs", systemImage: "arrow.right.circle")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.blue)
                .disabled(isResolving || conflict.resolution == .theirs)

                Button(action: { resolve(.skip) }) {
                    Label("Skip", systemImage: "forward.circle")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.orange)
                .disabled(isResolving || conflict.resolution == .skip)

                if isResolving {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()
            }

            if let error = resolveError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }

    private func resolve(_ resolution: ConflictResolution) {
        isResolving = true
        resolveError = nil
        Task { @MainActor in
            let success = engine.resolveConflict(
                workerId: workerId,
                filePath: conflict.filePath,
                resolution: resolution
            )
            if !success {
                resolveError = engine.lastError ?? "Resolution failed"
            }
            isResolving = false
        }
    }

    private func conflictPreview(label: String, content: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(color)

            Text(content)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(color.opacity(0.06))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(color.opacity(0.2), lineWidth: 1)
                )
        }
    }
}
