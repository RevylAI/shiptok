import SwiftUI

struct FeedView: View {
    private enum FeedContext: Hashable {
        case pullRequests(PullRequestFeed)
        case weeklyEditions
        case features
        case openDeck
    }

    private enum FeedPage: Identifiable {
        case pullRequest(PullRequest)
        case weeklyEdition(WeeklyEdition)
        case feature(Feature)
        case feedEnd

        var id: String {
            switch self {
            case .pullRequest(let pullRequest): pullRequest.id
            case .weeklyEdition(let weeklyEdition): weeklyEdition.id
            case .feature(let feature): feature.id
            case .feedEnd: "feed-end"
            }
        }

        var vibeTarget: VibeTarget? {
            switch self {
            case .pullRequest(let pullRequest): VibeTarget(pullRequest: pullRequest)
            case .weeklyEdition(let weeklyEdition): VibeTarget(weeklyEdition: weeklyEdition)
            case .feature(let feature): VibeTarget(feature: feature)
            case .feedEnd: nil
            }
        }
    }

    private enum DeckDrag {
        case pageSwipe
        case vibeSwipe
        case videoScrub
    }

    private struct VibeAwaitingFeedback: Identifiable, Equatable {
        let id: UUID
        let target: VibeTarget
        let vibe: PullRequestVibe
        var feedbackText = ""
    }

    private struct PresentedPullRequestID: Identifiable {
        let id: String
    }

    let viewer: FeedViewer
    let signInSession: ShipTokSignInSession
    let onChooseRepository: @MainActor (String) -> Void
    private let githubAPIClient: GitHubAPIClient
    @State private var feedStore: PullRequestFeedStore
    @State private var weeklyEditionsStore: PublishedIssuesStore<WeeklyEdition>
    @State private var featuresStore: PublishedIssuesStore<Feature>
    @State private var vibeOutbox: VibeOutbox
    // A demo visitor has no inbox or saved settings.
    @State private var inboxStore: DeveloperInboxStore?
    @State private var userSettingsStore: UserSettingsStore?
    @State private var demoGitHubConnectionPromptAction: DemoGitHubConnectionPromptAction?
    @AppStorage("feed-mode") private var savedFeedMode: FeedMode = .merged
    @State private var demoVisitFeedMode: FeedMode = .merged
    @State private var demoVisitShowsOnlyPullRequestsWithVideos = true
    @State private var playbackRateChoice: VideoPlaybackRateChoice
    @State private var openDeckSource: PullRequestDeckSource?
    @State private var openPullRequestsPageIndex = 0
    @State private var mergedPullRequestsPageIndex = 0
    @State private var weeklyEditionsPageIndex = 0
    @State private var featuresPageIndex = 0
    @State private var openDeckPageIndex = 0
    @State private var verticalDragOffset: CGFloat = 0
    @State private var horizontalDragOffset: CGFloat = 0
    @State private var activeDeckDrag: DeckDrag?
    @State private var videoScrubFraction: CGFloat?
    @State private var systemOcclusionFrames: [CGRect] = []
    @State private var isPageTransitionRunning = false
    @State private var cardEntranceScale: CGFloat = 1
    @State private var likeBurstTriggers: [String: Int] = [:]
    @State private var vibeAwaitingFeedback: VibeAwaitingFeedback?
    @State private var commentsSheetPullRequest: PullRequest?
    @State private var commentsSheetWeeklyEdition: WeeklyEdition?
    @State private var commentsSheetFeature: Feature?
    @State private var detailSheetPullRequest: PullRequest?
    @State private var mediaDeckPullRequestID: PresentedPullRequestID?
    @State private var postedContentAwaitingHideConfirmation: GitHubPostedContent?
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
    private static let feedModeSwitchInsetInCard = CGSize(width: 16, height: 12)
    private static let feedModeSwitchMinimumGapBelowSafeArea: CGFloat = 6
    private static let newerPullRequestsButtonGapBelowFeedModeSwitch: CGFloat = 8
    private static let connectGitHubButtonGapBeforeNewerPullRequestsButton: CGFloat = 8

    init(
        viewer: FeedViewer,
        repositoryFullName: String,
        signInSession: ShipTokSignInSession,
        onChooseRepository: @escaping @MainActor (String) -> Void,
        onFeedRepositoryLost: @escaping @MainActor (String) -> Void
    ) {
        let githubAPIClient = switch viewer {
        case .teammate(let teammate): GitHubAPIClient(source: .signedInAccount(teammate.accountAPI), repositoryFullName: repositoryFullName)
        case .demoVisitor(let demoVisitor): GitHubAPIClient(source: .demoFeed(demoVisitor.demoFeed), repositoryFullName: repositoryFullName)
        }
        self.viewer = viewer
        self.githubAPIClient = githubAPIClient
        self.signInSession = signInSession
        self.onChooseRepository = onChooseRepository
        let handleRejectedGitHubAccess: @MainActor (GitHubAPIError) -> Void = { githubAPIError in
            if case .feedRepositoryNotVisible = githubAPIError {
                onFeedRepositoryLost(githubAPIError.localizedDescription)
            } else if let teammate = viewer.teammate {
                signInSession.handleRejectedGitHubAccess(githubAPIError, endingSignInID: teammate.signInID)
            }
        }
        let feedStore = PullRequestFeedStore(
            githubAPIClient: githubAPIClient,
            analytics: viewer.analytics,
            viewerGitHubLogin: viewer.githubLogin,
            hiddenPeopleStore: viewer.hiddenPeopleStore,
            feedWork: viewer.feedWork,
            handleRejectedGitHubAccess: handleRejectedGitHubAccess
        )
        let weeklyEditionsStore = PublishedIssuesStore<WeeklyEdition>(
            githubAPIClient: githubAPIClient,
            analytics: viewer.analytics,
            handleRejectedGitHubAccess: handleRejectedGitHubAccess
        )
        _feedStore = State(initialValue: feedStore)
        let featuresStore = PublishedIssuesStore<Feature>(
            githubAPIClient: githubAPIClient,
            analytics: viewer.analytics,
            handleRejectedGitHubAccess: handleRejectedGitHubAccess
        )
        _weeklyEditionsStore = State(initialValue: weeklyEditionsStore)
        _featuresStore = State(initialValue: featuresStore)
        _vibeOutbox = State(initialValue: VibeOutbox(
            githubAPIClient: githubAPIClient,
            analytics: viewer.analytics,
            viewerGitHubLogin: viewer.githubLogin,
            feedStore: feedStore,
            weeklyEditionsStore: weeklyEditionsStore,
            featuresStore: featuresStore,
            handleRejectedGitHubAccess: handleRejectedGitHubAccess
        ))
        _inboxStore = State(initialValue: viewer.teammate.map { teammate in
            DeveloperInboxStore(viewer: teammate.user, githubAPIClient: githubAPIClient, hiddenPeopleStore: teammate.hiddenPeopleStore)
        })
        _userSettingsStore = State(initialValue: viewer.teammate.map { UserSettingsStore(accessTokenVault: $0.accessTokenVault) })
        _playbackRateChoice = State(initialValue: viewer.teammate == nil ? .forDemoVisit() : .savedOnDevice())
    }

    // A demo visit's choices last only as long as the visit (AGENTS.md, "Demo Mode").
    private var feedMode: FeedMode {
        get { viewer.teammate == nil ? demoVisitFeedMode : savedFeedMode }
        nonmutating set {
            if viewer.teammate == nil {
                demoVisitFeedMode = newValue
            } else {
                savedFeedMode = newValue
            }
        }
    }

    private var showsOnlyPullRequestsWithVideos: Bool {
        userSettingsStore?.userSettings.showsOnlyPullRequestsWithVideos ?? demoVisitShowsOnlyPullRequestsWithVideos
    }

