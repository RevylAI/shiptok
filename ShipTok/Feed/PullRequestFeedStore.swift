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
    // The viewer's place, kept while they're in another mode so cards that land above it still raise the "new" pill.
    fileprivate(set) var focusedPullRequestID: String?
    fileprivate(set) var isFeedEndFocused = false
    // From the viewer's first page in the mode until they leave it.
    fileprivate var isOnScreen = false
    // Whether the viewer has moved from one page to another since the mode came on screen; until then the card in focus is the one the mode opened on, not one they chose (AGENTS.md, "Feed Order").
    fileprivate var hasViewerMovedSinceShown = false
    // A card that left its feed while under the viewer's finger, which goes once the viewer moves on.
    fileprivate var pullRequestIDsLeavingOnceUnfocused: Set<String> = []
    // A fresh copy of the focused card that the viewer wouldn't be shown, which takes the shown copy's place once they move on (AGENTS.md, "Feed Order").
    fileprivate var pullRequestsReplacingOnceUnfocused: [String: PullRequest] = [:]
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

    // The focused card and the next card the viewer is shown are already rendered under the viewer's finger, so a newly found card never lands above or between them unless it's flagged as unseen. Cards the viewer isn't shown, hidden or filtered out by Videos only, don't count (AGENTS.md, "Feed Order").
    private func firstUnrenderedPageIndex(isShown: (PullRequest) -> Bool) -> Int {
        guard isOnScreen, hasFocusedPage else { return 0 }
        return nextShownPageIndex(after: focusedPageIndex, isShown: isShown).map { $0 + 1 } ?? pullRequests.count
    }

    private func renderedPullRequestIDs(isShown: (PullRequest) -> Bool) -> Set<String> {
        guard isOnScreen, let focusedPullRequestID, let focusedIndex = index(ofPullRequestID: focusedPullRequestID) else { return [] }
        var renderedPullRequestIDs: Set<String> = [focusedPullRequestID]
        if let nextShownPageIndex = nextShownPageIndex(after: focusedIndex, isShown: isShown) {
            renderedPullRequestIDs.insert(pullRequests[nextShownPageIndex].id)
        }
        return renderedPullRequestIDs
    }

    private func nextShownPageIndex(after pageIndex: Int, isShown: (PullRequest) -> Bool) -> Int? {
        pullRequests.indices.first { $0 > pageIndex && isShown(pullRequests[$0]) }
    }

    // A newly found card can take a slot anywhere above the viewer, so the first unseen one can be anywhere (AGENTS.md, "Feed Order").
    private var firstUnseenNewerPageIndex: Int? {
        pullRequests.firstIndex { unseenNewerPullRequestIDs.contains($0.id) }
    }

    // Nil focuses the feed's end. Only a move to another page lets the cards waiting on the viewer go or move, so being told the same page again changes nothing (AGENTS.md, "Feed Order").
    fileprivate mutating func focus(showingPullRequestID newFocusedPullRequestID: String?, isShown: (PullRequest) -> Bool) {
        let previouslyFocusedPullRequestID = focusedPullRequestID
        let isPageChange = newFocusedPullRequestID != focusedPullRequestID || (newFocusedPullRequestID == nil) != isFeedEndFocused
        hasViewerMovedSinceShown = isOnScreen && (hasViewerMovedSinceShown || (isPageChange && hasFocusedPage))
        isOnScreen = true
        focusedPullRequestID = newFocusedPullRequestID
        isFeedEndFocused = newFocusedPullRequestID == nil && !pullRequests.isEmpty
        if let firstUnseenNewerPageIndex, focusedPageIndex <= firstUnseenNewerPageIndex {
            unseenNewerPullRequestIDs.removeAll()
        } else if let newFocusedPullRequestID {
            unseenNewerPullRequestIDs.remove(newFocusedPullRequestID)
        }
        guard isPageChange else { return }
        settleCardsWaitingOnViewer(justLeftPullRequestID: previouslyFocusedPullRequestID, isShown: isShown)
    }

    // Leaving the mode releases what the viewer's finger held, while the viewer's place stays (AGENTS.md, "Feed Order").
    fileprivate mutating func leaveScreen(isShown: (PullRequest) -> Bool) {
        let justLeftPullRequestID = focusedPullRequestID
        isOnScreen = false
        settleCardsWaitingOnViewer(justLeftPullRequestID: justLeftPullRequestID, isShown: isShown)
    }

    // A card none of whose media loads for this viewer leaves like one that stopped belonging, except the card the mode opened on while the viewer hasn't moved off it: that one goes at once, and the next card the viewer is shown takes its place (AGENTS.md, "Feed Order").
    fileprivate mutating func removePullRequestWithoutLoadableMedia(withID pullRequestID: String, isShown: (PullRequest) -> Bool) {
        guard pullRequestID == focusedPullRequestID, isOnScreen, !hasViewerMovedSinceShown, let focusedIndex = index(ofPullRequestID: pullRequestID) else {
            removePullRequests { $0.id == pullRequestID }
            return
        }
        focusedPullRequestID = nextShownPageIndex(after: focusedIndex, isShown: isShown).map { pullRequests[$0].id }
        pullRequestIDsLeavingOnceUnfocused.remove(pullRequestID)
        pullRequestsReplacingOnceUnfocused[pullRequestID] = nil
        removePullRequests { $0.id == pullRequestID }
        isFeedEndFocused = focusedPullRequestID == nil && !pullRequests.isEmpty
    }

    // The focused card keeps the copy the viewer sees until they move on (AGENTS.md, "Feed Order").
    fileprivate mutating func replaceOnceUnfocused(with freshPullRequest: PullRequest) {
        pullRequestIDsLeavingOnceUnfocused.remove(freshPullRequest.id)
        pullRequestsReplacingOnceUnfocused[freshPullRequest.id] = freshPullRequest
    }

    // A fresh read the viewer can be shown, so the card no longer waits to leave or to give way.
    fileprivate mutating func keepPullRequest(withID pullRequestID: String) {
        pullRequestIDsLeavingOnceUnfocused.remove(pullRequestID)
        pullRequestsReplacingOnceUnfocused[pullRequestID] = nil
    }

    fileprivate func isWaitingOnViewer(pullRequestID: String) -> Bool {
        pullRequestIDsLeavingOnceUnfocused.contains(pullRequestID) || pullRequestsReplacingOnceUnfocused[pullRequestID] != nil
    }

    // The cards as they'll stand once the viewer moves on, which is what the next launch opens on.
    fileprivate var pullRequestsOnceViewerMovesOn: [PullRequest] {
        pullRequests.compactMap { pullRequest in
            pullRequestIDsLeavingOnceUnfocused.contains(pullRequest.id) ? nil : pullRequestsReplacingOnceUnfocused[pullRequest.id] ?? pullRequest
        }
    }

    // What waited on the viewer happens once they move on: a card waiting to leave goes, a fresh copy takes the shown one's place, and held cards take their slots.
    private mutating func settleCardsWaitingOnViewer(justLeftPullRequestID: String?, isShown: (PullRequest) -> Bool) {
        let leavingPullRequestIDs = pullRequestIDsLeavingOnceUnfocused
        pullRequestIDsLeavingOnceUnfocused.removeAll()
        if !leavingPullRequestIDs.isEmpty {
            removePullRequests { leavingPullRequestIDs.contains($0.id) }
        }
        let replacingPullRequests = Array(pullRequestsReplacingOnceUnfocused.values)
        pullRequestsReplacingOnceUnfocused.removeAll()
        for replacingPullRequest in replacingPullRequests {
            guard let replacedIndex = index(ofPullRequestID: replacingPullRequest.id) else { continue }
            pullRequests[replacedIndex] = replacingPullRequest
            if !isInFeedOrder(at: replacedIndex) {
                pullRequestIDsMovingOnceUnrendered.insert(replacingPullRequest.id)
            }
        }
        moveCardsNoLongerRendered(justLeftPullRequestID: justLeftPullRequestID, isShown: isShown)
    }

    // A pull request found after the feed opened, or one whose update moves it, takes its sorted slot. At or above the viewer it's flagged for the "new" pill; below, it never goes above the two cards already rendered, and waits there until the viewer moves on. One that sorts below every loaded card is left for its own page unless it may go last (AGENTS.md, "Feed Order").
    @discardableResult
    fileprivate mutating func insertIntoFeedOrder(_ pullRequest: PullRequest, mayGoLast: Bool = true, flagsUnseenAboveViewer: Bool = true, isShown: (PullRequest) -> Bool) -> Bool {
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
            let insertionIndex = max(feedOrderIndex, firstUnrenderedPageIndex(isShown: isShown))
            pullRequests.insert(pullRequest, at: insertionIndex)
            if insertionIndex != feedOrderIndex {
                pullRequestIDsMovingOnceUnrendered.insert(pullRequest.id)
            }
        }
        return true
    }

    // An older page's card goes below every loaded card, or takes its slot like a newly found one when it was updated after the cards below it were read (AGENTS.md, "Feed Order").
    fileprivate mutating func appendInFeedOrder(_ olderPullRequest: PullRequest, isShown: (PullRequest) -> Bool) {
        if let lastPlacedPullRequest = pullRequests.last(where: { !pullRequestIDsMovingOnceUnrendered.contains($0.id) }),
           olderPullRequest.comesBefore(lastPlacedPullRequest, in: feed) {
            insertIntoFeedOrder(olderPullRequest, isShown: isShown)
        } else {
            pullRequests.append(olderPullRequest)
        }
    }

    // An update that changes a card's slot moves it there; a card on screen, or next, keeps its slot until the viewer moves on (AGENTS.md, "Feed Order").
    fileprivate mutating func replace(_ updatedPullRequest: PullRequest, at existingIndex: Int, isShown: (PullRequest) -> Bool) {
        pullRequests[existingIndex] = updatedPullRequest
        guard !pullRequestIDsMovingOnceUnrendered.contains(updatedPullRequest.id), !isInFeedOrder(at: existingIndex) else { return }
        if renderedPullRequestIDs(isShown: isShown).contains(updatedPullRequest.id) {
            pullRequestIDsMovingOnceUnrendered.insert(updatedPullRequest.id)
            return
        }
        pullRequests.remove(at: existingIndex)
        insertIntoFeedOrder(updatedPullRequest, isShown: isShown)
    }

    private func isInFeedOrder(at pullRequestIndex: Int) -> Bool {
        let pullRequest = pullRequests[pullRequestIndex]
        let previousPlacedPullRequest = pullRequests[..<pullRequestIndex].last { !pullRequestIDsMovingOnceUnrendered.contains($0.id) }
        let nextPlacedPullRequest = pullRequests[(pullRequestIndex + 1)...].first { !pullRequestIDsMovingOnceUnrendered.contains($0.id) }
        return (previousPlacedPullRequest.map { $0.comesBefore(pullRequest, in: feed) } ?? true)
            && (nextPlacedPullRequest.map { pullRequest.comesBefore($0, in: feed) } ?? true)
    }

    // The card the viewer just left was on screen when it changed, so it moves without the "new" pill (AGENTS.md, "Feed Order").
    private mutating func moveCardsNoLongerRendered(justLeftPullRequestID: String?, isShown: (PullRequest) -> Bool) {
        let movingPullRequestIDs = pullRequestIDsMovingOnceUnrendered.subtracting(renderedPullRequestIDs(isShown: isShown))
        guard !movingPullRequestIDs.isEmpty else { return }
        pullRequestIDsMovingOnceUnrendered.subtract(movingPullRequestIDs)
        for movingPullRequestID in movingPullRequestIDs {
            guard let movingIndex = index(ofPullRequestID: movingPullRequestID) else { continue }
            let movingPullRequest = pullRequests.remove(at: movingIndex)
            insertIntoFeedOrder(movingPullRequest, flagsUnseenAboveViewer: movingPullRequestID != justLeftPullRequestID, isShown: isShown)
        }
    }

    // The card under the viewer's finger stays until the viewer moves on. Off screen it goes at once, and the viewer's place moves to the card after it (AGENTS.md, "Feed Order").
    fileprivate mutating func removePullRequests(where shouldRemove: (PullRequest) -> Bool) {
        if let focusedPullRequestID, let focusedIndex = index(ofPullRequestID: focusedPullRequestID), shouldRemove(pullRequests[focusedIndex]) {
            if isOnScreen {
                pullRequestIDsLeavingOnceUnfocused.insert(focusedPullRequestID)
            } else {
                self.focusedPullRequestID = pullRequests[(focusedIndex + 1)...].first { !shouldRemove($0) && !pullRequestIDsMovingOnceUnrendered.contains($0.id) }?.id
                isFeedEndFocused = self.focusedPullRequestID == nil
            }
        }
        let protectedPullRequestID = isOnScreen ? focusedPullRequestID : nil
        guard pullRequests.contains(where: { $0.id != protectedPullRequestID && shouldRemove($0) }) else { return }
        pullRequests.removeAll { $0.id != protectedPullRequestID && shouldRemove($0) }
        let remainingPullRequestIDs = Set(pullRequests.map(\.id))
        unseenNewerPullRequestIDs.formIntersection(remainingPullRequestIDs)
        pullRequestIDsMovingOnceUnrendered.formIntersection(remainingPullRequestIDs)
    }
}

