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
    // A merged page's window is the widest of these spans back from where the last one began that holds at most the target count, or everything older when that fits (AGENTS.md, "Feed Order").
    private static let mergedPullRequestWindowCandidateSpansHours: [TimeInterval] = [6, 24, 72, 168, 336, 720, 2160, 8760]
    private static let mergedPullRequestWindowTargetCount = 50
    private static let pullRequestsByIDBatchCount = 25
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
            // A pull request number the repository doesn't hold, or an id GitHub no longer has, reads as null beside this error, so a read by number or id can say it isn't there.
            if graphQLErrors.allSatisfy({ $0.type == "NOT_FOUND" && ($0.path == ["feedRepository", "pullRequest"] || $0.path.first == "nodes") }),
               let responseData = responseEnvelope.data {
                return responseData
            }
            Self.logger.error("GitHub refused \(operationName, privacy: .public): \(graphQLErrors.compactMap(\.type).joined(separator: ","), privacy: .public)")
            throw GitHubAPIError.graphQLErrors(operationName: operationName, messages: graphQLErrors.map(\.message))
        }
        guard let responseData = responseEnvelope.data else {
            throw GitHubAPIError.responseUnreadable(operationName: operationName)
        }
        return responseData
    }

    // Every merged pull request in a merge-date range, updated since a date if one is given, read in full; each page arrives as it loads (AGENTS.md, "Feed Order").
    func searchMergedPullRequests(
        updatedSince earliestUpdateDate: Date?,
        mergedFrom earliestMergeDate: Date?,
        mergedThrough latestMergeDate: Date
    ) async throws -> AsyncThrowingStream<[PullRequest], Error> {
        if case .demoFeed(let demoFeed) = source {
            // The demo feed carries no update dates, so it answers with every pull request in the merge range, and applying an unchanged one again changes nothing.
            var mergedPullRequests: [PullRequest] = []
            for pullRequestNode in try await demoFeed.snapshot().mergedPullRequests {
                guard let mergedAt = pullRequestNode.mergedAt,
                      earliestMergeDate.map({ mergedAt >= $0 }) ?? true,
                      mergedAt <= latestMergeDate
                else { continue }
                mergedPullRequests.append(try await pullRequest(from: pullRequestNode))
            }
            return AsyncThrowingStream { continuation in
                continuation.yield(mergedPullRequests)
                continuation.finish()
            }
        }
        let searchRanges = try await mergedPullRequestSearchRanges(
            updatedSince: earliestUpdateDate,
            mergedFrom: earliestMergeDate,
            mergedThrough: latestMergeDate
        )
        return AsyncThrowingStream<[PullRequest], Error> { continuation in
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

    // The newest merge-date window ending before a date that holds at most about 50 merged pull requests, the widest that does, read whole. Its start is where the next window ends, and nil once nothing older is left (AGENTS.md, "Feed Order").
    func fetchMergedPullRequestWindow(mergedBefore windowEndDate: Date) async throws -> MergedPullRequestWindow {
        let latestMergeDate = windowEndDate.addingTimeInterval(-1)
        if case .demoFeed(let demoFeed) = source {
            var mergedPullRequests: [PullRequest] = []
            for pullRequestNode in try await demoFeed.snapshot().mergedPullRequests {
                guard let mergedAt = pullRequestNode.mergedAt, mergedAt <= latestMergeDate else { continue }
                mergedPullRequests.append(try await pullRequest(from: pullRequestNode))
            }
            return MergedPullRequestWindow(pullRequests: mergedPullRequests, startDate: nil)
        }
        let candidateStartDates: [Date?] = Self.mergedPullRequestWindowCandidateSpansHours.map { windowEndDate.addingTimeInterval(-$0 * 60 * 60) } + [nil]
        let candidateSearchQueries = candidateStartDates.map { candidateStartDate in
            mergedPullRequestSearchQuery(updatedSince: nil, mergedFrom: candidateStartDate, mergedThrough: latestMergeDate)
        }
        let countsQuery = GitHubGraphQLDocument.mergedPullRequestCountsQuery(searchQueryCount: candidateSearchQueries.count)
        let countsByAlias: [String: IssueCountNode] = try await sendGraphQLQuery(
            countsQuery,
            variables: Dictionary(uniqueKeysWithValues: candidateSearchQueries.enumerated().map { ("searchQuery\($0.offset)", $0.element as any Sendable) })
        )
        let candidateCounts = try candidateSearchQueries.indices.map { candidateIndex in
            guard let issueCount = countsByAlias["count\(candidateIndex)"]?.issueCount else {
                throw GitHubAPIError.responseUnreadable(operationName: Self.operationName(in: countsQuery))
            }
            return issueCount
        }
        let windowIndex = candidateCounts.indices.last { candidateCounts[$0] <= Self.mergedPullRequestWindowTargetCount } ?? 0
        let windowStartDate = candidateStartDates[windowIndex]
        guard candidateCounts[windowIndex] > 0 else {
            return MergedPullRequestWindow(pullRequests: [], startDate: windowStartDate)
        }
        guard candidateCounts[windowIndex] > Self.mergedPullRequestSearchRangeMaximumResultCount else {
            return MergedPullRequestWindow(pullRequests: try await everyMergedPullRequest(matchingSearchQuery: candidateSearchQueries[windowIndex]), startDate: windowStartDate)
        }
        var mergedPullRequests: [PullRequest] = []
        for try await mergedPullRequestPage in try await searchMergedPullRequests(updatedSince: nil, mergedFrom: windowStartDate, mergedThrough: latestMergeDate) {
            mergedPullRequests += mergedPullRequestPage
        }
        return MergedPullRequestWindow(pullRequests: mergedPullRequests, startDate: windowStartDate)
    }

    private func mergedPullRequestSearchQuery(updatedSince earliestUpdateDate: Date?, mergedFrom earliestMergeDate: Date?, mergedThrough latestMergeDate: Date) -> String {
        let mergedRangeText = earliestMergeDate.map { "\($0.formatted(.iso8601))..\(latestMergeDate.formatted(.iso8601))" } ?? "<=\(latestMergeDate.formatted(.iso8601))"
        let updatedQualifier = earliestUpdateDate.map { " updated:>=\($0.formatted(.iso8601))" } ?? ""
        return "\(mergedPullRequestSearchQualifiers) merged:\(mergedRangeText)\(updatedQualifier) sort:updated-desc"
    }

    // GitHub search returns at most 1,000 results, so a merge-date range is halved at whole seconds until each part is small, which also lets the parts load in parallel; a part one second long can't be halved, so it's paged whole. A pull request's merge date never changes, so paging through a part never skips one that wasn't updated meanwhile, and one that was is read by the next search.
    private func mergedPullRequestSearchRanges(
        updatedSince earliestUpdateDate: Date?,
        mergedFrom earliestMergeDate: Date?,
        mergedThrough latestMergeDate: Date
    ) async throws -> [String] {
        let searchQuery = mergedPullRequestSearchQuery(updatedSince: earliestUpdateDate, mergedFrom: earliestMergeDate, mergedThrough: latestMergeDate)
        let probe: MergedPullRequestSearchProbeData = try await sendGraphQLQuery(GitHubGraphQLDocument.mergedPullRequestSearchProbeQuery, variables: [
            "owner": repositoryOwnerLogin,
            "name": repositoryName,
            "searchQuery": searchQuery,
        ])
        let matchingPullRequestCount = probe.search.issueCount
        let rangeStartSecond = (earliestMergeDate ?? probe.feedRepository.createdAt).timeIntervalSince1970.rounded(.down)
        let latestMergeSecond = latestMergeDate.timeIntervalSince1970.rounded(.down)
        guard matchingPullRequestCount > Self.mergedPullRequestSearchRangeMaximumResultCount, latestMergeSecond > rangeStartSecond else {
            return matchingPullRequestCount > 0 ? [searchQuery] : []
        }
        let rangeStartDate = Date(timeIntervalSince1970: rangeStartSecond)
        let rangeMidpointDate = Date(timeIntervalSince1970: ((rangeStartSecond + latestMergeSecond) / 2).rounded(.down))
        async let newerHalfSearchRanges = mergedPullRequestSearchRanges(
            updatedSince: earliestUpdateDate,
            mergedFrom: rangeMidpointDate.addingTimeInterval(1),
            mergedThrough: latestMergeDate
        )
        let olderHalfSearchRanges = try await mergedPullRequestSearchRanges(
            updatedSince: earliestUpdateDate,
            mergedFrom: rangeStartDate,
            mergedThrough: rangeMidpointDate
        )
        return try await newerHalfSearchRanges + olderHalfSearchRanges
    }

    private func everyMergedPullRequest(matchingSearchQuery searchQuery: String) async throws -> [PullRequest] {
        var mergedPullRequests: [PullRequest] = []
        var pageCursor: String?
        repeat {
            let page = try await fetchMergedPullRequestSearchPage(matchingSearchQuery: searchQuery, after: pageCursor)
            mergedPullRequests += page.mergedPullRequests
            pageCursor = page.nextPageCursor
        } while pageCursor != nil
        return mergedPullRequests
    }

    private func yieldMergedPullRequestPages(
        matchingSearchQuery searchQuery: String,
        to continuation: AsyncThrowingStream<[PullRequest], Error>.Continuation
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
    ) async throws -> (mergedPullRequests: [PullRequest], nextPageCursor: String?) {
        var variables: [String: any Sendable] = ["searchQuery": searchQuery]
        if let pageCursor {
            variables["after"] = pageCursor
        }
        let page: MergedPullRequestSearchPageData = try await sendGraphQLQuery(GitHubGraphQLDocument.mergedPullRequestsMatchingSearchQuery, variables: variables)
        var mergedPullRequests: [PullRequest] = []
        for pullRequestNode in page.search.nodes.compactMap({ $0 }) {
            guard pullRequestNode.mergedAt != nil else { continue }
            mergedPullRequests.append(try await pullRequest(from: pullRequestNode))
        }
        return (mergedPullRequests, page.search.pageInfo.hasNextPage ? page.search.pageInfo.endCursor : nil)
    }

    // A page of open pull requests, newest update first, through the repository's pull request list rather than search (AGENTS.md, "Feed Order").
    func fetchOpenPullRequestsPage(after pageCursor: String?) async throws -> OpenPullRequestsPage {
        if case .demoFeed(let demoFeed) = source {
            var openPullRequests: [PullRequest] = []
            for pullRequestNode in try await demoFeed.snapshot().openPullRequests where !Self.isClosedWithoutMerging(pullRequestNode) {
                openPullRequests.append(try await pullRequest(from: pullRequestNode))
            }
            return OpenPullRequestsPage(pullRequests: openPullRequests.sorted { $0.comesBefore($1, in: .open) }, nextPageCursor: nil)
        }
        var variables: [String: any Sendable] = ["owner": repositoryOwnerLogin, "name": repositoryName]
        if let pageCursor {
            variables["after"] = pageCursor
        }
        let page: OpenPullRequestsPageData = try await sendGraphQLQuery(GitHubGraphQLDocument.openPullRequestsPageQuery, variables: variables)
        guard let pullRequestConnection = page.feedRepository?.pullRequests else {
            throw GitHubAPIError.responseUnreadable(operationName: Self.operationName(in: GitHubGraphQLDocument.openPullRequestsPageQuery))
        }
        var openPullRequests: [PullRequest] = []
        for pullRequestNode in pullRequestConnection.nodes.compactMap({ $0 }) {
            openPullRequests.append(try await pullRequest(from: pullRequestNode))
        }
        return OpenPullRequestsPage(
            pullRequests: openPullRequests,
            nextPageCursor: pullRequestConnection.pageInfo.hasNextPage ? pullRequestConnection.pageInfo.endCursor : nil
        )
    }

    // The ids of the pull requests in these states updated since a date, newest update first. Only ids, so a refresh reads in full only what changed (AGENTS.md, "Feed Order").
    func fetchIDsOfPullRequestsUpdated(since earliestUpdateDate: Date, inStates pullRequestStates: [GitHubPullRequestState]) async throws -> [String] {
        if case .demoFeed(let demoFeed) = source {
            // The demo feed may carry no update dates, so it answers with every pull request in those states.
            let snapshot = try await demoFeed.snapshot()
            let openPullRequestNodes = pullRequestStates.contains(.open) ? snapshot.openPullRequests : []
            let mergedPullRequestNodes = pullRequestStates.contains(.merged) ? snapshot.mergedPullRequests : []
            return (openPullRequestNodes + mergedPullRequestNodes).map(\.id)
        }
        var updatedPullRequestIDs: [String] = []
        var pageCursor: String?
        repeat {
            var variables: [String: any Sendable] = [
                "owner": repositoryOwnerLogin,
                "name": repositoryName,
                "states": pullRequestStates.map(\.rawValue),
            ]
            if let pageCursor {
                variables["after"] = pageCursor
            }
            let page: PullRequestUpdatesPageData = try await sendGraphQLQuery(GitHubGraphQLDocument.pullRequestUpdatesQuery, variables: variables)
            guard let pullRequestConnection = page.feedRepository?.pullRequests else {
                throw GitHubAPIError.responseUnreadable(operationName: Self.operationName(in: GitHubGraphQLDocument.pullRequestUpdatesQuery))
            }
            for updatedPullRequestNode in pullRequestConnection.nodes.compactMap({ $0 }) {
                guard updatedPullRequestNode.updatedAt >= earliestUpdateDate else { return updatedPullRequestIDs }
                updatedPullRequestIDs.append(updatedPullRequestNode.id)
            }
            pageCursor = pullRequestConnection.pageInfo.hasNextPage ? pullRequestConnection.pageInfo.endCursor : nil
        } while pageCursor != nil
        return updatedPullRequestIDs
    }

    // Open and merged pull requests read by id, a few at a time; one closed without merging or gone is left out.
    func fetchPullRequests(ids pullRequestIDs: [String]) async throws -> [PullRequest] {
        if case .demoFeed(let demoFeed) = source {
            let snapshot = try await demoFeed.snapshot()
            let requestedPullRequestIDs = Set(pullRequestIDs)
            var pullRequests: [PullRequest] = []
            for pullRequestNode in snapshot.openPullRequests + snapshot.mergedPullRequests
            where requestedPullRequestIDs.contains(pullRequestNode.id) && !Self.isClosedWithoutMerging(pullRequestNode) {
                pullRequests.append(try await pullRequest(from: pullRequestNode))
            }
            return pullRequests
        }
        var pullRequests: [PullRequest] = []
        for batchStartIndex in stride(from: 0, to: pullRequestIDs.count, by: Self.pullRequestsByIDBatchCount) {
            let pullRequestIDBatch = Array(pullRequestIDs[batchStartIndex..<min(batchStartIndex + Self.pullRequestsByIDBatchCount, pullRequestIDs.count)])
            let response: PullRequestsByIDData = try await sendGraphQLQuery(GitHubGraphQLDocument.pullRequestsByIDQuery, variables: ["ids": pullRequestIDBatch])
            for pullRequestNode in response.nodes.compactMap({ $0 }) where !Self.isClosedWithoutMerging(pullRequestNode) {
                pullRequests.append(try await pullRequest(from: pullRequestNode))
            }
        }
        return pullRequests
    }

    func fetchPullRequest(number: Int) async throws -> PullRequest {
        if case .demoFeed(let demoFeed) = source {
            let snapshot = try await demoFeed.snapshot()
            guard let pullRequestNode = (snapshot.mergedPullRequests + snapshot.openPullRequests).first(where: { $0.number == number }),
                  !Self.isClosedWithoutMerging(pullRequestNode)
            else {
                throw GitHubAPIError.pullRequestNeitherOpenNorMerged(number: number)
            }
            return try await pullRequest(from: pullRequestNode)
        }
        let response: PullRequestByNumberData = try await sendGraphQLQuery(GitHubGraphQLDocument.pullRequestByNumberQuery, variables: [
            "owner": repositoryOwnerLogin,
            "name": repositoryName,
            "number": number,
        ])
        guard let pullRequestNode = response.feedRepository?.pullRequest, !Self.isClosedWithoutMerging(pullRequestNode) else {
            throw GitHubAPIError.pullRequestNeitherOpenNorMerged(number: number)
        }
        return try await pullRequest(from: pullRequestNode)
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

    // A pull request closed without merging is neither open nor merged, so ShipTok never shows it (docs/shiptok-format.md).
    private static func isClosedWithoutMerging(_ pullRequestNode: PullRequestNode) -> Bool {
        pullRequestNode.mergedAt == nil && pullRequestNode.state == "CLOSED"
    }

    private func pullRequest(from pullRequestNode: PullRequestNode) async throws -> PullRequest {
        let commentsWithBodyHTML = try await everyComment(ofSubjectID: pullRequestNode.id, firstPage: pullRequestNode.comments)
        let author = pullRequestNode.author.map(GitHubActor.init(node:))
        let labels = try (pullRequestNode.labels?.nodes ?? []).compactMap { $0 }.map { labelNode in
            guard let rgbHex = UInt32(labelNode.color, radix: 16) else {
                throw GitHubAPIError.responseUnreadable(operationName: "ShipTokPullRequestFields")
            }
            return GitHubLabel(name: labelNode.name, rgbHex: rgbHex)
        }
        return PullRequest(
            id: pullRequestNode.id,
            number: pullRequestNode.number,
            title: pullRequestNode.title,
            url: pullRequestNode.url,
            author: author,
            isDraft: pullRequestNode.isDraft ?? false,
            updatedAt: pullRequestNode.updatedAt ?? pullRequestNode.createdAt,
            mergedAt: pullRequestNode.mergedAt,
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

struct MergedPullRequestWindow: Sendable {
    let pullRequests: [PullRequest]
    // Nil once the window reaches back past the repository's first merged pull request.
    let startDate: Date?
}

struct OpenPullRequestsPage: Sendable {
    let pullRequests: [PullRequest]
    // Nil once this page is the last.
    let nextPageCursor: String?
}

enum GitHubPullRequestState: String, Sendable {
    case open = "OPEN"
    case closed = "CLOSED"
    case merged = "MERGED"
}
