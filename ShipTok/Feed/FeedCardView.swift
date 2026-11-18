import SwiftUI

enum FeedCardPost {
    case pullRequest(MergedPullRequest)
    case weeklyEdition(WeeklyEdition)

    var thread: any GitHubCommentThread {
        switch self {
        case .pullRequest(let pullRequest): pullRequest
        case .weeklyEdition(let weeklyEdition): weeklyEdition
        }
    }

    var vibeTarget: VibeTarget {
        switch self {
        case .pullRequest(let pullRequest): VibeTarget(pullRequest: pullRequest)
        case .weeklyEdition(let weeklyEdition): VibeTarget(weeklyEdition: weeklyEdition)
        }
    }

    var reactions: GitHubReactionSummary { thread.reactions }

    var discussionCommentCount: Int { thread.discussionComments.count }

    var mediaItems: [PullRequestMediaItem] { thread.mediaItems }
}

struct FeedCardVibes {
    let tally: PullRequestVibeTally
    let onCast: (PullRequestVibe) -> Void
    let onRemoveViewerVibe: () -> Void
}

// One feed page laid out like Instagram Reels: a pull request, or a week's video in weekly mode. Its layout follows AGENTS.md, "Card Layout".
struct FeedCardView: View {
    private struct CardFrames: Equatable {
        let card: CGRect
        let rail: CGRect
        let caption: CGRect
    }

    let post: FeedCardPost
    let heroMediaItem: PullRequestMediaItem?
    let isHeroMediaUnloadable: Bool
    let analyticsSubject: ShipTokAnalyticsSubject
    let pageChromeInsets: EdgeInsets
    let systemOcclusionFrames: [CGRect]
    let videoScrubFraction: CGFloat?
    let vibeFeedbackComposerHeight: CGFloat
    let isBehindVibeFeedbackComposer: Bool
    let isKeyboardShown: Bool
    let vibes: FeedCardVibes
    let moderation: GitHubPostedContentModeration
    let isPlaybackActive: Bool
    let isOccludedForAnalytics: Bool
    let horizontalDragProgress: CGFloat
    let likeBurstTrigger: Int
    let onDoubleTap: () -> Void
    let onToggleLike: () -> Void
    let onToggleReaction: (GitHubReaction) -> Void
    let onOpenComments: () -> Void
    let onOpenDeck: () -> Void
    let onTapCaption: () -> Void
    let onHeroMediaLoadFailure: (PullRequestMediaItem) -> Void
    let onTapWhileBehindVibeFeedbackComposer: () -> Void
    @State private var isReactionPickerPresented = false
    @State private var isViewerVibeRemovalConfirmationPresented = false
    @State private var reactButtonFrameInCard: CGRect = .zero
    @State private var captionHeight: CGFloat = 0
    @State private var heroPauseToggleTrigger = 0
    @State private var isHeroFastPlaybackHeld = false
    @Environment(\.shipTokAnalytics) private var analytics
    @Environment(VideoPlaybackRateChoice.self) private var playbackRateChoice

    private static let cardCornerRadius: CGFloat = 6
    private static let cardMargin: CGFloat = 8
    private static let cardMaximumTopInset: CGFloat = 30
    private static let cardToTabBarSpacing: CGFloat = 30
    private static let railColumnWidth: CGFloat = 84
    private static let minimumSystemRailStripWidth: CGFloat = 56
    private static let reelsVideoWidthToHeightRatio: CGFloat = 9.0 / 16.0
    private static let overlayInset: CGFloat = 16
    private static let captionBottomInset: CGFloat = 32
    private static let captionToComposerSpacing: CGFloat = 12
    private static let captionToRailSpacing: CGFloat = 8
    private static let railBottomInsetInColumn: CGFloat = 8
    private static let railBottomInsetOverCard: CGFloat = 28
    private static let videoScrubZoneDepthBelowCard: CGFloat = 12
    private static let railTrailingInsetOverCard: CGFloat = 4
    private static let captionBackdropFadeHeight: CGFloat = 80
    private static let captionBackdropTintOpacity = 0.65
    private static let captionBackdropBlurClearanceAboveProgressLine: CGFloat = 6
    private static let railWidth: CGFloat = 54
    private static let railGlyphSize = CGSize(width: 44, height: 40)
    private static let reactionPickerSpacing: CGFloat = 8
    private nonisolated static let cardCoordinateSpaceName = "mergedPullRequestCard"

