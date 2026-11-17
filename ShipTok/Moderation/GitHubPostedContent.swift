import Foundation

// A description or top-level comment someone posted on a pull request or week. The viewer can report it through GitHub's own report form, since GitHub hosts it and acts on reports, or hide its poster (AGENTS.md, "Report And Hide").
struct GitHubPostedContent: Hashable, Identifiable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case description
        case comment
    }

    let kind: Kind
    let postedBy: GitHubActor
    let githubURL: URL
    let postedOn: ShipTokAnalyticsSubject

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
        if let author {
            reportableContents.append(GitHubPostedContent(kind: .description, postedBy: author, githubURL: url, postedOn: subject))
        }
        var reportedCommentIDs: Set<String> = []
        for mediaItem in mediaItems {
            guard let sourceCommentID = mediaItem.sourceCommentID,
                  let postedBy = mediaItem.postedBy,
                  reportedCommentIDs.insert(sourceCommentID).inserted,
                  let commentURL = comments.first(where: { $0.id == sourceCommentID })?.url
                    ?? mediaItem.sourceCommentDatabaseID.flatMap({ URL(string: "\(url.absoluteString)#issuecomment-\($0)") })
            else { continue }
            reportableContents.append(GitHubPostedContent(kind: .comment, postedBy: postedBy, githubURL: commentURL, postedOn: subject))
        }
        guard let viewerGitHubLogin else { return reportableContents }
        return reportableContents.filter { !$0.postedBy.hasLogin(viewerGitHubLogin) }
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
