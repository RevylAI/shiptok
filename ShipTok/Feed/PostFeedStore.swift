import Foundation
import Observation
import OSLog

extension ShipTokPost {
    // Each mode's order, newest first: Open by last update, Merged by merge, Weekly by week, Features by close, and the higher number first on a tie (AGENTS.md, "Feed Order").
    func comesBefore(_ otherPost: ShipTokPost, in feedMode: FeedMode) -> Bool {
        let isNewer: Bool? = switch feedMode {
        case .open: Self.isNewer(pullRequest?.updatedAt, than: otherPost.pullRequest?.updatedAt)
        case .merged: Self.isNewer(pullRequest?.mergedAt, than: otherPost.pullRequest?.mergedAt)
        case .weekly: Self.isNewer(weekStart, than: otherPost.weekStart)
        case .features: Self.isNewer(closedAt, than: otherPost.closedAt)
        }
        return isNewer ?? (githubIssueNumber > otherPost.githubIssueNumber)
    }

    // What a mode holds as Revyl serves it, Videos only aside: a post with media of the mode's kind, and for Open and Merged a pull request in that state.
    func belongs(in feedMode: FeedMode) -> Bool {
        guard !media.isEmpty else { return false }
        return switch feedMode {
        case .open: kind == .pullRequest && pullRequest?.state == .open
        case .merged: kind == .pullRequest && pullRequest?.state == .merged
        case .weekly: kind == .weeklyEdition
        case .features: kind == .feature
        }
    }

    private static func isNewer<SortKey: Comparable>(_ sortKey: SortKey?, than otherSortKey: SortKey?) -> Bool? {
        switch (sortKey, otherSortKey) {
        case (let sortKey?, let otherSortKey?):
            return sortKey == otherSortKey ? nil : sortKey > otherSortKey
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (nil, nil):
            return nil
        }
    }
}

// One mode's feed as loaded so far, and where the viewer is in it.
struct LoadedPostFeed: Sendable {
    let feedMode: FeedMode
    fileprivate(set) var posts: [ShipTokPost] = []
    fileprivate(set) var unseenNewerPostIDs: Set<String> = []
    // Set once the newest page is in, from the saved feeds or Revyl.
    fileprivate(set) var isNewestPageLoaded = false
    // Where the next older page starts; nil before the newest page and once the feed holds every post.
    fileprivate(set) var nextCursor: String?
    fileprivate(set) var hasLoadedEveryPost = false
    // Whether Revyl left out what Videos only hides when it served these posts; nil when that wasn't known yet.
    fileprivate(set) var loadedShowingOnlyPostsWithVideos: Bool?
    fileprivate(set) var loadFailureMessage: String?
    fileprivate(set) var isPullToRefreshRunning = false
    // The viewer's place, kept while they're in another mode so cards that land above it still raise the "new" pill.
    fileprivate(set) var focusedPostID: String?
    fileprivate(set) var isFeedEndFocused = false
    // From the viewer's first page in the mode until they leave it.
    fileprivate var isOnScreen = false
    // Whether the viewer has moved from one page to another since the mode came on screen; until then the card in focus is the one the mode opened on, not one they chose (AGENTS.md, "Feed Order").
    fileprivate var hasViewerMovedSinceShown = false
    // A card that left its feed while under the viewer's finger, which goes once the viewer moves on.
    fileprivate var postIDsLeavingOnceUnfocused: Set<String> = []
    // A fresh copy of the focused card that the viewer wouldn't be shown, which takes the shown copy's place once they move on (AGENTS.md, "Feed Order").
    fileprivate var postsReplacingOnceUnfocused: [String: ShipTokPost] = [:]
    // A card out of feed order because it was on screen, or next, when it changed or arrived; it takes its slot once the viewer moves on (AGENTS.md, "Feed Order").
    fileprivate var postIDsMovingOnceUnrendered: Set<String> = []

    func index(ofPostID postID: String) -> Int? {
        posts.firstIndex { $0.id == postID }
    }

    fileprivate var focusedPageIndex: Int {
        if let focusedPostID, let focusedIndex = index(ofPostID: focusedPostID) {
            return focusedIndex
        }
        return isFeedEndFocused ? posts.count : 0
    }

    fileprivate var hasFocusedPage: Bool {
        focusedPostID != nil || isFeedEndFocused
    }

    // The focused card and the next card the viewer is shown are already rendered under the viewer's finger, so a newly found card never lands above or between them unless it's flagged as unseen. Cards the viewer isn't shown don't count (AGENTS.md, "Feed Order").
    private func firstUnrenderedPageIndex(isShown: (ShipTokPost) -> Bool) -> Int {
        guard isOnScreen, hasFocusedPage else { return 0 }
        return nextShownPageIndex(after: focusedPageIndex, isShown: isShown).map { $0 + 1 } ?? posts.count
    }

    private func renderedPostIDs(isShown: (ShipTokPost) -> Bool) -> Set<String> {
        guard isOnScreen, let focusedPostID, let focusedIndex = index(ofPostID: focusedPostID) else { return [] }
        var renderedPostIDs: Set<String> = [focusedPostID]
        if let nextShownPageIndex = nextShownPageIndex(after: focusedIndex, isShown: isShown) {
            renderedPostIDs.insert(posts[nextShownPageIndex].id)
        }
        return renderedPostIDs
    }

    private func nextShownPageIndex(after pageIndex: Int, isShown: (ShipTokPost) -> Bool) -> Int? {
        posts.indices.first { $0 > pageIndex && isShown(posts[$0]) }
    }

    // A newly found card can take a slot anywhere above the viewer, so the first unseen one can be anywhere (AGENTS.md, "Feed Order").
    private var firstUnseenNewerPageIndex: Int? {
        posts.firstIndex { unseenNewerPostIDs.contains($0.id) }
    }

    // Nil focuses the feed's end. Only a move to another page lets the cards waiting on the viewer go or move, so being told the same page again changes nothing (AGENTS.md, "Feed Order").
    fileprivate mutating func focus(showingPostID newFocusedPostID: String?, isShown: (ShipTokPost) -> Bool) {
        let previouslyFocusedPostID = focusedPostID
        let isPageChange = newFocusedPostID != focusedPostID || (newFocusedPostID == nil) != isFeedEndFocused
        hasViewerMovedSinceShown = isOnScreen && (hasViewerMovedSinceShown || (isPageChange && hasFocusedPage))
        isOnScreen = true
        focusedPostID = newFocusedPostID
        isFeedEndFocused = newFocusedPostID == nil && !posts.isEmpty
        if let firstUnseenNewerPageIndex, focusedPageIndex <= firstUnseenNewerPageIndex {
            unseenNewerPostIDs.removeAll()
        } else if let newFocusedPostID {
            unseenNewerPostIDs.remove(newFocusedPostID)
        }
        guard isPageChange else { return }
        settleCardsWaitingOnViewer(justLeftPostID: previouslyFocusedPostID, isShown: isShown)
    }

    // Leaving the mode releases what the viewer's finger held, while the viewer's place stays (AGENTS.md, "Feed Order").
    fileprivate mutating func leaveScreen(isShown: (ShipTokPost) -> Bool) {
        let justLeftPostID = focusedPostID
        isOnScreen = false
        settleCardsWaitingOnViewer(justLeftPostID: justLeftPostID, isShown: isShown)
    }

    // A card none of whose media loads for this viewer leaves like one that stopped belonging, except the card the mode opened on while the viewer hasn't moved off it: that one goes at once, and the next card the viewer is shown takes its place (AGENTS.md, "Feed Order").
    fileprivate mutating func removePostWithoutLoadableMedia(withID postID: String, isShown: (ShipTokPost) -> Bool) {
        guard postID == focusedPostID, isOnScreen, !hasViewerMovedSinceShown, let focusedIndex = index(ofPostID: postID) else {
            removePosts { $0.id == postID }
            return
        }
        focusedPostID = nextShownPageIndex(after: focusedIndex, isShown: isShown).map { posts[$0].id }
        postIDsLeavingOnceUnfocused.remove(postID)
        postsReplacingOnceUnfocused[postID] = nil
        removePosts { $0.id == postID }
        isFeedEndFocused = focusedPostID == nil && !posts.isEmpty
    }

