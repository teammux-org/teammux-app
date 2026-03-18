import SwiftUI

// MARK: - LiveFeedView

/// Right-pane tab showing the real-time message bus feed, with completion
/// and question card sections above the message stream.
///
/// Sections appear conditionally: completion cards when workers have signaled
/// completion, question cards when workers are awaiting Team Lead guidance.
/// The message feed auto-scrolls to the latest entry below.
struct LiveFeedView: View {
    @ObservedObject var engine: EngineClient
    @Binding var activeTab: RightTab
    @Binding var diffSelectedWorkerId: UInt32?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            feedHeader

            Divider()

            // Completion cards section
            if !engine.workerCompletions.isEmpty {
                completionSection
            }

            // Question cards section
            if !engine.workerQuestions.isEmpty {
                questionSection
            }

            // Peer question cards section
            if !engine.peerQuestions.isEmpty {
                peerQuestionSection
            }

            // Delegation informational cards section
            if !engine.peerDelegations.isEmpty {
                delegationSection
            }

            // Feed content
            if engine.messages.isEmpty {
                if engine.workerCompletions.isEmpty && engine.workerQuestions.isEmpty
                    && engine.peerQuestions.isEmpty && engine.peerDelegations.isEmpty {
                    emptyState
                }
            } else {
                feedList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Completion section

    private var completionSection: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(completionReports) { report in
                    CompletionCardView(
                        report: report,
                        engine: engine,
                        activeTab: $activeTab,
                        diffSelectedWorkerId: $diffSelectedWorkerId
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 200)
    }

    // MARK: - Question section

    private var questionSection: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(questionRequests) { request in
                    QuestionCardView(
                        request: request,
                        engine: engine
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 200)
    }

    /// Sorted completion reports for stable ForEach ordering (timestamp, then workerId tiebreak).
    private var completionReports: [CompletionReport] {
        engine.workerCompletions.values.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.workerId < $1.workerId
        }
    }

    /// Sorted question requests for stable ForEach ordering (timestamp, then workerId tiebreak).
    private var questionRequests: [QuestionRequest] {
        engine.workerQuestions.values.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.workerId < $1.workerId
        }
    }

    // MARK: - Peer question section

    private var peerQuestionSection: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(sortedPeerQuestions) { question in
                    PeerQuestionCardView(
                        question: question,
                        engine: engine
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 200)
    }

    /// Sorted peer questions for stable ForEach ordering (timestamp, then fromWorkerId tiebreak).
    private var sortedPeerQuestions: [PeerQuestion] {
        engine.peerQuestions.values.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.fromWorkerId < $1.fromWorkerId
        }
    }

    // MARK: - Delegation section

    private var delegationSection: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(recentDelegations) { delegation in
                    DelegationInfoCard(delegation: delegation, engine: engine)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 150)
    }

    /// Most recent delegations (newest first, max 10 shown in feed).
    private var recentDelegations: [PeerDelegation] {
        Array(engine.peerDelegations.suffix(10).reversed())
    }

    // MARK: - Header

    private var feedHeader: some View {
        HStack {
            Text("Live Feed")
                .font(.headline)

            Spacer()

            Text("\(engine.messages.count) events")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 32))
                .foregroundColor(.secondary)

            Text("No activity yet")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Messages between the Team Lead and workers will appear here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Feed list

    private var feedList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(engine.messages) { message in
                        LiveFeedRow(message: message, engine: engine)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
            }
            .onChange(of: engine.messages.count) { _, _ in
                // Auto-scroll to the latest message
                if let lastMessage = engine.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - LiveFeedRow

/// A single row in the Live Feed showing one message from the bus.
struct LiveFeedRow: View {
    let message: TeamMessage
    let engine: EngineClient

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Timestamp
            Text(Self.timeFormatter.string(from: message.timestamp))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 56, alignment: .leading)

            // Message type dot
            Circle()
                .fill(message.type.color)
                .frame(width: 6, height: 6)
                .padding(.top, 4)

            // Sender -> Receiver
            Text(routeLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.primary)
                .frame(minWidth: 80, alignment: .leading)

            // Payload
            Text(message.payload)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
    }

    // MARK: - Route label

    /// Formats the sender->receiver display string.
    /// Worker ID 0 is the Team Lead; otherwise lookup the worker name.
    private var routeLabel: String {
        let sender = nameForId(message.from)
        let receiver = nameForId(message.to)
        return "\(sender) -> \(receiver)"
    }

    private func nameForId(_ id: UInt32) -> String {
        if id == 0 {
            return "Lead"
        }
        if let worker = engine.roster.first(where: { $0.id == id }) {
            return worker.name
        }
        return "#\(id)"
    }
}

// MARK: - DelegationInfoCard

/// Informational card for a worker-to-worker task delegation.
/// No action buttons — the engine has already routed the delegation
/// directly to the target worker's PTY.
struct DelegationInfoCard: View {
    let delegation: PeerDelegation
    let engine: EngineClient

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "paperplane.fill")
                    .foregroundColor(.purple)
                    .font(.system(size: 12))

                Text("Delegated")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.purple)

                Spacer()

                Text("\(nameForId(delegation.fromWorkerId)) \u{2192} \(nameForId(delegation.targetWorkerId))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }

            Text(delegation.task)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .lineLimit(3)
        }
        .padding(8)
        .background(Color.purple.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.purple.opacity(0.15), lineWidth: 1)
        )
        .cornerRadius(6)
    }

    private func nameForId(_ id: UInt32) -> String {
        if id == 0 {
            return "Team Lead"
        }
        if let worker = engine.roster.first(where: { $0.id == id }) {
            return worker.name
        }
        return "Worker #\(id)"
    }
}
