import SwiftUI
import os

// MARK: - ContextView

/// Right-pane tab for viewing a worker's CLAUDE.md context file.
///
/// Reads {worktreePath}/CLAUDE.md from disk for the selected worker.
/// Section headers (## prefix) rendered bold. Auto-refreshes on role
/// hot-reload with changed-line highlight. Edit button opens role TOML.
struct ContextView: View {
    @ObservedObject var engine: EngineClient

    private static let logger = Logger(subsystem: "com.teammux.app", category: "ContextView")

    @State private var selectedWorkerId: UInt32?
    @State private var claudeContent: String?
    @State private var highlightedLines: Set<Int> = []
    @State private var highlightTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            workerPicker
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            contentArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if selectedWorkerId != nil {
                loadContent()
            }
        }
        .onChange(of: selectedWorkerId) { _, _ in
            highlightTask?.cancel()
            highlightedLines = []
            loadContent()
        }
        .onChange(of: engine.hotReloadedWorkers) { oldValue, newValue in
            guard let workerId = selectedWorkerId,
                  newValue.contains(workerId),
                  !oldValue.contains(workerId) else { return }
            loadContent(diffHighlight: true)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Label("CLAUDE.md Context", systemImage: "doc.text.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)

            if let workerId = selectedWorkerId,
               engine.hotReloadedWorkers.contains(workerId) {
                Text("\u{21BB} Updated")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: engine.hotReloadedWorkers)
            }

            Spacer()

            if let workerId = selectedWorkerId,
               let roleId = engine.workerRoles[workerId]?.id,
               let tomlPath = roleTomlPath(roleId: roleId) {
                Button(action: {
                    NSWorkspace.shared.open(URL(fileURLWithPath: tomlPath))
                }) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Edit role definition (\(roleId).toml)")
            }

            Button(action: {
                loadContent()
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedWorkerId == nil)
            .help("Refresh CLAUDE.md from disk")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

            Spacer()
        }
    }

    // MARK: - Content area

    @ViewBuilder
    private var contentArea: some View {
        if selectedWorkerId == nil {
            emptyStateNoWorker
        } else if let workerId = selectedWorkerId,
                  engine.workerWorktrees[workerId] == nil {
            emptyStateNoWorktree
        } else if claudeContent == nil {
            emptyStateNoFile
        } else if let content = claudeContent {
            claudeContentView(content)
        }
    }

    // MARK: - Empty states

    private var emptyStateNoWorker: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 32))
                .foregroundColor(.secondary)

            Text("Select a worker to view their CLAUDE.md context")
                .font(.headline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyStateNoWorktree: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 32))
                .foregroundColor(.secondary)

            Text("Worker has no worktree")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Waiting for spawn to complete.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyStateNoFile: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32))
                .foregroundColor(.secondary)

            Text("No CLAUDE.md found")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("The worker's worktree does not contain a CLAUDE.md file.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - CLAUDE.md content

    private func claudeContentView(_ content: String) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let lines = content.components(separatedBy: "\n")
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    lineView(line, at: index)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func lineView(_ line: String, at index: Int) -> some View {
        Group {
            if line.hasPrefix("## ") {
                Text(String(line.dropFirst(3)))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
            } else {
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 11, design: .monospaced))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 1)
        .background(
            highlightedLines.contains(index)
                ? Color.yellow.opacity(0.3)
                : Color.clear
        )
        .animation(.easeInOut(duration: 0.3), value: highlightedLines)
    }

    // MARK: - Content loading

    private func loadContent(diffHighlight: Bool = false) {
        guard let workerId = selectedWorkerId,
              let worktreePath = engine.workerWorktrees[workerId] else {
            claudeContent = nil
            return
        }

        let filePath = "\(worktreePath)/CLAUDE.md"
        let oldContent = claudeContent

        guard let data = FileManager.default.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8) else {
            claudeContent = nil
            Self.logger.info("loadContent: CLAUDE.md not found at \(filePath)")
            return
        }

        claudeContent = content

        if diffHighlight, let oldContent {
            applyDiffHighlight(oldContent: oldContent, newContent: content)
        }
    }

    private func applyDiffHighlight(oldContent: String, newContent: String) {
        let oldLines = oldContent.components(separatedBy: "\n")
        let newLines = newContent.components(separatedBy: "\n")

        var changedIndices: Set<Int> = []
        let maxIndex = max(oldLines.count, newLines.count)

        for i in 0..<maxIndex {
            let oldLine = i < oldLines.count ? oldLines[i] : nil
            let newLine = i < newLines.count ? newLines[i] : nil
            if oldLine != newLine {
                changedIndices.insert(i)
            }
        }

        guard !changedIndices.isEmpty else { return }

        // Cancel any existing highlight timer before starting new one.
        highlightTask?.cancel()
        highlightedLines = changedIndices

        highlightTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            highlightedLines = []
        }
    }

    // MARK: - Role TOML path resolution

    /// Resolve the role TOML file path from a role ID by checking the same
    /// search paths the engine uses (project-local, user, bundle, dev-build).
    private func roleTomlPath(roleId: String) -> String? {
        let fm = FileManager.default

        // 1. Project-local: {projectRoot}/.teammux/roles/{roleId}.toml
        if let root = engine.projectRoot {
            let path = "\(root)/.teammux/roles/\(roleId).toml"
            if fm.fileExists(atPath: path) { return path }
        }

        // 2. User-level: ~/.teammux/roles/{roleId}.toml
        let userPath = NSHomeDirectory() + "/.teammux/roles/\(roleId).toml"
        if fm.fileExists(atPath: userPath) { return userPath }

        // 3. App bundle: {bundle}/Resources/roles/{roleId}.toml
        if let bundlePath = Bundle.main.resourceURL?
            .appendingPathComponent("roles/\(roleId).toml").path,
           fm.fileExists(atPath: bundlePath) { return bundlePath }

        // 4. Dev-build fallback: {projectRoot}/roles/{roleId}.toml
        if let root = engine.projectRoot {
            let devPath = "\(root)/roles/\(roleId).toml"
            if fm.fileExists(atPath: devPath) { return devPath }
        }

        return nil
    }
}
