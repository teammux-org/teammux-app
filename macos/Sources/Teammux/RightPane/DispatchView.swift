import SwiftUI
import os

// MARK: - DispatchView

/// Right-pane tab for dispatching task instructions to active workers.
///
/// Top section shows a row per active worker with a text field and send button.
/// Bottom section shows the dispatch history as an audit trail.
///
/// Three visual states (the latter two share the worker section):
/// - No workers: empty state prompt
/// - Workers, no history: worker rows with "No dispatches yet"
/// - Workers + history: full view
struct DispatchView: View {
    @ObservedObject var engine: EngineClient

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if engine.roster.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    workerSection

                    Divider()
                        .padding(.vertical, 4)

                    historySection
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("Dispatch Tasks", systemImage: "paperplane.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "paperplane")
                .font(.system(size: 32))
                .foregroundColor(.secondary)

            Text("No active workers")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Spawn workers to dispatch tasks.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Worker section

    private var workerSection: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(engine.roster) { worker in
                    DispatchWorkerRow(worker: worker, engine: engine)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 200)
    }

    // MARK: - History section

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            if engine.dispatchHistory.isEmpty {
                Text("No dispatches yet")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                List {
                    ForEach(engine.dispatchHistory.reversed()) { event in
                        DispatchHistoryRow(event: event, engine: engine)
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - DispatchWorkerRow

/// A single worker row with a text field for the instruction and a send button.
/// Shows dispatch errors inline below the row, scoped per-worker.
struct DispatchWorkerRow: View {
    let worker: WorkerInfo
    @ObservedObject var engine: EngineClient

    private static let logger = Logger(subsystem: "com.teammux.app", category: "DispatchWorkerRow")

    @State private var instruction: String = ""
    @State private var dispatchError: String?
    @State private var isDispatching: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // Status dot
                Circle()
                    .fill(worker.status.color)
                    .frame(width: 8, height: 8)

                Text(worker.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .frame(minWidth: 60, alignment: .leading)

                // Instruction field
                TextField("Instruction...", text: $instruction)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { dispatchAction() }
                    .disabled(isDispatching)

                // Send button
                Button(action: dispatchAction) {
                    if isDispatching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 10))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isDispatching)
            }

            if let error = dispatchError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .padding(.leading, 14)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
    }

    // MARK: - Dispatch action

    private func dispatchAction() {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isDispatching = true
        dispatchError = nil

        Task { @MainActor in
            let success = engine.dispatchTask(workerId: worker.id, instruction: trimmed)
            if success {
                instruction = ""
                Self.logger.info("Dispatched task to worker \(worker.id) (\(worker.name))")
            } else {
                let errorMsg = engine.lastError ?? "Failed to dispatch task"
                dispatchError = errorMsg
                Self.logger.error("Dispatch failed for worker \(worker.id) (\(worker.name)): \(errorMsg)")
            }
            isDispatching = false
        }
    }
}

// MARK: - DispatchHistoryRow

/// A single row in the dispatch history showing what was sent, to whom, when,
/// the dispatch direction (task vs response), and delivery status.
struct DispatchHistoryRow: View {
    let event: DispatchEvent
    let engine: EngineClient

    private var workerName: String {
        engine.roster.first(where: { $0.id == event.targetWorkerId })?.name
            ?? "Worker \(event.targetWorkerId)"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: event.kind == .response ? "arrowshape.turn.up.left.fill" : "paperplane.fill")
                .font(.system(size: 9))
                .foregroundColor(.secondary)

            Text(workerName)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            Text("\"\(event.instruction)\"")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Text(event.timestamp, style: .relative)
                .font(.system(size: 9))
                .foregroundColor(.secondary)

            if event.delivered {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.green)
                    .help("Delivered successfully")
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                    .help("Not delivered — worker may be unavailable")
            }
        }
        .padding(.vertical, 2)
    }
}
