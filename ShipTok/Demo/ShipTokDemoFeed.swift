import Foundation

// What someone sees before signing in: one public repository's merged pull requests and weekly videos, which Revyl's backend reads with its GitHub App
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

struct DemoFeedSnapshot: Decodable {
    let repositoryFullName: String
    let mergedPullRequests: [PullRequestNode]
    let weeklyEditionIssues: [WeeklyEditionNode]

    enum CodingKeys: String, CodingKey {
        case repositoryFullName = "repository_full_name"
        case mergedPullRequests = "merged_pull_requests"
        case weeklyEditionIssues = "weekly_edition_issues"
    }
}
