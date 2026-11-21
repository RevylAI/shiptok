import SwiftUI

enum FeedCardPost {
    case pullRequest(PullRequest)
    case weeklyEdition(WeeklyEdition)
    case feature(Feature)

    var thread: any GitHubCommentThread {
        switch self {
        case .pullRequest(let pullRequest): pullRequest
        case .weeklyEdition(let weeklyEdition): weeklyEdition
        case .feature(let feature): feature
        }
    }

    var vibeTarget: VibeTarget {
        switch self {
        case .pullRequest(let pullRequest): VibeTarget(pullRequest: pullRequest)
        case .weeklyEdition(let weeklyEdition): VibeTarget(weeklyEdition: weeklyEdition)
        case .feature(let feature): VibeTarget(feature: feature)
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

// One feed page laid out like Instagram Reels: a pull request, a week's video in Weekly or a feature's video in Features. A pull request with no media, which only a feature's deck shows, puts its summary where the media would be. Its layout follows AGENTS.md, "Card Layout".
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
    let pageLayout: FeedPageLayout
    let videoScrubFraction: CGFloat?
    let heroZoom: MediaZoom
    let vibeFeedbackComposerHeight: CGFloat
    let isBehindVibeFeedbackComposer: Bool
    let isKeyboardShown: Bool
    let vibes: FeedCardVibes
    let moderation: GitHubPostedContentModeration
    // A week's or a feature's deck button shows a number only once that deck has been read in full, so it never counts a card the deck leaves out (AGENTS.md, "Pull Request Decks").
    let deckPullRequestCount: Int?
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
    let onHeroMediaLoadFailure: (PullRequestMediaItem, _ wasRefusedToViewer: Bool) -> Void
    let onHeroMediaSizeRead: (PullRequestMediaItem, CGSize) -> Void
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
    private static let overlayInset: CGFloat = 16
    private static let captionToComposerSpacing: CGFloat = 12
    private static let captionToRailSpacing: CGFloat = 8
    private static let captionBackdropFadeHeight: CGFloat = 80
    private static let captionBackdropBlurClearanceAboveProgressLine: CGFloat = 6
    private static let reactionPickerSpacing: CGFloat = 8
    private static let shipTokVideoSize = CGSize(width: 1080, height: 1920)
    private static let shipTokVideoSafeZoneTopFractionOfHeight: CGFloat = 322.0 / 1920.0
    private static let shipTokVideoSafeZoneBottomFractionOfHeight: CGFloat = 1376.0 / 1920.0
    private static let summaryToCaptionSpacing: CGFloat = 16
    private static let summaryOverflowFadeHeight: CGFloat = 48
    private nonisolated static let cardCoordinateSpaceName = "feedCard"

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

    // A zoomed hero is for reading what's in the media, so the caption and its backdrop step out of the way.
    private var isCardTextHidden: Bool {
        isReactionPickerPresented || showsOnlyHeroBehindVibeFeedbackComposer || isHeroPlaybackGestureActive || heroZoom.isZoomed
    }

    // The hero keeps one place in the view tree whatever the page layout, so a playing video never restarts when the window changes shape.
    var body: some View {
        GeometryReader { geometry in
            let arrangedFrames = cardFrames(in: geometry.size)
            ZStack(alignment: .topLeading) {
                heroMedia(captionBackdrop: captionBackdrop(frames: arrangedFrames))
                    .frame(width: arrangedFrames.card.width, height: arrangedFrames.card.height)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
                    .overlay {
                        if isHeroLoadableVideo {
                            heroFastPlaybackHoldArea
                        }
                    }
                    .offset(x: arrangedFrames.card.minX, y: arrangedFrames.card.minY)
                if case .pullRequest(let pullRequest) = post, heroMediaItem == nil {
                    let summaryFrame = pullRequestSummaryFrame(frames: arrangedFrames)
                    pullRequestSummary(pullRequest)
                        .frame(width: summaryFrame.width, height: summaryFrame.height, alignment: .topLeading)
                        .opacity(isCardTextHidden ? 0 : 1)
                        .offset(x: summaryFrame.minX, y: summaryFrame.minY)
                }
                caption
                    .frame(width: arrangedFrames.caption.width, height: arrangedFrames.caption.height, alignment: .bottomLeading)
                    .opacity(isCardTextHidden ? 0 : 1)
                    .animation(.easeOut(duration: 0.15), value: heroZoom.isZoomed)
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
            // A sideways swipe is the only visible way to cast a vibe, so every element on the card offers both to VoiceOver (AGENTS.md, "Vibes").
            .accessibilityActions {
                ForEach(PullRequestVibe.allCases, id: \.self) { vibe in
                    Button(vibe.displayName) { vibes.onCast(vibe) }
                }
            }
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

    private func cardFrames(in pageSize: CGSize) -> CardFrames {
        let card = pageLayout.card
        let captionLeading = card.minX + Self.overlayInset
        let captionTrailing = pageLayout.isRailBesideCard ? card.maxX - Self.overlayInset : pageLayout.rail.minX - Self.captionToRailSpacing
        let unobstructedCaptionBottom = pageLayout.contentBottom - FeedPageLayout.captionBottomInset
        let composerTop = pageSize.height - pageLayout.bottomChromeHeight - vibeFeedbackComposerHeight
        let captionBottom = vibeFeedbackComposerHeight > 0
            ? min(unobstructedCaptionBottom, composerTop - Self.captionToComposerSpacing)
            : unobstructedCaptionBottom
        let captionTop = max(card.minY, pageLayout.topRow.maxY) + Self.overlayInset
        let caption = CGRect(
            x: captionLeading,
            y: captionTop,
            width: max(captionTrailing - captionLeading, 0),
            height: max(captionBottom - captionTop, 0)
        )
        return CardFrames(card: card, rail: pageLayout.rail, caption: caption)
    }

    @ViewBuilder
    private func heroMedia(captionBackdrop: FeedCaptionBackdrop) -> some View {
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
                zoom: heroZoom,
                progressLineInsets: pageLayout.heroProgressLineInsets,
                wholeMediaInsets: pageLayout.wholeHeroMediaInsets,
                captionBackdrop: captionBackdrop,
                onLoadFailure: { onHeroMediaLoadFailure(heroMediaItem, $0) },
                onMediaSizeRead: { onHeroMediaSizeRead(heroMediaItem, $0) }
            )
            .id(heroMediaItem.id)
        } else {
            RevylBrandColor.surfaceRaised
                .overlay(alignment: .bottom) { captionBackdrop }
        }
    }

    // Everywhere on the hero but the scrub strip, so a finger resting on the progress line before it drags scrubs rather than speeding up.
    private var heroFastPlaybackHoldArea: some View {
        Color.clear
            .contentShape(Rectangle())
            .padding(.bottom, FeedPageLayout.captionBottomInset + pageLayout.homeIndicatorInsetInCard)
            .fastPlaybackHold(isHeld: $isHeroFastPlaybackHeld)
    }

    // The backdrop fades in over at most 80 points above the caption and never starts above the bottom of a ShipTok video's safe zone, so the video's own
    // captions stay sharp; where the caption itself reaches above that line, the backdrop starts at the caption's top (AGENTS.md, "Card Layout").
    private func captionBackdrop(frames: CardFrames) -> FeedCaptionBackdrop {
        let captionTopInCard = frames.caption.maxY - captionHeight - frames.card.minY
        let backdropTopInCard = min(
            max(captionTopInCard - Self.captionBackdropFadeHeight, shipTokVideoSafeZoneBottom(inCardOfSize: frames.card.size)),
            captionTopInCard
        )
        let backdropHeight = max(frames.card.height - backdropTopInCard, 1)
        let fadeEndLocation = (captionTopInCard - backdropTopInCard) / backdropHeight
        var blurMaskStops: [Gradient.Stop] = [.init(color: .clear, location: 0), .init(color: .black, location: fadeEndLocation)]
        if isHeroLoadableVideo {
            let blurClearHeight = pageLayout.heroProgressLineInsets.bottom + Self.captionBackdropBlurClearanceAboveProgressLine
            blurMaskStops += [
                .init(color: .black, location: 1 - (FeedPageLayout.captionBottomInset + pageLayout.homeIndicatorInsetInCard) / backdropHeight),
                .init(color: .clear, location: 1 - blurClearHeight / backdropHeight),
            ]
        }
        return FeedCaptionBackdrop(
            height: backdropHeight,
            tintFullLocation: fadeEndLocation,
            blurMaskStops: blurMaskStops,
            isHidden: isHeroPlaybackGestureActive || heroZoom.isZoomed
        )
    }

    // Where the safe zone of a 9:16 ShipTok video ends on a card of this size, the video laid out as the hero lays it out: cropped to fill the card when that
    // loses at most an eighth of it, else whole and centered between the page layout's whole-media insets (AGENTS.md, "Card Layout").
    private func shipTokVideoSafeZoneBottom(inCardOfSize cardSize: CGSize) -> CGFloat {
        let fillsCard = PullRequestMediaItemView.heroMediaFillsCard(mediaSize: Self.shipTokVideoSize, cardSize: cardSize)
        let insets = fillsCard ? EdgeInsets() : pageLayout.wholeHeroMediaInsets
        let videoBoxSize = CGSize(width: cardSize.width - insets.leading - insets.trailing, height: cardSize.height - insets.top - insets.bottom)
        let widthScale = videoBoxSize.width / Self.shipTokVideoSize.width
        let heightScale = videoBoxSize.height / Self.shipTokVideoSize.height
        let videoHeight = Self.shipTokVideoSize.height * (fillsCard ? max(widthScale, heightScale) : min(widthScale, heightScale))
        return insets.top + (videoBoxSize.height - videoHeight) / 2 + videoHeight * Self.shipTokVideoSafeZoneBottomFractionOfHeight
    }

    // The summary keeps to the band of the card where a ShipTok video keeps everything a viewer must read, beside the rail and above the caption, so nothing the app draws over a card covers it (AGENTS.md, "Card Layout").
    private func pullRequestSummaryFrame(frames: CardFrames) -> CGRect {
        let summaryTop = frames.card.minY + frames.card.height * Self.shipTokVideoSafeZoneTopFractionOfHeight
        let summaryBottom = min(
            frames.card.minY + frames.card.height * Self.shipTokVideoSafeZoneBottomFractionOfHeight,
            frames.caption.maxY - captionHeight - Self.summaryToCaptionSpacing
        )
        return CGRect(
            x: frames.caption.minX,
            y: summaryTop,
            width: min(frames.caption.width, ReadableContentColumn.maximumWidthPoints),
            height: max(summaryBottom - summaryTop, 0)
        )
    }

    // With nothing to play, the card says what the pull request changed. Only its details button takes a tap, so a double tap anywhere else still likes it and a link in the description never opens.
    private func pullRequestSummary(_ pullRequest: PullRequest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                pullRequestStateChip(pullRequest)
                PullRequestDiffStats(pullRequest: pullRequest)
            }
            .allowsHitTesting(false)
            ViewThatFits(in: .vertical) {
                pullRequestLabelsAndDescription(pullRequest)
                pullRequestLabelsAndDescription(pullRequest)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .mask {
                        VStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: Self.summaryOverflowFadeHeight)
                        }
                    }
            }
            .allowsHitTesting(false)
            Button(action: onTapCaption) {
                Label("Details", systemImage: "text.alignleft")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RevylBrandColor.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(RevylBrandColor.surfaceFloating))
                    .overlay(Capsule().stroke(RevylBrandColor.border, lineWidth: 1))
                    .expandingTapTargetVertically()
            }
            .buttonStyle(.swipeYielding)
            .accessibilityHint("Opens the pull request's details")
        }
    }

    private func pullRequestStateChip(_ pullRequest: PullRequest) -> some View {
        let (stateName, systemImageName, stateColor): (String, String, Color) =
            if pullRequest.mergedAt != nil {
                ("Merged", "arrow.triangle.merge", RevylBrandColor.brand)
            } else if pullRequest.isDraft {
                ("Draft", "arrow.triangle.pull", RevylBrandColor.textSubtle)
            } else {
                ("Open", "arrow.triangle.pull", RevylBrandColor.success)
            }
        return Label(stateName, systemImage: systemImageName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(RevylBrandColor.textPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(stateColor.opacity(0.25)))
            .overlay(Capsule().stroke(stateColor, lineWidth: 1))
    }

    private func pullRequestLabelsAndDescription(_ pullRequest: PullRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !pullRequest.labels.isEmpty {
                PullRequestLabelChips(labels: pullRequest.labels)
            }
            if MarkdownSummaryParser.blocks(from: pullRequest.descriptionMarkdown).isEmpty {
                Text("No description.")
                    .font(.subheadline)
                    .foregroundStyle(RevylBrandColor.textMuted)
            } else {
                MarkdownSummaryView(markdown: pullRequest.descriptionMarkdown)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var caption: some View {
        switch post {
        case .pullRequest(let pullRequest):
            pullRequestCaption(pullRequest)
        case .weeklyEdition(let weeklyEdition):
            publishedIssueCaption(
                chipText: "ShipTok weekly",
                dateText: weeklyEdition.weekDatesText,
                title: weeklyEdition.title,
                hook: weeklyEdition.hook,
                accessibilityHint: "Opens this week's pull requests"
            )
        case .feature(let feature):
            publishedIssueCaption(
                chipText: "ShipTok feature",
                dateText: "shipped \(feature.closedAt.formatted(.relative(presentation: .named)))",
                title: feature.title,
                hook: feature.hook,
                accessibilityHint: "Opens the pull requests behind this feature"
            )
        }
    }

    // A week or a feature names itself with a chip, a date, its title and its hook, and every part of the caption opens its pull requests.
    private func publishedIssueCaption(chipText: String, dateText: String, title: String, hook: String, accessibilityHint: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(action: onTapCaption) {
                    HStack(spacing: 8) {
                        Text(verbatim: chipText)
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(RevylBrandColor.brandGradient))
                        Text(verbatim: dateText)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(RevylBrandColor.textPrimary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.swipeYielding)
                .accessibilityHint(accessibilityHint)
                viewerVibeBadge
            }
            .animation(.snappy, value: vibes.tally.viewerVibe)
            Button(action: onTapCaption) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(RevylBrandColor.textPrimary)
                        .lineLimit(2)
                    Text(hook)
                        .font(.subheadline)
                        .foregroundStyle(RevylBrandColor.textBody)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.swipeYielding)
            .accessibilityHint(accessibilityHint)
        }
        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
        .onGeometryChange(for: CGFloat.self) { captionGeometry in
            captionGeometry.size.height
        } action: { measuredCaptionHeight in
            captionHeight = measuredCaptionHeight
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pullRequestCaption(_ pullRequest: PullRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(action: onTapCaption) {
                    HStack(spacing: 10) {
                        GitHubAvatarView(avatarURL: pullRequest.author?.avatarURL, diameter: 36)
                        Text(verbatim: pullRequest.author?.login ?? "ghost")
                            .font(.callout.weight(.semibold))
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
                        .font(.callout)
                        .foregroundStyle(RevylBrandColor.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(verbatim: "#\(pullRequest.number)")
                        Text("·")
                        if let mergedAt = pullRequest.mergedAt {
                            Text("merged \(mergedAt.formatted(.relative(presentation: .named)))")
                        } else {
                            Text("\(pullRequest.isDraft ? "Draft · " : "")updated \(pullRequest.updatedAt.formatted(.relative(presentation: .named)))")
                        }
                    }
                    .font(.subheadline)
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
                        .frame(width: FeedPageLayout.railGlyphSize.width, height: FeedPageLayout.railGlyphSize.height)
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
                        .frame(width: FeedPageLayout.railGlyphSize.width, height: 26)
                        .overlay(Capsule().strokeBorder(RevylBrandColor.textPrimary, lineWidth: 1.5))
                        .frame(width: FeedPageLayout.railGlyphSize.width, height: FeedPageLayout.railGlyphSize.height)
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
                // A lone still or GIF opens in the deck too, where it always shows whole (AGENTS.md, "Card Layout").
                if pullRequest.mediaItems.count > 1 || heroMediaItem?.kind == .image || heroMediaItem?.kind == .animatedImage {
                    PullRequestMediaDeckButton(mediaItems: pullRequest.mediaItems, action: onOpenDeck)
                }
            case .weeklyEdition:
                pullRequestDeckButton(accessibilityLabel: "This week's pull requests")
            case .feature:
                pullRequestDeckButton(accessibilityLabel: "The pull requests behind this feature")
            }
            if !moderation.reportableContents.isEmpty {
                moderationMenu
            }
        }
        .frame(width: FeedPageLayout.railWidth)
    }

    private func pullRequestDeckButton(accessibilityLabel: String) -> some View {
        Button(action: onOpenDeck) {
            railItem(systemImageName: "rectangle.stack", tint: RevylBrandColor.textPrimary, count: deckPullRequestCount)
        }
        .buttonStyle(.swipeYielding)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(deckPullRequestCount.map { $0 == 1 ? "1 pull request" : "\($0) pull requests" } ?? "")
    }

    private var moderationMenu: some View {
        GitHubPostedContentModerationMenu(moderation: moderation) {
            railItem(systemImageName: "ellipsis", tint: RevylBrandColor.textPrimary, count: nil)
        }
        .accessibilityLabel("More")
        .accessibilityHint("Report on GitHub or hide a person")
    }

    private var reactionPicker: some View {
        GitHubReactionPicker(viewerReactions: post.reactions.viewerReactions) { reaction in
            onToggleReaction(reaction)
            isReactionPickerPresented = false
        }
    }

    private func reactionPickerOffset(cardFrame: CGRect) -> CGSize {
        let pickerSize = GitHubReactionPicker.fittedSize
        let railLeadingX = reactButtonFrameInCard.midX - FeedPageLayout.railWidth / 2
        let pickerX = railLeadingX - Self.reactionPickerSpacing - pickerSize.width
        let pickerY = reactButtonFrameInCard.midY - pickerSize.height / 2
        let lowestPickerY = pageLayout.contentBottom - Self.overlayInset - pickerSize.height
        let highestPickerY = cardFrame.minY + Self.overlayInset
        return CGSize(
            width: max(pickerX, cardFrame.minX + Self.overlayInset),
            height: max(highestPickerY, min(pickerY, lowestPickerY))
        )
    }

    private func railItem(systemImageName: String, tint: Color, count: Int?) -> some View {
        VStack(spacing: 2) {
            Image(systemName: systemImageName)
                .font(.actionRailGlyph)
                .foregroundStyle(tint)
                .frame(width: FeedPageLayout.railGlyphSize.width, height: FeedPageLayout.railGlyphSize.height)
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

// The tint, not the blur, keeps the caption legible. Drawn over the blur, it holds at least 0.65 black from the caption's top line down, whatever the material does, so on pure white media textPrimary keeps 6.7:1 and the textBody metadata 4.7:1. The blur only keeps the media's own detail from competing with the caption, and over a video it clears above the progress line, which the hero draws over this backdrop so the tint never darkens it.
struct FeedCaptionBackdrop: View {
    let height: CGFloat
    let tintFullLocation: CGFloat
    let blurMaskStops: [Gradient.Stop]
    let isHidden: Bool

    private static let tintOpacity = 0.65

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .mask(LinearGradient(stops: blurMaskStops, startPoint: .top, endPoint: .bottom))
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(Self.tintOpacity), location: tintFullLocation),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(height: height)
        .opacity(isHidden ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: isHidden)
        .allowsHitTesting(false)
    }
}

// Stacks the rail from the bottom like Reels, closing its gaps when a tall status strip leaves less room, and never letting its top climb above its frame (AGENTS.md, "Card Layout").
private struct ActionRailStack: Layout {
    // A glyph's 40-point frame pads its 26-point symbol by 7 points above and below, so neighbors may overlap 6 points of it before the symbols crowd.
    private static let tightestSpacing: CGFloat = -6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let subviewSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let naturalHeight = subviewSizes.reduce(0) { $0 + $1.height } + FeedPageLayout.railGlyphSpacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: subviewSizes.map(\.width).max() ?? 0, height: min(naturalHeight, proposal.height ?? naturalHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let subviewSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let contentHeight = subviewSizes.reduce(0) { $0 + $1.height }
        let spacing = min(FeedPageLayout.railGlyphSpacing, max((bounds.height - contentHeight) / CGFloat(max(subviews.count - 1, 1)), Self.tightestSpacing))
        var subviewTop = bounds.minY
        for (subview, subviewSize) in zip(subviews, subviewSizes) {
            subview.place(at: CGPoint(x: bounds.midX, y: subviewTop), anchor: .top, proposal: ProposedViewSize(subviewSize))
            subviewTop += subviewSize.height + spacing
        }
    }
}