    // The box rides the keyboard over the card, so the caption would show half-covered around it; only the dimmed hero stays.
    private var showsOnlyHeroBehindVibeFeedbackComposer: Bool {
        isBehindVibeFeedbackComposer && isKeyboardShown
    }

    private var isHeroLoadableVideo: Bool {
        heroMediaItem?.kind == .video && !isHeroMediaUnloadable
    }

    // The 2x hint and the scrub readout sit where the caption's last lines do.
    private var isHeroPlaybackGestureActive: Bool {
        isHeroFastPlaybackHeld || videoScrubFraction != nil
    }

    var body: some View {
        GeometryReader { geometry in
            let arrangedFrames = cardFrames(in: geometry.size)
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .bottom) {
                    heroMedia
                    captionBackdrop(frames: arrangedFrames)
                }
                .frame(width: arrangedFrames.card.width, height: arrangedFrames.card.height)
                .clipShape(RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
                .overlay {
                    if isHeroLoadableVideo {
                        heroFastPlaybackHoldArea
                    }
                }
                .offset(x: arrangedFrames.card.minX, y: arrangedFrames.card.minY)
                caption
                    .frame(width: arrangedFrames.caption.width, height: arrangedFrames.caption.height, alignment: .bottomLeading)
                    .opacity(isReactionPickerPresented || showsOnlyHeroBehindVibeFeedbackComposer || isHeroPlaybackGestureActive ? 0 : 1)
                    .offset(x: arrangedFrames.caption.minX, y: arrangedFrames.caption.minY)
                if !isBehindVibeFeedbackComposer {
                    actionRail
                        .frame(width: arrangedFrames.rail.width, height: arrangedFrames.rail.height, alignment: .bottom)
                        .offset(x: arrangedFrames.rail.minX, y: arrangedFrames.rail.minY)
                }
                if isReactionPickerPresented {
                    reactionPicker
                        .offset(reactionPickerOffset(cardFrame: arrangedFrames.card))
                        .transition(.scale(scale: 0.6, anchor: .trailing).combined(with: .opacity))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .coordinateSpace(.named(Self.cardCoordinateSpaceName))
            .background(RevylBrandColor.canvas)
            .overlay {
                if isBehindVibeFeedbackComposer {
                    Color.black.opacity(0.5)
                }
            }
            .overlay { VibeStampView(horizontalDragProgress: horizontalDragProgress) }
            .overlay { HeartBurstView(trigger: likeBurstTrigger) }
            .animation(.snappy, value: isReactionPickerPresented)
            .animation(.easeOut(duration: 0.15), value: isHeroPlaybackGestureActive)
            .animation(.spring(duration: 0.35), value: arrangedFrames)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onDoubleTap)
            .onTapGesture {
                if isReactionPickerPresented {
                    isReactionPickerPresented = false
                } else {
                    heroPauseToggleTrigger += 1
                }
            }
            .overlay {
                if isBehindVibeFeedbackComposer {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onTapWhileBehindVibeFeedbackComposer)
                }
            }
            .animation(.spring(duration: 0.3), value: isBehindVibeFeedbackComposer)
            .animation(.easeOut(duration: 0.2), value: showsOnlyHeroBehindVibeFeedbackComposer)
            .onChange(of: isPlaybackActive) { _, isActive in
                if !isActive { isReactionPickerPresented = false }
            }
        }
    }

    // Placement reads only the window's size and safe area, never the device or its orientation, and the hero keeps one place in the view tree, so a playing video never restarts when the window changes shape.
    static func cardFrame(in pageSize: CGSize, pageChromeInsets insets: EdgeInsets) -> (card: CGRect, railColumnLeading: CGFloat?) {
        let cardTop = max(cardMargin, min(insets.top, cardMaximumTopInset))
        let cardHeight = max(pageSize.height - insets.bottom - cardToTabBarSpacing - cardTop, 0)
        let railColumnWidth = max(insets.trailing, Self.railColumnWidth)
        let centeredCardLeading = max(insets.leading, railColumnWidth)
        let centeredCardWidth = pageSize.width - centeredCardLeading - railColumnWidth
        if centeredCardWidth >= cardHeight * reelsVideoWidthToHeightRatio {
            return (CGRect(x: centeredCardLeading, y: cardTop, width: centeredCardWidth, height: cardHeight), pageSize.width - railColumnWidth)
        }
        let cardLeading = max(insets.leading, cardMargin)
        let systemRailStripWidth = insets.trailing >= minimumSystemRailStripWidth ? insets.trailing : nil
        let cardTrailingInset = systemRailStripWidth ?? max(insets.trailing, cardMargin)
        let card = CGRect(x: cardLeading, y: cardTop, width: max(pageSize.width - cardLeading - cardTrailingInset, 0), height: cardHeight)
        return (card, systemRailStripWidth.map { pageSize.width - $0 })
    }

    // The strip under the caption around the video's progress line, where a sideways drag scrubs the hero video instead of casting a vibe; it stops well above the tab bar (AGENTS.md, "Swipe Gestures").
    static func videoScrubZone(cardFrame: CGRect) -> CGRect {
        CGRect(
            x: cardFrame.minX,
            y: cardFrame.maxY - captionBottomInset,
            width: cardFrame.width,
            height: captionBottomInset + videoScrubZoneDepthBelowCard
        )
    }

    static func videoScrubFraction(atX fingerX: CGFloat, cardFrame: CGRect) -> CGFloat {
        let progressLineInset = PullRequestMediaItemView.heroProgressLineHorizontalInset
        let progressLineWidth = max(cardFrame.width - 2 * progressLineInset, 1)
        return min(max((fingerX - cardFrame.minX - progressLineInset) / progressLineWidth, 0), 1)
    }

    private func cardFrames(in pageSize: CGSize) -> CardFrames {
        let insets = pageChromeInsets
        let (card, railColumnLeading) = Self.cardFrame(in: pageSize, pageChromeInsets: insets)
        let railX: CGFloat
        let railBottom: CGFloat
        let captionTrailingInset: CGFloat
        if let railColumnLeading {
            railX = railColumnLeading + (pageSize.width - railColumnLeading - Self.railWidth) / 2
            railBottom = card.maxY - Self.railBottomInsetInColumn
            captionTrailingInset = Self.overlayInset
        } else {
            railX = card.maxX - Self.railTrailingInsetOverCard - Self.railWidth
            railBottom = card.maxY - Self.railBottomInsetOverCard
            captionTrailingInset = Self.railTrailingInsetOverCard + Self.railWidth + Self.captionToRailSpacing
        }
        // The Duo's status strip (its clock, battery and an expanded island) lies inside the safe area, so only the regions the system reserves say where the rail can start (AGENTS.md, "Card Layout").
        let unobstructedRailTop = card.minY + Self.overlayInset
        let railTop = systemOcclusionFrames
            .filter { $0.minY <= unobstructedRailTop && $0.minX < railX + Self.railWidth && $0.maxX > railX }
            .reduce(unobstructedRailTop) { max($0, $1.maxY) }
        let rail = CGRect(x: railX, y: railTop, width: Self.railWidth, height: max(railBottom - railTop, 0))
        let composerTop = pageSize.height - insets.bottom - vibeFeedbackComposerHeight
        let captionBottom = vibeFeedbackComposerHeight > 0
            ? min(card.maxY - Self.captionBottomInset, composerTop - Self.captionToComposerSpacing)
            : card.maxY - Self.captionBottomInset
        let captionTop = card.minY + Self.overlayInset
        let caption = CGRect(
            x: card.minX + Self.overlayInset,
            y: captionTop,
            width: max(card.width - Self.overlayInset - captionTrailingInset, 0),
            height: max(captionBottom - captionTop, 0)
        )
        return CardFrames(card: card, rail: rail, caption: caption)
    }

    @ViewBuilder
    private var heroMedia: some View {
        if let heroMediaItem {
            PullRequestHeroMediaView(
                mediaItem: heroMediaItem,
                analyticsSubject: analyticsSubject,
                mediaPosition: post.mediaItems.firstIndex(where: { $0.id == heroMediaItem.id }) ?? 0,
                isPlaybackActive: isPlaybackActive,
                isUnloadable: isHeroMediaUnloadable,
                isOccludedForAnalytics: isOccludedForAnalytics,
                pauseToggleTrigger: heroPauseToggleTrigger,
                isFastPlaybackHeld: isHeroFastPlaybackHeld,
                videoScrubFraction: videoScrubFraction,
                onLoadFailure: { onHeroMediaLoadFailure(heroMediaItem) }
            )
            .id(heroMediaItem.id)
        } else {
            RevylBrandColor.surfaceRaised
        }
    }

    // Everywhere on the hero but the scrub strip, so a finger resting on the progress line before it drags scrubs rather than speeding up.
    private var heroFastPlaybackHoldArea: some View {
        Color.clear
            .contentShape(Rectangle())
            .padding(.bottom, Self.captionBottomInset)
            .fastPlaybackHold(isHeld: $isHeroFastPlaybackHeld)
    }

    // The tint, not the blur, keeps the caption legible. Drawn over the blur, it holds at least 0.65 black from the caption's top line down, whatever the material does, so on pure white media textPrimary keeps 6.7:1 and the textBody metadata 4.7:1. The blur only keeps the media's own detail from competing with the caption, and over a video it clears above the progress line so the line stays sharp.
    private func captionBackdrop(frames: CardFrames) -> some View {
        let captionTopInCard = frames.caption.maxY - captionHeight - frames.card.minY
        let backdropHeight = min(frames.card.height - captionTopInCard + Self.captionBackdropFadeHeight, frames.card.height)
        let gradientHeight = max(backdropHeight, Self.captionBackdropFadeHeight)
        let fadeEndLocation = Self.captionBackdropFadeHeight / gradientHeight
        var blurMaskStops: [Gradient.Stop] = [.init(color: .clear, location: 0), .init(color: .black, location: fadeEndLocation)]
        if isHeroLoadableVideo {
            let blurClearHeight = PullRequestMediaItemView.heroProgressLineBottomInset + Self.captionBackdropBlurClearanceAboveProgressLine
            blurMaskStops += [
                .init(color: .black, location: 1 - Self.captionBottomInset / gradientHeight),
                .init(color: .clear, location: 1 - blurClearHeight / gradientHeight),
            ]
        }
        return ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .mask(LinearGradient(stops: blurMaskStops, startPoint: .top, endPoint: .bottom))
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(Self.captionBackdropTintOpacity), location: fadeEndLocation),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(height: max(backdropHeight, 0))
        .opacity(isHeroPlaybackGestureActive ? 0 : 1)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var caption: some View {
        switch post {
        case .pullRequest(let pullRequest):
            pullRequestCaption(pullRequest)
        case .weeklyEdition(let weeklyEdition):
            weeklyEditionCaption(weeklyEdition)
        }
    }

    private func weeklyEditionCaption(_ weeklyEdition: WeeklyEdition) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(action: onTapCaption) {
                    HStack(spacing: 8) {
                        Text(verbatim: "ShipTok weekly")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(RevylBrandColor.brandGradient))
                        Text(verbatim: weeklyEdition.weekDatesText)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(RevylBrandColor.textPrimary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.swipeYielding)
                .accessibilityHint("Opens this week's pull requests")
                viewerVibeBadge
            }
            .animation(.snappy, value: vibes.tally.viewerVibe)
            Button(action: onTapCaption) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(weeklyEdition.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RevylBrandColor.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(weeklyEdition.hook)
                        .font(.caption)
                        .foregroundStyle(RevylBrandColor.textBody)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.swipeYielding)
            .accessibilityHint("Opens this week's pull requests")
        }
        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
        .onGeometryChange(for: CGFloat.self) { captionGeometry in
            captionGeometry.size.height
        } action: { measuredCaptionHeight in
            captionHeight = measuredCaptionHeight
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pullRequestCaption(_ pullRequest: MergedPullRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(action: onTapCaption) {
                    HStack(spacing: 10) {
                        GitHubAvatarView(avatarURL: pullRequest.author?.avatarURL, diameter: 34)
                        Text(verbatim: pullRequest.author?.login ?? "ghost")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(RevylBrandColor.textPrimary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.swipeYielding)
                .accessibilityHint("Opens the pull request's details")
                viewerVibeBadge
            }
            .animation(.snappy, value: vibes.tally.viewerVibe)
            Button(action: onTapCaption) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pullRequest.title)
                        .font(.subheadline)
                        .foregroundStyle(RevylBrandColor.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        Text(verbatim: "#\(pullRequest.number)")
                        Text("·")
                        Text("merged \(pullRequest.mergedAt.formatted(.relative(presentation: .named)))")
                    }
                    .font(.caption)
                    .foregroundStyle(RevylBrandColor.textBody)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.swipeYielding)
            .accessibilityHint("Opens the pull request's details")
        }
        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
        .onGeometryChange(for: CGFloat.self) { captionGeometry in
            captionGeometry.size.height
        } action: { measuredCaptionHeight in
            captionHeight = measuredCaptionHeight
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // The badge is how a person removes their vibe later (AGENTS.md, "Vibes").
    @ViewBuilder
    private var viewerVibeBadge: some View {
        if let viewerVibe = vibes.tally.viewerVibe {
            Button { isViewerVibeRemovalConfirmationPresented = true } label: {
                Text("Your \(viewerVibe.displayName.lowercased())")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(viewerVibe.tintColor.opacity(0.85)))
                    .expandingTapTargetVertically()
            }
            .buttonStyle(.swipeYielding)
            .fixedSize()
            .transition(.scale(scale: 0.8, anchor: .leading).combined(with: .opacity))
            .accessibilityHint("Offers removing your vibe")
            .confirmationDialog(
                "Remove your \(viewerVibe.displayName.lowercased())?",
                isPresented: $isViewerVibeRemovalConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive, action: vibes.onRemoveViewerVibe)
            }
        }
    }

    private var actionRail: some View {
        let reactions = post.reactions
        let viewerHasLiked = reactions.viewerReactions.contains(.heart)
        let viewerReactionOtherThanLike = GitHubReaction.allCases.first { $0 != .heart && reactions.viewerReactions.contains($0) }
        let isHeroVideoMuted = HeroVideoMuteChoice.shared.isMuted
        return ActionRailStack {
            railItem(
                systemImageName: viewerHasLiked ? "heart.fill" : "heart",
                tint: viewerHasLiked ? RevylBrandColor.danger : RevylBrandColor.textPrimary,
                count: reactions.count(of: .heart)
            )
            .symbolEffect(.bounce, value: viewerHasLiked)
            .contentShape(Rectangle())
            .gesture(
                LongPressGesture(minimumDuration: 0.35)
                    .onEnded { _ in isReactionPickerPresented = true }
                    .exclusively(before: TapGesture().onEnded { onToggleLike() })
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(viewerHasLiked ? "Unlike" : "Like")
            .accessibilityValue(Self.compactCount(reactions.count(of: .heart)))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onToggleLike() }
            .accessibilityAction(named: "React") { isReactionPickerPresented = true }
            Button(action: onOpenComments) {
                railItem(
                    systemImageName: "bubble.right",
                    tint: RevylBrandColor.textPrimary,
                    count: post.discussionCommentCount
                )
            }
            .buttonStyle(.swipeYielding)
            .accessibilityLabel("Comments")
            .accessibilityValue(Self.compactCount(post.discussionCommentCount))
            Button { isReactionPickerPresented.toggle() } label: {
                if !isReactionPickerPresented, let viewerReactionOtherThanLike {
                    Text(verbatim: viewerReactionOtherThanLike.emoji)
                        .font(.system(size: 26))
                        .frame(width: Self.railGlyphSize.width, height: Self.railGlyphSize.height)
                        .actionRailGlyphStyle()
                } else {
                    railItem(systemImageName: isReactionPickerPresented ? "xmark" : "face.smiling", tint: RevylBrandColor.textPrimary, count: nil)
                }
            }
            .buttonStyle(.swipeYielding)
            .accessibilityLabel("React")
            .accessibilityValue(viewerReactionOtherThanLike?.accessibilityName ?? "")
            .onGeometryChange(for: CGRect.self) { reactButtonGeometry in
                reactButtonGeometry.frame(in: .named(Self.cardCoordinateSpaceName))
            } action: { reactButtonFrame in
                reactButtonFrameInCard = reactButtonFrame
            }
            vibesMenu
            if isHeroLoadableVideo {
                Button { HeroVideoMuteChoice.shared.isMuted.toggle() } label: {
                    railItem(
                        systemImageName: isHeroVideoMuted ? "speaker.slash" : "speaker.wave.2",
                        tint: RevylBrandColor.textPrimary,
                        count: nil
                    )
                    .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.swipeYielding)
                .accessibilityLabel(isHeroVideoMuted ? "Unmute video" : "Mute video")
                Button {
                    let previousRate = playbackRateChoice.chosenPlaybackRate
                    playbackRateChoice.chooseNextOfferedPlaybackRate()
                    analytics?.capture(.speedChanged(analyticsSubject, control: .feedRail, previousRate: previousRate,
                                                      playbackRate: playbackRateChoice.chosenPlaybackRate))
                } label: {
                    Text(verbatim: playbackRateChoice.chosenPlaybackRateText)
                        .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(RevylBrandColor.textPrimary)
                        .contentTransition(.numericText())
                        .frame(width: Self.railGlyphSize.width, height: 26)
                        .overlay(Capsule().strokeBorder(RevylBrandColor.textPrimary, lineWidth: 1.5))
                        .frame(width: Self.railGlyphSize.width, height: Self.railGlyphSize.height)
                        .actionRailGlyphStyle()
                        .animation(.snappy(duration: 0.2), value: playbackRateChoice.chosenPlaybackRate)
                }
                .buttonStyle(.swipeYielding)
                .accessibilityLabel("Playback speed")
                .accessibilityValue(playbackRateChoice.chosenPlaybackRateText)
                .accessibilityHint("Changes the speed of every video")
            }
            switch post {
            case .pullRequest(let pullRequest):
                // The deck is where a still or GIF zooms (AGENTS.md, "Card Layout").
                if pullRequest.mediaItems.count > 1 || heroMediaItem?.kind == .image || heroMediaItem?.kind == .animatedImage {
                    PullRequestMediaDeckButton(mediaItems: pullRequest.mediaItems, action: onOpenDeck)
                }
            case .weeklyEdition(let weeklyEdition):
                Button(action: onOpenDeck) {
                    railItem(
                        systemImageName: "rectangle.stack",
                        tint: RevylBrandColor.textPrimary,
                        count: weeklyEdition.pullRequestNumbers.count
                    )
                }
                .buttonStyle(.swipeYielding)
                .accessibilityLabel("This week's pull requests")
                .accessibilityValue(weeklyEdition.pullRequestNumbers.count == 1 ? "1 pull request" : "\(weeklyEdition.pullRequestNumbers.count) pull requests")
            }
            if !moderation.reportableContents.isEmpty {
                moderationMenu
            }
        }
        .frame(width: Self.railWidth)
    }

    private var moderationMenu: some View {
        GitHubPostedContentModerationMenu(moderation: moderation) {
            railItem(systemImageName: "ellipsis", tint: RevylBrandColor.textPrimary, count: nil)
        }
        .accessibilityLabel("More")
        .accessibilityHint("Report on GitHub or hide a person")
    }

    private var vibesMenu: some View {
        let viewerVibe = vibes.tally.viewerVibe
        return Menu {
            ForEach(PullRequestVibe.allCases, id: \.self) { vibe in
                Button { vibes.onCast(vibe) } label: {
                    Label(vibe.displayName, systemImage: vibe.systemImageName)
                }
            }
            if let viewerVibe {
                Button(role: .destructive, action: vibes.onRemoveViewerVibe) {
                    Label("Remove your \(viewerVibe.displayName.lowercased())", systemImage: "trash")
                }
            }
        } label: {
            railItem(
                systemImageName: viewerVibe.map { "\($0.systemImageName).fill" } ?? "sparkles",
                tint: viewerVibe?.tintColor ?? RevylBrandColor.textPrimary,
                count: nil
            )
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Vibes")
        .accessibilityValue(viewerVibe?.displayName ?? "")
    }

    private var reactionPicker: some View {
        GitHubReactionPicker(viewerReactions: post.reactions.viewerReactions) { reaction in
            onToggleReaction(reaction)
            isReactionPickerPresented = false
        }
    }

    private func reactionPickerOffset(cardFrame: CGRect) -> CGSize {
        let pickerSize = GitHubReactionPicker.fittedSize
        let railLeadingX = reactButtonFrameInCard.midX - Self.railWidth / 2
        let pickerX = railLeadingX - Self.reactionPickerSpacing - pickerSize.width
        let pickerY = reactButtonFrameInCard.midY - pickerSize.height / 2
        let lowestPickerY = cardFrame.maxY - Self.overlayInset - pickerSize.height
        let highestPickerY = cardFrame.minY + Self.overlayInset
        return CGSize(
            width: max(pickerX, cardFrame.minX + Self.overlayInset),
            height: max(highestPickerY, min(pickerY, lowestPickerY))
        )
    }

    private func railItem(systemImageName: String, tint: Color, count: Int?) -> some View {
        VStack(spacing: 2) {
            Image(systemName: systemImageName)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: Self.railGlyphSize.width, height: Self.railGlyphSize.height)
                .actionRailGlyphStyle()
            if let count {
                Text(Self.compactCount(count))
                    .actionRailCountStyle()
                    .contentTransition(.numericText(value: Double(count)))
                    .animation(.snappy, value: count)
            }
        }
    }

    static func compactCount(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName))
    }
}

// Stacks the rail from the bottom like Reels, closing its gaps when a tall status strip leaves less room, and never letting its top climb above its frame (AGENTS.md, "Card Layout").
private struct ActionRailStack: Layout {
    private static let preferredSpacing: CGFloat = 14
    // A glyph's 40-point frame pads its 26-point symbol by 7 points above and below, so neighbors may overlap 6 points of it before the symbols crowd.
    private static let tightestSpacing: CGFloat = -6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let subviewSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let naturalHeight = subviewSizes.reduce(0) { $0 + $1.height } + Self.preferredSpacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: subviewSizes.map(\.width).max() ?? 0, height: min(naturalHeight, proposal.height ?? naturalHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let subviewSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let contentHeight = subviewSizes.reduce(0) { $0 + $1.height }
        let spacing = min(Self.preferredSpacing, max((bounds.height - contentHeight) / CGFloat(max(subviews.count - 1, 1)), Self.tightestSpacing))
        var subviewTop = bounds.minY
        for (subview, subviewSize) in zip(subviews, subviewSizes) {
            subview.place(at: CGPoint(x: bounds.midX, y: subviewTop), anchor: .top, proposal: ProposedViewSize(subviewSize))
            subviewTop += subviewSize.height + spacing
        }
    }
}