// What the feed view shows of the store: a mode's feed or the open deck of the pull requests a card names, such as a week's (AGENTS.md, "Feed Order").
enum OnScreenPullRequests: Hashable {
    case feed(PullRequestFeed)
    case openDeck
}

// The Open and Merged modes' feeds and the open deck's pull requests, read from GitHub and kept current (AGENTS.md, "Feed Order" and "Feed Caching").
@Observable
@MainActor
final class PullRequestFeedStore {
    private static let mediaURLRenewalAgeSeconds: TimeInterval = 120
    private static let updateSearchOverlapSeconds: TimeInterval = 180
    // Older pull requests load once the viewer is this many shown cards from the end, until this many more show (AGENTS.md, "Feed Order").
    private static let olderPullRequestLoadDistanceInCards = 5
    private static let olderPullRequestLoadCardCount = 10
    // GitHub limits how much of its server time one account may take each minute, so a deck's pull requests load a few at a time.
    private static let concurrentOpenDeckFetchCount = 6
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "feed")

    private(set) var openFeed = LoadedPullRequestFeed(feed: .open)
    private(set) var mergedFeed = LoadedPullRequestFeed(feed: .merged)
    // Videos only: it filters what's shown, never what's read or saved (AGENTS.md, "Feed Order").
    var showsOnlyPullRequestsWithVideos = true
    var transientErrorMessage: String?
    // The pull requests of the card whose deck is open, in its video's order (AGENTS.md, "Weekly Mode").
    private(set) var openDeckPullRequests: [PullRequest] = []
    private(set) var isOpenDeckLoaded = false
    private(set) var openDeckLoadFailureMessage: String?
    private(set) var isOpenDeckPullToRefreshRunning = false

    @ObservationIgnored private var openDeckLoadTask: Task<Void, Never>?
    // The open deck's pull request numbers, how many of them are in or left out so far, and the last read that failed, so a load the deck left off screen carries on where it stopped (AGENTS.md, "Weekly Mode").
    @ObservationIgnored private var openDeckPullRequestNumbers: [Int] = []
    // A feature's deck shows its pull requests with or without media of their own; a week's leaves out those without (AGENTS.md, "Features Mode").
    @ObservationIgnored private var openDeckShowsPullRequestsWithoutMedia = false
    @ObservationIgnored private var openDeckResolvedNumberCount = 0
    @ObservationIgnored private var openDeckLastFetchErrorMessage: String?
    @ObservationIgnored private var focusedOpenDeckPullRequestID: String?
    // Whether the viewer has moved from one card of the open deck to another; until then the card in focus is the one the deck opened on (AGENTS.md, "Weekly Mode").
    @ObservationIgnored private var hasViewerMovedInOpenDeck = false
    // A deck card that closed or lost its last media while under the viewer's finger, which goes once they move on (AGENTS.md, "Weekly Mode").
    @ObservationIgnored private var openDeckPullRequestIDsLeavingOnceUnfocused: Set<String> = []
    @ObservationIgnored private var savedFeedsOpening: Task<Void, Never>?
    @ObservationIgnored private var olderPullRequestLoadRunningFeeds: Set<PullRequestFeed> = []
    @ObservationIgnored private var refreshRunningFeeds: Set<PullRequestFeed> = []
    // The merged feed holds every pull request merged since this whole second, the start of its oldest window; nil before its newest page and once it holds every one.
    @ObservationIgnored private var everyMergedPullRequestLoadedSince: Date?
    @ObservationIgnored private var nextOpenPullRequestsPageCursor: String?
    @ObservationIgnored private var savedFeedGeneration = 0
    @ObservationIgnored private var mediaFetchedAtByPullRequestID: [String: Date] = [:]
    // Each feed's last read of a pull request it took in, its update and merge date, so that feed's refresh doesn't read again what it already has, yet reads one that merged in the second it was read as open (AGENTS.md, "Feed Caching").
    @ObservationIgnored private var appliedUpdatesByFeed: [PullRequestFeed: [String: PullRequestUpdate]] = [:]
    @ObservationIgnored private var onScreenPullRequests: OnScreenPullRequests?
    @ObservationIgnored private var shownModeTasksByID: [UUID: Task<Void, Never>] = [:]
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
            ?? openDeckPullRequests.first { $0.id == pullRequestID }
    }

    // A deck's pull requests show in its video's order as each leading one arrives, so a page never moves under the viewer. A card names its pull requests by number, so they're read by number.
    func openDeck(pullRequestNumbers: [Int], showsPullRequestsWithoutMedia: Bool) {
        openDeckLoadTask?.cancel()
        openDeckLoadTask = nil
        var seenPullRequestNumbers: Set<Int> = []
        openDeckPullRequestNumbers = pullRequestNumbers.filter { seenPullRequestNumbers.insert($0).inserted }
        openDeckShowsPullRequestsWithoutMedia = showsPullRequestsWithoutMedia
        openDeckResolvedNumberCount = 0
        openDeckLastFetchErrorMessage = nil
        openDeckPullRequests = []
        isOpenDeckLoaded = false
        openDeckLoadFailureMessage = nil
        focusedOpenDeckPullRequestID = nil
        hasViewerMovedInOpenDeck = false
        openDeckPullRequestIDsLeavingOnceUnfocused = []
        startOpenDeckLoadIfUnfinished()
    }

    func closeDeck() {
        stopShownModeWork()
        openDeckLoadTask?.cancel()
        openDeckLoadTask = nil
        openDeckPullRequestNumbers = []
        openDeckShowsPullRequestsWithoutMedia = false
        openDeckResolvedNumberCount = 0
        openDeckLastFetchErrorMessage = nil
        openDeckPullRequests = []
        isOpenDeckLoaded = false
        openDeckLoadFailureMessage = nil
        focusedOpenDeckPullRequestID = nil
        hasViewerMovedInOpenDeck = false
        openDeckPullRequestIDsLeavingOnceUnfocused = []
    }

    // A deck shows every card it names whatever Videos only says, less what people the viewer hid wrote or posted (AGENTS.md, "Weekly Mode").
    var visibleOpenDeckPullRequests: [PullRequest] {
        openDeckPullRequests.compactMap(visibleCopyIgnoringVideosOnly(of:))
    }

    // Nil focuses the deck's end, or a deck with no card yet.
    func focusOpenDeckPage(showingPullRequestID focusedPullRequestID: String?) {
        hasViewerMovedInOpenDeck = hasViewerMovedInOpenDeck || (focusedOpenDeckPullRequestID != nil && focusedPullRequestID != focusedOpenDeckPullRequestID)
        if focusedPullRequestID != focusedOpenDeckPullRequestID, !openDeckPullRequestIDsLeavingOnceUnfocused.isEmpty {
            openDeckPullRequests.removeAll { openDeckPullRequestIDsLeavingOnceUnfocused.contains($0.id) }
            openDeckPullRequestIDsLeavingOnceUnfocused.removeAll()
        }
        let visibleOpenDeckPullRequests = visibleOpenDeckPullRequests
        guard let pageIndex = visibleOpenDeckPullRequests.firstIndex(where: { $0.id == focusedPullRequestID }) else {
            focusedOpenDeckPullRequestID = nil
            return
        }
        focusedOpenDeckPullRequestID = focusedPullRequestID
        let focusedPullRequest = visibleOpenDeckPullRequests[pageIndex]
        let nextPullRequest = visibleOpenDeckPullRequests.indices.contains(pageIndex + 1) ? visibleOpenDeckPullRequests[pageIndex + 1] : nil
        startShownModeWork { [self] in
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

    func refreshFocusedOpenDeckPullRequest() async {
        await feedWork.perform { [self] in
            guard let focusedOpenDeckPullRequestID, let focusedPullRequest = openDeckPullRequests.first(where: { $0.id == focusedOpenDeckPullRequestID }) else { return }
            await fetchAndApplyPullRequest(number: focusedPullRequest.number, forcesMediaURLRenewal: false)
        }
    }

    // A pull only happens on a deck's first card, so that's the card it reads again.
    func refreshOpenDeckFromPull() async {
        await feedWork.perform { [self] in
            guard let firstOpenDeckPullRequest = visibleOpenDeckPullRequests.first else { return }
            isOpenDeckPullToRefreshRunning = true
            defer { isOpenDeckPullToRefreshRunning = false }
            await fetchAndApplyPullRequest(number: firstOpenDeckPullRequest.number, forcesMediaURLRenewal: false)
        }
    }

    private func loadOpenDeck() async {
        let loadStartedAt = Date.now
        var fetchResultByNumber: [Int: Result<PullRequest, any Error>] = [:]
        await withTaskGroup(of: (number: Int, fetchResult: Result<PullRequest, any Error>).self) { taskGroup in
            var unrequestedNumbers = openDeckPullRequestNumbers.dropFirst(openDeckResolvedNumberCount)
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
            for _ in 0..<Self.concurrentOpenDeckFetchCount { requestNextPullRequest() }
            while let (number, fetchResult) = await taskGroup.next() {
                guard !Task.isCancelled else {
                    taskGroup.cancelAll()
                    return
                }
                fetchResultByNumber[number] = fetchResult
                while openDeckResolvedNumberCount < openDeckPullRequestNumbers.count, let resolvedFetchResult = fetchResultByNumber[openDeckPullRequestNumbers[openDeckResolvedNumberCount]] {
                    let resolvedNumber = openDeckPullRequestNumbers[openDeckResolvedNumberCount]
                    openDeckResolvedNumberCount += 1
                    switch resolvedFetchResult {
                    case .success(let fetchedPullRequest):
                        guard openDeckShowsPullRequestsWithoutMedia || !fetchedPullRequest.mediaItems.isEmpty, !isEveryMediaItemGivenUp(fetchedPullRequest) else {
                            Self.logger.info("#\(resolvedNumber, privacy: .public) has no media that loads, so its deck leaves it out")
                            continue
                        }
                        if !isInEitherFeed(pullRequestID: fetchedPullRequest.id) {
                            mediaFetchedAtByPullRequestID[fetchedPullRequest.id] = loadStartedAt
                        }
                        openDeckPullRequests.append(fetchedPullRequest)
                    case .failure(GitHubAPIError.pullRequestNeitherOpenNorMerged):
                        Self.logger.info("#\(resolvedNumber, privacy: .public) is closed without merging or gone, so its deck leaves it out")
                    case .failure(let error):
                        if let githubAPIError = error as? GitHubAPIError, githubAPIError.rejectsFeedAccess {
                            handleRejectedGitHubAccess(githubAPIError)
                            taskGroup.cancelAll()
                            return
                        }
                        Self.logger.error("Reading #\(resolvedNumber, privacy: .public) for its deck failed: \(error.publicLogDescription, privacy: .public)")
                        openDeckLastFetchErrorMessage = error.localizedDescription
                        if let loadedPullRequest = (mergedFeed.pullRequestsOnceViewerMovesOn + openFeed.pullRequestsOnceViewerMovesOn).first(where: { $0.number == resolvedNumber }),
                           !isEveryMediaItemGivenUp(loadedPullRequest) {
                            openDeckPullRequests.append(loadedPullRequest)
                        }
                    }
                }
                requestNextPullRequest()
            }
        }
        guard !Task.isCancelled else { return }
        isOpenDeckLoaded = true
        if openDeckPullRequests.isEmpty, let openDeckLastFetchErrorMessage {
            openDeckLoadFailureMessage = openDeckLastFetchErrorMessage
        }
        Self.logger.info("Read a deck's \(self.openDeckPullRequests.count, privacy: .public) of \(self.openDeckPullRequestNumbers.count, privacy: .public) pull requests in \(Self.millisecondsElapsed(since: loadStartedAt), privacy: .public) ms")
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
            } while !loadedFeed(feed).hasLoadedEveryPullRequest && visiblePullRequests(in: feed).count - visibleCountBeforeLoad < Self.olderPullRequestLoadCardCount && feed == shownFeed
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
        guard feed == shownFeed, loadedFeed.isNewestPageLoaded, !loadedFeed.hasLoadedEveryPullRequest, !olderPullRequestLoadRunningFeeds.contains(feed) else { return }
        let pullRequestsAfterFocus = loadedFeed.isFeedEndFocused
            ? []
            : loadedFeed.pullRequests.dropFirst(loadedFeed.focusedPullRequestID == nil ? 0 : loadedFeed.focusedPageIndex + 1)
        guard pullRequestsAfterFocus.filter({ visibleCopy(of: $0) != nil }).count <= Self.olderPullRequestLoadDistanceInCards else { return }
        startShownModeWork { [self] in await loadOlderPullRequestPages(in: feed) }
    }

    // Older pages, the open deck's load and the reads around the focused card belong to what's on screen, so they stop whenever it changes. Nil is Weekly's or Features' list, or Inbox or Settings over the feed (AGENTS.md, "Feed Order" and "Weekly Mode").
    func changeOnScreenPullRequests(to newOnScreenPullRequests: OnScreenPullRequests?) {
        if let previouslyShownFeed = shownFeed, newOnScreenPullRequests != .feed(previouslyShownFeed) {
            updateLoadedFeed(previouslyShownFeed) { loadedFeed in loadedFeed.leaveScreen(isShown: { visibleCopy(of: $0) != nil }) }
        }
        let wasOpenDeckOnScreen = onScreenPullRequests == .openDeck
        onScreenPullRequests = newOnScreenPullRequests
        stopShownModeWork()
        if wasOpenDeckOnScreen, newOnScreenPullRequests != .openDeck {
            leaveOpenDeckScreen()
        } else if !wasOpenDeckOnScreen, newOnScreenPullRequests == .openDeck {
            startOpenDeckLoadIfUnfinished()
        }
    }

    // The app may be ended once it leaves the screen, so the feeds are saved for the next launch then.
    @discardableResult
    func saveFeeds() -> Task<Void, Never>? {
        guard let viewerGitHubLogin, savedFeedsOpening != nil else { return nil }
        let savedMergedFeed = mergedFeed.everyUpdateAppliedBefore.map { everyUpdateAppliedBefore in
            SavedMergedPullRequestFeed(
                everyUpdateAppliedBefore: everyUpdateAppliedBefore,
                everyMergedPullRequestLoadedSince: everyMergedPullRequestLoadedSince,
                pullRequests: mergedFeed.pullRequestsOnceViewerMovesOn.map(Self.savedCopy(of:))
            )
        }
        let savedOpenFeed = openFeed.everyUpdateAppliedBefore.map { everyUpdateAppliedBefore in
            SavedOpenPullRequestFeed(
                everyUpdateAppliedBefore: everyUpdateAppliedBefore,
                nextPageCursor: nextOpenPullRequestsPageCursor,
                pullRequests: openFeed.pullRequestsOnceViewerMovesOn.map(Self.savedCopy(of:))
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
        updateLoadedFeed(feed) { loadedFeed in loadedFeed.focus(showingPullRequestID: focusedPullRequestID, isShown: { visibleCopy(of: $0) != nil }) }
        loadOlderPullRequestsIfViewerNearsEnd(in: feed)
        guard feed == shownFeed else { return }
        startShownModeWork { [self] in await refetchPullRequestsAroundFocus(in: feed) }
    }

    func heroMediaItem(of pullRequest: PullRequest) -> PullRequestMediaItem? {
        pullRequest.mediaItems.first { !unloadableMediaItemIDs.contains($0.id) } ?? pullRequest.mediaItems.first
    }

    // A failed load renews the pull request's media URLs at once while its cards are on screen; otherwise, or when that read fails, the next read that succeeds settles the failure (AGENTS.md, "Signed Media URLs").
    func recoverFromMediaLoadFailure(of mediaItem: PullRequestMediaItem, onPullRequestID pullRequestID: String, wasRefusedToViewer: Bool) {
        guard let pullRequest = pullRequest(withID: pullRequestID) else { return }
        let isURLRenewalNeeded = mediaLoadFailureRecovery.recordLoadFailure(of: mediaItem, wasRefusedToViewer: wasRefusedToViewer)
        removeIfEveryMediaItemGivenUp(pullRequest)
        guard isURLRenewalNeeded, onScreenPullRequests != nil, pullRequestIDsRenewingMediaURLsAfterLoadFailure.insert(pullRequestID).inserted else { return }
        startShownModeWork { [self] in
            await fetchAndApplyPullRequest(number: pullRequest.number, forcesMediaURLRenewal: true)
            pullRequestIDsRenewingMediaURLsAfterLoadFailure.remove(pullRequestID)
            if let loadedPullRequest = self.pullRequest(withID: pullRequestID) {
                removeIfEveryMediaItemGivenUp(loadedPullRequest)
            }
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

    private func startShownModeWork(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        let taskID = UUID()
        guard let task = feedWork.start({ [weak self] in
            await operation()
            self?.shownModeTasksByID[taskID] = nil
        }) else { return }
        shownModeTasksByID[taskID] = task
    }

    // Leaving the deck stops its load and releases what the viewer's finger held, while the viewer's place stays; coming back carries the load on from the first pull request not yet in (AGENTS.md, "Weekly Mode").
    private func leaveOpenDeckScreen() {
        openDeckLoadTask?.cancel()
        openDeckLoadTask = nil
        focusedOpenDeckPullRequestID = nil
        openDeckPullRequests.removeAll { openDeckPullRequestIDsLeavingOnceUnfocused.contains($0.id) }
        openDeckPullRequestIDsLeavingOnceUnfocused.removeAll()
    }

    private func startOpenDeckLoadIfUnfinished() {
        guard onScreenPullRequests == .openDeck, !isOpenDeckLoaded else { return }
        openDeckLoadTask?.cancel()
        openDeckLoadTask = feedWork.start { [self] in await loadOpenDeck() }
    }

    private func stopShownModeWork() {
        for task in shownModeTasksByID.values {
            task.cancel()
        }
        shownModeTasksByID.removeAll()
    }

    private var shownFeed: PullRequestFeed? {
        guard case .feed(let feed) = onScreenPullRequests else { return nil }
        return feed
    }

    private func isUnapplied(_ pullRequestUpdate: PullRequestUpdate, in feed: PullRequestFeed) -> Bool {
        appliedUpdatesByFeed[feed]?[pullRequestUpdate.id] != pullRequestUpdate
    }

    private func recordAppliedUpdate(of pullRequest: PullRequest, in feed: PullRequestFeed) {
        appliedUpdatesByFeed[feed, default: [:]][pullRequest.id] = PullRequestUpdate(id: pullRequest.id, updatedAt: pullRequest.updatedAt, mergedAt: pullRequest.mergedAt)
    }

    private func visibleCopy(of pullRequest: PullRequest) -> PullRequest? {
        guard let visiblePullRequest = visibleCopyIgnoringVideosOnly(of: pullRequest),
              !showsOnlyPullRequestsWithVideos || visiblePullRequest.mediaItems.first?.kind == .video
        else { return nil }
        return visiblePullRequest
    }

    // Hidden people's media can load once they're unhidden, so a pull request whose other media is all given up is only out of sight, the way Hide makes it, and comes back on Unhide (AGENTS.md, "Report And Hide" and "Feed Order").
    private func visibleCopyIgnoringVideosOnly(of pullRequest: PullRequest) -> PullRequest? {
        guard let visiblePullRequest = pullRequest.withoutHiddenPeople(hiddenPeopleStore),
              !isEveryMediaItemGivenUp(visiblePullRequest) || isEveryMediaItemGivenUp(pullRequest)
        else { return nil }
        return visiblePullRequest
    }

    private func isInEitherFeed(pullRequestID: String) -> Bool {
        PullRequestFeed.allCases.contains { loadedFeed($0).index(ofPullRequestID: pullRequestID) != nil }
    }

    // A pull request is dead for this viewer once every media item it holds, hidden people's included, is given up, refused to them or failing again after its renewal. One with no media left isn't: it leaves the way a card that stops belonging does (AGENTS.md, "Feed Order").
    private func isEveryMediaItemGivenUp(_ pullRequest: PullRequest) -> Bool {
        !pullRequest.mediaItems.isEmpty && pullRequest.mediaItems.allSatisfy { unloadableMediaItemIDs.contains($0.id) }
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
            if let demoPullRequests = try await githubAPIClient.fetchDemoFeedPullRequests(in: feed) {
                updatedPullRequestCount = applyDemoFeedSnapshot(demoPullRequests, to: feed, fetchedAt: refreshStartedAt)
            } else {
                switch feed {
                case .open:
                    updatedPullRequestCount = try await applyOpenPullRequestUpdates(since: earliestUpdateDate, fetchedAt: refreshStartedAt)
                case .merged:
                    updatedPullRequestCount = try await applyMergedPullRequestUpdates(since: earliestUpdateDate, fetchedAt: refreshStartedAt)
                }
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

    // Every merged pull request in the loaded merge-date range, or in any once the feed holds them all, updated since the last refresh is read in full, unless the store already read it at that update.
    private func applyMergedPullRequestUpdates(since earliestUpdateDate: Date, fetchedAt refreshStartedAt: Date) async throws -> Int {
        let mergedPullRequestUpdates = try await githubAPIClient.fetchPullRequestUpdates(since: earliestUpdateDate, inStates: [.merged])
        return try await githubAPIClient.fetchPullRequests(ids: mergedPullRequestUpdates.filter { mergedPullRequestUpdate in
            isUnapplied(mergedPullRequestUpdate, in: .merged)
                && everyMergedPullRequestLoadedSince.map { (mergedPullRequestUpdate.mergedAt ?? .distantPast) >= $0 } ?? true
        }.map(\.id)) { [self] updatedPullRequests in
            for updatedPullRequest in updatedPullRequests.sorted(by: { !$0.comesBefore($1, in: .merged) }) {
                apply(updatedPullRequest, fetchedAt: refreshStartedAt, forcesMediaURLRenewal: false)
            }
        }
    }

    // A pull request that closed or merged leaves Open; every open one updated since the last refresh is read in full, unless the store already read it at that update, and moves its card to its new slot or takes its slot as a new one.
    private func applyOpenPullRequestUpdates(since earliestUpdateDate: Date, fetchedAt refreshStartedAt: Date) async throws -> Int {
        let closedOrMergedPullRequestIDs = Set(try await githubAPIClient.fetchPullRequestUpdates(since: earliestUpdateDate, inStates: [.closed, .merged]).map(\.id))
        updateLoadedFeed(.open) { $0.removePullRequests { closedOrMergedPullRequestIDs.contains($0.id) } }
        let openPullRequestUpdates = try await githubAPIClient.fetchPullRequestUpdates(since: earliestUpdateDate, inStates: [.open])
        let updatedOpenPullRequestCount = try await githubAPIClient.fetchPullRequests(ids: openPullRequestUpdates.filter { isUnapplied($0, in: .open) }.map(\.id)) { [self] updatedOpenPullRequests in
            for updatedPullRequest in updatedOpenPullRequests.sorted(by: { !$0.comesBefore($1, in: .open) }) {
                apply(updatedPullRequest, fetchedAt: refreshStartedAt, forcesMediaURLRenewal: false)
            }
        }
        return closedOrMergedPullRequestIDs.count + updatedOpenPullRequestCount
    }

    // The demo is a snapshot of each mode's newest pull requests, so a refresh makes the mode's list match it: a card the snapshot no longer holds leaves, the one under the viewer's finger once they move on, and every card it holds is applied with its fresh media links (AGENTS.md, "Demo Mode").
    private func applyDemoFeedSnapshot(_ demoPullRequests: [PullRequest], to feed: PullRequestFeed, fetchedAt refreshStartedAt: Date) -> Int {
        let demoPullRequestIDs = Set(demoPullRequests.map(\.id))
        updateLoadedFeed(feed) { $0.removePullRequests { !demoPullRequestIDs.contains($0.id) } }
        for demoPullRequest in demoPullRequests.sorted(by: { !$0.comesBefore($1, in: feed) }) {
            apply(demoPullRequest, fetchedAt: refreshStartedAt, forcesMediaURLRenewal: false)
        }
        return demoPullRequests.count
    }

    private func appendOlderPullRequests(_ olderPullRequests: [PullRequest], to feed: PullRequestFeed, fetchedAt: Date) -> Int {
        var appendedPullRequestCount = 0
        for olderPullRequest in olderPullRequests.sorted(by: { $0.comesBefore($1, in: feed) }) {
            recordAppliedUpdate(of: olderPullRequest, in: feed)
            if loadedFeed(feed).index(ofPullRequestID: olderPullRequest.id) != nil {
                apply(olderPullRequest, fetchedAt: fetchedAt, forcesMediaURLRenewal: false)
            } else if olderPullRequest.belongs(in: feed), !isEveryMediaItemGivenUp(olderPullRequest) {
                mediaFetchedAtByPullRequestID[olderPullRequest.id] = fetchedAt
                updateLoadedFeed(feed) { loadedFeed in loadedFeed.appendInFeedOrder(olderPullRequest, isShown: { visibleCopy(of: $0) != nil }) }
                appendedPullRequestCount += 1
            }
        }
        return appendedPullRequestCount
    }

    // A pull request dead for this viewer leaves each feed and the open deck (AGENTS.md, "Feed Order").
    private func removeIfEveryMediaItemGivenUp(_ pullRequest: PullRequest) {
        guard isEveryMediaItemGivenUp(pullRequest) else { return }
        for feed in PullRequestFeed.allCases where loadedFeed(feed).index(ofPullRequestID: pullRequest.id) != nil {
            updateLoadedFeed(feed) { loadedFeed in
                loadedFeed.removePullRequestWithoutLoadableMedia(withID: pullRequest.id, isShown: { visibleCopy(of: $0) != nil })
            }
        }
        if openDeckPullRequests.contains(where: { $0.id == pullRequest.id }) {
            removeFromOpenDeckWithMediaGivenUp(pullRequestID: pullRequest.id)
        }
    }

    // Like a mode, a deck that opened on a dead card skips it at once while the viewer hasn't moved off it, and the next card they're shown takes focus (AGENTS.md, "Weekly Mode").
    private func removeFromOpenDeckWithMediaGivenUp(pullRequestID: String) {
        let visibleOpenDeckPullRequests = visibleOpenDeckPullRequests
        guard pullRequestID == focusedOpenDeckPullRequestID, !hasViewerMovedInOpenDeck,
              let focusedPageIndex = visibleOpenDeckPullRequests.firstIndex(where: { $0.id == pullRequestID })
        else {
            removeFromOpenDeck(pullRequestID: pullRequestID)
            return
        }
        focusedOpenDeckPullRequestID = visibleOpenDeckPullRequests.indices.contains(focusedPageIndex + 1) ? visibleOpenDeckPullRequests[focusedPageIndex + 1].id : nil
        openDeckPullRequestIDsLeavingOnceUnfocused.remove(pullRequestID)
        openDeckPullRequests.removeAll { $0.id == pullRequestID }
    }

    private func refetchPullRequestsAroundFocus(in feed: PullRequestFeed) async {
        let loadedFeed = loadedFeed(feed)
        guard let focusedPullRequestID = loadedFeed.focusedPullRequestID, let focusedIndex = loadedFeed.index(ofPullRequestID: focusedPullRequestID) else { return }
        let focusedPullRequest = loadedFeed.pullRequests[focusedIndex]
        async let focusedPullRequestRefetch: Void = fetchAndApplyPullRequest(
            number: focusedPullRequest.number,
            forcesMediaURLRenewal: isMediaURLRenewalDue(forPullRequestID: focusedPullRequest.id)
        )
        if let nextShownPullRequest = loadedFeed.pullRequests[(focusedIndex + 1)...].first(where: { visibleCopy(of: $0) != nil }),
           isMediaURLRenewalDue(forPullRequestID: nextShownPullRequest.id) {
            await fetchAndApplyPullRequest(number: nextShownPullRequest.number, forcesMediaURLRenewal: true)
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
            if let openDeckPullRequest = openDeckPullRequests.first(where: { $0.number == number }) {
                removeFromOpenDeck(pullRequestID: openDeckPullRequest.id)
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
        removeIfEveryMediaItemGivenUp(fetchedPullRequest)
        if let openDeckIndex = openDeckPullRequests.firstIndex(where: { $0.id == fetchedPullRequest.id }) {
            if openDeckShowsPullRequestsWithoutMedia || !fetchedPullRequest.mediaItems.isEmpty, !isEveryMediaItemGivenUp(fetchedPullRequest) {
                let existingPullRequest = openDeckPullRequests[openDeckIndex]
                var updatedPullRequest = keepingLocalWrites(of: existingPullRequest, in: fetchedPullRequest)
                if fetchedPullRequest.id == focusedOpenDeckPullRequestID && !forcesMediaURLRenewal {
                    updatedPullRequest = keepingMediaURLs(of: existingPullRequest, in: updatedPullRequest, except: renewedMediaItemIDs)
                } else if !isInEitherFeed(pullRequestID: fetchedPullRequest.id) {
                    mediaFetchedAtByPullRequestID[fetchedPullRequest.id] = fetchedAt
                }
                openDeckPullRequests[openDeckIndex] = updatedPullRequest
                openDeckPullRequestIDsLeavingOnceUnfocused.remove(fetchedPullRequest.id)
            } else {
                removeFromOpenDeck(pullRequestID: fetchedPullRequest.id)
            }
        }
        for feed in PullRequestFeed.allCases {
            apply(fetchedPullRequest, to: feed, fetchedAt: fetchedAt, forcesMediaURLRenewal: forcesMediaURLRenewal, renewedMediaItemIDs: renewedMediaItemIDs)
        }
    }

    // A loaded card updates and moves to its new slot, and the focused one keeps its signed media URLs so a playing video isn't reloaded; a load failure renews them. A merged pull request merged before the loaded range waits for its own page.
    private func apply(_ fetchedPullRequest: PullRequest, to feed: PullRequestFeed, fetchedAt: Date, forcesMediaURLRenewal: Bool, renewedMediaItemIDs: Set<String>) {
        let loadedFeed = loadedFeed(feed)
        if loadedFeed.isNewestPageLoaded {
            recordAppliedUpdate(of: fetchedPullRequest, in: feed)
        }
        guard let existingIndex = loadedFeed.index(ofPullRequestID: fetchedPullRequest.id) else {
            guard loadedFeed.isNewestPageLoaded, fetchedPullRequest.belongs(in: feed), !isEveryMediaItemGivenUp(fetchedPullRequest) else { return }
            let mayGoLast = switch feed {
            case .open: loadedFeed.hasLoadedEveryPullRequest || loadedFeed.pullRequests.isEmpty
            case .merged: everyMergedPullRequestLoadedSince.map { (fetchedPullRequest.mergedAt ?? .distantPast) >= $0 } ?? true
            }
            var isInserted = false
            updateLoadedFeed(feed) { loadedFeed in isInserted = loadedFeed.insertIntoFeedOrder(fetchedPullRequest, mayGoLast: mayGoLast, isShown: { visibleCopy(of: $0) != nil }) }
            if isInserted {
                mediaFetchedAtByPullRequestID[fetchedPullRequest.id] = fetchedAt
            }
            return
        }
        let existingPullRequest = loadedFeed.pullRequests[existingIndex]
        let isFocused = existingPullRequest.id == loadedFeed.focusedPullRequestID
        let fetchedPullRequestBelongs = fetchedPullRequest.belongs(in: feed) && !isEveryMediaItemGivenUp(fetchedPullRequest)
        if !fetchedPullRequestBelongs, !isFocused {
            updateLoadedFeed(feed) { $0.removePullRequests { $0.id == fetchedPullRequest.id } }
            return
        }
        var updatedPullRequest = keepingLocalWrites(of: existingPullRequest, in: fetchedPullRequest)
        if !forcesMediaURLRenewal && isFocused {
            updatedPullRequest = keepingMediaURLs(of: existingPullRequest, in: updatedPullRequest, except: renewedMediaItemIDs)
        }
        // A fresh copy the viewer wouldn't be shown, with no media left or no video left under Videos only, never empties or pulls away the card they're on; hiding a person and changing Videos only still apply to the kept copy at once (AGENTS.md, "Feed Order").
        if isFocused, loadedFeed.isOnScreen, visibleCopy(of: existingPullRequest) != nil, !fetchedPullRequestBelongs || visibleCopy(of: updatedPullRequest) == nil {
            updateLoadedFeed(feed) { loadedFeed in
                if fetchedPullRequestBelongs {
                    loadedFeed.replaceOnceUnfocused(with: updatedPullRequest)
                } else {
                    loadedFeed.removePullRequests { $0.id == fetchedPullRequest.id }
                }
            }
            return
        }
        if forcesMediaURLRenewal || !isFocused {
            mediaFetchedAtByPullRequestID[fetchedPullRequest.id] = fetchedAt
        }
        if updatedPullRequest != existingPullRequest {
            updateLoadedFeed(feed) { loadedFeed in loadedFeed.replace(updatedPullRequest, at: existingIndex, isShown: { visibleCopy(of: $0) != nil }) }
        }
        if !fetchedPullRequestBelongs {
            updateLoadedFeed(feed) { $0.removePullRequests { $0.id == fetchedPullRequest.id } }
        } else if loadedFeed.isWaitingOnViewer(pullRequestID: fetchedPullRequest.id) {
            updateLoadedFeed(feed) { $0.keepPullRequest(withID: fetchedPullRequest.id) }
        }
    }

    // GitHub can answer with a reaction still in flight or a comment the viewer just deleted, so the local copy wins for those.
    // The focused card keeps its signed media URLs so a playing video isn't reloaded; an item whose load failed takes its fresh one.
    private func keepingMediaURLs(of existingPullRequest: PullRequest, in updatedPullRequest: PullRequest, except renewedMediaItemIDs: Set<String>) -> PullRequest {
        let existingMediaItemsByID = Dictionary(
            existingPullRequest.mediaItems.filter { $0.url != nil && !renewedMediaItemIDs.contains($0.id) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var pullRequestKeepingMediaURLs = updatedPullRequest
        pullRequestKeepingMediaURLs.mediaItems = updatedPullRequest.mediaItems.map { fetchedMediaItem in
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
        return pullRequestKeepingMediaURLs
    }

    // A deck card under the viewer's finger keeps the copy they see until they move on (AGENTS.md, "Weekly Mode").
    private func removeFromOpenDeck(pullRequestID: String) {
        if pullRequestID == focusedOpenDeckPullRequestID {
            openDeckPullRequestIDsLeavingOnceUnfocused.insert(pullRequestID)
        } else {
            openDeckPullRequests.removeAll { $0.id == pullRequestID }
        }
    }

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

    // A pull request can be in a feed and in the open deck at once, and every change shows on each of its cards.
    private func updateEveryCopy(ofPullRequestID pullRequestID: String, _ update: (inout PullRequest) -> Void) {
        if let openDeckIndex = openDeckPullRequests.firstIndex(where: { $0.id == pullRequestID }) {
            update(&openDeckPullRequests[openDeckIndex])
        }
        for feed in PullRequestFeed.allCases {
            guard let pullRequestIndex = loadedFeed(feed).index(ofPullRequestID: pullRequestID) else { continue }
            updateLoadedFeed(feed) { update(&$0.pullRequests[pullRequestIndex]) }
        }
    }

    // A saved feed holds no description, comment or credential; the title and label names it keeps were redacted when the pull request was read (AGENTS.md, "Feed Caching").
    private static func savedCopy(of pullRequest: PullRequest) -> PullRequest {
        PullRequest(
            id: pullRequest.id, number: pullRequest.number,
            title: pullRequest.title, url: pullRequest.url,
            author: pullRequest.author, isDraft: pullRequest.isDraft, updatedAt: pullRequest.updatedAt,
            mergedAt: pullRequest.mergedAt, descriptionMarkdown: "",
            additions: pullRequest.additions, deletions: pullRequest.deletions, changedFiles: pullRequest.changedFiles,
            labels: pullRequest.labels,
            reactions: pullRequest.reactions, comments: [], mediaItems: pullRequest.mediaItems
        )
    }

    private static func millisecondsElapsed(since startDate: Date) -> Int {
        Int(Date.now.timeIntervalSince(startDate) * 1000)
    }
}
