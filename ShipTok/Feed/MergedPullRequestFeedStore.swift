import Foundation
import Observation
import OSLog

@Observable
@MainActor
final class MergedPullRequestFeedStore {
    private static let liveRefreshIntervalSeconds = 10
    private static let feedWindowSeconds: TimeInterval = 14 * 24 * 60 * 60
    private static let mediaURLRenewalAgeSeconds: TimeInterval = 120
    private static let updateSearchOverlapSeconds: TimeInterval = 180
    // GitHub limits how much of its server time one account may take each minute, so a week's pull requests load a few at a time.
    private static let concurrentOpenWeekFetchCount = 6
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "feed")

    private(set) var pullRequests: [MergedPullRequest] = []
    private(set) var isFeedWindowLoaded = false
    private(set) var feedLoadFailureMessage: String?
    private(set) var isPullToRefreshRunning = false
    private(set) var unseenNewerPullRequestIDs: Set<String> = []
    private(set) var unloadableMediaItemIDs: Set<String> = []
    var transientErrorMessage: String?
    // The pull requests of the weekly edition whose deck is open, in its video's order (AGENTS.md, "Weekly Mode").
    private(set) var openWeekPullRequests: [MergedPullRequest] = []
    private(set) var isOpenWeekLoaded = false
    private(set) var openWeekLoadFailureMessage: String?

    private var openWeekLoadTask: Task<Void, Never>?
    private var focusedPullRequestID: String?
    private var isFeedEndFocused = false
    private var isFeedLoadRunning = false
    // Set once the feed holds every pull request that belongs in it as of this date, from the saved feed or the launch's search.
    private var nextUpdateSearchStartDate: Date?
    private var isRefreshRunning = false
    private var savedFeedGeneration = 0
    private var mediaFetchedAtByPullRequestID: [String: Date] = [:]
    private var failedLoadURLByMediaItemID: [String: URL] = [:]
    private var urlRenewalDateAfterLoadFailureByMediaItemID: [String: Date] = [:]
    private var pullRequestIDsRenewingMediaURLsAfterLoadFailure: Set<String> = []
    private var reactionWriteCountByPullRequestID: [String: Int] = [:]
    // A fetch that started before a delete can still return the comment, so a comment the viewer deleted stays out of every later fetch.
    private var viewerDeletedCommentIDs: Set<String> = []
    private let githubAPIClient: GitHubAPIClient
    private let reactionWriteQueue: ViewerReactionWriteQueue
    private let analytics: ShipTokAnalytics
    // A demo visitor has none, and their feed isn't saved (AGENTS.md, "Demo Mode").
    private let viewerGitHubLogin: String?
    private let feedCache = MergedPullRequestFeedCache()
    private let handleRejectedGitHubAccess: @MainActor (GitHubAPIError) -> Void

    init(
        githubAPIClient: GitHubAPIClient,
        analytics: ShipTokAnalytics,
        viewerGitHubLogin: String?,
        handleRejectedGitHubAccess: @escaping @MainActor (GitHubAPIError) -> Void
    ) {
        self.githubAPIClient = githubAPIClient
        reactionWriteQueue = ViewerReactionWriteQueue(githubAPIClient: githubAPIClient)
        self.analytics = analytics
        self.viewerGitHubLogin = viewerGitHubLogin
        self.handleRejectedGitHubAccess = handleRejectedGitHubAccess
    }

    func pullRequest(withID pullRequestID: String) -> MergedPullRequest? {
        pullRequests.first { $0.id == pullRequestID } ?? openWeekPullRequests.first { $0.id == pullRequestID }
    }

    // A week's pull requests show in its video's order as each leading one arrives, so a page never moves under the viewer. A week can reach back past the feed's window, so they're read by number.
    func openWeek(pullRequestNumbers: [Int]) {
        openWeekLoadTask?.cancel()
        var seenPullRequestNumbers: Set<Int> = []
        let uniquePullRequestNumbers = pullRequestNumbers.filter { seenPullRequestNumbers.insert($0).inserted }
        openWeekPullRequests = []
        isOpenWeekLoaded = false
        openWeekLoadFailureMessage = nil
        openWeekLoadTask = Task { await loadOpenWeek(pullRequestNumbers: uniquePullRequestNumbers) }
    }

    func closeWeek() {
        openWeekLoadTask?.cancel()
        openWeekLoadTask = nil
        openWeekPullRequests = []
        isOpenWeekLoaded = false
        openWeekLoadFailureMessage = nil
    }

    func focusOpenWeekPage(showingPullRequestID focusedPullRequestID: String) {
        guard let pageIndex = openWeekPullRequests.firstIndex(where: { $0.id == focusedPullRequestID }) else { return }
        let focusedPullRequest = openWeekPullRequests[pageIndex]
        let nextPullRequest = openWeekPullRequests.indices.contains(pageIndex + 1) ? openWeekPullRequests[pageIndex + 1] : nil
        Task {
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

    // A pull only happens on a week's first card, so that's the card it reads again.
    func refreshOpenWeekFromPull() async {
        guard let firstOpenWeekPullRequest = openWeekPullRequests.first else { return }
        isPullToRefreshRunning = true
        defer { isPullToRefreshRunning = false }
        await fetchAndApplyPullRequest(number: firstOpenWeekPullRequest.number, forcesMediaURLRenewal: false)
    }

    private func loadOpenWeek(pullRequestNumbers: [Int]) async {
        let loadStartedAt = Date.now
        var fetchResultByNumber: [Int: Result<MergedPullRequest, any Error>] = [:]
        var resolvedNumberCount = 0
        var lastFetchError: (any Error)?
        await withTaskGroup(of: (number: Int, fetchResult: Result<MergedPullRequest, any Error>).self) { taskGroup in
            var unrequestedNumbers = ArraySlice(pullRequestNumbers)
            func requestNextPullRequest() {
                guard let number = unrequestedNumbers.popFirst() else { return }
                taskGroup.addTask { [githubAPIClient] in
                    do {
                        return (number, .success(try await githubAPIClient.fetchMergedPullRequest(number: number)))
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
                        if index(ofPullRequestID: fetchedPullRequest.id) == nil {
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
                        if let savedPullRequest = pullRequests.first(where: { $0.number == resolvedNumber }) {
                            openWeekPullRequests.append(savedPullRequest)
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

    // A launch opens on the saved feed at once and asks GitHub only for what changed since. With nothing saved it opens on the ShipTok-labeled pull requests, which lead the feed, then reads the window behind them (AGENTS.md, "Feed Order" and "Feed Caching").
    func loadFeed() async {
        guard !isFeedLoadRunning, nextUpdateSearchStartDate == nil else { return }
        isFeedLoadRunning = true
        defer { isFeedLoadRunning = false }
        feedLoadFailureMessage = nil
        let loadStartedAt = Date.now
        if pullRequests.isEmpty, let viewerGitHubLogin {
            let savedFeed = await feedCache.loadSavedFeed(viewerGitHubLogin: viewerGitHubLogin, repositoryFullName: githubAPIClient.repositoryFullName, appliedSince: feedWindowStartDate)
            if let savedFeed {
                let windowStartDate = feedWindowStartDate
                pullRequests = savedFeed.pullRequests
                    .filter { $0.belongsInFeed(mergedWindowStartDate: windowStartDate) }
                    .sorted { $0.comesBeforeInFeed($1) }
                nextUpdateSearchStartDate = savedFeed.everyUpdateAppliedBefore
                isFeedWindowLoaded = true
                Self.logger.info("Opened on \(self.pullRequests.count, privacy: .public) saved pull requests in \(Self.millisecondsElapsed(since: loadStartedAt), privacy: .public) ms")
                await refreshNewestData(reportsFailure: false)
                return
            }
        }
        do {
            let windowStartDate = loadStartedAt.addingTimeInterval(-Self.feedWindowSeconds)
            if pullRequests.isEmpty {
                let labeledPullRequests = try await githubAPIClient.fetchMergedPullRequests(labeled: MergedPullRequest.shipTokLabelName)
                insertFoundPullRequests(labeledPullRequests, mergedWindowStartDate: windowStartDate, fetchedAt: loadStartedAt)
                Self.logger.info("Opened on \(self.pullRequests.count, privacy: .public) labeled pull requests in \(Self.millisecondsElapsed(since: loadStartedAt), privacy: .public) ms")
            }
            let windowSearch = try await githubAPIClient.searchMergedPullRequests(updatedSince: nil, mergedFrom: windowStartDate, mergedThrough: loadStartedAt)
            for try await windowPage in windowSearch {
                insertFoundPullRequests(windowPage, mergedWindowStartDate: windowStartDate, fetchedAt: loadStartedAt)
            }
            try Task.checkCancellation()
            nextUpdateSearchStartDate = loadStartedAt
            isFeedWindowLoaded = true
            saveFeed()
            Self.logger.info("Read the window: \(self.pullRequests.count, privacy: .public) pull requests with media in \(Self.millisecondsElapsed(since: loadStartedAt), privacy: .public) ms")
        } catch {
            if error.isTaskCancellation { return }
            if let githubAPIError = error as? GitHubAPIError, githubAPIError.rejectsFeedAccess {
                handleRejectedGitHubAccess(githubAPIError)
                return
            }
            Self.logger.error("Loading the feed failed: \(error.publicLogDescription, privacy: .public)")
            feedLoadFailureMessage = error.localizedDescription
        }
    }

    // The app may be ended once it leaves the screen, so the feed is saved for the next launch then.
    @discardableResult
    func saveFeed() -> Task<Void, Never>? {
        guard let nextUpdateSearchStartDate, let viewerGitHubLogin else { return nil }
        savedFeedGeneration += 1
        let savedFeed = SavedMergedPullRequestFeed(
            formatVersion: SavedMergedPullRequestFeed.currentFormatVersion,
            viewerGitHubLogin: viewerGitHubLogin,
            repositoryFullName: githubAPIClient.repositoryFullName,
            everyUpdateAppliedBefore: nextUpdateSearchStartDate,
            pullRequests: pullRequests.map { pullRequest in
                MergedPullRequest(
                    id: pullRequest.id, number: pullRequest.number, title: pullRequest.title, url: pullRequest.url,
                    author: pullRequest.author, mergedAt: pullRequest.mergedAt, descriptionMarkdown: "",
                    additions: pullRequest.additions, deletions: pullRequest.deletions, changedFiles: pullRequest.changedFiles,
                    labels: pullRequest.labels, reactions: pullRequest.reactions, comments: [], mediaItems: pullRequest.mediaItems
                )
            }
        )
        let generation = savedFeedGeneration
        return Task { [feedCache] in await feedCache.save(savedFeed, generation: generation) }
    }

    func runLiveRefreshLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(Self.liveRefreshIntervalSeconds))
            } catch {
                return
            }
            await refreshNewestData(reportsFailure: false)
        }
    }

    func refreshAfterReturningToForeground() async {
        await refreshNewestData(reportsFailure: false)
    }

    func refreshFromPull() async {
        isPullToRefreshRunning = true
        defer { isPullToRefreshRunning = false }
        await refreshNewestData(reportsFailure: true)
    }

    // Nil focuses the feed's end. Pages are named by pull request rather than position, since the feed shows only what people the viewer hid didn't post.
    func focusFeedPage(showingPullRequestID focusedPullRequestID: String?) {
        self.focusedPullRequestID = focusedPullRequestID
        isFeedEndFocused = focusedPullRequestID == nil && !pullRequests.isEmpty
        if let firstUnseenNewerPageIndex, focusedPageIndex <= firstUnseenNewerPageIndex {
            unseenNewerPullRequestIDs.removeAll()
        } else if let focusedPullRequestID {
            unseenNewerPullRequestIDs.remove(focusedPullRequestID)
        }
        Task { await refetchPullRequestsAroundFocus() }
    }

    // Newly merged pull requests sort into their groups, so the first unseen one can sit anywhere above the viewer (AGENTS.md, "Feed Order").
    private var firstUnseenNewerPageIndex: Int? {
        pullRequests.firstIndex { unseenNewerPullRequestIDs.contains($0.id) }
    }

    func heroMediaItem(of pullRequest: MergedPullRequest) -> PullRequestMediaItem? {
        pullRequest.mediaItems.first { !unloadableMediaItemIDs.contains($0.id) } ?? pullRequest.mediaItems.first
    }

    // A media item is given up on only once the URL renewed after its failed load fails too, so an expired signed URL never hides it. A pull request none of whose media loads leaves the feed while the viewer is still above it (AGENTS.md, "Feed Order").
    func recoverFromMediaLoadFailure(of mediaItem: PullRequestMediaItem, onPullRequestID pullRequestID: String) async {
        guard let pullRequest = pullRequest(withID: pullRequestID) else { return }
        defer {
            if let pullRequestIndex = index(ofPullRequestID: pullRequestID), pullRequestIndex > focusedPageIndex, !hasLoadableMedia(pullRequests[pullRequestIndex]) {
                pullRequests.remove(at: pullRequestIndex)
            }
        }
        if let urlRenewalDate = urlRenewalDateAfterLoadFailureByMediaItemID[mediaItem.id],
           Date.now.timeIntervalSince(urlRenewalDate) < Self.mediaURLRenewalAgeSeconds {
            unloadableMediaItemIDs.insert(mediaItem.id)
            return
        }
        failedLoadURLByMediaItemID[mediaItem.id] = mediaItem.url
        guard pullRequestIDsRenewingMediaURLsAfterLoadFailure.insert(pullRequestID).inserted else { return }
        defer { pullRequestIDsRenewingMediaURLsAfterLoadFailure.remove(pullRequestID) }
        let renewalStartedAt = Date.now
        await fetchAndApplyPullRequest(number: pullRequest.number, forcesMediaURLRenewal: true)
        guard let renewedPullRequest = self.pullRequest(withID: pullRequestID),
              let mediaFetchedAt = mediaFetchedAtByPullRequestID[pullRequestID],
              mediaFetchedAt >= renewalStartedAt
        else { return }
        for renewedMediaItem in renewedPullRequest.mediaItems {
            guard let failedLoadURL = failedLoadURLByMediaItemID.removeValue(forKey: renewedMediaItem.id) else { continue }
            if failedLoadURL == renewedMediaItem.url {
                unloadableMediaItemIDs.insert(renewedMediaItem.id)
            } else {
                urlRenewalDateAfterLoadFailureByMediaItemID[renewedMediaItem.id] = .now
            }
        }
    }

    func applyFetchedPullRequest(_ fetchedPullRequest: MergedPullRequest) {
        apply(fetchedPullRequest, fetchedAt: .now, forcesMediaURLRenewal: false)
    }

    func appendComment(_ comment: PullRequestComment, toPullRequestID pullRequestID: String) {
        viewerDeletedCommentIDs.remove(comment.id)
        updateOpenWeekCopy(ofPullRequestID: pullRequestID) { openWeekPullRequest in
            if !openWeekPullRequest.comments.contains(where: { $0.id == comment.id }) {
                openWeekPullRequest.comments.append(comment)
            }
        }
        guard let pullRequestIndex = index(ofPullRequestID: pullRequestID),
              !pullRequests[pullRequestIndex].comments.contains(where: { $0.id == comment.id })
        else { return }
        pullRequests[pullRequestIndex].comments.append(comment)
    }

    func removeViewerDeletedComments(withIDs commentIDs: Set<String>, fromPullRequestID pullRequestID: String) {
        viewerDeletedCommentIDs.formUnion(commentIDs)
        updateOpenWeekCopy(ofPullRequestID: pullRequestID) { openWeekPullRequest in
            openWeekPullRequest.comments.removeAll { commentIDs.contains($0.id) }
        }
        guard let pullRequestIndex = index(ofPullRequestID: pullRequestID) else { return }
        pullRequests[pullRequestIndex].comments.removeAll { commentIDs.contains($0.id) }
    }

    func toggleReaction(_ reaction: GitHubReaction, pullRequestID: String) async {
        guard let pullRequest = pullRequest(withID: pullRequestID) else { return }
        await setViewerReaction(reaction, isReacting: !pullRequest.reactions.viewerReactions.contains(reaction), on: pullRequest)
    }

    func likeUnlessAlreadyLiked(pullRequestID: String) async {
        guard let pullRequest = pullRequest(withID: pullRequestID), !pullRequest.reactions.viewerReactions.contains(.heart) else { return }
        await setViewerReaction(.heart, isReacting: true, on: pullRequest)
    }

    private var focusedPageIndex: Int {
        if let focusedPullRequestID, let focusedIndex = index(ofPullRequestID: focusedPullRequestID) {
            return focusedIndex
        }
        return isFeedEndFocused ? pullRequests.count : 0
    }

    private var feedWindowStartDate: Date {
        Date.now.addingTimeInterval(-Self.feedWindowSeconds)
    }

    // The focused card and the one after it are already rendered under the viewer's finger, so a newly found card never lands above or between them unless it's flagged as unseen (AGENTS.md, "Feed Order").
    private var firstUnrenderedPageIndex: Int {
        hasFocusedPage ? min(focusedPageIndex + 2, pullRequests.count) : 0
    }

    private var hasFocusedPage: Bool {
        focusedPullRequestID != nil || isFeedEndFocused
    }

    // A pull request found after the feed opened sorts only into the cards after the one in focus and the one after it, since both are already rendered (AGENTS.md, "Feed Order").
    private func insertFoundPullRequests(_ foundPullRequests: [MergedPullRequest], mergedWindowStartDate: Date, fetchedAt: Date) {
        var knownPullRequestIDs = Set(pullRequests.map(\.id))
        for foundPullRequest in foundPullRequests {
            guard foundPullRequest.belongsInFeed(mergedWindowStartDate: mergedWindowStartDate),
                  hasLoadableMedia(foundPullRequest),
                  knownPullRequestIDs.insert(foundPullRequest.id).inserted
            else { continue }
            mediaFetchedAtByPullRequestID[foundPullRequest.id] = fetchedAt
            pullRequests.insert(foundPullRequest, at: feedOrderInsertionIndex(of: foundPullRequest, searchingFrom: firstUnrenderedPageIndex))
        }
    }

    private func feedOrderInsertionIndex(of pullRequest: MergedPullRequest, searchingFrom startIndex: Int) -> Int {
        pullRequests[startIndex...].firstIndex { pullRequest.comesBeforeInFeed($0) } ?? pullRequests.count
    }

    private func insertIntoFeedOrderFlaggingUnseen(_ pullRequest: MergedPullRequest) {
        let feedOrderIndex = feedOrderInsertionIndex(of: pullRequest, searchingFrom: 0)
        if hasFocusedPage, feedOrderIndex <= focusedPageIndex {
            pullRequests.insert(pullRequest, at: feedOrderIndex)
            unseenNewerPullRequestIDs.insert(pullRequest.id)
        } else {
            pullRequests.insert(pullRequest, at: max(feedOrderIndex, firstUnrenderedPageIndex))
        }
    }

    // A card ages out of the window without GitHub reporting a change, so each refresh drops the ones the feed's rules no longer admit, except the one under the viewer's finger (AGENTS.md, "Feed Order").
    private func removeCardsThatLeftTheFeed() {
        let windowStartDate = feedWindowStartDate
        pullRequests.removeAll { $0.id != focusedPullRequestID && !$0.belongsInFeed(mergedWindowStartDate: windowStartDate) }
        unseenNewerPullRequestIDs.formIntersection(pullRequests.map(\.id))
    }

    private func index(ofPullRequestID pullRequestID: String) -> Int? {
        pullRequests.firstIndex { $0.id == pullRequestID }
    }

    private func hasLoadableMedia(_ pullRequest: MergedPullRequest) -> Bool {
        pullRequest.mediaItems.contains { !unloadableMediaItemIDs.contains($0.id) }
    }

    private func isMediaURLRenewalDue(forPullRequestID pullRequestID: String) -> Bool {
        Date.now.timeIntervalSince(mediaFetchedAtByPullRequestID[pullRequestID] ?? .distantPast) > Self.mediaURLRenewalAgeSeconds
    }

    private func refreshNewestData(reportsFailure: Bool) async {
        if feedLoadFailureMessage != nil {
            await loadFeed()
        }
        guard !isRefreshRunning, let nextUpdateSearchStartDate else { return }
        isRefreshRunning = true
        defer { isRefreshRunning = false }
        removeCardsThatLeftTheFeed()
        if let focusedPullRequestID, let focusedPullRequest = pullRequest(withID: focusedPullRequestID) {
            await fetchAndApplyPullRequest(number: focusedPullRequest.number, forcesMediaURLRenewal: false)
        }
        let refreshStartedAt = Date.now
        do {
            let updatedPullRequestSearch = try await githubAPIClient.searchMergedPullRequests(
                updatedSince: nextUpdateSearchStartDate.addingTimeInterval(-Self.updateSearchOverlapSeconds),
                mergedFrom: nil,
                mergedThrough: refreshStartedAt
            )
            var updatedPullRequestCount = 0
            for try await updatedPullRequestPage in updatedPullRequestSearch {
                for updatedPullRequest in updatedPullRequestPage.sorted(by: { $0.mergedAt < $1.mergedAt }) {
                    apply(updatedPullRequest, fetchedAt: refreshStartedAt, forcesMediaURLRenewal: false)
                }
                updatedPullRequestCount += updatedPullRequestPage.count
            }
            try Task.checkCancellation()
            Self.logger.debug("Read \(updatedPullRequestCount, privacy: .public) pull requests updated since \(nextUpdateSearchStartDate.formatted(.iso8601), privacy: .public) in \(Self.millisecondsElapsed(since: refreshStartedAt), privacy: .public) ms")
            self.nextUpdateSearchStartDate = refreshStartedAt
        } catch {
            if error.isTaskCancellation { return }
            if let githubAPIError = error as? GitHubAPIError, githubAPIError.rejectsFeedAccess {
                handleRejectedGitHubAccess(githubAPIError)
                return
            }
            Self.logger.error("Refreshing the feed failed: \(error.publicLogDescription, privacy: .public)")
            if reportsFailure {
                transientErrorMessage = "Couldn't refresh. \(error.localizedDescription)"
            }
        }
    }

    private func refetchPullRequestsAroundFocus() async {
        guard let focusedPullRequestID, let focusedIndex = index(ofPullRequestID: focusedPullRequestID) else { return }
        let focusedPullRequest = pullRequests[focusedIndex]
        async let focusedPullRequestRefetch: Void = fetchAndApplyPullRequest(
            number: focusedPullRequest.number,
            forcesMediaURLRenewal: isMediaURLRenewalDue(forPullRequestID: focusedPullRequest.id)
        )
        if pullRequests.indices.contains(focusedIndex + 1) {
            let nextPullRequest = pullRequests[focusedIndex + 1]
            if isMediaURLRenewalDue(forPullRequestID: nextPullRequest.id) {
                await fetchAndApplyPullRequest(number: nextPullRequest.number, forcesMediaURLRenewal: true)
            }
        }
        await focusedPullRequestRefetch
    }

    private func fetchAndApplyPullRequest(number: Int, forcesMediaURLRenewal: Bool) async {
        let fetchStartedAt = Date.now
        do {
            let fetchedPullRequest = try await githubAPIClient.fetchMergedPullRequest(number: number)
            apply(fetchedPullRequest, fetchedAt: fetchStartedAt, forcesMediaURLRenewal: forcesMediaURLRenewal)
        } catch {
            if error.isTaskCancellation { return }
            if let githubAPIError = error as? GitHubAPIError, githubAPIError.rejectsFeedAccess {
                handleRejectedGitHubAccess(githubAPIError)
                return
            }
            Self.logger.error("Refetching #\(number, privacy: .public) failed: \(error.publicLogDescription, privacy: .public)")
        }
    }

    // The focused card keeps its signed media URLs so a playing video isn't reloaded; a load failure renews them.
    private func apply(_ fetchedPullRequest: MergedPullRequest, fetchedAt: Date, forcesMediaURLRenewal: Bool) {
        updateOpenWeekCopy(ofPullRequestID: fetchedPullRequest.id) { openWeekPullRequest in
            var updatedOpenWeekPullRequest = fetchedPullRequest
            updatedOpenWeekPullRequest.comments.removeAll { viewerDeletedCommentIDs.contains($0.id) }
            if reactionWriteCountByPullRequestID[fetchedPullRequest.id, default: 0] > 0 {
                updatedOpenWeekPullRequest.reactions = openWeekPullRequest.reactions
            }
            openWeekPullRequest = updatedOpenWeekPullRequest
        }
        if index(ofPullRequestID: fetchedPullRequest.id) == nil, openWeekPullRequests.contains(where: { $0.id == fetchedPullRequest.id }) {
            mediaFetchedAtByPullRequestID[fetchedPullRequest.id] = fetchedAt
        }
        guard let existingIndex = index(ofPullRequestID: fetchedPullRequest.id) else {
            guard fetchedPullRequest.belongsInFeed(mergedWindowStartDate: feedWindowStartDate), hasLoadableMedia(fetchedPullRequest) else { return }
            mediaFetchedAtByPullRequestID[fetchedPullRequest.id] = fetchedAt
            insertIntoFeedOrderFlaggingUnseen(fetchedPullRequest)
            return
        }
        let existingPullRequest = pullRequests[existingIndex]
        let isFocused = existingPullRequest.id == focusedPullRequestID
        if !fetchedPullRequest.belongsInFeed(mergedWindowStartDate: feedWindowStartDate), !isFocused {
            pullRequests.remove(at: existingIndex)
            unseenNewerPullRequestIDs.remove(existingPullRequest.id)
            return
        }
        var updatedPullRequest = fetchedPullRequest
        updatedPullRequest.comments.removeAll { viewerDeletedCommentIDs.contains($0.id) }
        if reactionWriteCountByPullRequestID[fetchedPullRequest.id, default: 0] > 0 {
            updatedPullRequest.reactions = existingPullRequest.reactions
        }
        if forcesMediaURLRenewal || !isFocused {
            mediaFetchedAtByPullRequestID[fetchedPullRequest.id] = fetchedAt
        } else {
            let existingMediaItemsByID = Dictionary(
                existingPullRequest.mediaItems.filter { $0.url != nil }.map { ($0.id, $0) },
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
        if updatedPullRequest.feedGroup != existingPullRequest.feedGroup, existingIndex >= firstUnrenderedPageIndex {
            pullRequests.remove(at: existingIndex)
            insertIntoFeedOrderFlaggingUnseen(updatedPullRequest)
        } else if updatedPullRequest != existingPullRequest {
            pullRequests[existingIndex] = updatedPullRequest
        }
    }

    private func setViewerReaction(_ reaction: GitHubReaction, isReacting: Bool, on pullRequest: MergedPullRequest) async {
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
        updateOpenWeekCopy(ofPullRequestID: pullRequestID) { update(&$0.reactions) }
        guard let pullRequestIndex = index(ofPullRequestID: pullRequestID) else { return }
        update(&pullRequests[pullRequestIndex].reactions)
    }

    // A pull request can be both in the feed and in the open week, and every change shows on both cards.
    private func updateOpenWeekCopy(ofPullRequestID pullRequestID: String, _ update: (inout MergedPullRequest) -> Void) {
        guard let openWeekIndex = openWeekPullRequests.firstIndex(where: { $0.id == pullRequestID }) else { return }
        update(&openWeekPullRequests[openWeekIndex])
    }

    private static func millisecondsElapsed(since startDate: Date) -> Int {
        Int(Date.now.timeIntervalSince(startDate) * 1000)
    }
}
