import Foundation

enum GitHubReaction: String, CaseIterable, Hashable, Sendable, Codable {
    case thumbsUp = "THUMBS_UP"
    case thumbsDown = "THUMBS_DOWN"
    case laugh = "LAUGH"
    case hooray = "HOORAY"
    case confused = "CONFUSED"
    case heart = "HEART"
    case rocket = "ROCKET"
    case eyes = "EYES"

    var emoji: String {
        switch self {
        case .thumbsUp: "👍"
        case .thumbsDown: "👎"
        case .laugh: "😄"
        case .hooray: "🎉"
        case .confused: "😕"
        case .heart: "❤️"
        case .rocket: "🚀"
        case .eyes: "👀"
        }
    }
}

struct GitHubReactionSummary: Hashable, Sendable, Codable {
    var countsByReaction: [GitHubReaction: Int]
    var viewerReactions: Set<GitHubReaction>

    func count(of reaction: GitHubReaction) -> Int {
        countsByReaction[reaction, default: 0]
    }

    mutating func setViewerHasReacted(_ viewerHasReacted: Bool, with reaction: GitHubReaction) {
        guard viewerReactions.contains(reaction) != viewerHasReacted else { return }
        let updatedCount = count(of: reaction) + (viewerHasReacted ? 1 : -1)
        countsByReaction[reaction] = updatedCount > 0 ? updatedCount : nil
        if viewerHasReacted {
            viewerReactions.insert(reaction)
        } else {
            viewerReactions.remove(reaction)
        }
    }
}

struct GitHubLabel: Hashable, Sendable, Codable {
    let name: String
    let rgbHex: UInt32
}

struct GitHubActor: Hashable, Sendable, Codable {
    let login: String
    let avatarURL: URL?
    let isBot: Bool

    func hasLogin(_ githubLogin: String) -> Bool {
        login.caseInsensitiveCompare(githubLogin) == .orderedSame
    }
}

struct PullRequestComment: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let author: GitHubActor?
    let bodyMarkdown: String
    let createdAt: Date
    let url: URL
    let viewerCanDelete: Bool
    var reactions: GitHubReactionSummary
    var databaseID: Int? = nil
    var lastEditedAt: Date? = nil
}

struct MergedPullRequest: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let author: GitHubActor?
    let mergedAt: Date
    let descriptionMarkdown: String
    let additions: Int
    let deletions: Int
    let changedFiles: Int
    let labels: [GitHubLabel]
    var reactions: GitHubReactionSummary
    var comments: [PullRequestComment]
    var mediaItems: [PullRequestMediaItem]
}

// One week's video, published as a closed GitHub issue in the weekly format (WeeklyEditionFormat).
struct WeeklyEdition: Identifiable, Hashable, Sendable {
    let id: String
    let number: Int
    let url: URL
    let author: GitHubActor?
    let weekStartDate: Date
    let title: String
    let hook: String
    let pullRequestNumbers: [Int]
    var reactions: GitHubReactionSummary
    var comments: [PullRequestComment]
    var mediaItems: [PullRequestMediaItem]
}

// Any GitHub conversation the feed shows, a pull request or a weekly edition, takes comments, reactions and vibes the same way.
protocol GitHubCommentThread: Hashable, Sendable {
    var id: String { get }
    var number: Int { get }
    var url: URL { get }
    var author: GitHubActor? { get }
    var reactions: GitHubReactionSummary { get }
    var comments: [PullRequestComment] { get set }
    var mediaItems: [PullRequestMediaItem] { get set }
}

extension GitHubCommentThread {
    // Discussion excludes bots, vibes and comments carrying a ShipTok tag: the ShipTok format section of PR #6690.
    var discussionComments: [PullRequestComment] {
        comments.filter { $0.isWrittenByPerson && PullRequestVibeComment(comment: $0) == nil }
    }
}

extension MergedPullRequest: GitHubCommentThread {}
extension WeeklyEdition: GitHubCommentThread {}
