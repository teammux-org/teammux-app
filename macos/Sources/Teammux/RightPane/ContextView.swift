import SwiftUI
import AppKit
import os

// MARK: - ContextView

/// Right-pane tab for viewing a worker's CLAUDE.md context file and
/// agent memory timeline (S13).
///
/// Renders CLAUDE.md with full inline markdown (bold, italic, code) via
/// `AttributedString(markdown:)` and header detection (TD23). Auto-refreshes
/// on role hot-reload using a reload counter dict to detect rapid repeated
/// saves within the 3-second window (TD27). Changed lines are identified
/// via LCS diff rather than positional comparison (TD28).
///
/// The Memory section displays per-worker context summaries persisted in
/// `.teammux-memory.md`. Entries are collapsible and show timestamp, task,
/// files touched, and PR link. Memory persists across session restore.
struct ContextView: View {
    @ObservedObject var engine: EngineClient

    private static let logger = Logger(subsystem: "com.teammux.app", category: "ContextView")

    @Binding var selectedWorkerId: UInt32?

    @State private var claudeContent: String?
    @State private var loadError: String?
    @State private var highlightedLines: Set<Int> = []
    @State private var highlightTask: Task<Void, Never>?
    @State private var memoryExpanded: Bool = true

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
                  let newSeq = newValue[workerId],
                  newSeq != oldValue[workerId] else { return }
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
               engine.hotReloadedWorkers[workerId] != nil {
                Text("\u{21BB} Updated")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: engine.hotReloadedWorkers[selectedWorkerId ?? 0])
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

    // MARK: - CLAUDE.md content (TD23) + Memory timeline (S13)

