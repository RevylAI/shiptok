import SwiftUI

enum PullRequestVibe: String, CaseIterable, Hashable, Sendable {
    case good
    case bad

    var displayName: String {
        switch self {
        case .good: "Good vibes"
        case .bad: "Bad vibes"
        }
    }

    var tintColor: Color {
        switch self {
        case .good: RevylBrandColor.success
        case .bad: RevylBrandColor.danger
        }
    }

    var systemImageName: String {
        switch self {
        case .good: "hand.thumbsup"
        case .bad: "hand.thumbsdown"
        }
    }

    fileprivate var markerLine: String {
        "<!-- shiptok:vibe \(rawValue) -->"
    }
}

// The vibe comment's marker and layout are the "Vibes" section of docs/shiptok-format.md.
struct PullRequestVibeComment: Sendable {
    let vibe: PullRequestVibe
    let feedbackText: String
    let comment: PullRequestComment

    init?(comment: PullRequestComment) {
        let firstBodyLine = comment.bodyMarkdown.prefix(while: { !$0.isNewline })
        let trimmedFirstBodyLine = firstBodyLine.trimmingCharacters(in: .whitespaces)
        guard let vibe = PullRequestVibe.allCases.first(where: { $0.markerLine == trimmedFirstBodyLine }) else { return nil }
        var feedbackLines = comment.bodyMarkdown
            .dropFirst(firstBodyLine.count)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        if feedbackLines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("**") == true {
            feedbackLines = feedbackLines.dropFirst()
        }
        self.vibe = vibe
        self.feedbackText = feedbackLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        self.comment = comment
    }

    static func bodyMarkdown(vibe: PullRequestVibe, feedbackText: String) -> String {
        let markerAndHeadline = "\(vibe.markerLine)\n**\(vibe.displayName)** via ShipTok"
        let trimmedFeedbackText = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFeedbackText.isEmpty ? markerAndHeadline : "\(markerAndHeadline)\n\n\(trimmedFeedbackText)"
    }
}

struct PullRequestVibeTally: Equatable {
    var goodVibeCount: Int
    var badVibeCount: Int
    var viewerVibe: PullRequestVibe?

    func count(of vibe: PullRequestVibe) -> Int {
        switch vibe {
        case .good: goodVibeCount
        case .bad: badVibeCount
        }
    }
}

extension GitHubCommentThread {
    var newestVibeCommentPerAuthor: [PullRequestVibeComment] {
        var newestVibeCommentByAuthorLogin: [String: PullRequestVibeComment] = [:]
        for comment in comments {
            guard let author = comment.author, !author.isBot, let vibeComment = PullRequestVibeComment(comment: comment) else { continue }
            let authorLogin = author.login.lowercased()
            if let newerVibeComment = newestVibeCommentByAuthorLogin[authorLogin], newerVibeComment.comment.createdAt > comment.createdAt {
                continue
            }
            newestVibeCommentByAuthorLogin[authorLogin] = vibeComment
        }
        return newestVibeCommentByAuthorLogin.values.sorted { $0.comment.createdAt > $1.comment.createdAt }
    }

    // A demo visitor has no login, so no vibe is theirs.
    func vibeTally(viewerGitHubLogin: String?, viewerPendingVibe: PullRequestVibe?) -> PullRequestVibeTally {
        var authorVibes = newestVibeCommentPerAuthor.map { (authorLogin: $0.comment.author?.login ?? "", vibe: $0.vibe) }
        if let viewerGitHubLogin, let viewerPendingVibe {
            authorVibes.removeAll { $0.authorLogin.caseInsensitiveCompare(viewerGitHubLogin) == .orderedSame }
            authorVibes.append((authorLogin: viewerGitHubLogin, vibe: viewerPendingVibe))
        }
        return PullRequestVibeTally(
            goodVibeCount: authorVibes.filter { $0.vibe == .good }.count,
            badVibeCount: authorVibes.filter { $0.vibe == .bad }.count,
            viewerVibe: viewerGitHubLogin.flatMap { viewerGitHubLogin in
                authorVibes.first { $0.authorLogin.caseInsensitiveCompare(viewerGitHubLogin) == .orderedSame }?.vibe
            }
        )
    }
}
