import Foundation

enum ShipTokReaction: String, CaseIterable, Hashable, Sendable, Codable, CodingKeyRepresentable {
    case thumbsUp = "thumbs_up"
    case thumbsDown = "thumbs_down"
    case laugh
    case hooray
    case confused
    case heart
    case rocket
    case eyes

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

    var accessibilityName: String {
        switch self {
        case .thumbsUp: "Thumbs up"
        case .thumbsDown: "Thumbs down"
        case .laugh: "Laugh"
        case .hooray: "Hooray"
        case .confused: "Confused"
        case .heart: "Heart"
        case .rocket: "Rocket"
        case .eyes: "Eyes"
        }
    }
}

struct ShipTokReactionSummary: Hashable, Sendable {
    var countsByReaction: [ShipTokReaction: Int]
    var viewerReactions: Set<ShipTokReaction>

    func count(of reaction: ShipTokReaction) -> Int {
        countsByReaction[reaction, default: 0]
    }

    mutating func setViewerHasReacted(_ viewerHasReacted: Bool, with reaction: ShipTokReaction) {
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

// A Revyl account as ShipTok shows it: a comment's author, someone in the inbox.
struct ShipTokPerson: Hashable, Sendable, Codable {
    let revylUserID: String
    let displayName: String
    let avatarURL: URL?

    private enum CodingKeys: String, CodingKey {
        case revylUserID = "revyl_user_id"
        case displayName = "display_name"
        case avatarURL = "avatar_url"
    }
}

struct ShipTokGitHubAuthor: Hashable, Sendable, Codable {
    // Nil for a deleted GitHub account.
    let login: String?
    let avatarURL: URL?
    let isBot: Bool

    private enum CodingKeys: String, CodingKey {
        case login
        case avatarURL = "avatar_url"
        case isBot = "is_bot"
    }
}

struct ShipTokLabel: Hashable, Sendable, Codable {
    let name: String
    let color: String

    var rgbHex: UInt32 {
        UInt32(color.trimmingPrefix("#"), radix: 16) ?? 0
    }
}

struct ShipTokPullRequestDetails: Hashable, Sendable, Codable {
    enum State: String, Hashable, Sendable, Codable {
        case open
        case merged
        case closed
    }

    let state: State
    let isDraft: Bool
    let createdAt: Date
    let updatedAt: Date
    let mergedAt: Date?
    let additions: Int
    let deletions: Int
    let changedFiles: Int
    let labels: [ShipTokLabel]

    private enum CodingKeys: String, CodingKey {
        case state
        case isDraft = "is_draft"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case mergedAt = "merged_at"
        case additions
        case deletions
        case changedFiles = "changed_files"
        case labels
    }
}

struct ShipTokPostMedia: Identifiable, Hashable, Sendable, Codable {
    enum Kind: String, Hashable, Sendable, Codable {
        case video
        case image
        case gif
    }

    // Stable for the same file across reads, while its URL changes with each signing.
    let id: String
    let kind: Kind
    // Nil on a saved card: a media link opens the file for whoever holds it, so a saved copy never keeps one (AGENTS.md, "Feed Caching").
    let url: URL?
    let posterURL: URL?
    let isShipTokVideo: Bool
    let isRevylHosted: Bool
    let urlExpiresAt: Date?

    // A signed link stops working once it expires, and only a fresh read of its post renews it; any other link works again when requested again (AGENTS.md, "Signed Media URLs").
    var hasExpiringSignedURL: Bool {
        urlExpiresAt != nil
    }

    private enum CodingKeys: String, CodingKey {
        case id = "media_id"
        case kind = "media_kind"
        case url
        case posterURL = "poster_url"
        case isShipTokVideo = "is_shiptok_video"
        case isRevylHosted = "is_revyl_hosted"
        case urlExpiresAt = "url_expires_at"
    }

    init(id: String, kind: Kind, url: URL?, posterURL: URL?, isShipTokVideo: Bool, isRevylHosted: Bool, urlExpiresAt: Date?) {
        self.id = id
        self.kind = kind
        self.url = url
        self.posterURL = posterURL
        self.isShipTokVideo = isShipTokVideo
        self.isRevylHosted = isRevylHosted
        self.urlExpiresAt = urlExpiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        posterURL = try container.decodeIfPresent(URL.self, forKey: .posterURL)
        isShipTokVideo = try container.decode(Bool.self, forKey: .isShipTokVideo)
        isRevylHosted = try container.decode(Bool.self, forKey: .isRevylHosted)
        urlExpiresAt = try container.decodeIfPresent(Date.self, forKey: .urlExpiresAt)
    }

    // A saved media item never holds a link (AGENTS.md, "Feed Caching").
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(isShipTokVideo, forKey: .isShipTokVideo)
        try container.encode(isRevylHosted, forKey: .isRevylHosted)
    }

    var withoutLinks: ShipTokPostMedia {
        ShipTokPostMedia(id: id, kind: kind, url: nil, posterURL: nil, isShipTokVideo: isShipTokVideo, isRevylHosted: isRevylHosted, urlExpiresAt: nil)
    }
}

// A post's likes, reactions, vibes and comment count, and what the viewer gave it. A like is the heart reaction.
struct ShipTokPostFeedback: Hashable, Sendable, Codable {
    var reactions: ShipTokReactionSummary
    var goodVibeCount: Int
    var badVibeCount: Int
    var commentCount: Int
    var viewerVibe: ShipTokVibe?
    var viewerVibeFeedbackText: String?
    // What deletes the viewer's vibe; nil while it has none, or while a new one is on its way.
    var viewerVibeID: String?
    // True when Revyl matched the post to the viewer as its developer, so the post is theirs and offers no Report or Hide.
    let viewerIsDeveloper: Bool

