import Foundation
import OSLog

enum GitHubAPIError: LocalizedError {
    case accessTokenRejected
    case feedRepositoryNotVisible(repositoryFullName: String)
    case rateLimited
    case requestFailed(operationName: String, statusCode: Int)
    case graphQLErrors(operationName: String, messages: [String])
    case responseUnreadable(operationName: String)
    case pullRequestNotMerged(number: Int)
    case weeklyEditionUnreadable(number: Int)
    case signInRequired

    var rejectsFeedAccess: Bool {
        switch self {
        case .accessTokenRejected, .feedRepositoryNotVisible:
            true
        case .rateLimited, .requestFailed, .graphQLErrors, .responseUnreadable, .pullRequestNotMerged, .weeklyEditionUnreadable, .signInRequired:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case .accessTokenRejected:
            "GitHub no longer accepts this sign-in. Sign in with Revyl again."
        case .feedRepositoryNotVisible(let repositoryFullName):
            "Revyl's GitHub App no longer reaches \(repositoryFullName) for you. Choose another repository."
        case .rateLimited:
            "GitHub's rate limit is used up for now. ShipTok tries again shortly."
        case .requestFailed(let operationName, let statusCode):
            "GitHub answered \(statusCode) to \(operationName)."
        case .graphQLErrors(let operationName, let messages):
            "GitHub refused \(operationName): \(messages.joined(separator: " "))"
        case .responseUnreadable(let operationName):
            "GitHub's answer to \(operationName) couldn't be read."
        case .pullRequestNotMerged(let number):
            "#\(number) isn't merged."
        case .weeklyEditionUnreadable(let number):
            "#\(number) isn't a weekly video ShipTok can read."
        case .signInRequired:
            "Sign in with Revyl to do that."
        }
    }
}

extension Error {
    var isTaskCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}

final class GitHubAPIClient: Sendable {
    enum Source: Sendable {
        case signedInAccount(GitHubAccountAPI)
        case demoFeed(ShipTokDemoFeed)
    }

    let repositoryFullName: String
    private let repositoryOwnerLogin: String
    private let repositoryName: String
    private var mergedPullRequestSearchQualifiers: String { "repo:\(repositoryFullName) is:pr is:merged" }

