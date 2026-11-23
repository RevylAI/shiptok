import SwiftUI

struct FeedView: View {
    private enum FeedContext: Hashable {
        case feed(FeedMode)
        case openDeck
    }

    private enum FeedPage: Identifiable {
        case post(ShipTokPost)
        case feedEnd

        var id: String {
            switch self {
            case .post(let post): post.id
            case .feedEnd: "feed-end"
            }
        }

        var vibeTarget: VibeTarget? {
            switch self {
            case .post(let post): VibeTarget(post: post)
            case .feedEnd: nil
            }
        }
    }

    private enum DeckDrag {
        case pageSwipe
        case vibeSwipe
        case videoScrub
        // While the hero is zoomed, one finger pans it instead of swiping (AGENTS.md, "Swipe Gestures").
        case heroPan(MediaZoomPan)
        // A drag that a pinch overlaps belongs to the pinch until its finger lifts, so a pinch never swipes.
        case heroPinch
    }

    // A zoom never outlives the card and media it was made on.
    private struct HeroZoomSubject: Equatable {
        let feedContext: FeedContext
        let pageID: String
        let heroMediaItemID: String?
    }

    private struct VibeAwaitingFeedback: Identifiable, Equatable {
        let id: UUID
        let target: VibeTarget
        let vibe: ShipTokVibe
        var feedbackText = ""
    }

    private struct CommentsSheetRequest: Identifiable {
        let id = UUID()
        let post: ShipTokPost
        let focusedCommentID: String?
    }

    // An inbox item or a notification can name a post that isn't loaded yet, so its comments open once its card has been read.
    private struct PendingCommentsOpening: Equatable {
        let postID: String
        let focusedCommentID: String?
    }

    private struct PresentedPostID: Identifiable {
        let id: String
    }

    let viewer: SignedInTeammate
    let repository: FeedRepositoryChoice
    let signInSession: ShipTokSignInSession
    let onChooseRepository: @MainActor (ShipTokRepository) -> Void
    @State private var feedStore: PostFeedStore
    @State private var vibeOutbox: VibeOutbox
    @State private var inboxStore: DeveloperInboxStore
    @State private var userSettingsStore: UserSettingsStore
    @AppStorage("feed-mode") private var feedMode: FeedMode = .merged
    @State private var playbackRateChoice: VideoPlaybackRateChoice
    @State private var pageIndexByFeedMode: [FeedMode: Int] = [:]
    @State private var openDeckPageIndex = 0
    @State private var verticalDragOffset: CGFloat = 0
    @State private var horizontalDragOffset: CGFloat = 0
    @State private var activeDeckDrag: DeckDrag?
    @State private var videoScrubFraction: CGFloat?
    @State private var heroZoom = MediaZoom.normalFit
    @State private var heroPinch: MediaZoom.Pinch?
    @State private var heroMediaSizes: [String: CGSize] = [:]
    @State private var systemOcclusionFrames: [CGRect] = []
    @State private var isTabBarShown = true
    @State private var isPageTransitionRunning = false
    @State private var cardEntranceScale: CGFloat = 1
    @State private var likeBurstTriggers: [String: Int] = [:]
    @State private var vibeAwaitingFeedback: VibeAwaitingFeedback?
    @State private var commentsSheetRequest: CommentsSheetRequest?
    @State private var pendingCommentsOpening: PendingCommentsOpening?
    @State private var detailSheetPostID: PresentedPostID?
    @State private var mediaDeckPostID: PresentedPostID?
    @State private var contentAwaitingHideConfirmation: ReportableContent?
    @State private var selectedTab: AppTab = .feed
    @State private var goodVibesHapticTrigger = 0
    @State private var badVibesHapticTrigger = 0
    @State private var likeHapticTrigger = 0
    @State private var pageChangeHapticTrigger = 0
    @State private var pullToRefreshHapticTrigger = 0
    @State private var vibeFeedbackComposerHeight: CGFloat = 0
    @State private var safeAreaBottomInset: CGFloat = 0
    @State private var keyboardAwareSafeAreaBottomInset: CGFloat = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    private static let liveRefreshIntervalSeconds = 10
    private static let pullToRefreshThresholdFraction: CGFloat = 0.18
    private static let toastMaximumWidth: CGFloat = 440
    private static let vibeFeedbackComposerMaximumWidth: CGFloat = 560
    private static let cardRailClearanceWidth: CGFloat = 88
    private static let tabBarMinimumBottomGap: CGFloat = 20
    private static let tabBarDipIntoBottomSafeArea: CGFloat = 12
    private static let tabPageScrollEndToTabBarSpacing: CGFloat = 12
    private static let minimumKeyboardOverlap: CGFloat = 1
    private static let newerPostsButtonGapBelowTopRow: CGFloat = 8

    init(
        viewer: SignedInTeammate,
        repository: FeedRepositoryChoice,
        signInSession: ShipTokSignInSession,
        onChooseRepository: @escaping @MainActor (ShipTokRepository) -> Void,
        onRepositoryLost: @escaping @MainActor (String) -> Void
    ) {
        self.viewer = viewer
        self.repository = repository
        self.signInSession = signInSession
        self.onChooseRepository = onChooseRepository
        let feedStore = PostFeedStore(
            api: viewer.api,
            repositoryID: repository.githubRepositoryID,
            analytics: viewer.analytics,
            revylUserID: viewer.account.revylUserID,
            hiddenPeopleStore: viewer.hiddenPeopleStore,
            feedWork: viewer.feedWork,
            onRepositoryLost: onRepositoryLost
        )
        _feedStore = State(initialValue: feedStore)
        _vibeOutbox = State(initialValue: VibeOutbox(api: viewer.api, analytics: viewer.analytics, feedStore: feedStore))
        _inboxStore = State(initialValue: DeveloperInboxStore(api: viewer.api, hiddenPeopleStore: viewer.hiddenPeopleStore))
        _userSettingsStore = State(initialValue: UserSettingsStore(api: viewer.api))
        _playbackRateChoice = State(initialValue: .savedOnDevice())
    }

    private var showsOnlyPostsWithVideos: Bool {
        userSettingsStore.userSettings.showsOnlyPostsWithVideos
    }

    // A week's or a feature's deck shows over its own mode; a deck of one post, opened from the inbox or a notification, shows over whichever mode is selected (AGENTS.md, "Pull Request Decks").
    private var feedContext: FeedContext {
        guard let openDeckSource = feedStore.openDeckSource, openDeckSource.feedMode == nil || openDeckSource.feedMode == feedMode else {
            return .feed(feedMode)
        }
        return .openDeck
    }

    private var shownFeedMode: FeedMode? {
        guard case .feed(let shownFeedMode) = onScreenFeedContext else { return nil }
        return shownFeedMode
    }

    private var onScreenPosts: OnScreenPosts? {
        switch onScreenFeedContext {
        case .feed(let shownFeedMode): .feed(shownFeedMode)
        case .openDeck: .openDeck
        case nil: nil
        }
    }

    // Refreshes, focus and the reads around it run only while the feed is on screen, never under Inbox or Settings (AGENTS.md, "Feed Order").
    private var onScreenFeedContext: FeedContext? {
        selectedTab == .feed ? feedContext : nil
    }

    // What people the viewer hid posted leaves every page, so page indexes count only what's shown (AGENTS.md, "Report And Hide").
    private var feedPages: [FeedPage] {
        switch feedContext {
        case .feed(let feedMode): feedStore.visiblePosts(in: feedMode).map(FeedPage.post) + [.feedEnd]
        case .openDeck: feedStore.visibleOpenDeckPosts.map(FeedPage.post) + [.feedEnd]
        }
    }

    private var visiblePostIDsByFeedMode: [FeedMode: [String]] {
        Dictionary(uniqueKeysWithValues: FeedMode.allCases.map { feedMode in (feedMode, feedStore.visiblePosts(in: feedMode).map(\.id)) })
    }

    // Each context keeps its own place, so switching modes or closing a deck returns to the card the viewer left.
    private var currentPageIndex: Int {
        get {
            switch feedContext {
            case .feed(let feedMode): pageIndexByFeedMode[feedMode, default: 0]
            case .openDeck: openDeckPageIndex
            }
        }
        nonmutating set {
            switch feedContext {
            case .feed(let feedMode): pageIndexByFeedMode[feedMode] = newValue
            case .openDeck: openDeckPageIndex = newValue
            }
        }
    }

