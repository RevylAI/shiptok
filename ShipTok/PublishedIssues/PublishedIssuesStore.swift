import Foundation
import Observation
import OSLog

// The cards of a mode that shows published issues, Weekly's weeks or Features' features: every one, read whole from GitHub on each read (AGENTS.md, "Published Issues").
@Observable
@MainActor
final class PublishedIssuesStore<Issue: PublishedIssue> {
    private static var mediaURLRenewalAgeSeconds: TimeInterval { 120 }
    private static var logger: Logger { Logger(subsystem: "ai.revyl.shiptok", category: "published-issues") }

    private(set) var publishedIssues: [Issue] = []
    private(set) var isLoaded = false
    private(set) var loadFailureMessage: String?
    private(set) var isPullToRefreshRunning = false
    var transientErrorMessage: String?

    private var isRefreshRunning = false
    private var fetchedAt: Date?
    private var mediaLoadFailureRecovery = MediaLoadFailureRecovery()
    private var reactionWriteCountByPublishedIssueID: [String: Int] = [:]
    // Each local change to an issue takes a new generation, so a read that started before it keeps that issue's reactions and comments (AGENTS.md, "Published Issues").
    private var localChangeGeneration = 0
    private var localChangeGenerationByPublishedIssueID: [String: Int] = [:]
    private var viewerDeletedCommentIDs: Set<String> = []
    private let githubAPIClient: GitHubAPIClient
    private let reactionWriteQueue: ViewerReactionWriteQueue
    private let analytics: ShipTokAnalytics
    private let handleRejectedGitHubAccess: @MainActor (GitHubAPIError) -> Void

    init(githubAPIClient: GitHubAPIClient, analytics: ShipTokAnalytics, handleRejectedGitHubAccess: @escaping @MainActor (GitHubAPIError) -> Void) {
        self.githubAPIClient = githubAPIClient
        reactionWriteQueue = ViewerReactionWriteQueue(githubAPIClient: githubAPIClient)
        self.analytics = analytics
        self.handleRejectedGitHubAccess = handleRejectedGitHubAccess
    }

    var unloadableMediaItemIDs: Set<String> {
        mediaLoadFailureRecovery.unloadableMediaItemIDs
    }

    func publishedIssue(withID publishedIssueID: String) -> Issue? {
        publishedIssues.first { $0.id == publishedIssueID }
    }

    func heroMediaItem(of publishedIssue: Issue) -> PullRequestMediaItem? {
        publishedIssue.mediaItems.first { !unloadableMediaItemIDs.contains($0.id) } ?? publishedIssue.mediaItems.first
    }

    // Signed media URLs stop working minutes after a fetch, so cards shown later read the issues again first.
    func refreshIfMediaURLsAreStale() async {
        guard Date.now.timeIntervalSince(fetchedAt ?? .distantPast) > Self.mediaURLRenewalAgeSeconds else { return }
        await refresh(reportsFailure: false)
    }

    func refreshFromPull() async {
        isPullToRefreshRunning = true
        defer { isPullToRefreshRunning = false }
        await refresh(reportsFailure: true)
    }

    func refresh() async {
        await refresh(reportsFailure: false)
    }

    func recoverFromMediaLoadFailure(of mediaItem: PullRequestMediaItem, wasRefusedToViewer: Bool) async {
        guard mediaLoadFailureRecovery.recordLoadFailure(of: mediaItem, wasRefusedToViewer: wasRefusedToViewer) else { return }
        await refresh(reportsFailure: false)
    }

    func applyFetchedPublishedIssue(_ fetchedPublishedIssue: Issue) {
        recordLocalChange(toPublishedIssueID: fetchedPublishedIssue.id)
        guard let publishedIssueIndex = publishedIssues.firstIndex(where: { $0.id == fetchedPublishedIssue.id }) else { return }
        publishedIssues[publishedIssueIndex] = keepingLocalWrites(of: publishedIssues[publishedIssueIndex], in: fetchedPublishedIssue)
    }

