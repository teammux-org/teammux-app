import SwiftUI

// MARK: - CompletionCardView

/// A card displaying a worker's completion signal with actions to view the
/// diff or dismiss the notification.
///
/// "View Diff" switches the right pane to the Diff tab and pre-selects the
/// completing worker. "Dismiss" calls `engine.acknowledgeCompletion(workerId:)`.
struct CompletionCardView: View {
    let report: CompletionReport
    @ObservedObject var engine: EngineClient
    @Binding var activeTab: RightTab
    @Binding var diffSelectedWorkerId: UInt32?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: worker name
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 14))

                Text(workerName)
                    .font(.system(size: 12, weight: .semibold))

                Spacer()

                Text(relativeTimestamp)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Summary
            Text(report.summary)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .lineLimit(3)

            // Commit hash (if available)
            if let commit = report.gitCommit, !commit.isEmpty {
                HStack(spacing: 4) {
                    Text("Commit:")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    Text(String(commit.prefix(7)))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            // Actions
            HStack {
                Spacer()

                Button("View Diff") {
                    diffSelectedWorkerId = report.workerId
                    activeTab = .diff
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.accentColor)

                Button("Dismiss") {
                    engine.acknowledgeCompletion(workerId: report.workerId)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(Color.green.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.green.opacity(0.2), lineWidth: 1)
        )
        .cornerRadius(6)
    }

    // MARK: - Helpers

    private var workerName: String {
        if let worker = engine.roster.first(where: { $0.id == report.workerId }) {
            return worker.name
        }
        return "Worker #\(report.workerId)"
    }

    private var relativeTimestamp: String {
        let interval = Date().timeIntervalSince(report.timestamp)
        let minutes = Int(interval / 60)
        if minutes < 1 {
            return "just now"
        } else if minutes == 1 {
            return "1 min ago"
        } else if minutes < 60 {
            return "\(minutes) mins ago"
        } else {
            let hours = minutes / 60
            return hours == 1 ? "1 hr ago" : "\(hours) hrs ago"
        }
    }
}
