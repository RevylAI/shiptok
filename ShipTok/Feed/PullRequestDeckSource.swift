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

    var pullRequestNumbers: [Int] {
        switch self {
        case .weeklyEdition(let weeklyEdition): weeklyEdition.pullRequestNumbers
        case .feature(let feature): feature.pullRequestNumbers
        }
    }

    // A feature's video is its card and its deck is the work behind it, so the deck shows its pull requests with or without media of their own; a week's shows only those with media.
    var showsPullRequestsWithoutMedia: Bool {
        switch self {
        case .weeklyEdition: false
        case .feature: true
        }
    }
}
