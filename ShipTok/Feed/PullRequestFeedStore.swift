import Foundation
import Observation
import OSLog

// One pull request feed as loaded so far, and where the viewer is in it.
struct LoadedPullRequestFeed: Sendable {
    let feed: PullRequestFeed
    fileprivate(set) var pullRequests: [PullRequest] = []
    fileprivate(set) var unseenNewerPullRequestIDs: Set<String> = []
    // Set once the newest page is in, from the saved feeds or GitHub: every update before it is applied.
    fileprivate(set) var everyUpdateAppliedBefore: Date?
    fileprivate(set) var hasLoadedEveryPullRequest = false
    fileprivate(set) var loadFailureMessage: String?
    fileprivate(set) var isPullToRefreshRunning = false
    fileprivate(set) var focusedPullRequestID: String?
    fileprivate(set) var isFeedEndFocused = false
    // A card that left its feed while under the viewer's finger, which goes once the viewer moves on.
    fileprivate var pullRequestIDsLeavingOnceUnfocused: Set<String> = []
    // A card out of feed order because it was on screen, or next, when it changed or arrived; it takes its slot once the viewer moves on (AGENTS.md, "Feed Order").
    fileprivate var pullRequestIDsMovingOnceUnrendered: Set<String> = []

    var isNewestPageLoaded: Bool {
        everyUpdateAppliedBefore != nil
    }

    func index(ofPullRequestID pullRequestID: String) -> Int? {
        pullRequests.firstIndex { $0.id == pullRequestID }
    }

    fileprivate var focusedPageIndex: Int {
        if let focusedPullRequestID, let focusedIndex = index(ofPullRequestID: focusedPullRequestID) {
            return focusedIndex
        }
        return isFeedEndFocused ? pullRequests.count : 0
    }

    fileprivate var hasFocusedPage: Bool {
        focusedPullRequestID != nil || isFeedEndFocused
    }

    // The focused card and the one after it are already rendered under the viewer's finger, so a newly found card never lands above or between them unless it's flagged as unseen (AGENTS.md, "Feed Order").
    private var firstUnrenderedPageIndex: Int {
        hasFocusedPage ? min(focusedPageIndex + 2, pullRequests.count) : 0
    }

    private var renderedPullRequestIDs: Set<String> {
        guard let focusedPullRequestID, let focusedIndex = index(ofPullRequestID: focusedPullRequestID) else { return [] }
        return Set(pullRequests[focusedIndex..<min(focusedIndex + 2, pullRequests.count)].map(\.id))
    }

    // A newly found card can take a slot anywhere above the viewer, so the first unseen one can be anywhere (AGENTS.md, "Feed Order").
    private var firstUnseenNewerPageIndex: Int? {
        pullRequests.firstIndex { unseenNewerPullRequestIDs.contains($0.id) }
    }

    // Nil focuses the feed's end.
    fileprivate mutating func focus(showingPullRequestID newFocusedPullRequestID: String?) {
        let previouslyFocusedPullRequestID = focusedPullRequestID
        defer { moveCardsNoLongerRendered(justLeftPullRequestID: previouslyFocusedPullRequestID) }
        focusedPullRequestID = newFocusedPullRequestID
        isFeedEndFocused = newFocusedPullRequestID == nil && !pullRequests.isEmpty
        if let firstUnseenNewerPageIndex, focusedPageIndex <= firstUnseenNewerPageIndex {
            unseenNewerPullRequestIDs.removeAll()
        } else if let newFocusedPullRequestID {
            unseenNewerPullRequestIDs.remove(newFocusedPullRequestID)
        }
        if let newFocusedPullRequestID {
            pullRequestIDsLeavingOnceUnfocused.remove(newFocusedPullRequestID)
        }
        guard !pullRequestIDsLeavingOnceUnfocused.isEmpty else { return }
        pullRequests.removeAll { pullRequestIDsLeavingOnceUnfocused.contains($0.id) }
        unseenNewerPullRequestIDs.subtract(pullRequestIDsLeavingOnceUnfocused)
        pullRequestIDsLeavingOnceUnfocused.removeAll()
    }

    // A pull request found after the feed opened, or one whose update moves it, takes its sorted slot. At or above the viewer it's flagged for the "new" pill; below, it never goes above the two cards already rendered, and waits there until the viewer moves on. One that sorts below every loaded card is left for its own page unless it may go last (AGENTS.md, "Feed Order").
    @discardableResult
    fileprivate mutating func insertIntoFeedOrder(_ pullRequest: PullRequest, mayGoLast: Bool = true, flagsUnseenAboveViewer: Bool = true) -> Bool {
        guard let feedOrderIndex = pullRequests.firstIndex(where: { !pullRequestIDsMovingOnceUnrendered.contains($0.id) && pullRequest.comesBefore($0, in: feed) })
            ?? (mayGoLast ? pullRequests.count : nil)
        else {
            return false
        }
        if hasFocusedPage, feedOrderIndex <= focusedPageIndex {
            pullRequests.insert(pullRequest, at: feedOrderIndex)
            if flagsUnseenAboveViewer {
                unseenNewerPullRequestIDs.insert(pullRequest.id)
            }
        } else {
            let insertionIndex = max(feedOrderIndex, firstUnrenderedPageIndex)
            pullRequests.insert(pullRequest, at: insertionIndex)
            if insertionIndex != feedOrderIndex {
                pullRequestIDsMovingOnceUnrendered.insert(pullRequest.id)
            }
        }
        return true
    }

    // An older page's card goes below every loaded card, or takes its slot like a newly found one when it was updated after the cards below it were read (AGENTS.md, "Feed Order").
    fileprivate mutating func appendInFeedOrder(_ olderPullRequest: PullRequest) {
        if let lastPlacedPullRequest = pullRequests.last(where: { !pullRequestIDsMovingOnceUnrendered.contains($0.id) }),
           olderPullRequest.comesBefore(lastPlacedPullRequest, in: feed) {
            insertIntoFeedOrder(olderPullRequest)
        } else {
            pullRequests.append(olderPullRequest)
        }
    }

    // An update that changes a card's slot moves it there; a card on screen, or next, keeps its slot until the viewer moves on (AGENTS.md, "Feed Order").
    fileprivate mutating func replace(_ updatedPullRequest: PullRequest, at existingIndex: Int) {
        pullRequests[existingIndex] = updatedPullRequest
        guard !pullRequestIDsMovingOnceUnrendered.contains(updatedPullRequest.id), !isInFeedOrder(at: existingIndex) else { return }
        if renderedPullRequestIDs.contains(updatedPullRequest.id) {
            pullRequestIDsMovingOnceUnrendered.insert(updatedPullRequest.id)
            return
        }
        pullRequests.remove(at: existingIndex)
        insertIntoFeedOrder(updatedPullRequest)
    }

