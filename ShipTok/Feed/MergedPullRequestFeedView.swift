import SwiftUI

struct MergedPullRequestFeedView: View {
    private enum FeedContext: Hashable {
        case pullRequests
        case weeklyEditions
        case openWeek
    }

    private enum FeedPage: Identifiable {
        case pullRequest(MergedPullRequest)
        case weeklyEdition(WeeklyEdition)
        case feedEnd

        var id: String {
            switch self {
            case .pullRequest(let pullRequest): pullRequest.id
            case .weeklyEdition(let weeklyEdition): weeklyEdition.id
            case .feedEnd: "feed-end"
            }
        }

        var vibeTarget: VibeTarget? {
            switch self {
            case .pullRequest(let pullRequest): VibeTarget(pullRequest: pullRequest)
            case .weeklyEdition(let weeklyEdition): VibeTarget(weeklyEdition: weeklyEdition)
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
    let signInSession: GitHubSignInSession
    let onChooseRepository: @MainActor (String) -> Void
    private let githubAPIClient: GitHubAPIClient
    @State private var feedStore: MergedPullRequestFeedStore
    @State private var weeklyEditionsStore: WeeklyEditionsStore
    @State private var vibeOutbox: VibeOutbox
    // A demo visitor has no inbox or saved settings.
    @State private var inboxStore: DeveloperInboxStore?
    @State private var userSettingsStore: UserSettingsStore?
    @State private var demoSignInPromptAction: DemoSignInPromptAction?
    @AppStorage("feed-mode") private var savedFeedMode: FeedMode = .perPullRequest
    @State private var demoVisitFeedMode: FeedMode = .perPullRequest
    @State private var playbackRateChoice: VideoPlaybackRateChoice
    @State private var openWeeklyEdition: WeeklyEdition?
    @State private var pullRequestsPageIndex = 0
    @State private var weeklyEditionsPageIndex = 0
    @State private var openWeekPageIndex = 0
    @State private var verticalDragOffset: CGFloat = 0
    @State private var horizontalDragOffset: CGFloat = 0
    @State private var activeDeckDrag: DeckDrag?
    @State private var videoScrubFraction: CGFloat?
    @State private var systemOcclusionFrames: [CGRect] = []
    @State private var isPageTransitionRunning = false
    @State private var cardEntranceScale: CGFloat = 1
    @State private var likeBurstTriggers: [String: Int] = [:]
    @State private var vibeAwaitingFeedback: VibeAwaitingFeedback?
    @State private var commentsSheetPullRequest: MergedPullRequest?
    @State private var commentsSheetWeeklyEdition: WeeklyEdition?
    @State private var detailSheetPullRequest: MergedPullRequest?
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

    init(
        viewer: FeedViewer,
        repositoryFullName: String,
        signInSession: GitHubSignInSession,
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
        let feedStore = MergedPullRequestFeedStore(
            githubAPIClient: githubAPIClient,
            analytics: viewer.analytics,
            viewerGitHubLogin: viewer.githubLogin,
            handleRejectedGitHubAccess: handleRejectedGitHubAccess
        )
        let weeklyEditionsStore = WeeklyEditionsStore(
            githubAPIClient: githubAPIClient,
            analytics: viewer.analytics,
            handleRejectedGitHubAccess: handleRejectedGitHubAccess
        )
        _feedStore = State(initialValue: feedStore)
        _weeklyEditionsStore = State(initialValue: weeklyEditionsStore)
        _vibeOutbox = State(initialValue: VibeOutbox(
            githubAPIClient: githubAPIClient,
            analytics: viewer.analytics,
            viewerGitHubLogin: viewer.githubLogin,
            feedStore: feedStore,
            weeklyEditionsStore: weeklyEditionsStore,
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

    private var feedContext: FeedContext {
        switch feedMode {
        case .perPullRequest: .pullRequests
        case .weekly: openWeeklyEdition == nil ? .weeklyEditions : .openWeek
        }
    }

    // What people the viewer hid wrote or posted leaves every page, so page indexes count only what's shown (AGENTS.md, "Report And Hide").
    private var visiblePullRequests: [MergedPullRequest] {
        feedStore.pullRequests.compactMap { $0.withoutHiddenPeople(viewer.hiddenPeopleStore) }
    }

    private var visibleWeeklyEditions: [WeeklyEdition] {
        weeklyEditionsStore.weeklyEditions.compactMap { $0.withoutHiddenPeople(viewer.hiddenPeopleStore) }
    }

    private var visibleOpenWeekPullRequests: [MergedPullRequest] {
        feedStore.openWeekPullRequests.compactMap { $0.withoutHiddenPeople(viewer.hiddenPeopleStore) }
    }

    private var feedPages: [FeedPage] {
        switch feedContext {
        case .pullRequests: visiblePullRequests.map(FeedPage.pullRequest) + [.feedEnd]
        case .weeklyEditions: visibleWeeklyEditions.map(FeedPage.weeklyEdition) + [.feedEnd]
        case .openWeek: visibleOpenWeekPullRequests.map(FeedPage.pullRequest) + [.feedEnd]
        }
    }

    // Each context keeps its own place, so switching modes or closing a week returns to the card the viewer left.
    private var currentPageIndex: Int {
        get {
            switch feedContext {
            case .pullRequests: pullRequestsPageIndex
            case .weeklyEditions: weeklyEditionsPageIndex
            case .openWeek: openWeekPageIndex
            }
        }
        nonmutating set {
            switch feedContext {
            case .pullRequests: pullRequestsPageIndex = newValue
            case .weeklyEditions: weeklyEditionsPageIndex = newValue
            case .openWeek: openWeekPageIndex = newValue
            }
        }
    }

    private var clampedPageIndex: Int {
        min(max(currentPageIndex, 0), feedPages.count - 1)
    }

    private var isPullToRefreshRunning: Bool {
        switch feedContext {
        case .pullRequests, .openWeek: feedStore.isPullToRefreshRunning
        case .weeklyEditions: weeklyEditionsStore.isPullToRefreshRunning
        }
    }

    private var nextPageOffsetSign: CGFloat {
        FeedSwipeGestureMapping.direction(for: .showNextPullRequest) == .up ? 1 : -1
    }

    private var isFeedCovered: Bool {
        detailSheetPullRequest != nil || mediaDeckPullRequestID != nil || selectedTab != .feed
    }

    private var isHeroOccludedForAnalytics: Bool {
        commentsSheetPullRequest != nil || commentsSheetWeeklyEdition != nil
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
                            feedModeSwitch(pageSize: pageGeometry.size, pageChromeInsets: pageChromeInsets)
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
            .overlay(alignment: .top) {
                newerPullRequestsButton
                    .animation(.snappy, value: feedStore.unseenNewerPullRequestIDs.isEmpty)
            }
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
                            if newSelectedTab == .inbox, promptsSignIn(for: .inbox) { return }
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
                    try await githubAPIClient.fetchMergedPullRequest(number: number)
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
                onThreadChanged: { changedWeeklyEdition in weeklyEditionsStore.applyFetchedWeeklyEdition(changedWeeklyEdition) }
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
        .task { await feedStore.loadFeed() }
        .task { await feedStore.runLiveRefreshLoop() }
        .task { await inboxStore?.runLiveRefreshLoop() }
        .task { await userSettingsStore?.refresh() }
        .onAppear { focusPage(at: currentPageIndex) }
        .onChange(of: currentPageIndex) { _, newPageIndex in
            focusPage(at: newPageIndex)
        }
        .onChange(of: feedContext) {
            postVibeAwaitingFeedback()
            focusPage(at: currentPageIndex)
        }
        .onChange(of: selectedTab) { _, newSelectedTab in
            if newSelectedTab != .feed { postVibeAwaitingFeedback() }
        }
        .onChange(of: visiblePullRequests.map(\.id)) { previousPullRequestIDs, currentPullRequestIDs in
            keepPullRequestsPageInPlace(previousPullRequestIDs: previousPullRequestIDs, currentPullRequestIDs: currentPullRequestIDs)
        }
        .onChange(of: visibleWeeklyEditions.map(\.id)) { previousWeeklyEditionIDs, currentWeeklyEditionIDs in
            guard previousWeeklyEditionIDs.indices.contains(weeklyEditionsPageIndex),
                  let movedPageIndex = currentWeeklyEditionIDs.firstIndex(of: previousWeeklyEditionIDs[weeklyEditionsPageIndex])
            else { return }
            weeklyEditionsPageIndex = movedPageIndex
        }
        .onChange(of: scenePhase) { _, newScenePhase in
            switch newScenePhase {
            case .active:
                Task { await feedStore.refreshAfterReturningToForeground() }
                if feedContext == .weeklyEditions {
                    Task { await weeklyEditionsStore.refreshIfMediaURLsAreStale() }
                }
                Task { await inboxStore?.refresh() }
                Task { await userSettingsStore?.refresh() }
            case .background:
                postVibeAwaitingFeedback()
                vibeOutbox.postAllQueuedVibesBeforeSuspension()
                feedStore.saveFeed()
            default:
                break
            }
        }
        .confirmingHide(of: $postedContentAwaitingHideConfirmation) { postedContent in
            viewer.hiddenPeopleStore.hide(postedContent.postedBy)
            viewer.analytics.capture(.personHidden(postedContent, control: .feedRail))
        }
        .demoSignInPrompt($demoSignInPromptAction, signInSession: signInSession)
        .environment(\.shipTokAnalytics, viewer.analytics)
        .environment(\.signedInGitHubAccessTokenVault, viewer.teammate?.accessTokenVault)
        .environment(playbackRateChoice)
    }

    @ViewBuilder
    private var newerPullRequestsButton: some View {
        let visiblePullRequests = self.visiblePullRequests
        let unseenNewerPageIndexes = visiblePullRequests.indices.filter { feedStore.unseenNewerPullRequestIDs.contains(visiblePullRequests[$0].id) }
        if feedContext == .pullRequests, let firstUnseenNewerPageIndex = unseenNewerPageIndexes.first, firstUnseenNewerPageIndex < currentPageIndex {
            let unseenNewerPullRequestCount = unseenNewerPageIndexes.count
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
            .padding(.top, 8)
            .accessibilityLabel(unseenNewerPullRequestCount == 1 ? "1 newly merged PR above" : "\(unseenNewerPullRequestCount) newly merged PRs above")
            .transition(.scale.combined(with: .opacity))
        }
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
                            await feedStore.saveFeed()?.value
                            onChooseRepository(repositoryFullName)
                        }
                    )
                }
            case .demoVisitor(let demoVisitor):
                DemoSettingsView(demoVisitor: demoVisitor, signInSession: signInSession)
            }
        }
    }

