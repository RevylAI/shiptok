import Foundation
import Observation
import UIKit

// A post's comments, top-level oldest first with every reply under its comment, and its vibes oldest first, as Revyl serves them 50 a page. The sheet re-reads the pages it has every few seconds while it's open (AGENTS.md, "Comments").
@Observable
@MainActor
final class PostCommentsStore {
    private static let refreshIntervalSeconds = 5

    private(set) var comments: [ShipTokPostComment] = []
    private(set) var vibes: [ShipTokPostVibe] = []
    private(set) var hasLoadedFirstPage = false
    private(set) var commentsNextCursor: String?
    private(set) var vibesNextCursor: String?
    private(set) var isLoadingMore = false
    private(set) var isPostingComment = false
    private(set) var refreshFailureMessage: String?
    var actionFailureMessage: String?
    var reportConfirmationMessage: String?
    let postID: String
    private var localChangeGeneration = 0
    private var deletedCommentIDs: Set<String> = []
    private var deletedVibeIDs: Set<String> = []
    private let api: RevylShipTokAPI
    private let reactionWriteQueue: ViewerReactionWriteQueue
    private let analytics: ShipTokAnalytics
    private let analyticsSubject: ShipTokAnalyticsSubject
    // Tells the post's cards how many comments and replies came or went, so their count moves at once.
    private let onCommentCountChange: (Int) -> Void
    // Tells the post's cards a vibe was deleted, so they read the post's vibes again.
    private let onVibeDeleted: () -> Void

    init(
        postID: String,
        api: RevylShipTokAPI,
        analytics: ShipTokAnalytics,
        analyticsSubject: ShipTokAnalyticsSubject,
        onCommentCountChange: @escaping (Int) -> Void,
        onVibeDeleted: @escaping () -> Void
    ) {
        self.postID = postID
        self.api = api
        reactionWriteQueue = ViewerReactionWriteQueue(api: api)
        self.analytics = analytics
        self.analyticsSubject = analyticsSubject
        self.onCommentCountChange = onCommentCountChange
        self.onVibeDeleted = onVibeDeleted
    }

    var hasMorePages: Bool {
        commentsNextCursor != nil || vibesNextCursor != nil
    }

    // Re-reads as many pages as are loaded. A read that a local change overtook holds feedback older than that change, so it's dropped.
    func refresh() async {
        let localChangeGenerationAtFetchStart = localChangeGeneration
        let loadedCommentCount = comments.count
        let loadedVibeCount = vibes.count
        do {
            async let fetchedComments = fetchCommentPages(coveringCount: loadedCommentCount)
            async let fetchedVibes = fetchVibePages(coveringCount: loadedVibeCount)
            let (commentPages, vibePages) = try await (fetchedComments, fetchedVibes)
            refreshFailureMessage = nil
            guard localChangeGeneration == localChangeGenerationAtFetchStart else { return }
            comments = withoutDeletedComments(commentPages.comments)
            commentsNextCursor = commentPages.nextCursor
            vibes = vibePages.vibes.filter { !deletedVibeIDs.contains($0.id) }
            vibesNextCursor = vibePages.nextCursor
            hasLoadedFirstPage = true
        } catch {
            if error.isTaskCancellation { return }
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
            try? await Task.sleep(for: .seconds(Self.refreshIntervalSeconds))
        }
    }

