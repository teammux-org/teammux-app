import SwiftUI

// MARK: - DiffView

/// Right-pane tab showing the diff of a selected worker's pull request,
/// fetched via the GitHub PR files API.
///
/// Has a worker picker dropdown at top, then renders diff files with
/// line-by-line coloring: additions in green, deletions in red, hunk headers in blue.
struct DiffView: View {
    @ObservedObject var engine: EngineClient

    @Binding var selectedWorkerId: UInt32?
    @State private var diffFiles: [DiffFile] = []
    @State private var isLoading = false
    @State private var diffError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Worker picker
            workerPicker
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            // Diff content
            diffContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if selectedWorkerId != nil && diffFiles.isEmpty && !isLoading {
                loadDiff(for: selectedWorkerId)
            }
        }
    }

    // MARK: - Worker picker

    private var workerPicker: some View {
        HStack {
            Text("Worker:")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Picker("Worker", selection: $selectedWorkerId) {
                Text("Select a worker...").tag(nil as UInt32?)

                ForEach(engine.roster) { worker in
                    Text(worker.name).tag(worker.id as UInt32?)
                }
            }
            .labelsHidden()
            .onChange(of: selectedWorkerId) { _, newValue in
                loadDiff(for: newValue)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Diff content

    @ViewBuilder
    private var diffContent: some View {
        if selectedWorkerId == nil {
            selectWorkerState
        } else if isLoading {
            loadingState
        } else if let error = diffError {
            diffErrorState(error)
        } else if diffFiles.isEmpty {
            noChangesState
        } else {
            diffFileList
        }
    }

    // MARK: - States

    private var selectWorkerState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32))
                .foregroundColor(.secondary)

            Text("Select a worker")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Choose a worker from the picker above to view their diff.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)

            Text("Loading diff...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func diffErrorState(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.red)

            Text("Failed to load diff")
                .font(.headline)
                .foregroundColor(.primary)

            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var noChangesState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundColor(.secondary)

            Text("No changes")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("No changed files found in this worker's pull request.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Diff file list

    private var diffFileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(diffFiles) { file in
                    DiffFileView(file: file)
                }
            }
            .padding(12)
        }
    }

    // MARK: - Load diff

    private func loadDiff(for workerId: UInt32?) {
        guard let workerId else {
            diffFiles = []
            diffError = nil
            return
        }

        isLoading = true
        diffError = nil
        let engine = self.engine
        Task.detached {
            let result = engine.getDiff(for: workerId)
            await MainActor.run {
                self.diffFiles = result
                // If result is empty and engine reported an error, it was an API failure
                // rather than genuinely no changes.
                if result.isEmpty, let engineError = engine.lastError {
                    self.diffError = engineError
                }
                self.isLoading = false
            }
        }
    }
}

// MARK: - DiffFileView

/// Renders a single file's diff with a header and colored patch lines.
struct DiffFileView: View {
    let file: DiffFile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // File header
            HStack {
                Text(file.status.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(file.status.color)
                    .cornerRadius(3)

                Text(file.filePath)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)

                Spacer()

                HStack(spacing: 8) {
                    Text("+\(file.additions)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.green)

                    Text("-\(file.deletions)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.red)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(4)

            // Patch lines
            let lines = file.patch.components(separatedBy: "\n")
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                DiffLineView(line: line)
            }
        }
    }
}

// MARK: - DiffLineView

/// A single line in a diff patch, colored by type:
/// - `+` lines: green background
/// - `-` lines: red background
/// - `@@` lines: blue text
/// - context lines: default
struct DiffLineView: View {
    let line: String

    var body: some View {
        Text(line)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(lineColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(lineBackground)
    }

    private var lineColor: Color {
        if line.hasPrefix("@@") {
            return .blue
        }
        return .primary
    }

    private var lineBackground: Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            return Color.green.opacity(0.12)
        } else if line.hasPrefix("-") && !line.hasPrefix("---") {
            return Color.red.opacity(0.12)
        } else if line.hasPrefix("@@") {
            return Color.blue.opacity(0.08)
        }
        return .clear
    }
}