    private static let graphQLEndpointURL = URL(string: "https://api.github.com/graphql")!
    private static let mergedPullRequestSearchRangeMaximumResultCount = 125
    // GitHub limits how much of its server time one account may take each minute, so only a few full pull request reads run at once.
    private static let concurrentlyReadPullRequestBatchCount = 6
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "github")

    private let source: Source

    init(source: Source, repositoryFullName: String) {
        self.source = source
        self.repositoryFullName = repositoryFullName
        let repositoryComponents = repositoryFullName.split(separator: "/")
        repositoryOwnerLogin = String(repositoryComponents[0])
        repositoryName = String(repositoryComponents[1])
    }

    func pullRequestURL(number: Int) -> URL {
        URL(string: "https://github.com/\(repositoryFullName)/pull/\(number)")!
    }

    // A demo visitor has no GitHub account, so every write and every read beyond the demo feed asks them to sign in.
    func sendGraphQLQuery<ResponseData: Decodable>(_ query: String, variables: [String: any Sendable]) async throws -> ResponseData {
        guard case .signedInAccount(let accountAPI) = source else { throw GitHubAPIError.signInRequired }
        let operationName = Self.operationName(in: query)
        let requestBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "variables": variables.mapValues { $0 as Any },
        ] as [String: Any])
        var request = URLRequest(url: Self.graphQLEndpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody
        let responseData = try await accountAPI.sendAuthorizedRequest(request, operationName: operationName)
        let responseEnvelope: GraphQLResponseEnvelope<ResponseData>
        do {
            responseEnvelope = try Self.makeJSONDecoder().decode(GraphQLResponseEnvelope<ResponseData>.self, from: responseData)
        } catch {
            Self.logger.error("Reading GitHub's answer to \(operationName, privacy: .public) failed at \(Self.decodingFailureLocation(error), privacy: .public)")
            throw GitHubAPIError.responseUnreadable(operationName: operationName)
        }
        if let graphQLErrors = responseEnvelope.errors, !graphQLErrors.isEmpty {
            if graphQLErrors.contains(where: { $0.type == "RATE_LIMITED" }) {
                throw GitHubAPIError.rateLimited
            }
            if graphQLErrors.contains(where: { $0.type == "NOT_FOUND" && $0.path == ["feedRepository"] }) {
                throw GitHubAPIError.feedRepositoryNotVisible(repositoryFullName: repositoryFullName)
            }
            Self.logger.error("GitHub refused \(operationName, privacy: .public): \(graphQLErrors.compactMap(\.type).joined(separator: ","), privacy: .public)")
            throw GitHubAPIError.graphQLErrors(operationName: operationName, messages: graphQLErrors.map(\.message))
        }
        guard let responseData = responseEnvelope.data else {
            throw GitHubAPIError.responseUnreadable(operationName: operationName)
        }
        return responseData
    }

    // Every merged pull request in a merge-date range, updated since a date if one is given, read in full; each page arrives as it loads, so the caller can show it at once (shiptok/AGENTS.md, Feed Order).
    func searchMergedPullRequests(
        updatedSince earliestUpdateDate: Date?,
        mergedFrom earliestMergeDate: Date?,
        mergedThrough latestMergeDate: Date
    ) async throws -> AsyncThrowingStream<[MergedPullRequest], Error> {
        if case .demoFeed(let demoFeed) = source {
            // The demo feed carries no update dates, so it answers with every pull request in the merge range, and applying an unchanged one again changes nothing.
            var mergedPullRequests: [MergedPullRequest] = []
            for pullRequestNode in try await demoFeed.snapshot().mergedPullRequests {
                guard let mergedAt = pullRequestNode.mergedAt,
                      earliestMergeDate.map({ mergedAt >= $0 }) ?? true,
                      mergedAt <= latestMergeDate
                else { continue }
                mergedPullRequests.append(try await mergedPullRequest(from: pullRequestNode, mergedAt: mergedAt))
            }
            return AsyncThrowingStream { continuation in
                continuation.yield(mergedPullRequests)
                continuation.finish()
            }
        }
        let searchRanges = try await mergedPullRequestSearchRanges(updatedSince: earliestUpdateDate, mergedFrom: earliestMergeDate, mergedThrough: latestMergeDate)
        return AsyncThrowingStream<[MergedPullRequest], Error> { continuation in
            let searchTask = Task {
                do {
                    try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                        for (searchRangeIndex, searchQuery) in searchRanges.enumerated() {
                            if searchRangeIndex >= Self.concurrentlyReadPullRequestBatchCount {
                                _ = try await taskGroup.next()
                            }
                            taskGroup.addTask { try await self.yieldMergedPullRequestPages(matchingSearchQuery: searchQuery, to: continuation) }
                        }
                        try await taskGroup.waitForAll()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in searchTask.cancel() }
        }
    }

    // One cheap search, so a launch with nothing saved opens on the labeled pull requests before it reads the window (shiptok/AGENTS.md, Feed Order).
    func fetchMergedPullRequests(labeled labelName: String) async throws -> [MergedPullRequest] {
        if case .demoFeed(let demoFeed) = source {
            var mergedPullRequests: [MergedPullRequest] = []
            for pullRequestNode in try await demoFeed.snapshot().mergedPullRequests {
                guard let mergedAt = pullRequestNode.mergedAt,
                      (pullRequestNode.labels?.nodes ?? []).contains(where: { $0?.name.caseInsensitiveCompare(labelName) == .orderedSame })
                else { continue }
                mergedPullRequests.append(try await mergedPullRequest(from: pullRequestNode, mergedAt: mergedAt))
            }
            return mergedPullRequests
        }
        let searchQuery = "\(mergedPullRequestSearchQualifiers) label:\(labelName) sort:updated-desc"
        var mergedPullRequests: [MergedPullRequest] = []
        var pageCursor: String?
        repeat {
            let page = try await fetchMergedPullRequestSearchPage(matchingSearchQuery: searchQuery, after: pageCursor)
            mergedPullRequests += page.mergedPullRequests
            pageCursor = page.nextPageCursor
        } while pageCursor != nil
        return mergedPullRequests
    }

    // GitHub search returns at most 1,000 results, so a merge-date range is halved until each part is small, which also lets the parts load in parallel. A pull request's merge date never changes, so paging through a part never skips one that wasn't updated meanwhile, and one that was is read by the next search.
    private func mergedPullRequestSearchRanges(
        updatedSince earliestUpdateDate: Date?,
        mergedFrom earliestMergeDate: Date?,
        mergedThrough latestMergeDate: Date
    ) async throws -> [String] {
        let mergedRangeText = earliestMergeDate.map { "\($0.formatted(.iso8601))..\(latestMergeDate.formatted(.iso8601))" } ?? "<=\(latestMergeDate.formatted(.iso8601))"
        let updatedQualifier = earliestUpdateDate.map { " updated:>=\($0.formatted(.iso8601))" } ?? ""
        let searchQuery = "\(mergedPullRequestSearchQualifiers) merged:\(mergedRangeText)\(updatedQualifier) sort:updated-desc"
        let probe: MergedPullRequestSearchProbeData = try await sendGraphQLQuery(Self.mergedPullRequestSearchProbeQuery, variables: [
            "owner": repositoryOwnerLogin,
            "name": repositoryName,
            "searchQuery": searchQuery,
        ])
        let matchingPullRequestCount = probe.search.issueCount
        guard matchingPullRequestCount > Self.mergedPullRequestSearchRangeMaximumResultCount else {
            return matchingPullRequestCount > 0 ? [searchQuery] : []
        }
        let rangeStartDate = earliestMergeDate ?? probe.feedRepository.createdAt
        let rangeMidpointDate = Date(timeIntervalSince1970: ((rangeStartDate.timeIntervalSince1970 + latestMergeDate.timeIntervalSince1970) / 2).rounded(.down))
        async let newerHalfSearchRanges = mergedPullRequestSearchRanges(
            updatedSince: earliestUpdateDate,
            mergedFrom: rangeMidpointDate.addingTimeInterval(1),
            mergedThrough: latestMergeDate
        )
        let olderHalfSearchRanges = try await mergedPullRequestSearchRanges(updatedSince: earliestUpdateDate, mergedFrom: rangeStartDate, mergedThrough: rangeMidpointDate)
        return try await newerHalfSearchRanges + olderHalfSearchRanges
    }

    private func yieldMergedPullRequestPages(
        matchingSearchQuery searchQuery: String,
        to continuation: AsyncThrowingStream<[MergedPullRequest], Error>.Continuation
    ) async throws {
        var pageCursor: String?
        repeat {
            let page = try await fetchMergedPullRequestSearchPage(matchingSearchQuery: searchQuery, after: pageCursor)
            continuation.yield(page.mergedPullRequests)
            pageCursor = page.nextPageCursor
        } while pageCursor != nil
    }

    private func fetchMergedPullRequestSearchPage(
        matchingSearchQuery searchQuery: String,
        after pageCursor: String?
    ) async throws -> (mergedPullRequests: [MergedPullRequest], nextPageCursor: String?) {
        var variables: [String: any Sendable] = ["searchQuery": searchQuery]
        if let pageCursor {
            variables["after"] = pageCursor
        }
        let page: MergedPullRequestSearchPageData = try await sendGraphQLQuery(Self.mergedPullRequestsMatchingSearchQuery, variables: variables)
        var mergedPullRequests: [MergedPullRequest] = []
        for pullRequestNode in page.search.nodes.compactMap({ $0 }) {
            guard let mergedAt = pullRequestNode.mergedAt else { continue }
            mergedPullRequests.append(try await mergedPullRequest(from: pullRequestNode, mergedAt: mergedAt))
        }
        return (mergedPullRequests, page.search.pageInfo.hasNextPage ? page.search.pageInfo.endCursor : nil)
    }

    func fetchMergedPullRequest(number: Int) async throws -> MergedPullRequest {
        if case .demoFeed(let demoFeed) = source {
            guard let pullRequestNode = try await demoFeed.snapshot().mergedPullRequests.first(where: { $0.number == number }),
                  let mergedAt = pullRequestNode.mergedAt
            else {
                throw GitHubAPIError.pullRequestNotMerged(number: number)
            }
            return try await mergedPullRequest(from: pullRequestNode, mergedAt: mergedAt)
        }
        let response: MergedPullRequestByNumberData = try await sendGraphQLQuery(Self.mergedPullRequestByNumberQuery, variables: [
            "owner": repositoryOwnerLogin,
            "name": repositoryName,
            "number": number,
        ])
        guard let pullRequestNode = response.feedRepository?.pullRequest, let mergedAt = pullRequestNode.mergedAt else {
            throw GitHubAPIError.pullRequestNotMerged(number: number)
        }
        return try await mergedPullRequest(from: pullRequestNode, mergedAt: mergedAt)
    }

    // Every published weekly edition, newest week first: the closed issues carrying the weekly label, read through the issues API, never search,
    // so a week shows the moment it closes (shiptok/AGENTS.md, Weekly Mode).
    func fetchWeeklyEditions() async throws -> [WeeklyEdition] {
        if case .demoFeed(let demoFeed) = source {
            var weeklyEditions: [WeeklyEdition] = []
            for weeklyEditionNode in try await demoFeed.snapshot().weeklyEditionIssues {
                guard let weeklyEdition = try await weeklyEdition(from: weeklyEditionNode) else { continue }
                weeklyEditions.append(weeklyEdition)
            }
            return weeklyEditions.sorted { $0.weekStartDate > $1.weekStartDate }
        }
        var weeklyEditions: [WeeklyEdition] = []
        var pageCursor: String?
        repeat {
            var variables: [String: any Sendable] = [
                "owner": repositoryOwnerLogin,
                "name": repositoryName,
                "labelName": WeeklyEditionFormat.labelName,
            ]
            if let pageCursor { variables["after"] = pageCursor }
            let page: WeeklyEditionIssuesPageData = try await sendGraphQLQuery(Self.closedWeeklyEditionIssuesQuery, variables: variables)
            guard let issueConnection = page.feedRepository?.issues else {
                throw GitHubAPIError.responseUnreadable(operationName: Self.operationName(in: Self.closedWeeklyEditionIssuesQuery))
            }
            for weeklyEditionNode in issueConnection.nodes.compactMap({ $0 }) {
                guard let weeklyEdition = try await weeklyEdition(from: weeklyEditionNode) else {
                    Self.logger.error("#\(weeklyEditionNode.number, privacy: .public) carries the weekly label but not the weekly format, so it's left out")
                    continue
                }
                weeklyEditions.append(weeklyEdition)
            }
            pageCursor = issueConnection.pageInfo.hasNextPage ? issueConnection.pageInfo.endCursor : nil
        } while pageCursor != nil
        return weeklyEditions.sorted { $0.weekStartDate > $1.weekStartDate }
    }

    func fetchWeeklyEdition(number: Int) async throws -> WeeklyEdition {
        if case .demoFeed(let demoFeed) = source {
            guard let weeklyEditionNode = try await demoFeed.snapshot().weeklyEditionIssues.first(where: { $0.number == number }),
                  let weeklyEdition = try await weeklyEdition(from: weeklyEditionNode)
            else {
                throw GitHubAPIError.weeklyEditionUnreadable(number: number)
            }
            return weeklyEdition
        }
        let response: WeeklyEditionByNumberData = try await sendGraphQLQuery(Self.weeklyEditionByNumberQuery, variables: [
            "owner": repositoryOwnerLogin,
            "name": repositoryName,
            "number": number,
        ])
        guard let weeklyEditionNode = response.feedRepository?.issue,
              let weeklyEdition = try await weeklyEdition(from: weeklyEditionNode)
        else {
            throw GitHubAPIError.weeklyEditionUnreadable(number: number)
        }
        return weeklyEdition
    }

    func addComment(bodyMarkdown: String, toSubjectID subjectID: String) async throws -> PullRequestComment {
        let response: AddPullRequestCommentData = try await sendGraphQLQuery(Self.addPullRequestCommentMutation, variables: [
            "subjectID": subjectID,
            "body": bodyMarkdown,
        ])
        guard let commentNode = response.addComment?.commentEdge?.node else {
            throw GitHubAPIError.responseUnreadable(operationName: Self.operationName(in: Self.addPullRequestCommentMutation))
        }
        return PullRequestComment(node: commentNode)
    }

    func deleteComment(id commentID: String) async throws {
        let _: IgnoredGraphQLData = try await sendGraphQLQuery(Self.deletePullRequestCommentMutation, variables: ["commentID": commentID])
    }

    func addReaction(_ reaction: GitHubReaction, toSubjectID subjectID: String) async throws {
        let _: IgnoredGraphQLData = try await sendGraphQLQuery(Self.addReactionMutation, variables: [
            "subjectID": subjectID,
            "content": reaction.rawValue,
        ])
    }

    func removeReaction(_ reaction: GitHubReaction, fromSubjectID subjectID: String) async throws {
        let _: IgnoredGraphQLData = try await sendGraphQLQuery(Self.removeReactionMutation, variables: [
            "subjectID": subjectID,
            "content": reaction.rawValue,
        ])
    }

    private func everyComment(ofSubjectID subjectID: String, firstPage: IssueCommentConnectionNode) async throws -> [(comment: PullRequestComment, bodyHTML: String)] {
        var commentNodes = firstPage.nodes.compactMap { $0 }
        var commentsPageInfo = firstPage.pageInfo
        while commentsPageInfo.hasNextPage, let endCursor = commentsPageInfo.endCursor {
            let page: CommentsPageData = try await sendGraphQLQuery(Self.commentsPageQuery, variables: [
                "subjectID": subjectID,
                "after": endCursor,
            ])
            guard let commentConnection = page.node?.comments else {
                throw GitHubAPIError.responseUnreadable(operationName: Self.operationName(in: Self.commentsPageQuery))
            }
            commentNodes += commentConnection.nodes.compactMap { $0 }
            commentsPageInfo = commentConnection.pageInfo
        }
        return commentNodes.map { (comment: PullRequestComment(node: $0), bodyHTML: $0.bodyHTML) }
    }

    private func weeklyEdition(from weeklyEditionNode: WeeklyEditionNode) async throws -> WeeklyEdition? {
        guard weeklyEditionNode.state == "CLOSED",
              weeklyEditionNode.labels.nodes.compactMap({ $0 }).contains(where: { $0.name == WeeklyEditionFormat.labelName }),
              let description = WeeklyEditionFormat.description(fromMarkdown: weeklyEditionNode.body)
        else { return nil }
        let commentsWithBodyHTML = try await everyComment(ofSubjectID: weeklyEditionNode.id, firstPage: weeklyEditionNode.comments)
        let author = weeklyEditionNode.author.map(GitHubActor.init(node:))
        let mediaItems = PullRequestMediaExtraction.mediaItems(
            descriptionMarkdown: weeklyEditionNode.body,
            descriptionHTML: weeklyEditionNode.bodyHTML,
            descriptionLastEditedAt: weeklyEditionNode.lastEditedAt ?? weeklyEditionNode.createdAt,
            descriptionAuthor: author,
            comments: commentsWithBodyHTML
        )
        guard !mediaItems.isEmpty else { return nil }
        return WeeklyEdition(
            id: weeklyEditionNode.id,
            number: weeklyEditionNode.number,
            url: weeklyEditionNode.url,
            author: author,
            weekStartDate: description.weekStartDate,
            title: description.title,
            hook: description.hook,
            pullRequestNumbers: description.pullRequestNumbers,
            reactions: GitHubReactionSummary(reactionGroups: weeklyEditionNode.reactionGroups ?? []),
            comments: commentsWithBodyHTML.map(\.comment),
            mediaItems: mediaItems
        )
    }

    private func mergedPullRequest(from pullRequestNode: PullRequestNode, mergedAt: Date) async throws -> MergedPullRequest {
        let commentsWithBodyHTML = try await everyComment(ofSubjectID: pullRequestNode.id, firstPage: pullRequestNode.comments)
        let author = pullRequestNode.author.map(GitHubActor.init(node:))
        let labels = try (pullRequestNode.labels?.nodes ?? []).compactMap { $0 }.map { labelNode in
            guard let rgbHex = UInt32(labelNode.color, radix: 16) else {
                throw GitHubAPIError.responseUnreadable(operationName: "ShipTokMergedPullRequestFields")
            }
            return GitHubLabel(name: labelNode.name, rgbHex: rgbHex)
        }
        return MergedPullRequest(
            id: pullRequestNode.id,
            number: pullRequestNode.number,
            title: pullRequestNode.title,
            url: pullRequestNode.url,
            author: author,
            mergedAt: mergedAt,
            descriptionMarkdown: pullRequestNode.body,
            additions: pullRequestNode.additions,
            deletions: pullRequestNode.deletions,
            changedFiles: pullRequestNode.changedFiles,
            labels: labels,
            reactions: GitHubReactionSummary(reactionGroups: pullRequestNode.reactionGroups ?? []),
            comments: commentsWithBodyHTML.map(\.comment),
            mediaItems: PullRequestMediaExtraction.mediaItems(
                descriptionMarkdown: pullRequestNode.body,
                descriptionHTML: pullRequestNode.bodyHTML,
                descriptionLastEditedAt: pullRequestNode.lastEditedAt ?? pullRequestNode.createdAt,
                descriptionAuthor: author,
                comments: commentsWithBodyHTML
            )
        )
    }

    private static func operationName(in query: String) -> String {
        let words = query.split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == "{" })
        guard words.count > 1, words[0] == "query" || words[0] == "mutation" else { return "a GraphQL request" }
        return String(words[1])
    }

    fileprivate static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func decodingFailureLocation(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return "an unknown place" }
        switch decodingError {
        case .keyNotFound(let missingKey, let context):
            return (context.codingPath + [missingKey]).map(\.stringValue).joined(separator: ".")
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return context.codingPath.map(\.stringValue).joined(separator: ".")
        @unknown default:
            return "an unknown place"
        }
    }

    private static let issueCommentFieldsFragment = """
        fragment ShipTokIssueCommentFields on IssueComment {
          id
          databaseId
          author { __typename login avatarUrl }
          body
          bodyHTML
          createdAt
          lastEditedAt
          url
          viewerCanDelete
          reactionGroups { content viewerHasReacted reactors { totalCount } }
        }
        """

    private static let mergedPullRequestFieldsFragment = """
        fragment ShipTokMergedPullRequestFields on PullRequest {
          id
          number
          title
          url
          mergedAt
          createdAt
          lastEditedAt
          body
          bodyHTML
          additions
          deletions
          changedFiles
          labels(first: 20) { nodes { name color } }
          author { __typename login avatarUrl }
          reactionGroups { content viewerHasReacted reactors { totalCount } }
          comments(first: 100) {
            pageInfo { hasNextPage endCursor }
            nodes { ...ShipTokIssueCommentFields }
          }
        }
        """

    private static let mergedPullRequestsMatchingSearchQuery = """
        query MergedPullRequestsMatchingSearch($searchQuery: String!, $after: String) {
          search(query: $searchQuery, type: ISSUE, first: 25, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes { ... on PullRequest { ...ShipTokMergedPullRequestFields } }
          }
        }
        """ + "\n" + mergedPullRequestFieldsFragment + "\n" + issueCommentFieldsFragment

    private static let mergedPullRequestByNumberQuery = """
        query MergedPullRequestByNumber($owner: String!, $name: String!, $number: Int!) {
          feedRepository: repository(owner: $owner, name: $name) {
            pullRequest(number: $number) { ...ShipTokMergedPullRequestFields }
          }
        }
        """ + "\n" + mergedPullRequestFieldsFragment + "\n" + issueCommentFieldsFragment

    private static let commentsPageQuery = """
        query CommentsPage($subjectID: ID!, $after: String!) {
          node(id: $subjectID) {
            ... on PullRequest {
              comments(first: 100, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes { ...ShipTokIssueCommentFields }
              }
            }
            ... on Issue {
              comments(first: 100, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes { ...ShipTokIssueCommentFields }
              }
            }
          }
        }
        """ + "\n" + issueCommentFieldsFragment

    private static let weeklyEditionFieldsFragment = """
        fragment ShipTokWeeklyEditionFields on Issue {
          id
          number
          url
          state
          labels(first: 100) { nodes { name color } }
          createdAt
          lastEditedAt
          body
          bodyHTML
          author { __typename login avatarUrl }
          reactionGroups { content viewerHasReacted reactors { totalCount } }
          comments(first: 100) {
            pageInfo { hasNextPage endCursor }
            nodes { ...ShipTokIssueCommentFields }
          }
        }
        """

    private static let closedWeeklyEditionIssuesQuery = """
        query ClosedWeeklyEditionIssues($owner: String!, $name: String!, $labelName: String!, $after: String) {
          feedRepository: repository(owner: $owner, name: $name) {
            issues(labels: [$labelName], states: [CLOSED], first: 25, after: $after, orderBy: { field: CREATED_AT, direction: DESC }) {
              pageInfo { hasNextPage endCursor }
              nodes { ...ShipTokWeeklyEditionFields }
            }
          }
        }
        """ + "\n" + weeklyEditionFieldsFragment + "\n" + issueCommentFieldsFragment

    private static let weeklyEditionByNumberQuery = """
        query WeeklyEditionByNumber($owner: String!, $name: String!, $number: Int!) {
          feedRepository: repository(owner: $owner, name: $name) {
            issue(number: $number) { ...ShipTokWeeklyEditionFields }
          }
        }
        """ + "\n" + weeklyEditionFieldsFragment + "\n" + issueCommentFieldsFragment

    private static let mergedPullRequestSearchProbeQuery = """
        query MergedPullRequestSearchProbe($owner: String!, $name: String!, $searchQuery: String!) {
          feedRepository: repository(owner: $owner, name: $name) { createdAt }
          search(query: $searchQuery, type: ISSUE, first: 0) { issueCount }
        }
        """

    private static let addPullRequestCommentMutation = """
        mutation AddPullRequestComment($subjectID: ID!, $body: String!) {
          addComment(input: {subjectId: $subjectID, body: $body}) {
            commentEdge { node { ...ShipTokIssueCommentFields } }
          }
        }
        """ + "\n" + issueCommentFieldsFragment

    private static let deletePullRequestCommentMutation = """
        mutation DeletePullRequestComment($commentID: ID!) {
          deleteIssueComment(input: {id: $commentID}) { clientMutationId }
        }
        """

    private static let addReactionMutation = """
        mutation AddReaction($subjectID: ID!, $content: ReactionContent!) {
          addReaction(input: {subjectId: $subjectID, content: $content}) { reaction { content } }
        }
        """

    private static let removeReactionMutation = """
        mutation RemoveReaction($subjectID: ID!, $content: ReactionContent!) {
          removeReaction(input: {subjectId: $subjectID, content: $content}) { reaction { content } }
        }
        """
}

