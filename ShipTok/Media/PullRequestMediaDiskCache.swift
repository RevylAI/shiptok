import CryptoKit
import Foundation
import OSLog
import UniformTypeIdentifiers

// Media under one id never changes, so a video or image downloaded once plays from the device on every later launch. Files are named by a hash of the media item's id, which never carries a signed query string (AGENTS.md, "Feed Caching").
enum PullRequestMediaDiskCache {
    private static let directoryURL = URL.cachesDirectory.appending(path: "pull-request-media", directoryHint: .isDirectory)
    private static let videoFileExtensions = ["mp4", "mov", "m4v"]
    private static let imageFileExtension = "image"
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "pull-request-media")
    private static let fileSaveQueue = DispatchQueue(label: "ai.revyl.shiptok.pull-request-media-saves", qos: .utility)

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

    // Media of a card that left the feed is never shown again, so a launch keeps only the files of the cards it opens on.
    static func removeFilesInBackground(exceptForMediaItemIDs keptMediaItemIDs: Set<String>) {
        let keptFileBaseNames = Set(keptMediaItemIDs.map(fileBaseName(forMediaItemID:)))
        DispatchQueue.global(qos: .utility).async {
            let fileURLs: [URL]
            do {
                fileURLs = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            } catch {
                return
            }
            var removedFileCount = 0
            for fileURL in fileURLs where !keptFileBaseNames.contains(fileURL.deletingPathExtension().lastPathComponent) {
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

    // Saves run in order on one queue, so files deleted once this returns stay deleted by every save queued before it.
    static func finishPendingSaves() async {
        await withCheckedContinuation { continuation in
            fileSaveQueue.async { continuation.resume() }
        }
    }

    private static func saveInBackground(_ data: Data, toFileNamed fileName: String) {
        fileSaveQueue.async {
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
