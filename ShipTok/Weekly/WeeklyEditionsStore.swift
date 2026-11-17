import Foundation
import Observation
import OSLog

// The weekly mode's cards: every published weekly edition, read whole from GitHub (shiptok/AGENTS.md, Weekly Mode).
@Observable
@MainActor
final class WeeklyEditionsStore {
    private static let mediaURLRenewalAgeSeconds: TimeInterval = 120
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "weekly")

    private(set) var weeklyEditions: [WeeklyEdition] = []
    private(set) var isLoaded = false
    private(set) var loadFailureMessage: String?
    private(set) var isPullToRefreshRunning = false
    private(set) var unloadableMediaItemIDs: Set<String> = []
    var transientErrorMessage: String?

    private var isRefreshRunning = false
    private var fetchedAt: Date?
    private var urlRenewalDateAfterLoadFailureByMediaItemID: [String: Date] = [:]
    private var reactionWriteCountByWeeklyEditionID: [String: Int] = [:]
    private var viewerDeletedCommentIDs: Set<String> = []
    private let githubAPIClient: GitHubAPIClient
    private let analytics: ShipTokAnalytics
    private let handleRejectedGitHubAccess: @MainActor (GitHubAPIError) -> Void

    init(githubAPIClient: GitHubAPIClient, analytics: ShipTokAnalytics, handleRejectedGitHubAccess: @escaping @MainActor (GitHubAPIError) -> Void) {
        self.githubAPIClient = githubAPIClient
        self.analytics = analytics
        self.handleRejectedGitHubAccess = handleRejectedGitHubAccess
    }

    func weeklyEdition(withID weeklyEditionID: String) -> WeeklyEdition? {
        weeklyEditions.first { $0.id == weeklyEditionID }
    }

    func heroMediaItem(of weeklyEdition: WeeklyEdition) -> PullRequestMediaItem? {
        weeklyEdition.mediaItems.first { !unloadableMediaItemIDs.contains($0.id) } ?? weeklyEdition.mediaItems.first
    }

    // Signed media URLs stop working minutes after a fetch, so weekly cards shown later read the editions again first.
    func refreshIfMediaURLsAreStale() async {
        guard Date.now.timeIntervalSince(fetchedAt ?? .distantPast) > Self.mediaURLRenewalAgeSeconds else { return }
        await refresh(reportsFailure: false)
    }

    func refreshFromPull() async {
        isPullToRefreshRunning = true
        defer { isPullToRefreshRunning = false }
        await refresh(reportsFailure: true)
    }

    func retryLoad() async {
        await refresh(reportsFailure: false)
    }

    // A media item is given up on only once the URL renewed after its failed load fails too, so an expired signed URL never hides it.
    func recoverFromMediaLoadFailure(of mediaItem: PullRequestMediaItem) async {
        if let urlRenewalDate = urlRenewalDateAfterLoadFailureByMediaItemID[mediaItem.id],
           Date.now.timeIntervalSince(urlRenewalDate) < Self.mediaURLRenewalAgeSeconds {
            unloadableMediaItemIDs.insert(mediaItem.id)
            return
        }
        urlRenewalDateAfterLoadFailureByMediaItemID[mediaItem.id] = .now
        await refresh(reportsFailure: false)
    }

    func applyFetchedWeeklyEdition(_ fetchedWeeklyEdition: WeeklyEdition) {
        guard let weeklyEditionIndex = weeklyEditions.firstIndex(where: { $0.id == fetchedWeeklyEdition.id }) else { return }
        weeklyEditions[weeklyEditionIndex] = keepingLocalWrites(of: weeklyEditions[weeklyEditionIndex], in: fetchedWeeklyEdition)
    }

    func appendComment(_ comment: PullRequestComment, toWeeklyEditionID weeklyEditionID: String) {
        viewerDeletedCommentIDs.remove(comment.id)
        guard let weeklyEditionIndex = weeklyEditions.firstIndex(where: { $0.id == weeklyEditionID }),
              !weeklyEditions[weeklyEditionIndex].comments.contains(where: { $0.id == comment.id })
        else { return }
        weeklyEditions[weeklyEditionIndex].comments.append(comment)
    }

    func removeViewerDeletedComments(withIDs commentIDs: Set<String>, fromWeeklyEditionID weeklyEditionID: String) {
        viewerDeletedCommentIDs.formUnion(commentIDs)
        guard let weeklyEditionIndex = weeklyEditions.firstIndex(where: { $0.id == weeklyEditionID }) else { return }
        weeklyEditions[weeklyEditionIndex].comments.removeAll { commentIDs.contains($0.id) }
    }

    func toggleReaction(_ reaction: GitHubReaction, weeklyEditionID: String) async {
        guard let weeklyEdition = weeklyEdition(withID: weeklyEditionID) else { return }
        await setViewerReaction(reaction, isReacting: !weeklyEdition.reactions.viewerReactions.contains(reaction), on: weeklyEdition)
    }

    func likeUnlessAlreadyLiked(weeklyEditionID: String) async {
        guard let weeklyEdition = weeklyEdition(withID: weeklyEditionID), !weeklyEdition.reactions.viewerReactions.contains(.heart) else { return }
        await setViewerReaction(.heart, isReacting: true, on: weeklyEdition)
    }

    private func refresh(reportsFailure: Bool) async {
        guard !isRefreshRunning else { return }
        isRefreshRunning = true
        defer { isRefreshRunning = false }
        let fetchStartedAt = Date.now
        do {
            let fetchedWeeklyEditions = try await githubAPIClient.fetchWeeklyEditions()
            weeklyEditions = fetchedWeeklyEditions.map { fetchedWeeklyEdition in
                guard let existingWeeklyEdition = weeklyEdition(withID: fetchedWeeklyEdition.id) else { return fetchedWeeklyEdition }
                return keepingLocalWrites(of: existingWeeklyEdition, in: fetchedWeeklyEdition)
            }
            fetchedAt = fetchStartedAt
            isLoaded = true
            loadFailureMessage = nil
            Self.logger.info("Read \(fetchedWeeklyEditions.count, privacy: .public) weekly editions in \(Int(Date.now.timeIntervalSince(fetchStartedAt) * 1000), privacy: .public) ms")
        } catch {
            if error.isTaskCancellation { return }
            if let githubAPIError = error as? GitHubAPIError, githubAPIError.rejectsFeedAccess {
                handleRejectedGitHubAccess(githubAPIError)
                return
            }
            Self.logger.error("Reading the weekly editions failed: \(Self.safeFailureDescription(error), privacy: .public)")
            if !isLoaded {
                loadFailureMessage = error.localizedDescription
            } else if reportsFailure {
                transientErrorMessage = "Couldn't refresh. \(error.localizedDescription)"
            }
        }
    }

    private func setViewerReaction(_ reaction: GitHubReaction, isReacting: Bool, on weeklyEdition: WeeklyEdition) async {
        let weeklyEditionID = weeklyEdition.id
        let attempt = analytics.requestMutation(.reaction, change: isReacting ? .add : .remove,
            subject: ShipTokAnalyticsSubject(kind: .weeklyEdition, nodeID: weeklyEditionID, number: weeklyEdition.number),
            reaction: reaction)
        updateReactions(ofWeeklyEditionID: weeklyEditionID) { $0.setViewerHasReacted(isReacting, with: reaction) }
        reactionWriteCountByWeeklyEditionID[weeklyEditionID, default: 0] += 1
        defer {
            let remainingWriteCount = reactionWriteCountByWeeklyEditionID[weeklyEditionID, default: 1] - 1
            reactionWriteCountByWeeklyEditionID[weeklyEditionID] = remainingWriteCount > 0 ? remainingWriteCount : nil
        }
        do {
            if isReacting {
                try await githubAPIClient.addReaction(reaction, toSubjectID: weeklyEditionID)
            } else {
                try await githubAPIClient.removeReaction(reaction, fromSubjectID: weeklyEditionID)
            }
            analytics.capture(.mutationCompleted(attempt, outcome: .succeeded, commentID: nil, commentDatabaseID: nil))
        } catch {
            analytics.capture(.mutationCompleted(attempt, outcome: error.isTaskCancellation ? .cancelled : .failed,
                                                  commentID: nil, commentDatabaseID: nil))
            updateReactions(ofWeeklyEditionID: weeklyEditionID) { $0.setViewerHasReacted(!isReacting, with: reaction) }
            if error.isTaskCancellation { return }
            if let githubAPIError = error as? GitHubAPIError, githubAPIError.rejectsFeedAccess {
                handleRejectedGitHubAccess(githubAPIError)
                return
            }
            let failedAction = switch (reaction, isReacting) {
            case (.heart, true): "like the week of \(weeklyEdition.weekDatesText)"
            case (.heart, false): "unlike the week of \(weeklyEdition.weekDatesText)"
            case (_, true): "react \(reaction.emoji) to the week of \(weeklyEdition.weekDatesText)"
            case (_, false): "remove \(reaction.emoji) from the week of \(weeklyEdition.weekDatesText)"
            }
            transientErrorMessage = "Couldn't \(failedAction). \(error.localizedDescription)"
        }
    }

    // GitHub can answer with a reaction still in flight or a comment the viewer just deleted, so the local copy wins for those.
    private func keepingLocalWrites(of existingWeeklyEdition: WeeklyEdition, in fetchedWeeklyEdition: WeeklyEdition) -> WeeklyEdition {
        var updatedWeeklyEdition = fetchedWeeklyEdition
        if reactionWriteCountByWeeklyEditionID[fetchedWeeklyEdition.id, default: 0] > 0 {
            updatedWeeklyEdition.reactions = existingWeeklyEdition.reactions
        }
        updatedWeeklyEdition.comments.removeAll { viewerDeletedCommentIDs.contains($0.id) }
        return updatedWeeklyEdition
    }

    private func updateReactions(ofWeeklyEditionID weeklyEditionID: String, _ update: (inout GitHubReactionSummary) -> Void) {
        guard let weeklyEditionIndex = weeklyEditions.firstIndex(where: { $0.id == weeklyEditionID }) else { return }
        update(&weeklyEditions[weeklyEditionIndex].reactions)
    }

    private static func safeFailureDescription(_ error: Error) -> String {
        if let githubAPIError = error as? GitHubAPIError {
            return githubAPIError.localizedDescription
        }
        if let urlError = error as? URLError {
            return "URLError \(urlError.code.rawValue)"
        }
        return String(describing: type(of: error))
    }
}