// What someone sees before signing in: one public repository's merged pull requests and weekly videos, which Revyl's backend reads with its GitHub App
// and holds for about half a minute. GitHub signs the media links in it for about five minutes, so the app holds it about as long (shiptok/AGENTS.md, "Demo Mode").
actor ShipTokDemoFeed {
    private static let freshnessSeconds: TimeInterval = 15
    private let shipTokAPI = RevylShipTokAPI()
    private var heldSnapshot: (snapshot: DemoFeedSnapshot, readAt: Date)?
    private var snapshotRead: Task<DemoFeedSnapshot, any Error>?

    func repositoryFullName() async throws -> String {
        try await snapshot().repositoryFullName
    }

    fileprivate func snapshot() async throws -> DemoFeedSnapshot {
        if let heldSnapshot, Date.now.timeIntervalSince(heldSnapshot.readAt) < Self.freshnessSeconds {
            return heldSnapshot.snapshot
        }
        if let snapshotRead {
            return try await snapshotRead.value
        }
        let read = Task { [shipTokAPI] in
            let snapshotData = try await shipTokAPI.fetchDemoFeed()
            do {
                return try GitHubAPIClient.makeJSONDecoder().decode(DemoFeedSnapshot.self, from: snapshotData)
            } catch {
                throw RevylShipTokAPIError.responseUnreadable(operationName: "the demo")
            }
        }
        snapshotRead = read
        defer { snapshotRead = nil }
        let snapshot = try await read.value
        heldSnapshot = (snapshot, .now)
        return snapshot
    }
}

