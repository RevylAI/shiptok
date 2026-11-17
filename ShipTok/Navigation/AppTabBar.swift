import SwiftUI

enum AppTab: CaseIterable {
    case feed
    case inbox
    case settings
}

// A floating pill like Instagram's tab bar; the inbox and settings tabs replace the feed while it pauses (AGENTS.md, "Card Layout").
struct AppTabBar: View {
    static let height: CGFloat = 60

    @Binding var selectedTab: AppTab
    let unseenInboxItemCount: Int
    let viewerAvatarURL: URL?

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
                                Capsule().fill(Self.selectedItemFill)
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
        .animation(.spring(duration: 0.25), value: selectedTab)
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
                    if unseenInboxItemCount > 0 {
                        Text(unseenInboxItemCount > 99 ? "99+" : "\(unseenInboxItemCount)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(RevylBrandColor.danger))
                            .offset(x: 10, y: -8)
                    }
                }
        case .settings:
            if let viewerAvatarURL {
                GitHubAvatarView(avatarURL: viewerAvatarURL, diameter: 28)
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