    func appendComment(_ comment: PullRequestComment, toPublishedIssueID publishedIssueID: String) {
        recordLocalChange(toPublishedIssueID: publishedIssueID)
        viewerDeletedCommentIDs.remove(comment.id)
        guard let publishedIssueIndex = publishedIssues.firstIndex(where: { $0.id == publishedIssueID }),
              !publishedIssues[publishedIssueIndex].comments.contains(where: { $0.id == comment.id })
        else { return }
        publishedIssues[publishedIssueIndex].comments.append(comment)
    }

    func removeViewerDeletedComments(withIDs commentIDs: Set<String>, fromPublishedIssueID publishedIssueID: String) {
        recordLocalChange(toPublishedIssueID: publishedIssueID)
        viewerDeletedCommentIDs.formUnion(commentIDs)
        guard let publishedIssueIndex = publishedIssues.firstIndex(where: { $0.id == publishedIssueID }) else { return }
        publishedIssues[publishedIssueIndex].comments.removeAll { commentIDs.contains($0.id) }
    }

    func toggleReaction(_ reaction: GitHubReaction, publishedIssueID: String) async {
        guard let publishedIssue = publishedIssue(withID: publishedIssueID) else { return }
        await setViewerReaction(reaction, isReacting: !publishedIssue.reactions.viewerReactions.contains(reaction), on: publishedIssue)
    }

    func likeUnlessAlreadyLiked(publishedIssueID: String) async {
        guard let publishedIssue = publishedIssue(withID: publishedIssueID), !publishedIssue.reactions.viewerReactions.contains(.heart) else { return }
        await setViewerReaction(.heart, isReacting: true, on: publishedIssue)
    }

    // A media load that fails while a read runs is newer than that read, which settles only older failures, so the refresh reads once more for it.
    private func refresh(reportsFailure: Bool) async {
        guard !isRefreshRunning else { return }
        isRefreshRunning = true
        defer { isRefreshRunning = false }
        var fetchStartedAt = Date.now
        while await fetchAndApplyPublishedIssues(startedAt: fetchStartedAt, reportsFailure: reportsFailure),
              mediaLoadFailureRecovery.hasLoadFailureRecorded(after: fetchStartedAt) {
            fetchStartedAt = .now
        }
    }

    private func fetchAndApplyPublishedIssues(startedAt fetchStartedAt: Date, reportsFailure: Bool) async -> Bool {
        let localChangeGenerationAtFetchStart = localChangeGeneration
        do {
            let fetchedPublishedIssues = try await Issue.fetchEveryPublishedIssue(from: githubAPIClient)
            publishedIssues = fetchedPublishedIssues.map { fetchedPublishedIssue in
                guard let existingPublishedIssue = publishedIssue(withID: fetchedPublishedIssue.id) else { return fetchedPublishedIssue }
                var updatedPublishedIssue = keepingLocalWrites(of: existingPublishedIssue, in: fetchedPublishedIssue)
                if localChangeGenerationByPublishedIssueID[fetchedPublishedIssue.id, default: 0] > localChangeGenerationAtFetchStart {
                    updatedPublishedIssue.reactions = existingPublishedIssue.reactions
                    updatedPublishedIssue.comments = existingPublishedIssue.comments
                }
                return updatedPublishedIssue
            }
            if mediaLoadFailureRecovery.hasPendingLoadFailure {
                mediaLoadFailureRecovery.settleLoadFailures(of: fetchedPublishedIssues.flatMap(\.mediaItems), readStartedAt: fetchStartedAt)
            }
            fetchedAt = fetchStartedAt
            isLoaded = true
            loadFailureMessage = nil
            Self.logger.info("Read \(fetchedPublishedIssues.count, privacy: .public) \(String(describing: Issue.self), privacy: .public) issues in \(Int(Date.now.timeIntervalSince(fetchStartedAt) * 1000), privacy: .public) ms")
            return true
        } catch {
            if error.isTaskCancellation { return false }
            if let githubAPIError = error as? GitHubAPIError, githubAPIError.rejectsFeedAccess {
                handleRejectedGitHubAccess(githubAPIError)
                return false
            }
            Self.logger.error("Reading the \(String(describing: Issue.self), privacy: .public) issues failed: \(error.publicLogDescription, privacy: .public)")
            if !isLoaded {
                loadFailureMessage = error.localizedDescription
            } else if reportsFailure {
                transientErrorMessage = "Couldn't refresh. \(error.localizedDescription)"
            }
            return false
        }
    }

