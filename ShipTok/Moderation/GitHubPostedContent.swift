import Foundation

// A description, top-level comment or reaction someone posted on a pull request or week. The viewer can report a description or comment through GitHub's own report form, since GitHub hosts it and acts on reports, or hide its poster (AGENTS.md, "Report And Hide").
struct GitHubPostedContent: Hashable, Identifiable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case description
        case comment
        case reaction
    }

    let kind: Kind
    let postedBy: GitHubActor
    // A reaction's is the pull request or week it reacts to.
    let githubURL: URL
    // Nil in the inbox, whose query doesn't read the pull request's node id.
    let postedOn: ShipTokAnalyticsSubject?

    var id: URL { githubURL }

    // The form GitHub's own Report content menu opens for this description or comment.
    var githubReportURL: URL {
        let queryValueCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encodedContentURL = githubURL.absoluteString.addingPercentEncoding(withAllowedCharacters: queryValueCharacters) ?? ""
        // GitHub's GraphQL API gives a bot's login without the "[bot]" suffix its report form needs to name the account.
        let reportedLogin = postedBy.isBot ? "\(postedBy.login)[bot]" : postedBy.login
        let encodedReportedPerson = "\(reportedLogin) (user)".addingPercentEncoding(withAllowedCharacters: queryValueCharacters) ?? ""
        return URL(string: "https://github.com/contact/report-content?content_url=\(encodedContentURL)&report=\(encodedReportedPerson)")!
    }
}

extension GitHubCommentThread {
    // The thread's description, then each comment whose media the thread shows, leaving out the viewer's own; a demo visitor has none.
    func reportableContents(postedOn subject: ShipTokAnalyticsSubject, excludingContentBy viewerGitHubLogin: String?) -> [GitHubPostedContent] {
        var reportableContents: [GitHubPostedContent] = []
        if let author, !(viewerGitHubLogin.map(author.hasLogin) ?? false) {
            reportableContents.append(GitHubPostedContent(kind: .description, postedBy: author, githubURL: url, postedOn: subject))
        }
        var reportedCommentIDs: Set<String> = []
        for mediaItem in mediaItems {
            guard let sourceCommentID = mediaItem.sourceCommentID,
                  reportedCommentIDs.insert(sourceCommentID).inserted,
                  let commentContent = reportableContent(of: mediaItem, postedOn: subject, excludingContentBy: viewerGitHubLogin)
            else { continue }
            reportableContents.append(commentContent)
        }
        return reportableContents
    }

    // The description or comment a media item came from, unless the viewer posted it.
    func reportableContent(of mediaItem: PullRequestMediaItem, postedOn subject: ShipTokAnalyticsSubject, excludingContentBy viewerGitHubLogin: String?) -> GitHubPostedContent? {
        let postedContent: GitHubPostedContent
        if let sourceCommentID = mediaItem.sourceCommentID {
            guard let postedBy = mediaItem.postedBy,
                  let commentURL = comments.first(where: { $0.id == sourceCommentID })?.url
                    ?? mediaItem.sourceCommentDatabaseID.flatMap({ URL(string: "\(url.absoluteString)#issuecomment-\($0)") })
            else { return nil }
            postedContent = GitHubPostedContent(kind: .comment, postedBy: postedBy, githubURL: commentURL, postedOn: subject)
        } else {
            guard let author else { return nil }
            postedContent = GitHubPostedContent(kind: .description, postedBy: author, githubURL: url, postedOn: subject)
        }
        if let viewerGitHubLogin, postedContent.postedBy.hasLogin(viewerGitHubLogin) { return nil }
        return postedContent
    }

    // Nil when a hidden person wrote the thread or posted every one of its media items, so it leaves the feed; otherwise the thread without hidden people's comments, vibes and media. A hidden hero gives way to the hero the ShipTok format's rule picks from the media left.
    @MainActor
    func withoutHiddenPeople(_ hiddenPeopleStore: HiddenPeopleStore) -> Self? {
        guard hiddenPeopleStore.hasHiddenPeople else { return self }
        guard !hiddenPeopleStore.isHidden(author) else { return nil }
        var visibleThread = self
        visibleThread.comments.removeAll { hiddenPeopleStore.isHidden($0.author) }
        visibleThread.mediaItems = PullRequestMediaExtraction.mediaItemsWithHeroFirst(mediaItems.filter { !hiddenPeopleStore.isHidden($0.postedBy) })
        guard !visibleThread.mediaItems.isEmpty || mediaItems.isEmpty else { return nil }
        return visibleThread
    }
}
