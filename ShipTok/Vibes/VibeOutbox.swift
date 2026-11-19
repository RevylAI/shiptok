import Foundation
import Observation
import OSLog
import UIKit

@Observable
@MainActor
final class VibeOutbox {
    struct QueuedVibe: Identifiable, Equatable {
        let id: UUID
        let target: VibeTarget
        let vibe: PullRequestVibe
        let feedbackText: String
    }

    private static let undoWindowSeconds = 5
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "vibe-outbox")

    private(set) var queuedVibes: [QueuedVibe] = []
    private(set) var failedVibe: QueuedVibe?
    private var postingVibeIDs: Set<UUID> = []
    private var vibeIDsUndoneWhilePosting: Set<UUID> = []
    private var delayedPostTasks: [UUID: Task<Void, Never>] = [:]
    private var latestVibeWriteByThreadID: [String: Task<Void, Never>] = [:]
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private let githubAPIClient: GitHubAPIClient
    private let analytics: ShipTokAnalytics
    // A demo visitor has none, and casts no vibe.
    private let viewerGitHubLogin: String?
    private let feedStore: PullRequestFeedStore
    private let weeklyEditionsStore: WeeklyEditionsStore
    private let handleRejectedGitHubAccess: @MainActor (GitHubAPIError) -> Void

    init(
        githubAPIClient: GitHubAPIClient,
        analytics: ShipTokAnalytics,
        viewerGitHubLogin: String?,
        feedStore: PullRequestFeedStore,
        weeklyEditionsStore: WeeklyEditionsStore,
        handleRejectedGitHubAccess: @escaping @MainActor (GitHubAPIError) -> Void
    ) {
        self.githubAPIClient = githubAPIClient
        self.analytics = analytics
        self.viewerGitHubLogin = viewerGitHubLogin
        self.feedStore = feedStore
        self.weeklyEditionsStore = weeklyEditionsStore
        self.handleRejectedGitHubAccess = handleRejectedGitHubAccess
    }

    var undoableVibe: QueuedVibe? {
        queuedVibes.last { !vibeIDsUndoneWhilePosting.contains($0.id) }
    }

    func pendingVibe(forThreadID threadID: String) -> PullRequestVibe? {
        queuedVibes.last { $0.target.threadID == threadID && !vibeIDsUndoneWhilePosting.contains($0.id) }?.vibe
    }

    func enqueue(_ queuedVibe: QueuedVibe) {
        let threadID = queuedVibe.target.threadID
        for replacedVibe in queuedVibes where replacedVibe.target.threadID == threadID && !postingVibeIDs.contains(replacedVibe.id) {
            delayedPostTasks.removeValue(forKey: replacedVibe.id)?.cancel()
            analytics.capture(.vibeCancelled(replacedVibe.target.analyticsSubject,
                                            selectionID: replacedVibe.id, vibe: replacedVibe.vibe))
        }
        queuedVibes.removeAll { $0.target.threadID == threadID && !postingVibeIDs.contains($0.id) }
        queuedVibes.append(queuedVibe)
        if failedVibe?.target.threadID == threadID {
            failedVibe = nil
        }
        delayedPostTasks[queuedVibe.id] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.undoWindowSeconds))
            } catch {
                return
            }
            await self?.post(queuedVibe)
        }
    }

    func undo(_ queuedVibeID: UUID) -> QueuedVibe? {
        guard let undoneVibe = queuedVibes.first(where: { $0.id == queuedVibeID }),
              !vibeIDsUndoneWhilePosting.contains(queuedVibeID)
        else { return nil }
        analytics.capture(.vibeCancelled(undoneVibe.target.analyticsSubject,
                                        selectionID: undoneVibe.id, vibe: undoneVibe.vibe))
        if postingVibeIDs.contains(queuedVibeID) {
            vibeIDsUndoneWhilePosting.insert(queuedVibeID)
        } else {
            delayedPostTasks.removeValue(forKey: queuedVibeID)?.cancel()
            queuedVibes.removeAll { $0.id == queuedVibeID }
        }
        return undoneVibe
    }

    func removeViewerVibe(on target: VibeTarget) async {
        for queuedVibe in queuedVibes where queuedVibe.target.threadID == target.threadID {
            _ = undo(queuedVibe.id)
        }
        if failedVibe?.target.threadID == target.threadID {
            failedVibe = nil
        }
        let viewerVibeComments = comments(of: target).filter { isViewerVibeComment($0) }
        removeViewerDeletedComments(withIDs: Set(viewerVibeComments.map(\.id)), from: target)
        for (viewerVibeCommentIndex, viewerVibeComment) in viewerVibeComments.enumerated() {
            let attempt = analytics.requestMutation(.vibe, change: .remove,
                subject: target.analyticsSubject,
                vibe: PullRequestVibeComment(comment: viewerVibeComment)?.vibe, commentID: viewerVibeComment.id)
            do {
                try await githubAPIClient.deleteComment(id: viewerVibeComment.id)
                analytics.capture(.mutationCompleted(attempt, outcome: .succeeded,
                    commentID: viewerVibeComment.id, commentDatabaseID: viewerVibeComment.databaseID))
            } catch {
                analytics.capture(.mutationCompleted(attempt, outcome: error.isTaskCancellation ? .cancelled : .failed,
                    commentID: viewerVibeComment.id, commentDatabaseID: viewerVibeComment.databaseID))
                Self.logger.error("Removing the viewer's vibe on #\(target.number, privacy: .public) failed")
                for undeletedVibeComment in viewerVibeComments[viewerVibeCommentIndex...] {
                    appendComment(undeletedVibeComment, to: target)
                }
                if let githubAPIError = error as? GitHubAPIError, githubAPIError.rejectsFeedAccess {
                    handleRejectedGitHubAccess(githubAPIError)
                } else {
                    showTransientError("Couldn't remove your vibe on \(target.reference). \(error.localizedDescription)", about: target)
                }
                return
            }
        }
    }

    func postAllQueuedVibesBeforeSuspension() {
        guard !queuedVibes.isEmpty, backgroundTaskIdentifier == .invalid else { return }
        backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "post-queued-vibes") { [weak self] in
            Task { @MainActor [weak self] in self?.endBackgroundTask() }
        }
        Task {
            for queuedVibe in queuedVibes {
                delayedPostTasks.removeValue(forKey: queuedVibe.id)?.cancel()
                await post(queuedVibe)
            }
            endBackgroundTask()
        }
    }

    func retryFailedVibe() {
        guard let failedVibe else { return }
        self.failedVibe = nil
        queuedVibes.append(failedVibe)
        Task { await post(failedVibe) }
    }

    func dismissFailedVibe() {
        failedVibe = nil
    }

    // Each vibe's post replaces the viewer's other vibes on its thread, so a thread's vibes post one at a time in the order cast, and an earlier vibe's replacing never deletes a later one.
    private func post(_ queuedVibe: QueuedVibe) async {
        delayedPostTasks[queuedVibe.id] = nil
        guard queuedVibes.contains(queuedVibe), !postingVibeIDs.contains(queuedVibe.id) else { return }
        postingVibeIDs.insert(queuedVibe.id)
        let threadID = queuedVibe.target.threadID
        let earlierVibeWrite = latestVibeWriteByThreadID[threadID]
        let vibeWrite = Task {
            await earlierVibeWrite?.value
            await writeVibe(queuedVibe)
        }
        latestVibeWriteByThreadID[threadID] = vibeWrite
        await vibeWrite.value
        if latestVibeWriteByThreadID[threadID] == vibeWrite {
            latestVibeWriteByThreadID[threadID] = nil
        }
    }

    private func writeVibe(_ queuedVibe: QueuedVibe) async {
        defer {
            postingVibeIDs.remove(queuedVibe.id)
            vibeIDsUndoneWhilePosting.remove(queuedVibe.id)
            queuedVibes.removeAll { $0.id == queuedVibe.id }
        }
        guard !vibeIDsUndoneWhilePosting.contains(queuedVibe.id) else { return }
        let postedVibeComment: PullRequestComment
        let attempt = analytics.requestMutation(.vibe, change: .add,
            subject: queuedVibe.target.analyticsSubject,
            vibe: queuedVibe.vibe, selectionID: queuedVibe.id)
        do {
            postedVibeComment = try await githubAPIClient.addComment(
                bodyMarkdown: PullRequestVibeComment.bodyMarkdown(vibe: queuedVibe.vibe, feedbackText: queuedVibe.feedbackText),
                toSubjectID: queuedVibe.target.threadID
            )
            analytics.capture(.mutationCompleted(attempt, outcome: .succeeded,
                commentID: postedVibeComment.id, commentDatabaseID: postedVibeComment.databaseID))
        } catch {
            analytics.capture(.mutationCompleted(attempt, outcome: error.isTaskCancellation ? .cancelled : .failed,
                                                  commentID: nil, commentDatabaseID: nil))
            Self.logger.error("Posting a vibe on #\(queuedVibe.target.number, privacy: .public) failed")
            if let githubAPIError = error as? GitHubAPIError, githubAPIError.rejectsFeedAccess {
                handleRejectedGitHubAccess(githubAPIError)
            } else {
                failedVibe = queuedVibe
            }
            return
        }
        if !vibeIDsUndoneWhilePosting.contains(queuedVibe.id) {
            await deleteViewerEarlierVibeComments(replacedBy: postedVibeComment, of: queuedVibe)
        }
        if vibeIDsUndoneWhilePosting.contains(queuedVibe.id) {
            await deleteVibeComment(postedVibeComment, undoing: queuedVibe)
        }
    }

    // A person has one vibe per pull request or week, so a new vibe comment replaces their earlier ones (AGENTS.md, "Vibes").
    private func deleteViewerEarlierVibeComments(replacedBy postedVibeComment: PullRequestComment, of queuedVibe: QueuedVibe) async {
        let target = queuedVibe.target
        do {
            switch target.kind {
            case .pullRequest:
                let fetchedPullRequest = try await githubAPIClient.fetchPullRequest(number: target.number)
                feedStore.applyFetchedPullRequest(try await removingViewerEarlierVibeComments(from: fetchedPullRequest, keeping: postedVibeComment))
            case .weeklyEdition:
                let fetchedWeeklyEdition = try await githubAPIClient.fetchWeeklyEdition(number: target.number)
                weeklyEditionsStore.applyFetchedWeeklyEdition(try await removingViewerEarlierVibeComments(from: fetchedWeeklyEdition, keeping: postedVibeComment))
            }
        } catch {
            Self.logger.error("Replacing earlier vibes on #\(target.number, privacy: .public) failed after the new vibe posted")
            appendComment(postedVibeComment, to: target)
            if let githubAPIError = error as? GitHubAPIError, githubAPIError.rejectsFeedAccess {
                handleRejectedGitHubAccess(githubAPIError)
            }
        }
    }

    private func removingViewerEarlierVibeComments<Thread: GitHubCommentThread>(from fetchedThread: Thread, keeping postedVibeComment: PullRequestComment) async throws -> Thread {
        var refreshedThread = fetchedThread
        if !refreshedThread.comments.contains(where: { $0.id == postedVibeComment.id }) {
            refreshedThread.comments.append(postedVibeComment)
        }
        let replacedVibeComments = refreshedThread.comments.filter { comment in
            comment.id != postedVibeComment.id && isViewerVibeComment(comment)
        }
        for replacedVibeComment in replacedVibeComments {
            try await githubAPIClient.deleteComment(id: replacedVibeComment.id)
            refreshedThread.comments.removeAll { $0.id == replacedVibeComment.id }
        }
        return refreshedThread
    }

    private func deleteVibeComment(_ postedVibeComment: PullRequestComment, undoing queuedVibe: QueuedVibe) async {
        let target = queuedVibe.target
        let attempt = analytics.requestMutation(.vibe, change: .remove,
            subject: target.analyticsSubject,
            vibe: queuedVibe.vibe, commentID: postedVibeComment.id, selectionID: queuedVibe.id)
        removeViewerDeletedComments(withIDs: [postedVibeComment.id], from: target)
        do {
            try await githubAPIClient.deleteComment(id: postedVibeComment.id)
            analytics.capture(.mutationCompleted(attempt, outcome: .succeeded,
                commentID: postedVibeComment.id, commentDatabaseID: postedVibeComment.databaseID))
        } catch {
            analytics.capture(.mutationCompleted(attempt, outcome: error.isTaskCancellation ? .cancelled : .failed,
                commentID: postedVibeComment.id, commentDatabaseID: postedVibeComment.databaseID))
            Self.logger.error("Undoing a posted vibe on #\(target.number, privacy: .public) failed")
            appendComment(postedVibeComment, to: target)
            if let githubAPIError = error as? GitHubAPIError, githubAPIError.rejectsFeedAccess {
                handleRejectedGitHubAccess(githubAPIError)
            } else {
                showTransientError("Couldn't undo \(queuedVibe.vibe.displayName.lowercased()) on \(target.reference). \(error.localizedDescription)", about: target)
            }
        }
    }

    private func comments(of target: VibeTarget) -> [PullRequestComment] {
        switch target.kind {
        case .pullRequest: feedStore.pullRequest(withID: target.threadID)?.comments ?? []
        case .weeklyEdition: weeklyEditionsStore.weeklyEdition(withID: target.threadID)?.comments ?? []
        }
    }

    private func appendComment(_ comment: PullRequestComment, to target: VibeTarget) {
        switch target.kind {
        case .pullRequest: feedStore.appendComment(comment, toPullRequestID: target.threadID)
        case .weeklyEdition: weeklyEditionsStore.appendComment(comment, toWeeklyEditionID: target.threadID)
        }
    }

    private func removeViewerDeletedComments(withIDs commentIDs: Set<String>, from target: VibeTarget) {
        switch target.kind {
        case .pullRequest: feedStore.removeViewerDeletedComments(withIDs: commentIDs, fromPullRequestID: target.threadID)
        case .weeklyEdition: weeklyEditionsStore.removeViewerDeletedComments(withIDs: commentIDs, fromWeeklyEditionID: target.threadID)
        }
    }

    private func showTransientError(_ message: String, about target: VibeTarget) {
        switch target.kind {
        case .pullRequest: feedStore.transientErrorMessage = message
        case .weeklyEdition: weeklyEditionsStore.transientErrorMessage = message
        }
    }

    private func isViewerVibeComment(_ comment: PullRequestComment) -> Bool {
        guard let viewerGitHubLogin else { return false }
        return comment.viewerCanDelete && comment.author?.hasLogin(viewerGitHubLogin) == true && PullRequestVibeComment(comment: comment) != nil
    }

    private func endBackgroundTask() {
        guard backgroundTaskIdentifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
        backgroundTaskIdentifier = .invalid
    }
}
