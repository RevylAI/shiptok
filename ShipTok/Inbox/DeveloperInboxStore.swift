import Foundation
import Observation

struct DeveloperInboxItem: Identifiable, Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case vibe(PullRequestVibe, feedbackText: String)
        case comment(bodyMarkdown: String)
        case reaction(GitHubReaction)
    }

    let id: String
    let actor: GitHubActor?
    let action: Action
    let occurredAt: Date
    let pullRequestNumber: Int
    let pullRequestTitle: String
}

@Observable
@MainActor
final class DeveloperInboxStore {
    private static let refreshIntervalSeconds = 15
    private static let viewerMergedPullRequestActivityQuery = """
    query DeveloperInboxViewerMergedPullRequestActivity($searchQuery: String!) {
      search(query: $searchQuery, type: ISSUE, first: 20) {
        nodes {
          ... on PullRequest {
            number
            title
            reactions(last: 20) {
              nodes { id content createdAt user { login avatarUrl } }
            }
            comments(last: 20) {
              nodes { id body createdAt url viewerCanDelete author { __typename login avatarUrl } }
            }
          }
        }
      }
    }
    """

    private var fetchedInboxItems: [DeveloperInboxItem] = []
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    private(set) var lastSeenOccurredAt: Date
    private let viewer: GitHubUserIdentity
    private let githubAPIClient: GitHubAPIClient
    private let hiddenPeopleStore: HiddenPeopleStore
    private let lastSeenOccurredAtDefaultsKey: String

    init(viewer: GitHubUserIdentity, githubAPIClient: GitHubAPIClient, hiddenPeopleStore: HiddenPeopleStore) {
        self.viewer = viewer
        self.githubAPIClient = githubAPIClient
        self.hiddenPeopleStore = hiddenPeopleStore
        lastSeenOccurredAtDefaultsKey = "developer-inbox-last-seen-occurred-at-github-\(viewer.githubUserID)-\(githubAPIClient.repositoryFullName.lowercased())"
        lastSeenOccurredAt = UserDefaults.standard.object(forKey: lastSeenOccurredAtDefaultsKey) as? Date ?? .distantPast
    }

    // People the viewer hid never reach the inbox (shiptok/AGENTS.md, "Report And Hide").
    var inboxItems: [DeveloperInboxItem] {
        fetchedInboxItems.filter { !hiddenPeopleStore.isHidden($0.actor) }
    }

    var unseenItemCount: Int {
        inboxItems.filter { $0.occurredAt > lastSeenOccurredAt }.count
    }

    func refresh() async {
        do {
            let activityResponse: ViewerMergedPullRequestActivityResponse = try await githubAPIClient.sendGraphQLQuery(
                Self.viewerMergedPullRequestActivityQuery,
                variables: ["searchQuery": "repo:\(githubAPIClient.repositoryFullName) is:pr is:merged author:\(viewer.githubLogin) sort:updated-desc"]
            )
            let fetchedItems = activityResponse.search.nodes
                .compactMap { $0 }
                .flatMap(inboxItemsFromOtherPeople(on:))
                .sorted { $0.occurredAt > $1.occurredAt }
            if fetchedItems != fetchedInboxItems {
                fetchedInboxItems = fetchedItems
            }
            errorMessage = nil
            hasLoaded = true
        } catch {
            if Task.isCancelled { return }
            errorMessage = error.localizedDescription
        }
    }

    func runLiveRefreshLoop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(Self.refreshIntervalSeconds))
        }
    }

    func markAllItemsSeen() {
        guard let newestOccurredAt = inboxItems.map(\.occurredAt).max(), newestOccurredAt > lastSeenOccurredAt else { return }
        lastSeenOccurredAt = newestOccurredAt
        UserDefaults.standard.set(newestOccurredAt, forKey: lastSeenOccurredAtDefaultsKey)
    }

    private func inboxItemsFromOtherPeople(on pullRequestNode: ViewerMergedPullRequestActivityResponse.PullRequestNode) -> [DeveloperInboxItem] {
        let commentItems = pullRequestNode.comments.nodes.compactMap { $0 }.compactMap { commentNode -> DeveloperInboxItem? in
            let comment = PullRequestComment(
                id: commentNode.id,
                author: commentNode.author.map { GitHubActor(login: $0.login, avatarURL: $0.avatarUrl, isBot: $0.typename == "Bot") },
                bodyMarkdown: commentNode.body,
                createdAt: commentNode.createdAt,
                url: commentNode.url,
                viewerCanDelete: commentNode.viewerCanDelete,
                reactions: GitHubReactionSummary(countsByReaction: [:], viewerReactions: [])
            )
            guard comment.isWrittenByPerson, comment.author?.hasLogin(viewer.githubLogin) != true else { return nil }
            let action: DeveloperInboxItem.Action = PullRequestVibeComment(comment: comment)
                .map { .vibe($0.vibe, feedbackText: $0.feedbackText) } ?? .comment(bodyMarkdown: comment.bodyMarkdown)
            return DeveloperInboxItem(
                id: comment.id,
                actor: comment.author,
                action: action,
                occurredAt: comment.createdAt,
                pullRequestNumber: pullRequestNode.number,
                pullRequestTitle: pullRequestNode.title
            )
        }
        let reactionItems = pullRequestNode.reactions.nodes.compactMap { $0 }.compactMap { reactionNode -> DeveloperInboxItem? in
            guard let reactorNode = reactionNode.user, let reaction = GitHubReaction(rawValue: reactionNode.content) else { return nil }
            let reactor = GitHubActor(login: reactorNode.login, avatarURL: reactorNode.avatarUrl, isBot: reactorNode.login.hasSuffix("[bot]"))
            guard !reactor.isBot, !reactor.hasLogin(viewer.githubLogin) else { return nil }
            return DeveloperInboxItem(
                id: reactionNode.id,
                actor: reactor,
                action: .reaction(reaction),
                occurredAt: reactionNode.createdAt,
                pullRequestNumber: pullRequestNode.number,
                pullRequestTitle: pullRequestNode.title
            )
        }
        return commentItems + reactionItems
    }
}

private struct ViewerMergedPullRequestActivityResponse: Decodable {
    let search: Search

    // GitHub returns null for a node it can't resolve, such as a comment deleted while the query ran.
    struct Search: Decodable {
        let nodes: [PullRequestNode?]
    }

    struct PullRequestNode: Decodable {
        let number: Int
        let title: String
        let reactions: Connection<ReactionNode>
        let comments: Connection<CommentNode>
    }

    struct Connection<Node: Decodable>: Decodable {
        let nodes: [Node?]
    }

    struct ReactionNode: Decodable {
        let id: String
        let content: String
        let createdAt: Date
        let user: ActorNode?
    }

    struct CommentNode: Decodable {
        let id: String
        let body: String
        let createdAt: Date
        let url: URL
        let viewerCanDelete: Bool
        let author: ActorNode?
    }

    struct ActorNode: Decodable {
        let typename: String?
        let login: String
        let avatarUrl: URL?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case login
            case avatarUrl
        }
    }
}
