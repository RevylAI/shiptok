import CryptoKit
import Foundation
import OSLog
import UniformTypeIdentifiers

// Media under one id never changes, so a video or image downloaded once plays from the device on later launches until it goes a month unused. Each signed-in person's files live in a folder of their own, by GitHub user ID, so no viewer ever reads another's. Files are named by a hash of the media item's id, which never carries a signed query string (AGENTS.md, "Feed Caching").
struct PullRequestMediaDiskCache: Sendable {
    static let rootDirectoryURL = URL.cachesDirectory.appending(path: "pull-request-media", directoryHint: .isDirectory)
    private static let videoFileExtensions = ["mp4", "mov", "m4v"]
    private static let imageFileExtension = "image"
    private static let unusedFileRetentionSeconds: TimeInterval = 30 * 24 * 60 * 60
    private static let retiredDemoVisitsFolderName = "demo"
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "pull-request-media")
    private static let fileWriteQueue = DispatchQueue(label: "ai.revyl.shiptok.pull-request-media-writes", qos: .utility)

    let directoryURL: URL

    private init(viewerFolderName: String) {
        directoryURL = Self.rootDirectoryURL.appending(path: viewerFolderName, directoryHint: .isDirectory)
    }

    static func forSignedInGitHubUser(id githubUserID: Int64) -> PullRequestMediaDiskCache {
        PullRequestMediaDiskCache(viewerFolderName: "github-user-\(githubUserID)")
    }

    func cachedVideoFileURL(forMediaItemID mediaItemID: String) -> URL? {
        let fileBaseName = Self.fileBaseName(forMediaItemID: mediaItemID)
        return Self.videoFileExtensions
            .map { directoryURL.appending(path: "\(fileBaseName).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    @concurrent
    func cachedImageData(forMediaItemID mediaItemID: String) async -> Data? {
        let fileURL = directoryURL.appending(path: "\(Self.fileBaseName(forMediaItemID: mediaItemID)).\(Self.imageFileExtension)")
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return nil }
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            Self.logger.error("Reading a saved image failed: \(Self.failureDescription(error), privacy: .public)")
            return nil
        }
    }

    func saveVideoInBackground(_ videoData: Data, contentTypeIdentifier: String, forMediaItemID mediaItemID: String) {
        let preferredFileExtension = UTType(contentTypeIdentifier)?.preferredFilenameExtension ?? ""
        let fileExtension = Self.videoFileExtensions.contains(preferredFileExtension) ? preferredFileExtension : "mp4"
        saveInBackground(videoData, toFileNamed: "\(Self.fileBaseName(forMediaItemID: mediaItemID)).\(fileExtension)")
    }

    func saveImageInBackground(_ imageData: Data, forMediaItemID mediaItemID: String) {
        saveInBackground(imageData, toFileNamed: "\(Self.fileBaseName(forMediaItemID: mediaItemID)).\(Self.imageFileExtension)")
    }

    func removeFiles(forMediaItemID mediaItemID: String) {
        let fileBaseName = Self.fileBaseName(forMediaItemID: mediaItemID)
        for fileExtension in Self.videoFileExtensions + [Self.imageFileExtension] {
            try? FileManager.default.removeItem(at: directoryURL.appending(path: "\(fileBaseName).\(fileExtension)"))
        }
    }

    // A file's modification date is its last use, so pruning measures from when it was last shown, not downloaded.
    func markFilesUsedInBackground(forMediaItemID mediaItemID: String) {
        let fileBaseName = Self.fileBaseName(forMediaItemID: mediaItemID)
        let directoryURL = directoryURL
        Self.fileWriteQueue.async {
            for fileExtension in Self.videoFileExtensions + [Self.imageFileExtension] {
                let filePath = directoryURL.appending(path: "\(fileBaseName).\(fileExtension)").path(percentEncoded: false)
                guard FileManager.default.fileExists(atPath: filePath) else { continue }
                do {
                    try FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: filePath)
                } catch {
                    Self.logger.error("Marking a saved media file used failed: \(Self.failureDescription(error), privacy: .public)")
                }
            }
        }
    }

    // Queued behind every save, so a download that finished before a sign-in ended goes with the rest of that viewer's files.
    func removeAllFilesInBackground() {
        let directoryURL = directoryURL
        Self.fileWriteQueue.async {
            do {
                try FileManager.default.removeItem(at: directoryURL)
            } catch CocoaError.fileNoSuchFile {
                return
            } catch {
                Self.logger.error("Removing a viewer's saved media files failed: \(Self.failureDescription(error), privacy: .public)")
            }
        }
    }

    // The feed, weeks and decks share their viewer's files, so files go by how long they've gone unused, never by one surface's list. A file directly under the root was saved before each viewer had a folder, and earlier builds saved demo visits' media in a folder of their own, so no viewer reads either and both go.
    static func removeLongUnusedFilesInBackground() {
        let oldestKeptUseDate = Date.now.addingTimeInterval(-unusedFileRetentionSeconds)
        fileWriteQueue.async {
            let rootEntryURLs: [URL]
            do {
                rootEntryURLs = try FileManager.default.contentsOfDirectory(at: rootDirectoryURL, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey])
            } catch CocoaError.fileReadNoSuchFile {
                return
            } catch {
                logger.error("Listing saved media folders failed: \(failureDescription(error), privacy: .public)")
                return
            }
            var keptFileCount = 0
            var removedFileCount = 0
            func removeSavedFile(at fileURL: URL) {
                do {
                    try FileManager.default.removeItem(at: fileURL)
                    removedFileCount += 1
                } catch {
                    logger.error("Removing a saved media file failed: \(failureDescription(error), privacy: .public)")
                }
            }
            // Only an entry known to be a file, or the retired demo visits' folder, goes from the root, so one whose type can't be read never takes a viewer's folder with it.
            for rootEntryURL in rootEntryURLs {
                let rootEntryValues: URLResourceValues
                do {
                    rootEntryValues = try rootEntryURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                } catch {
                    logger.error("Reading a saved media entry's type failed, so it stays: \(failureDescription(error), privacy: .public)")
                    continue
                }
                if rootEntryValues.isRegularFile == true {
                    removeSavedFile(at: rootEntryURL)
                    continue
                }
                guard rootEntryValues.isDirectory == true else { continue }
                if rootEntryURL.lastPathComponent == retiredDemoVisitsFolderName {
                    removeSavedFile(at: rootEntryURL)
                    continue
                }
                let viewerFileURLs: [URL]
                do {
                    viewerFileURLs = try FileManager.default.contentsOfDirectory(at: rootEntryURL, includingPropertiesForKeys: [.contentModificationDateKey])
                } catch {
                    logger.error("Listing a viewer's saved media files failed: \(failureDescription(error), privacy: .public)")
                    continue
                }
                for viewerFileURL in viewerFileURLs {
                    if let lastUsedAt = try? viewerFileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                       lastUsedAt >= oldestKeptUseDate {
                        keptFileCount += 1
                    } else {
                        removeSavedFile(at: viewerFileURL)
                    }
                }
            }
            logger.info("Kept \(keptFileCount, privacy: .public) saved media files and removed \(removedFileCount, privacy: .public)")
        }
    }

    // Saves run in order on one queue, so files deleted once this returns stay deleted by every save queued before it.
    static func finishPendingSaves() async {
        await withCheckedContinuation { continuation in
            fileWriteQueue.async { continuation.resume() }
        }
    }

    private func saveInBackground(_ data: Data, toFileNamed fileName: String) {
        let directoryURL = directoryURL
        Self.fileWriteQueue.async {
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                try data.write(to: directoryURL.appending(path: fileName), options: .atomic)
            } catch {
                Self.logger.error("Saving a media file failed: \(Self.failureDescription(error), privacy: .public)")
            }
        }
    }

    private static func fileBaseName(forMediaItemID mediaItemID: String) -> String {
        SHA256.hash(data: Data(mediaItemID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func failureDescription(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }
}
