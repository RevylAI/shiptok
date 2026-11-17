import OSLog
import UIKit

enum LoadedPullRequestImage {
    case still(UIImage)
    case animatedGIF(Data)

    var pixelSize: CGSize {
        switch self {
        case .still(let stillImage):
            CGSize(width: stillImage.size.width * stillImage.scale, height: stillImage.size.height * stillImage.scale)
        case .animatedGIF(let gifData):
            UIImage(data: gifData)?.size ?? .zero
        }
    }
}

// Media under one id never changes, so swiping back or opening the deck reuses what already loaded instead of a signed URL that may have expired.
@MainActor
enum PullRequestMediaMemoryCache {
    private static let stillImagesByMediaItemID = NSCache<NSString, UIImage>()
    private static let animatedGIFDataByMediaItemID = NSCache<NSString, NSData>()
    private static let videoResourceLoadersByMediaItemID = NSCache<NSString, SingleRequestVideoResourceLoader>()
    // A download keeps its loader alive until it ends, even after the cache above evicts it, so stopping every download needs its own list.
    private static let downloadingVideoResourceLoaders = NSHashTable<SingleRequestVideoResourceLoader>.weakObjects()
    private static var failedExpiringSignedURLs = Set<URL>()
    private static var mediaItemIDsWithFailedLastLoad = Set<String>()
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "pull-request-media")
    // An image load compares it before keeping what it downloaded, so a load that began before a removal keeps nothing.
    private(set) static var allMediaRemovalCount = 0

    // Deleting a person's ShipTok data leaves no media behind: every download stops without saving, and every loaded image and video is forgotten (AGENTS.md, "Ownership And Boundaries").
    static func removeAllLoadedMediaAndStopDownloads() {
        allMediaRemovalCount += 1
        for videoResourceLoader in downloadingVideoResourceLoaders.allObjects {
            videoResourceLoader.stopDownloadWithoutSaving()
        }
        downloadingVideoResourceLoaders.removeAllObjects()
        stillImagesByMediaItemID.removeAllObjects()
        animatedGIFDataByMediaItemID.removeAllObjects()
        videoResourceLoadersByMediaItemID.removeAllObjects()
        failedExpiringSignedURLs.removeAll()
        mediaItemIDsWithFailedLastLoad.removeAll()
    }

    // An expiring signed URL that failed once is never requested again; the feed fetches a fresh one instead (AGENTS.md, "Signed Media URLs").
    static func hasExpiringSignedURLFailed(for mediaItem: PullRequestMediaItem) -> Bool {
        mediaItem.url.map(failedExpiringSignedURLs.contains) ?? false
    }

    // A first failure is expected and renews the URL, so only a failure after renewal is an error (AGENTS.md, "Signed Media URLs").
    static func loadFailureLogLevel(for mediaItem: PullRequestMediaItem) -> OSLogType {
        mediaItemIDsWithFailedLastLoad.contains(mediaItem.id) ? .error : .debug
    }

    // Whatever failed to play, a saved file included, is dropped, so the next attempt downloads it again.
    static func recordLoadFailure(of mediaItem: PullRequestMediaItem) {
        mediaItemIDsWithFailedLastLoad.insert(mediaItem.id)
        videoResourceLoadersByMediaItemID.removeObject(forKey: mediaItem.id as NSString)
        PullRequestMediaDiskCache.removeFiles(forMediaItemID: mediaItem.id)
        guard mediaItem.hasExpiringSignedURL, let failedURL = mediaItem.url else { return }
        failedExpiringSignedURLs.insert(failedURL)
    }

    static func recordLoadSuccess(of mediaItem: PullRequestMediaItem) {
        mediaItemIDsWithFailedLastLoad.remove(mediaItem.id)
    }

    static func loadedImage(forMediaItemID mediaItemID: String) -> LoadedPullRequestImage? {
        if let stillImage = stillImagesByMediaItemID.object(forKey: mediaItemID as NSString) {
            return .still(stillImage)
        }
        return animatedGIFDataByMediaItemID.object(forKey: mediaItemID as NSString).map { .animatedGIF($0 as Data) }
    }

    static func storeLoadedImage(_ loadedImage: LoadedPullRequestImage, forMediaItemID mediaItemID: String) {
        switch loadedImage {
        case .still(let stillImage):
            stillImagesByMediaItemID.setObject(stillImage, forKey: mediaItemID as NSString)
        case .animatedGIF(let gifData):
            animatedGIFDataByMediaItemID.setObject(gifData as NSData, forKey: mediaItemID as NSString)
        }
    }

    // Nil while a saved card waits for its refetch to bring a URL for a video that isn't saved on the device (AGENTS.md, "Feed Caching").
    static func reuseOrStartVideoLoad(for mediaItem: PullRequestMediaItem) -> SingleRequestVideoResourceLoader? {
        let cacheKey = mediaItem.id as NSString
        if let videoResourceLoader = videoResourceLoadersByMediaItemID.object(forKey: cacheKey), !videoResourceLoader.hasFailed {
            return videoResourceLoader
        }
        var savedVideoResourceLoader: SingleRequestVideoResourceLoader?
        if let savedVideoFileURL = PullRequestMediaDiskCache.cachedVideoFileURL(forMediaItemID: mediaItem.id) {
            do {
                savedVideoResourceLoader = try SingleRequestVideoResourceLoader(savedVideoFileURL: savedVideoFileURL)
            } catch {
                let readError = error as NSError
                logger.error("Reading a saved video failed, so it downloads again: \(readError.domain, privacy: .public) \(readError.code)")
            }
        }
        let videoResourceLoader: SingleRequestVideoResourceLoader
        if let savedVideoResourceLoader {
            videoResourceLoader = savedVideoResourceLoader
        } else if let videoURL = mediaItem.url {
            videoResourceLoader = SingleRequestVideoResourceLoader(
                videoURL: videoURL,
                savingAsMediaItemID: mediaItem.id,
                failureLogLevel: loadFailureLogLevel(for: mediaItem)
            )
            downloadingVideoResourceLoaders.add(videoResourceLoader)
        } else {
            return nil
        }
        videoResourceLoadersByMediaItemID.setObject(videoResourceLoader, forKey: cacheKey)
        return videoResourceLoader
    }
}
