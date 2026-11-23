import SwiftUI

enum FeedMode: String, CaseIterable, Sendable, Codable {
    case open
    case merged
    case weekly
    case features

    var tabTitle: String {
        switch self {
        case .open: "Open"
        case .merged: "Merged"
        case .weekly: "Weekly"
        case .features: "Features"
        }
    }
}

// The tabs at the top of the feed for the modes the person keeps on, in Open / Merged / Weekly / Features order, plain text like Reels' own; while a week's or a
// feature's pull requests are open they become the way back to the weeks or features (AGENTS.md, "Card Layout" and "Feed Modes").
struct FeedModeSwitch: View {
    @Binding var feedMode: FeedMode
    let feedModesWithShownTabs: [FeedMode]
    let shownDeckSource: PostDeckSource?
    let onCloseDeck: () -> Void
    // Where the card's middle falls in the switch's own frame, which the tabs center on whenever they fit there.
    let preferredTabsCenterX: CGFloat
    @Environment(\.shipTokAnalytics) private var analytics

    private static let tabSpacing: CGFloat = 18
    private static let unselectedTabOpacity = 0.6
    private static let tabMinimumScaleFactor: CGFloat = 0.5

    var body: some View {
        Group {
            if let shownDeckSource {
                Button(action: onCloseDeck) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.title3.weight(.semibold))
                        Text(backButtonTitle(closing: shownDeckSource))
                            .font(.headline)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .expandingTapTargetVertically()
                }
                .buttonStyle(.swipeYielding)
                .accessibilityHint(backButtonHint(closing: shownDeckSource))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                FeedModeTabsLayout(spacing: Self.tabSpacing, preferredCenterX: preferredTabsCenterX) {
                    ForEach(feedModesWithShownTabs, id: \.self) { mode in
                        tab(for: mode)
                    }
                }
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
    }

    // A week's dates are short enough to name it; a feature's title can run to 70 characters, so its back button names where it goes back to.
    private func backButtonTitle(closing deckSource: PostDeckSource) -> String {
        switch deckSource {
        case .pullRequestsOf(let deckPost) where deckPost.kind == .weeklyEdition: deckPost.weekDatesText.map { "Week of \($0)" } ?? "Weekly"
        case .pullRequestsOf: "Features"
        case .post: "Back"
        }
    }

    private func backButtonHint(closing deckSource: PostDeckSource) -> String {
        switch deckSource.feedMode {
        case .weekly: "Goes back to the weekly videos"
        case .features: "Goes back to the feature videos"
        case .open, .merged, nil: "Goes back to the feed"
        }
    }

    private func tab(for mode: FeedMode) -> some View {
        let isSelected = feedMode == mode
        return Button {
            let previousMode = feedMode
            withAnimation(.snappy) { feedMode = mode }
            if previousMode != mode {
                analytics?.capture(.feedModeChanged(previousMode: previousMode, mode: mode))
            }
        } label: {
            Text(verbatim: mode.tabTitle)
                .font(.title2.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(Self.tabMinimumScaleFactor)
                .foregroundStyle(Color.white.opacity(isSelected ? 1 : Self.unselectedTabOpacity))
                .expandingTapTargetVertically()
        }
        .buttonStyle(.swipeYielding)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// One rule on every window (AGENTS.md, "Card Layout"): the tabs keep their size and center on the card; where that would leave the space they're given, they
// move only as far as it takes to stay inside it, and where they're wider than that space, they shrink evenly to its width.
private struct FeedModeTabsLayout: Layout {
    let spacing: CGFloat
    let preferredCenterX: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let naturalSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let naturalSize = CGSize(width: Self.rowWidth(of: naturalSizes, spacing: spacing), height: naturalSizes.map(\.height).max() ?? 0)
        return proposal.replacingUnspecifiedDimensions(by: naturalSize)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let naturalSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let naturalRowWidth = Self.rowWidth(of: naturalSizes, spacing: spacing)
        let scale = naturalRowWidth > bounds.width ? bounds.width / naturalRowWidth : 1
        let rowWidth = naturalRowWidth * scale
        var subviewLeading = min(max(bounds.minX + preferredCenterX - rowWidth / 2, bounds.minX), bounds.maxX - rowWidth)
        for (subview, naturalSize) in zip(subviews, naturalSizes) {
            let subviewWidth = naturalSize.width * scale
            subview.place(
                at: CGPoint(x: subviewLeading, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: subviewWidth, height: naturalSize.height)
            )
            subviewLeading += subviewWidth + spacing * scale
        }
    }

    private static func rowWidth(of subviewSizes: [CGSize], spacing: CGFloat) -> CGFloat {
        subviewSizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(subviewSizes.count - 1, 0))
    }
}