    private var clampedPageIndex: Int {
        min(max(currentPageIndex, 0), feedPages.count - 1)
    }

    private var isPullToRefreshRunning: Bool {
        switch feedContext {
        case .feed(let feedMode): feedStore.loadedFeed(feedMode).isPullToRefreshRunning
        case .openDeck: feedStore.isOpenDeckPullToRefreshRunning
        }
    }

    private var nextPageOffsetSign: CGFloat {
        FeedSwipeGestureMapping.direction(for: .showNextPullRequest) == .up ? 1 : -1
    }

    private var isFeedCovered: Bool {
        detailSheetPostID != nil || mediaDeckPostID != nil || selectedTab != .feed
    }

    private var heroZoomSubject: HeroZoomSubject {
        let currentPage = feedPages[clampedPageIndex]
        return HeroZoomSubject(feedContext: feedContext, pageID: currentPage.id, heroMediaItemID: loadableHeroMediaItem(of: currentPage)?.id)
    }

    private var isHeroOccludedForAnalytics: Bool {
        commentsSheetRequest != nil
    }

    // Read from the keyboard's effect on the safe area rather than show and hide notifications, which can arrive unpaired when an iPhone Duo rotates.
    private var isKeyboardShown: Bool {
        keyboardAwareSafeAreaBottomInset - safeAreaBottomInset >= Self.minimumKeyboardOverlap
    }

    // The pill sits a little into the home indicator's band, as iOS's own floating tab bars do, and never closer than the minimum gap to the screen's edge.
    private var tabBarBottomGap: CGFloat {
        max(safeAreaBottomInset - Self.tabBarDipIntoBottomSafeArea, Self.tabBarMinimumBottomGap)
    }