    private enum CodingKeys: String, CodingKey {
        case reactionCounts = "reaction_counts"
        case goodVibeCount = "good_vibe_count"
        case badVibeCount = "bad_vibe_count"
        case commentCount = "comment_count"
        case viewer
    }

    private struct Viewer: Codable {
        let reactions: [ShipTokReaction]
        let vibe: ShipTokVibe?
        let vibeFeedbackText: String?
        let vibeID: String?
        let isDeveloper: Bool

        private enum CodingKeys: String, CodingKey {
            case reactions
            case vibe
            case vibeFeedbackText = "vibe_feedback_text"
            case vibeID = "vibe_id"
            case isDeveloper = "is_developer"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let viewer = try container.decode(Viewer.self, forKey: .viewer)
        reactions = ShipTokReactionSummary(
            countsByReaction: try container.decode([ShipTokReaction: Int].self, forKey: .reactionCounts).filter { $0.value > 0 },
            viewerReactions: Set(viewer.reactions)
        )
        goodVibeCount = try container.decode(Int.self, forKey: .goodVibeCount)
        badVibeCount = try container.decode(Int.self, forKey: .badVibeCount)
        commentCount = try container.decode(Int.self, forKey: .commentCount)
        viewerVibe = viewer.vibe
        viewerVibeFeedbackText = viewer.vibeFeedbackText
        viewerVibeID = viewer.vibeID
        viewerIsDeveloper = viewer.isDeveloper
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reactions.countsByReaction, forKey: .reactionCounts)
        try container.encode(goodVibeCount, forKey: .goodVibeCount)
        try container.encode(badVibeCount, forKey: .badVibeCount)
        try container.encode(commentCount, forKey: .commentCount)
        try container.encode(Viewer(reactions: Array(reactions.viewerReactions), vibe: viewerVibe, vibeFeedbackText: viewerVibeFeedbackText, vibeID: viewerVibeID, isDeveloper: viewerIsDeveloper), forKey: .viewer)
    }

