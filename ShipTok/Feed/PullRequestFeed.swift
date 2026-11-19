import Foundation

// The Open and Merged modes' cards: open pull requests, newest update first, and merged ones, newest merge first (AGENTS.md, "Feed Order").
enum PullRequestFeed: String, Sendable, CaseIterable {
    case open
    case merged
}

extension PullRequest {
    func belongs(in feed: PullRequestFeed) -> Bool {
        guard !mediaItems.isEmpty else { return false }
        return switch feed {
        case .open: mergedAt == nil
        case .merged: mergedAt != nil
        }
    }

    func comesBefore(_ otherPullRequest: PullRequest, in feed: PullRequestFeed) -> Bool {
        let (feedOrderDate, otherFeedOrderDate) = switch feed {
        case .open: (updatedAt, otherPullRequest.updatedAt)
        case .merged: (mergedAt ?? .distantPast, otherPullRequest.mergedAt ?? .distantPast)
        }
        if feedOrderDate != otherFeedOrderDate {
            return feedOrderDate > otherFeedOrderDate
        }
        return number > otherPullRequest.number
    }
}