    private var feedContext: FeedContext {
        switch feedMode {
        case .open: .pullRequests(.open)
        case .merged: .pullRequests(.merged)
        case .weekly: openDeckSource?.feedMode == .weekly ? .openDeck : .weeklyEditions
        case .features: openDeckSource?.feedMode == .features ? .openDeck : .features
        }
    }

    private var shownPullRequestFeed: PullRequestFeed? {
        guard case .pullRequests(let feed) = onScreenFeedContext else { return nil }
        return feed
    }

    private var onScreenPullRequests: OnScreenPullRequests? {
        switch onScreenFeedContext {
        case .pullRequests(let feed): .feed(feed)
        case .openDeck: .openDeck
        case .weeklyEditions, .features, nil: nil
        }
    }

    // Refreshes, focus and the reads around it run only while the feed is on screen, never under Inbox or Settings (AGENTS.md, "Feed Order").
    private var onScreenFeedContext: FeedContext? {
        selectedTab == .feed ? feedContext : nil
    }

    // What people the viewer hid wrote or posted leaves every page, so page indexes count only what's shown (AGENTS.md, "Report And Hide").
    private var visibleWeeklyEditions: [WeeklyEdition] {
        weeklyEditionsStore.publishedIssues.compactMap { $0.withoutHiddenPeople(viewer.hiddenPeopleStore) }
    }

    private var visibleFeatures: [Feature] {
        featuresStore.publishedIssues.compactMap { $0.withoutHiddenPeople(viewer.hiddenPeopleStore) }
    }

    private var feedPages: [FeedPage] {
        switch feedContext {
        case .pullRequests(let feed): feedStore.visiblePullRequests(in: feed).map(FeedPage.pullRequest) + [.feedEnd]
        case .weeklyEditions: visibleWeeklyEditions.map(FeedPage.weeklyEdition) + [.feedEnd]
        case .features: visibleFeatures.map(FeedPage.feature) + [.feedEnd]
        case .openDeck: feedStore.visibleOpenDeckPullRequests.map(FeedPage.pullRequest) + [.feedEnd]
        }
    }

    // Each context keeps its own place, so switching modes or closing a deck returns to the card the viewer left.
    private var currentPageIndex: Int {
        get {
            switch feedContext {
            case .pullRequests(let feed): pageIndex(in: feed)
            case .weeklyEditions: weeklyEditionsPageIndex
            case .features: featuresPageIndex
            case .openDeck: openDeckPageIndex
            }
        }
        nonmutating set {
            switch feedContext {
            case .pullRequests(let feed): setPageIndex(newValue, in: feed)
            case .weeklyEditions: weeklyEditionsPageIndex = newValue
            case .features: featuresPageIndex = newValue
            case .openDeck: openDeckPageIndex = newValue
            }
        }
    }

    private var clampedPageIndex: Int {
        min(max(currentPageIndex, 0), feedPages.count - 1)
    }

    private var isPullToRefreshRunning: Bool {
        switch feedContext {
        case .pullRequests(let feed): feedStore.loadedFeed(feed).isPullToRefreshRunning
        case .weeklyEditions: weeklyEditionsStore.isPullToRefreshRunning
        case .features: featuresStore.isPullToRefreshRunning
        case .openDeck: feedStore.isOpenDeckPullToRefreshRunning
        }
    }

    private var nextPageOffsetSign: CGFloat {
        FeedSwipeGestureMapping.direction(for: .showNextPullRequest) == .up ? 1 : -1
    }

    private var isFeedCovered: Bool {
        detailSheetPullRequest != nil || mediaDeckPullRequestID != nil || selectedTab != .feed
    }

