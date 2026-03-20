import SwiftUI

// MARK: - PaneIconRail

/// Vertical scrollable icon rail for right pane navigation.
///
/// Sits on the far right edge of the right pane. Each icon is an
/// SF Symbol with a 44pt tap target, tooltip on hover, and
/// active/inactive visual states.
struct PaneIconRail: View {
    @Binding var activeTab: RightTab

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 4) {
                ForEach(RightTab.allCases) { tab in
                    iconButton(for: tab)
                }
            }
            .padding(.vertical, 8)
        }
        .frame(width: 44)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Icon button

    private func iconButton(for tab: RightTab) -> some View {
        Button(action: {
            activeTab = tab
        }) {
            Image(systemName: tab.iconName)
                .font(.system(size: 16))
                .foregroundColor(activeTab == tab ? .accentColor : .secondary)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(activeTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(tab.rawValue)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
}