    func loadMore() async {
        guard hasMorePages, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            if let commentsNextCursor {
                let page = try await api.fetchComments(postID: postID, cursor: commentsNextCursor)
                let loadedCommentIDs = Set(comments.map(\.id))
                comments += withoutDeletedComments(page.comments.filter { !loadedCommentIDs.contains($0.id) })
                self.commentsNextCursor = page.nextCursor
            }
            if let vibesNextCursor {
                let page = try await api.fetchVibes(postID: postID, cursor: vibesNextCursor)
                let loadedVibeIDs = Set(vibes.map(\.id))
                vibes += page.vibes.filter { !loadedVibeIDs.contains($0.id) && !deletedVibeIDs.contains($0.id) }
                self.vibesNextCursor = page.nextCursor
            }
        } catch {
            if error.isTaskCancellation { return }
            actionFailureMessage = error.localizedDescription
        }
    }

    // A reply to a reply attaches to its top-level comment, since replies are one level deep.
    func postComment(body: String, replyingTo repliedComment: ShipTokPostComment?) async -> ShipTokPostComment? {
        let parentCommentID = repliedComment.map { $0.parentCommentID ?? $0.id }
        let attempt = analytics.requestMutation(.comment, change: .add, subject: analyticsSubject, isReply: parentCommentID != nil)
        isPostingComment = true
        defer { isPostingComment = false }
        do {
            let postedComment = try await api.postComment(body: body, parentCommentID: parentCommentID, postID: postID)
            localChangeGeneration += 1
            if let parentCommentID, let parentIndex = comments.firstIndex(where: { $0.id == parentCommentID }) {
                comments[parentIndex].replies.append(postedComment)
            } else if parentCommentID == nil, commentsNextCursor == nil {
                comments.append(postedComment)
            }
            onCommentCountChange(1)
            analytics.capture(.mutationCompleted(attempt, outcome: .succeeded, commentID: postedComment.id))
            return postedComment
        } catch {
            analytics.capture(.mutationCompleted(attempt, outcome: error.isTaskCancellation ? .cancelled : .failed, commentID: nil))
            actionFailureMessage = error.localizedDescription
            return nil
        }
    }

    // Deleting a comment deletes its replies.
    func deleteComment(_ comment: ShipTokPostComment) async {
        let attempt = analytics.requestMutation(.comment, change: .remove, subject: analyticsSubject, commentID: comment.id, isReply: comment.parentCommentID != nil)
        let commentsBeforeDeletion = comments
        localChangeGeneration += 1
        deletedCommentIDs.insert(comment.id)
        comments = withoutDeletedComments(comments)
        let removedCount = 1 + comment.replies.count
        onCommentCountChange(-removedCount)
        defer { localChangeGeneration += 1 }
        do {
            try await api.deleteComment(commentID: comment.id, postID: postID)
            analytics.capture(.mutationCompleted(attempt, outcome: .succeeded, commentID: comment.id))
        } catch {
            analytics.capture(.mutationCompleted(attempt, outcome: error.isTaskCancellation ? .cancelled : .failed, commentID: comment.id))
            deletedCommentIDs.remove(comment.id)
            comments = commentsBeforeDeletion
            onCommentCountChange(removedCount)
            actionFailureMessage = error.localizedDescription
        }
    }

    // Its author clears their vibe this way, and an Owner or Admin deletes anyone's.
    func deleteVibe(_ vibe: ShipTokPostVibe) async {
        let attempt = analytics.requestMutation(.vibe, change: .remove, subject: analyticsSubject, vibe: vibe.vibe, vibeID: vibe.id)
        let vibesBeforeDeletion = vibes
        localChangeGeneration += 1
        deletedVibeIDs.insert(vibe.id)
        vibes.removeAll { $0.id == vibe.id }
        defer { localChangeGeneration += 1 }
        do {
            try await api.deleteVibe(vibeID: vibe.id, postID: postID)
            analytics.capture(.mutationCompleted(attempt, outcome: .succeeded, commentID: nil))
            onVibeDeleted()
        } catch {
            analytics.capture(.mutationCompleted(attempt, outcome: error.isTaskCancellation ? .cancelled : .failed, commentID: nil))
            deletedVibeIDs.remove(vibe.id)
            vibes = vibesBeforeDeletion
            actionFailureMessage = error.localizedDescription
        }
    }

    func toggleReaction(_ reaction: ShipTokReaction, on comment: ShipTokPostComment) async {
        guard let currentComment = self.comment(withID: comment.id) else { return }
        let isAddingReaction = !currentComment.reactions.viewerReactions.contains(reaction)
        let attempt = analytics.requestMutation(.reaction, change: isAddingReaction ? .add : .remove,
                                                subject: analyticsSubject, reaction: reaction, commentID: comment.id,
                                                isReply: comment.parentCommentID != nil)
        localChangeGeneration += 1
        updateComment(withID: comment.id) { $0.reactions.setViewerHasReacted(isAddingReaction, with: reaction) }
        defer { localChangeGeneration += 1 }
        switch await reactionWriteQueue.write(reaction, viewerHasReacted: isAddingReaction, on: .comment(postID: postID, commentID: comment.id)) {
        case .succeeded:
            analytics.capture(.mutationCompleted(attempt, outcome: .succeeded, commentID: comment.id))
        case .failed(let error, let restoredViewerHasReacted):
            analytics.capture(.mutationCompleted(attempt, outcome: error.isTaskCancellation ? .cancelled : .failed, commentID: comment.id))
            if let restoredViewerHasReacted {
                updateComment(withID: comment.id) { $0.reactions.setViewerHasReacted(restoredViewerHasReacted, with: reaction) }
            }
            actionFailureMessage = error.localizedDescription
        }
    }

    // Revyl emails the organization's owners and admins the comment or vibe, its author and the post (AGENTS.md, "Report And Hide").
    func report(_ reportableContent: ReportableContent, control: ShipTokAnalyticsEvent.ModerationControl) async {
        do {
            if let vibeID = reportableContent.vibeID {
                try await api.reportVibe(vibeID: vibeID, postID: postID)
            } else if let commentID = reportableContent.commentID {
                try await api.reportComment(commentID: commentID, postID: postID)
            } else {
                return
            }
            analytics.capture(.contentReported(reportableContent, control: control))
            reportConfirmationMessage = "Thanks. Your organization's owners and admins will look at it."
        } catch {
            if error.isTaskCancellation { return }
            actionFailureMessage = error.localizedDescription
        }
    }

    func comment(withID commentID: String) -> ShipTokPostComment? {
        for topLevelComment in comments {
            if topLevelComment.id == commentID { return topLevelComment }
            if let reply = topLevelComment.replies.first(where: { $0.id == commentID }) { return reply }
        }
        return nil
    }

    private func fetchCommentPages(coveringCount loadedCount: Int) async throws -> (comments: [ShipTokPostComment], nextCursor: String?) {
        var fetchedComments: [ShipTokPostComment] = []
        var nextCursor: String?
        repeat {
            let page = try await api.fetchComments(postID: postID, cursor: nextCursor)
            fetchedComments += page.comments
            nextCursor = page.nextCursor
        } while nextCursor != nil && fetchedComments.count < loadedCount
        return (fetchedComments, nextCursor)
    }

    private func fetchVibePages(coveringCount loadedCount: Int) async throws -> (vibes: [ShipTokPostVibe], nextCursor: String?) {
        var fetchedVibes: [ShipTokPostVibe] = []
        var nextCursor: String?
        repeat {
            let page = try await api.fetchVibes(postID: postID, cursor: nextCursor)
            fetchedVibes += page.vibes
            nextCursor = page.nextCursor
        } while nextCursor != nil && fetchedVibes.count < loadedCount
        return (fetchedVibes, nextCursor)
    }

    private func updateComment(withID commentID: String, _ update: (inout ShipTokPostComment) -> Void) {
        for topLevelIndex in comments.indices {
            if comments[topLevelIndex].id == commentID {
                update(&comments[topLevelIndex])
                return
            }
            if let replyIndex = comments[topLevelIndex].replies.firstIndex(where: { $0.id == commentID }) {
                update(&comments[topLevelIndex].replies[replyIndex])
                return
            }
        }
    }

    // A read that started before a delete can still bring the comment back, so a comment the viewer deleted stays out of every later read.
    private func withoutDeletedComments(_ fetchedComments: [ShipTokPostComment]) -> [ShipTokPostComment] {
        fetchedComments.compactMap { fetchedComment in
            guard !deletedCommentIDs.contains(fetchedComment.id) else { return nil }
            var visibleComment = fetchedComment
            visibleComment.replies.removeAll { deletedCommentIDs.contains($0.id) }
            return visibleComment
        }
    }
}