    private func setViewerReaction(_ reaction: GitHubReaction, isReacting: Bool, on publishedIssue: Issue) async {
        let publishedIssueID = publishedIssue.id
        let attempt = analytics.requestMutation(.reaction, change: isReacting ? .add : .remove,
            subject: ShipTokAnalyticsSubject(kind: Issue.analyticsSubjectKind, nodeID: publishedIssueID, number: publishedIssue.number),
            reaction: reaction)
        updateReactions(ofPublishedIssueID: publishedIssueID) { $0.setViewerHasReacted(isReacting, with: reaction) }
        recordLocalChange(toPublishedIssueID: publishedIssueID)
        reactionWriteCountByPublishedIssueID[publishedIssueID, default: 0] += 1
        defer {
            let remainingWriteCount = reactionWriteCountByPublishedIssueID[publishedIssueID, default: 1] - 1
            reactionWriteCountByPublishedIssueID[publishedIssueID] = remainingWriteCount > 0 ? remainingWriteCount : nil
            recordLocalChange(toPublishedIssueID: publishedIssueID)
        }
        switch await reactionWriteQueue.write(reaction, viewerHasReacted: isReacting, onSubjectID: publishedIssueID) {
        case .succeeded:
            analytics.capture(.mutationCompleted(attempt, outcome: .succeeded, commentID: nil, commentDatabaseID: nil))
        case .failed(let error, let restoredViewerHasReacted):
            analytics.capture(.mutationCompleted(attempt, outcome: error.isTaskCancellation ? .cancelled : .failed,
                                                  commentID: nil, commentDatabaseID: nil))
            if let restoredViewerHasReacted {
                updateReactions(ofPublishedIssueID: publishedIssueID) { $0.setViewerHasReacted(restoredViewerHasReacted, with: reaction) }
            }
            if error.isTaskCancellation { return }
            if let githubAPIError = error as? GitHubAPIError, githubAPIError.rejectsFeedAccess {
                handleRejectedGitHubAccess(githubAPIError)
                return
            }
            let failedAction = switch (reaction, isReacting) {
            case (.heart, true): "like \(publishedIssue.reference)"
            case (.heart, false): "unlike \(publishedIssue.reference)"
            case (_, true): "react \(reaction.emoji) to \(publishedIssue.reference)"
            case (_, false): "remove \(reaction.emoji) from \(publishedIssue.reference)"
            }
            transientErrorMessage = "Couldn't \(failedAction). \(error.localizedDescription)"
        }
    }

    // GitHub can answer with a reaction still in flight or a comment the viewer just deleted, so the local copy wins for those.
    private func keepingLocalWrites(of existingPublishedIssue: Issue, in fetchedPublishedIssue: Issue) -> Issue {
        var updatedPublishedIssue = fetchedPublishedIssue
        if reactionWriteCountByPublishedIssueID[fetchedPublishedIssue.id, default: 0] > 0 {
            updatedPublishedIssue.reactions = existingPublishedIssue.reactions
        }
        updatedPublishedIssue.comments.removeAll { viewerDeletedCommentIDs.contains($0.id) }
        return updatedPublishedIssue
    }

    private func recordLocalChange(toPublishedIssueID publishedIssueID: String) {
        localChangeGeneration += 1
        localChangeGenerationByPublishedIssueID[publishedIssueID] = localChangeGeneration
    }

    private func updateReactions(ofPublishedIssueID publishedIssueID: String, _ update: (inout GitHubReactionSummary) -> Void) {
        guard let publishedIssueIndex = publishedIssues.firstIndex(where: { $0.id == publishedIssueID }) else { return }
        update(&publishedIssues[publishedIssueIndex].reactions)
    }
}