    private var tabBarBottomPadding: CGFloat {
        tabBarBottomGap - safeAreaBottomInset
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Pages fill the screen under the status bar, tab bar and home indicator, and FeedPageLayout places each card, its rail and the top row in
            // it; the box rides the keyboard over the card, so the keyboard never relayouts it (AGENTS.md, "Card Layout").
            GeometryReader { safeAreaGeometry in
                GeometryReader { pageGeometry in
                    let pageLayout = FeedPageLayout.arranged(
                        pageSize: pageGeometry.size,
                        safeAreaInsets: safeAreaGeometry.safeAreaInsets,
                        floatingTabBarHeightWithBottomGap: tabBarBottomGap + AppTabBar.height,
                        systemOcclusionFrames: systemOcclusionFrames
                    )
                    feedContent(pageSize: pageGeometry.size, pageLayout: pageLayout)
                        .overlay(alignment: .topLeading) {
                            feedChrome(pageLayout: pageLayout)
                        }
                        .overlay(alignment: .top) {
                            newerPostsButton
                                .animation(.snappy, value: shownFeedMode.map { feedStore.loadedFeed($0).unseenNewerPostIDs.isEmpty } ?? true)
                                .offset(
                                    x: pageLayout.card.midX - pageGeometry.size.width / 2,
                                    y: pageLayout.topRow.maxY + Self.newerPostsButtonGapBelowTopRow
                                )
                        }
                        // Read from this full-screen reader, which never moves with a dragged page, so the rail never jumps mid-swipe.
                        .onChange(of: Self.systemOcclusionFrames(in: pageGeometry), initial: true) { _, measuredSystemOcclusionFrames in
                            systemOcclusionFrames = measuredSystemOcclusionFrames
                        }
                        .onChange(of: pageLayout.isTabBarShown, initial: true) { _, isTabBarShownInPageLayout in
                            isTabBarShown = isTabBarShownInPageLayout
                        }
                }
                .ignoresSafeArea(.container)
                .onChange(of: safeAreaGeometry.safeAreaInsets.bottom, initial: true) { _, measuredSafeAreaBottomInset in
                    safeAreaBottomInset = measuredSafeAreaBottomInset
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .accessibilityHidden(selectedTab != .feed)
            // Scroll content margins rather than safe-area padding, which a List inside the tabs' NavigationStack ignores, leaving its last rows under the pill.
            selectedTabPage
                .contentMargins(.bottom, isTabBarShown ? AppTabBar.height + tabBarBottomPadding + Self.tabPageScrollEndToTabBarSpacing : 0, for: .scrollContent)
            VStack(spacing: 0) {
                toastStack
                vibeFeedbackComposer
                    .onGeometryChange(for: CGFloat.self) { composerGeometry in
                        composerGeometry.size.height
                    } action: { measuredComposerHeight in
                        vibeFeedbackComposerHeight = measuredComposerHeight
                    }
                if isTabBarShown && !isKeyboardShown {
                    AppTabBar(
                        selectedTab: $selectedTab,
                        unseenInboxItemCount: inboxStore.unreadCount,
                        viewerAvatarURL: viewer.account.avatarURL
                    )
                    .frame(maxWidth: .infinity)
                    .ignoresSafeArea(.container, edges: .horizontal)
                    .padding(.bottom, tabBarBottomPadding)
                }
            }
            .background {
                GeometryReader { keyboardAwareGeometry in
                    Color.clear.onChange(of: keyboardAwareGeometry.safeAreaInsets.bottom, initial: true) { _, measuredKeyboardAwareSafeAreaBottomInset in
                        keyboardAwareSafeAreaBottomInset = measuredKeyboardAwareSafeAreaBottomInset
                    }
                }
            }
        }
        .background(RevylBrandColor.canvas.ignoresSafeArea())
        .sensoryFeedback(.success, trigger: goodVibesHapticTrigger)
        .sensoryFeedback(.warning, trigger: badVibesHapticTrigger)
        .sensoryFeedback(.impact(weight: .light), trigger: likeHapticTrigger)
        .sensoryFeedback(.selection, trigger: pageChangeHapticTrigger)
        .sensoryFeedback(.impact(weight: .medium), trigger: pullToRefreshHapticTrigger)
        .sheet(item: $commentsSheetRequest) { commentsSheetRequest in
            let postID = commentsSheetRequest.post.id
            PostCommentsSheet(
                post: commentsSheetRequest.post,
                viewer: viewer.account,
                hiddenPeopleStore: viewer.hiddenPeopleStore,
                api: viewer.api,
                analytics: viewer.analytics,
                focusedCommentID: commentsSheetRequest.focusedCommentID,
                onCommentCountChange: { commentCountChange in feedStore.changeCommentCount(by: commentCountChange, onPostID: postID) },
                onVibeDeleted: { Task { await feedStore.rereadPost(postID: postID) } }
            )
        }
        .sheet(item: $detailSheetPostID) { presentedPostID in
            DetailSheetContent(feedStore: feedStore, vibeOutbox: vibeOutbox, viewer: viewer, postID: presentedPostID.id)
        }
        .fullScreenCover(item: $mediaDeckPostID) { presentedPostID in
            MediaDeckCoverContent(feedStore: feedStore, viewer: viewer, postID: presentedPostID.id)
        }
        .task(id: onScreenFeedContext) {
            if onScreenFeedContext != nil {
                await refreshShownFeedContextWhileShown()
            }
        }
        .task { await inboxStore.runLiveRefreshLoop() }
        .task { await userSettingsStore.refresh() }
        .onAppear {
            feedStore.changeOnScreenPosts(to: onScreenPosts)
            focusPage(at: currentPageIndex)
        }
        .onChange(of: currentPageIndex) { _, newPageIndex in
            focusPage(at: newPageIndex)
        }
        .onChange(of: feedContext) {
            postVibeAwaitingFeedback()
        }
        .onChange(of: heroZoomSubject) {
            heroZoom = .normalFit
            heroPinch = nil
        }
        .onChange(of: onScreenFeedContext) {
            feedStore.changeOnScreenPosts(to: onScreenPosts)
            focusPage(at: currentPageIndex)
        }
        .onChange(of: selectedTab) { _, newSelectedTab in
            if newSelectedTab != .feed { postVibeAwaitingFeedback() }
        }
        .onChange(of: visiblePostIDsByFeedMode) { previousPostIDsByFeedMode, currentPostIDsByFeedMode in
            for feedMode in FeedMode.allCases where previousPostIDsByFeedMode[feedMode] != currentPostIDsByFeedMode[feedMode] {
                keepPostsPageInPlace(
                    in: feedMode,
                    previousPostIDs: previousPostIDsByFeedMode[feedMode] ?? [],
                    currentPostIDs: currentPostIDsByFeedMode[feedMode] ?? []
                )
            }
        }
        .onChange(of: feedStore.visibleOpenDeckPosts.map(\.id)) { previousPostIDs, currentPostIDs in
            let previouslyShownPostID = previousPostIDs.indices.contains(openDeckPageIndex) ? previousPostIDs[openDeckPageIndex] : nil
            if let previouslyShownPostID, let movedPageIndex = currentPostIDs.firstIndex(of: previouslyShownPostID), movedPageIndex != openDeckPageIndex {
                openDeckPageIndex = movedPageIndex
                return
            }
            // The page stayed but its card changed: the first card arrived, or the one under the viewer left, so the store's focus follows while the deck is on screen, never landing on a mode's card at the same index.
            let shownPostID = currentPostIDs.indices.contains(openDeckPageIndex) ? currentPostIDs[openDeckPageIndex] : nil
            if shownPostID != previouslyShownPostID, onScreenFeedContext == .openDeck {
                focusPage(at: openDeckPageIndex)
            }
        }
        // Revyl leaves out of Open and Merged what Videos only hides, so the feeds follow the setting Revyl has saved, not a toggle still saving (AGENTS.md, "Feed Order").
        .onChange(of: userSettingsStore.savedUserSettings?.showsOnlyPostsWithVideos, initial: true) { _, savedShowsOnlyPostsWithVideos in
            if let savedShowsOnlyPostsWithVideos {
                feedStore.applyShowsOnlyPostsWithVideos(savedShowsOnlyPostsWithVideos)
            }
        }
        // A mode whose tab the viewer turned off gives way to the first tab still on (AGENTS.md, "Feed Modes").
        .onChange(of: userSettingsStore.feedModesWithShownTabs, initial: true) { _, feedModesWithShownTabs in
            if !feedModesWithShownTabs.contains(feedMode), let firstShownFeedMode = feedModesWithShownTabs.first {
                feedMode = firstShownFeedMode
            }
        }
        .onChange(of: pendingCommentsOpening.flatMap { feedStore.post(withID: $0.postID) }?.id) {
            guard let pendingCommentsOpening, let post = feedStore.post(withID: pendingCommentsOpening.postID) else { return }
            self.pendingCommentsOpening = nil
            commentsSheetRequest = CommentsSheetRequest(post: post, focusedCommentID: pendingCommentsOpening.focusedCommentID)
        }
        .onChange(of: ShipTokPushNotifications.shared.openedNotification?.id, initial: true) {
            guard let openedNotification = ShipTokPushNotifications.shared.takeOpenedNotification() else { return }
            openPost(postID: openedNotification.postID, opensComments: openedNotification.opensComments, focusedCommentID: openedNotification.commentID)
        }
        .onChange(of: scenePhase) { _, newScenePhase in
            switch newScenePhase {
            case .active:
                if selectedTab == .feed {
                    Task { await refreshShownFeedContext() }
                }
                Task { await inboxStore.refresh() }
                Task { await userSettingsStore.refresh() }
            case .background:
                postVibeAwaitingFeedback()
                vibeOutbox.postAllQueuedVibesBeforeSuspension()
                feedStore.saveFeeds()
            default:
                break
            }
        }
        .confirmingHide(of: $contentAwaitingHideConfirmation) { hiddenContent in
            viewer.hiddenPeopleStore.hide(hiddenContent.poster)
            viewer.analytics.capture(.personHidden(hiddenContent, control: .feedRail))
        }
        .environment(\.shipTokAnalytics, viewer.analytics)
        .environment(\.feedViewerMediaCache, viewer.mediaCache)
        .environment(playbackRateChoice)
    }

    @ViewBuilder
    private var newerPostsButton: some View {
        if let shownFeedMode {
            newerPostsButton(in: shownFeedMode)
        }
    }

    @ViewBuilder
    private func newerPostsButton(in feedMode: FeedMode) -> some View {
        let visiblePosts = feedStore.visiblePosts(in: feedMode)
        let unseenNewerPostIDs = feedStore.loadedFeed(feedMode).unseenNewerPostIDs
        let unseenNewerPageIndexes = visiblePosts.indices.filter { unseenNewerPostIDs.contains(visiblePosts[$0].id) }
        if let firstUnseenNewerPageIndex = unseenNewerPageIndexes.first, firstUnseenNewerPageIndex < currentPageIndex {
            let unseenNewerPostCount = unseenNewerPageIndexes.count
            let isOne = unseenNewerPostCount == 1
            let unseenNewerPostsDescription = switch feedMode {
            case .open: isOne ? "newly updated open PR" : "newly updated open PRs"
            case .merged: isOne ? "newly merged PR" : "newly merged PRs"
            case .weekly: isOne ? "new weekly video" : "new weekly videos"
            case .features: isOne ? "new feature video" : "new feature videos"
            }
            Button {
                withAnimation(.spring(duration: 0.35)) { currentPageIndex = firstUnseenNewerPageIndex }
            } label: {
                Label("\(unseenNewerPostCount) new", systemImage: "arrow.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(RevylBrandColor.brandGradient))
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .fixedSize()
            .accessibilityLabel("\(unseenNewerPostCount) \(unseenNewerPostsDescription) above")
            .transition(.scale.combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var selectedTabPage: some View {
        switch selectedTab {
        case .feed:
            EmptyView()
        case .inbox:
            DeveloperInboxView(
                store: inboxStore,
                onOpenItem: { inboxItem in
                    openPost(postID: inboxItem.post.postID, opensComments: inboxItem.kind != .reaction, focusedCommentID: inboxItem.commentID)
                },
                onHide: { hiddenContent in
                    viewer.hiddenPeopleStore.hide(hiddenContent.poster)
                    viewer.analytics.capture(.personHidden(hiddenContent, control: .inboxRow))
                },
                onShowFeed: onShowFeedFromTabPage
            )
        case .settings:
            SettingsView(
                viewer: viewer,
                userSettingsStore: userSettingsStore,
                chosenRepository: repository,
                signInSession: signInSession,
                onChooseRepository: { chosenRepository in
                    postVibeAwaitingFeedback()
                    vibeOutbox.postAllQueuedVibesBeforeSuspension()
                    await feedStore.saveFeeds()?.value
                    onChooseRepository(chosenRepository)
                },
                onShowFeed: onShowFeedFromTabPage
            )
        }
    }

    private var onShowFeedFromTabPage: (() -> Void)? {
        isTabBarShown ? nil : { selectedTab = .feed }
    }

    // The mode tabs in the top row, centered over the card wherever they fit, and inbox and settings where FeedPageLayout puts them when no tab bar shows
    // (AGENTS.md, "Card Layout" and "Feed Modes").
    private func feedChrome(pageLayout: FeedPageLayout) -> some View {
        let feedModeSwitchArea = pageLayout.feedModeSwitchArea
        return ZStack(alignment: .topLeading) {
            FeedModeSwitch(
                feedMode: Binding(get: { feedMode }, set: { feedMode = $0 }),
                feedModesWithShownTabs: userSettingsStore.feedModesWithShownTabs,
                shownDeckSource: feedContext == .openDeck ? feedStore.openDeckSource : nil,
                onCloseDeck: closeDeck,
                preferredTabsCenterX: pageLayout.card.midX - feedModeSwitchArea.minX
            )
            .frame(width: feedModeSwitchArea.width, height: feedModeSwitchArea.height)
            .offset(x: feedModeSwitchArea.minX, y: feedModeSwitchArea.minY)
            switch pageLayout.navigationPlacement {
            case .floatingTabBar:
                EmptyView()
            case .topCornerButtons(let row):
                feedNavigationButtons(style: .topCornerGlyphs)
                    .frame(width: row.width, height: row.height, alignment: .trailing)
                    .offset(x: row.minX, y: row.minY)
            case .statusStripButtons(let column):
                feedNavigationButtons(style: .statusStripGlyphs)
                    .frame(width: column.width, height: column.height, alignment: .top)
                    .offset(x: column.minX, y: column.minY)
            }
        }
        .opacity(vibeAwaitingFeedback == nil ? 1 : 0)
    }

    private func feedNavigationButtons(style: FeedNavigationButtons.Style) -> some View {
        FeedNavigationButtons(style: style, unseenInboxItemCount: inboxStore.unreadCount, onSelectTab: { selectedTab = $0 })
    }

    @ViewBuilder
    private func feedContent(pageSize: CGSize, pageLayout: FeedPageLayout) -> some View {
        switch feedContext {
        case .feed(let feedMode):
            modeFeedContent(in: feedMode, pageSize: pageSize, pageLayout: pageLayout)
        case .openDeck:
            openDeckFeedContent(pageSize: pageSize, pageLayout: pageLayout)
        }
    }

    // Until a card shows, the feed keeps reading older pages, so it's loading until Revyl has no more (AGENTS.md, "Feed Order").
    @ViewBuilder
    private func modeFeedContent(in feedMode: FeedMode, pageSize: CGSize, pageLayout: FeedPageLayout) -> some View {
        let loadedFeed = feedStore.loadedFeed(feedMode)
        if !feedStore.visiblePosts(in: feedMode).isEmpty {
            feedDeck(deckSize: pageSize, pageLayout: pageLayout)
        } else if let loadFailureMessage = loadedFeed.loadFailureMessage {
            let failureTitle = switch feedMode {
            case .open: "Couldn't load open PRs"
            case .merged: "Couldn't load merged PRs"
            case .weekly: "Couldn't load the weekly videos"
            case .features: "Couldn't load the feature videos"
            }
            RevylContentUnavailableView(
                systemImageName: "exclamationmark.triangle",
                title: Text(failureTitle),
                message: Text(verbatim: loadFailureMessage),
                actionTitle: Text("Try again"),
                action: { Task { await feedStore.loadOlderPosts(in: feedMode) } }
            )
        } else if !loadedFeed.hasLoadedEveryPost {
            let loadingMessage = switch feedMode {
            case .open: "Finding open PRs with \(showsOnlyPostsWithVideos ? "videos" : "videos and screenshots")…"
            case .merged: "Finding merged PRs with \(showsOnlyPostsWithVideos ? "videos" : "videos and screenshots")…"
            case .weekly: "Finding the weekly videos…"
            case .features: "Finding the feature videos…"
            }
            FeedLoadingView(message: loadingMessage)
        } else {
            emptyFeedView(of: feedMode)
        }
    }

    @ViewBuilder
    private func emptyFeedView(of feedMode: FeedMode) -> some View {
        let shownMediaDescription = showsOnlyPostsWithVideos ? "lead with a video" : "carry a video, screenshot or GIF"
        let videosOnlyHint = showsOnlyPostsWithVideos ? " Turn off Videos only in Settings to see ones with only screenshots or GIFs." : ""
        switch feedMode {
        case .open:
            RevylContentUnavailableView(
                systemImageName: "film.stack",
                title: Text(showsOnlyPostsWithVideos ? "No open PRs with videos" : "No open PRs with media"),
                message: Text("ShipTok shows open pull requests in \(repository.fullName), drafts included, that \(shownMediaDescription). None do right now.\(videosOnlyHint)")
            )
        case .merged:
            RevylContentUnavailableView(
                systemImageName: "film.stack",
                title: Text(showsOnlyPostsWithVideos ? "No merged PRs with videos yet" : "No merged PRs with media yet"),
                message: Text("ShipTok shows pull requests merged into \(repository.fullName) that \(shownMediaDescription). None do yet.\(videosOnlyHint)")
            )
        case .weekly:
            RevylContentUnavailableView(
                systemImageName: "calendar",
                title: Text("No weekly videos yet"),
                message: Text("Each week's video is a closed issue labeled shiptok-weekly in \(repository.fullName). None is posted yet.")
            )
        case .features:
            RevylContentUnavailableView(
                systemImageName: "sparkles.rectangle.stack",
                title: Text("No feature videos yet"),
                message: Text("Each feature's video is a closed issue labeled shiptok-feature in \(repository.fullName). None is posted yet.")
            )
        }
    }

    @ViewBuilder
    private func openDeckFeedContent(pageSize: CGSize, pageLayout: FeedPageLayout) -> some View {
        let deckFeedMode = feedStore.openDeckSource?.feedMode
        if !feedStore.visibleOpenDeckPosts.isEmpty {
            feedDeck(deckSize: pageSize, pageLayout: pageLayout)
        } else if let openDeckReadFailureMessage = feedStore.openDeckReadFailureMessage {
            let failureTitle = switch deckFeedMode {
            case .weekly: "Couldn't load this week's pull requests"
            case .features: "Couldn't load this feature's pull requests"
            case .open, .merged, nil: "Couldn't load this post"
            }
            RevylContentUnavailableView(
                systemImageName: "exclamationmark.triangle",
                title: Text(failureTitle),
                message: Text(verbatim: openDeckReadFailureMessage),
                actionTitle: Text("Try again"),
                action: { feedStore.retryOpenDeckRead() }
            )
        } else if !feedStore.isOpenDeckRead {
            let loadingMessage = switch deckFeedMode {
            case .weekly: "Loading the week's pull requests…"
            case .features: "Loading the feature's pull requests…"
            case .open, .merged, nil: "Loading the post…"
            }
            FeedLoadingView(message: loadingMessage)
        } else {
            switch deckFeedMode {
            case .weekly:
                RevylContentUnavailableView(
                    systemImageName: "rectangle.stack",
                    title: Text("No pull requests to show for this week"),
                    message: Text("A week's deck leaves out pull requests closed without merging, ones with no video, screenshot or GIF, and ones by people you hid."),
                    actionTitle: Text("Back to weekly videos"),
                    action: closeDeck
                )
            case .features:
                RevylContentUnavailableView(
                    systemImageName: "rectangle.stack",
                    title: Text("No pull requests to show for this feature"),
                    message: Text("A feature's deck leaves out pull requests closed without merging and ones by people you hid."),
                    actionTitle: Text("Back to feature videos"),
                    action: closeDeck
                )
            case .open, .merged, nil:
                RevylContentUnavailableView(
                    systemImageName: "eye.slash",
                    title: Text("This post is hidden"),
                    message: Text("It's by someone you hid. Unhide them in Settings to see it."),
                    actionTitle: Text("Back"),
                    action: closeDeck
                )
            }
        }
    }

    private func feedDeck(deckSize: CGSize, pageLayout: FeedPageLayout) -> some View {
        let pages = feedPages
        let currentIndex = clampedPageIndex
        let visiblePageEntries = (max(0, currentIndex - 1)...min(pages.count - 1, currentIndex + 1))
            .map { pageIndex in (pageIndex: pageIndex, page: pages[pageIndex]) }
        return ZStack {
            ForEach(visiblePageEntries, id: \.page.id) { pageEntry in
                let isCurrentPage = pageEntry.pageIndex == currentIndex
                pageView(pageEntry.page, isCurrentPage: isCurrentPage, deckSize: deckSize, pageLayout: pageLayout)
                    .frame(width: deckSize.width, height: deckSize.height)
                    .scaleEffect(isCurrentPage ? cardEntranceScale : 1)
                    .rotationEffect(.degrees(isCurrentPage ? Double(horizontalDragOffset / max(deckSize.width, 1)) * 12 : 0), anchor: .bottom)
                    .offset(
                        x: isCurrentPage ? horizontalDragOffset : 0,
                        y: CGFloat(pageEntry.pageIndex - currentIndex) * deckSize.height * nextPageOffsetSign + verticalDragOffset
                    )
            }
        }
        .frame(width: deckSize.width, height: deckSize.height)
        .clipped()
        .overlay(alignment: .top) {
            pullToRefreshIndicator(deckSize: deckSize)
                .padding(.top, pageLayout.topRow.maxY)
        }
        .contentShape(Rectangle())
        .gesture(deckDragGesture(deckSize: deckSize, pageLayout: pageLayout))
        .simultaneousGesture(heroPinchGesture(pageLayout: pageLayout))
        .onChange(of: pageLayout) { previousPageLayout, resizedPageLayout in
            guard let previousHeroZoomViewport = heroZoomViewport(pageLayout: previousPageLayout),
                  let resizedHeroZoomViewport = heroZoomViewport(pageLayout: resizedPageLayout)
            else { return }
            heroZoom = heroZoom.refitted(
                from: previousHeroZoomViewport.mediaFrame,
                in: previousHeroZoomViewport.frameInCard.size,
                to: resizedHeroZoomViewport.mediaFrame,
                in: resizedHeroZoomViewport.frameInCard.size
            )
        }
    }

    @ViewBuilder
    private func pullToRefreshIndicator(deckSize: CGSize) -> some View {
        let pullProgress = clampedPageIndex == 0
            ? max(0, verticalDragOffset * nextPageOffsetSign) / max(deckSize.height * Self.pullToRefreshThresholdFraction / 3, 1)
            : 0
        if isPullToRefreshRunning || pullProgress > 0 {
            Group {
                if isPullToRefreshRunning {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 15, weight: .bold))
                        .rotationEffect(.degrees(pullProgress >= 1 ? 180 : 0))
                        .animation(.spring(duration: 0.2), value: pullProgress >= 1)
                }
            }
            .foregroundStyle(RevylBrandColor.textPrimary)
            .frame(width: 36, height: 36)
            .background(Circle().fill(RevylBrandColor.surfaceFloating))
            .overlay(Circle().stroke(RevylBrandColor.border, lineWidth: 1))
            .opacity(isPullToRefreshRunning ? 1 : min(1, pullProgress))
            .padding(.top, 10)
            .accessibilityLabel("Refreshing")
        }
    }

    @ViewBuilder
    private func pageView(_ page: FeedPage, isCurrentPage: Bool, deckSize: CGSize, pageLayout: FeedPageLayout) -> some View {
        switch page {
        case .post(let post):
            feedCard(post, isCurrentPage: isCurrentPage, deckSize: deckSize, pageLayout: pageLayout)
        case .feedEnd:
            feedEndPage
        }
    }

    private func feedCard(_ post: ShipTokPost, isCurrentPage: Bool, deckSize: CGSize, pageLayout: FeedPageLayout) -> FeedCardView {
        let vibeTarget = VibeTarget(post: post)
        let analyticsSubject = vibeTarget.analyticsSubject
        let heroMediaItem = feedStore.heroMediaItem(of: post)
        let postID = post.id
        return FeedCardView(
            post: post,
            heroMediaItem: heroMediaItem,
            isHeroMediaUnloadable: heroMediaItem.map { feedStore.unloadableMediaItemIDs.contains($0.id) } ?? false,
            analyticsSubject: analyticsSubject,
            pageLayout: pageLayout,
            videoScrubFraction: isCurrentPage ? videoScrubFraction : nil,
            heroZoom: isCurrentPage ? heroZoom : .normalFit,
            vibeFeedbackComposerHeight: vibeFeedbackComposerHeight,
            isBehindVibeFeedbackComposer: vibeAwaitingFeedback != nil,
            isKeyboardShown: isKeyboardShown,
            vibes: feedCardVibes(
                tally: post.feedback.vibeTally(showingPendingVibe: vibeOutbox.pendingVibe(forPostID: postID)),
                target: vibeTarget,
                deckWidth: deckSize.width
            ),
            moderation: feedCardModeration(of: post),
            deckPullRequestCount: post.kind == .pullRequest ? nil : feedStore.postCountOfDeckRead(deckPostID: postID),
            isPlaybackActive: isCurrentPage && scenePhase == .active && !isFeedCovered,
            isOccludedForAnalytics: isHeroOccludedForAnalytics,
            horizontalDragProgress: isCurrentPage ? horizontalDragOffset / max(deckSize.width, 1) : 0,
            likeBurstTrigger: likeBurstTriggers[postID, default: 0],
            onDoubleTap: {
                if heroZoom.isZoomed {
                    withAnimation(MediaZoom.settleAnimation) { heroZoom = .normalFit }
                    return
                }
                showLikeBurst(onPostID: postID)
                viewer.analytics.capture(.likeSelected(analyticsSubject, control: .doubleTap, wasLiked: post.reactions.viewerReactions.contains(.heart)))
                Task { await feedStore.likeUnlessAlreadyLiked(postID: postID) }
            },
            onToggleLike: {
                likeHapticTrigger += 1
                viewer.analytics.capture(.likeSelected(analyticsSubject, control: .feedRail, wasLiked: post.reactions.viewerReactions.contains(.heart)))
                Task { await feedStore.toggleReaction(.heart, postID: postID) }
            },
            onToggleReaction: { reaction in Task { await feedStore.toggleReaction(reaction, postID: postID) } },
            onOpenComments: {
                commentsSheetRequest = CommentsSheetRequest(post: feedStore.post(withID: postID) ?? post, focusedCommentID: nil)
                viewer.analytics.capture(.commentsOpened(analyticsSubject))
            },
            onOpenDeck: {
                switch post.kind {
                case .pullRequest: mediaDeckPostID = PresentedPostID(id: postID)
                case .weeklyEdition, .feature: openDeck(.pullRequestsOf(post))
                }
            },
            onTapCaption: {
                switch post.kind {
                case .pullRequest: detailSheetPostID = PresentedPostID(id: postID)
                case .weeklyEdition, .feature: openDeck(.pullRequestsOf(post))
                }
            },
            onHeroMediaLoadFailure: { failedHeroMediaItem in
                feedStore.recoverFromMediaLoadFailure(of: failedHeroMediaItem, onPostID: postID)
            },
            onHeroMediaSizeRead: { heroMediaItem, heroMediaSize in
                if heroMediaSizes[heroMediaItem.id] != heroMediaSize {
                    heroMediaSizes[heroMediaItem.id] = heroMediaSize
                }
            },
            onTapWhileBehindVibeFeedbackComposer: dismissKeyboard
        )
    }

    private func feedCardVibes(tally: VibeTally, target: VibeTarget, deckWidth: CGFloat) -> FeedCardVibes {
        FeedCardVibes(
            tally: tally,
            onCast: { vibe in
                guard !isPageTransitionRunning else { return }
                flingCard(of: target, castingVibe: vibe, deckWidth: deckWidth)
            },
            onRemoveViewerVibe: { removeViewerVibe(on: target) }
        )
    }

    // A post is GitHub's, so its report opens GitHub's own form (AGENTS.md, "Report And Hide").
    private func feedCardModeration(of post: ShipTokPost) -> ContentModeration {
        ContentModeration(
            reportableContents: ReportableContent(post: post).map { [$0] } ?? [],
            onReport: { reportedContent in
                guard let githubReportURL = reportedContent.githubReportURL else { return }
                viewer.analytics.capture(.contentReportOpened(reportedContent, control: .feedRail))
                openURL(githubReportURL)
            },
            onHide: { contentToHide in contentAwaitingHideConfirmation = contentToHide }
        )
    }

    @ViewBuilder
    private var feedEndPage: some View {
        switch feedContext {
        case .feed(let feedMode):
            let loadedFeed = feedStore.loadedFeed(feedMode)
            FeedEndPageView(
                feedMode: feedMode,
                repositoryFullName: repository.fullName,
                showsOnlyPostsWithVideos: showsOnlyPostsWithVideos,
                loadFailureMessage: loadedFeed.loadFailureMessage,
                hasLoadedEveryPost: loadedFeed.hasLoadedEveryPost,
                onRetry: { Task { await feedStore.loadOlderPosts(in: feedMode) } }
            )
        case .openDeck:
            Group {
                switch feedStore.openDeckSource {
                case .pullRequestsOf(let deckPost) where deckPost.kind == .weeklyEdition:
                    RevylContentUnavailableView(
                        systemImageName: "checkmark.seal.fill",
                        title: Text("That's the week of \(deckPost.weekDatesText ?? "#\(deckPost.githubIssueNumber)")"),
                        message: Text("You've seen every pull request in this week's video."),
                        actionTitle: Text("Back to weekly videos"),
                        action: closeDeck
                    )
                case .pullRequestsOf(let deckPost):
                    RevylContentUnavailableView(
                        systemImageName: "checkmark.seal.fill",
                        title: Text("That's “\(deckPost.title)”"),
                        message: Text("You've seen every pull request behind this feature."),
                        actionTitle: Text("Back to feature videos"),
                        action: closeDeck
                    )
                case .post, nil:
                    RevylContentUnavailableView(
                        systemImageName: "checkmark.seal.fill",
                        title: Text("That's this post"),
                        message: Text("Go back for the rest of the feed."),
                        actionTitle: Text("Back to the feed"),
                        action: closeDeck
                    )
                }
            }
            .background(RevylBrandColor.canvas)
        }
    }

    private var toastStack: some View {
        VStack(spacing: 8) {
            if let failedVibe = vibeOutbox.failedVibe {
                FeedToastView(
                    message: "Couldn't post \(failedVibe.vibe.displayName.lowercased()) on \(failedVibe.target.reference)",
                    tint: RevylBrandColor.danger,
                    actionTitle: "Retry",
                    action: { vibeOutbox.retryFailedVibe() },
                    onDismiss: { vibeOutbox.dismissFailedVibe() }
                )
            }
            if let undoableVibe = vibeOutbox.undoableVibe {
                FeedToastView(
                    message: "\(undoableVibe.vibe.displayName) on “\(undoableVibe.target.title)”",
                    tint: undoableVibe.vibe.tintColor,
                    actionTitle: "Undo",
                    action: { undoVibe(undoableVibe.id) }
                )
                .id(undoableVibe.id)
            }
            if let transientErrorMessage = feedStore.transientErrorMessage {
                FeedToastView(
                    message: transientErrorMessage,
                    tint: RevylBrandColor.warning,
                    onDismiss: { feedStore.transientErrorMessage = nil }
                )
            }
        }
        .frame(maxWidth: Self.toastMaximumWidth)
        .padding(.leading, 16)
        .padding(.trailing, Self.cardRailClearanceWidth)
        .padding(.bottom, 10)
        .animation(.snappy, value: vibeOutbox.undoableVibe?.id)
        .animation(.snappy, value: vibeOutbox.failedVibe?.id)
        .animation(.snappy, value: feedStore.transientErrorMessage)
    }

    private var vibeFeedbackComposer: some View {
        ZStack {
            if let vibeAwaitingFeedback {
                VibeFeedbackComposer(
                    vibe: vibeAwaitingFeedback.vibe,
                    targetTitle: vibeAwaitingFeedback.target.title,
                    feedbackText: feedbackTextBinding(forVibeAwaitingFeedbackID: vibeAwaitingFeedback.id),
                    onSend: postVibeAwaitingFeedback,
                    onSkip: {
                        self.vibeAwaitingFeedback?.feedbackText = ""
                        postVibeAwaitingFeedback()
                    },
                    onCancel: cancelVibeAwaitingFeedback
                )
                .id(vibeAwaitingFeedback.id)
                .frame(maxWidth: Self.vibeFeedbackComposerMaximumWidth)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: vibeAwaitingFeedback?.id)
    }

    // A composer that is leaving can still write late typing or dictation; only the current vibe's composer may change its text.
    private func feedbackTextBinding(forVibeAwaitingFeedbackID vibeAwaitingFeedbackID: UUID) -> Binding<String> {
        Binding(
            get: { vibeAwaitingFeedback?.id == vibeAwaitingFeedbackID ? vibeAwaitingFeedback?.feedbackText ?? "" : "" },
            set: { newFeedbackText in
                guard vibeAwaitingFeedback?.id == vibeAwaitingFeedbackID else { return }
                vibeAwaitingFeedback?.feedbackText = newFeedbackText
            }
        )
    }
    // A sideways drag from the strip around a video's progress line scrubs it; from anywhere else it casts a vibe (AGENTS.md, "Swipe Gestures").
    private func deckDragGesture(deckSize: CGSize, pageLayout: FeedPageLayout) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { dragValue in
                guard !isPageTransitionRunning else { return }
                if heroPinch != nil {
                    activeDeckDrag = .heroPinch
                }
                if activeDeckDrag == nil {
                    let isSideways = abs(dragValue.translation.width) > abs(dragValue.translation.height)
                    if isSideways, isHeroLoadableVideo(of: feedPages[clampedPageIndex]), pageLayout.videoScrubZone.contains(dragValue.startLocation) {
                        activeDeckDrag = .videoScrub
                    } else if heroZoom.isZoomed {
                        activeDeckDrag = .heroPan(MediaZoomPan(startZoom: heroZoom, startTranslation: dragValue.translation))
                    } else if isSideways {
                        activeDeckDrag = .vibeSwipe
                    } else {
                        activeDeckDrag = .pageSwipe
                    }
                }
                switch activeDeckDrag {
                case .vibeSwipe:
                    guard feedPages[clampedPageIndex].vibeTarget != nil else { return }
                    horizontalDragOffset = dragValue.translation.width
                case .pageSwipe:
                    verticalDragOffset = resistedVerticalDragOffset(dragValue.translation.height)
                case .videoScrub:
                    videoScrubFraction = pageLayout.videoScrubFraction(atX: dragValue.location.x)
                case .heroPan(let heroPan):
                    guard let zoomViewport = heroZoomViewport(pageLayout: pageLayout) else { return }
                    heroZoom = heroPan.startZoom.panned(
                        by: heroPan.translation(from: dragValue.translation),
                        mediaFrame: zoomViewport.mediaFrame,
                        in: zoomViewport.frameInCard.size
                    )
                case .heroPinch, nil:
                    break
                }
            }
            .onEnded { dragValue in
                let endedDeckDrag = activeDeckDrag
                activeDeckDrag = nil
                videoScrubFraction = nil
                guard !isPageTransitionRunning else { return }
                switch endedDeckDrag {
                case .pageSwipe:
                    finishVerticalDrag(dragValue, deckSize: deckSize)
                case .vibeSwipe:
                    finishHorizontalDrag(dragValue, deckSize: deckSize)
                case .heroPan(let heroPan):
                    guard let zoomViewport = heroZoomViewport(pageLayout: pageLayout) else { return }
                    withAnimation(MediaZoom.settleAnimation) {
                        heroZoom = heroPan.startZoom.panEnded(
                            by: heroPan.translation(from: dragValue.predictedEndTranslation),
                            mediaFrame: zoomViewport.mediaFrame,
                            in: zoomViewport.frameInCard.size
                        )
                    }
                case .videoScrub, .heroPinch, nil:
                    break
                }
            }
    }

    // A pinch on the card zooms its hero around where the fingers met, and whatever the feed's drag had started gives way to it (AGENTS.md, "Swipe Gestures").
    private func heroPinchGesture(pageLayout: FeedPageLayout) -> some Gesture {
        MagnifyGesture()
            .onChanged { magnifyValue in
                guard !isPageTransitionRunning, let zoomViewport = heroZoomViewport(pageLayout: pageLayout) else { return }
                let activeHeroPinch = heroPinch ?? MediaZoom.Pinch(
                    startZoom: heroZoom,
                    anchor: CGPoint(
                        x: magnifyValue.startLocation.x - pageLayout.card.minX - zoomViewport.frameInCard.minX,
                        y: magnifyValue.startLocation.y - pageLayout.card.minY - zoomViewport.frameInCard.minY
                    )
                )
                if heroPinch == nil, activeDeckDrag != nil {
                    activeDeckDrag = .heroPinch
                    videoScrubFraction = nil
                    withAnimation(.spring(duration: 0.3)) {
                        verticalDragOffset = 0
                        horizontalDragOffset = 0
                    }
                }
                heroPinch = activeHeroPinch
                heroZoom = activeHeroPinch.startZoom.pinched(by: magnifyValue.magnification, around: activeHeroPinch.anchor, in: zoomViewport.frameInCard.size)
            }
            .onEnded { magnifyValue in
                guard let endedHeroPinch = heroPinch else { return }
                heroPinch = nil
                guard let zoomViewport = heroZoomViewport(pageLayout: pageLayout) else {
                    heroZoom = .normalFit
                    return
                }
                let settledHeroZoom = endedHeroPinch.startZoom.pinchEnded(
                    by: magnifyValue.magnification,
                    around: endedHeroPinch.anchor,
                    mediaFrame: zoomViewport.mediaFrame,
                    in: zoomViewport.frameInCard.size
                )
                withAnimation(MediaZoom.settleAnimation) { heroZoom = settledHeroZoom }
                if !endedHeroPinch.startZoom.isZoomed, settledHeroZoom.isZoomed {
                    captureHeroZoomIn()
                }
            }
    }

    // Where the hero of the card in focus zooms its media, once it has loaded far enough to know its size; a pinch zooms only that.
    private func heroZoomViewport(pageLayout: FeedPageLayout) -> PostMediaView.HeroZoomViewport? {
        guard let heroMediaItem = loadableHeroMediaItem(of: feedPages[clampedPageIndex]),
              let heroMediaSize = heroMediaSizes[heroMediaItem.id]
        else { return nil }
        return PostMediaView.heroZoomViewport(mediaSize: heroMediaSize, cardSize: pageLayout.card.size, wholeMediaInsets: pageLayout.wholeHeroMediaInsets)
    }

    private func captureHeroZoomIn() {
        let currentPage = feedPages[clampedPageIndex]
        guard let heroMediaItem = loadableHeroMediaItem(of: currentPage), let analyticsSubject = currentPage.vibeTarget?.analyticsSubject else { return }
        let mediaItems: [ShipTokPostMedia] = switch currentPage {
        case .post(let post): post.media
        case .feedEnd: []
        }
        viewer.analytics.capture(.mediaZoomed(ShipTokAnalyticsMedia(
            subject: analyticsSubject,
            surface: .feed,
            mediaItem: heroMediaItem,
            mediaPosition: mediaItems.firstIndex { $0.id == heroMediaItem.id } ?? 0
        )))
    }

    private func loadableHeroMediaItem(of page: FeedPage) -> ShipTokPostMedia? {
        guard case .post(let post) = page, let heroMediaItem = feedStore.heroMediaItem(of: post),
              !feedStore.unloadableMediaItemIDs.contains(heroMediaItem.id)
        else { return nil }
        return heroMediaItem
    }

    private func isHeroLoadableVideo(of page: FeedPage) -> Bool {
        loadableHeroMediaItem(of: page)?.kind == .video
    }

    // The Duo's status strip, an expanded island included, is an occlusion region from iOS 27.1, and no earlier device has a strip beside the card.
    private static func systemOcclusionFrames(in screenGeometry: GeometryProxy) -> [CGRect] {
        guard #available(iOS 27.1, *) else { return [] }
        return screenGeometry.reservedRegions(kind: .occlusion).map(\.frame)
    }

    private func pageStep(forVerticalTranslation verticalTranslation: CGFloat) -> Int {
        switch FeedSwipeGestureMapping.action(for: verticalTranslation < 0 ? .up : .down) {
        case .showNextPullRequest: 1
        case .showPreviousPullRequest: -1
        case .castGoodVibes, .castBadVibes: 0
        }
    }

    private func resistedVerticalDragOffset(_ verticalTranslation: CGFloat) -> CGFloat {
        let verticalPageStep = pageStep(forVerticalTranslation: verticalTranslation)
        let targetPageIndex = clampedPageIndex + verticalPageStep
        return verticalPageStep != 0 && feedPages.indices.contains(targetPageIndex) ? verticalTranslation : verticalTranslation / 3
    }

    private func finishVerticalDrag(_ dragValue: DragGesture.Value, deckSize: CGSize) {
        let verticalPageStep = pageStep(forVerticalTranslation: dragValue.translation.height)
        let targetPageIndex = clampedPageIndex + verticalPageStep
        let passedThreshold = abs(dragValue.translation.height) > deckSize.height * Self.pullToRefreshThresholdFraction
            || abs(dragValue.predictedEndTranslation.height) > deckSize.height * 0.5
        guard verticalPageStep != 0, passedThreshold, feedPages.indices.contains(targetPageIndex) else {
            if verticalPageStep == -1, targetPageIndex < 0, abs(dragValue.translation.height) > deckSize.height * Self.pullToRefreshThresholdFraction {
                pullToRefreshHapticTrigger += 1
                refreshFromPull()
            }
            withAnimation(.spring(duration: 0.3)) { verticalDragOffset = 0 }
            return
        }
        // A refresh can add or remove cards above the viewer while the page slides, so the swipe lands on the page it showed, wherever that page now sits.
        let targetPageID = feedPages[targetPageIndex].id
        isPageTransitionRunning = true
        withAnimation(.spring(duration: 0.32, bounce: 0.08), completionCriteria: .logicallyComplete) {
            verticalDragOffset = -CGFloat(verticalPageStep) * deckSize.height * nextPageOffsetSign
        } completion: {
            currentPageIndex = feedPages.firstIndex { $0.id == targetPageID } ?? min(targetPageIndex, feedPages.count - 1)
            verticalDragOffset = 0
            isPageTransitionRunning = false
            pageChangeHapticTrigger += 1
        }
    }

    private func finishHorizontalDrag(_ dragValue: DragGesture.Value, deckSize: CGSize) {
        let swipeDirection: FeedSwipeDirection = dragValue.translation.width > 0 ? .right : .left
        let passedThreshold = abs(dragValue.translation.width) > deckSize.width * 0.28
            || abs(dragValue.predictedEndTranslation.width) > deckSize.width * 0.7
        guard let vibeTarget = feedPages[clampedPageIndex].vibeTarget,
              passedThreshold,
              let swipedVibe = FeedSwipeGestureMapping.action(for: swipeDirection).castVibe
        else {
            withAnimation(.spring(duration: 0.3)) { horizontalDragOffset = 0 }
            return
        }
        flingCard(of: vibeTarget, castingVibe: swipedVibe, deckWidth: deckSize.width)
    }

    private func refreshFromPull() {
        switch feedContext {
        case .feed(let feedMode): Task { await feedStore.refreshFromPull(in: feedMode) }
        case .openDeck: Task { await feedStore.refreshOpenDeckFromPull() }
        }
    }

    private func focusPage(at pageIndex: Int) {
        switch onScreenFeedContext {
        case nil:
            break
        case .feed(let feedMode):
            focusFeedPage(in: feedMode, at: pageIndex)
        case .openDeck:
            let visibleOpenDeckPosts = feedStore.visibleOpenDeckPosts
            feedStore.focusOpenDeckPage(showingPostID: visibleOpenDeckPosts.indices.contains(pageIndex) ? visibleOpenDeckPosts[pageIndex].id : nil)
        }
    }

    private func focusFeedPage(in feedMode: FeedMode, at pageIndex: Int) {
        let visiblePosts = feedStore.visiblePosts(in: feedMode)
        feedStore.focusFeedPage(in: feedMode, showingPostID: visiblePosts.indices.contains(pageIndex) ? visiblePosts[pageIndex].id : nil)
    }

    // An iOS app shows the newest data it has, so the shown mode reads Revyl again as soon as it shows and every few seconds while it stays (AGENTS.md, "Feed Order").
    private func refreshShownFeedContextWhileShown() async {
        while !Task.isCancelled {
            await refreshShownFeedContext()
            do {
                try await Task.sleep(for: .seconds(Self.liveRefreshIntervalSeconds))
            } catch {
                return
            }
        }
    }

    private func refreshShownFeedContext() async {
        switch feedContext {
        case .feed(let feedMode): await feedStore.refreshNewestData(in: feedMode)
        case .openDeck: await feedStore.refreshOpenDeck()
        }
    }

    // The store holds one deck, so opening a feature's deck closes an open week's and the other way round, and the mode behind the closed one shows its list (AGENTS.md, "Feed Modes").
    private func openDeck(_ deckSource: PostDeckSource) {
        openDeckPageIndex = 0
        feedStore.openDeck(deckSource)
    }

    private func closeDeck() {
        pendingCommentsOpening = nil
        withAnimation(.spring(duration: 0.3)) { feedStore.closeDeck() }
    }

    // A vibe from VoiceOver's actions leaves the same way as a swipe, toward that vibe's swipe direction, so both ways read as one gesture.
    private func flingCard(of vibeTarget: VibeTarget, castingVibe vibe: ShipTokVibe, deckWidth: CGFloat) {
        isPageTransitionRunning = true
        let selectionID = UUID()
        viewer.analytics.capture(.vibeSelected(vibeTarget.analyticsSubject,
                                                 selectionID: selectionID, vibe: vibe))
        let vibeSwipeAction: FeedSwipeAction = switch vibe {
        case .good: .castGoodVibes
        case .bad: .castBadVibes
        }
        let flingDistance = deckWidth * 1.4 * (FeedSwipeGestureMapping.direction(for: vibeSwipeAction) == .right ? 1 : -1)
        withAnimation(.easeIn(duration: 0.2), completionCriteria: .logicallyComplete) {
            horizontalDragOffset = flingDistance
        } completion: {
            switch vibe {
            case .good: goodVibesHapticTrigger += 1
            case .bad: badVibesHapticTrigger += 1
            }
            castVibe(vibe, on: vibeTarget, selectionID: selectionID)
            showNextPageAfterVibe()
        }
    }

    // The feedback box never blocks the swipe (AGENTS.md, "Vibes").
    private func castVibe(_ vibe: ShipTokVibe, on vibeTarget: VibeTarget, selectionID: UUID) {
        postVibeAwaitingFeedback()
        if userSettingsStore.showsFeedbackBox(for: vibe) {
            vibeAwaitingFeedback = VibeAwaitingFeedback(id: selectionID, target: vibeTarget, vibe: vibe)
        } else {
            vibeOutbox.enqueue(VibeOutbox.QueuedVibe(id: selectionID, target: vibeTarget, vibe: vibe, feedbackText: ""))
        }
    }

    private func postVibeAwaitingFeedback() {
        guard let vibeAwaitingFeedback else { return }
        self.vibeAwaitingFeedback = nil
        vibeOutbox.enqueue(VibeOutbox.QueuedVibe(
            id: vibeAwaitingFeedback.id,
            target: vibeAwaitingFeedback.target,
            vibe: vibeAwaitingFeedback.vibe,
            feedbackText: vibeAwaitingFeedback.feedbackText
        ))
    }

    private func cancelVibeAwaitingFeedback() {
        guard let cancelledVibe = vibeAwaitingFeedback else { return }
        vibeAwaitingFeedback = nil
        viewer.analytics.capture(.vibeCancelled(cancelledVibe.target.analyticsSubject,
                                                  selectionID: cancelledVibe.id, vibe: cancelledVibe.vibe))
        showPage(withID: cancelledVibe.target.postID)
    }

    private func removeViewerVibe(on vibeTarget: VibeTarget) {
        if vibeAwaitingFeedback?.target.postID == vibeTarget.postID {
            if let pendingVibe = vibeAwaitingFeedback {
                viewer.analytics.capture(.vibeCancelled(vibeTarget.analyticsSubject,
                                                          selectionID: pendingVibe.id, vibe: pendingVibe.vibe))
            }
            vibeAwaitingFeedback = nil
        }
        Task { await vibeOutbox.removeViewerVibe(on: vibeTarget) }
    }

    private func showNextPageAfterVibe() {
        currentPageIndex = min(clampedPageIndex + 1, feedPages.count - 1)
        horizontalDragOffset = 0
        cardEntranceScale = 0.92
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) { cardEntranceScale = 1 }
        isPageTransitionRunning = false
    }

    private func showLikeBurst(onPostID postID: String) {
        likeBurstTriggers[postID, default: 0] += 1
        likeHapticTrigger += 1
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func undoVibe(_ queuedVibeID: UUID) {
        guard let undoneVibe = vibeOutbox.undo(queuedVibeID) else { return }
        showPage(withID: undoneVibe.target.postID)
    }

    // Only a page of the context on screen comes back; a vibe from another mode or deck stays where it was cast.
    private func showPage(withID pageID: String) {
        guard let pageIndex = feedPages.firstIndex(where: { $0.id == pageID }) else { return }
        withAnimation(.spring(duration: 0.35)) { currentPageIndex = pageIndex }
    }

    // The viewer's card keeps its place as cards arrive or leave around it. At the feed's end the viewer stays just past every card they had, so the first older card that loads is the one they see next (AGENTS.md, "Feed Order").
    private func keepPostsPageInPlace(in feedMode: FeedMode, previousPostIDs: [String], currentPostIDs: [String]) {
        let isShowingFeed = onScreenFeedContext == .feed(feedMode)
        let previousPageIndex = pageIndexByFeedMode[feedMode, default: 0]
        defer {
            if isShowingFeed { feedStore.loadOlderPostsIfViewerNearsEnd(in: feedMode) }
        }
        guard previousPostIDs.indices.contains(previousPageIndex) else {
            let previousPostIDSet = Set(previousPostIDs)
            pageIndexByFeedMode[feedMode] = (currentPostIDs.lastIndex { previousPostIDSet.contains($0) } ?? -1) + 1
            if isShowingFeed { focusFeedPage(in: feedMode, at: pageIndexByFeedMode[feedMode, default: 0]) }
            return
        }
        if let movedPageIndex = currentPostIDs.firstIndex(of: previousPostIDs[previousPageIndex]) {
            if movedPageIndex != previousPageIndex {
                pageIndexByFeedMode[feedMode] = movedPageIndex
            }
        } else {
            pageIndexByFeedMode[feedMode] = min(previousPageIndex, currentPostIDs.count)
            if isShowingFeed { focusFeedPage(in: feedMode, at: pageIndexByFeedMode[feedMode, default: 0]) }
        }
    }

    // A post in a feed of a mode whose tab shows opens there; any other, from this repository or another, opens on its own (AGENTS.md, "Inbox").
    private func openPost(postID: String, opensComments: Bool, focusedCommentID: String?) {
        selectedTab = .feed
        if let shownFeedMode = userSettingsStore.feedModesWithShownTabs.first(where: { feedStore.visiblePosts(in: $0).contains { $0.id == postID } }),
           let pageIndex = feedStore.visiblePosts(in: shownFeedMode).firstIndex(where: { $0.id == postID }) {
            if feedStore.openDeckSource?.feedMode == nil || feedStore.openDeckSource?.feedMode == shownFeedMode {
                closeDeck()
            }
            feedMode = shownFeedMode
            pageIndexByFeedMode[shownFeedMode] = pageIndex
        } else {
            openDeck(.post(postID: postID))
        }
        guard opensComments else {
            pendingCommentsOpening = nil
            return
        }
        if let post = feedStore.post(withID: postID) {
            pendingCommentsOpening = nil
            commentsSheetRequest = CommentsSheetRequest(post: post, focusedCommentID: focusedCommentID)
        } else {
            pendingCommentsOpening = PendingCommentsOpening(postID: postID, focusedCommentID: focusedCommentID)
        }
    }
}

private struct MediaDeckCoverContent: View {
    let feedStore: PostFeedStore
    let viewer: SignedInTeammate
    let postID: String
    @State private var contentAwaitingHideConfirmation: ReportableContent?
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    private var visiblePost: ShipTokPost? {
        feedStore.post(withID: postID).flatMap { viewer.hiddenPeopleStore.isHidden($0.githubAuthor) ? nil : $0 }
    }

    var body: some View {
        let post = visiblePost
        PostMediaDeckView(
            mediaItems: post?.media ?? [],
            unloadableMediaItemIDs: feedStore.unloadableMediaItemIDs,
            analyticsSubject: post.map(ShipTokAnalyticsSubject.init(post:)),
            moderation: post.flatMap(ReportableContent.init(post:)).map { reportableContent in
                ContentModeration(
                    reportableContents: [reportableContent],
                    onReport: { reportedContent in
                        guard let githubReportURL = reportedContent.githubReportURL else { return }
                        viewer.analytics.capture(.contentReportOpened(reportedContent, control: .mediaDeck))
                        openURL(githubReportURL)
                    },
                    onHide: { contentToHide in contentAwaitingHideConfirmation = contentToHide }
                )
            },
            onLoadFailure: { failedMediaItem in
                feedStore.recoverFromMediaLoadFailure(of: failedMediaItem, onPostID: postID)
            }
        )
        .confirmingHide(of: $contentAwaitingHideConfirmation) { hiddenContent in
            viewer.hiddenPeopleStore.hide(hiddenContent.poster)
            viewer.analytics.capture(.personHidden(hiddenContent, control: .mediaDeck))
            dismiss()
        }
    }
}

private struct DetailSheetContent: View {
    let feedStore: PostFeedStore
    let vibeOutbox: VibeOutbox
    let viewer: SignedInTeammate
    let postID: String
    @State private var contentAwaitingHideConfirmation: ReportableContent?
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let post = feedStore.post(withID: postID) {
            PullRequestDetailSheet(
                post: post,
                vibeTally: post.feedback.vibeTally(showingPendingVibe: vibeOutbox.pendingVibe(forPostID: post.id)),
                moderation: ContentModeration(
                    reportableContents: ReportableContent(post: post).map { [$0] } ?? [],
                    onReport: { reportedContent in
                        guard let githubReportURL = reportedContent.githubReportURL else { return }
                        viewer.analytics.capture(.contentReportOpened(reportedContent, control: .detailSheet))
                        openURL(githubReportURL)
                    },
                    onHide: { contentToHide in contentAwaitingHideConfirmation = contentToHide }
                ),
                onToggleReaction: { reaction in
                    Task { await feedStore.toggleReaction(reaction, postID: post.id) }
                }
            )
            .confirmingHide(of: $contentAwaitingHideConfirmation) { hiddenContent in
                viewer.hiddenPeopleStore.hide(hiddenContent.poster)
                viewer.analytics.capture(.personHidden(hiddenContent, control: .detailSheet))
                dismiss()
            }
        }
    }
}