    private var isHeroOccludedForAnalytics: Bool {
        commentsSheetPullRequest != nil || commentsSheetWeeklyEdition != nil || commentsSheetFeature != nil
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
            // Pages fill the screen under the status bar, tab bar and home indicator, and each lays its card out between the top of the status bar and the
            // tab bar; the box rides the keyboard over the card, so the keyboard never relayouts it (AGENTS.md, "Card Layout").
            GeometryReader { safeAreaGeometry in
                let pageChromeInsets = EdgeInsets(
                    top: safeAreaGeometry.safeAreaInsets.top,
                    leading: safeAreaGeometry.safeAreaInsets.leading,
                    bottom: tabBarBottomGap + AppTabBar.height,
                    trailing: safeAreaGeometry.safeAreaInsets.trailing
                )
                GeometryReader { pageGeometry in
                    feedContent(pageSize: pageGeometry.size, pageChromeInsets: pageChromeInsets)
                        .overlay(alignment: .topLeading) {
                            feedModeSwitchAndNewerPullRequestsButton(pageSize: pageGeometry.size, pageChromeInsets: pageChromeInsets)
                        }
                        // Read from this full-screen reader, which never moves with a dragged page, so the rail never jumps mid-swipe.
                        .onChange(of: Self.systemOcclusionFrames(in: pageGeometry), initial: true) { _, measuredSystemOcclusionFrames in
                            systemOcclusionFrames = measuredSystemOcclusionFrames
                        }
                }
                .ignoresSafeArea(.container)
                .onChange(of: safeAreaGeometry.safeAreaInsets.bottom, initial: true) { _, measuredSafeAreaBottomInset in
                    safeAreaBottomInset = measuredSafeAreaBottomInset
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            // Scroll content margins rather than safe-area padding, which a List inside the tabs' NavigationStack ignores, leaving its last rows under the pill.
            selectedTabPage
                .contentMargins(.bottom, AppTabBar.height + tabBarBottomPadding + Self.tabPageScrollEndToTabBarSpacing, for: .scrollContent)
            VStack(spacing: 0) {
                toastStack
                vibeFeedbackComposer
                    .onGeometryChange(for: CGFloat.self) { composerGeometry in
                        composerGeometry.size.height
                    } action: { measuredComposerHeight in
                        vibeFeedbackComposerHeight = measuredComposerHeight
                    }
                if !isKeyboardShown {
                    AppTabBar(
                        selectedTab: Binding(get: { selectedTab }, set: { newSelectedTab in
                            if newSelectedTab == .inbox, promptsGitHubConnection(for: .inbox) { return }
                            selectedTab = newSelectedTab
                        }),
                        unseenInboxItemCount: inboxStore?.unseenItemCount ?? 0,
                        viewerAvatarURL: viewer.teammate?.user.githubAvatarURL
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
        .sheet(item: $commentsSheetPullRequest) { pullRequest in
            PullRequestCommentsSheet(
                thread: pullRequest,
                viewer: viewer.teammate?.user,
                signInSession: signInSession,
                hiddenPeopleStore: viewer.hiddenPeopleStore,
                githubAPIClient: githubAPIClient,
                analytics: viewer.analytics,
                analyticsSubject: VibeTarget(pullRequest: pullRequest).analyticsSubject,
                fetchLatestThread: { [githubAPIClient = githubAPIClient] number in
                    try await githubAPIClient.fetchPullRequest(number: number)
                },
                onThreadChanged: { changedPullRequest in feedStore.applyFetchedPullRequest(changedPullRequest) }
            )
        }
        .sheet(item: $commentsSheetWeeklyEdition) { weeklyEdition in
            PullRequestCommentsSheet(
                thread: weeklyEdition,
                viewer: viewer.teammate?.user,
                signInSession: signInSession,
                hiddenPeopleStore: viewer.hiddenPeopleStore,
                githubAPIClient: githubAPIClient,
                analytics: viewer.analytics,
                analyticsSubject: VibeTarget(weeklyEdition: weeklyEdition).analyticsSubject,
                fetchLatestThread: { [githubAPIClient = githubAPIClient] number in
                    try await githubAPIClient.fetchWeeklyEdition(number: number)
                },
                onThreadChanged: { changedWeeklyEdition in weeklyEditionsStore.applyFetchedPublishedIssue(changedWeeklyEdition) }
            )
        }
        .sheet(item: $commentsSheetFeature) { feature in
            PullRequestCommentsSheet(
                thread: feature,
                viewer: viewer.teammate?.user,
                signInSession: signInSession,
                hiddenPeopleStore: viewer.hiddenPeopleStore,
                githubAPIClient: githubAPIClient,
                analytics: viewer.analytics,
                analyticsSubject: VibeTarget(feature: feature).analyticsSubject,
                fetchLatestThread: { [githubAPIClient = githubAPIClient] number in
                    try await githubAPIClient.fetchFeature(number: number)
                },
                onThreadChanged: { changedFeature in featuresStore.applyFetchedPublishedIssue(changedFeature) }
            )
        }
        .sheet(item: $detailSheetPullRequest) { pullRequest in
            DetailSheetContent(
                feedStore: feedStore,
                vibeOutbox: vibeOutbox,
                viewer: viewer,
                signInSession: signInSession,
                repositoryFullName: githubAPIClient.repositoryFullName,
                presentedPullRequest: pullRequest
            )
        }
        .fullScreenCover(item: $mediaDeckPullRequestID) { presentedPullRequestID in
            MediaDeckCoverContent(feedStore: feedStore, viewer: viewer, signInSession: signInSession, pullRequestID: presentedPullRequestID.id)
        }
        .task(id: onScreenFeedContext) {
            if onScreenFeedContext != nil {
                await refreshShownFeedContextWhileShown()
            }
        }
        .task { await inboxStore?.runLiveRefreshLoop() }
        .task { await userSettingsStore?.refresh() }
        .onAppear {
            feedStore.changeOnScreenPullRequests(to: onScreenPullRequests)
            focusPage(at: currentPageIndex)
        }
        .onChange(of: currentPageIndex) { _, newPageIndex in
            focusPage(at: newPageIndex)
        }
        .onChange(of: feedContext) {
            postVibeAwaitingFeedback()
        }
        .onChange(of: onScreenFeedContext) {
            feedStore.changeOnScreenPullRequests(to: onScreenPullRequests)
            focusPage(at: currentPageIndex)
        }
        .onChange(of: selectedTab) { _, newSelectedTab in
            if newSelectedTab != .feed { postVibeAwaitingFeedback() }
        }
        .onChange(of: feedStore.visiblePullRequests(in: .open).map(\.id)) { previousPullRequestIDs, currentPullRequestIDs in
            keepPullRequestsPageInPlace(in: .open, previousPullRequestIDs: previousPullRequestIDs, currentPullRequestIDs: currentPullRequestIDs)
        }
        .onChange(of: feedStore.visiblePullRequests(in: .merged).map(\.id)) { previousPullRequestIDs, currentPullRequestIDs in
            keepPullRequestsPageInPlace(in: .merged, previousPullRequestIDs: previousPullRequestIDs, currentPullRequestIDs: currentPullRequestIDs)
        }
        .onChange(of: feedStore.visibleOpenDeckPullRequests.map(\.id)) { previousPullRequestIDs, currentPullRequestIDs in
            let previouslyShownPullRequestID = previousPullRequestIDs.indices.contains(openDeckPageIndex) ? previousPullRequestIDs[openDeckPageIndex] : nil
            if let previouslyShownPullRequestID, let movedPageIndex = currentPullRequestIDs.firstIndex(of: previouslyShownPullRequestID), movedPageIndex != openDeckPageIndex {
                openDeckPageIndex = movedPageIndex
                return
            }
            // A viewer on the end page goes to the first card added, since a pull request read again after a failure can join anywhere in the deck.
            if previouslyShownPullRequestID == nil, let addedPageIndex = currentPullRequestIDs.firstIndex(where: { !previousPullRequestIDs.contains($0) }), addedPageIndex != openDeckPageIndex {
                openDeckPageIndex = addedPageIndex
                return
            }
            // The page stayed but its card changed: the first card arrived, or the one under the viewer left, so the store's focus follows while the deck is on screen, never landing on a mode's card at the same index.
            let shownPullRequestID = currentPullRequestIDs.indices.contains(openDeckPageIndex) ? currentPullRequestIDs[openDeckPageIndex] : nil
            if shownPullRequestID != previouslyShownPullRequestID, onScreenFeedContext == .openDeck {
                focusPage(at: openDeckPageIndex)
            }
        }
        .onChange(of: visibleWeeklyEditions.map(\.id)) { previousWeeklyEditionIDs, currentWeeklyEditionIDs in
            guard previousWeeklyEditionIDs.indices.contains(weeklyEditionsPageIndex),
                  let movedPageIndex = currentWeeklyEditionIDs.firstIndex(of: previousWeeklyEditionIDs[weeklyEditionsPageIndex])
            else { return }
            weeklyEditionsPageIndex = movedPageIndex
        }
        .onChange(of: visibleFeatures.map(\.id)) { previousFeatureIDs, currentFeatureIDs in
            guard previousFeatureIDs.indices.contains(featuresPageIndex),
                  let movedPageIndex = currentFeatureIDs.firstIndex(of: previousFeatureIDs[featuresPageIndex])
            else { return }
            featuresPageIndex = movedPageIndex
        }
        .onChange(of: showsOnlyPullRequestsWithVideos, initial: true) { _, newShowsOnlyPullRequestsWithVideos in
            feedStore.showsOnlyPullRequestsWithVideos = newShowsOnlyPullRequestsWithVideos
        }
        .onChange(of: scenePhase) { _, newScenePhase in
            switch newScenePhase {
            case .active:
                if selectedTab == .feed {
                    Task { await refreshShownFeedContext() }
                }
                Task { await inboxStore?.refresh() }
                Task { await userSettingsStore?.refresh() }
            case .background:
                postVibeAwaitingFeedback()
                vibeOutbox.postAllQueuedVibesBeforeSuspension()
                feedStore.saveFeeds()
            default:
                break
            }
        }
        .confirmingHide(of: $postedContentAwaitingHideConfirmation) { postedContent in
            viewer.hiddenPeopleStore.hide(postedContent.postedBy)
            viewer.analytics.capture(.personHidden(postedContent, control: .feedRail))
        }
        .demoGitHubConnectionPrompt($demoGitHubConnectionPromptAction, signInSession: signInSession)
        .environment(\.shipTokAnalytics, viewer.analytics)
        .environment(\.feedViewerMediaCache, viewer.mediaCache)
        .environment(playbackRateChoice)
    }

    @ViewBuilder
    private var newerPullRequestsButton: some View {
        if let shownPullRequestFeed {
            newerPullRequestsButton(in: shownPullRequestFeed)
        }
    }

    @ViewBuilder
    private func newerPullRequestsButton(in feed: PullRequestFeed) -> some View {
        let visiblePullRequests = feedStore.visiblePullRequests(in: feed)
        let unseenNewerPullRequestIDs = feedStore.loadedFeed(feed).unseenNewerPullRequestIDs
        let unseenNewerPageIndexes = visiblePullRequests.indices.filter { unseenNewerPullRequestIDs.contains(visiblePullRequests[$0].id) }
        if let firstUnseenNewerPageIndex = unseenNewerPageIndexes.first, firstUnseenNewerPageIndex < currentPageIndex {
            let unseenNewerPullRequestCount = unseenNewerPageIndexes.count
            let unseenNewerPullRequestsDescription = feed == .merged
                ? (unseenNewerPullRequestCount == 1 ? "newly merged PR" : "newly merged PRs")
                : (unseenNewerPullRequestCount == 1 ? "newly updated open PR" : "newly updated open PRs")
            Button {
                withAnimation(.spring(duration: 0.35)) { currentPageIndex = firstUnseenNewerPageIndex }
            } label: {
                Label("\(unseenNewerPullRequestCount) new", systemImage: "arrow.up")
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
            .accessibilityLabel("\(unseenNewerPullRequestCount) \(unseenNewerPullRequestsDescription) above")
            .transition(.scale.combined(with: .opacity))
        }
    }

    // Its whole 44-point tap target is its frame, like the "new" pill's, so the row under the switch never reaches into the switch's taps.
    private var connectGitHubButton: some View {
        Button {
            _ = promptsGitHubConnection(for: .connectGitHub)
        } label: {
            Label("Connect GitHub", systemImage: "link")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(RevylBrandColor.brand))
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.swipeYielding)
        .fixedSize()
    }

    @ViewBuilder
    private var selectedTabPage: some View {
        switch selectedTab {
        case .feed:
            EmptyView()
        case .inbox:
            if let inboxStore {
                DeveloperInboxView(
                    store: inboxStore,
                    onOpenPullRequest: openPullRequest(number:),
                    onReport: { postedContent in
                        viewer.analytics.capture(.contentReportOpened(postedContent, control: .inboxRow))
                        openURL(postedContent.githubReportURL)
                    },
                    onHide: { postedContent in
                        viewer.hiddenPeopleStore.hide(postedContent.postedBy)
                        viewer.analytics.capture(.personHidden(postedContent, control: .inboxRow))
                    }
                )
            }
        case .settings:
            switch viewer {
            case .teammate(let teammate):
                if let userSettingsStore {
                    SettingsView(
                        viewer: teammate.user,
                        signInID: teammate.signInID,
                        userSettingsStore: userSettingsStore,
                        hiddenPeopleStore: teammate.hiddenPeopleStore,
                        accountAPI: teammate.accountAPI,
                        chosenRepositoryFullName: githubAPIClient.repositoryFullName,
                        signInSession: signInSession,
                        onChooseRepository: { repositoryFullName in
                            postVibeAwaitingFeedback()
                            vibeOutbox.postAllQueuedVibesBeforeSuspension()
                            await feedStore.saveFeeds()?.value
                            onChooseRepository(repositoryFullName)
                        }
                    )
                }
            case .demoVisitor(let demoVisitor):
                DemoSettingsView(
                    demoVisitor: demoVisitor,
                    signInSession: signInSession,
                    showsOnlyPullRequestsWithVideos: $demoVisitShowsOnlyPullRequestsWithVideos
                )
            }
        }
    }

    // The switch sits over the card's top left, inside the format's top safe zone and never under the status bar. Under it, clear of the switch's taps,
    // one row holds a demo visitor's Connect GitHub, so the way to their own feed always shows, and then the "new" pill, so neither covers the switch or the
    // other however wide the switch grows (AGENTS.md, "Card Layout" and "Demo Mode").
    private func feedModeSwitchAndNewerPullRequestsButton(pageSize: CGSize, pageChromeInsets: EdgeInsets) -> some View {
        let cardFrame = FeedCardView.cardFrame(in: pageSize, pageChromeInsets: pageChromeInsets).card
        return VStack(alignment: .leading, spacing: Self.newerPullRequestsButtonGapBelowFeedModeSwitch) {
            FeedModeSwitch(
                feedMode: Binding(get: { feedMode }, set: { feedMode = $0 }),
                shownDeckSource: feedContext == .openDeck ? openDeckSource : nil,
                onCloseDeck: closeDeck
            )
            .opacity(vibeAwaitingFeedback == nil ? 1 : 0)
            HStack(spacing: Self.connectGitHubButtonGapBeforeNewerPullRequestsButton) {
                if viewer.teammate == nil {
                    connectGitHubButton
                        .opacity(vibeAwaitingFeedback == nil ? 1 : 0)
                }
                newerPullRequestsButton
                    .animation(.snappy, value: shownPullRequestFeed.map { feedStore.loadedFeed($0).unseenNewerPullRequestIDs.isEmpty } ?? true)
            }
        }
        .offset(
            x: cardFrame.minX + Self.feedModeSwitchInsetInCard.width,
            y: max(cardFrame.minY + Self.feedModeSwitchInsetInCard.height, pageChromeInsets.top + Self.feedModeSwitchMinimumGapBelowSafeArea)
        )
    }

    @ViewBuilder
    private func feedContent(pageSize: CGSize, pageChromeInsets: EdgeInsets) -> some View {
        switch feedContext {
        case .pullRequests(let feed):
            pullRequestsFeedContent(in: feed, pageSize: pageSize, pageChromeInsets: pageChromeInsets)
        case .weeklyEditions:
            weeklyEditionsFeedContent(pageSize: pageSize, pageChromeInsets: pageChromeInsets)
        case .features:
            featuresFeedContent(pageSize: pageSize, pageChromeInsets: pageChromeInsets)
        case .openDeck:
            openDeckFeedContent(pageSize: pageSize, pageChromeInsets: pageChromeInsets)
        }
    }

    @ViewBuilder
    private func weeklyEditionsFeedContent(pageSize: CGSize, pageChromeInsets: EdgeInsets) -> some View {
        if !weeklyEditionsStore.publishedIssues.isEmpty {
            feedDeck(deckSize: pageSize, pageChromeInsets: pageChromeInsets)
        } else if let loadFailureMessage = weeklyEditionsStore.loadFailureMessage {
            RevylContentUnavailableView(
                systemImageName: "exclamationmark.triangle",
                title: Text("Couldn't load the weekly videos"),
                message: Text(verbatim: loadFailureMessage),
                actionTitle: Text("Try again"),
                action: { Task { await weeklyEditionsStore.refresh() } }
            )
        } else if !weeklyEditionsStore.isLoaded {
            FeedLoadingView(message: "Finding the weekly videos…")
        } else {
            RevylContentUnavailableView(
                systemImageName: "calendar",
                title: Text("No weekly videos yet"),
                message: Text("Each week's video is a closed issue labeled \(WeeklyEditionFormat.labelName) in \(githubAPIClient.repositoryFullName). None is posted yet.")
            )
        }
    }

    @ViewBuilder
    private func featuresFeedContent(pageSize: CGSize, pageChromeInsets: EdgeInsets) -> some View {
        if !featuresStore.publishedIssues.isEmpty {
            feedDeck(deckSize: pageSize, pageChromeInsets: pageChromeInsets)
        } else if let loadFailureMessage = featuresStore.loadFailureMessage {
            RevylContentUnavailableView(
                systemImageName: "exclamationmark.triangle",
                title: Text("Couldn't load the feature videos"),
                message: Text(verbatim: loadFailureMessage),
                actionTitle: Text("Try again"),
                action: { Task { await featuresStore.refresh() } }
            )
        } else if !featuresStore.isLoaded {
            FeedLoadingView(message: "Finding the feature videos…")
        } else {
            RevylContentUnavailableView(
                systemImageName: "sparkles.rectangle.stack",
                title: Text("No feature videos yet"),
                message: Text("Each feature's video is a closed issue labeled \(FeatureFormat.labelName) in \(githubAPIClient.repositoryFullName). None is posted yet.")
            )
        }
    }

    @ViewBuilder
    private func openDeckFeedContent(pageSize: CGSize, pageChromeInsets: EdgeInsets) -> some View {
        let isWeekDeck = openDeckSource?.feedMode == .weekly
        if !feedStore.openDeckPullRequests.isEmpty {
            feedDeck(deckSize: pageSize, pageChromeInsets: pageChromeInsets)
        } else if let openDeckReadFailureMessage = feedStore.openDeckReadFailureMessage {
            RevylContentUnavailableView(
                systemImageName: "exclamationmark.triangle",
                title: Text(isWeekDeck ? "Couldn't load this week's pull requests" : "Couldn't load this feature's pull requests"),
                message: Text(verbatim: openDeckReadFailureMessage),
                actionTitle: Text("Try again"),
                action: { feedStore.retryOpenDeckReads() }
            )
        } else if !feedStore.openDeckPullRequestNumbersToRead.isEmpty {
            FeedLoadingView(message: isWeekDeck ? "Loading the week's pull requests…" : "Loading the feature's pull requests…")
        } else {
            RevylContentUnavailableView(
                systemImageName: "rectangle.stack",
                title: Text(isWeekDeck ? "None of this week's pull requests could be read" : "None of this feature's pull requests could be read"),
                message: Text("They may be private to you, or closed without being merged."),
                actionTitle: Text(isWeekDeck ? "Back to weekly videos" : "Back to feature videos"),
                action: closeDeck
            )
        }
    }

    // Until a card shows, the feed keeps reading older pages, so it's loading until GitHub has no more (AGENTS.md, "Feed Order").
    @ViewBuilder
    private func pullRequestsFeedContent(in feed: PullRequestFeed, pageSize: CGSize, pageChromeInsets: EdgeInsets) -> some View {
        let loadedFeed = feedStore.loadedFeed(feed)
        if !feedStore.visiblePullRequests(in: feed).isEmpty {
            feedDeck(deckSize: pageSize, pageChromeInsets: pageChromeInsets)
        } else if let loadFailureMessage = loadedFeed.loadFailureMessage {
            RevylContentUnavailableView(
                systemImageName: "exclamationmark.triangle",
                title: Text(feed == .merged ? "Couldn't load merged PRs" : "Couldn't load open PRs"),
                message: Text(verbatim: loadFailureMessage),
                actionTitle: Text("Try again"),
                action: { Task { await feedStore.loadOlderPullRequests(in: feed) } }
            )
        } else if !loadedFeed.hasLoadedEveryPullRequest {
            FeedLoadingView(message: "Finding \(feed == .merged ? "merged" : "open") PRs with \(showsOnlyPullRequestsWithVideos ? "videos" : "videos and screenshots")…")
        } else {
            let shownMediaDescription = showsOnlyPullRequestsWithVideos ? "lead with a video" : "carry a video, screenshot or GIF"
            let videosOnlyHint = showsOnlyPullRequestsWithVideos ? " Turn off Videos only in Settings to see ones with only screenshots or GIFs." : ""
            switch feed {
            case .open:
                RevylContentUnavailableView(
                    systemImageName: "film.stack",
                    title: Text(showsOnlyPullRequestsWithVideos ? "No open PRs with videos" : "No open PRs with media"),
                    message: Text("ShipTok shows open pull requests in \(githubAPIClient.repositoryFullName), drafts included, that \(shownMediaDescription). None do right now.\(videosOnlyHint)")
                )
            case .merged:
                RevylContentUnavailableView(
                    systemImageName: "film.stack",
                    title: Text(showsOnlyPullRequestsWithVideos ? "No merged PRs with videos yet" : "No merged PRs with media yet"),
                    message: Text("ShipTok shows pull requests merged into \(githubAPIClient.repositoryFullName) that \(shownMediaDescription). None do yet.\(videosOnlyHint)")
                )
            }
        }
    }

    private func feedDeck(deckSize: CGSize, pageChromeInsets: EdgeInsets) -> some View {
        let pages = feedPages
        let currentIndex = clampedPageIndex
        let visiblePageEntries = (max(0, currentIndex - 1)...min(pages.count - 1, currentIndex + 1))
            .map { pageIndex in (pageIndex: pageIndex, page: pages[pageIndex]) }
        return ZStack {
            ForEach(visiblePageEntries, id: \.page.id) { pageEntry in
                let isCurrentPage = pageEntry.pageIndex == currentIndex
                pageView(pageEntry.page, isCurrentPage: isCurrentPage, deckSize: deckSize, pageChromeInsets: pageChromeInsets)
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
                .padding(.top, pageChromeInsets.top)
        }
        .contentShape(Rectangle())
        .gesture(deckDragGesture(deckSize: deckSize, pageChromeInsets: pageChromeInsets))
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
    private func pageView(_ page: FeedPage, isCurrentPage: Bool, deckSize: CGSize, pageChromeInsets: EdgeInsets) -> some View {
        switch page {
        case .pullRequest(let pullRequest):
            feedCard(
                .pullRequest(pullRequest),
                heroMediaItem: feedStore.heroMediaItem(of: pullRequest),
                unloadableMediaItemIDs: feedStore.unloadableMediaItemIDs,
                isCurrentPage: isCurrentPage,
                deckSize: deckSize,
                pageChromeInsets: pageChromeInsets,
                likeUnlessAlreadyLiked: { Task { await feedStore.likeUnlessAlreadyLiked(pullRequestID: pullRequest.id) } },
                toggleReaction: { reaction in Task { await feedStore.toggleReaction(reaction, pullRequestID: pullRequest.id) } },
                openComments: { commentsSheetPullRequest = feedStore.pullRequest(withID: pullRequest.id) ?? pullRequest },
                openDeck: { mediaDeckPullRequestID = PresentedPullRequestID(id: pullRequest.id) },
                tapCaption: { detailSheetPullRequest = pullRequest },
                recoverFromHeroMediaLoadFailure: { failedHeroMediaItem, wasRefusedToViewer in
                    feedStore.recoverFromMediaLoadFailure(of: failedHeroMediaItem, onPullRequestID: pullRequest.id, wasRefusedToViewer: wasRefusedToViewer)
                }
            )
        case .weeklyEdition(let weeklyEdition):
            feedCard(
                .weeklyEdition(weeklyEdition),
                heroMediaItem: weeklyEditionsStore.heroMediaItem(of: weeklyEdition),
                unloadableMediaItemIDs: weeklyEditionsStore.unloadableMediaItemIDs,
                isCurrentPage: isCurrentPage,
                deckSize: deckSize,
                pageChromeInsets: pageChromeInsets,
                likeUnlessAlreadyLiked: { Task { await weeklyEditionsStore.likeUnlessAlreadyLiked(publishedIssueID: weeklyEdition.id) } },
                toggleReaction: { reaction in Task { await weeklyEditionsStore.toggleReaction(reaction, publishedIssueID: weeklyEdition.id) } },
                openComments: { commentsSheetWeeklyEdition = weeklyEditionsStore.publishedIssue(withID: weeklyEdition.id) ?? weeklyEdition },
                openDeck: { openDeck(of: .weeklyEdition(weeklyEdition)) },
                tapCaption: { openDeck(of: .weeklyEdition(weeklyEdition)) },
                recoverFromHeroMediaLoadFailure: { failedHeroMediaItem, wasRefusedToViewer in
                    Task { await weeklyEditionsStore.recoverFromMediaLoadFailure(of: failedHeroMediaItem, wasRefusedToViewer: wasRefusedToViewer) }
                }
            )
        case .feature(let feature):
            feedCard(
                .feature(feature),
                heroMediaItem: featuresStore.heroMediaItem(of: feature),
                unloadableMediaItemIDs: featuresStore.unloadableMediaItemIDs,
                isCurrentPage: isCurrentPage,
                deckSize: deckSize,
                pageChromeInsets: pageChromeInsets,
                likeUnlessAlreadyLiked: { Task { await featuresStore.likeUnlessAlreadyLiked(publishedIssueID: feature.id) } },
                toggleReaction: { reaction in Task { await featuresStore.toggleReaction(reaction, publishedIssueID: feature.id) } },
                openComments: { commentsSheetFeature = featuresStore.publishedIssue(withID: feature.id) ?? feature },
                openDeck: { openDeck(of: .feature(feature)) },
                tapCaption: { openDeck(of: .feature(feature)) },
                recoverFromHeroMediaLoadFailure: { failedHeroMediaItem, wasRefusedToViewer in
                    Task { await featuresStore.recoverFromMediaLoadFailure(of: failedHeroMediaItem, wasRefusedToViewer: wasRefusedToViewer) }
                }
            )
        case .feedEnd:
            feedEndPage
        }
    }

    private func feedCard(
        _ post: FeedCardPost,
        heroMediaItem: PullRequestMediaItem?,
        unloadableMediaItemIDs: Set<String>,
        isCurrentPage: Bool,
        deckSize: CGSize,
        pageChromeInsets: EdgeInsets,
        likeUnlessAlreadyLiked: @escaping () -> Void,
        toggleReaction: @escaping (GitHubReaction) -> Void,
        openComments: @escaping () -> Void,
        openDeck: @escaping () -> Void,
        tapCaption: @escaping () -> Void,
        recoverFromHeroMediaLoadFailure: @escaping (PullRequestMediaItem, _ wasRefusedToViewer: Bool) -> Void
    ) -> FeedCardView {
        let thread = post.thread
        let vibeTarget = post.vibeTarget
        let analyticsSubject = vibeTarget.analyticsSubject
        let deckSource: PullRequestDeckSource? = switch post {
        case .pullRequest: nil
        case .weeklyEdition(let weeklyEdition): .weeklyEdition(weeklyEdition)
        case .feature(let feature): .feature(feature)
        }
        return FeedCardView(
            post: post,
            heroMediaItem: heroMediaItem,
            isHeroMediaUnloadable: heroMediaItem.map { unloadableMediaItemIDs.contains($0.id) } ?? false,
            analyticsSubject: analyticsSubject,
            pageChromeInsets: pageChromeInsets,
            systemOcclusionFrames: systemOcclusionFrames,
            videoScrubFraction: isCurrentPage ? videoScrubFraction : nil,
            vibeFeedbackComposerHeight: vibeFeedbackComposerHeight,
            isBehindVibeFeedbackComposer: vibeAwaitingFeedback != nil,
            isKeyboardShown: isKeyboardShown,
            vibes: feedCardVibes(
                tally: thread.vibeTally(
                    viewerGitHubLogin: viewer.githubLogin,
                    viewerPendingVibe: vibeOutbox.pendingVibe(forThreadID: thread.id)
                ),
                target: vibeTarget,
                deckWidth: deckSize.width
            ),
            moderation: feedCardModeration(reportableContents: thread.reportableContents(
                postedOn: analyticsSubject,
                excludingContentBy: viewer.githubLogin
            )),
            deckPullRequestCount: deckSource.flatMap { feedStore.pullRequestCountOfDeckReadInFull(listing: $0.listing) },
            isPlaybackActive: isCurrentPage && scenePhase == .active && !isFeedCovered,
            isOccludedForAnalytics: isHeroOccludedForAnalytics,
            horizontalDragProgress: isCurrentPage ? horizontalDragOffset / max(deckSize.width, 1) : 0,
            likeBurstTrigger: likeBurstTriggers[thread.id, default: 0],
            onDoubleTap: {
                guard !promptsGitHubConnection(for: .like) else { return }
                showLikeBurst(onPostID: thread.id)
                viewer.analytics.capture(.likeSelected(analyticsSubject, control: .doubleTap, wasLiked: thread.reactions.viewerReactions.contains(.heart)))
                likeUnlessAlreadyLiked()
            },
            onToggleLike: {
                guard !promptsGitHubConnection(for: .like) else { return }
                likeHapticTrigger += 1
                viewer.analytics.capture(.likeSelected(analyticsSubject, control: .feedRail, wasLiked: thread.reactions.viewerReactions.contains(.heart)))
                toggleReaction(.heart)
            },
            onToggleReaction: { reaction in
                guard !promptsGitHubConnection(for: .reaction) else { return }
                toggleReaction(reaction)
            },
            onOpenComments: {
                openComments()
                viewer.analytics.capture(.commentsOpened(analyticsSubject))
            },
            onOpenDeck: openDeck,
            onTapCaption: tapCaption,
            onHeroMediaLoadFailure: recoverFromHeroMediaLoadFailure,
            onTapWhileBehindVibeFeedbackComposer: dismissKeyboard
        )
    }

    private func feedCardVibes(tally: PullRequestVibeTally, target: VibeTarget, deckWidth: CGFloat) -> FeedCardVibes {
        FeedCardVibes(
            tally: tally,
            onCast: { vibe in
                guard !isPageTransitionRunning else { return }
                flingCard(of: target, castingVibe: vibe, deckWidth: deckWidth)
            },
            onRemoveViewerVibe: { removeViewerVibe(on: target) }
        )
    }

    private func feedCardModeration(reportableContents: [GitHubPostedContent]) -> GitHubPostedContentModeration {
        GitHubPostedContentModeration(
            reportableContents: reportableContents,
            onReport: { postedContent in
                guard !promptsGitHubConnection(for: .report) else { return }
                viewer.analytics.capture(.contentReportOpened(postedContent, control: .feedRail))
                openURL(postedContent.githubReportURL)
            },
            onHide: { postedContent in postedContentAwaitingHideConfirmation = postedContent }
        )
    }

    @ViewBuilder
    private var feedEndPage: some View {
        switch feedContext {
        case .pullRequests(let feed):
            let loadedFeed = feedStore.loadedFeed(feed)
            FeedEndPageView(
                feed: feed,
                repositoryFullName: githubAPIClient.repositoryFullName,
                isDemoVisit: viewer.teammate == nil,
                showsOnlyPullRequestsWithVideos: showsOnlyPullRequestsWithVideos,
                loadFailureMessage: loadedFeed.loadFailureMessage,
                hasLoadedEveryPullRequest: loadedFeed.hasLoadedEveryPullRequest,
                onRetry: { Task { await feedStore.loadOlderPullRequests(in: feed) } }
            )
        case .weeklyEditions:
            RevylContentUnavailableView(
                systemImageName: "checkmark.seal.fill",
                title: Text("That's every weekly video"),
                message: Text("A new one lands after each week ends, Monday to Sunday.")
            )
            .background(RevylBrandColor.canvas)
        case .features:
            RevylContentUnavailableView(
                systemImageName: "checkmark.seal.fill",
                title: Text("That's every feature video"),
                message: Text("A new one lands when its issue closes.")
            )
            .background(RevylBrandColor.canvas)
        case .openDeck:
            // While a pull request the deck lists is still unread after a failed read, its end page offers to try again rather than saying the viewer saw them all (AGENTS.md, "Pull Request Decks").
            let isWeekDeck = openDeckSource?.feedMode == .weekly
            if let openDeckReadFailureMessage = feedStore.openDeckReadFailureMessage {
                let unreadPullRequestCount = feedStore.openDeckPullRequestNumbersToRead.count
                RevylContentUnavailableView(
                    systemImageName: "exclamationmark.triangle",
                    title: Text(isWeekDeck
                        ? "Couldn't load \(unreadPullRequestCount) of this week's pull requests"
                        : "Couldn't load \(unreadPullRequestCount) of this feature's pull requests"),
                    message: Text(verbatim: openDeckReadFailureMessage),
                    actionTitle: Text("Try again"),
                    action: { feedStore.retryOpenDeckReads() }
                )
                .background(RevylBrandColor.canvas)
            } else if !feedStore.openDeckPullRequestNumbersToRead.isEmpty {
                FeedLoadingView(message: isWeekDeck ? "Loading the rest of the week…" : "Loading the rest of the feature…")
                    .background(RevylBrandColor.canvas)
            } else {
                switch openDeckSource {
                case .weeklyEdition(let weeklyEdition):
                    RevylContentUnavailableView(
                        systemImageName: "checkmark.seal.fill",
                        title: Text("That's the week of \(weeklyEdition.weekDatesText)"),
                        message: Text("You've seen every pull request in this week's video."),
                        actionTitle: Text("Back to weekly videos"),
                        action: closeDeck
                    )
                    .background(RevylBrandColor.canvas)
                case .feature(let feature):
                    RevylContentUnavailableView(
                        systemImageName: "checkmark.seal.fill",
                        title: Text("That's “\(feature.title)”"),
                        message: Text("You've seen every pull request behind this feature."),
                        actionTitle: Text("Back to feature videos"),
                        action: closeDeck
                    )
                    .background(RevylBrandColor.canvas)
                case nil:
                    EmptyView()
                }
            }
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
            if let weeklyTransientErrorMessage = weeklyEditionsStore.transientErrorMessage {
                FeedToastView(
                    message: weeklyTransientErrorMessage,
                    tint: RevylBrandColor.warning,
                    onDismiss: { weeklyEditionsStore.transientErrorMessage = nil }
                )
            }
            if let featuresTransientErrorMessage = featuresStore.transientErrorMessage {
                FeedToastView(
                    message: featuresTransientErrorMessage,
                    tint: RevylBrandColor.warning,
                    onDismiss: { featuresStore.transientErrorMessage = nil }
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
        .animation(.snappy, value: weeklyEditionsStore.transientErrorMessage)
        .animation(.snappy, value: featuresStore.transientErrorMessage)
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
    private func deckDragGesture(deckSize: CGSize, pageChromeInsets: EdgeInsets) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { dragValue in
                guard !isPageTransitionRunning else { return }
                let cardFrame = FeedCardView.cardFrame(in: deckSize, pageChromeInsets: pageChromeInsets).card
                if activeDeckDrag == nil {
                    if abs(dragValue.translation.width) <= abs(dragValue.translation.height) {
                        activeDeckDrag = .pageSwipe
                    } else if isHeroLoadableVideo(of: feedPages[clampedPageIndex]),
                              FeedCardView.videoScrubZone(cardFrame: cardFrame).contains(dragValue.startLocation) {
                        activeDeckDrag = .videoScrub
                    } else {
                        activeDeckDrag = .vibeSwipe
                    }
                }
                switch activeDeckDrag {
                case .vibeSwipe:
                    guard feedPages[clampedPageIndex].vibeTarget != nil else { return }
                    horizontalDragOffset = dragValue.translation.width
                case .pageSwipe:
                    verticalDragOffset = resistedVerticalDragOffset(dragValue.translation.height)
                case .videoScrub:
                    videoScrubFraction = FeedCardView.videoScrubFraction(atX: dragValue.location.x, cardFrame: cardFrame)
                case nil:
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
                case .videoScrub, nil:
                    break
                }
            }
    }

    private func isHeroLoadableVideo(of page: FeedPage) -> Bool {
        let (heroMediaItem, unloadableMediaItemIDs): (PullRequestMediaItem?, Set<String>) = switch page {
        case .pullRequest(let pullRequest): (feedStore.heroMediaItem(of: pullRequest), feedStore.unloadableMediaItemIDs)
        case .weeklyEdition(let weeklyEdition): (weeklyEditionsStore.heroMediaItem(of: weeklyEdition), weeklyEditionsStore.unloadableMediaItemIDs)
        case .feature(let feature): (featuresStore.heroMediaItem(of: feature), featuresStore.unloadableMediaItemIDs)
        case .feedEnd: (nil, [])
        }
        guard let heroMediaItem else { return false }
        return heroMediaItem.kind == .video && !unloadableMediaItemIDs.contains(heroMediaItem.id)
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
        case .pullRequests(let feed): Task { await feedStore.refreshFromPull(in: feed) }
        case .weeklyEditions: Task { await weeklyEditionsStore.refreshFromPull() }
        case .features: Task { await featuresStore.refreshFromPull() }
        case .openDeck: Task { await feedStore.refreshOpenDeckFromPull() }
        }
    }

    private func focusPage(at pageIndex: Int) {
        switch onScreenFeedContext {
        case nil:
            break
        case .pullRequests(let feed):
            focusPullRequestsPage(in: feed, at: pageIndex)
        case .weeklyEditions:
            Task { await weeklyEditionsStore.refreshIfMediaURLsAreStale() }
        case .features:
            Task { await featuresStore.refreshIfMediaURLsAreStale() }
        case .openDeck:
            let visibleOpenDeckPullRequests = feedStore.visibleOpenDeckPullRequests
            feedStore.focusOpenDeckPage(showingPullRequestID: visibleOpenDeckPullRequests.indices.contains(pageIndex) ? visibleOpenDeckPullRequests[pageIndex].id : nil)
        }
    }

    private func focusPullRequestsPage(in feed: PullRequestFeed, at pageIndex: Int) {
        let visiblePullRequests = feedStore.visiblePullRequests(in: feed)
        feedStore.focusFeedPage(in: feed, showingPullRequestID: visiblePullRequests.indices.contains(pageIndex) ? visiblePullRequests[pageIndex].id : nil)
    }

    private func pageIndex(in feed: PullRequestFeed) -> Int {
        switch feed {
        case .open: openPullRequestsPageIndex
        case .merged: mergedPullRequestsPageIndex
        }
    }

    private func setPageIndex(_ pageIndex: Int, in feed: PullRequestFeed) {
        switch feed {
        case .open: openPullRequestsPageIndex = pageIndex
        case .merged: mergedPullRequestsPageIndex = pageIndex
        }
    }

    // An iOS app shows the newest data it has, so the shown mode reads GitHub again as soon as it shows and every few seconds while it stays (AGENTS.md, "Feed Order").
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
        case .pullRequests(let feed): await feedStore.refreshNewestData(in: feed)
        case .weeklyEditions: await weeklyEditionsStore.refresh()
        case .features: await featuresStore.refresh()
        case .openDeck: await feedStore.refreshOpenDeck()
        }
    }

    // The store holds one deck, so opening a feature's deck closes an open week's and the other way round, and the mode behind the closed one shows its list (AGENTS.md, "Feed Modes").
    private func openDeck(of deckSource: PullRequestDeckSource) {
        openDeckPageIndex = 0
        openDeckSource = deckSource
        feedStore.openDeck(listing: deckSource.listing)
    }

    private func closeDeck() {
        withAnimation(.spring(duration: 0.3)) { openDeckSource = nil }
        feedStore.closeDeck()
    }

    // A vibe from the rail leaves the same way as a swipe, toward that vibe's swipe direction, so both ways read as one gesture.
    private func flingCard(of vibeTarget: VibeTarget, castingVibe vibe: PullRequestVibe, deckWidth: CGFloat) {
        guard !promptsGitHubConnection(for: .vibe) else {
            withAnimation(.spring(duration: 0.3)) { horizontalDragOffset = 0 }
            return
        }
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
    private func castVibe(_ vibe: PullRequestVibe, on vibeTarget: VibeTarget, selectionID: UUID) {
        postVibeAwaitingFeedback()
        if userSettingsStore?.showsFeedbackBox(for: vibe) == true {
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
        showPage(withID: cancelledVibe.target.threadID)
    }

    private func removeViewerVibe(on vibeTarget: VibeTarget) {
        if vibeAwaitingFeedback?.target.threadID == vibeTarget.threadID {
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

    // A demo visitor is asked to connect GitHub instead of posting to GitHub; true when that's what happened (AGENTS.md, "Demo Mode").
    private func promptsGitHubConnection(for action: DemoGitHubConnectionPromptAction) -> Bool {
        guard case .demoVisitor(let demoVisitor) = viewer else { return false }
        demoVisitor.analytics.capture(.demoGitHubConnectionPrompted(action))
        demoGitHubConnectionPromptAction = action
        return true
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
        showPage(withID: undoneVibe.target.threadID)
    }

    // Only a page of the context on screen comes back; a vibe from another mode or deck stays where it was cast.
    private func showPage(withID pageID: String) {
        guard let pageIndex = feedPages.firstIndex(where: { $0.id == pageID }) else { return }
        withAnimation(.spring(duration: 0.35)) { currentPageIndex = pageIndex }
    }

    // The viewer's card keeps its place as cards arrive or leave around it. At the feed's end the viewer stays just past every card they had, so the first older card that loads is the one they see next (AGENTS.md, "Feed Order").
    private func keepPullRequestsPageInPlace(in feed: PullRequestFeed, previousPullRequestIDs: [String], currentPullRequestIDs: [String]) {
        let isShowingFeed = onScreenFeedContext == .pullRequests(feed)
        let previousPageIndex = pageIndex(in: feed)
        defer {
            if isShowingFeed { feedStore.loadOlderPullRequestsIfViewerNearsEnd(in: feed) }
        }
        guard previousPullRequestIDs.indices.contains(previousPageIndex) else {
            let previousPullRequestIDSet = Set(previousPullRequestIDs)
            setPageIndex((currentPullRequestIDs.lastIndex { previousPullRequestIDSet.contains($0) } ?? -1) + 1, in: feed)
            if isShowingFeed { focusPullRequestsPage(in: feed, at: pageIndex(in: feed)) }
            return
        }
        if let movedPageIndex = currentPullRequestIDs.firstIndex(of: previousPullRequestIDs[previousPageIndex]) {
            if movedPageIndex != previousPageIndex {
                setPageIndex(movedPageIndex, in: feed)
            }
        } else {
            setPageIndex(min(previousPageIndex, currentPullRequestIDs.count), in: feed)
            if isShowingFeed { focusPullRequestsPage(in: feed, at: pageIndex(in: feed)) }
        }
    }

    private func openPullRequest(number: Int) {
        for feed in [PullRequestFeed.merged, .open] {
            guard let pageIndex = feedStore.visiblePullRequests(in: feed).firstIndex(where: { $0.number == number }) else { continue }
            feedMode = FeedMode(feed)
            selectedTab = .feed
            setPageIndex(pageIndex, in: feed)
            return
        }
        openURL(githubAPIClient.pullRequestURL(number: number))
    }
}

private struct MediaDeckCoverContent: View {
    let feedStore: PullRequestFeedStore
    let viewer: FeedViewer
    let signInSession: ShipTokSignInSession
    let pullRequestID: String
    @State private var postedContentAwaitingHideConfirmation: GitHubPostedContent?
    @State private var demoGitHubConnectionPromptAction: DemoGitHubConnectionPromptAction?
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    private var visiblePullRequest: PullRequest? {
        feedStore.pullRequest(withID: pullRequestID)?.withoutHiddenPeople(viewer.hiddenPeopleStore)
    }

    var body: some View {
        let pullRequest = visiblePullRequest
        let analyticsSubject = pullRequest.map { VibeTarget(pullRequest: $0).analyticsSubject }
        PullRequestMediaDeckView(
            mediaItems: pullRequest?.mediaItems ?? [],
            unloadableMediaItemIDs: feedStore.unloadableMediaItemIDs,
            analyticsSubject: analyticsSubject,
            reportableContent: { mediaItem in
                guard let pullRequest, let analyticsSubject else { return nil }
                return pullRequest.reportableContent(of: mediaItem, postedOn: analyticsSubject, excludingContentBy: viewer.githubLogin)
            },
            onReport: { postedContent in
                if case .demoVisitor(let demoVisitor) = viewer {
                    demoVisitor.analytics.capture(.demoGitHubConnectionPrompted(.report))
                    demoGitHubConnectionPromptAction = .report
                    return
                }
                viewer.analytics.capture(.contentReportOpened(postedContent, control: .mediaDeck))
                openURL(postedContent.githubReportURL)
            },
            onHide: { postedContent in postedContentAwaitingHideConfirmation = postedContent },
            onLoadFailure: { failedMediaItem, wasRefusedToViewer in
                feedStore.recoverFromMediaLoadFailure(of: failedMediaItem, onPullRequestID: pullRequestID, wasRefusedToViewer: wasRefusedToViewer)
            }
        )
        .confirmingHide(of: $postedContentAwaitingHideConfirmation) { postedContent in
            viewer.hiddenPeopleStore.hide(postedContent.postedBy)
            viewer.analytics.capture(.personHidden(postedContent, control: .mediaDeck))
            if visiblePullRequest == nil { dismiss() }
        }
        .demoGitHubConnectionPrompt($demoGitHubConnectionPromptAction, signInSession: signInSession)
    }
}

private struct DetailSheetContent: View {
    let feedStore: PullRequestFeedStore
    let vibeOutbox: VibeOutbox
    let viewer: FeedViewer
    let signInSession: ShipTokSignInSession
    let repositoryFullName: String
    let presentedPullRequest: PullRequest
    @State private var postedContentAwaitingHideConfirmation: GitHubPostedContent?
    @State private var demoGitHubConnectionPromptAction: DemoGitHubConnectionPromptAction?
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let storedPullRequest = feedStore.pullRequest(withID: presentedPullRequest.id) ?? presentedPullRequest
        let pullRequest = storedPullRequest.withoutHiddenPeople(viewer.hiddenPeopleStore) ?? storedPullRequest
        PullRequestDetailSheet(
            pullRequest: pullRequest,
            repositoryFullName: repositoryFullName,
            vibeTally: pullRequest.vibeTally(
                viewerGitHubLogin: viewer.githubLogin,
                viewerPendingVibe: vibeOutbox.pendingVibe(forThreadID: pullRequest.id)
            ),
            moderation: GitHubPostedContentModeration(
                reportableContents: pullRequest.reportableContents(
                    postedOn: VibeTarget(pullRequest: pullRequest).analyticsSubject,
                    excludingContentBy: viewer.githubLogin
                ).filter { $0.kind == .description },
                onReport: { postedContent in
                    guard !promptsGitHubConnection(for: .report) else { return }
                    viewer.analytics.capture(.contentReportOpened(postedContent, control: .detailSheet))
                    openURL(postedContent.githubReportURL)
                },
                onHide: { postedContent in postedContentAwaitingHideConfirmation = postedContent }
            ),
            onToggleReaction: { reaction in
                guard !promptsGitHubConnection(for: .reaction) else { return }
                Task { await feedStore.toggleReaction(reaction, pullRequestID: pullRequest.id) }
            }
        )
        .confirmingHide(of: $postedContentAwaitingHideConfirmation) { postedContent in
            viewer.hiddenPeopleStore.hide(postedContent.postedBy)
            viewer.analytics.capture(.personHidden(postedContent, control: .detailSheet))
            dismiss()
        }
        .demoGitHubConnectionPrompt($demoGitHubConnectionPromptAction, signInSession: signInSession)
    }

    private func promptsGitHubConnection(for action: DemoGitHubConnectionPromptAction) -> Bool {
        guard case .demoVisitor(let demoVisitor) = viewer else { return false }
        demoVisitor.analytics.capture(.demoGitHubConnectionPrompted(action))
        demoGitHubConnectionPromptAction = action
        return true
    }
}
