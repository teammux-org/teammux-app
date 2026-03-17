import SwiftUI

// MARK: - ConflictView

/// Sheet view displaying merge conflicts for a worker's branch.
///
/// Shows each conflicting file with its type and read-only ours/theirs content
/// previews. The Team Lead reviews the conflicts then chooses "Force Merge"
/// (calls `approveMerge` again) or "Reject" as the resolution. Per-file
/// resolution is not supported by the engine API — this view is informational
/// + action footer.
struct ConflictView: View {
    let worker: WorkerInfo
    let conflicts: [ConflictInfo]
    @ObservedObject var engine: EngineClient
    @Environment(\.dismiss) var dismiss

    @State private var isActionInFlight = false
    @State private var actionError: String?

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
                Text("Merge conflict in \(worker.name)'s branch")
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

    // MARK: - Conflict list

    private var conflictList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(conflicts) { conflict in
                    ConflictFileRow(conflict: conflict)
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

            HStack(spacing: 12) {
                Button(action: forceMerge) {
                    if isActionInFlight {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Force Merge", systemImage: "arrow.triangle.merge")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(isActionInFlight)

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

    private func forceMerge() {
        isActionInFlight = true
        actionError = nil
        Task { @MainActor in
            let success = engine.approveMerge(workerId: worker.id, strategy: .merge)
            if success {
                dismiss()
            } else {
                actionError = engine.lastError ?? "Force merge failed"
            }
            isActionInFlight = false
        }
    }

    private func reject() {
        isActionInFlight = true
        actionError = nil
        Task { @MainActor in
            let success = engine.rejectMerge(workerId: worker.id)
            if success {
                dismiss()
            } else {
                actionError = engine.lastError ?? "Reject failed"
            }
            isActionInFlight = false
        }
    }
}

// MARK: - ConflictFileRow

/// A single conflict entry showing file path, conflict type, and read-only
/// ours/theirs content previews.
struct ConflictFileRow: View {
    let conflict: ConflictInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // File path and conflict type
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundColor(.red)

                Text(conflict.filePath)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

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
                conflictPreview(label: "ours", content: ours, color: .green)
            }

            // Theirs preview
            if let theirs = conflict.theirs, !theirs.isEmpty {
                conflictPreview(label: "theirs", content: theirs, color: .red)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
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
