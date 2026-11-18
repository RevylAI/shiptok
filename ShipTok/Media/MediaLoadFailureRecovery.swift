import Foundation

// A media item that failed to load is given up only once a URL renewed after the failure fails too, or a read that started after the failure brings back the URL that failed, so an expired signed URL never hides it. A video refused to the viewer is given up at once, since no renewal changes that answer (AGENTS.md, "Signed Media URLs").
struct MediaLoadFailureRecovery {
    private struct PendingLoadFailure {
        let url: URL
        let recordedAt: Date
    }

    private static let renewedURLTrialSeconds: TimeInterval = 120

    private(set) var unloadableMediaItemIDs: Set<String> = []
    private var pendingLoadFailureByMediaItemID: [String: PendingLoadFailure] = [:]
    private var urlRenewalDateByMediaItemID: [String: Date] = [:]

    // False when the item is given up at once; otherwise the failure waits for a read to settle it.
    mutating func recordLoadFailure(of mediaItem: PullRequestMediaItem, wasRefusedToViewer: Bool) -> Bool {
        if wasRefusedToViewer {
            unloadableMediaItemIDs.insert(mediaItem.id)
            return false
        }
        if let urlRenewalDate = urlRenewalDateByMediaItemID[mediaItem.id],
           Date.now.timeIntervalSince(urlRenewalDate) < Self.renewedURLTrialSeconds {
            unloadableMediaItemIDs.insert(mediaItem.id)
            return false
        }
        if let failedURL = mediaItem.url {
            pendingLoadFailureByMediaItemID[mediaItem.id] = PendingLoadFailure(url: failedURL, recordedAt: .now)
        }
        return true
    }

    // A read that started before a failure may bring back the very URL that failed, so it settles only older failures. Returns the items it gave a new URL.
    @discardableResult
    mutating func settleLoadFailures(of readMediaItems: [PullRequestMediaItem], readStartedAt: Date) -> Set<String> {
        var renewedMediaItemIDs: Set<String> = []
        for readMediaItem in readMediaItems {
            guard let pendingLoadFailure = pendingLoadFailureByMediaItemID[readMediaItem.id],
                  pendingLoadFailure.recordedAt <= readStartedAt
            else { continue }
            pendingLoadFailureByMediaItemID[readMediaItem.id] = nil
            if readMediaItem.url == pendingLoadFailure.url {
                unloadableMediaItemIDs.insert(readMediaItem.id)
            } else {
                urlRenewalDateByMediaItemID[readMediaItem.id] = .now
                renewedMediaItemIDs.insert(readMediaItem.id)
            }
        }
        return renewedMediaItemIDs
    }

    // A store observes this whole value, so it settles only when something is pending, and a read with nothing to settle doesn't redraw what shows its media.
    var hasPendingLoadFailure: Bool {
        !pendingLoadFailureByMediaItemID.isEmpty
    }

    func hasLoadFailureRecorded(after date: Date) -> Bool {
        pendingLoadFailureByMediaItemID.values.contains { $0.recordedAt > date }
    }
}
