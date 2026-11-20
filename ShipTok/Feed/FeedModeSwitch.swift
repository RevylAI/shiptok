import SwiftUI

enum FeedMode: String, Sendable {
    case open
    case merged
    case weekly

    init(_ feed: PullRequestFeed) {
        switch feed {
        case .open: self = .open
        case .merged: self = .merged
        }
    }
}

// The Open / Merged / Weekly tabs at the top of the feed, plain text like Reels' own; while a week's pull requests are open they become the way back to the
// weeks (AGENTS.md, "Card Layout" and "Weekly Mode").
struct FeedModeSwitch: View {
    @Binding var feedMode: FeedMode
    let openWeekDatesText: String?
    let onCloseWeek: () -> Void
    // Where the card's middle falls in the switch's own frame, which the tabs center on whenever they fit there.
    let preferredTabsCenterX: CGFloat
    @Environment(\.shipTokAnalytics) private var analytics

    private static let tabSpacing: CGFloat = 18
    private static let unselectedTabOpacity = 0.6
    private static let tabMinimumScaleFactor: CGFloat = 0.5

    var body: some View {
        Group {
            if let openWeekDatesText {
                Button(action: onCloseWeek) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.title3.weight(.semibold))
                        Text("Week of \(openWeekDatesText)")
                            .font(.headline)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .expandingTapTargetVertically()
                }
                .buttonStyle(.swipeYielding)
                .accessibilityHint("Goes back to the weekly videos")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                FeedModeTabsLayout(spacing: Self.tabSpacing, preferredCenterX: preferredTabsCenterX) {
                    tab("Open", mode: .open)
                    tab("Merged", mode: .merged)
                    tab("Weekly", mode: .weekly)
                }
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
    }

    private func tab(_ title: String, mode: FeedMode) -> some View {
        let isSelected = feedMode == mode
        return Button {
            let previousMode = feedMode
            withAnimation(.snappy) { feedMode = mode }
            if previousMode != mode {
                analytics?.capture(.feedModeChanged(previousMode: previousMode, mode: mode))
            }
        } label: {
            Text(verbatim: title)
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