private struct DemoFeedSnapshot: Decodable {
    let repositoryFullName: String
    let mergedPullRequests: [PullRequestNode]
    let weeklyEditionIssues: [WeeklyEditionNode]

    enum CodingKeys: String, CodingKey {
        case repositoryFullName = "repository_full_name"
        case mergedPullRequests = "merged_pull_requests"
        case weeklyEditionIssues = "weekly_edition_issues"
    }
}

private struct GraphQLResponseEnvelope<ResponseData: Decodable>: Decodable {
    let data: ResponseData?
    let errors: [GraphQLError]?

    enum CodingKeys: String, CodingKey {
        case data
        case errors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        errors = try container.decodeIfPresent([GraphQLError].self, forKey: .errors)
        if let errors, !errors.isEmpty {
            data = try? container.decodeIfPresent(ResponseData.self, forKey: .data)
        } else {
            data = try container.decodeIfPresent(ResponseData.self, forKey: .data)
        }
    }
}

private struct GraphQLError: Decodable {
    let message: String
    let type: String?
    let path: [String]

    enum CodingKeys: String, CodingKey {
        case message
        case type
        case path
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(String.self, forKey: .message)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        var pathElements: [String] = []
        if var pathContainer = try? container.nestedUnkeyedContainer(forKey: .path) {
            while !pathContainer.isAtEnd {
                if let fieldName = try? pathContainer.decode(String.self) {
                    pathElements.append(fieldName)
                } else if let listIndex = try? pathContainer.decode(Int.self) {
                    pathElements.append(String(listIndex))
                } else {
                    break
                }
            }
        }
        path = pathElements
    }
}

