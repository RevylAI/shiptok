import SwiftUI

enum FeedMode: String, Sendable {
    case perPullRequest
    case weekly
}

// The PRs / Weekly switch over the feed's top left; while a week's pull requests are open it becomes the way back to the weeks (AGENTS.md, "Weekly Mode").
struct FeedModeSwitch: View {
    @Binding var feedMode: FeedMode
    let openWeekDatesText: String?
    let onCloseWeek: () -> Void
    @Environment(\.shipTokAnalytics) private var analytics
    @Namespace private var selectedSegmentHighlightNamespace

    var body: some View {
        Group {
            if let openWeekDatesText {
                Button(action: onCloseWeek) {
                    Label("Week of \(openWeekDatesText)", systemImage: "chevron.left")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(.black.opacity(0.5)))
                        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
                        .expandingTapTargetVertically()
                }
                .buttonStyle(.swipeYielding)
                .accessibilityHint("Goes back to the weekly videos")
            } else {
                HStack(spacing: 2) {
                    segment("PRs", mode: .perPullRequest)
                    segment("Weekly", mode: .weekly)
                }
                .padding(3)
                .background(Capsule().fill(.black.opacity(0.5)))
                .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
            }
        }
        .fixedSize()
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
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
