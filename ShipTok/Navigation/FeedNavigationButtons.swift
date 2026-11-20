import SwiftUI

// Inbox and settings where no tab bar shows: glyphs drawn and spaced like the rail's at the top of the Duo's status strip, or plain glyphs in the top
// row's corner. The feed itself is home, so it needs no button (AGENTS.md, "Card Layout").
struct FeedNavigationButtons: View {
    enum Style {
        case statusStripGlyphs
        case topCornerGlyphs
    }

    let style: Style
    let unseenInboxItemCount: Int
    let onSelectTab: (AppTab) -> Void

    private static let topCornerGlyphFont = Font.system(size: 24, weight: .semibold)

    var body: some View {
        switch style {
        case .statusStripGlyphs:
            VStack(spacing: FeedPageLayout.railGlyphSpacing) { buttons }
        case .topCornerGlyphs:
            HStack(spacing: FeedPageLayout.topCornerButtonSpacing) { buttons }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        button(for: .inbox, systemImageName: "tray.full")
            .accessibilityLabel(unseenInboxItemCount > 0 ? "Inbox, \(unseenInboxItemCount) new" : "Inbox")
            .animation(.snappy, value: unseenInboxItemCount)
        button(for: .settings, systemImageName: "gearshape")
            .accessibilityLabel("Settings")
    }

    private func button(for tab: AppTab, systemImageName: String) -> some View {
        Button { onSelectTab(tab) } label: {
            switch style {
            case .statusStripGlyphs:
                glyph(for: tab, systemImageName: systemImageName, font: .actionRailGlyph)
                    .actionRailGlyphStyle()
                    .frame(width: FeedPageLayout.railGlyphSize.width, height: FeedPageLayout.railGlyphSize.height)
                    .contentShape(Rectangle())
            case .topCornerGlyphs:
                glyph(for: tab, systemImageName: systemImageName, font: Self.topCornerGlyphFont)
                    .actionRailGlyphStyle()
                    .frame(width: FeedPageLayout.topCornerButtonTapTargetSize, height: FeedPageLayout.topCornerButtonTapTargetSize)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.swipeYielding)
    }

    private func glyph(for tab: AppTab, systemImageName: String, font: Font) -> some View {
        Image(systemName: systemImageName)
            .font(font)
            .foregroundStyle(RevylBrandColor.textPrimary)
            .overlay(alignment: .topTrailing) {
                if tab == .inbox {
                    UnseenInboxCountBadge(unseenItemCount: unseenInboxItemCount)
                }
            }
    }
}

extension View {
    // With no tab bar, nothing else leads from the inbox or settings back to the feed (AGENTS.md, "Card Layout").
    func backToFeedToolbarItem(_ onShowFeed: (() -> Void)?) -> some View {
        toolbar {
            if let onShowFeed {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onShowFeed) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .fontWeight(.semibold)
                            Text("Feed")
                        }
                    }
                    .accessibilityLabel("Back to feed")
                }
            }
        }
    }
}