private struct IgnoredGraphQLData: Decodable {}

private struct ActorNode: Decodable {
    let typeName: String
    let login: String
    let avatarUrl: URL?

    enum CodingKeys: String, CodingKey {
        case typeName = "__typename"
        case login
        case avatarUrl
    }
}

private struct TotalCountNode: Decodable {
    let totalCount: Int
}

private struct IssueCountNode: Decodable {
    let issueCount: Int
}

private struct PageInfoNode: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
}

private struct ReactionGroupNode: Decodable {
    let content: String
    let viewerHasReacted: Bool
    let reactors: TotalCountNode
}

private struct IssueCommentNode: Decodable {
    let id: String
    let databaseId: Int?
    let author: ActorNode?
    let body: String
    let bodyHTML: String
    let createdAt: Date
    let lastEditedAt: Date?
    let url: URL
    let viewerCanDelete: Bool
    let reactionGroups: [ReactionGroupNode]?
}

private struct IssueCommentConnectionNode: Decodable {
    let pageInfo: PageInfoNode
    let nodes: [IssueCommentNode?]
}

private struct PullRequestNode: Decodable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let mergedAt: Date?
    let createdAt: Date
    let lastEditedAt: Date?
    let body: String
    let bodyHTML: String
    let additions: Int
    let deletions: Int
    let changedFiles: Int
    let labels: LabelConnectionNode?
    let author: ActorNode?
    let reactionGroups: [ReactionGroupNode]?
    let comments: IssueCommentConnectionNode
}

