import SwiftUI

enum FeedMode: String, Sendable {
    case perPullRequest
    case weekly
}

// The PRs / Weekly tabs at the top of the feed, plain text like Reels' own; while a week's pull requests are open they become the way back to the weeks
// (AGENTS.md, "Weekly Mode").
struct FeedModeSwitch: View {
    @Binding var feedMode: FeedMode
    let openWeekDatesText: String?
    let onCloseWeek: () -> Void
    @Environment(\.shipTokAnalytics) private var analytics

    private static let tabSpacing: CGFloat = 18
    private static let unselectedTabOpacity = 0.6

    var body: some View {
        Group {
            if let openWeekDatesText {
                Button(action: onCloseWeek) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.title3.weight(.semibold))
                        Text("Week of \(openWeekDatesText)")
                            .font(.headline)
                    }
                    .foregroundStyle(.white)
                    .expandingTapTargetVertically()
                }
                .buttonStyle(.swipeYielding)
                .accessibilityHint("Goes back to the weekly videos")
            } else {
                HStack(spacing: Self.tabSpacing) {
                    tab("PRs", mode: .perPullRequest)
                    tab("Weekly", mode: .weekly)
                }
            }
        }
        .fixedSize()
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
                .foregroundStyle(Color.white.opacity(isSelected ? 1 : Self.unselectedTabOpacity))
                .expandingTapTargetVertically()
        }
        .buttonStyle(.swipeYielding)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
