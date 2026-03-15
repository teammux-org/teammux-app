import SwiftUI

// MARK: - WorkerRow

/// A single row in the roster representing a worker agent.
/// Shows status dot (color from WorkerStatus), worker name,
/// truncated task description, and a dismiss button on hover.
/// Active state shows accent-color left border and background highlight.
struct WorkerRow: View {
    let worker: WorkerInfo
    let isActive: Bool
    let onTap: () -> Void
    let onDismiss: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Accent left border when active
            RoundedRectangle(cornerRadius: 1)
                .fill(isActive ? Color.accentColor : Color.clear)
                .frame(width: 2)

            // Status dot using worker.status.color
            Circle()
                .fill(worker.status.color)
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

            // Dismiss button — visible on hover
            if isHovering {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss worker")
            }
        }
        .padding(.vertical, 6)
        .padding(.trailing, 8)
        .background(
            isActive
                ? Color.accentColor.opacity(0.12)
                : (isHovering ? Color.secondary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            onTap()
        }
    }
}
