import Foundation
import OSLog

struct SavedPostFeedsContent: Codable, Sendable {
    let revylUserID: String
    let githubRepositoryID: Int64
    let feeds: [SavedPostFeed]
}

struct SavedPostFeed: Codable, Sendable {
    let feedMode: FeedMode
    // Nil once the feed holds every post.
    let nextCursor: String?
    // Whether Revyl left out what Videos only hides when it served these posts; nil when that wasn't known yet.
    let showsOnlyPostsWithVideos: Bool?
    let posts: [ShipTokPost]
}

// Each mode's feed for one Revyl account and repository, saved on the device so a launch opens on it at once and asks Revyl only for its newest page (AGENTS.md, "Feed Caching").
actor SavedPostFeeds {
    static let directoryURL = URL.cachesDirectory.appending(path: "post-feeds", directoryHint: .isDirectory)
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "feed")
    private var newestSavedGeneration = 0

    func load(revylUserID: String, githubRepositoryID: Int64) -> SavedPostFeedsContent? {
        let fileURL = Self.fileURL(revylUserID: revylUserID, githubRepositoryID: githubRepositoryID)
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return nil }
        do {
            let savedContent = try JSONDecoder().decode(SavedPostFeedsContent.self, from: Data(contentsOf: fileURL))
            guard savedContent.revylUserID == revylUserID, savedContent.githubRepositoryID == githubRepositoryID else { return nil }
            return savedContent
        } catch {
            Self.logger.error("The saved feeds couldn't be read, so they're read again from Revyl: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }

    // Saves arrive from separate tasks, so an older snapshot that lands after a newer one is skipped, and a save the ended sign-in cancelled writes nothing.
    func save(_ content: SavedPostFeedsContent, generation: Int) {
        guard !Task.isCancelled, generation > newestSavedGeneration else { return }
        newestSavedGeneration = generation
        do {
            try FileManager.default.createDirectory(at: Self.directoryURL, withIntermediateDirectories: true)
            try JSONEncoder().encode(content).write(to: Self.fileURL(revylUserID: content.revylUserID, githubRepositoryID: content.githubRepositoryID), options: .atomic)
        } catch {
            Self.logger.error("Saving the feeds failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private static func fileURL(revylUserID: String, githubRepositoryID: Int64) -> URL {
        directoryURL.appending(path: "revyl-user-\(revylUserID)-repository-\(githubRepositoryID).json")
    }
}
