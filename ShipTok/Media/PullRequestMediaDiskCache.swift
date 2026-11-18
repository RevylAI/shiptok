import CryptoKit
import Foundation
import OSLog
import UniformTypeIdentifiers

// Media under one id never changes, so a video or image downloaded once plays from the device on later launches until it goes a month unused. Files are named by a hash of the media item's id, which never carries a signed query string (AGENTS.md, "Feed Caching").
enum PullRequestMediaDiskCache {
    static let directoryURL = URL.cachesDirectory.appending(path: "pull-request-media", directoryHint: .isDirectory)
    private static let videoFileExtensions = ["mp4", "mov", "m4v"]
    private static let imageFileExtension = "image"
    private static let unusedFileRetentionSeconds: TimeInterval = 30 * 24 * 60 * 60
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "pull-request-media")
    private static let fileWriteQueue = DispatchQueue(label: "ai.revyl.shiptok.pull-request-media-writes", qos: .utility)

    static func cachedVideoFileURL(forMediaItemID mediaItemID: String) -> URL? {
        let fileBaseName = fileBaseName(forMediaItemID: mediaItemID)
        return videoFileExtensions
            .map { directoryURL.appending(path: "\(fileBaseName).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    @concurrent
    static func cachedImageData(forMediaItemID mediaItemID: String) async -> Data? {
        let fileURL = directoryURL.appending(path: "\(fileBaseName(forMediaItemID: mediaItemID)).\(imageFileExtension)")
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return nil }
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            logger.error("Reading a saved image failed: \(Self.failureDescription(error), privacy: .public)")
            return nil
        }
    }

    static func saveVideoInBackground(_ videoData: Data, contentTypeIdentifier: String, forMediaItemID mediaItemID: String) {
        let preferredFileExtension = UTType(contentTypeIdentifier)?.preferredFilenameExtension ?? ""
        let fileExtension = videoFileExtensions.contains(preferredFileExtension) ? preferredFileExtension : "mp4"
        saveInBackground(videoData, toFileNamed: "\(fileBaseName(forMediaItemID: mediaItemID)).\(fileExtension)")
    }

    static func saveImageInBackground(_ imageData: Data, forMediaItemID mediaItemID: String) {
        saveInBackground(imageData, toFileNamed: "\(fileBaseName(forMediaItemID: mediaItemID)).\(imageFileExtension)")
    }

    static func removeFiles(forMediaItemID mediaItemID: String) {
        let fileBaseName = fileBaseName(forMediaItemID: mediaItemID)
        for fileExtension in videoFileExtensions + [imageFileExtension] {
            try? FileManager.default.removeItem(at: directoryURL.appending(path: "\(fileBaseName).\(fileExtension)"))
        }
    }

    // A file's modification date is its last use, so pruning measures from when it was last shown, not downloaded.
    static func markFilesUsedInBackground(forMediaItemID mediaItemID: String) {
        let fileBaseName = fileBaseName(forMediaItemID: mediaItemID)
        fileWriteQueue.async {
            for fileExtension in videoFileExtensions + [imageFileExtension] {
                let filePath = directoryURL.appending(path: "\(fileBaseName).\(fileExtension)").path(percentEncoded: false)
                guard FileManager.default.fileExists(atPath: filePath) else { continue }
                do {
                    try FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: filePath)
                } catch {
                    logger.error("Marking a saved media file used failed: \(Self.failureDescription(error), privacy: .public)")
                }
            }
        }
    }

    // The feed, weeks, decks and the demo all save here, so files go by how long they've gone unused, never by one surface's list.
    static func removeLongUnusedFilesInBackground() {
        let oldestKeptUseDate = Date.now.addingTimeInterval(-unusedFileRetentionSeconds)
        fileWriteQueue.async {
            let fileURLs: [URL]
            do {
                fileURLs = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.contentModificationDateKey])
            } catch CocoaError.fileReadNoSuchFile {
                return
            } catch {
                logger.error("Listing saved media files failed: \(Self.failureDescription(error), privacy: .public)")
                return
            }
            var removedFileCount = 0
            for fileURL in fileURLs {
                guard let lastUsedAt = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      lastUsedAt < oldestKeptUseDate
                else { continue }
                do {
                    try FileManager.default.removeItem(at: fileURL)
                    removedFileCount += 1
                } catch {
                    logger.error("Removing a saved media file failed: \(Self.failureDescription(error), privacy: .public)")
                }
            }
            logger.info("Kept \(fileURLs.count - removedFileCount, privacy: .public) saved media files and removed \(removedFileCount, privacy: .public)")
        }
    }

    // Queued behind every save, so a download that finished before a sign-in ended goes with the rest (AGENTS.md, "Feed Caching").
    static func removeAllFilesInBackground() {
        fileWriteQueue.async {
            do {
                try FileManager.default.removeItem(at: directoryURL)
            } catch CocoaError.fileNoSuchFile {
                return
            } catch {
                logger.error("Removing every saved media file failed: \(Self.failureDescription(error), privacy: .public)")
            }
        }
    }

    // Saves run in order on one queue, so files deleted once this returns stay deleted by every save queued before it.
    static func finishPendingSaves() async {
        await withCheckedContinuation { continuation in
            fileWriteQueue.async { continuation.resume() }
        }
    }

    private static func saveInBackground(_ data: Data, toFileNamed fileName: String) {
        fileWriteQueue.async {
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                try data.write(to: directoryURL.appending(path: fileName), options: .atomic)
            } catch {
                logger.error("Saving a media file failed: \(Self.failureDescription(error), privacy: .public)")
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