private struct LabelConnectionNode: Decodable {
    let nodes: [LabelNode?]
}

private struct LabelNode: Decodable {
    let name: String
    let color: String
}

private struct PullRequestSearchConnectionNode: Decodable {
    let pageInfo: PageInfoNode
    let nodes: [PullRequestNode?]
}

private struct MergedPullRequestSearchPageData: Decodable {
    let search: PullRequestSearchConnectionNode
}

private struct MergedPullRequestByNumberData: Decodable {
    struct RepositoryNode: Decodable {
        let pullRequest: PullRequestNode?
    }

    let feedRepository: RepositoryNode?
}

private struct CommentsPageData: Decodable {
    struct CommentedNode: Decodable {
        let comments: IssueCommentConnectionNode?
    }

    let node: CommentedNode?
}

private struct WeeklyEditionNode: Decodable {
    let id: String
    let number: Int
    let url: URL
    let state: String
    let labels: LabelConnectionNode
    let createdAt: Date
    let lastEditedAt: Date?
    let body: String
    let bodyHTML: String
    let author: ActorNode?
    let reactionGroups: [ReactionGroupNode]?
    let comments: IssueCommentConnectionNode
}

private struct WeeklyEditionIssuesPageData: Decodable {
    struct IssueConnectionNode: Decodable {
        let pageInfo: PageInfoNode
        let nodes: [WeeklyEditionNode?]
    }

