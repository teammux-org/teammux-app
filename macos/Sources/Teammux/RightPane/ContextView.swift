import SwiftUI
import os

// MARK: - ContextView

/// Right-pane tab for viewing a worker's CLAUDE.md context file.
///
/// Reads {worktreePath}/CLAUDE.md from disk for the selected worker.
/// Level-2 section headers (## prefix) are rendered bold; other heading
/// levels are displayed as plain text (TD23). Auto-refreshes on role
/// hot-reload with changed-line highlight. Edit button opens the worker's
/// role TOML (visible only when a role is assigned and its file is found).
struct ContextView: View {
    @ObservedObject var engine: EngineClient

    private static let logger = Logger(subsystem: "com.teammux.app", category: "ContextView")

    @Binding var selectedWorkerId: UInt32?

    @State private var claudeContent: String?
    @State private var loadError: String?
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
            loadError = nil
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
                    let opened = NSWorkspace.shared.open(URL(fileURLWithPath: tomlPath))
                    if !opened {
                        Self.logger.warning("Failed to open role TOML at \(tomlPath) — no default app for .toml?")
                    }
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
            emptyState(icon: "doc.text",
                       title: "Select a worker to view their CLAUDE.md context")
        } else if let workerId = selectedWorkerId,
                  engine.workerWorktrees[workerId] == nil {
            emptyState(icon: "clock",
                       title: "Worker has no worktree",
                       subtitle: "Waiting for spawn to complete.")
        } else if let error = loadError {
            emptyState(icon: "exclamationmark.triangle",
                       title: "Could not read CLAUDE.md",
                       subtitle: error)
        } else if let content = claudeContent {
            claudeContentView(content)
        } else {
            emptyState(icon: "doc.text.magnifyingglass",
                       title: "No CLAUDE.md found",
                       subtitle: "The worker's worktree does not contain a CLAUDE.md file.")
        }
    }

    // MARK: - Empty state

    private func emptyState(icon: String, title: String, subtitle: String? = nil) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(.secondary)

            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
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
        let isHeader = line.hasPrefix("## ")
        let displayText = isHeader ? String(line.dropFirst(3)) : (line.isEmpty ? " " : line)
        let weight: Font.Weight = isHeader ? .bold : .regular

        return Text(displayText)
            .font(.system(size: 11, weight: weight, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1)
            .background(highlightedLines.contains(index) ? Color.yellow.opacity(0.3) : Color.clear)
            .animation(.easeInOut(duration: 0.3), value: highlightedLines)
    }

    // MARK: - Content loading

    private func loadContent(diffHighlight: Bool = false) {
        guard let workerId = selectedWorkerId,
              let worktreePath = engine.workerWorktrees[workerId] else {
            claudeContent = nil
            loadError = nil
            return
        }

        let filePath = "\(worktreePath)/CLAUDE.md"
        let oldContent = claudeContent

        guard let data = FileManager.default.contents(atPath: filePath) else {
            claudeContent = nil
            loadError = nil
            Self.logger.info("loadContent: CLAUDE.md not found at \(filePath)")
            return
        }

        guard let content = String(data: data, encoding: .utf8) else {
            claudeContent = nil
            loadError = "CLAUDE.md exists but could not be decoded as UTF-8 (\(data.count) bytes)"
            Self.logger.warning("loadContent: CLAUDE.md at \(filePath) is not valid UTF-8 (\(data.count) bytes)")
            return
        }

        claudeContent = content
        loadError = nil

        if diffHighlight, let oldContent {
            applyDiffHighlight(oldContent: oldContent, newContent: content)
        }
    }

    /// Highlights lines that differ between old and new content for 2 seconds.
    /// Uses positional comparison (not LCS/Myers diff), so an insertion or
    /// deletion will mark all subsequent shifted lines as changed (TD28).
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
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            highlightedLines = []
        }
    }

    // MARK: - Role TOML path resolution

    /// Resolve the role TOML file path from a role ID. Checks search paths
    /// that approximate the engine's resolution order (project-local, user,
    /// bundle, dev-build). The dev-build path uses projectRoot instead of the
    /// engine's exe_dir since exe_dir is not accessible from Swift.
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
        // (engine uses {exe_dir}/roles/ but exe_dir is not accessible from Swift;
        // projectRoot matches the repo layout during development)
        if let root = engine.projectRoot {
            let devPath = "\(root)/roles/\(roleId).toml"
            if fm.fileExists(atPath: devPath) { return devPath }
        }

        Self.logger.debug("roleTomlPath: no TOML found for role '\(roleId)' in any search path")
        return nil
    }
}