    // A new vibe replaces the viewer's earlier one, so its count moves from the old vibe to the new.
    mutating func setViewerVibe(_ vibe: ShipTokVibe?, feedbackText: String?, vibeID: String?) {
        switch viewerVibe {
        case .good: goodVibeCount = max(goodVibeCount - 1, 0)
        case .bad: badVibeCount = max(badVibeCount - 1, 0)
        case nil: break
        }
        switch vibe {
        case .good: goodVibeCount += 1
        case .bad: badVibeCount += 1
        case nil: break
        }
        viewerVibe = vibe
        viewerVibeFeedbackText = vibe == nil ? nil : feedbackText
        viewerVibeID = vibe == nil ? nil : vibeID
    }

    // A vibe still in its undo window or on its way shows as the viewer's at once.
    func vibeTally(showingPendingVibe pendingVibe: ShipTokVibe?) -> VibeTally {
        var shownFeedback = self
        if let pendingVibe {
            shownFeedback.setViewerVibe(pendingVibe, feedbackText: nil, vibeID: nil)
        }
        return VibeTally(goodVibeCount: shownFeedback.goodVibeCount, badVibeCount: shownFeedback.badVibeCount, viewerVibe: shownFeedback.viewerVibe)
    }
}

// One card in ShipTok's feed: a pull request, a weekly edition or a feature, with its media in show order, as Revyl's backend serves it (docs/shiptok-format.md).
struct ShipTokPost: Identifiable, Hashable, Sendable, Codable {
    enum Kind: String, Hashable, Sendable, Codable {
        case pullRequest = "pull_request"
        case weeklyEdition = "weekly_edition"
        case feature
    }

    let id: String
    let kind: Kind
    let githubRepositoryID: Int64
    let githubRepositoryFullName: String
    let githubIssueNumber: Int
    let githubURL: URL
    let title: String
    let hook: String?
    // The Monday a weekly edition covers, as "YYYY-MM-DD" in the week's Pacific calendar.
    let weekStart: String?
    let deckPullRequestNumbers: [Int]
    let githubAuthor: ShipTokGitHubAuthor
    let pullRequest: ShipTokPullRequestDetails?
    let closedAt: Date?
    var descriptionMarkdown: String
    var media: [ShipTokPostMedia]
    var feedback: ShipTokPostFeedback

    private enum CodingKeys: String, CodingKey {
        case id = "post_id"
        case kind = "post_kind"
        case githubRepositoryID = "github_repository_id"
        case githubRepositoryFullName = "github_repository_full_name"
        case githubIssueNumber = "github_issue_number"
        case githubURL = "github_url"
        case title
        case hook
        case weekStart = "week_start"
        case deckPullRequestNumbers = "deck_pull_request_numbers"
        case githubAuthor = "github_author"
        case pullRequest = "pull_request"
        case closedAt = "closed_at"
        case descriptionMarkdown = "description_markdown"
        case media
        case feedback
    }

    var reactions: ShipTokReactionSummary {
        get { feedback.reactions }
        set { feedback.reactions = newValue }
    }

    // A week's or a feature's card opens the deck of the pull requests its video covers (AGENTS.md, "Pull Request Decks").
    var hasDeck: Bool {
        kind != .pullRequest && !deckPullRequestNumbers.isEmpty
    }

    // How a sentence names it, as in "Couldn't like #12." or "Couldn't like the week of Nov 9–15."
    var reference: String {
        switch kind {
        case .pullRequest: "#\(githubIssueNumber)"
        case .weeklyEdition: "the week of \(weekDatesText ?? "#\(githubIssueNumber)")"
        case .feature: "the feature “\(title)”"
        }
    }

