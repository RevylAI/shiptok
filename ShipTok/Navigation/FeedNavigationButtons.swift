import SwiftUI

// Inbox and settings where no tab bar shows: round buttons at the top of the Duo's status strip, or plain glyphs in the top row's corner. The feed
// itself is home, so it needs no button (AGENTS.md, "Card Layout").
struct FeedNavigationButtons: View {
    enum Style {
        case statusStripCircles
        case topCornerGlyphs
    }

    let style: Style
    let unseenInboxItemCount: Int
    let onSelectTab: (AppTab) -> Void

    private static let circleFill = Color(rgbHex: 0x3A3C41)
    private static let circleGlyphSize: CGFloat = 20
    private static let topCornerGlyphSize: CGFloat = 24
    private static let topCornerGlyphSpacing: CGFloat = 8
    private static let topCornerGlyphTapTargetSize: CGFloat = 44

    var body: some View {
        switch style {
        case .statusStripCircles:
            VStack(spacing: FeedPageLayout.statusStripButtonSpacing) { buttons }
        case .topCornerGlyphs:
            HStack(spacing: Self.topCornerGlyphSpacing) { buttons }
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
            case .statusStripCircles:
                glyph(for: tab, systemImageName: systemImageName, size: Self.circleGlyphSize)
                    .frame(width: FeedPageLayout.statusStripButtonDiameter, height: FeedPageLayout.statusStripButtonDiameter)
                    .background(Circle().fill(Self.circleFill))
                    .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                    .contentShape(Circle())
            case .topCornerGlyphs:
                glyph(for: tab, systemImageName: systemImageName, size: Self.topCornerGlyphSize)
                    .actionRailGlyphStyle()
                    .frame(width: Self.topCornerGlyphTapTargetSize, height: Self.topCornerGlyphTapTargetSize)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.swipeYielding)
    }

    private func glyph(for tab: AppTab, systemImageName: String, size: CGFloat) -> some View {
        Image(systemName: systemImageName)
            .font(.system(size: size, weight: .semibold))
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
