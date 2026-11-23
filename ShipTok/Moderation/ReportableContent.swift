import SwiftUI

// What the viewer can report or hide the poster of: a post, which GitHub hosts and takes reports on through its own form, or a comment, reply or vibe, which Revyl holds and reports to the organization's owners and admins. An inbox vibe or reaction can only be hidden (AGENTS.md, "Report And Hide").
struct ReportableContent: Hashable, Identifiable {
    enum Kind: Hashable {
        case post(ShipTokPost.Kind)
        case comment
        case reply
        case vibe
        case reaction
    }

    let kind: Kind
    let poster: HiddenPerson
    let postID: String
    let commentID: String?
    let vibeID: String?
    // The form GitHub's own Report content menu opens for a post; nil for what Revyl holds.
    let githubReportURL: URL?

    var id: String { commentID ?? vibeID ?? postID }

    var isReportable: Bool {
        githubReportURL != nil || commentID != nil || vibeID != nil
    }

    // Nil for the viewer's own post and for a post whose GitHub account was deleted, which has nobody to report or hide (AGENTS.md, "Report And Hide").
    init?(post: ShipTokPost) {
        guard !post.feedback.viewerIsDeveloper, let login = post.githubAuthor.login else { return nil }
        kind = .post(post.kind)
        poster = HiddenPerson(githubLogin: login)
        postID = post.id
        commentID = nil
        vibeID = nil
        let queryValueCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encodedContentURL = post.githubURL.absoluteString.addingPercentEncoding(withAllowedCharacters: queryValueCharacters) ?? ""
        // GitHub's report form names a bot's account with its "[bot]" suffix.
        let reportedLogin = post.githubAuthor.isBot ? "\(login)[bot]" : login
        let encodedReportedPerson = "\(reportedLogin) (user)".addingPercentEncoding(withAllowedCharacters: queryValueCharacters) ?? ""
        githubReportURL = URL(string: "https://github.com/contact/report-content?content_url=\(encodedContentURL)&report=\(encodedReportedPerson)")
    }

    init(comment: ShipTokPostComment) {
        kind = comment.parentCommentID == nil ? .comment : .reply
        poster = HiddenPerson(revylPerson: comment.author)
        postID = comment.postID
        commentID = comment.id
        vibeID = nil
        githubReportURL = nil
    }

    init(vibe: ShipTokPostVibe) {
        kind = .vibe
        poster = HiddenPerson(revylPerson: vibe.author)
        postID = vibe.postID
        commentID = nil
        vibeID = vibe.id
        githubReportURL = nil
    }

    // An inbox item names its comment or reply, which can be reported; its vibe or reaction can only be hidden.
    init(inboxItem: ShipTokInboxItem) {
        kind = switch inboxItem.kind {
        case .reaction: .reaction
        case .vibe: .vibe
        case .comment: .comment
        case .reply: .reply
        }
        poster = HiddenPerson(revylPerson: inboxItem.actor)
        postID = inboxItem.post.postID
        commentID = inboxItem.kind == .comment || inboxItem.kind == .reply ? inboxItem.commentID : nil
        vibeID = nil
        githubReportURL = nil
    }

    var sectionTitle: String {
        switch kind {
        case .post(.pullRequest): "Pull request by \(poster.displayName)"
        case .post(.weeklyEdition): "Weekly video by \(poster.displayName)"
        case .post(.feature): "Feature video by \(poster.displayName)"
        case .comment: "Comment by \(poster.displayName)"
        case .reply: "Reply by \(poster.displayName)"
        case .vibe: "Vibe by \(poster.displayName)"
        case .reaction: "Reaction by \(poster.displayName)"
        }
    }
}

struct ContentModeration {
    let reportableContents: [ReportableContent]
    let onReport: (ReportableContent) -> Void
    let onHide: (ReportableContent) -> Void
}

struct ContentModerationMenu<MenuLabel: View>: View {
    let moderation: ContentModeration
    @ViewBuilder let label: () -> MenuLabel

    var body: some View {
        Menu {
            ForEach(moderation.reportableContents) { reportableContent in
                Section(reportableContent.sectionTitle) {
                    ContentModerationButtons(reportableContent: reportableContent, onReport: moderation.onReport, onHide: moderation.onHide)
                }
            }
        } label: {
            label()
        }
        .menuOrder(.fixed)
    }
}

struct ContentModerationButtons: View {
    let reportableContent: ReportableContent
    let onReport: (ReportableContent) -> Void
    let onHide: (ReportableContent) -> Void

    var body: some View {
        if reportableContent.isReportable {
            Button { onReport(reportableContent) } label: {
                Label(reportableContent.githubReportURL == nil ? "Report" : "Report on GitHub", systemImage: "flag")
            }
        }
        Button(role: .destructive) { onHide(reportableContent) } label: {
            Label("Hide \(reportableContent.poster.displayName)", systemImage: "eye.slash")
        }
    }
}