    // "Nov 9–15", or "Oct 26–Nov 1" when the week spans two months.
    var weekDatesText: String? {
        guard let weekStart else { return nil }
        let dateParts = weekStart.split(separator: "-").compactMap { Int($0) }
        let calendar = Self.weekCalendar
        guard dateParts.count == 3,
              let weekStartDate = calendar.date(from: DateComponents(year: dateParts[0], month: dateParts[1], day: dateParts[2]))
        else { return nil }
        let weekEndDate = calendar.date(byAdding: .day, value: 6, to: weekStartDate) ?? weekStartDate
        let monthAndDay = Date.FormatStyle(timeZone: calendar.timeZone).month(.abbreviated).day()
        let weekEndText = calendar.component(.month, from: weekEndDate) == calendar.component(.month, from: weekStartDate)
            ? String(calendar.component(.day, from: weekEndDate))
            : weekEndDate.formatted(monthAndDay)
        return "\(weekStartDate.formatted(monthAndDay))–\(weekEndText)"
    }

    private static var weekCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    // A saved feed keeps no description or media link, so nothing it holds opens a file (AGENTS.md, "Feed Caching").
    var savedCopy: ShipTokPost {
        var savedPost = self
        savedPost.descriptionMarkdown = ""
        savedPost.media = media.map(\.withoutLinks)
        return savedPost
    }
}

struct ShipTokPostComment: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let postID: String
    let parentCommentID: String?
    // The comment a reply answers, the top-level one or a reply under it, and that comment's author.
    let replyToCommentID: String?
    let replyToAuthor: ShipTokPerson?
    let author: ShipTokPerson
    let body: String
    let createdAt: Date
    let viewerCanDelete: Bool
    var reactions: ShipTokReactionSummary
    // A top-level comment's replies, oldest first; a reply has none, since replies are one level deep.
    var replies: [ShipTokPostComment]

    private enum CodingKeys: String, CodingKey {
        case id = "comment_id"
        case postID = "post_id"
        case parentCommentID = "parent_comment_id"
        case replyToCommentID = "reply_to_comment_id"
        case replyToAuthor = "reply_to_author"
        case author
        case body
        case createdAt = "created_at"
        case viewerCanDelete = "viewer_can_delete"
        case reactionCounts = "reaction_counts"
        case viewerReactions = "viewer_reactions"
        case replies
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        postID = try container.decode(String.self, forKey: .postID)
        parentCommentID = try container.decodeIfPresent(String.self, forKey: .parentCommentID)
        replyToCommentID = try container.decodeIfPresent(String.self, forKey: .replyToCommentID)
        replyToAuthor = try container.decodeIfPresent(ShipTokPerson.self, forKey: .replyToAuthor)
        author = try container.decode(ShipTokPerson.self, forKey: .author)
        body = try container.decode(String.self, forKey: .body)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        viewerCanDelete = try container.decode(Bool.self, forKey: .viewerCanDelete)
        reactions = ShipTokReactionSummary(
            countsByReaction: try container.decode([ShipTokReaction: Int].self, forKey: .reactionCounts).filter { $0.value > 0 },
            viewerReactions: Set(try container.decode([ShipTokReaction].self, forKey: .viewerReactions))
        )
        replies = try container.decodeIfPresent([ShipTokPostComment].self, forKey: .replies) ?? []
    }
}

// One person's vibe on a post, with the feedback they wrote, shown beside the post's comments in time order (AGENTS.md, "Vibes").
struct ShipTokPostVibe: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let postID: String
    let author: ShipTokPerson
    let vibe: ShipTokVibe
    let feedbackText: String?
    let createdAt: Date
    let updatedAt: Date
    let viewerCanDelete: Bool

    private enum CodingKeys: String, CodingKey {
        case id = "vibe_id"
        case postID = "post_id"
        case author
        case vibe
        case feedbackText = "feedback_text"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case viewerCanDelete = "viewer_can_delete"
    }
}

struct ShipTokRepository: Identifiable, Hashable, Sendable, Decodable {
    let githubRepositoryID: Int64
    let fullName: String
    let isPrivate: Bool
    let pushedAt: Date?

    var id: Int64 { githubRepositoryID }

