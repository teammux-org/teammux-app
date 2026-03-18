import SwiftUI
import AppKit
import os

// MARK: - GitView

/// Right-pane tab showing Git status for all workers.
///
/// Displays a list grouped into "Main branch", "Active workers", and
/// optionally "Completed" sections. Each active worker row shows a status dot,
/// monospaced branch name, PR action, merge status badge, and approve/reject
/// buttons for the Team Lead review workflow.
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

    // MARK: - Computed properties

    /// Workers whose merge has not reached a terminal state.
    private var activeWorkers: [WorkerInfo] {
        engine.roster.filter { worker in
            guard let status = engine.mergeStatuses[worker.id] else { return true }
            return status != .success && status != .rejected
        }
    }

    /// Workers whose merge has reached a terminal state (success or rejected).
    private var completedWorkers: [WorkerInfo] {
        engine.roster.filter { worker in
            guard let status = engine.mergeStatuses[worker.id] else { return false }
            return status == .success || status == .rejected
        }
    }

    // MARK: - Git list

    /// Sorted PR events for display: open first, then merged, then closed;
    /// within each status group, newest first by timestamp.
    private var sortedPREvents: [PREvent] {
        engine.workerPRs.values.sorted { a, b in
            let order: (PRStatus) -> Int = { status in
                switch status {
                case .open:   return 0
                case .merged: return 1
                case .closed: return 2
                }
            }
            if order(a.status) != order(b.status) {
                return order(a.status) < order(b.status)
            }
            return a.timestamp > b.timestamp
        }
    }

    private var gitList: some View {
        List {
            if !engine.workerPRs.isEmpty {
                Section("Pull Requests") {
                    ForEach(sortedPREvents) { prEvent in
                        PRCardView(prEvent: prEvent, engine: engine)
                    }
                }
            }

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
                ForEach(activeWorkers) { worker in
                    GitWorkerRow(worker: worker, engine: engine)
                }
            }

            if !completedWorkers.isEmpty {
                Section("Completed") {
                    ForEach(completedWorkers) { worker in
                        CompletedWorkerRow(
                            worker: worker,
                            engine: engine
                        )
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - CompletedWorkerRow

/// A row in the history section showing a worker whose merge completed or was rejected.
struct CompletedWorkerRow: View {
    let worker: WorkerInfo
    @ObservedObject var engine: EngineClient

    private static let logger = Logger(subsystem: "com.teammux.app", category: "CompletedWorkerRow")

    private var mergeStatus: MergeStatus {
        guard let status = engine.mergeStatuses[worker.id] else {
            Self.logger.warning("Worker \(worker.id) in completed section but has no merge status")
            return .pending
        }
        return status
    }

    /// Try to find a completion message for this worker to get timestamp and commit hash.
    private var completionMessage: TeamMessage? {
        engine.messages.last { $0.from == worker.id && $0.type == .completion }
    }

    private var displayTimestamp: Date {
        completionMessage?.timestamp ?? worker.spawnedAt
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(mergeStatus.color)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(worker.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                Text(worker.taskDescription)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                outcomeBadge

                HStack(spacing: 4) {
                    if let commit = completionMessage?.gitCommit {
                        Text(String(commit.prefix(7)))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    Text(displayTimestamp, style: .relative)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var outcomeBadge: some View {
        switch mergeStatus {
        case .success:
            Text("Merged")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.green.opacity(0.12))
                .cornerRadius(4)
        case .rejected:
            Text("Rejected")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(4)
        default:
            Text("Unknown")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(4)
        }
    }
}

// MARK: - GitWorkerRow

/// A single row in the Git view showing a worker's branch, PR action,
/// merge status badge, and approve/reject buttons.
struct GitWorkerRow: View {
    let worker: WorkerInfo
    @ObservedObject var engine: EngineClient

    @State private var isCreatingPR = false
    @State private var prError: String?
    @State private var lastCreatedPR: GitHubPR?
    @State private var isMergeActionInFlight = false
    @State private var mergeError: String?
    @State private var showConflictSheet = false

    private var mergeStatus: MergeStatus? {
        engine.mergeStatuses[worker.id]
    }

    private var conflicts: [ConflictInfo] {
        engine.pendingConflicts[worker.id] ?? []
    }

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

                // Merge status badge
                if let status = mergeStatus {
                    mergeStatusBadge(status)
                }

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

            // Approve / Reject buttons — shown when no terminal merge status
            if shouldShowMergeActions {
                mergeActions
            }

            if let error = prError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .lineLimit(2)
            }

            if let error = mergeError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
        .onChange(of: mergeStatus) { _, newStatus in
            if newStatus == .conflict && !conflicts.isEmpty {
                showConflictSheet = true
            } else if newStatus != .conflict {
                showConflictSheet = false
            }
        }
        .onChange(of: conflicts) { _, newConflicts in
            if mergeStatus == .conflict && !newConflicts.isEmpty && !showConflictSheet {
                showConflictSheet = true
            }
        }
        .sheet(isPresented: $showConflictSheet) {
            ConflictView(
                worker: worker,
                conflicts: conflicts,
                engine: engine
            )
        }
    }

    // MARK: - Merge status badge

    private func mergeStatusBadge(_ status: MergeStatus) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)

            Text(status.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(status.color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(status.color.opacity(0.12))
        .cornerRadius(4)
    }

    // MARK: - Merge actions

    private var shouldShowMergeActions: Bool {
        guard let status = mergeStatus else {
            // No merge initiated yet — show buttons so Team Lead can approve/reject
            return true
        }
        // Show actions for pending and conflict states (re-approve or reject)
        return status == .pending || status == .conflict
    }

    private var mergeActions: some View {
        HStack(spacing: 8) {
            Button(action: approveMerge) {
                if isMergeActionInFlight {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Approve", systemImage: "checkmark.circle")
                        .font(.system(size: 10, weight: .medium))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.green)
            .disabled(isMergeActionInFlight)

            Button(action: rejectMerge) {
                Label("Reject", systemImage: "xmark.circle")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
            .disabled(isMergeActionInFlight)

            Spacer()
        }
        .padding(.leading, 16)
    }

    // MARK: - Actions

    private func approveMerge() {
        isMergeActionInFlight = true
        mergeError = nil
        Task { @MainActor in
            let success = engine.approveMerge(workerId: worker.id, strategy: .merge)
            if !success {
                mergeError = engine.lastError ?? "Failed to approve merge"
            }
            isMergeActionInFlight = false
        }
    }

    private func rejectMerge() {
        isMergeActionInFlight = true
        mergeError = nil
        Task { @MainActor in
            let success = engine.rejectMerge(workerId: worker.id)
            if !success {
                mergeError = engine.lastError ?? "Failed to reject merge"
            }
            isMergeActionInFlight = false
        }
    }

    private func createPR(for worker: WorkerInfo) {
        isCreatingPR = true
        prError = nil
        Task { @MainActor in
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

// MARK: - PRCardView

/// A card in the Pull Requests section showing a worker's PR with status badge,
/// title, branch name, and action buttons (Approve, Reject, Open in GitHub).
struct PRCardView: View {
    let prEvent: PREvent
    @ObservedObject var engine: EngineClient

    private static let logger = Logger(subsystem: "com.teammux.app", category: "PRCardView")

    @State private var isMergeActionInFlight = false
    @State private var actionError: String?

    /// Worker name from the roster, or a fallback label.
    private var workerName: String {
        engine.roster.first { $0.id == prEvent.workerId }?.name ?? "Worker \(prEvent.workerId)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: status badge + title
            HStack(spacing: 8) {
                prStatusBadge

                VStack(alignment: .leading, spacing: 2) {
                    Text(prEvent.title.isEmpty ? workerName : prEvent.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if !prEvent.branchName.isEmpty {
                        Text(prEvent.branchName)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                Text(workerName)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }

            // Actions: Approve / Reject / Open in GitHub
            HStack(spacing: 8) {
                if prEvent.status == .open {
                    Button(action: approveMerge) {
                        if isMergeActionInFlight {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Approve", systemImage: "checkmark.circle")
                                .font(.system(size: 10, weight: .medium))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.green)
                    .disabled(isMergeActionInFlight)

                    Button(action: rejectMerge) {
                        Label("Reject", systemImage: "xmark.circle")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                    .disabled(isMergeActionInFlight)
                }

                Spacer()

                if !prEvent.prUrl.isEmpty {
                    Button(action: openInGitHub) {
                        Label("Open in GitHub", systemImage: "arrow.up.right.square")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let error = actionError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Status badge

    private var prStatusBadge: some View {
        Text(prEvent.status.label)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(prEvent.status.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(prEvent.status.color.opacity(0.12))
            .cornerRadius(4)
    }

    // MARK: - Actions

    private func approveMerge() {
        isMergeActionInFlight = true
        actionError = nil
        Task { @MainActor in
            let success = engine.approveMerge(workerId: prEvent.workerId, strategy: .merge)
            if !success {
                let msg = engine.lastError ?? "Failed to approve merge"
                Self.logger.error("approveMerge failed for worker \(prEvent.workerId): \(msg)")
                actionError = msg
            }
            isMergeActionInFlight = false
        }
    }

    private func rejectMerge() {
        isMergeActionInFlight = true
        actionError = nil
        Task { @MainActor in
            let success = engine.rejectMerge(workerId: prEvent.workerId)
            if !success {
                let msg = engine.lastError ?? "Failed to reject merge"
                Self.logger.error("rejectMerge failed for worker \(prEvent.workerId): \(msg)")
                actionError = msg
            }
            isMergeActionInFlight = false
        }
    }

    private func openInGitHub() {
        guard let url = URL(string: prEvent.prUrl) else {
            let msg = "Cannot open PR: invalid URL for worker \(prEvent.workerId)"
            Self.logger.error("\(msg)")
            actionError = msg
            return
        }
        NSWorkspace.shared.open(url)
    }
}