    struct RepositoryNode: Decodable {
        let issues: IssueConnectionNode
    }

    let feedRepository: RepositoryNode?
}

private struct WeeklyEditionByNumberData: Decodable {
    struct RepositoryNode: Decodable {
        let issue: WeeklyEditionNode?
    }

    let feedRepository: RepositoryNode?
}

private struct MergedPullRequestSearchProbeData: Decodable {
    struct RepositoryNode: Decodable {
        let createdAt: Date
    }

    let feedRepository: RepositoryNode
    let search: IssueCountNode
}

private struct AddPullRequestCommentData: Decodable {
    struct AddCommentPayload: Decodable {
        let commentEdge: CommentEdge?
    }

    struct CommentEdge: Decodable {
        let node: IssueCommentNode?
    }

    let addComment: AddCommentPayload?
}

private extension GitHubActor {
    init(node: ActorNode) {
        self.init(login: node.login, avatarURL: node.avatarUrl, isBot: node.typeName == "Bot")
    }
}

private extension GitHubReactionSummary {
    init(reactionGroups: [ReactionGroupNode]) {
        var countsByReaction: [GitHubReaction: Int] = [:]
        var viewerReactions: Set<GitHubReaction> = []
        for reactionGroup in reactionGroups {
            guard let reaction = GitHubReaction(rawValue: reactionGroup.content) else { continue }
            if reactionGroup.reactors.totalCount > 0 {
                countsByReaction[reaction] = reactionGroup.reactors.totalCount
            }
            if reactionGroup.viewerHasReacted {
                viewerReactions.insert(reaction)
            }
        }
        self.init(countsByReaction: countsByReaction, viewerReactions: viewerReactions)
    }
}

private extension PullRequestComment {
    init(node: IssueCommentNode) {
        self.init(
            id: node.id,
            author: node.author.map(GitHubActor.init(node:)),
            bodyMarkdown: node.body,
            createdAt: node.createdAt,
            url: node.url,
            viewerCanDelete: node.viewerCanDelete,
            reactions: GitHubReactionSummary(reactionGroups: node.reactionGroups ?? []),
            databaseID: node.databaseId,
            lastEditedAt: node.lastEditedAt
        )
    }
}
