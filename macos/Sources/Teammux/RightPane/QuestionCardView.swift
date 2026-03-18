import SwiftUI

// MARK: - QuestionCardView

/// A card displaying a worker's question with an inline text field for the
/// Team Lead's response.
///
/// "Dispatch" calls `engine.dispatchResponse(workerId:response:)` and clears the
/// question only on success. On failure the card stays visible so the Team Lead
/// knows the response was not delivered.
/// "Dismiss" clears the question without responding.
struct QuestionCardView: View {
    let request: QuestionRequest
    @ObservedObject var engine: EngineClient

    @State private var responseText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: worker name
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 14))

                Text(workerName)
                    .font(.system(size: 12, weight: .semibold))

                Spacer()

                Text(relativeTimestamp)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Question text
            Text(request.question)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .lineLimit(4)

            // Context (if available)
            if let context = request.context, !context.isEmpty {
                Text(context)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            // Response text field
            TextField("Type your response...", text: $responseText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .lineLimit(1...4)

            // Actions
            HStack {
                Spacer()

                Button("Dismiss") {
                    engine.clearQuestion(workerId: request.workerId)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

                Button(action: dispatchResponse) {
                    HStack(spacing: 3) {
                        Text("Dispatch")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9))
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.accentColor)
                .disabled(responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        )
        .cornerRadius(6)
    }

    // MARK: - Actions

    private func dispatchResponse() {
        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let success = engine.dispatchResponse(workerId: request.workerId, response: trimmed)
        if success {
            engine.clearQuestion(workerId: request.workerId)
        }
    }

    // MARK: - Helpers

    private var workerName: String {
        if let worker = engine.roster.first(where: { $0.id == request.workerId }) {
            return worker.name
        }
        return "Worker #\(request.workerId)"
    }

    private var relativeTimestamp: String {
        let interval = Date().timeIntervalSince(request.timestamp)
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