    // The focused card keeps the copy the viewer sees until they move on (AGENTS.md, "Feed Order").
    fileprivate mutating func replaceOnceUnfocused(with freshPost: ShipTokPost) {
        postIDsLeavingOnceUnfocused.remove(freshPost.id)
        postsReplacingOnceUnfocused[freshPost.id] = freshPost
    }

    // A fresh read the viewer can be shown, so the card no longer waits to leave or to give way.
    fileprivate mutating func keepPost(withID postID: String) {
        postIDsLeavingOnceUnfocused.remove(postID)
        postsReplacingOnceUnfocused[postID] = nil
    }

    fileprivate func isWaitingOnViewer(postID: String) -> Bool {
        postIDsLeavingOnceUnfocused.contains(postID) || postsReplacingOnceUnfocused[postID] != nil
    }

    // The cards as they'll stand once the viewer moves on, which is what the next launch opens on.
    fileprivate var postsOnceViewerMovesOn: [ShipTokPost] {
        posts.compactMap { post in
            postIDsLeavingOnceUnfocused.contains(post.id) ? nil : postsReplacingOnceUnfocused[post.id] ?? post
        }
    }

    // What waited on the viewer happens once they move on: a card waiting to leave goes, a fresh copy takes the shown one's place, and held cards take their slots.
    private mutating func settleCardsWaitingOnViewer(justLeftPostID: String?, isShown: (ShipTokPost) -> Bool) {
        let leavingPostIDs = postIDsLeavingOnceUnfocused
        postIDsLeavingOnceUnfocused.removeAll()
        if !leavingPostIDs.isEmpty {
            removePosts { leavingPostIDs.contains($0.id) }
        }
        let replacingPosts = Array(postsReplacingOnceUnfocused.values)
        postsReplacingOnceUnfocused.removeAll()
        for replacingPost in replacingPosts {
            guard let replacedIndex = index(ofPostID: replacingPost.id) else { continue }
            posts[replacedIndex] = replacingPost
            if !isInFeedOrder(at: replacedIndex) {
                postIDsMovingOnceUnrendered.insert(replacingPost.id)
            }
        }
        moveCardsNoLongerRendered(justLeftPostID: justLeftPostID, isShown: isShown)
    }

    // A post found after the feed opened, or one whose update moves it, takes its sorted slot. At or above the viewer it's flagged for the "new" pill; below, it never goes above the two cards already rendered, and waits there until the viewer moves on. One that sorts below every loaded card is left for its own page unless it may go last (AGENTS.md, "Feed Order").
    @discardableResult
    fileprivate mutating func insertIntoFeedOrder(_ post: ShipTokPost, mayGoLast: Bool = true, flagsUnseenAboveViewer: Bool = true, isShown: (ShipTokPost) -> Bool) -> Bool {
        guard let feedOrderIndex = posts.firstIndex(where: { !postIDsMovingOnceUnrendered.contains($0.id) && post.comesBefore($0, in: feedMode) })
            ?? (mayGoLast ? posts.count : nil)
        else {
            return false
        }
        if hasFocusedPage, feedOrderIndex <= focusedPageIndex {
            posts.insert(post, at: feedOrderIndex)
            if flagsUnseenAboveViewer {
                unseenNewerPostIDs.insert(post.id)
            }
        } else {
            let insertionIndex = max(feedOrderIndex, firstUnrenderedPageIndex(isShown: isShown))
            posts.insert(post, at: insertionIndex)
            if insertionIndex != feedOrderIndex {
                postIDsMovingOnceUnrendered.insert(post.id)
            }
        }
        return true
    }

    // An older page's card goes below every loaded card, or takes its slot like a newly found one when it sorts above the cards already below it (AGENTS.md, "Feed Order").
    fileprivate mutating func appendInFeedOrder(_ olderPost: ShipTokPost, isShown: (ShipTokPost) -> Bool) {
        if let lastPlacedPost = posts.last(where: { !postIDsMovingOnceUnrendered.contains($0.id) }),
           olderPost.comesBefore(lastPlacedPost, in: feedMode) {
            insertIntoFeedOrder(olderPost, isShown: isShown)
        } else {
            posts.append(olderPost)
        }
    }

    // An update that changes a card's slot moves it there; a card on screen, or next, keeps its slot until the viewer moves on (AGENTS.md, "Feed Order").
    fileprivate mutating func replace(_ updatedPost: ShipTokPost, at existingIndex: Int, isShown: (ShipTokPost) -> Bool) {
        posts[existingIndex] = updatedPost
        guard !postIDsMovingOnceUnrendered.contains(updatedPost.id), !isInFeedOrder(at: existingIndex) else { return }
        if renderedPostIDs(isShown: isShown).contains(updatedPost.id) {
            postIDsMovingOnceUnrendered.insert(updatedPost.id)
            return
        }
        posts.remove(at: existingIndex)
        insertIntoFeedOrder(updatedPost, isShown: isShown)
    }

    private func isInFeedOrder(at postIndex: Int) -> Bool {
        let post = posts[postIndex]
        let previousPlacedPost = posts[..<postIndex].last { !postIDsMovingOnceUnrendered.contains($0.id) }
        let nextPlacedPost = posts[(postIndex + 1)...].first { !postIDsMovingOnceUnrendered.contains($0.id) }
        return (previousPlacedPost.map { $0.comesBefore(post, in: feedMode) } ?? true)
            && (nextPlacedPost.map { post.comesBefore($0, in: feedMode) } ?? true)
    }

    // The card the viewer just left was on screen when it changed, so it moves without the "new" pill (AGENTS.md, "Feed Order").
    private mutating func moveCardsNoLongerRendered(justLeftPostID: String?, isShown: (ShipTokPost) -> Bool) {
        let movingPostIDs = postIDsMovingOnceUnrendered.subtracting(renderedPostIDs(isShown: isShown))
        guard !movingPostIDs.isEmpty else { return }
        postIDsMovingOnceUnrendered.subtract(movingPostIDs)
        for movingPostID in movingPostIDs {
            guard let movingIndex = index(ofPostID: movingPostID) else { continue }
            let movingPost = posts.remove(at: movingIndex)
            insertIntoFeedOrder(movingPost, flagsUnseenAboveViewer: movingPostID != justLeftPostID, isShown: isShown)
        }
    }

    // The card under the viewer's finger stays until the viewer moves on. Off screen it goes at once, and the viewer's place moves to the card after it (AGENTS.md, "Feed Order").
    fileprivate mutating func removePosts(where shouldRemove: (ShipTokPost) -> Bool) {
        if let focusedPostID, let focusedIndex = index(ofPostID: focusedPostID), shouldRemove(posts[focusedIndex]) {
            if isOnScreen {
                postIDsLeavingOnceUnfocused.insert(focusedPostID)
            } else {
                self.focusedPostID = posts[(focusedIndex + 1)...].first { !shouldRemove($0) && !postIDsMovingOnceUnrendered.contains($0.id) }?.id
                isFeedEndFocused = self.focusedPostID == nil
            }
        }
        let protectedPostID = isOnScreen ? focusedPostID : nil
        guard posts.contains(where: { $0.id != protectedPostID && shouldRemove($0) }) else { return }
        posts.removeAll { $0.id != protectedPostID && shouldRemove($0) }
        let remainingPostIDs = Set(posts.map(\.id))
        unseenNewerPostIDs.formIntersection(remainingPostIDs)
        postIDsMovingOnceUnrendered.formIntersection(remainingPostIDs)
    }
}

