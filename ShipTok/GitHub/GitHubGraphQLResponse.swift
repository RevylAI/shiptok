import Foundation

struct GraphQLResponseEnvelope<ResponseData: Decodable>: Decodable {
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

struct GraphQLError: Decodable {
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

struct IgnoredGraphQLData: Decodable {}

struct ActorNode: Decodable {
    let typeName: String
    let login: String
    let avatarUrl: URL?

    enum CodingKeys: String, CodingKey {
        case typeName = "__typename"
        case login
        case avatarUrl
    }
}

struct TotalCountNode: Decodable {
    let totalCount: Int
}

struct IssueCountNode: Decodable {
    let issueCount: Int
}

struct PageInfoNode: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
}

struct ReactionGroupNode: Decodable {
    let content: String
    let viewerHasReacted: Bool
    let reactors: TotalCountNode
}

struct IssueCommentNode: Decodable {
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

struct IssueCommentConnectionNode: Decodable {
    let pageInfo: PageInfoNode
    let nodes: [IssueCommentNode?]
}

struct PullRequestNode: Decodable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let state: String
    let isDraft: Bool
    let updatedAt: Date
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

struct LabelConnectionNode: Decodable {
    let nodes: [LabelNode?]
}

struct LabelNode: Decodable {
    let name: String
    let color: String
}

struct PullRequestConnectionNode: Decodable {
    let pageInfo: PageInfoNode
    let nodes: [PullRequestNode?]
}

struct MergedPullRequestSearchPageData: Decodable {
    let search: PullRequestConnectionNode
}

struct OpenPullRequestsPageData: Decodable {
    struct RepositoryNode: Decodable {
        let pullRequests: PullRequestConnectionNode
    }

    let feedRepository: RepositoryNode?
}

struct PullRequestUpdatesPageData: Decodable {
    struct UpdatedPullRequestNode: Decodable {
        let id: String
        let updatedAt: Date
        let mergedAt: Date?
    }

    struct UpdatedPullRequestConnectionNode: Decodable {
        let pageInfo: PageInfoNode
        let nodes: [UpdatedPullRequestNode?]
    }

    struct RepositoryNode: Decodable {
        let pullRequests: UpdatedPullRequestConnectionNode
    }

    let feedRepository: RepositoryNode?
}

struct PullRequestsByIDData: Decodable {
    let nodes: [PullRequestNode?]
}

struct PullRequestByNumberData: Decodable {
    struct RepositoryNode: Decodable {
        let pullRequest: PullRequestNode?
    }

    let feedRepository: RepositoryNode?
}

struct CommentsPageData: Decodable {
    struct CommentedNode: Decodable {
        let comments: IssueCommentConnectionNode?
    }

    let node: CommentedNode?
}

// An issue ShipTok may publish as a card, a weekly edition or a feature, as the issue queries return it.
struct IssueNode: Decodable {
    let id: String
    let number: Int
    let url: URL
    let state: String
    let labels: LabelConnectionNode
    let createdAt: Date
    let closedAt: Date?
    let lastEditedAt: Date?
    let body: String
    let bodyHTML: String
    let author: ActorNode?
    let reactionGroups: [ReactionGroupNode]?
    let comments: IssueCommentConnectionNode
}

struct ClosedIssuesWithLabelPageData: Decodable {
    struct IssueConnectionNode: Decodable {
        let pageInfo: PageInfoNode
        let nodes: [IssueNode?]
    }

    struct RepositoryNode: Decodable {
        let issues: IssueConnectionNode
    }

    let feedRepository: RepositoryNode?
}

struct IssueByNumberData: Decodable {
    struct RepositoryNode: Decodable {
        let issue: IssueNode?
    }

    let feedRepository: RepositoryNode?
}

struct MergedPullRequestSearchProbeData: Decodable {
    struct RepositoryNode: Decodable {
        let createdAt: Date
    }

    let feedRepository: RepositoryNode
    let search: IssueCountNode
}

struct AddPullRequestCommentData: Decodable {
    struct AddCommentPayload: Decodable {
        let commentEdge: CommentEdge?
    }

    struct CommentEdge: Decodable {
        let node: IssueCommentNode?
    }

    let addComment: AddCommentPayload?
}

extension GitHubActor {
    init(node: ActorNode) {
        self.init(login: node.login, avatarURL: node.avatarUrl, isBot: node.typeName == "Bot")
    }
}

extension GitHubReactionSummary {
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

extension PullRequestComment {
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
