import Foundation

// The card whose deck of pull requests is open: a week in Weekly or a feature in Features, one at a time (AGENTS.md, "Pull Request Decks").
enum PullRequestDeckSource: Equatable {
    case weeklyEdition(WeeklyEdition)
    case feature(Feature)

    var feedMode: FeedMode {
        switch self {
        case .weeklyEdition: .weekly
        case .feature: .features
        }
    }

    // A feature's video is its card and its deck is the work behind it, so the deck shows its pull requests with or without media of their own; a week's shows only those with media.
    var listing: PullRequestDeckListing {
        switch self {
        case .weeklyEdition(let weeklyEdition): PullRequestDeckListing(pullRequestNumbers: weeklyEdition.pullRequestNumbers, showsPullRequestsWithoutMedia: false)
        case .feature(let feature): PullRequestDeckListing(pullRequestNumbers: feature.pullRequestNumbers, showsPullRequestsWithoutMedia: true)
        }
    }
}

// What decides which cards a deck shows: the pull requests its card lists, in order, and whether it keeps those without media of their own.
struct PullRequestDeckListing: Hashable {
    let pullRequestNumbers: [Int]
    let showsPullRequestsWithoutMedia: Bool
}
