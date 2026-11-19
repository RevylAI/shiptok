import SwiftUI

enum FeedMode: String, Sendable {
    case open
    case merged
    case weekly
    case features

    init(_ feed: PullRequestFeed) {
        switch feed {
        case .open: self = .open
        case .merged: self = .merged
        }
    }
}

// The Open / Merged / Weekly / Features switch over the feed's top left; while a week's or a feature's pull requests are open it becomes the way back to
// the weeks or features (AGENTS.md, "Weekly Mode" and "Features Mode").
struct FeedModeSwitch: View {
    @Binding var feedMode: FeedMode
    let shownDeckSource: PullRequestDeckSource?
    let onCloseDeck: () -> Void
    @Environment(\.shipTokAnalytics) private var analytics
    @Namespace private var selectedSegmentHighlightNamespace

    var body: some View {
        Group {
            if let shownDeckSource {
                Button(action: onCloseDeck) {
                    Label(backButtonTitle(closing: shownDeckSource), systemImage: "chevron.left")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(.black.opacity(0.5)))
                        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
                        .expandingTapTargetVertically()
                }
                .buttonStyle(.swipeYielding)
                .accessibilityHint(shownDeckSource.feedMode == .weekly ? "Goes back to the weekly videos" : "Goes back to the feature videos")
            } else {
                HStack(spacing: 2) {
                    segment("Open", mode: .open)
                    segment("Merged", mode: .merged)
                    segment("Weekly", mode: .weekly)
                    segment("Features", mode: .features)
                }
                .padding(3)
                .background(Capsule().fill(.black.opacity(0.5)))
                .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
            }
        }
        .fixedSize()
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
    }

    // A week's dates are short enough to name it; a feature's title can run to 70 characters, so its chip names where it goes back to.
    private func backButtonTitle(closing deckSource: PullRequestDeckSource) -> String {
        switch deckSource {
        case .weeklyEdition(let weeklyEdition): "Week of \(weeklyEdition.weekDatesText)"
        case .feature: "Features"
        }
    }

    private func segment(_ title: String, mode: FeedMode) -> some View {
        let isSelected = feedMode == mode
        return Button {
            let previousMode = feedMode
            withAnimation(.snappy) { feedMode = mode }
            if previousMode != mode {
                analytics?.capture(.feedModeChanged(previousMode: previousMode, mode: mode))
            }
        } label: {
            Text(verbatim: title)
                .font(.caption.weight(.bold))
                .foregroundStyle(isSelected ? Color.black : Color.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.white)
                            .matchedGeometryEffect(id: "selectedSegmentHighlight", in: selectedSegmentHighlightNamespace)
                    }
                }
                .expandingTapTargetVertically()
        }
        .buttonStyle(.swipeYielding)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