    // Over the card's top left, inside the format's top safe zone, and never under the status bar (AGENTS.md, "Weekly Mode").
    private func feedModeSwitch(pageSize: CGSize, pageChromeInsets: EdgeInsets) -> some View {
        let cardFrame = FeedCardView.cardFrame(in: pageSize, pageChromeInsets: pageChromeInsets).card
        return FeedModeSwitch(
            feedMode: Binding(get: { feedMode }, set: { feedMode = $0 }),
            openWeekDatesText: feedContext == .openWeek ? openWeeklyEdition?.weekDatesText : nil,
            onCloseWeek: closeWeek
        )
        .offset(
            x: cardFrame.minX + Self.feedModeSwitchInsetInCard.width,
            y: max(cardFrame.minY + Self.feedModeSwitchInsetInCard.height, pageChromeInsets.top + Self.feedModeSwitchMinimumGapBelowSafeArea)
        )
        .opacity(vibeAwaitingFeedback == nil ? 1 : 0)
    }

    @ViewBuilder
    private func feedContent(pageSize: CGSize, pageChromeInsets: EdgeInsets) -> some View {
        switch feedContext {
        case .pullRequests:
            pullRequestsFeedContent(pageSize: pageSize, pageChromeInsets: pageChromeInsets)
        case .weeklyEditions:
            weeklyEditionsFeedContent(pageSize: pageSize, pageChromeInsets: pageChromeInsets)
        case .openWeek:
            openWeekFeedContent(pageSize: pageSize, pageChromeInsets: pageChromeInsets)
        }
    }

