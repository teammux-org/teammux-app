import SwiftUI

// MARK: - ProjectTabBar

/// Horizontal tab bar showing all open projects.
/// Each tab displays an activity dot, the project name, and a close button.
/// A trailing [+] button opens a new project via the ProjectManager.
struct ProjectTabBar: View {
    @EnvironmentObject var projectManager: ProjectManager

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(projectManager.projects) { project in
                        ProjectTab(
                            project: project,
                            isActive: project.id == projectManager.activeProjectId,
                            onSelect: {
                                projectManager.activate(project.id)
                            },
                            onClose: {
                                projectManager.closeProject(project.id)
                            }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }

            Spacer()

            Button(action: {
                projectManager.openNewProject()
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .help("Open new project")
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            Divider(),
            alignment: .bottom
        )
    }
}

// MARK: - ProjectTab

/// A single tab representing an open project.
struct ProjectTab: View {
    let project: Project
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            // Activity dot
            if project.hasUnseenActivity {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
            }

            Text(project.name)
                .font(.system(size: 12))
                .lineLimit(1)

            // Close button (visible on hover or when active)
            if isHovering || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isActive
                ? Color.accentColor.opacity(0.15)
                : (isHovering ? Color.secondary.opacity(0.08) : Color.clear)
        )
        .cornerRadius(4)
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            onSelect()
        }
    }
}
