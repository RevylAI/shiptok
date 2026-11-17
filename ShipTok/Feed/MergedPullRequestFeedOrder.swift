import Foundation

enum MergedPullRequestFeedGroup: Int, Sendable {
    case shipTokVideo
    case otherVideo
    case imageOrAnimatedImage

    init(firstMediaItem: PullRequestMediaItem) {
        switch (firstMediaItem.kind, firstMediaItem.isShipTokVideo) {
        case (.video, true): self = .shipTokVideo
        case (.video, false): self = .otherVideo
        case (.image, _), (.animatedImage, _): self = .imageOrAnimatedImage
        }
    }

    var isShipTokVideo: Bool {
        self == .shipTokVideo
    }
}

extension MergedPullRequest {
    static let shipTokLabelName = "shiptok"

    // The feed is what merged in the window, plus every pull request labeled shiptok whose hero is a ShipTok video, so the demo videos never age out (AGENTS.md, "Feed Order").
    func belongsInFeed(mergedWindowStartDate: Date) -> Bool {
        guard let feedGroup else { return false }
        if mergedAt >= mergedWindowStartDate { return true }
        return feedGroup.isShipTokVideo && labels.contains { $0.name.caseInsensitiveCompare(Self.shipTokLabelName) == .orderedSame }
    }

    // The format's first media, never the store's load-failure-aware hero, so a failed load never reorders the feed (AGENTS.md, "Feed Order").
    var feedGroup: MergedPullRequestFeedGroup? {
        mediaItems.first.map(MergedPullRequestFeedGroup.init(firstMediaItem:))
    }

    func comesBeforeInFeed(_ otherPullRequest: MergedPullRequest) -> Bool {
        let feedGroupRank = feedGroup?.rawValue ?? Int.max
        let otherFeedGroupRank = otherPullRequest.feedGroup?.rawValue ?? Int.max
        if feedGroupRank != otherFeedGroupRank {
            return feedGroupRank < otherFeedGroupRank
        }
        if mergedAt != otherPullRequest.mergedAt {
            return mergedAt > otherPullRequest.mergedAt
        }
        return number > otherPullRequest.number
    }
}