    private func claudeContentView(_ content: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(buildMarkdownContent(content))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                if let workerId = selectedWorkerId {
                    memorySection(workerId: workerId)
                }
            }
        }
    }

    // MARK: - Memory timeline (S13)

    @ViewBuilder
    private func memorySection(workerId: UInt32) -> some View {
        let memoryContent = engine.workerMemory[workerId]
        let entries = parseMemoryEntries(memoryContent)

        if !entries.isEmpty {
            Divider()
                .padding(.horizontal, 12)

            VStack(alignment: .leading, spacing: 0) {
                Button(action: { memoryExpanded.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: memoryExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)

                        Label("Agent Memory (\(entries.count))", systemImage: "brain")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if memoryExpanded {
                    ForEach(entries.indices, id: \.self) { idx in
                        memoryEntryView(entries[idx])
                        if idx < entries.count - 1 {
                            Divider()
                                .padding(.horizontal, 16)
                        }
                    }
                }
            }
        }
    }

    private func memoryEntryView(_ entry: MemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.timestamp)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)

            Text(buildMarkdownContent(entry.body))
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    /// Build an `AttributedString` with inline markdown styling, header
    /// formatting, and diff-highlight backgrounds applied via ranges.
    private func buildMarkdownContent(_ content: String) -> AttributedString {
        let lines = content.components(separatedBy: "\n")

        // Pre-process: convert header prefixes to bold inline syntax,
        // skipping lines inside fenced code blocks.
        var inCodeBlock = false
        let processed = lines.map { line -> String in
            if line.hasPrefix("```") {
                inCodeBlock = !inCodeBlock
                return line
            }
            guard !inCodeBlock else { return line }

            if line.hasPrefix("#### ") {
                return "**\(line.dropFirst(5))**"
            } else if line.hasPrefix("### ") {
                return "**\(line.dropFirst(4))**"
            } else if line.hasPrefix("## ") {
                return "**\(line.dropFirst(3))**"
            } else if line.hasPrefix("# ") {
                return "**\(line.dropFirst(2))**"
            }
            return line
        }.joined(separator: "\n")

        var result: AttributedString
        do {
            result = try AttributedString(
                markdown: processed,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        } catch {
            Self.logger.warning("buildMarkdownContent: markdown parse failed, falling back to plain text: \(error)")
            result = AttributedString(processed)
        }

        // Apply diff-highlight backgrounds to changed line ranges.
        if !highlightedLines.isEmpty {
            Self.applyDiffHighlights(&result, highlightedLines: highlightedLines)
        }

        return result
    }

    /// Walk the attributed string character-by-character to find line
    /// boundaries (newlines) and apply yellow background to changed lines.
    private static func applyDiffHighlights(
        _ result: inout AttributedString,
        highlightedLines: Set<Int>
    ) {
        let bgColor = Color(nsColor: NSColor.systemYellow.withAlphaComponent(0.3))
        var lineStart = result.startIndex
        var lineIndex = 0

        var current = result.startIndex
        while current < result.endIndex {
            if result.characters[current] == "\n" {
                if highlightedLines.contains(lineIndex) {
                    result[lineStart..<current].backgroundColor = bgColor
                }
                lineStart = result.characters.index(after: current)
                lineIndex += 1
            }
            current = result.characters.index(after: current)
        }
        // Last line (no trailing newline)
        if lineStart < result.endIndex && highlightedLines.contains(lineIndex) {
            result[lineStart..<result.endIndex].backgroundColor = bgColor
        }
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

    // MARK: - LCS diff highlight (TD28)

    /// Highlights truly changed lines between old and new content for 2 seconds.
    /// Uses LCS (longest common subsequence) to identify lines that were actually
    /// added, removed, or modified — eliminates false positives from shifted lines.
    private func applyDiffHighlight(oldContent: String, newContent: String) {
        let oldLines = oldContent.components(separatedBy: "\n")
        let newLines = newContent.components(separatedBy: "\n")

        let changedIndices = Self.changedLineIndices(old: oldLines, new: newLines)
        guard !changedIndices.isEmpty else { return }

        highlightTask?.cancel()
        highlightedLines = changedIndices

        highlightTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            highlightedLines = []
        }
    }

    /// Compute indices of lines in `newLines` that are NOT part of the LCS
    /// with `oldLines` — these are truly added or changed lines.
    private static func changedLineIndices(old oldLines: [String], new newLines: [String]) -> Set<Int> {
        let m = oldLines.count
        let n = newLines.count
        guard m > 0, n > 0 else { return Set(0..<n) }

        // Build LCS DP table
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if oldLines[i - 1] == newLines[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack to find which new-content line indices are in the LCS
        var lcsNewIndices: Set<Int> = []
        var i = m, j = n
        while i > 0 && j > 0 {
            if oldLines[i - 1] == newLines[j - 1] {
                lcsNewIndices.insert(j - 1)
                i -= 1
                j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }

        return Set(0..<n).subtracting(lcsNewIndices)
    }

    // MARK: - Memory entry parsing

    /// A single memory entry parsed from .teammux-memory.md.
    private struct MemoryEntry {
        let timestamp: String
        let body: String
    }

    /// Parse .teammux-memory.md content into individual entries.
    /// Format: each entry starts with `## {timestamp}` followed by body text.
    private func parseMemoryEntries(_ content: String?) -> [MemoryEntry] {
        guard let content, !content.isEmpty else { return [] }

        var entries: [MemoryEntry] = []
        var currentTimestamp: String?
        var currentBodyLines: [String] = []

        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                // Flush previous entry
                if let ts = currentTimestamp {
                    let body = currentBodyLines.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty {
                        entries.append(MemoryEntry(timestamp: ts, body: body))
                    }
                }
                currentTimestamp = String(line.dropFirst(3))
                currentBodyLines = []
            } else if line.hasPrefix("# ") {
                // Skip the file header
                continue
            } else if currentTimestamp != nil {
                currentBodyLines.append(line)
            }
        }

        // Flush last entry
        if let ts = currentTimestamp {
            let body = currentBodyLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                entries.append(MemoryEntry(timestamp: ts, body: body))
            }
        }

        // Newest first
        return entries.reversed()
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
