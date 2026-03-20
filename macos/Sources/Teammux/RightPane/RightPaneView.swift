import SwiftUI

// MARK: - RightTab

/// The tabs available in the right pane.
enum RightTab: String, CaseIterable, Identifiable {
    case teamLead = "Team Lead"
    case git = "Git"
    case diff = "Diff"
    case liveFeed = "Live Feed"
    case dispatch = "Dispatch"
    case context = "Context"
    case you = "You"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .teamLead: return "terminal"
        case .git:      return "arrow.triangle.branch"
        case .diff:     return "doc.text.magnifyingglass"
        case .liveFeed: return "bubble.left.and.bubble.right"
        case .dispatch: return "paperplane"
        case .context:  return "doc.text"
        case .you:      return "person.fill"
        }
    }

    /// Keyboard shortcut number (1-based) for Cmd+N switching.
    var shortcutIndex: Int {
        switch self {
        case .teamLead: return 1
        case .git:      return 2
        case .diff:     return 3
        case .liveFeed: return 4
        case .dispatch: return 5
        case .context:  return 6
        case .you:      return 7
        }
    }

    /// Returns the RightTab for a given shortcut number, or nil.
    static func fromShortcut(_ number: Int) -> RightTab? {
        allCases.first { $0.shortcutIndex == number }
    }
}

// MARK: - RightPaneView

/// Right pane with a vertical icon rail on the far right edge
/// routing to a content view for each pane.
struct RightPaneView: View {
    @ObservedObject var engine: EngineClient

    @State private var activeTab: RightTab = .teamLead
    @State private var diffSelectedWorkerId: UInt32? = nil
    @State private var contextSelectedWorkerId: UInt32? = nil
    @State private var keyMonitor: Any?

    var body: some View {
        HStack(spacing: 0) {
            // Pane content
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.15), value: activeTab)

            Divider()

            // Vertical icon rail on far right edge
            PaneIconRail(activeTab: $activeTab)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    // MARK: - Keyboard shortcuts (Cmd+1..7)

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  let chars = event.charactersIgnoringModifiers,
                  let number = Int(chars),
                  let tab = RightTab.fromShortcut(number) else {
                return event
            }
            activeTab = tab
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
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
            ContextView(engine: engine, selectedWorkerId: $contextSelectedWorkerId)
        case .you:
            youPlaceholder
        }
    }

    // MARK: - You placeholder (S12 will replace with UserTerminalView)

    private var youPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.fill")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("Your Terminal")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Your Claude Code session will appear here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
