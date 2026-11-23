import Foundation
import Observation
import OSLog
import UIKit

// A vibe waits five seconds for Undo before it's sent, and a person has one vibe per post, so a new one replaces their earlier one (AGENTS.md, "Vibes").
@Observable
@MainActor
final class VibeOutbox {
    struct QueuedVibe: Identifiable, Equatable {
        let id: UUID
        let target: VibeTarget
        let vibe: ShipTokVibe
        let feedbackText: String
    }

    private static let undoWindowSeconds = 5
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "vibe-outbox")

    private(set) var queuedVibes: [QueuedVibe] = []
    private(set) var failedVibe: QueuedVibe?
    private var postingVibeIDs: Set<UUID> = []
    private var vibeIDsUndoneWhilePosting: Set<UUID> = []
    private var delayedPostTasks: [UUID: Task<Void, Never>] = [:]
    private var latestVibeWriteByPostID: [String: Task<Void, Never>] = [:]
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private let api: RevylShipTokAPI
    private let analytics: ShipTokAnalytics
    private let feedStore: PostFeedStore

    init(api: RevylShipTokAPI, analytics: ShipTokAnalytics, feedStore: PostFeedStore) {
        self.api = api
        self.analytics = analytics
        self.feedStore = feedStore
    }

    var undoableVibe: QueuedVibe? {
        queuedVibes.last { !vibeIDsUndoneWhilePosting.contains($0.id) }
    }

    func pendingVibe(forPostID postID: String) -> ShipTokVibe? {
        queuedVibes.last { $0.target.postID == postID && !vibeIDsUndoneWhilePosting.contains($0.id) }?.vibe
    }

    func enqueue(_ queuedVibe: QueuedVibe) {
        let postID = queuedVibe.target.postID
        for replacedVibe in queuedVibes where replacedVibe.target.postID == postID && !postingVibeIDs.contains(replacedVibe.id) {
            delayedPostTasks.removeValue(forKey: replacedVibe.id)?.cancel()
            analytics.capture(.vibeCancelled(replacedVibe.target.analyticsSubject, selectionID: replacedVibe.id, vibe: replacedVibe.vibe))
        }
        queuedVibes.removeAll { $0.target.postID == postID && !postingVibeIDs.contains($0.id) }
        queuedVibes.append(queuedVibe)
        if failedVibe?.target.postID == postID {
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
        analytics.capture(.vibeCancelled(undoneVibe.target.analyticsSubject, selectionID: undoneVibe.id, vibe: undoneVibe.vibe))
        if postingVibeIDs.contains(queuedVibeID) {
            vibeIDsUndoneWhilePosting.insert(queuedVibeID)
        } else {
            delayedPostTasks.removeValue(forKey: queuedVibeID)?.cancel()
            queuedVibes.removeAll { $0.id == queuedVibeID }
        }
        return undoneVibe
    }

    func removeViewerVibe(on target: VibeTarget) async {
        for queuedVibe in queuedVibes where queuedVibe.target.postID == target.postID {
            _ = undo(queuedVibe.id)
        }
        if failedVibe?.target.postID == target.postID {
            failedVibe = nil
        }
        await latestVibeWriteByPostID[target.postID]?.value
        guard let feedback = feedStore.post(withID: target.postID)?.feedback, let viewerVibeID = feedback.viewerVibeID else { return }
        await deleteViewerVibe(vibeID: viewerVibeID, vibe: feedback.viewerVibe, on: target, selectionID: nil)
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

    // Each vibe replaces the viewer's earlier one on its post, so a post's vibes are sent one at a time in the order cast.
    private func post(_ queuedVibe: QueuedVibe) async {
        delayedPostTasks[queuedVibe.id] = nil
        guard queuedVibes.contains(queuedVibe), !postingVibeIDs.contains(queuedVibe.id) else { return }
        postingVibeIDs.insert(queuedVibe.id)
        let postID = queuedVibe.target.postID
        let earlierVibeWrite = latestVibeWriteByPostID[postID]
        let vibeWrite = Task {
            await earlierVibeWrite?.value
            await writeVibe(queuedVibe)
        }
        latestVibeWriteByPostID[postID] = vibeWrite
        await vibeWrite.value
        if latestVibeWriteByPostID[postID] == vibeWrite {
            latestVibeWriteByPostID[postID] = nil
        }
    }

    private func writeVibe(_ queuedVibe: QueuedVibe) async {
        defer {
            postingVibeIDs.remove(queuedVibe.id)
            vibeIDsUndoneWhilePosting.remove(queuedVibe.id)
            queuedVibes.removeAll { $0.id == queuedVibe.id }
        }
        guard !vibeIDsUndoneWhilePosting.contains(queuedVibe.id) else { return }
        let target = queuedVibe.target
        let feedbackText = queuedVibe.feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attempt = analytics.requestMutation(.vibe, change: .add, subject: target.analyticsSubject, vibe: queuedVibe.vibe, selectionID: queuedVibe.id)
        do {
            try await feedStore.writeViewerVibe(queuedVibe.vibe, feedbackText: feedbackText.isEmpty ? nil : feedbackText, onPostID: target.postID) { [api] in
                try await api.setVibe(queuedVibe.vibe, feedbackText: feedbackText.isEmpty ? nil : feedbackText, postID: target.postID).id
            }
            analytics.capture(.mutationCompleted(attempt, outcome: .succeeded, commentID: nil))
        } catch {
            analytics.capture(.mutationCompleted(attempt, outcome: error.isTaskCancellation ? .cancelled : .failed, commentID: nil))
            Self.logger.error("Sending a vibe failed: \(error.publicLogDescription, privacy: .public)")
            if (error as? RevylShipTokAPIError)?.refusesSignIn != true {
                failedVibe = queuedVibe
            }
            return
        }
        if vibeIDsUndoneWhilePosting.contains(queuedVibe.id), let viewerVibeID = feedStore.post(withID: target.postID)?.feedback.viewerVibeID {
            await deleteViewerVibe(vibeID: viewerVibeID, vibe: queuedVibe.vibe, on: target, selectionID: queuedVibe.id)
        }
    }

    private func deleteViewerVibe(vibeID: String, vibe: ShipTokVibe?, on target: VibeTarget, selectionID: UUID?) async {
        let attempt = analytics.requestMutation(.vibe, change: .remove, subject: target.analyticsSubject, vibe: vibe, vibeID: vibeID, selectionID: selectionID)
        do {
            try await feedStore.writeViewerVibe(nil, feedbackText: nil, onPostID: target.postID) { [api] in
                try await api.deleteVibe(vibeID: vibeID, postID: target.postID)
                return nil
            }
            analytics.capture(.mutationCompleted(attempt, outcome: .succeeded, commentID: nil))
        } catch {
            analytics.capture(.mutationCompleted(attempt, outcome: error.isTaskCancellation ? .cancelled : .failed, commentID: nil))
            Self.logger.error("Removing a vibe failed: \(error.publicLogDescription, privacy: .public)")
            if error.isTaskCancellation || (error as? RevylShipTokAPIError)?.refusesSignIn == true { return }
            feedStore.transientErrorMessage = "Couldn't remove your vibe on \(target.reference). \(error.localizedDescription)"
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskIdentifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
        backgroundTaskIdentifier = .invalid
    }
}
