import CryptoKit
import Foundation
import OSLog

struct SavedPullRequestFeeds: Codable, Sendable {
    static let currentFormatVersion = 7
    let formatVersion: Int
    let viewerGitHubLogin: String
    let repositoryFullName: String
    let mergedFeed: SavedMergedPullRequestFeed?
    let openFeed: SavedOpenPullRequestFeed?
}

struct SavedMergedPullRequestFeed: Codable, Sendable {
    let everyUpdateAppliedBefore: Date
    // Nil once the feed holds every merged pull request.
    let everyMergedPullRequestLoadedSince: Date?
    let pullRequests: [PullRequest]
}

struct SavedOpenPullRequestFeed: Codable, Sendable {
    let everyUpdateAppliedBefore: Date
    // Nil once the feed holds every open pull request.
    let nextPageCursor: String?
    let pullRequests: [PullRequest]
}

// The Open and Merged feeds, each with the moment every update before it was applied and where its next older page starts, saved on the device so a launch opens on them at once and asks GitHub only for what changed since (AGENTS.md, "Feed Caching").
actor PullRequestFeedCache {
    static let savedFeedsDirectoryURL = URL.cachesDirectory.appending(path: "pull-request-feeds", directoryHint: .isDirectory)
    // Where saved feeds were kept before the Open feed existed; whatever is left there is of no use.
    static let replacedSavedFeedsDirectoryURL = URL.cachesDirectory.appending(path: "merged-pull-request-feeds", directoryHint: .isDirectory)
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "feed")
    private var newestSavedFeedsGeneration = 0

    // Launch clears them, so they go for every viewer, whether or not a feed ever opens again.
    static func removeReplacedSavedFeedsInBackground() {
        Task.detached(priority: .background) {
            do {
                try FileManager.default.removeItem(at: Self.replacedSavedFeedsDirectoryURL)
            } catch CocoaError.fileNoSuchFile {
                return
            } catch {
                logger.error("Deleting the saved feeds of an earlier format failed: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    func loadSavedFeeds(viewerGitHubLogin: String, repositoryFullName: String) -> SavedPullRequestFeeds? {
        // Feeds saved in another format can't be read for any login, so they go.
        let savedFeedsFileURLs = (try? FileManager.default.contentsOfDirectory(at: Self.savedFeedsDirectoryURL, includingPropertiesForKeys: nil)) ?? []
        for savedFeedsFileURL in savedFeedsFileURLs {
            let savedFeeds = (try? Data(contentsOf: savedFeedsFileURL)).flatMap { try? JSONDecoder().decode(SavedPullRequestFeeds.self, from: $0) }
            if savedFeeds?.formatVersion != SavedPullRequestFeeds.currentFormatVersion {
                try? FileManager.default.removeItem(at: savedFeedsFileURL)
            }
        }
        let savedFeedsFileURL = Self.savedFeedsFileURL(viewerGitHubLogin: viewerGitHubLogin, repositoryFullName: repositoryFullName)
        guard FileManager.default.fileExists(atPath: savedFeedsFileURL.path(percentEncoded: false)) else { return nil }
        let savedFeeds: SavedPullRequestFeeds
        do {
            savedFeeds = try JSONDecoder().decode(SavedPullRequestFeeds.self, from: Data(contentsOf: savedFeedsFileURL))
        } catch {
            Self.logger.error("The saved feeds couldn't be read, so they're read again from GitHub: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
        guard savedFeeds.formatVersion == SavedPullRequestFeeds.currentFormatVersion,
              savedFeeds.viewerGitHubLogin.caseInsensitiveCompare(viewerGitHubLogin) == .orderedSame,
              savedFeeds.repositoryFullName.caseInsensitiveCompare(repositoryFullName) == .orderedSame
        else { return nil }
        return savedFeeds
    }

    // Saves arrive from separate tasks, so an older snapshot that lands after a newer one is skipped, and a save the ended sign-in cancelled writes nothing.
    func save(_ feeds: SavedPullRequestFeeds, generation: Int) {
        guard !Task.isCancelled, generation > newestSavedFeedsGeneration else { return }
        newestSavedFeedsGeneration = generation
        do {
            let savedFeedsFileURL = Self.savedFeedsFileURL(viewerGitHubLogin: feeds.viewerGitHubLogin, repositoryFullName: feeds.repositoryFullName)
            try FileManager.default.createDirectory(at: Self.savedFeedsDirectoryURL, withIntermediateDirectories: true)
            try JSONEncoder().encode(feeds).write(to: savedFeedsFileURL, options: .atomic)
        } catch {
            Self.logger.error("Saving the feeds failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private static func savedFeedsFileURL(viewerGitHubLogin: String, repositoryFullName: String) -> URL {
        let cacheIdentity = "\(repositoryFullName.lowercased())|\(viewerGitHubLogin.lowercased())"
        let fileName = SHA256.hash(data: Data(cacheIdentity.utf8)).map { String(format: "%02x", $0) }.joined()
        return savedFeedsDirectoryURL.appending(path: "\(fileName).json")
    }
}