    private func isInFeedOrder(at pullRequestIndex: Int) -> Bool {
        let pullRequest = pullRequests[pullRequestIndex]
        let previousPlacedPullRequest = pullRequests[..<pullRequestIndex].last { !pullRequestIDsMovingOnceUnrendered.contains($0.id) }
        let nextPlacedPullRequest = pullRequests[(pullRequestIndex + 1)...].first { !pullRequestIDsMovingOnceUnrendered.contains($0.id) }
        return (previousPlacedPullRequest.map { $0.comesBefore(pullRequest, in: feed) } ?? true)
            && (nextPlacedPullRequest.map { pullRequest.comesBefore($0, in: feed) } ?? true)
    }

    // The card the viewer just left was on screen when it changed, so it moves without the "new" pill (AGENTS.md, "Feed Order").
    private mutating func moveCardsNoLongerRendered(justLeftPullRequestID: String?) {
        let movingPullRequestIDs = pullRequestIDsMovingOnceUnrendered.subtracting(renderedPullRequestIDs)
        guard !movingPullRequestIDs.isEmpty else { return }
        pullRequestIDsMovingOnceUnrendered.subtract(movingPullRequestIDs)
        for movingPullRequestID in movingPullRequestIDs {
            guard let movingIndex = index(ofPullRequestID: movingPullRequestID) else { continue }
            let movingPullRequest = pullRequests.remove(at: movingIndex)
            insertIntoFeedOrder(movingPullRequest, flagsUnseenAboveViewer: movingPullRequestID != justLeftPullRequestID)
        }
    }

    // The card under the viewer's finger stays until the viewer moves on (AGENTS.md, "Feed Order").
    fileprivate mutating func removePullRequests(where shouldRemove: (PullRequest) -> Bool) {
        if let focusedPullRequestID, let focusedIndex = index(ofPullRequestID: focusedPullRequestID), shouldRemove(pullRequests[focusedIndex]) {
            pullRequestIDsLeavingOnceUnfocused.insert(focusedPullRequestID)
        }
        guard pullRequests.contains(where: { $0.id != focusedPullRequestID && shouldRemove($0) }) else { return }
        pullRequests.removeAll { $0.id != focusedPullRequestID && shouldRemove($0) }
        let remainingPullRequestIDs = Set(pullRequests.map(\.id))
        unseenNewerPullRequestIDs.formIntersection(remainingPullRequestIDs)
        pullRequestIDsMovingOnceUnrendered.formIntersection(remainingPullRequestIDs)
    }
}

