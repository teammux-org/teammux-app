import SwiftUI

// MARK: - TeamLeadRow

/// Pinned row at the top of the roster representing the Team Lead.
/// Always shows a green status dot with "TEAM LEAD" label and "Claude Code" name.
/// When active, displays an accent-color left border and background highlight.
struct TeamLeadRow: View {
    let isActive: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Accent left border when active
            RoundedRectangle(cornerRadius: 1)
                .fill(isActive ? Color.accentColor : Color.clear)
                .frame(width: 2)

            // Status dot — always green for Team Lead
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text("TEAM LEAD")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(0.5)

                Text("Claude Code")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 8)
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
