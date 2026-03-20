import SwiftUI

// MARK: - WorkerRow

/// A single row in the roster representing a worker agent.
/// Shows status dot (color from WorkerStatus), worker name,
/// truncated task description, and a dismiss button on hover.
/// Active state shows accent-color left border and background highlight.
/// When the worker has an assigned role, displays the role emoji before
/// the name and the role name below the task description. A lock icon
/// appears when the role has deny_write patterns.
struct WorkerRow: View {
    let worker: WorkerInfo
    let role: RoleDefinition?
    let branch: String?
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

            // Health indicator dot (only shown when not healthy)
            if worker.healthStatus != .healthy {
                Circle()
                    .fill(worker.healthStatus.color)
                    .frame(width: 6, height: 6)
                    .help("Health: \(worker.healthStatus.label)")
            }

            // Role emoji badge (only when role is assigned with non-empty emoji)
            if let role, !role.emoji.isEmpty {
                Text(role.emoji)
                    .font(.system(size: 14))
                    .accessibilityLabel("\(role.name) role")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(worker.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                Text(worker.taskDescription)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)

                // Role name (only when role is assigned)
                if let role {
                    Text(role.name)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                // Branch badge — tap to copy branch name to clipboard
                if let branch {
                    Text(branch)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        .onTapGesture {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(branch, forType: .string)
                        }
                }
            }

            Spacer()

            // Capability lock icon — shown when role has deny_write patterns
            if let role, !role.denyWritePatterns.isEmpty {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help("Restricted: \(role.denyWritePatterns.joined(separator: ", "))")
            }

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
