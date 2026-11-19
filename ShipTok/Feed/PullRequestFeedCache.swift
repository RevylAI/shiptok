import CryptoKit
import Foundation
import OSLog

struct SavedMergedPullRequestFeed: Codable, Sendable {
    static let currentFormatVersion = 6
    let formatVersion: Int
    let viewerGitHubLogin: String
    let repositoryFullName: String
    let everyUpdateAppliedBefore: Date
    let pullRequests: [PullRequest]
}

// The feed and the moment every update before it was applied, saved on the device so a launch opens on it at once and asks GitHub only for what changed since (AGENTS.md, "Feed Caching").
actor PullRequestFeedCache {
    static let savedFeedsDirectoryURL = URL.cachesDirectory.appending(path: "merged-pull-request-feeds", directoryHint: .isDirectory)
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "feed")
    private var newestSavedFeedGeneration = 0

    // A feed saved for another GitHub login or before the window began is of no use, since its updates would take longer to read than the window itself.
    func loadSavedFeed(viewerGitHubLogin: String, repositoryFullName: String, appliedSince earliestUsefulDate: Date) -> SavedMergedPullRequestFeed? {
        // A feed saved in another format can't be read for any login, so it goes.
        let savedFeedFileURLs = (try? FileManager.default.contentsOfDirectory(at: Self.savedFeedsDirectoryURL, includingPropertiesForKeys: nil)) ?? []
        for savedFeedFileURL in savedFeedFileURLs {
            let savedFeed = (try? Data(contentsOf: savedFeedFileURL)).flatMap { try? JSONDecoder().decode(SavedMergedPullRequestFeed.self, from: $0) }
            if savedFeed?.formatVersion != SavedMergedPullRequestFeed.currentFormatVersion {
                try? FileManager.default.removeItem(at: savedFeedFileURL)
            }
        }
        let savedFeedFileURL = Self.savedFeedFileURL(viewerGitHubLogin: viewerGitHubLogin, repositoryFullName: repositoryFullName)
        guard FileManager.default.fileExists(atPath: savedFeedFileURL.path(percentEncoded: false)) else { return nil }
        let savedFeed: SavedMergedPullRequestFeed
        do {
            savedFeed = try JSONDecoder().decode(SavedMergedPullRequestFeed.self, from: Data(contentsOf: savedFeedFileURL))
        } catch {
            Self.logger.error("The saved feed couldn't be read, so the window is read again: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
        guard savedFeed.formatVersion == SavedMergedPullRequestFeed.currentFormatVersion,
              savedFeed.viewerGitHubLogin.caseInsensitiveCompare(viewerGitHubLogin) == .orderedSame,
              savedFeed.repositoryFullName.caseInsensitiveCompare(repositoryFullName) == .orderedSame,
              savedFeed.everyUpdateAppliedBefore >= earliestUsefulDate
        else { return nil }
        return savedFeed
    }

    // Saves arrive from separate tasks, so an older snapshot that lands after a newer one is skipped.
    func save(_ feed: SavedMergedPullRequestFeed, generation: Int) {
        guard generation > newestSavedFeedGeneration else { return }
        newestSavedFeedGeneration = generation
        do {
            let savedFeedFileURL = Self.savedFeedFileURL(viewerGitHubLogin: feed.viewerGitHubLogin, repositoryFullName: feed.repositoryFullName)
            try FileManager.default.createDirectory(at: Self.savedFeedsDirectoryURL, withIntermediateDirectories: true)
            try JSONEncoder().encode(feed).write(to: savedFeedFileURL, options: .atomic)
        } catch {
            Self.logger.error("Saving the feed failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private static func savedFeedFileURL(viewerGitHubLogin: String, repositoryFullName: String) -> URL {
        let cacheIdentity = "\(repositoryFullName.lowercased())|\(viewerGitHubLogin.lowercased())"
        let fileName = SHA256.hash(data: Data(cacheIdentity.utf8)).map { String(format: "%02x", $0) }.joined()
        return savedFeedsDirectoryURL.appending(path: "\(fileName).json")
    }
}
