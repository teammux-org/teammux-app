import SwiftUI

// MARK: - PeerQuestionCardView

/// A card displaying a worker-to-worker question that the Team Lead can relay
/// or dismiss.
///
/// "Relay" calls `engine.dispatchTask(workerId:instruction:)` targeting the
/// intended recipient, then clears the peer question on success. On failure
/// the card stays visible so the Team Lead knows the relay was not delivered.
/// "Dismiss" clears the peer question without relaying.
struct PeerQuestionCardView: View {
    let question: PeerQuestion
    @ObservedObject var engine: EngineClient

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: sender → target route
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.swap")
                    .foregroundColor(.purple)
                    .font(.system(size: 14))

                Text("\(nameForId(question.fromWorkerId)) \u{2192} \(nameForId(question.targetWorkerId))")
                    .font(.system(size: 12, weight: .semibold))

                Spacer()

                Text(relativeTimestamp)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Message text
            Text(question.message)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .lineLimit(4)

            // Actions
            HStack {
                Spacer()

                Button("Dismiss") {
                    engine.clearPeerQuestion(fromWorkerId: question.fromWorkerId)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

                Button(action: relayQuestion) {
                    HStack(spacing: 3) {
                        Text("Relay")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9))
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.accentColor)
            }
        }
        .padding(10)
        .background(Color.purple.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.purple.opacity(0.2), lineWidth: 1)
        )
        .cornerRadius(6)
    }

    // MARK: - Actions

    private func relayQuestion() {
        let success = engine.dispatchTask(
            workerId: question.targetWorkerId,
            instruction: question.message
        )
        if success {
            engine.clearPeerQuestion(fromWorkerId: question.fromWorkerId)
        }
    }

    // MARK: - Helpers

    private func nameForId(_ id: UInt32) -> String {
        if id == 0 {
            return "Team Lead"
        }
        if let worker = engine.roster.first(where: { $0.id == id }) {
            return worker.name
        }
        return "Worker #\(id)"
    }

    private var relativeTimestamp: String {
        let interval = Date().timeIntervalSince(question.timestamp)
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
