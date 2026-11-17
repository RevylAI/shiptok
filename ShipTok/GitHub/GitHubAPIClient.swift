import Foundation
import OSLog

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

    // Every merged pull request in a merge-date range, updated since a date if one is given, read in full; each page arrives as it loads, so the caller can show it at once (AGENTS.md, "Feed Order").
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

    // One cheap search, so a launch with nothing saved opens on the labeled pull requests before it reads the window (AGENTS.md, "Feed Order").
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
        let probe: MergedPullRequestSearchProbeData = try await sendGraphQLQuery(GitHubGraphQLDocument.mergedPullRequestSearchProbeQuery, variables: [
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
        let page: MergedPullRequestSearchPageData = try await sendGraphQLQuery(GitHubGraphQLDocument.mergedPullRequestsMatchingSearchQuery, variables: variables)
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
        let response: MergedPullRequestByNumberData = try await sendGraphQLQuery(GitHubGraphQLDocument.mergedPullRequestByNumberQuery, variables: [
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
    // so a week shows the moment it closes (AGENTS.md, "Weekly Mode").
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
            let page: WeeklyEditionIssuesPageData = try await sendGraphQLQuery(GitHubGraphQLDocument.closedWeeklyEditionIssuesQuery, variables: variables)
            guard let issueConnection = page.feedRepository?.issues else {
                throw GitHubAPIError.responseUnreadable(operationName: Self.operationName(in: GitHubGraphQLDocument.closedWeeklyEditionIssuesQuery))
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
        let response: WeeklyEditionByNumberData = try await sendGraphQLQuery(GitHubGraphQLDocument.weeklyEditionByNumberQuery, variables: [
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
        let response: AddPullRequestCommentData = try await sendGraphQLQuery(GitHubGraphQLDocument.addPullRequestCommentMutation, variables: [
            "subjectID": subjectID,
            "body": bodyMarkdown,
        ])
        guard let commentNode = response.addComment?.commentEdge?.node else {
            throw GitHubAPIError.responseUnreadable(operationName: Self.operationName(in: GitHubGraphQLDocument.addPullRequestCommentMutation))
        }
        return PullRequestComment(node: commentNode)
    }

    func deleteComment(id commentID: String) async throws {
        let _: IgnoredGraphQLData = try await sendGraphQLQuery(GitHubGraphQLDocument.deletePullRequestCommentMutation, variables: ["commentID": commentID])
    }

    func addReaction(_ reaction: GitHubReaction, toSubjectID subjectID: String) async throws {
        let _: IgnoredGraphQLData = try await sendGraphQLQuery(GitHubGraphQLDocument.addReactionMutation, variables: [
            "subjectID": subjectID,
            "content": reaction.rawValue,
        ])
    }

    func removeReaction(_ reaction: GitHubReaction, fromSubjectID subjectID: String) async throws {
        let _: IgnoredGraphQLData = try await sendGraphQLQuery(GitHubGraphQLDocument.removeReactionMutation, variables: [
            "subjectID": subjectID,
            "content": reaction.rawValue,
        ])
    }

    private func everyComment(ofSubjectID subjectID: String, firstPage: IssueCommentConnectionNode) async throws -> [(comment: PullRequestComment, bodyHTML: String)] {
        var commentNodes = firstPage.nodes.compactMap { $0 }
        var commentsPageInfo = firstPage.pageInfo
        while commentsPageInfo.hasNextPage, let endCursor = commentsPageInfo.endCursor {
            let page: CommentsPageData = try await sendGraphQLQuery(GitHubGraphQLDocument.commentsPageQuery, variables: [
                "subjectID": subjectID,
                "after": endCursor,
            ])
            guard let commentConnection = page.node?.comments else {
                throw GitHubAPIError.responseUnreadable(operationName: Self.operationName(in: GitHubGraphQLDocument.commentsPageQuery))
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

    static func makeJSONDecoder() -> JSONDecoder {
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
}
