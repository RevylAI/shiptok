import Foundation

// What someone signed in to Revyl sees until they connect GitHub: one public repository's open and merged pull requests, weekly videos and feature videos, which Revyl's backend reads with its GitHub App
// (AGENTS.md, "Demo Mode"). GitHub signs the media links in it for only minutes, so a snapshot is reused only briefly before it's read again.
actor ShipTokDemoFeed {
    private static let freshnessSeconds: TimeInterval = 15
    private let shipTokAPI = RevylShipTokAPI()
    private var heldSnapshot: (snapshot: DemoFeedSnapshot, readAt: Date)?
    private var snapshotRead: Task<DemoFeedSnapshot, any Error>?

    func repositoryFullName() async throws -> String {
        try await snapshot().repositoryFullName
    }

    func snapshot() async throws -> DemoFeedSnapshot {
        if let heldSnapshot, Date.now.timeIntervalSince(heldSnapshot.readAt) < Self.freshnessSeconds {
            return heldSnapshot.snapshot
        }
        if let snapshotRead {
            return try await snapshotRead.value
        }
        let read = Task { [shipTokAPI] in
            let snapshotData = try await shipTokAPI.fetchDemoFeed()
            let snapshot: DemoFeedSnapshot
            do {
                snapshot = try GitHubAPIClient.makeJSONDecoder().decode(DemoFeedSnapshot.self, from: snapshotData)
            } catch {
                throw RevylShipTokAPIError.responseUnreadable(operationName: "the demo")
            }
            // GitHubAPIClient reads the repository as owner/name.
            guard snapshot.repositoryFullName.split(separator: "/").count == 2 else {
                throw RevylShipTokAPIError.responseUnreadable(operationName: "the demo")
            }
            return snapshot
        }
        snapshotRead = read
        defer { snapshotRead = nil }
        let snapshot = try await read.value
        heldSnapshot = (snapshot, .now)
        return snapshot
    }
}

struct DemoFeedSnapshot: Decodable {
    let repositoryFullName: String
    let openPullRequests: [PullRequestNode]
    let mergedPullRequests: [PullRequestNode]
    let weeklyEditionIssues: [IssueNode]
    let featureIssues: [IssueNode]

    enum CodingKeys: String, CodingKey {
        case repositoryFullName = "repository_full_name"
        case openPullRequests = "open_pull_requests"
        case mergedPullRequests = "merged_pull_requests"
        case weeklyEditionIssues = "weekly_edition_issues"
        case featureIssues = "feature_issues"
    }

    // A demo feed without open pull requests leaves the demo's Open mode empty, and one without features, as from a backend older than Features, leaves its Features mode empty (AGENTS.md, "Demo Mode").
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repositoryFullName = try container.decode(String.self, forKey: .repositoryFullName)
        openPullRequests = try container.decodeIfPresent([PullRequestNode].self, forKey: .openPullRequests) ?? []
        mergedPullRequests = try container.decode([PullRequestNode].self, forKey: .mergedPullRequests)
        weeklyEditionIssues = try container.decode([IssueNode].self, forKey: .weeklyEditionIssues)
        featureIssues = try container.decodeIfPresent([IssueNode].self, forKey: .featureIssues) ?? []
    }
}
