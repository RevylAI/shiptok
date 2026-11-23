import SwiftUI

enum AppTab: CaseIterable {
    case feed
    case inbox
    case settings
}

// A floating pill like Instagram's tab bar, shown where the card leaves room for it; the inbox and settings tabs replace the feed while it pauses (AGENTS.md, "Card Layout").
struct AppTabBar: View {
    static let height: CGFloat = 60

    @Binding var selectedTab: AppTab
    let unseenInboxItemCount: Int
    let viewerAvatarURL: URL?
    @Namespace private var selectedTabHighlightNamespace

    private static let itemWidth: CGFloat = 92
    private static let edgePadding: CGFloat = 5
    private static let pillFill = Color(rgbHex: 0x2E3035)
    private static let selectedItemFill = Color(rgbHex: 0x18181B)

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button { selectedTab = tab } label: {
                    tabIcon(tab)
                        .frame(width: Self.itemWidth, height: Self.height - Self.edgePadding * 2)
                        .background {
                            if selectedTab == tab {
                                Capsule()
                                    .fill(Self.selectedItemFill)
                                    .matchedGeometryEffect(id: "selectedTabHighlight", in: selectedTabHighlightNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(for: tab))
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
        }
        .padding(Self.edgePadding)
        .frame(height: Self.height)
        .background(Capsule().fill(Self.pillFill))
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .animation(.snappy, value: selectedTab)
        .animation(.snappy, value: unseenInboxItemCount)
    }

    @ViewBuilder
    private func tabIcon(_ tab: AppTab) -> some View {
        let isSelected = selectedTab == tab
        switch tab {
        case .feed:
            Image(systemName: isSelected ? "house.fill" : "house")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(RevylBrandColor.textPrimary)
        case .inbox:
            Image(systemName: isSelected ? "tray.full.fill" : "tray.full")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(RevylBrandColor.textPrimary)
                .overlay(alignment: .topTrailing) {
                    UnseenInboxCountBadge(unseenItemCount: unseenInboxItemCount)
                }
        case .settings:
            if let viewerAvatarURL {
                AvatarView(avatarURL: viewerAvatarURL, diameter: 28)
                    .overlay(Circle().stroke(isSelected ? RevylBrandColor.textPrimary : .clear, lineWidth: 2))
            } else {
                Image(systemName: isSelected ? "person.crop.circle.fill" : "person.crop.circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(RevylBrandColor.textPrimary)
            }
        }
    }

    private func accessibilityLabel(for tab: AppTab) -> String {
        switch tab {
        case .feed: "Feed"
        case .inbox: unseenInboxItemCount > 0 ? "Inbox, \(unseenInboxItemCount) new" : "Inbox"
        case .settings: "Settings"
        }
    }
}
