import SwiftUI

// MARK: - RightTab

/// The six tabs available in the right pane.
enum RightTab: String, CaseIterable, Identifiable {
    case teamLead = "Team Lead"
    case git = "Git"
    case diff = "Diff"
    case liveFeed = "Live Feed"
    case dispatch = "Dispatch"
    case context = "Context"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .teamLead: return "person.fill"
        case .git:      return "arrow.triangle.branch"
        case .diff:     return "doc.text.magnifyingglass"
        case .liveFeed: return "antenna.radiowaves.left.and.right"
        case .dispatch: return "paperplane.fill"
        case .context:  return "doc.text.fill"
        }
    }
}

// MARK: - RightPaneView

/// Right pane with a custom tab bar (not native segmented control)
/// routing to six content views: Team Lead terminal, Git, Diff, Live Feed, Dispatch, and Context.
///
/// The active tab is indicated by a thin underline in accent color.
struct RightPaneView: View {
    @ObservedObject var engine: EngineClient

    @State private var activeTab: RightTab = .teamLead
    @State private var diffSelectedWorkerId: UInt32? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Custom tab bar
            tabBar

            Divider()

            // Tab content
            tabContent
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(RightTab.allCases) { tab in
                tabButton(for: tab)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private func tabButton(for tab: RightTab) -> some View {
        Button(action: {
            activeTab = tab
        }) {
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: tab.iconName)
                        .font(.system(size: 10))
                    Text(tab.rawValue)
                        .font(.system(size: 11, weight: activeTab == tab ? .semibold : .regular))
                }
                .foregroundColor(activeTab == tab ? .primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                // Underline indicator
                Rectangle()
                    .fill(activeTab == tab ? Color.accentColor : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch activeTab {
        case .teamLead:
            TeamLeadTerminalView(engine: engine, activeTab: $activeTab)
        case .git:
            GitView(engine: engine)
        case .diff:
            DiffView(engine: engine, selectedWorkerId: $diffSelectedWorkerId)
        case .liveFeed:
            LiveFeedView(engine: engine, activeTab: $activeTab, diffSelectedWorkerId: $diffSelectedWorkerId)
        case .dispatch:
            DispatchView(engine: engine)
        case .context:
            ContextView(engine: engine)
        }
    }
}