    private enum CodingKeys: String, CodingKey {
        case githubRepositoryID = "github_repository_id"
        case fullName = "full_name"
        case isPrivate = "is_private"
        case pushedAt = "pushed_at"
    }
}

// Who is signed in, and the organization whose repositories they watch.
struct RevylAccount: Hashable, Sendable, Codable {
    struct Organization: Hashable, Sendable, Codable {
        let orgID: String
        let displayName: String

        private enum CodingKeys: String, CodingKey {
            case orgID = "org_id"
            case displayName = "display_name"
        }
    }

    let revylUserID: String
    let displayName: String
    let avatarURL: URL?
    let email: String
    let organization: Organization

    private enum CodingKeys: String, CodingKey {
        case revylUserID = "revyl_user_id"
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case email
        case organization
    }
}

struct ShipTokInboxItem: Identifiable, Hashable, Sendable, Decodable {
    enum Kind: String, Hashable, Sendable, Decodable {
        case reaction
        case vibe
        case comment
        case reply
    }

    struct Post: Hashable, Sendable, Decodable {
        let postID: String
        let kind: ShipTokPost.Kind
        let title: String
        let githubRepositoryFullName: String
        let githubIssueNumber: Int

        private enum CodingKeys: String, CodingKey {
            case postID = "post_id"
            case kind = "post_kind"
            case title
            case githubRepositoryFullName = "github_repository_full_name"
            case githubIssueNumber = "github_issue_number"
        }
    }

    let id: String
    let kind: Kind
    let actor: ShipTokPerson
    let post: Post
    let reaction: ShipTokReaction?
    let vibe: ShipTokVibe?
    let text: String?
    let commentID: String?
    // Whose comment a reply answers, which is someone else's when the reply lands in a thread the viewer started.
    let replyToAuthor: ShipTokPerson?
    let createdAt: Date
    // The backend's own spelling of when it was created, which marks the inbox read through exactly this item, to the microsecond (AGENTS.md, "Inbox").
    let createdAtText: String
    let isUnread: Bool

    private enum CodingKeys: String, CodingKey {
        case id = "inbox_item_id"
        case kind = "inbox_item_kind"
        case actor
        case post
        case reaction
        case vibe
        case text
        case commentID = "comment_id"
        case replyToAuthor = "reply_to_author"
        case createdAt = "created_at"
        case isUnread = "is_unread"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        actor = try container.decode(ShipTokPerson.self, forKey: .actor)
        post = try container.decode(Post.self, forKey: .post)
        reaction = try container.decodeIfPresent(ShipTokReaction.self, forKey: .reaction)
        vibe = try container.decodeIfPresent(ShipTokVibe.self, forKey: .vibe)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        commentID = try container.decodeIfPresent(String.self, forKey: .commentID)
        replyToAuthor = try container.decodeIfPresent(ShipTokPerson.self, forKey: .replyToAuthor)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        createdAtText = try container.decode(String.self, forKey: .createdAt)
        isUnread = try container.decode(Bool.self, forKey: .isUnread)
    }
}

extension JSONDecoder {
    static var shipTokBackend: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateText = try container.decode(String.self)
            guard let date = Date(shipTokBackendText: dateText) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 time")
            }
            return date
        }
        return decoder
    }
}

extension Date {
    // Revyl's backend writes times in ISO 8601 with up to six fractional digits, more than Foundation's ISO 8601 parser reads, so the fraction is read on its own.
    init?(shipTokBackendText dateText: String) {
        let fractionMatch = dateText.firstMatch(of: #/\.(\d+)/#)
        let wholeSecondsText = fractionMatch.map { dateText.replacingCharacters(in: $0.range, with: "") } ?? dateText
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let wholeSecondsDate = formatter.date(from: wholeSecondsText) else { return nil }
        let fractionSeconds = fractionMatch.flatMap { Double("0.\($0.1)") } ?? 0
        self = wholeSecondsDate.addingTimeInterval(fractionSeconds)
    }
}
