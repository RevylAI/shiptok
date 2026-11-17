import Foundation
import Observation
import UIKit

private let commentsRefreshIntervalSeconds = 5

@Observable
@MainActor
final class PullRequestCommentsStore<Thread: GitHubCommentThread> {
    private(set) var thread: Thread
    private(set) var isPostingComment = false
    private(set) var refreshFailureMessage: String?
    var actionFailureMessage: String?
    private var localChangeGeneration = 0
    private var deletedCommentIDs: Set<String> = []
    private let githubAPIClient: GitHubAPIClient
    private let analytics: ShipTokAnalytics
    private let analyticsSubject: ShipTokAnalyticsSubject
    private let fetchLatestThread: (Int) async throws -> Thread
    private let onThreadChanged: (Thread) -> Void

    init(
        thread: Thread,
        githubAPIClient: GitHubAPIClient,
        analytics: ShipTokAnalytics,
        analyticsSubject: ShipTokAnalyticsSubject,
        fetchLatestThread: @escaping (Int) async throws -> Thread,
        onThreadChanged: @escaping (Thread) -> Void
    ) {
        self.thread = thread
        self.githubAPIClient = githubAPIClient
        self.analytics = analytics
        self.analyticsSubject = analyticsSubject
        self.fetchLatestThread = fetchLatestThread
        self.onThreadChanged = onThreadChanged
    }

    func refresh() async {
        let localChangeGenerationAtFetchStart = localChangeGeneration
        do {
            var fetchedThread = try await fetchLatestThread(thread.number)
            fetchedThread.comments.removeAll { deletedCommentIDs.contains($0.id) }
            refreshFailureMessage = nil
            guard localChangeGeneration == localChangeGenerationAtFetchStart,
                  Self.hasVisibleChanges(from: thread, to: fetchedThread) else { return }
            thread = fetchedThread
            onThreadChanged(fetchedThread)
        } catch {
            if Task.isCancelled { return }
            refreshFailureMessage = error.localizedDescription
        }
    }

    func runLiveRefreshLoop() async {
        let foregroundRefreshTask = Task {
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                await refresh()
            }
        }
        defer { foregroundRefreshTask.cancel() }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(commentsRefreshIntervalSeconds))
        }
    }

    func postComment(bodyMarkdown: String) async -> PullRequestComment? {
        let attempt = analytics.requestMutation(.comment, change: .add, subject: analyticsSubject)
        isPostingComment = true
        defer { isPostingComment = false }
        do {
            let postedComment = try await githubAPIClient.addComment(bodyMarkdown: bodyMarkdown, toSubjectID: thread.id)
            localChangeGeneration += 1
            thread.comments.append(postedComment)
            onThreadChanged(thread)
            analytics.capture(.mutationCompleted(attempt, outcome: .succeeded,
                                                  commentID: postedComment.id, commentDatabaseID: postedComment.databaseID))
            return postedComment
        } catch {
            analytics.capture(.mutationCompleted(attempt, outcome: error.isTaskCancellation ? .cancelled : .failed,
                                                  commentID: nil, commentDatabaseID: nil))
            actionFailureMessage = error.localizedDescription
            return nil
        }
    }

    func deleteComment(id commentID: String) async {
        guard let commentIndex = thread.comments.firstIndex(where: { $0.id == commentID }) else { return }
        localChangeGeneration += 1
        deletedCommentIDs.insert(commentID)
        let deletedComment = thread.comments.remove(at: commentIndex)
        let deletedVibe = PullRequestVibeComment(comment: deletedComment)?.vibe
        let attempt = analytics.requestMutation(deletedVibe == nil ? .comment : .vibe, change: .remove,
                                                subject: analyticsSubject, vibe: deletedVibe, commentID: commentID)
        defer { localChangeGeneration += 1 }
        do {
            try await githubAPIClient.deleteComment(id: commentID)
            analytics.capture(.mutationCompleted(attempt, outcome: .succeeded,
                                                  commentID: commentID, commentDatabaseID: deletedComment.databaseID))
            onThreadChanged(thread)
        } catch {
            analytics.capture(.mutationCompleted(attempt, outcome: error.isTaskCancellation ? .cancelled : .failed,
                                                  commentID: commentID, commentDatabaseID: deletedComment.databaseID))
            deletedCommentIDs.remove(commentID)
            thread.comments.insert(deletedComment, at: min(commentIndex, thread.comments.endIndex))
            actionFailureMessage = error.localizedDescription
        }
    }

    func toggleReaction(_ reaction: GitHubReaction, onCommentID commentID: String) async {
        guard let commentIndex = thread.comments.firstIndex(where: { $0.id == commentID }) else { return }
        let previousReactions = thread.comments[commentIndex].reactions
        let isAddingReaction = !previousReactions.viewerReactions.contains(reaction)
        let attempt = analytics.requestMutation(.reaction, change: isAddingReaction ? .add : .remove,
                                                subject: analyticsSubject, reaction: reaction, commentID: commentID)
        localChangeGeneration += 1
        thread.comments[commentIndex].reactions.setViewerHasReacted(isAddingReaction, with: reaction)
        defer { localChangeGeneration += 1 }
        do {
            if isAddingReaction {
                try await githubAPIClient.addReaction(reaction, toSubjectID: commentID)
            } else {
                try await githubAPIClient.removeReaction(reaction, fromSubjectID: commentID)
            }
            analytics.capture(.mutationCompleted(attempt, outcome: .succeeded, commentID: commentID, commentDatabaseID: nil))
            onThreadChanged(thread)
        } catch {
            analytics.capture(.mutationCompleted(attempt, outcome: error.isTaskCancellation ? .cancelled : .failed,
                                                  commentID: commentID, commentDatabaseID: nil))
            if let revertIndex = thread.comments.firstIndex(where: { $0.id == commentID }) {
                thread.comments[revertIndex].reactions = previousReactions
            }
            actionFailureMessage = error.localizedDescription
        }
    }

    // GitHub re-signs the media URLs in mediaItems on every fetch, so whole-value equality always differs.
    private static func hasVisibleChanges(from currentThread: Thread, to fetchedThread: Thread) -> Bool {
        currentThread.reactions != fetchedThread.reactions
            || currentThread.mediaItems.map(\.id) != fetchedThread.mediaItems.map(\.id)
            || currentThread.comments.count != fetchedThread.comments.count
            || zip(currentThread.comments, fetchedThread.comments).contains { currentComment, fetchedComment in
                currentComment.id != fetchedComment.id
                    || currentComment.bodyMarkdown != fetchedComment.bodyMarkdown
                    || currentComment.reactions != fetchedComment.reactions
                    || currentComment.viewerCanDelete != fetchedComment.viewerCanDelete
            }
    }
}