// What the feed view shows of the store: a mode's feed, or the open deck (AGENTS.md, "Feed Order").
enum OnScreenPosts: Hashable {
    case feed(FeedMode)
    case openDeck
}

// What an open deck shows: the pull requests a week's or a feature's video covers, or one post opened from the inbox (AGENTS.md, "Pull Request Decks").
enum PostDeckSource: Hashable {
    case pullRequestsOf(ShipTokPost)
    case post(postID: String)

    // The mode whose tab a deck opens under; one post opens over whichever mode shows.
    var feedMode: FeedMode? {
        switch self {
        case .pullRequestsOf(let deckPost): deckPost.kind == .weeklyEdition ? .weekly : .features
        case .post: nil
        }
    }
}

// Every mode's feed of one repository and the open deck, read from Revyl and kept current (AGENTS.md, "Feed Order" and "Feed Caching").
@Observable
@MainActor
final class PostFeedStore {
    // A signed media link this close to expiring is renewed before the viewer reaches its card (AGENTS.md, "Signed Media URLs").
    private static let mediaURLRenewalLeadSeconds: TimeInterval = 120
    // Older posts load once the viewer is this many shown cards from the end, until this many more show (AGENTS.md, "Feed Order").
    private static let olderPostLoadDistanceInCards = 5
    private static let olderPostLoadCardCount = 10
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "feed")

    private(set) var loadedFeeds: [FeedMode: LoadedPostFeed] = Dictionary(uniqueKeysWithValues: FeedMode.allCases.map { ($0, LoadedPostFeed(feedMode: $0)) })
    var transientErrorMessage: String?
    private(set) var openDeckSource: PostDeckSource?
    // The open deck's posts in its video's order (AGENTS.md, "Pull Request Decks").
    private(set) var openDeckPosts: [ShipTokPost] = []
    private(set) var isOpenDeckRead = false
    private(set) var openDeckReadFailureMessage: String?
    private(set) var isOpenDeckPullToRefreshRunning = false
    // The posts each week's or feature's deck held when it was last read, which its card's deck button counts (AGENTS.md, "Pull Request Decks").
    private var postsOfDecksReadByDeckPostID: [String: [ShipTokPost]] = [:]
    private var mediaLoadFailureRecovery = MediaLoadFailureRecovery()

    // What Revyl last confirmed of the viewer's Videos only; nil until it's read.
    @ObservationIgnored private var showsOnlyPostsWithVideos: Bool?
    @ObservationIgnored private var openDeckReadTask: Task<Void, Never>?
    @ObservationIgnored private var focusedOpenDeckPostID: String?
    // Whether the viewer has moved from one card of the open deck to another; until then the card in focus is the one the deck opened on (AGENTS.md, "Pull Request Decks").
    @ObservationIgnored private var hasViewerMovedInOpenDeck = false
    // A deck card that closed or lost its last media while under the viewer's finger, which goes once they move on (AGENTS.md, "Pull Request Decks").
    @ObservationIgnored private var openDeckPostIDsLeavingOnceUnfocused: Set<String> = []
    @ObservationIgnored private var savedFeedsOpening: Task<Void, Never>?
    @ObservationIgnored private var olderPostLoadRunningFeedModes: Set<FeedMode> = []
    @ObservationIgnored private var refreshRunningFeedModes: Set<FeedMode> = []
    // A feed read again from its newest page leaves every read started before that out of it.
    @ObservationIgnored private var resetCountByFeedMode: [FeedMode: Int] = [:]
    @ObservationIgnored private var savedFeedGeneration = 0
    @ObservationIgnored private var onScreenPosts: OnScreenPosts?
    @ObservationIgnored private var shownModeTasksByID: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var postIDsRenewingMediaURLsAfterLoadFailure: Set<String> = []
    @ObservationIgnored private var reactionWriteCountByPostID: [String: Int] = [:]
    @ObservationIgnored private var vibeWriteCountByPostID: [String: Int] = [:]
    let repositoryID: Int64
    private let api: RevylShipTokAPI
    private let reactionWriteQueue: ViewerReactionWriteQueue
    private let analytics: ShipTokAnalytics
    private let revylUserID: String
    private let hiddenPeopleStore: HiddenPeopleStore
    private let savedPostFeeds = SavedPostFeeds()
    private let feedWork: FeedViewerWork
    private let onRepositoryLost: @MainActor (String) -> Void

    init(
        api: RevylShipTokAPI,
        repositoryID: Int64,
        analytics: ShipTokAnalytics,
        revylUserID: String,
        hiddenPeopleStore: HiddenPeopleStore,
        feedWork: FeedViewerWork,
        onRepositoryLost: @escaping @MainActor (String) -> Void
    ) {
        self.api = api
        self.repositoryID = repositoryID
        reactionWriteQueue = ViewerReactionWriteQueue(api: api)
        self.analytics = analytics
        self.revylUserID = revylUserID
        self.hiddenPeopleStore = hiddenPeopleStore
        self.feedWork = feedWork
        self.onRepositoryLost = onRepositoryLost
    }

    var unloadableMediaItemIDs: Set<String> {
        mediaLoadFailureRecovery.unloadableMediaItemIDs
    }

    func loadedFeed(_ feedMode: FeedMode) -> LoadedPostFeed {
        loadedFeeds[feedMode]!
    }

    // What people the viewer hid posted leaves every card, so only what's shown is counted (AGENTS.md, "Report And Hide").
    func visiblePosts(in feedMode: FeedMode) -> [ShipTokPost] {
        loadedFeed(feedMode).posts.filter { isVisible($0) }
    }

    // A deck shows every post it holds, less what people the viewer hid posted (AGENTS.md, "Pull Request Decks").
    var visibleOpenDeckPosts: [ShipTokPost] {
        openDeckPosts.filter { isVisible($0) }
    }

    func post(withID postID: String) -> ShipTokPost? {
        for feedMode in FeedMode.allCases {
            if let post = loadedFeed(feedMode).posts.first(where: { $0.id == postID }) { return post }
        }
        return openDeckPosts.first { $0.id == postID }
    }

    // Nil until the deck has been read; then the posts it held, less those the viewer can't see now. Reading every deck ahead of its opening would cost a read for each card the viewer only scrolls past.
    func postCountOfDeckRead(deckPostID: String) -> Int? {
        postsOfDecksReadByDeckPostID[deckPostID].map { deckPosts in
            deckPosts.filter { isVisible($0) && !isEveryMediaItemGivenUp($0) }.count
        }
    }

    func heroMediaItem(of post: ShipTokPost) -> ShipTokPostMedia? {
        post.media.first { !unloadableMediaItemIDs.contains($0.id) } ?? post.media.first
    }

    // A deck is read in one request, and read again on a pull, a retry or coming back to it after a read was cut short (AGENTS.md, "Pull Request Decks").
    func openDeck(_ deckSource: PostDeckSource) {
        openDeckReadTask?.cancel()
        openDeckReadTask = nil
        openDeckSource = deckSource
        openDeckPosts = []
        isOpenDeckRead = false
        openDeckReadFailureMessage = nil
        focusedOpenDeckPostID = nil
        hasViewerMovedInOpenDeck = false
        openDeckPostIDsLeavingOnceUnfocused = []
        startOpenDeckReadIfUnread()
    }

    func closeDeck() {
        stopShownModeWork()
        openDeckReadTask?.cancel()
        openDeckReadTask = nil
        openDeckSource = nil
        openDeckPosts = []
        isOpenDeckRead = false
        openDeckReadFailureMessage = nil
        focusedOpenDeckPostID = nil
        hasViewerMovedInOpenDeck = false
        openDeckPostIDsLeavingOnceUnfocused = []
    }

    // Nil focuses the deck's end, or a deck with no card yet.
    func focusOpenDeckPage(showingPostID focusedPostID: String?) {
        hasViewerMovedInOpenDeck = hasViewerMovedInOpenDeck || (focusedOpenDeckPostID != nil && focusedPostID != focusedOpenDeckPostID)
        if focusedPostID != focusedOpenDeckPostID, !openDeckPostIDsLeavingOnceUnfocused.isEmpty {
            openDeckPosts.removeAll { openDeckPostIDsLeavingOnceUnfocused.contains($0.id) }
            openDeckPostIDsLeavingOnceUnfocused.removeAll()
        }
        let visibleOpenDeckPosts = visibleOpenDeckPosts
        guard let pageIndex = visibleOpenDeckPosts.firstIndex(where: { $0.id == focusedPostID }) else {
            focusedOpenDeckPostID = nil
            return
        }
        focusedOpenDeckPostID = focusedPostID
        let focusedPost = visibleOpenDeckPosts[pageIndex]
        let nextPost = visibleOpenDeckPosts.indices.contains(pageIndex + 1) ? visibleOpenDeckPosts[pageIndex + 1] : nil
        startShownModeWork { [self] in
            async let focusedPostRefetch: Void = fetchAndApplyPost(postID: focusedPost.id, forcesMediaURLRenewal: isMediaURLRenewalDue(of: focusedPost))
            if let nextPost, isMediaURLRenewalDue(of: nextPost) {
                await fetchAndApplyPost(postID: nextPost.id, forcesMediaURLRenewal: true)
            }
            await focusedPostRefetch
        }
    }

    func refreshOpenDeck() async {
        await feedWork.perform { [self] in
            guard isOpenDeckRead else {
                startOpenDeckReadIfUnread()
                await openDeckReadTask?.value
                return
            }
            guard let focusedOpenDeckPostID else { return }
            await fetchAndApplyPost(postID: focusedOpenDeckPostID, forcesMediaURLRenewal: false)
        }
    }

    // A pull only happens on a deck's first card, so that's the card it reads again, or the whole deck while it's unread.
    func refreshOpenDeckFromPull() async {
        await feedWork.perform { [self] in
            isOpenDeckPullToRefreshRunning = true
            defer { isOpenDeckPullToRefreshRunning = false }
            guard isOpenDeckRead else {
                openDeckReadFailureMessage = nil
                startOpenDeckReadIfUnread()
                await openDeckReadTask?.value
                return
            }
            guard let firstOpenDeckPost = visibleOpenDeckPosts.first else { return }
            await fetchAndApplyPost(postID: firstOpenDeckPost.id, forcesMediaURLRenewal: false)
        }
    }

    func retryOpenDeckRead() {
        openDeckReadFailureMessage = nil
        startOpenDeckReadIfUnread()
    }

    private func startOpenDeckReadIfUnread() {
        guard onScreenPosts == .openDeck, openDeckReadTask == nil, openDeckSource != nil, !isOpenDeckRead else { return }
        openDeckReadTask = feedWork.start { [self] in await readOpenDeck() }
    }

    private func readOpenDeck() async {
        guard let deckSource = openDeckSource else { return }
        let readStartedAt = Date.now
        do {
            let deckPosts: [ShipTokPost]
            switch deckSource {
            case .pullRequestsOf(let deckPost): deckPosts = try await api.fetchDeck(postID: deckPost.id)
            case .post(let postID): deckPosts = [try await api.fetchPost(postID: postID)]
            }
            try Task.checkCancellation()
            if mediaLoadFailureRecovery.hasPendingLoadFailure {
                mediaLoadFailureRecovery.settleLoadFailures(of: deckPosts.flatMap(\.media), readStartedAt: readStartedAt)
            }
            openDeckPosts = deckPosts.filter { isKeptInOpenDeck($0) }
            isOpenDeckRead = true
            openDeckReadFailureMessage = nil
            if case .pullRequestsOf(let deckPost) = deckSource {
                postsOfDecksReadByDeckPostID[deckPost.id] = openDeckPosts
            }
            Self.logger.info("A deck read \(deckPosts.count, privacy: .public) posts in \(Self.millisecondsElapsed(since: readStartedAt), privacy: .public) ms")
        } catch {
            if Task.isCancelled { return }
            if !handleRefusal(error) {
                Self.logger.error("Reading a deck failed: \(error.publicLogDescription, privacy: .public)")
                openDeckReadFailureMessage = error.localizedDescription
            }
        }
        openDeckReadTask = nil
    }

    // A launch opens on the saved feeds at once and asks Revyl for each mode's newest page; a feed with nothing loaded reads pages until enough cards show (AGENTS.md, "Feed Order" and "Feed Caching").
    func refreshNewestData(in feedMode: FeedMode) async {
        await feedWork.perform { [self] in await refreshNewestData(in: feedMode, reportsFailure: false) }
    }

    func refreshFromPull(in feedMode: FeedMode) async {
        await feedWork.perform { [self] in
            updateLoadedFeed(feedMode) { $0.isPullToRefreshRunning = true }
            defer { updateLoadedFeed(feedMode) { $0.isPullToRefreshRunning = false } }
            await refreshNewestData(in: feedMode, reportsFailure: true)
        }
    }

    func loadOlderPosts(in feedMode: FeedMode) async {
        await feedWork.perform { [self] in await loadOlderPostPages(in: feedMode) }
    }

    // Revyl leaves out of Open and Merged what Videos only hides, so a feed it served under the other setting is read again from its newest page (AGENTS.md, "Feed Order").
    func applyShowsOnlyPostsWithVideos(_ newShowsOnlyPostsWithVideos: Bool) {
        showsOnlyPostsWithVideos = newShowsOnlyPostsWithVideos
        for feedMode in [FeedMode.open, .merged] {
            let loadedFeed = loadedFeed(feedMode)
            guard loadedFeed.isNewestPageLoaded else { continue }
            guard let loadedShowingOnlyPostsWithVideos = loadedFeed.loadedShowingOnlyPostsWithVideos else {
                updateLoadedFeed(feedMode) { $0.loadedShowingOnlyPostsWithVideos = newShowsOnlyPostsWithVideos }
                continue
            }
            guard loadedShowingOnlyPostsWithVideos != newShowsOnlyPostsWithVideos else { continue }
            let wasOnScreen = loadedFeed.isOnScreen
            resetCountByFeedMode[feedMode, default: 0] += 1
            olderPostLoadRunningFeedModes.remove(feedMode)
            refreshRunningFeedModes.remove(feedMode)
            updateLoadedFeed(feedMode) { resetFeed in
                resetFeed = LoadedPostFeed(feedMode: feedMode)
                resetFeed.isOnScreen = wasOnScreen
            }
            if shownFeedMode == feedMode {
                startShownModeWork { [self] in await loadOlderPostPages(in: feedMode) }
            }
        }
        saveFeeds()
    }

    // Older posts are read a page at a time and put below every card already loaded, so nothing moves under the viewer, until enough more cards show or Revyl has no more. A page can hold none and still name a next one (AGENTS.md, "Feed Order").
    private func loadOlderPostPages(in feedMode: FeedMode) async {
        await openSavedFeedsOnce()
        guard !loadedFeed(feedMode).hasLoadedEveryPost, olderPostLoadRunningFeedModes.insert(feedMode).inserted else { return }
        let resetCount = resetCountByFeedMode[feedMode, default: 0]
        defer {
            if resetCountByFeedMode[feedMode, default: 0] == resetCount {
                olderPostLoadRunningFeedModes.remove(feedMode)
            }
        }
        if loadedFeed(feedMode).loadFailureMessage != nil {
            updateLoadedFeed(feedMode) { $0.loadFailureMessage = nil }
        }
        let visibleCountBeforeLoad = visiblePosts(in: feedMode).count
        do {
            repeat {
                let pageReadStartedAt = Date.now
                let isNewestPage = !loadedFeed(feedMode).isNewestPageLoaded
                let page = try await api.fetchFeedPage(repositoryID: repositoryID, feedMode: feedMode, cursor: loadedFeed(feedMode).nextCursor)
                try Task.checkCancellation()
                guard resetCountByFeedMode[feedMode, default: 0] == resetCount else { return }
                let visibleCountBeforePage = visiblePosts(in: feedMode).count
                let addedPostCount = appendOlderPosts(page.posts, to: feedMode, fetchedAt: pageReadStartedAt)
                let showsOnlyPostsWithVideos = showsOnlyPostsWithVideos
                updateLoadedFeed(feedMode) { loadedFeed in
                    loadedFeed.nextCursor = page.nextCursor
                    loadedFeed.hasLoadedEveryPost = page.nextCursor == nil
                    loadedFeed.isNewestPageLoaded = true
                    if loadedFeed.loadedShowingOnlyPostsWithVideos == nil {
                        loadedFeed.loadedShowingOnlyPostsWithVideos = showsOnlyPostsWithVideos
                    }
                }
                if !isNewestPage {
                    analytics.capture(.olderPostsLoaded(feedMode, addedPostCount: addedPostCount, addedVisiblePostCount: visiblePosts(in: feedMode).count - visibleCountBeforePage))
                }
                Self.logger.info("Read \(isNewestPage ? "the newest" : "an older", privacy: .public) page of \(feedMode.rawValue, privacy: .public) posts: \(addedPostCount, privacy: .public) more in \(Self.millisecondsElapsed(since: pageReadStartedAt), privacy: .public) ms")
            } while !loadedFeed(feedMode).hasLoadedEveryPost
                && visiblePosts(in: feedMode).count - visibleCountBeforeLoad < Self.olderPostLoadCardCount
                && feedMode == shownFeedMode
            saveFeeds()
        } catch {
            if handleRefusal(error) { return }
            Self.logger.error("Loading \(feedMode.rawValue, privacy: .public) posts failed: \(error.publicLogDescription, privacy: .public)")
            updateLoadedFeed(feedMode) { $0.loadFailureMessage = error.localizedDescription }
        }
    }

    // Counting only the cards the viewer is shown, so the next page is in before they reach the end (AGENTS.md, "Feed Order").
    func loadOlderPostsIfViewerNearsEnd(in feedMode: FeedMode) {
        let loadedFeed = loadedFeed(feedMode)
        guard feedMode == shownFeedMode, loadedFeed.isNewestPageLoaded, !loadedFeed.hasLoadedEveryPost, !olderPostLoadRunningFeedModes.contains(feedMode) else { return }
        let postsAfterFocus = loadedFeed.isFeedEndFocused
            ? []
            : loadedFeed.posts.dropFirst(loadedFeed.focusedPostID == nil ? 0 : loadedFeed.focusedPageIndex + 1)
        guard postsAfterFocus.filter({ isVisible($0) }).count <= Self.olderPostLoadDistanceInCards else { return }
        startShownModeWork { [self] in await loadOlderPostPages(in: feedMode) }
    }

    // Older pages, the open deck's read and the reads around the focused card belong to what's on screen, so they stop whenever it changes. Nil is Inbox or Settings over the feed (AGENTS.md, "Feed Order" and "Pull Request Decks").
    func changeOnScreenPosts(to newOnScreenPosts: OnScreenPosts?) {
        if let previouslyShownFeedMode = shownFeedMode, newOnScreenPosts != .feed(previouslyShownFeedMode) {
            updateLoadedFeed(previouslyShownFeedMode) { loadedFeed in loadedFeed.leaveScreen(isShown: { isVisible($0) }) }
        }
        let wasOpenDeckOnScreen = onScreenPosts == .openDeck
        onScreenPosts = newOnScreenPosts
        stopShownModeWork()
        if wasOpenDeckOnScreen, newOnScreenPosts != .openDeck {
            leaveOpenDeckScreen()
        } else if !wasOpenDeckOnScreen, newOnScreenPosts == .openDeck {
            startOpenDeckReadIfUnread()
        }
    }

    // The app may be ended once it leaves the screen, so the feeds are saved for the next launch then.
    @discardableResult
    func saveFeeds() -> Task<Void, Never>? {
        guard savedFeedsOpening != nil else { return nil }
        let savedFeeds = FeedMode.allCases.compactMap { feedMode -> SavedPostFeed? in
            let loadedFeed = loadedFeed(feedMode)
            guard loadedFeed.isNewestPageLoaded else { return nil }
            return SavedPostFeed(
                feedMode: feedMode,
                nextCursor: loadedFeed.nextCursor,
                showsOnlyPostsWithVideos: loadedFeed.loadedShowingOnlyPostsWithVideos,
                posts: loadedFeed.postsOnceViewerMovesOn.map(\.savedCopy)
            )
        }
        guard !savedFeeds.isEmpty else { return nil }
        savedFeedGeneration += 1
        let savedContent = SavedPostFeedsContent(revylUserID: revylUserID, githubRepositoryID: repositoryID, feeds: savedFeeds)
        let generation = savedFeedGeneration
        return feedWork.start { [savedPostFeeds] in await savedPostFeeds.save(savedContent, generation: generation) }
    }

    // Nil focuses the feed's end. Pages are named by post rather than position, since a feed shows only what people the viewer hid didn't post.
    func focusFeedPage(in feedMode: FeedMode, showingPostID focusedPostID: String?) {
        updateLoadedFeed(feedMode) { loadedFeed in loadedFeed.focus(showingPostID: focusedPostID, isShown: { isVisible($0) }) }
        loadOlderPostsIfViewerNearsEnd(in: feedMode)
        guard feedMode == shownFeedMode else { return }
        startShownModeWork { [self] in await refetchPostsAroundFocus(in: feedMode) }
    }

    // A failed load renews the post's media links at once while its cards are on screen; otherwise, or when that read fails, the next read that succeeds settles the failure (AGENTS.md, "Signed Media URLs").
    func recoverFromMediaLoadFailure(of mediaItem: ShipTokPostMedia, onPostID postID: String) {
        guard let post = post(withID: postID) else { return }
        let isURLRenewalNeeded = mediaLoadFailureRecovery.recordLoadFailure(of: mediaItem)
        removeIfEveryMediaItemGivenUp(post)
        guard isURLRenewalNeeded, onScreenPosts != nil, postIDsRenewingMediaURLsAfterLoadFailure.insert(postID).inserted else { return }
        startShownModeWork { [self] in
            await fetchAndApplyPost(postID: postID, forcesMediaURLRenewal: true)
            postIDsRenewingMediaURLsAfterLoadFailure.remove(postID)
            if let loadedPost = self.post(withID: postID) {
                removeIfEveryMediaItemGivenUp(loadedPost)
            }
        }
    }

    func toggleReaction(_ reaction: ShipTokReaction, postID: String) async {
        guard let post = post(withID: postID) else { return }
        await setViewerReaction(reaction, isReacting: !post.reactions.viewerReactions.contains(reaction), on: post)
    }

    func likeUnlessAlreadyLiked(postID: String) async {
        guard let post = post(withID: postID), !post.reactions.viewerReactions.contains(.heart) else { return }
        await setViewerReaction(.heart, isReacting: true, on: post)
    }

    // The comments sheet tells every card of the post how many comments and replies came or went, so the count moves at once.
    func changeCommentCount(by commentCountChange: Int, onPostID postID: String) {
        updateEveryCopy(ofPostID: postID) { post in
            post.feedback.commentCount = max(post.feedback.commentCount + commentCountChange, 0)
        }
    }

    // The viewer's vibe shows at once and stays while its write runs, so a read that started before the write never takes it back; a failed write restores what was there. The write answers the vibe's id, nil once it's deleted.
    func writeViewerVibe(_ vibe: ShipTokVibe?, feedbackText: String?, onPostID postID: String, using write: () async throws -> String?) async throws {
        let feedbackBeforeWrite = post(withID: postID)?.feedback
        updateEveryCopy(ofPostID: postID) { $0.feedback.setViewerVibe(vibe, feedbackText: feedbackText, vibeID: nil) }
        vibeWriteCountByPostID[postID, default: 0] += 1
        defer {
            let remainingWriteCount = vibeWriteCountByPostID[postID, default: 1] - 1
            vibeWriteCountByPostID[postID] = remainingWriteCount > 0 ? remainingWriteCount : nil
        }
        do {
            let writtenVibeID = try await write()
            updateEveryCopy(ofPostID: postID) { $0.feedback.viewerVibeID = writtenVibeID }
        } catch {
            if let feedbackBeforeWrite {
                updateEveryCopy(ofPostID: postID) {
                    $0.feedback.setViewerVibe(feedbackBeforeWrite.viewerVibe, feedbackText: feedbackBeforeWrite.viewerVibeFeedbackText, vibeID: feedbackBeforeWrite.viewerVibeID)
                }
            }
            throw error
        }
    }

    // Reads the post again, as after a vibe someone deleted from its comments sheet.
    func rereadPost(postID: String) async {
        await feedWork.perform { [self] in await fetchAndApplyPost(postID: postID, forcesMediaURLRenewal: false) }
    }

    // A refused sign-in ends it on its own, and a repository the organization's installation no longer covers sends the viewer to choose another (AGENTS.md, "Repositories"). True when nothing more is for the store to show.
    private func handleRefusal(_ error: Error) -> Bool {
        if error.isTaskCancellation { return true }
        guard let apiError = error as? RevylShipTokAPIError else { return false }
        if apiError.refusesSignIn { return true }
        switch apiError {
        case .repositoryNotFound, .githubAppNotInstalled:
            onRepositoryLost(apiError.localizedDescription)
            return true
        default:
            return false
        }
    }

    private func updateLoadedFeed(_ feedMode: FeedMode, _ update: (inout LoadedPostFeed) -> Void) {
        update(&loadedFeeds[feedMode]!)
    }

    private func startShownModeWork(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        let taskID = UUID()
        guard let task = feedWork.start({ [weak self] in
            await operation()
            self?.shownModeTasksByID[taskID] = nil
        }) else { return }
        shownModeTasksByID[taskID] = task
    }

    // Leaving the deck stops its read and releases what the viewer's finger held, while the viewer's place stays; coming back reads it if it's still unread (AGENTS.md, "Pull Request Decks").
    private func leaveOpenDeckScreen() {
        openDeckReadTask?.cancel()
        openDeckReadTask = nil
        focusedOpenDeckPostID = nil
        openDeckPosts.removeAll { openDeckPostIDsLeavingOnceUnfocused.contains($0.id) }
        openDeckPostIDsLeavingOnceUnfocused.removeAll()
    }

    private func stopShownModeWork() {
        for task in shownModeTasksByID.values {
            task.cancel()
        }
        shownModeTasksByID.removeAll()
    }

    private var shownFeedMode: FeedMode? {
        guard case .feed(let feedMode) = onScreenPosts else { return nil }
        return feedMode
    }

    private func isVisible(_ post: ShipTokPost) -> Bool {
        !hiddenPeopleStore.isHidden(post.githubAuthor)
    }

    // Revyl's own rule for what a mode holds, with Videos only as Revyl last confirmed it, so a post read elsewhere joins a feed only where Revyl would serve it.
    private func belongs(_ post: ShipTokPost, in feedMode: FeedMode) -> Bool {
        guard post.belongs(in: feedMode) else { return false }
        switch feedMode {
        case .open, .merged:
            return !(showsOnlyPostsWithVideos ?? true) || post.media.first?.kind == .video
        case .weekly, .features:
            return true
        }
    }

    // A deck leaves out a pull request closed without merging, one whose media all failed for this viewer, and in a week's deck one without media; one post opened on its own always shows (AGENTS.md, "Pull Request Decks").
    private func isKeptInOpenDeck(_ post: ShipTokPost) -> Bool {
        guard case .pullRequestsOf(let deckPost) = openDeckSource else { return true }
        guard post.pullRequest?.state != .closed, !isEveryMediaItemGivenUp(post) else { return false }
        return deckPost.kind == .feature || !post.media.isEmpty
    }

    // A post is dead for this viewer once every media item it holds is given up, failing again after its renewal. One with no media isn't (AGENTS.md, "Feed Order").
    private func isEveryMediaItemGivenUp(_ post: ShipTokPost) -> Bool {
        !post.media.isEmpty && post.media.allSatisfy { unloadableMediaItemIDs.contains($0.id) }
    }

    // A saved card holds no media link, and a signed one is renewed before it expires (AGENTS.md, "Signed Media URLs").
    private func isMediaURLRenewalDue(of post: ShipTokPost) -> Bool {
        post.media.contains { mediaItem in
            guard mediaItem.url != nil else { return true }
            return mediaItem.urlExpiresAt.map { $0.timeIntervalSinceNow < Self.mediaURLRenewalLeadSeconds } ?? false
        }
    }

    // Saved feeds are read once, by whichever feed is shown first, and no feed loads or refreshes before they are.
    private func openSavedFeedsOnce() async {
        if savedFeedsOpening == nil {
            savedFeedsOpening = Task { await openSavedFeeds() }
        }
        await savedFeedsOpening?.value
    }

    private func openSavedFeeds() async {
        let openStartedAt = Date.now
        guard let savedContent = await savedPostFeeds.load(revylUserID: revylUserID, githubRepositoryID: repositoryID) else { return }
        for savedFeed in savedContent.feeds {
            if let showsOnlyPostsWithVideos, let savedShowingOnlyPostsWithVideos = savedFeed.showsOnlyPostsWithVideos,
               [.open, .merged].contains(savedFeed.feedMode), savedShowingOnlyPostsWithVideos != showsOnlyPostsWithVideos {
                continue
            }
            updateLoadedFeed(savedFeed.feedMode) { loadedFeed in
                loadedFeed.posts = savedFeed.posts.filter { $0.belongs(in: savedFeed.feedMode) }.sorted { $0.comesBefore($1, in: savedFeed.feedMode) }
                loadedFeed.nextCursor = savedFeed.nextCursor
                loadedFeed.hasLoadedEveryPost = savedFeed.nextCursor == nil
                loadedFeed.isNewestPageLoaded = true
                loadedFeed.loadedShowingOnlyPostsWithVideos = savedFeed.showsOnlyPostsWithVideos
            }
        }
        Self.logger.info("Opened on \(savedContent.feeds.map(\.posts.count).reduce(0, +), privacy: .public) saved posts in \(Self.millisecondsElapsed(since: openStartedAt), privacy: .public) ms")
    }

    private func refreshNewestData(in feedMode: FeedMode, reportsFailure: Bool) async {
        await openSavedFeedsOnce()
        guard loadedFeed(feedMode).isNewestPageLoaded else {
            await loadOlderPostPages(in: feedMode)
            return
        }
        guard refreshRunningFeedModes.insert(feedMode).inserted else { return }
        let resetCount = resetCountByFeedMode[feedMode, default: 0]
        defer {
            if resetCountByFeedMode[feedMode, default: 0] == resetCount {
                refreshRunningFeedModes.remove(feedMode)
            }
            loadOlderPostsIfViewerNearsEnd(in: feedMode)
        }
        if let focusedPostID = loadedFeed(feedMode).focusedPostID {
            await fetchAndApplyPost(postID: focusedPostID, forcesMediaURLRenewal: false)
        }
        let refreshStartedAt = Date.now
        do {
            let newestPage = try await api.fetchFeedPage(repositoryID: repositoryID, feedMode: feedMode, cursor: nil)
            try Task.checkCancellation()
            guard resetCountByFeedMode[feedMode, default: 0] == resetCount else { return }
            applyNewestPage(newestPage, in: feedMode, fetchedAt: refreshStartedAt)
            Self.logger.debug("Read the newest page of \(feedMode.rawValue, privacy: .public) posts in \(Self.millisecondsElapsed(since: refreshStartedAt), privacy: .public) ms")
        } catch {
            if handleRefusal(error) { return }
            Self.logger.error("Refreshing \(feedMode.rawValue, privacy: .public) posts failed: \(error.publicLogDescription, privacy: .public)")
            if reportsFailure {
                transientErrorMessage = "Couldn't refresh. \(error.localizedDescription)"
            }
        }
    }

    // The newest page updates the cards it holds and adds new ones in their slots. A loaded card that sorts above the page's last card yet isn't on it has left the feed: it closed, merged, lost its media or stopped leading with a video (AGENTS.md, "Feed Order").
    private func applyNewestPage(_ newestPage: ShipTokPostPage, in feedMode: FeedMode, fetchedAt: Date) {
        let newestPagePostsInFeedOrder = newestPage.posts.sorted { $0.comesBefore($1, in: feedMode) }
        for newestPagePost in newestPagePostsInFeedOrder.reversed() {
            apply(newestPagePost, fetchedAt: fetchedAt, forcesMediaURLRenewal: false)
        }
        let newestPagePostIDs = Set(newestPage.posts.map(\.id))
        if let lastNewestPagePost = newestPagePostsInFeedOrder.last {
            updateLoadedFeed(feedMode) { loadedFeed in
                loadedFeed.removePosts { !newestPagePostIDs.contains($0.id) && $0.comesBefore(lastNewestPagePost, in: feedMode) }
            }
        } else if newestPage.nextCursor == nil {
            updateLoadedFeed(feedMode) { loadedFeed in
                loadedFeed.removePosts { _ in true }
                loadedFeed.nextCursor = nil
                loadedFeed.hasLoadedEveryPost = true
            }
        }
    }

    private func appendOlderPosts(_ olderPosts: [ShipTokPost], to feedMode: FeedMode, fetchedAt: Date) -> Int {
        var appendedPostCount = 0
        for olderPost in olderPosts.sorted(by: { $0.comesBefore($1, in: feedMode) }) {
            if loadedFeed(feedMode).index(ofPostID: olderPost.id) != nil {
                apply(olderPost, fetchedAt: fetchedAt, forcesMediaURLRenewal: false)
            } else if olderPost.belongs(in: feedMode), !isEveryMediaItemGivenUp(olderPost) {
                if mediaLoadFailureRecovery.hasPendingLoadFailure {
                    mediaLoadFailureRecovery.settleLoadFailures(of: olderPost.media, readStartedAt: fetchedAt)
                }
                updateLoadedFeed(feedMode) { loadedFeed in loadedFeed.appendInFeedOrder(olderPost, isShown: { isVisible($0) }) }
                appendedPostCount += 1
            }
        }
        return appendedPostCount
    }

    // A post dead for this viewer leaves each feed and the open deck (AGENTS.md, "Feed Order").
    private func removeIfEveryMediaItemGivenUp(_ post: ShipTokPost) {
        guard isEveryMediaItemGivenUp(post) else { return }
        for feedMode in FeedMode.allCases where loadedFeed(feedMode).index(ofPostID: post.id) != nil {
            updateLoadedFeed(feedMode) { loadedFeed in
                loadedFeed.removePostWithoutLoadableMedia(withID: post.id, isShown: { isVisible($0) })
            }
        }
        if openDeckPosts.contains(where: { $0.id == post.id }), case .pullRequestsOf = openDeckSource {
            removeFromOpenDeckWithMediaGivenUp(postID: post.id)
        }
    }

    // Like a mode, a deck that opened on a dead card skips it at once while the viewer hasn't moved off it, and the next card they're shown takes focus (AGENTS.md, "Pull Request Decks").
    private func removeFromOpenDeckWithMediaGivenUp(postID: String) {
        let visibleOpenDeckPosts = visibleOpenDeckPosts
        guard postID == focusedOpenDeckPostID, !hasViewerMovedInOpenDeck,
              let focusedPageIndex = visibleOpenDeckPosts.firstIndex(where: { $0.id == postID })
        else {
            removeFromOpenDeck(postID: postID)
            return
        }
        focusedOpenDeckPostID = visibleOpenDeckPosts.indices.contains(focusedPageIndex + 1) ? visibleOpenDeckPosts[focusedPageIndex + 1].id : nil
        openDeckPostIDsLeavingOnceUnfocused.remove(postID)
        openDeckPosts.removeAll { $0.id == postID }
    }

    private func refetchPostsAroundFocus(in feedMode: FeedMode) async {
        let loadedFeed = loadedFeed(feedMode)
        guard let focusedPostID = loadedFeed.focusedPostID, let focusedIndex = loadedFeed.index(ofPostID: focusedPostID) else { return }
        let focusedPost = loadedFeed.posts[focusedIndex]
        async let focusedPostRefetch: Void = fetchAndApplyPost(postID: focusedPost.id, forcesMediaURLRenewal: isMediaURLRenewalDue(of: focusedPost))
        if let nextShownPost = loadedFeed.posts[(focusedIndex + 1)...].first(where: { isVisible($0) }), isMediaURLRenewalDue(of: nextShownPost) {
            await fetchAndApplyPost(postID: nextShownPost.id, forcesMediaURLRenewal: true)
        }
        await focusedPostRefetch
    }

    private func fetchAndApplyPost(postID: String, forcesMediaURLRenewal: Bool) async {
        let fetchStartedAt = Date.now
        do {
            let fetchedPost = try await api.fetchPost(postID: postID)
            apply(fetchedPost, fetchedAt: fetchStartedAt, forcesMediaURLRenewal: forcesMediaURLRenewal)
        } catch RevylShipTokAPIError.postNotFound {
            for feedMode in FeedMode.allCases where loadedFeed(feedMode).index(ofPostID: postID) != nil {
                updateLoadedFeed(feedMode) { $0.removePosts { $0.id == postID } }
            }
            if openDeckPosts.contains(where: { $0.id == postID }) {
                removeFromOpenDeck(postID: postID)
            }
            Self.logger.info("A post is gone, so its card leaves")
        } catch {
            if handleRefusal(error) { return }
            Self.logger.error("Rereading a post failed: \(error.publicLogDescription, privacy: .public)")
        }
    }

    private func apply(_ fetchedPost: ShipTokPost, fetchedAt: Date, forcesMediaURLRenewal: Bool) {
        let renewedMediaItemIDs = mediaLoadFailureRecovery.hasPendingLoadFailure
            ? mediaLoadFailureRecovery.settleLoadFailures(of: fetchedPost.media, readStartedAt: fetchedAt)
            : []
        removeIfEveryMediaItemGivenUp(fetchedPost)
        if let openDeckIndex = openDeckPosts.firstIndex(where: { $0.id == fetchedPost.id }) {
            if isKeptInOpenDeck(fetchedPost) {
                let existingPost = openDeckPosts[openDeckIndex]
                var updatedPost = keepingLocalWrites(of: existingPost, in: fetchedPost)
                if fetchedPost.id == focusedOpenDeckPostID && !forcesMediaURLRenewal {
                    updatedPost = keepingMediaURLs(of: existingPost, in: updatedPost, except: renewedMediaItemIDs)
                }
                openDeckPosts[openDeckIndex] = updatedPost
                openDeckPostIDsLeavingOnceUnfocused.remove(fetchedPost.id)
            } else {
                removeFromOpenDeck(postID: fetchedPost.id)
            }
        }
        guard fetchedPost.githubRepositoryID == repositoryID else { return }
        for feedMode in FeedMode.allCases {
            apply(fetchedPost, to: feedMode, forcesMediaURLRenewal: forcesMediaURLRenewal, renewedMediaItemIDs: renewedMediaItemIDs)
        }
    }

    // A loaded card updates and moves to its new slot, and the focused one keeps its media links so a playing video isn't reloaded; a load failure renews them. A post that sorts below every loaded card waits for its own page.
    private func apply(_ fetchedPost: ShipTokPost, to feedMode: FeedMode, forcesMediaURLRenewal: Bool, renewedMediaItemIDs: Set<String>) {
        let loadedFeed = loadedFeed(feedMode)
        let fetchedPostBelongs = belongs(fetchedPost, in: feedMode) && !isEveryMediaItemGivenUp(fetchedPost)
        guard let existingIndex = loadedFeed.index(ofPostID: fetchedPost.id) else {
            guard loadedFeed.isNewestPageLoaded, fetchedPostBelongs else { return }
            let mayGoLast = loadedFeed.hasLoadedEveryPost || loadedFeed.posts.isEmpty
            updateLoadedFeed(feedMode) { loadedFeed in loadedFeed.insertIntoFeedOrder(fetchedPost, mayGoLast: mayGoLast, isShown: { isVisible($0) }) }
            return
        }
        let existingPost = loadedFeed.posts[existingIndex]
        let isFocused = existingPost.id == loadedFeed.focusedPostID
        if !fetchedPostBelongs, !isFocused {
            updateLoadedFeed(feedMode) { $0.removePosts { $0.id == fetchedPost.id } }
            return
        }
        var updatedPost = keepingLocalWrites(of: existingPost, in: fetchedPost)
        if !forcesMediaURLRenewal && isFocused {
            updatedPost = keepingMediaURLs(of: existingPost, in: updatedPost, except: renewedMediaItemIDs)
        }
        // A fresh copy the viewer wouldn't be shown never empties or pulls away the card they're on (AGENTS.md, "Feed Order").
        if isFocused, loadedFeed.isOnScreen, isVisible(existingPost), !fetchedPostBelongs {
            updateLoadedFeed(feedMode) { $0.removePosts { $0.id == fetchedPost.id } }
            return
        }
        if updatedPost != existingPost {
            updateLoadedFeed(feedMode) { loadedFeed in loadedFeed.replace(updatedPost, at: existingIndex, isShown: { isVisible($0) }) }
        }
        if !fetchedPostBelongs {
            updateLoadedFeed(feedMode) { $0.removePosts { $0.id == fetchedPost.id } }
        } else if loadedFeed.isWaitingOnViewer(postID: fetchedPost.id) {
            updateLoadedFeed(feedMode) { $0.keepPost(withID: fetchedPost.id) }
        }
    }

    // The focused card keeps its media links so a playing video isn't reloaded; an item whose load failed takes its fresh one.
    private func keepingMediaURLs(of existingPost: ShipTokPost, in updatedPost: ShipTokPost, except renewedMediaItemIDs: Set<String>) -> ShipTokPost {
        let existingMediaItemsByID = Dictionary(
            existingPost.media.filter { $0.url != nil && !renewedMediaItemIDs.contains($0.id) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var postKeepingMediaURLs = updatedPost
        postKeepingMediaURLs.media = updatedPost.media.map { fetchedMediaItem in
            guard let existingMediaItem = existingMediaItemsByID[fetchedMediaItem.id] else { return fetchedMediaItem }
            return ShipTokPostMedia(
                id: fetchedMediaItem.id,
                kind: fetchedMediaItem.kind,
                url: existingMediaItem.url,
                posterURL: existingMediaItem.posterURL,
                isShipTokVideo: fetchedMediaItem.isShipTokVideo,
                isRevylHosted: fetchedMediaItem.isRevylHosted,
                urlExpiresAt: existingMediaItem.urlExpiresAt
            )
        }
        return postKeepingMediaURLs
    }

    // A deck card under the viewer's finger keeps the copy they see until they move on (AGENTS.md, "Pull Request Decks").
    private func removeFromOpenDeck(postID: String) {
        if postID == focusedOpenDeckPostID {
            openDeckPostIDsLeavingOnceUnfocused.insert(postID)
        } else {
            openDeckPosts.removeAll { $0.id == postID }
        }
    }

    // Revyl can answer before a reaction or vibe the viewer just changed is written, so the local copy wins for those while the write runs.
    private func keepingLocalWrites(of existingPost: ShipTokPost, in fetchedPost: ShipTokPost) -> ShipTokPost {
        var updatedPost = fetchedPost
        if reactionWriteCountByPostID[fetchedPost.id, default: 0] > 0 {
            updatedPost.feedback.reactions = existingPost.feedback.reactions
        }
        if vibeWriteCountByPostID[fetchedPost.id, default: 0] > 0 {
            updatedPost.feedback.goodVibeCount = existingPost.feedback.goodVibeCount
            updatedPost.feedback.badVibeCount = existingPost.feedback.badVibeCount
            updatedPost.feedback.viewerVibe = existingPost.feedback.viewerVibe
            updatedPost.feedback.viewerVibeFeedbackText = existingPost.feedback.viewerVibeFeedbackText
            updatedPost.feedback.viewerVibeID = existingPost.feedback.viewerVibeID
        }
        return updatedPost
    }

    private func setViewerReaction(_ reaction: ShipTokReaction, isReacting: Bool, on post: ShipTokPost) async {
        let postID = post.id
        let attempt = analytics.requestMutation(.reaction, change: isReacting ? .add : .remove,
                                                subject: ShipTokAnalyticsSubject(post: post), reaction: reaction)
        updateEveryCopy(ofPostID: postID) { $0.reactions.setViewerHasReacted(isReacting, with: reaction) }
        reactionWriteCountByPostID[postID, default: 0] += 1
        defer {
            let remainingWriteCount = reactionWriteCountByPostID[postID, default: 1] - 1
            reactionWriteCountByPostID[postID] = remainingWriteCount > 0 ? remainingWriteCount : nil
        }
        switch await reactionWriteQueue.write(reaction, viewerHasReacted: isReacting, on: .post(postID: postID)) {
        case .succeeded:
            analytics.capture(.mutationCompleted(attempt, outcome: .succeeded, commentID: nil))
        case .failed(let error, let restoredViewerHasReacted):
            analytics.capture(.mutationCompleted(attempt, outcome: error.isTaskCancellation ? .cancelled : .failed, commentID: nil))
            if let restoredViewerHasReacted {
                updateEveryCopy(ofPostID: postID) { $0.reactions.setViewerHasReacted(restoredViewerHasReacted, with: reaction) }
            }
            if handleRefusal(error) { return }
            let failedAction = switch (reaction, isReacting) {
            case (.heart, true): "like \(post.reference)"
            case (.heart, false): "unlike \(post.reference)"
            case (_, true): "react \(reaction.emoji) to \(post.reference)"
            case (_, false): "remove \(reaction.emoji) from \(post.reference)"
            }
            transientErrorMessage = "Couldn't \(failedAction). \(error.localizedDescription)"
        }
    }

    // A post can be in several feeds and the open deck at once, and every change shows on each of its cards.
    private func updateEveryCopy(ofPostID postID: String, _ update: (inout ShipTokPost) -> Void) {
        if let openDeckIndex = openDeckPosts.firstIndex(where: { $0.id == postID }) {
            update(&openDeckPosts[openDeckIndex])
        }
        for feedMode in FeedMode.allCases {
            guard let postIndex = loadedFeed(feedMode).index(ofPostID: postID) else { continue }
            updateLoadedFeed(feedMode) { update(&$0.posts[postIndex]) }
        }
    }

    private static func millisecondsElapsed(since startDate: Date) -> Int {
        Int(Date.now.timeIntervalSince(startDate) * 1000)
    }
}