    @ViewBuilder
    private func weeklyEditionsFeedContent(pageSize: CGSize, pageChromeInsets: EdgeInsets) -> some View {
        if !weeklyEditionsStore.weeklyEditions.isEmpty {
            feedDeck(deckSize: pageSize, pageChromeInsets: pageChromeInsets)
        } else if let loadFailureMessage = weeklyEditionsStore.loadFailureMessage {
            RevylContentUnavailableView(
                systemImageName: "exclamationmark.triangle",
                title: Text("Couldn't load the weekly videos"),
                message: Text(verbatim: loadFailureMessage),
                actionTitle: Text("Try again"),
                action: { Task { await weeklyEditionsStore.retryLoad() } }
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
    private func openWeekFeedContent(pageSize: CGSize, pageChromeInsets: EdgeInsets) -> some View {
        if !feedStore.openWeekPullRequests.isEmpty {
            feedDeck(deckSize: pageSize, pageChromeInsets: pageChromeInsets)
        } else if let openWeekLoadFailureMessage = feedStore.openWeekLoadFailureMessage, let openWeeklyEdition {
            RevylContentUnavailableView(
                systemImageName: "exclamationmark.triangle",
                title: Text("Couldn't load this week's pull requests"),
                message: Text(verbatim: openWeekLoadFailureMessage),
                actionTitle: Text("Try again"),
                action: { feedStore.openWeek(pullRequestNumbers: openWeeklyEdition.pullRequestNumbers) }
            )
        } else if !feedStore.isOpenWeekLoaded {
            FeedLoadingView(message: "Loading the week's pull requests…")
        } else {
            RevylContentUnavailableView(
                systemImageName: "rectangle.stack",
                title: Text("None of this week's pull requests could be read"),
                message: Text("They may be private to you or no longer merged."),
                actionTitle: Text("Back to weekly videos"),
                action: closeWeek
            )
        }
    }

    @ViewBuilder
    private func pullRequestsFeedContent(pageSize: CGSize, pageChromeInsets: EdgeInsets) -> some View {
        if !feedStore.pullRequests.isEmpty {
            feedDeck(deckSize: pageSize, pageChromeInsets: pageChromeInsets)
        } else if let failureMessage = feedStore.feedLoadFailureMessage {
            RevylContentUnavailableView(
                systemImageName: "exclamationmark.triangle",
                title: Text("Couldn't load merged PRs"),
                message: Text(verbatim: failureMessage),
                actionTitle: Text("Try again"),
                action: { Task { await feedStore.loadFeed() } }
            )
        } else if !feedStore.isFeedWindowLoaded {
            FeedLoadingView(message: "Finding merged PRs with videos and screenshots…")
        } else {
            RevylContentUnavailableView(
                systemImageName: "film.stack",
                title: Text("No PRs with media yet"),
                message: Text("ShipTok shows pull requests merged into \(githubAPIClient.repositoryFullName) in the last two weeks that carry a video, screenshot or GIF. None do yet.")
            )
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
                recoverFromHeroMediaLoadFailure: { failedHeroMediaItem in
                    Task { await feedStore.recoverFromMediaLoadFailure(of: failedHeroMediaItem, onPullRequestID: pullRequest.id) }
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
                likeUnlessAlreadyLiked: { Task { await weeklyEditionsStore.likeUnlessAlreadyLiked(weeklyEditionID: weeklyEdition.id) } },
                toggleReaction: { reaction in Task { await weeklyEditionsStore.toggleReaction(reaction, weeklyEditionID: weeklyEdition.id) } },
                openComments: { commentsSheetWeeklyEdition = weeklyEditionsStore.weeklyEditions.first { $0.id == weeklyEdition.id } ?? weeklyEdition },
                openDeck: { openWeek(weeklyEdition) },
                tapCaption: { openWeek(weeklyEdition) },
                recoverFromHeroMediaLoadFailure: { failedHeroMediaItem in
                    Task { await weeklyEditionsStore.recoverFromMediaLoadFailure(of: failedHeroMediaItem) }
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
        recoverFromHeroMediaLoadFailure: @escaping (PullRequestMediaItem) -> Void
    ) -> FeedCardView {
        let thread = post.thread
        let vibeTarget = post.vibeTarget
        let analyticsSubject = vibeTarget.analyticsSubject
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
            isPlaybackActive: isCurrentPage && scenePhase == .active && !isFeedCovered,
            isOccludedForAnalytics: isHeroOccludedForAnalytics,
            horizontalDragProgress: isCurrentPage ? horizontalDragOffset / max(deckSize.width, 1) : 0,
            likeBurstTrigger: likeBurstTriggers[thread.id, default: 0],
            onDoubleTap: {
                guard !promptsSignIn(for: .like) else { return }
                showLikeBurst(onPostID: thread.id)
                viewer.analytics.capture(.likeSelected(analyticsSubject, control: .doubleTap, wasLiked: thread.reactions.viewerReactions.contains(.heart)))
                likeUnlessAlreadyLiked()
            },
            onToggleLike: {
                guard !promptsSignIn(for: .like) else { return }
                likeHapticTrigger += 1
                viewer.analytics.capture(.likeSelected(analyticsSubject, control: .feedRail, wasLiked: thread.reactions.viewerReactions.contains(.heart)))
                toggleReaction(.heart)
            },
            onToggleReaction: { reaction in
                guard !promptsSignIn(for: .reaction) else { return }
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
                guard !promptsSignIn(for: .report) else { return }
                viewer.analytics.capture(.contentReportOpened(postedContent, control: .feedRail))
                openURL(postedContent.githubReportURL)
            },
            onHide: { postedContent in postedContentAwaitingHideConfirmation = postedContent }
        )
    }

    @ViewBuilder
    private var feedEndPage: some View {
        switch feedContext {
        case .pullRequests:
            FeedEndPageView(
                repositoryFullName: githubAPIClient.repositoryFullName,
                feedLoadFailureMessage: feedStore.feedLoadFailureMessage,
                isFeedWindowLoaded: feedStore.isFeedWindowLoaded,
                onRetry: { Task { await feedStore.loadFeed() } }
            )
        case .weeklyEditions:
            RevylContentUnavailableView(
                systemImageName: "checkmark.seal.fill",
                title: Text("That's every weekly video"),
                message: Text("A new one lands after each week ends, Monday to Sunday.")
            )
            .background(RevylBrandColor.canvas)
        case .openWeek:
            if feedStore.isOpenWeekLoaded {
                RevylContentUnavailableView(
                    systemImageName: "checkmark.seal.fill",
                    title: Text("That's the week of \(openWeeklyEdition?.weekDatesText ?? "")"),
                    message: Text("You've seen every pull request in this week's video."),
                    actionTitle: Text("Back to weekly videos"),
                    action: closeWeek
                )
                .background(RevylBrandColor.canvas)
            } else {
                FeedLoadingView(message: "Loading the rest of the week…")
                    .background(RevylBrandColor.canvas)
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
        }
        .frame(maxWidth: Self.toastMaximumWidth)
        .padding(.leading, 16)
        .padding(.trailing, Self.cardRailClearanceWidth)
        .padding(.bottom, 10)
        .animation(.snappy, value: vibeOutbox.undoableVibe?.id)
        .animation(.snappy, value: vibeOutbox.failedVibe?.id)
        .animation(.snappy, value: feedStore.transientErrorMessage)
        .animation(.snappy, value: weeklyEditionsStore.transientErrorMessage)
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
        case .pullRequests: Task { await feedStore.refreshFromPull() }
        case .weeklyEditions: Task { await weeklyEditionsStore.refreshFromPull() }
        case .openWeek: Task { await feedStore.refreshOpenWeekFromPull() }
        }
    }

    private func focusPage(at pageIndex: Int) {
        switch feedContext {
        case .pullRequests:
            focusPullRequestsPage(at: pageIndex)
        case .weeklyEditions:
            Task { await weeklyEditionsStore.refreshIfMediaURLsAreStale() }
        case .openWeek:
            let visibleOpenWeekPullRequests = self.visibleOpenWeekPullRequests
            guard visibleOpenWeekPullRequests.indices.contains(pageIndex) else { return }
            feedStore.focusOpenWeekPage(showingPullRequestID: visibleOpenWeekPullRequests[pageIndex].id)
        }
    }

    private func focusPullRequestsPage(at pageIndex: Int) {
        let visiblePullRequests = self.visiblePullRequests
        feedStore.focusFeedPage(showingPullRequestID: visiblePullRequests.indices.contains(pageIndex) ? visiblePullRequests[pageIndex].id : nil)
    }

    private func openWeek(_ weeklyEdition: WeeklyEdition) {
        openWeekPageIndex = 0
        openWeeklyEdition = weeklyEdition
        feedStore.openWeek(pullRequestNumbers: weeklyEdition.pullRequestNumbers)
    }

    private func closeWeek() {
        withAnimation(.spring(duration: 0.3)) { openWeeklyEdition = nil }
        feedStore.closeWeek()
    }

    // A vibe from the rail leaves the same way as a swipe, toward that vibe's swipe direction, so both ways read as one gesture.
    private func flingCard(of vibeTarget: VibeTarget, castingVibe vibe: PullRequestVibe, deckWidth: CGFloat) {
        guard !promptsSignIn(for: .vibe) else {
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

    // A demo visitor is asked to sign in instead of posting to GitHub; true when that's what happened (AGENTS.md, "Demo Mode").
    private func promptsSignIn(for action: DemoSignInPromptAction) -> Bool {
        guard case .demoVisitor(let demoVisitor) = viewer else { return false }
        demoVisitor.analytics.capture(.demoSignInPrompted(action))
        demoSignInPromptAction = action
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

    // Only a page of the context on screen comes back; a vibe from another mode or week stays where it was cast.
    private func showPage(withID pageID: String) {
        guard let pageIndex = feedPages.firstIndex(where: { $0.id == pageID }) else { return }
        withAnimation(.spring(duration: 0.35)) { currentPageIndex = pageIndex }
    }

    private func keepPullRequestsPageInPlace(previousPullRequestIDs: [String], currentPullRequestIDs: [String]) {
        let isShowingPullRequests = feedContext == .pullRequests
        guard previousPullRequestIDs.indices.contains(pullRequestsPageIndex) else {
            if isShowingPullRequests { focusPullRequestsPage(at: pullRequestsPageIndex) }
            return
        }
        let currentPullRequestID = previousPullRequestIDs[pullRequestsPageIndex]
        if let movedPageIndex = currentPullRequestIDs.firstIndex(of: currentPullRequestID) {
            if movedPageIndex != pullRequestsPageIndex {
                pullRequestsPageIndex = movedPageIndex
            }
        } else {
            pullRequestsPageIndex = min(pullRequestsPageIndex, currentPullRequestIDs.count)
            if isShowingPullRequests { focusPullRequestsPage(at: pullRequestsPageIndex) }
        }
    }

    private func openPullRequest(number: Int) {
        guard let pageIndex = visiblePullRequests.firstIndex(where: { $0.number == number }) else {
            openURL(githubAPIClient.pullRequestURL(number: number))
            return
        }
        feedMode = .perPullRequest
        selectedTab = .feed
        pullRequestsPageIndex = pageIndex
    }
}

private struct MediaDeckCoverContent: View {
    let feedStore: MergedPullRequestFeedStore
    let viewer: FeedViewer
    let signInSession: GitHubSignInSession
    let pullRequestID: String
    @State private var postedContentAwaitingHideConfirmation: GitHubPostedContent?
    @State private var demoSignInPromptAction: DemoSignInPromptAction?
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    private var visiblePullRequest: MergedPullRequest? {
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
                    demoVisitor.analytics.capture(.demoSignInPrompted(.report))
                    demoSignInPromptAction = .report
                    return
                }
                viewer.analytics.capture(.contentReportOpened(postedContent, control: .mediaDeck))
                openURL(postedContent.githubReportURL)
            },
            onHide: { postedContent in postedContentAwaitingHideConfirmation = postedContent },
            onLoadFailure: { failedMediaItem in
                Task { await feedStore.recoverFromMediaLoadFailure(of: failedMediaItem, onPullRequestID: pullRequestID) }
            }
        )
        .confirmingHide(of: $postedContentAwaitingHideConfirmation) { postedContent in
            viewer.hiddenPeopleStore.hide(postedContent.postedBy)
            viewer.analytics.capture(.personHidden(postedContent, control: .mediaDeck))
            if visiblePullRequest == nil { dismiss() }
        }
        .demoSignInPrompt($demoSignInPromptAction, signInSession: signInSession)
    }
}

private struct DetailSheetContent: View {
    let feedStore: MergedPullRequestFeedStore
    let vibeOutbox: VibeOutbox
    let viewer: FeedViewer
    let signInSession: GitHubSignInSession
    let repositoryFullName: String
    let presentedPullRequest: MergedPullRequest
    @State private var postedContentAwaitingHideConfirmation: GitHubPostedContent?
    @State private var demoSignInPromptAction: DemoSignInPromptAction?
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let storedPullRequest = feedStore.pullRequest(withID: presentedPullRequest.id) ?? presentedPullRequest
        let pullRequest = storedPullRequest.withoutHiddenPeople(viewer.hiddenPeopleStore) ?? storedPullRequest
        MergedPullRequestDetailSheet(
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
                    guard !promptsSignIn(for: .report) else { return }
                    viewer.analytics.capture(.contentReportOpened(postedContent, control: .detailSheet))
                    openURL(postedContent.githubReportURL)
                },
                onHide: { postedContent in postedContentAwaitingHideConfirmation = postedContent }
            ),
            onToggleReaction: { reaction in
                guard !promptsSignIn(for: .reaction) else { return }
                Task { await feedStore.toggleReaction(reaction, pullRequestID: pullRequest.id) }
            }
        )
        .confirmingHide(of: $postedContentAwaitingHideConfirmation) { postedContent in
            viewer.hiddenPeopleStore.hide(postedContent.postedBy)
            viewer.analytics.capture(.personHidden(postedContent, control: .detailSheet))
            dismiss()
        }
        .demoSignInPrompt($demoSignInPromptAction, signInSession: signInSession)
    }

    private func promptsSignIn(for action: DemoSignInPromptAction) -> Bool {
        guard case .demoVisitor(let demoVisitor) = viewer else { return false }
        demoVisitor.analytics.capture(.demoSignInPrompted(action))
        demoSignInPromptAction = action
        return true
    }
}