// The Open and Merged modes' feeds and a week's open pull requests, read from GitHub and kept current (AGENTS.md, "Feed Order" and "Feed Caching").
@Observable
@MainActor
final class PullRequestFeedStore {
    private static let mediaURLRenewalAgeSeconds: TimeInterval = 120
    private static let updateSearchOverlapSeconds: TimeInterval = 180
    // Older pull requests load once the viewer is this many shown cards from the end, until this many more show (AGENTS.md, "Feed Order").
    private static let olderPullRequestLoadDistanceInCards = 5
    private static let olderPullRequestLoadCardCount = 10
    // GitHub limits how much of its server time one account may take each minute, so a week's pull requests load a few at a time.
    private static let concurrentOpenWeekFetchCount = 6
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "feed")

    private(set) var openFeed = LoadedPullRequestFeed(feed: .open)
    private(set) var mergedFeed = LoadedPullRequestFeed(feed: .merged)
    // Videos only: it filters what's shown, never what's read or saved (AGENTS.md, "Feed Order").
    var showsOnlyPullRequestsWithVideos = true
    var transientErrorMessage: String?
    // The pull requests of the weekly edition whose deck is open, in its video's order (AGENTS.md, "Weekly Mode").
    private(set) var openWeekPullRequests: [PullRequest] = []
    private(set) var isOpenWeekLoaded = false
    private(set) var openWeekLoadFailureMessage: String?
    private(set) var isOpenWeekPullToRefreshRunning = false

    @ObservationIgnored private var openWeekLoadTask: Task<Void, Never>?
    @ObservationIgnored private var focusedOpenWeekPullRequestID: String?
    @ObservationIgnored private var savedFeedsOpening: Task<Void, Never>?
    @ObservationIgnored private var olderPullRequestLoadRunningFeeds: Set<PullRequestFeed> = []
    @ObservationIgnored private var refreshRunningFeeds: Set<PullRequestFeed> = []
    // The merged feed holds every pull request merged since this whole second, the start of its oldest window; nil before its newest page and once it holds every one.
    @ObservationIgnored private var everyMergedPullRequestLoadedSince: Date?
    @ObservationIgnored private var nextOpenPullRequestsPageCursor: String?
    @ObservationIgnored private var savedFeedGeneration = 0
    @ObservationIgnored private var mediaFetchedAtByPullRequestID: [String: Date] = [:]
    private var mediaLoadFailureRecovery = MediaLoadFailureRecovery()
    @ObservationIgnored private var pullRequestIDsRenewingMediaURLsAfterLoadFailure: Set<String> = []
    @ObservationIgnored private var reactionWriteCountByPullRequestID: [String: Int] = [:]
    // A fetch that started before a delete can still return the comment, so a comment the viewer deleted stays out of every later fetch.
    @ObservationIgnored private var viewerDeletedCommentIDs: Set<String> = []
    private let githubAPIClient: GitHubAPIClient
    private let reactionWriteQueue: ViewerReactionWriteQueue
    private let analytics: ShipTokAnalytics
    // A demo visitor has none, and their feeds aren't saved (AGENTS.md, "Demo Mode").
    private let viewerGitHubLogin: String?
    private let hiddenPeopleStore: HiddenPeopleStore
    private let feedCache = PullRequestFeedCache()
    private let feedWork: FeedViewerWork
    private let handleRejectedGitHubAccess: @MainActor (GitHubAPIError) -> Void

    init(
        githubAPIClient: GitHubAPIClient,
        analytics: ShipTokAnalytics,
        viewerGitHubLogin: String?,
        hiddenPeopleStore: HiddenPeopleStore,
        feedWork: FeedViewerWork,
        handleRejectedGitHubAccess: @escaping @MainActor (GitHubAPIError) -> Void
    ) {
        self.githubAPIClient = githubAPIClient
        self.feedWork = feedWork
        reactionWriteQueue = ViewerReactionWriteQueue(githubAPIClient: githubAPIClient)
        self.analytics = analytics
        self.viewerGitHubLogin = viewerGitHubLogin
        self.hiddenPeopleStore = hiddenPeopleStore
        self.handleRejectedGitHubAccess = handleRejectedGitHubAccess
    }

    var unloadableMediaItemIDs: Set<String> {
        mediaLoadFailureRecovery.unloadableMediaItemIDs
    }

    func loadedFeed(_ feed: PullRequestFeed) -> LoadedPullRequestFeed {
        switch feed {
        case .open: openFeed
        case .merged: mergedFeed
        }
    }

    // What people the viewer hid wrote or posted leaves every card, and with Videos only on a card shows only if what's left leads with a video, so only what's shown is counted (AGENTS.md, "Report And Hide" and "Feed Order").
    func visiblePullRequests(in feed: PullRequestFeed) -> [PullRequest] {
        loadedFeed(feed).pullRequests.compactMap(visibleCopy(of:))
    }

    func pullRequest(withID pullRequestID: String) -> PullRequest? {
        mergedFeed.pullRequests.first { $0.id == pullRequestID }
            ?? openFeed.pullRequests.first { $0.id == pullRequestID }
            ?? openWeekPullRequests.first { $0.id == pullRequestID }
    }

    // A week's pull requests show in its video's order as each leading one arrives, so a page never moves under the viewer. A week names its pull requests by number, so they're read by number.
    func openWeek(pullRequestNumbers: [Int]) {
        openWeekLoadTask?.cancel()
        var seenPullRequestNumbers: Set<Int> = []
        let uniquePullRequestNumbers = pullRequestNumbers.filter { seenPullRequestNumbers.insert($0).inserted }
        openWeekPullRequests = []
        isOpenWeekLoaded = false
        openWeekLoadFailureMessage = nil
        focusedOpenWeekPullRequestID = nil
        openWeekLoadTask = feedWork.start { [self] in await loadOpenWeek(pullRequestNumbers: uniquePullRequestNumbers) }
    }

    func closeWeek() {
        openWeekLoadTask?.cancel()
        openWeekLoadTask = nil
        openWeekPullRequests = []
        isOpenWeekLoaded = false
        openWeekLoadFailureMessage = nil
        focusedOpenWeekPullRequestID = nil
    }

    func focusOpenWeekPage(showingPullRequestID focusedPullRequestID: String) {
        guard let pageIndex = openWeekPullRequests.firstIndex(where: { $0.id == focusedPullRequestID }) else { return }
        focusedOpenWeekPullRequestID = focusedPullRequestID
        let focusedPullRequest = openWeekPullRequests[pageIndex]
        let nextPullRequest = openWeekPullRequests.indices.contains(pageIndex + 1) ? openWeekPullRequests[pageIndex + 1] : nil
        feedWork.start { [self] in
            async let focusedPullRequestRefetch: Void = fetchAndApplyPullRequest(
                number: focusedPullRequest.number,
                forcesMediaURLRenewal: isMediaURLRenewalDue(forPullRequestID: focusedPullRequest.id)
            )
            if let nextPullRequest, isMediaURLRenewalDue(forPullRequestID: nextPullRequest.id) {
                await fetchAndApplyPullRequest(number: nextPullRequest.number, forcesMediaURLRenewal: true)
            }
            await focusedPullRequestRefetch
        }
    }

    func refreshFocusedOpenWeekPullRequest() async {
        await feedWork.perform { [self] in
            guard let focusedOpenWeekPullRequestID, let focusedPullRequest = openWeekPullRequests.first(where: { $0.id == focusedOpenWeekPullRequestID }) else { return }
            await fetchAndApplyPullRequest(number: focusedPullRequest.number, forcesMediaURLRenewal: false)
        }
    }

    // A pull only happens on a week's first card, so that's the card it reads again.
    func refreshOpenWeekFromPull() async {
        await feedWork.perform { [self] in
            guard let firstOpenWeekPullRequest = openWeekPullRequests.first else { return }
            isOpenWeekPullToRefreshRunning = true
            defer { isOpenWeekPullToRefreshRunning = false }
            await fetchAndApplyPullRequest(number: firstOpenWeekPullRequest.number, forcesMediaURLRenewal: false)
        }
    }

    private func loadOpenWeek(pullRequestNumbers: [Int]) async {
        let loadStartedAt = Date.now
        var fetchResultByNumber: [Int: Result<PullRequest, any Error>] = [:]
        var resolvedNumberCount = 0
        var lastFetchError: (any Error)?
        await withTaskGroup(of: (number: Int, fetchResult: Result<PullRequest, any Error>).self) { taskGroup in
            var unrequestedNumbers = ArraySlice(pullRequestNumbers)
            func requestNextPullRequest() {
                guard let number = unrequestedNumbers.popFirst() else { return }
                taskGroup.addTask { [githubAPIClient] in
                    do {
                        return (number, .success(try await githubAPIClient.fetchPullRequest(number: number)))
                    } catch {
                        return (number, .failure(error))
                    }
                }
            }
            for _ in 0..<Self.concurrentOpenWeekFetchCount { requestNextPullRequest() }
            while let (number, fetchResult) = await taskGroup.next() {
                guard !Task.isCancelled else {
                    taskGroup.cancelAll()
                    return
                }
                fetchResultByNumber[number] = fetchResult
                while resolvedNumberCount < pullRequestNumbers.count, let resolvedFetchResult = fetchResultByNumber[pullRequestNumbers[resolvedNumberCount]] {
                    let resolvedNumber = pullRequestNumbers[resolvedNumberCount]
                    resolvedNumberCount += 1
                    switch resolvedFetchResult {
                    case .success(let fetchedPullRequest):
                        if !isInEitherFeed(pullRequestID: fetchedPullRequest.id) {
                            mediaFetchedAtByPullRequestID[fetchedPullRequest.id] = loadStartedAt
                        }
                        openWeekPullRequests.append(fetchedPullRequest)
                    case .failure(let error):
                        if let githubAPIError = error as? GitHubAPIError, githubAPIError.rejectsFeedAccess {
                            handleRejectedGitHubAccess(githubAPIError)
                            taskGroup.cancelAll()
                            return
                        }
                        Self.logger.error("Reading #\(resolvedNumber, privacy: .public) for its week failed: \(error.publicLogDescription, privacy: .public)")
                        lastFetchError = error
                        if let loadedPullRequest = (mergedFeed.pullRequests + openFeed.pullRequests).first(where: { $0.number == resolvedNumber }) {
                            openWeekPullRequests.append(loadedPullRequest)
                        }
                    }
                }
                requestNextPullRequest()
            }
        }
        guard !Task.isCancelled else { return }
        isOpenWeekLoaded = true
        if openWeekPullRequests.isEmpty, let lastFetchError {
            openWeekLoadFailureMessage = lastFetchError.localizedDescription
        }
        Self.logger.info("Read a week's \(self.openWeekPullRequests.count, privacy: .public) of \(pullRequestNumbers.count, privacy: .public) pull requests in \(Self.millisecondsElapsed(since: loadStartedAt), privacy: .public) ms")
    }

    // A launch opens on the saved feeds at once and asks GitHub only for what changed since; a feed with nothing loaded reads its newest page first (AGENTS.md, "Feed Order" and "Feed Caching").
    func refreshNewestData(in feed: PullRequestFeed) async {
        await feedWork.perform { [self] in await refreshNewestData(in: feed, reportsFailure: false) }
    }

    func refreshFromPull(in feed: PullRequestFeed) async {
        await feedWork.perform { [self] in
            updateLoadedFeed(feed) { $0.isPullToRefreshRunning = true }
            defer { updateLoadedFeed(feed) { $0.isPullToRefreshRunning = false } }
            await refreshNewestData(in: feed, reportsFailure: true)
        }
    }

    func loadOlderPullRequests(in feed: PullRequestFeed) async {
        await feedWork.perform { [self] in await loadOlderPullRequestPages(in: feed) }
    }

    // Older pull requests are read a page at a time, each read whole, sorted and put below every card already loaded, so nothing moves under the viewer, until enough more cards show or GitHub has no more (AGENTS.md, "Feed Order").
    private func loadOlderPullRequestPages(in feed: PullRequestFeed) async {
        await openSavedFeedsOnce()
        guard !loadedFeed(feed).hasLoadedEveryPullRequest, olderPullRequestLoadRunningFeeds.insert(feed).inserted else { return }
        defer { olderPullRequestLoadRunningFeeds.remove(feed) }
        if loadedFeed(feed).loadFailureMessage != nil {
            updateLoadedFeed(feed) { $0.loadFailureMessage = nil }
        }
        let loadStartedAt = Date.now
        let visibleCountBeforeLoad = visiblePullRequests(in: feed).count
        do {
            repeat {
                let pageReadStartedAt = Date.now
                let isNewestPage = !loadedFeed(feed).isNewestPageLoaded
                let olderPullRequests: [PullRequest]
                let hasLoadedEveryPullRequest: Bool
                switch feed {
                case .open:
                    let openPullRequestsPage = try await githubAPIClient.fetchOpenPullRequestsPage(after: nextOpenPullRequestsPageCursor)
                    olderPullRequests = openPullRequestsPage.pullRequests
                    nextOpenPullRequestsPageCursor = openPullRequestsPage.nextPageCursor
                    hasLoadedEveryPullRequest = openPullRequestsPage.nextPageCursor == nil
                case .merged:
                    let mergedPullRequestWindow = try await githubAPIClient.fetchMergedPullRequestWindow(mergedBefore: everyMergedPullRequestLoadedSince ?? loadStartedAt)
                    olderPullRequests = mergedPullRequestWindow.pullRequests
                    everyMergedPullRequestLoadedSince = mergedPullRequestWindow.startDate
                    hasLoadedEveryPullRequest = mergedPullRequestWindow.startDate == nil
                }
                let visibleCountBeforePage = visiblePullRequests(in: feed).count
                let addedPullRequestCount = appendOlderPullRequests(olderPullRequests, to: feed, fetchedAt: pageReadStartedAt)
                updateLoadedFeed(feed) { loadedFeed in
                    loadedFeed.hasLoadedEveryPullRequest = hasLoadedEveryPullRequest
                    if loadedFeed.everyUpdateAppliedBefore == nil {
                        loadedFeed.everyUpdateAppliedBefore = loadStartedAt
                    }
                }
                let addedVisiblePullRequestCount = visiblePullRequests(in: feed).count - visibleCountBeforePage
                if !isNewestPage {
                    analytics.capture(.olderPullRequestsLoaded(feed, addedPullRequestCount: addedPullRequestCount, addedVisiblePullRequestCount: addedVisiblePullRequestCount))
                }
                Self.logger.info("Read \(isNewestPage ? "the newest" : "an older", privacy: .public) page of \(feed.rawValue, privacy: .public) pull requests: \(addedPullRequestCount, privacy: .public) more with media in \(Self.millisecondsElapsed(since: pageReadStartedAt), privacy: .public) ms")
            } while !loadedFeed(feed).hasLoadedEveryPullRequest && visiblePullRequests(in: feed).count - visibleCountBeforeLoad < Self.olderPullRequestLoadCardCount
            saveFeeds()
        } catch {
            if error.isTaskCancellation { return }
            if let githubAPIError = error as? GitHubAPIError, githubAPIError.rejectsFeedAccess {
                handleRejectedGitHubAccess(githubAPIError)
                return
            }
            Self.logger.error("Loading \(feed.rawValue, privacy: .public) pull requests failed: \(error.publicLogDescription, privacy: .public)")
            updateLoadedFeed(feed) { $0.loadFailureMessage = error.localizedDescription }
        }
    }

    // Counting only the cards the viewer is shown, so the next page is in before they reach the end (AGENTS.md, "Feed Order").
    func loadOlderPullRequestsIfViewerNearsEnd(in feed: PullRequestFeed) {
        let loadedFeed = loadedFeed(feed)
        guard loadedFeed.isNewestPageLoaded, !loadedFeed.hasLoadedEveryPullRequest, !olderPullRequestLoadRunningFeeds.contains(feed) else { return }
        let pullRequestsAfterFocus = loadedFeed.isFeedEndFocused
            ? []
            : loadedFeed.pullRequests.dropFirst(loadedFeed.focusedPullRequestID == nil ? 0 : loadedFeed.focusedPageIndex + 1)
        guard pullRequestsAfterFocus.filter({ visibleCopy(of: $0) != nil }).count <= Self.olderPullRequestLoadDistanceInCards else { return }
        feedWork.start { [self] in await loadOlderPullRequestPages(in: feed) }
    }

    // The app may be ended once it leaves the screen, so the feeds are saved for the next launch then.
    @discardableResult
    func saveFeeds() -> Task<Void, Never>? {
        guard let viewerGitHubLogin, savedFeedsOpening != nil else { return nil }
        let savedMergedFeed = mergedFeed.everyUpdateAppliedBefore.map { everyUpdateAppliedBefore in
            SavedMergedPullRequestFeed(
                everyUpdateAppliedBefore: everyUpdateAppliedBefore,
                everyMergedPullRequestLoadedSince: everyMergedPullRequestLoadedSince,
                pullRequests: mergedFeed.pullRequests.map(Self.savedCopy(of:))
            )
        }
        let savedOpenFeed = openFeed.everyUpdateAppliedBefore.map { everyUpdateAppliedBefore in
            SavedOpenPullRequestFeed(
                everyUpdateAppliedBefore: everyUpdateAppliedBefore,
                nextPageCursor: nextOpenPullRequestsPageCursor,
                pullRequests: openFeed.pullRequests.map(Self.savedCopy(of:))
            )
        }
        guard savedMergedFeed != nil || savedOpenFeed != nil else { return nil }
        savedFeedGeneration += 1
        let savedFeeds = SavedPullRequestFeeds(
            formatVersion: SavedPullRequestFeeds.currentFormatVersion,
            viewerGitHubLogin: viewerGitHubLogin,
            repositoryFullName: githubAPIClient.repositoryFullName,
            mergedFeed: savedMergedFeed,
            openFeed: savedOpenFeed
        )
        let generation = savedFeedGeneration
        return feedWork.start { [feedCache] in await feedCache.save(savedFeeds, generation: generation) }
    }

    // Nil focuses the feed's end. Pages are named by pull request rather than position, since a feed shows only what people the viewer hid didn't post.
    func focusFeedPage(in feed: PullRequestFeed, showingPullRequestID focusedPullRequestID: String?) {
        updateLoadedFeed(feed) { $0.focus(showingPullRequestID: focusedPullRequestID) }
        loadOlderPullRequestsIfViewerNearsEnd(in: feed)
        feedWork.start { [self] in await refetchPullRequestsAroundFocus(in: feed) }
    }

    func heroMediaItem(of pullRequest: PullRequest) -> PullRequestMediaItem? {
        pullRequest.mediaItems.first { !unloadableMediaItemIDs.contains($0.id) } ?? pullRequest.mediaItems.first
    }

    // A failed load renews the pull request's media URLs at once, and when that read fails, the next one that succeeds settles the failure.
    func recoverFromMediaLoadFailure(of mediaItem: PullRequestMediaItem, onPullRequestID pullRequestID: String, wasRefusedToViewer: Bool) async {
        await feedWork.perform { [self] in
            guard let pullRequest = pullRequest(withID: pullRequestID) else { return }
            defer {
                if let loadedPullRequest = self.pullRequest(withID: pullRequestID) {
                    removeIfNoMediaLoadsAheadOfViewer(loadedPullRequest)
                }
            }
            guard mediaLoadFailureRecovery.recordLoadFailure(of: mediaItem, wasRefusedToViewer: wasRefusedToViewer),
                  pullRequestIDsRenewingMediaURLsAfterLoadFailure.insert(pullRequestID).inserted
            else { return }
            defer { pullRequestIDsRenewingMediaURLsAfterLoadFailure.remove(pullRequestID) }
            await fetchAndApplyPullRequest(number: pullRequest.number, forcesMediaURLRenewal: true)
        }
    }

    // A read made elsewhere has no known start, so it leaves failed media loads for the store's own reads to settle.
    func applyFetchedPullRequest(_ fetchedPullRequest: PullRequest) {
        apply(fetchedPullRequest, fetchedAt: .now, forcesMediaURLRenewal: false, settlesMediaLoadFailures: false)
    }

    func appendComment(_ comment: PullRequestComment, toPullRequestID pullRequestID: String) {
        viewerDeletedCommentIDs.remove(comment.id)
        updateEveryCopy(ofPullRequestID: pullRequestID) { pullRequest in
            if !pullRequest.comments.contains(where: { $0.id == comment.id }) {
                pullRequest.comments.append(comment)
            }
        }
    }

    func removeViewerDeletedComments(withIDs commentIDs: Set<String>, fromPullRequestID pullRequestID: String) {
        viewerDeletedCommentIDs.formUnion(commentIDs)
        updateEveryCopy(ofPullRequestID: pullRequestID) { pullRequest in
            pullRequest.comments.removeAll { commentIDs.contains($0.id) }
        }
    }

    func toggleReaction(_ reaction: GitHubReaction, pullRequestID: String) async {
        guard let pullRequest = pullRequest(withID: pullRequestID) else { return }
        await setViewerReaction(reaction, isReacting: !pullRequest.reactions.viewerReactions.contains(reaction), on: pullRequest)
    }

    func likeUnlessAlreadyLiked(pullRequestID: String) async {
        guard let pullRequest = pullRequest(withID: pullRequestID), !pullRequest.reactions.viewerReactions.contains(.heart) else { return }
        await setViewerReaction(.heart, isReacting: true, on: pullRequest)
    }

    private func updateLoadedFeed(_ feed: PullRequestFeed, _ update: (inout LoadedPullRequestFeed) -> Void) {
        switch feed {
        case .open: update(&openFeed)
        case .merged: update(&mergedFeed)
        }
    }

    private func visibleCopy(of pullRequest: PullRequest) -> PullRequest? {
        guard let visiblePullRequest = pullRequest.withoutHiddenPeople(hiddenPeopleStore),
              !showsOnlyPullRequestsWithVideos || visiblePullRequest.mediaItems.first?.kind == .video
        else { return nil }
        return visiblePullRequest
    }

    private func isInEitherFeed(pullRequestID: String) -> Bool {
        PullRequestFeed.allCases.contains { loadedFeed($0).index(ofPullRequestID: pullRequestID) != nil }
    }

    private func hasLoadableMedia(_ pullRequest: PullRequest) -> Bool {
        pullRequest.mediaItems.contains { !unloadableMediaItemIDs.contains($0.id) }
    }

    private func isMediaURLRenewalDue(forPullRequestID pullRequestID: String) -> Bool {
        Date.now.timeIntervalSince(mediaFetchedAtByPullRequestID[pullRequestID] ?? .distantPast) > Self.mediaURLRenewalAgeSeconds
    }

    // Saved feeds are read once, by whichever feed is shown first, and neither feed loads or refreshes before they are.
    private func openSavedFeedsOnce() async {
        if savedFeedsOpening == nil {
            savedFeedsOpening = Task { await openSavedFeeds() }
        }
        await savedFeedsOpening?.value
    }

    private func openSavedFeeds() async {
        let openStartedAt = Date.now
        guard let viewerGitHubLogin,
              let savedFeeds = await feedCache.loadSavedFeeds(viewerGitHubLogin: viewerGitHubLogin, repositoryFullName: githubAPIClient.repositoryFullName)
        else { return }
        if let savedMergedFeed = savedFeeds.mergedFeed {
            everyMergedPullRequestLoadedSince = savedMergedFeed.everyMergedPullRequestLoadedSince
            updateLoadedFeed(.merged) { loadedFeed in
                loadedFeed.pullRequests = savedMergedFeed.pullRequests.filter { $0.belongs(in: .merged) }.sorted { $0.comesBefore($1, in: .merged) }
                loadedFeed.everyUpdateAppliedBefore = savedMergedFeed.everyUpdateAppliedBefore
                loadedFeed.hasLoadedEveryPullRequest = savedMergedFeed.everyMergedPullRequestLoadedSince == nil
            }
        }
        if let savedOpenFeed = savedFeeds.openFeed {
            nextOpenPullRequestsPageCursor = savedOpenFeed.nextPageCursor
            updateLoadedFeed(.open) { loadedFeed in
                loadedFeed.pullRequests = savedOpenFeed.pullRequests.filter { $0.belongs(in: .open) }.sorted { $0.comesBefore($1, in: .open) }
                loadedFeed.everyUpdateAppliedBefore = savedOpenFeed.everyUpdateAppliedBefore
                loadedFeed.hasLoadedEveryPullRequest = savedOpenFeed.nextPageCursor == nil
            }
        }
        Self.logger.info("Opened on \(self.mergedFeed.pullRequests.count, privacy: .public) saved merged and \(self.openFeed.pullRequests.count, privacy: .public) saved open pull requests in \(Self.millisecondsElapsed(since: openStartedAt), privacy: .public) ms")
    }

    private func refreshNewestData(in feed: PullRequestFeed, reportsFailure: Bool) async {
        await openSavedFeedsOnce()
        guard let everyUpdateAppliedBefore = loadedFeed(feed).everyUpdateAppliedBefore else {
            await loadOlderPullRequestPages(in: feed)
            return
        }
        guard refreshRunningFeeds.insert(feed).inserted else { return }
        defer {
            refreshRunningFeeds.remove(feed)
            loadOlderPullRequestsIfViewerNearsEnd(in: feed)
        }
        if let focusedPullRequestID = loadedFeed(feed).focusedPullRequestID, let focusedPullRequest = pullRequest(withID: focusedPullRequestID) {
            await fetchAndApplyPullRequest(number: focusedPullRequest.number, forcesMediaURLRenewal: false)
        }
        let refreshStartedAt = Date.now
        let earliestUpdateDate = everyUpdateAppliedBefore.addingTimeInterval(-Self.updateSearchOverlapSeconds)
        do {
            let updatedPullRequestCount: Int
            switch feed {
            case .open:
                updatedPullRequestCount = try await applyOpenPullRequestUpdates(since: earliestUpdateDate, fetchedAt: refreshStartedAt)
            case .merged:
                updatedPullRequestCount = try await applyMergedPullRequestUpdates(since: earliestUpdateDate, fetchedAt: refreshStartedAt)
            }
            try Task.checkCancellation()
            Self.logger.debug("Read \(updatedPullRequestCount, privacy: .public) \(feed.rawValue, privacy: .public) pull requests updated since \(everyUpdateAppliedBefore.formatted(.iso8601), privacy: .public) in \(Self.millisecondsElapsed(since: refreshStartedAt), privacy: .public) ms")
            updateLoadedFeed(feed) { $0.everyUpdateAppliedBefore = refreshStartedAt }
        } catch {
            if error.isTaskCancellation { return }
            if let githubAPIError = error as? GitHubAPIError, githubAPIError.rejectsFeedAccess {
                handleRejectedGitHubAccess(githubAPIError)
                return
            }
            Self.logger.error("Refreshing \(feed.rawValue, privacy: .public) pull requests failed: \(error.publicLogDescription, privacy: .public)")
            if reportsFailure {
                transientErrorMessage = "Couldn't refresh. \(error.localizedDescription)"
            }
        }
    }

    // Every merged pull request in the loaded merge-date range updated since the last refresh, or in every merge date once the feed holds them all.
    private func applyMergedPullRequestUpdates(since earliestUpdateDate: Date, fetchedAt refreshStartedAt: Date) async throws -> Int {
        let updatedPullRequestSearch = try await githubAPIClient.searchMergedPullRequests(
            updatedSince: earliestUpdateDate,
            mergedFrom: everyMergedPullRequestLoadedSince,
            mergedThrough: refreshStartedAt
        )
        var updatedPullRequestCount = 0
        for try await updatedPullRequestPage in updatedPullRequestSearch {
            for updatedPullRequest in updatedPullRequestPage.sorted(by: { !$0.comesBefore($1, in: .merged) }) {
                apply(updatedPullRequest, fetchedAt: refreshStartedAt, forcesMediaURLRenewal: false)
            }
            updatedPullRequestCount += updatedPullRequestPage.count
        }
        return updatedPullRequestCount
    }

    // A pull request that closed or merged leaves Open; every open one updated since the last refresh is read in full and moves its card to its new slot or takes its slot as a new one.
    private func applyOpenPullRequestUpdates(since earliestUpdateDate: Date, fetchedAt refreshStartedAt: Date) async throws -> Int {
        let closedOrMergedPullRequestIDs = Set(try await githubAPIClient.fetchIDsOfPullRequestsUpdated(since: earliestUpdateDate, inStates: [.closed, .merged]))
        updateLoadedFeed(.open) { $0.removePullRequests { closedOrMergedPullRequestIDs.contains($0.id) } }
        let updatedOpenPullRequestIDs = try await githubAPIClient.fetchIDsOfPullRequestsUpdated(since: earliestUpdateDate, inStates: [.open])
        let updatedOpenPullRequests = try await githubAPIClient.fetchPullRequests(ids: updatedOpenPullRequestIDs)
        for updatedPullRequest in updatedOpenPullRequests.sorted(by: { !$0.comesBefore($1, in: .open) }) {
            apply(updatedPullRequest, fetchedAt: refreshStartedAt, forcesMediaURLRenewal: false)
        }
        return closedOrMergedPullRequestIDs.count + updatedOpenPullRequests.count
    }

    private func appendOlderPullRequests(_ olderPullRequests: [PullRequest], to feed: PullRequestFeed, fetchedAt: Date) -> Int {
        var appendedPullRequestCount = 0
        for olderPullRequest in olderPullRequests.sorted(by: { $0.comesBefore($1, in: feed) }) {
            if loadedFeed(feed).index(ofPullRequestID: olderPullRequest.id) != nil {
                apply(olderPullRequest, fetchedAt: fetchedAt, forcesMediaURLRenewal: false)
            } else if olderPullRequest.belongs(in: feed), hasLoadableMedia(olderPullRequest) {
                mediaFetchedAtByPullRequestID[olderPullRequest.id] = fetchedAt
                updateLoadedFeed(feed) { $0.appendInFeedOrder(olderPullRequest) }
                appendedPullRequestCount += 1
            }
        }
        return appendedPullRequestCount
    }

    // A pull request none of whose media loads leaves each feed while the viewer is still above it (AGENTS.md, "Feed Order").
    private func removeIfNoMediaLoadsAheadOfViewer(_ pullRequest: PullRequest) {
        guard !hasLoadableMedia(pullRequest) else { return }
        for feed in PullRequestFeed.allCases {
            let loadedFeed = loadedFeed(feed)
            guard let pullRequestIndex = loadedFeed.index(ofPullRequestID: pullRequest.id), pullRequestIndex > loadedFeed.focusedPageIndex else { continue }
            updateLoadedFeed(feed) { $0.removePullRequests { $0.id == pullRequest.id } }
        }
    }

    private func refetchPullRequestsAroundFocus(in feed: PullRequestFeed) async {
        let loadedFeed = loadedFeed(feed)
        guard let focusedPullRequestID = loadedFeed.focusedPullRequestID, let focusedIndex = loadedFeed.index(ofPullRequestID: focusedPullRequestID) else { return }
        let focusedPullRequest = loadedFeed.pullRequests[focusedIndex]
        async let focusedPullRequestRefetch: Void = fetchAndApplyPullRequest(
            number: focusedPullRequest.number,
            forcesMediaURLRenewal: isMediaURLRenewalDue(forPullRequestID: focusedPullRequest.id)
        )
        if loadedFeed.pullRequests.indices.contains(focusedIndex + 1) {
            let nextPullRequest = loadedFeed.pullRequests[focusedIndex + 1]
            if isMediaURLRenewalDue(forPullRequestID: nextPullRequest.id) {
                await fetchAndApplyPullRequest(number: nextPullRequest.number, forcesMediaURLRenewal: true)
            }
        }
        await focusedPullRequestRefetch
    }

    private func fetchAndApplyPullRequest(number: Int, forcesMediaURLRenewal: Bool) async {
        let fetchStartedAt = Date.now
        do {
            let fetchedPullRequest = try await githubAPIClient.fetchPullRequest(number: number)
            apply(fetchedPullRequest, fetchedAt: fetchStartedAt, forcesMediaURLRenewal: forcesMediaURLRenewal)
        } catch GitHubAPIError.pullRequestNeitherOpenNorMerged {
            for feed in PullRequestFeed.allCases where loadedFeed(feed).pullRequests.contains(where: { $0.number == number }) {
                updateLoadedFeed(feed) { $0.removePullRequests { $0.number == number } }
            }
            Self.logger.info("#\(number, privacy: .public) is closed without merging or gone, so its card leaves the feed")
        } catch {
            if error.isTaskCancellation { return }
            if let githubAPIError = error as? GitHubAPIError, githubAPIError.rejectsFeedAccess {
                handleRejectedGitHubAccess(githubAPIError)
                return
            }
            Self.logger.error("Refetching #\(number, privacy: .public) failed: \(error.publicLogDescription, privacy: .public)")
        }
    }

    private func apply(_ fetchedPullRequest: PullRequest, fetchedAt: Date, forcesMediaURLRenewal: Bool, settlesMediaLoadFailures: Bool = true) {
        let renewedMediaItemIDs = settlesMediaLoadFailures && mediaLoadFailureRecovery.hasPendingLoadFailure
            ? mediaLoadFailureRecovery.settleLoadFailures(of: fetchedPullRequest.mediaItems, readStartedAt: fetchedAt)
            : []
        removeIfNoMediaLoadsAheadOfViewer(fetchedPullRequest)
        if let openWeekIndex = openWeekPullRequests.firstIndex(where: { $0.id == fetchedPullRequest.id }) {
            openWeekPullRequests[openWeekIndex] = keepingLocalWrites(of: openWeekPullRequests[openWeekIndex], in: fetchedPullRequest)
            if !isInEitherFeed(pullRequestID: fetchedPullRequest.id) {
                mediaFetchedAtByPullRequestID[fetchedPullRequest.id] = fetchedAt
            }
        }
        for feed in PullRequestFeed.allCases {
            apply(fetchedPullRequest, to: feed, fetchedAt: fetchedAt, forcesMediaURLRenewal: forcesMediaURLRenewal, renewedMediaItemIDs: renewedMediaItemIDs)
        }
    }

    // A loaded card updates and moves to its new slot, and the focused one keeps its signed media URLs so a playing video isn't reloaded; a load failure renews them. A merged pull request merged before the loaded range waits for its own page.
    private func apply(_ fetchedPullRequest: PullRequest, to feed: PullRequestFeed, fetchedAt: Date, forcesMediaURLRenewal: Bool, renewedMediaItemIDs: Set<String>) {
        let loadedFeed = loadedFeed(feed)
        guard let existingIndex = loadedFeed.index(ofPullRequestID: fetchedPullRequest.id) else {
            guard loadedFeed.isNewestPageLoaded, fetchedPullRequest.belongs(in: feed), hasLoadableMedia(fetchedPullRequest) else { return }
            let mayGoLast = switch feed {
            case .open: loadedFeed.hasLoadedEveryPullRequest || loadedFeed.pullRequests.isEmpty
            case .merged: everyMergedPullRequestLoadedSince.map { (fetchedPullRequest.mergedAt ?? .distantPast) >= $0 } ?? true
            }
            var isInserted = false
            updateLoadedFeed(feed) { isInserted = $0.insertIntoFeedOrder(fetchedPullRequest, mayGoLast: mayGoLast) }
            if isInserted {
                mediaFetchedAtByPullRequestID[fetchedPullRequest.id] = fetchedAt
            }
            return
        }
        let existingPullRequest = loadedFeed.pullRequests[existingIndex]
        let isFocused = existingPullRequest.id == loadedFeed.focusedPullRequestID
        if !fetchedPullRequest.belongs(in: feed), !isFocused {
            updateLoadedFeed(feed) { $0.removePullRequests { $0.id == fetchedPullRequest.id } }
            return
        }
        var updatedPullRequest = keepingLocalWrites(of: existingPullRequest, in: fetchedPullRequest)
        if forcesMediaURLRenewal || !isFocused {
            mediaFetchedAtByPullRequestID[fetchedPullRequest.id] = fetchedAt
        } else {
            let existingMediaItemsByID = Dictionary(
                existingPullRequest.mediaItems.filter { $0.url != nil && !renewedMediaItemIDs.contains($0.id) }.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            updatedPullRequest.mediaItems = fetchedPullRequest.mediaItems.map { fetchedMediaItem in
                guard let existingMediaItem = existingMediaItemsByID[fetchedMediaItem.id] else { return fetchedMediaItem }
                return PullRequestMediaItem(
                    id: fetchedMediaItem.id,
                    kind: fetchedMediaItem.kind,
                    url: existingMediaItem.url,
                    isShipTokVideo: fetchedMediaItem.isShipTokVideo,
                    sourceCommentID: fetchedMediaItem.sourceCommentID,
                    sourceCommentDatabaseID: fetchedMediaItem.sourceCommentDatabaseID,
                    postedBy: fetchedMediaItem.postedBy,
                    sourceLastEditedAt: fetchedMediaItem.sourceLastEditedAt
                )
            }
        }
        if updatedPullRequest != existingPullRequest {
            updateLoadedFeed(feed) { $0.replace(updatedPullRequest, at: existingIndex) }
        }
        if !fetchedPullRequest.belongs(in: feed) {
            updateLoadedFeed(feed) { $0.removePullRequests { $0.id == fetchedPullRequest.id } }
        }
    }

    // GitHub can answer with a reaction still in flight or a comment the viewer just deleted, so the local copy wins for those.
    private func keepingLocalWrites(of existingPullRequest: PullRequest, in fetchedPullRequest: PullRequest) -> PullRequest {
        var updatedPullRequest = fetchedPullRequest
        updatedPullRequest.comments.removeAll { viewerDeletedCommentIDs.contains($0.id) }
        if reactionWriteCountByPullRequestID[fetchedPullRequest.id, default: 0] > 0 {
            updatedPullRequest.reactions = existingPullRequest.reactions
        }
        return updatedPullRequest
    }

    private func setViewerReaction(_ reaction: GitHubReaction, isReacting: Bool, on pullRequest: PullRequest) async {
        let pullRequestID = pullRequest.id
        let attempt = analytics.requestMutation(.reaction, change: isReacting ? .add : .remove,
            subject: ShipTokAnalyticsSubject(kind: .pullRequest, nodeID: pullRequestID, number: pullRequest.number),
            reaction: reaction)
        updateReactions(ofPullRequestID: pullRequestID) { $0.setViewerHasReacted(isReacting, with: reaction) }
        reactionWriteCountByPullRequestID[pullRequestID, default: 0] += 1
        defer {
            let remainingWriteCount = reactionWriteCountByPullRequestID[pullRequestID, default: 1] - 1
            reactionWriteCountByPullRequestID[pullRequestID] = remainingWriteCount > 0 ? remainingWriteCount : nil
        }
        switch await reactionWriteQueue.write(reaction, viewerHasReacted: isReacting, onSubjectID: pullRequestID) {
        case .succeeded:
            analytics.capture(.mutationCompleted(attempt, outcome: .succeeded, commentID: nil, commentDatabaseID: nil))
        case .failed(let error, let restoredViewerHasReacted):
            analytics.capture(.mutationCompleted(attempt, outcome: error.isTaskCancellation ? .cancelled : .failed,
                                                  commentID: nil, commentDatabaseID: nil))
            if let restoredViewerHasReacted {
                updateReactions(ofPullRequestID: pullRequestID) { $0.setViewerHasReacted(restoredViewerHasReacted, with: reaction) }
            }
            if error.isTaskCancellation { return }
            if let githubAPIError = error as? GitHubAPIError, githubAPIError.rejectsFeedAccess {
                handleRejectedGitHubAccess(githubAPIError)
                return
            }
            let failedAction = switch (reaction, isReacting) {
            case (.heart, true): "like #\(pullRequest.number)"
            case (.heart, false): "unlike #\(pullRequest.number)"
            case (_, true): "react \(reaction.emoji) to #\(pullRequest.number)"
            case (_, false): "remove \(reaction.emoji) from #\(pullRequest.number)"
            }
            transientErrorMessage = "Couldn't \(failedAction). \(error.localizedDescription)"
        }
    }

    private func updateReactions(ofPullRequestID pullRequestID: String, _ update: (inout GitHubReactionSummary) -> Void) {
        updateEveryCopy(ofPullRequestID: pullRequestID) { update(&$0.reactions) }
    }

    // A pull request can be in a feed and in the open week at once, and every change shows on each of its cards.
    private func updateEveryCopy(ofPullRequestID pullRequestID: String, _ update: (inout PullRequest) -> Void) {
        if let openWeekIndex = openWeekPullRequests.firstIndex(where: { $0.id == pullRequestID }) {
            update(&openWeekPullRequests[openWeekIndex])
        }
        for feed in PullRequestFeed.allCases {
            guard let pullRequestIndex = loadedFeed(feed).index(ofPullRequestID: pullRequestID) else { continue }
            updateLoadedFeed(feed) { update(&$0.pullRequests[pullRequestIndex]) }
        }
    }

    // A saved feed holds no description, comment or credential (AGENTS.md, "Feed Caching").
    private static func savedCopy(of pullRequest: PullRequest) -> PullRequest {
        PullRequest(
            id: pullRequest.id, number: pullRequest.number, title: pullRequest.title, url: pullRequest.url,
            author: pullRequest.author, isDraft: pullRequest.isDraft, updatedAt: pullRequest.updatedAt,
            mergedAt: pullRequest.mergedAt, descriptionMarkdown: "",
            additions: pullRequest.additions, deletions: pullRequest.deletions, changedFiles: pullRequest.changedFiles,
            labels: pullRequest.labels, reactions: pullRequest.reactions, comments: [], mediaItems: pullRequest.mediaItems
        )
    }

    private static func millisecondsElapsed(since startDate: Date) -> Int {
        Int(Date.now.timeIntervalSince(startDate) * 1000)
    }
}
