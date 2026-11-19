import OSLog
import SwiftUI
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

// The media one feed viewer has: images and videos loaded in memory, the downloads under way and the files saved on the device. Each viewer has their own, so nothing loaded for one person, a private repository's media included, is ever another's; a load captures its viewer's cache before it starts and keeps what it gets only there. Media under one id never changes, so swiping back or opening the deck reuses what already loaded instead of a signed URL that may have expired (AGENTS.md, "Feed Caching").
@MainActor
final class FeedViewerMediaCache {
    let savedMedia: PullRequestMediaDiskCache
    // Nil for a demo visit, so a demo's video requests carry no credential.
    let hostedVideoRevylSignIn: HostedVideoRevylSignIn?
    private let stillImagesByMediaItemID = NSCache<NSString, UIImage>()
    private let animatedGIFDataByMediaItemID = NSCache<NSString, NSData>()
    private let videoResourceLoadersByMediaItemID = NSCache<NSString, SingleRequestVideoResourceLoader>()
    // A download keeps its loader alive until it ends, even after the cache above evicts it, so stopping every download needs its own list.
    private let downloadingVideoResourceLoaders = NSHashTable<SingleRequestVideoResourceLoader>.weakObjects()
    private var failedExpiringSignedURLs = Set<URL>()
    private var mediaItemIDsWithFailedLastLoad = Set<String>()
    private var hasRemovedAllMedia = false
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "pull-request-media")

    init(savedMedia: PullRequestMediaDiskCache, hostedVideoRevylSignIn: HostedVideoRevylSignIn?) {
        self.savedMedia = savedMedia
        self.hostedVideoRevylSignIn = hostedVideoRevylSignIn
    }

    // When a sign-in ends its media goes with it: every download stops without saving, everything loaded is forgotten, its folder is removed and nothing is kept again. Each viewer's media is already apart, so this is cleanup, and one that lands late or fails leaves nothing for anyone else (AGENTS.md, "Feed Caching").
    func stopDownloadsAndRemoveAllMedia() {
        hasRemovedAllMedia = true
        for videoResourceLoader in downloadingVideoResourceLoaders.allObjects {
            videoResourceLoader.stopDownloadWithoutSaving()
        }
        downloadingVideoResourceLoaders.removeAllObjects()
        stillImagesByMediaItemID.removeAllObjects()
        animatedGIFDataByMediaItemID.removeAllObjects()
        videoResourceLoadersByMediaItemID.removeAllObjects()
        failedExpiringSignedURLs.removeAll()
        mediaItemIDsWithFailedLastLoad.removeAll()
        savedMedia.removeAllFilesInBackground()
    }

    // An expiring signed URL that failed once is never requested again; the feed fetches a fresh one instead (AGENTS.md, "Signed Media URLs").
    func hasExpiringSignedURLFailed(for mediaItem: PullRequestMediaItem) -> Bool {
        mediaItem.url.map(failedExpiringSignedURLs.contains) ?? false
    }

    // A first failure is expected and renews the URL, so only a failure after renewal is an error (AGENTS.md, "Signed Media URLs").
    func loadFailureLogLevel(for mediaItem: PullRequestMediaItem) -> OSLogType {
        mediaItemIDsWithFailedLastLoad.contains(mediaItem.id) ? .error : .debug
    }

    // Whatever failed to play, a saved file included, is dropped, so the next attempt downloads it again. A refusal is this viewer's answer, not an expired signature, so it never marks a URL as one to renew.
    func recordLoadFailure(of mediaItem: PullRequestMediaItem, wasRefusedToViewer: Bool) {
        mediaItemIDsWithFailedLastLoad.insert(mediaItem.id)
        videoResourceLoadersByMediaItemID.removeObject(forKey: mediaItem.id as NSString)
        savedMedia.removeFiles(forMediaItemID: mediaItem.id)
        guard !wasRefusedToViewer, mediaItem.hasExpiringSignedURL, let failedURL = mediaItem.url else { return }
        failedExpiringSignedURLs.insert(failedURL)
    }

    func recordLoadSuccess(of mediaItem: PullRequestMediaItem) {
        mediaItemIDsWithFailedLastLoad.remove(mediaItem.id)
    }

    func loadedImage(forMediaItemID mediaItemID: String) -> LoadedPullRequestImage? {
        if let stillImage = stillImagesByMediaItemID.object(forKey: mediaItemID as NSString) {
            return .still(stillImage)
        }
        return animatedGIFDataByMediaItemID.object(forKey: mediaItemID as NSString).map { .animatedGIF($0 as Data) }
    }

    func storeLoadedImage(_ loadedImage: LoadedPullRequestImage, forMediaItemID mediaItemID: String) {
        guard !hasRemovedAllMedia else { return }
        switch loadedImage {
        case .still(let stillImage):
            stillImagesByMediaItemID.setObject(stillImage, forKey: mediaItemID as NSString)
        case .animatedGIF(let gifData):
            animatedGIFDataByMediaItemID.setObject(gifData as NSData, forKey: mediaItemID as NSString)
        }
    }

    // An image that finishes downloading after its viewer's media was removed is kept nowhere.
    func storeDownloadedImage(_ downloadedImage: LoadedPullRequestImage, imageData: Data, forMediaItemID mediaItemID: String) {
        guard !hasRemovedAllMedia else { return }
        savedMedia.saveImageInBackground(imageData, forMediaItemID: mediaItemID)
        storeLoadedImage(downloadedImage, forMediaItemID: mediaItemID)
    }

    // Nil while a saved card waits for its refetch to bring a URL for a video that isn't saved on the device, and once the viewer's media was removed (AGENTS.md, "Feed Caching").
    func reuseOrStartVideoLoad(for mediaItem: PullRequestMediaItem) -> SingleRequestVideoResourceLoader? {
        guard !hasRemovedAllMedia else { return nil }
        let cacheKey = mediaItem.id as NSString
        if let videoResourceLoader = videoResourceLoadersByMediaItemID.object(forKey: cacheKey), !videoResourceLoader.hasFailed {
            return videoResourceLoader
        }
        var savedVideoResourceLoader: SingleRequestVideoResourceLoader?
        if let savedVideoFileURL = savedMedia.cachedVideoFileURL(forMediaItemID: mediaItem.id) {
            do {
                savedVideoResourceLoader = try SingleRequestVideoResourceLoader(savedVideoFileURL: savedVideoFileURL)
                savedMedia.markFilesUsedInBackground(forMediaItemID: mediaItem.id)
            } catch {
                let readError = error as NSError
                Self.logger.error("Reading a saved video failed, so it downloads again: \(readError.domain, privacy: .public) \(readError.code)")
            }
        }
        let videoResourceLoader: SingleRequestVideoResourceLoader
        if let savedVideoResourceLoader {
            videoResourceLoader = savedVideoResourceLoader
        } else if let videoURL = mediaItem.url {
            videoResourceLoader = SingleRequestVideoResourceLoader(
                videoURL: videoURL,
                savingInto: savedMedia,
                asMediaItemID: mediaItem.id,
                failureLogLevel: loadFailureLogLevel(for: mediaItem),
                hostedVideoRevylSignIn: hostedVideoRevylSignIn
            )
            downloadingVideoResourceLoaders.add(videoResourceLoader)
        } else {
            return nil
        }
        videoResourceLoadersByMediaItemID.setObject(videoResourceLoader, forKey: cacheKey)
        return videoResourceLoader
    }
}

private struct FeedViewerMediaCacheEnvironmentKey: EnvironmentKey {
    static let defaultValue: FeedViewerMediaCache? = nil
}

extension EnvironmentValues {
    var feedViewerMediaCache: FeedViewerMediaCache? {
        get { self[FeedViewerMediaCacheEnvironmentKey.self] }
        set { self[FeedViewerMediaCacheEnvironmentKey.self] = newValue }
    }
}
