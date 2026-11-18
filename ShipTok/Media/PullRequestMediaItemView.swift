import AVFoundation
import ImageIO
import OSLog
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PullRequestMediaItemView: View {
    enum Presentation: Equatable {
        case hero
        case deckPage
    }

    let mediaItem: PullRequestMediaItem
    let presentation: Presentation
    let analyticsMedia: ShipTokAnalyticsMedia?
    let isMuted: Bool
    let isPlaybackActive: Bool
    let isUnloadable: Bool
    var isOccludedForAnalytics = false
    var pauseToggleTrigger = 0
    var isFastPlaybackHeld = false
    var videoScrubFraction: CGFloat?
    let onLoadFailure: (_ wasRefusedToViewer: Bool) -> Void
    @State private var loadedImage: LoadedPullRequestImage?
    @State private var videoPlayback: LoopingVideoPlayback?
    @State private var hasFailedToLoad = false
    @State private var renewalRequestCount = 0
    @State private var isWaitingForGitHubAccessToken = false
    @State private var naturalSize: CGSize?
    @State private var hasReadVideoNaturalSize = false
    @State private var isPausedByViewer = false
    @State private var isDeckPageFastPlaybackHeld = false
    @State private var deckPageVideoScrubFraction: CGFloat?
    @State private var fastPlaybackStartInstant: ContinuousClock.Instant?
    @State private var videoScrubStartSeconds: Double?
    @State private var hasReportedPlaybackFailure = false
    @State private var hasTerminalPlaybackFailure = false
    @Environment(\.shipTokAnalytics) private var analytics
    @Environment(\.feedViewerMediaCache) private var feedViewerMediaCache
    @Environment(VideoPlaybackRateChoice.self) private var playbackRateChoice
    @Environment(\.scenePhase) private var scenePhase
    static let heroProgressLineHorizontalInset: CGFloat = 16
    static let heroProgressLineBottomInset: CGFloat = 15
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "pull-request-media")
    private static let fastPlaybackRate: Float = 2
    private static let deckPageProgressLineHitSlop: CGFloat = 20
    private static let imageDownloadAttemptLimit = 3
    private static let gitHubAccessTokenRetryDelay: Duration = .seconds(5)
    private static let heroFillMinimumVisibleFraction: CGFloat = 0.875
    private static let heroBackdropDimmingOpacity = 0.35
    private static let heroBackdropBlurRadius: CGFloat = 30

    // A material blurs whatever lies behind it, a player layer or a UIKit image view included, which a blur modifier isn't guaranteed to reach.
    private static var heroBackdropMaterialBlur: some View {
        Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
    }

    private var videoPlaybackHasFailed: Bool {
        videoPlayback?.hasFailed ?? false
    }

    // The hero's fill or fit depends on the video's size, so a video shows only once both are known.
    private var isVideoShowing: Bool {
        videoPlayback?.hasStartedPlaying == true && hasReadVideoNaturalSize
    }

    private var isShowingLoadedMedia: Bool {
        loadedImage != nil || isVideoShowing
    }

    // The hero's hold and scrub come from the card and the feed's drag, whose gestures they must share; a deck page holds its own.
    private var isFastPlaybackActive: Bool {
        (isFastPlaybackHeld || isDeckPageFastPlaybackHeld) && isPlaybackActive && !isPausedByViewer
    }

    private var activeVideoScrubFraction: CGFloat? {
        videoScrubFraction ?? deckPageVideoScrubFraction
    }

    var body: some View {
        ZStack {
            Color.black
            if isUnloadable {
                unavailableLabel
            } else {
                if let videoPlayback {
                    videoView(videoPlayback)
                } else if let loadedImage {
                    imageView(loadedImage)
                }
                if !isShowingLoadedMedia {
                    ProgressView().tint(RevylBrandColor.textMuted)
                }
            }
        }
        .task(id: MediaLoadRequest(mediaURL: mediaItem.url, renewalRequestCount: renewalRequestCount)) { await loadUnlessAlreadyLoaded() }
        .task(id: videoPlayback?.isReadyToPlay == true) { await handleVideoReadyToPlay() }
        .task(id: isWaitingForGitHubAccessToken && isWatchedPresentation) { await loadAgainAfterGitHubAccessTokenWait() }
        .onChange(of: isPlaybackActive) {
            isPausedByViewer = false
            updateVideoPlayback(restartingFromBeginning: true)
            updateWatchVisibility()
        }
        .onChange(of: isVideoShowing) { updateWatchVisibility() }
        .onChange(of: isOccludedForAnalytics) { updateWatchVisibility() }
        .onChange(of: scenePhase) { updateWatchVisibility() }
        .onChange(of: isPausedByViewer) {
            updateVideoPlayback(restartingFromBeginning: false)
        }
        .onChange(of: pauseToggleTrigger) {
            guard videoPlayback != nil, isPlaybackActive else { return }
            withAnimation(.easeOut(duration: 0.15)) { isPausedByViewer.toggle() }
        }
        .onChange(of: isMuted) { _, isMuted in
            videoPlayback?.isMuted = isMuted
        }
        .onChange(of: isFastPlaybackActive) { _, isActive in
            updateFastPlayback(isActive: isActive)
        }
        .onChange(of: playbackRateChoice.chosenPlaybackRate) {
            applyPlaybackRate()
        }
        .onChange(of: activeVideoScrubFraction) { previousFraction, fraction in
            updateVideoScrub(from: previousFraction, to: fraction)
        }
        .onChange(of: videoPlaybackHasFailed) { _, hasFailed in
            if hasFailed { handleLoadFailure() }
        }
        .onChange(of: isUnloadable) { _, isUnloadable in
            guard isUnloadable else { return }
            hasTerminalPlaybackFailure = true
            reportVisiblePlaybackFailure()
            videoPlayback?.setAnalyticsVisibility(false)
            videoPlayback?.pause()
            videoPlayback = nil
        }
        .onAppear {
            updateVideoPlayback(restartingFromBeginning: false)
            updateWatchVisibility()
        }
        .onDisappear {
            videoPlayback?.setAnalyticsVisibility(false)
            videoPlayback?.pause()
        }
    }

    // A failed load keeps the loading look while its URL is renewed. Once the store gives the item up, only this shows and nothing loads or plays again (AGENTS.md, "Feed Order").
    private var unavailableLabel: some View {
        VStack(spacing: 8) {
            Image(systemName: mediaItem.kind == .video ? "video.slash" : "photo")
                .font(.title)
                .foregroundStyle(RevylBrandColor.textSubtle)
                .accessibilityHidden(true)
            Text(mediaItem.kind == .video ? "Video unavailable" : "Image unavailable")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(RevylBrandColor.textMuted)
        }
    }

    // A first frame shown before playback can start reads as a frozen video, so the loading look stays until it plays.
    @ViewBuilder
    private func videoView(_ videoPlayback: LoopingVideoPlayback) -> some View {
        switch presentation {
        case .hero:
            heroFrame { contentMode in
                VideoPlayerLayerView(player: videoPlayback.player, contentMode: contentMode)
            } backdrop: {
                VideoPlayerLayerView(player: videoPlayback.player, contentMode: .fill)
                    .overlay(Self.heroBackdropMaterialBlur)
            }
            .overlay { pausedGlyph }
            .overlay(alignment: .bottom) {
                if isPlaybackActive {
                    VStack(spacing: 10) {
                        playbackGestureHint(videoPlayback)
                        VideoPlaybackProgressBar(player: videoPlayback.player, thicknessPoints: 2, scrubFraction: activeVideoScrubFraction)
                    }
                    .padding(.horizontal, Self.heroProgressLineHorizontalInset)
                    .padding(.bottom, Self.heroProgressLineBottomInset)
                }
            }
            .opacity(isVideoShowing ? 1 : 0)
        case .deckPage:
            VStack(spacing: 12) {
                VideoPlayerLayerView(player: videoPlayback.player, contentMode: .fit)
                    .opacity(isVideoShowing ? 1 : 0)
                    .overlay { pausedGlyph }
                    .overlay(alignment: .bottom) { playbackGestureHint(videoPlayback).padding(.bottom, 12) }
                    .contentShape(Rectangle())
                    .fastPlaybackHold(isHeld: $isDeckPageFastPlaybackHeld)
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { isPausedByViewer.toggle() } }
                    .accessibilityAddTraits(.startsMediaSession)
                    .accessibilityLabel(isPausedByViewer ? "Play video" : "Pause video")
                VideoPlaybackProgressBar(player: videoPlayback.player, thicknessPoints: 3, scrubFraction: deckPageVideoScrubFraction)
                    .overlay { deckPageProgressLineScrubArea }
                    .padding(.horizontal, 16)
            }
            .padding(.bottom, 12)
        }
    }

    // A page swipe that starts on the line scrubs instead, so the hit area reaches only a little past the line and stays above the home indicator.
    private var deckPageProgressLineScrubArea: some View {
        GeometryReader { progressLineGeometry in
            Color.clear
                .contentShape(Rectangle().inset(by: -Self.deckPageProgressLineHitSlop))
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            deckPageVideoScrubFraction = min(max(drag.location.x / max(progressLineGeometry.size.width, 1), 0), 1)
                        }
                        .onEnded { _ in deckPageVideoScrubFraction = nil }
                )
        }
    }

    @ViewBuilder
    private func playbackGestureHint(_ videoPlayback: LoopingVideoPlayback) -> some View {
        if let hintText = playbackGestureHintText(videoPlayback) {
            hintText
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(.black.opacity(0.5)))
                .allowsHitTesting(false)
        }
    }

    private func playbackGestureHintText(_ videoPlayback: LoopingVideoPlayback) -> Text? {
        if let activeVideoScrubFraction, let durationSeconds = videoPlayback.durationSeconds {
            let scrubbedSeconds = durationSeconds * Double(activeVideoScrubFraction)
            return Text(verbatim: "\(Self.playbackTimeText(seconds: scrubbedSeconds)) / \(Self.playbackTimeText(seconds: durationSeconds))")
        }
        return isFastPlaybackActive ? Text("\(Image(systemName: "forward.fill")) 2x") : nil
    }

    private static func playbackTimeText(seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }

    @ViewBuilder
    private var pausedGlyph: some View {
        if isPausedByViewer {
            Image(systemName: "play.fill")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(radius: 8)
                .allowsHitTesting(false)
                .transition(.scale(scale: 1.3).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func imageView(_ loadedImage: LoadedPullRequestImage) -> some View {
        switch (loadedImage, presentation) {
        case (.animatedGIF(let gifData), .hero):
            heroFrame { contentMode in
                AnimatedGIFView(gifData: gifData, isAnimating: isPlaybackActive, contentMode: contentMode)
            } backdrop: {
                AnimatedGIFView(gifData: gifData, isAnimating: false, contentMode: .fill)
                    .overlay(Self.heroBackdropMaterialBlur)
            }
        case (.animatedGIF(let gifData), .deckPage):
            AnimatedGIFView(gifData: gifData, isAnimating: isPlaybackActive, contentMode: .fit)
        case (.still(let stillImage), .hero):
            heroFrame { contentMode in
                Image(uiImage: stillImage).resizable().aspectRatio(contentMode: contentMode)
            } backdrop: {
                Image(uiImage: stillImage).resizable().scaledToFill()
                    .blur(radius: Self.heroBackdropBlurRadius, opaque: true)
            }
        case (.still(let stillImage), .deckPage):
            ZoomableImageView(image: stillImage)
        }
    }

    // Media within an eighth of the card's shape crops to fill it, as Reels fill a phone with a 9:16 video; any other shape shows whole over a blurred copy of itself (AGENTS.md, "Card Layout").
    private func heroFrame<Media: View, Backdrop: View>(
        @ViewBuilder media: @escaping (ContentMode) -> Media,
        @ViewBuilder backdrop: @escaping () -> Backdrop
    ) -> some View {
        GeometryReader { geometry in
            let fillsCard = Self.heroMediaFillsCard(mediaSize: naturalSize, cardSize: geometry.size)
            ZStack {
                if !fillsCard {
                    backdrop()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .overlay(Color.black.opacity(Self.heroBackdropDimmingOpacity))
                }
                media(fillsCard ? .fill : .fit).frame(width: geometry.size.width, height: geometry.size.height)
            }
            .clipped()
            .contentShape(Rectangle())
        }
    }

    private static func heroMediaFillsCard(mediaSize: CGSize?, cardSize: CGSize) -> Bool {
        guard let mediaSize, mediaSize.width > 0, mediaSize.height > 0, cardSize.width > 0, cardSize.height > 0 else { return false }
        let mediaAspectRatio = mediaSize.width / mediaSize.height
        let cardAspectRatio = cardSize.width / cardSize.height
        return min(mediaAspectRatio, cardAspectRatio) / max(mediaAspectRatio, cardAspectRatio) >= heroFillMinimumVisibleFraction
    }

    private func updateVideoPlayback(restartingFromBeginning: Bool) {
        guard let videoPlayback else { return }
        if isPlaybackActive, !isPausedByViewer, activeVideoScrubFraction == nil {
            videoPlayback.play(fromBeginning: restartingFromBeginning)
        } else {
            videoPlayback.pause()
        }
    }

    private func updateWatchVisibility() {
        videoPlayback?.setAnalyticsVisibility(isPlaybackActive && isVideoShowing && scenePhase == .active && !isOccludedForAnalytics,
                                              endReason: scenePhase == .active ? .hidden : .background)
        reportVisiblePlaybackFailure()
    }

    private func reportVisiblePlaybackFailure() {
        guard isPlaybackActive, scenePhase == .active, !isOccludedForAnalytics, hasTerminalPlaybackFailure,
              mediaItem.kind == .video, !hasReportedPlaybackFailure,
              let analyticsMedia else { return }
        hasReportedPlaybackFailure = true
        analytics?.capture(.playbackFailed(analyticsMedia))
    }

    // A hold plays at 2x whatever speed is chosen, and letting go returns to the chosen speed.
    private func applyPlaybackRate() {
        videoPlayback?.playbackRate = isFastPlaybackActive ? Self.fastPlaybackRate : playbackRateChoice.chosenPlaybackRate
    }

    private func updateFastPlayback(isActive: Bool) {
        guard videoPlayback != nil else { return }
        if isActive || fastPlaybackStartInstant != nil {
            let chosenRate = playbackRateChoice.chosenPlaybackRate
            analytics?.capture(.speedChanged(analyticsMedia?.subject, control: .hold,
                                              previousRate: isActive ? chosenRate : Self.fastPlaybackRate,
                                              playbackRate: isActive ? Self.fastPlaybackRate : chosenRate))
        }
        applyPlaybackRate()
        if isActive {
            fastPlaybackStartInstant = .now
        } else if let fastPlaybackStartInstant {
            let heldSeconds = (ContinuousClock.now - fastPlaybackStartInstant) / .seconds(1)
            Self.logger.info("Played a \(presentation.loggedPlace, privacy: .public) video at 2x for \(heldSeconds, format: .fixed(precision: 1)) s while held")
            self.fastPlaybackStartInstant = nil
        }
    }

    // The video holds still under the finger and plays on from where it's let go, unless the viewer had paused it.
    private func updateVideoScrub(from previousFraction: CGFloat?, to fraction: CGFloat?) {
        guard let videoPlayback else { return }
        guard let fraction else {
            if let videoScrubStartSeconds, let durationSeconds = videoPlayback.durationSeconds {
                let scrubEndSeconds = videoPlayback.player.currentTime().seconds
                Self.logger.info("Scrubbed a \(presentation.loggedPlace, privacy: .public) video from \(videoScrubStartSeconds, format: .fixed(precision: 1)) s to \(scrubEndSeconds, format: .fixed(precision: 1)) s of \(durationSeconds, format: .fixed(precision: 1)) s")
            }
            videoScrubStartSeconds = nil
            updateVideoPlayback(restartingFromBeginning: false)
            return
        }
        if previousFraction == nil {
            videoScrubStartSeconds = videoPlayback.player.currentTime().seconds
        }
        videoPlayback.pause()
        if let durationSeconds = videoPlayback.durationSeconds {
            videoPlayback.seek(toSeconds: durationSeconds * Double(fraction))
        }
    }

    // Media under one id never changes, so it loads from memory, then the device, and only then the network, and a fresh signed URL matters only after a failed load. A saved card with nothing on the device waits for its refetch to bring a URL. The viewer's media cache is taken before anything is awaited, so what loads is kept only for that viewer (AGENTS.md, "Signed Media URLs" and "Feed Caching").
    private func loadUnlessAlreadyLoaded() async {
        guard let mediaCache = feedViewerMediaCache, !isUnloadable, hasFailedToLoad || (loadedImage == nil && videoPlayback == nil) else { return }
        guard !mediaCache.hasExpiringSignedURLFailed(for: mediaItem) else {
            handleLoadFailure()
            return
        }
        switch mediaItem.kind {
        case .video:
            guard let videoResourceLoader = mediaCache.reuseOrStartVideoLoad(for: mediaItem) else { return }
            hasFailedToLoad = false
            isWaitingForGitHubAccessToken = false
            hasTerminalPlaybackFailure = false
            videoPlayback = LoopingVideoPlayback(videoResourceLoader: videoResourceLoader, isMuted: isMuted)
            if let analytics, let analyticsMedia {
                videoPlayback?.attachVideoWatch(ShipTokVideoWatch(analytics: analytics, media: analyticsMedia))
            }
            applyPlaybackRate()
            updateVideoPlayback(restartingFromBeginning: true)
        case .image, .animatedImage:
            if let cachedImage = mediaCache.loadedImage(forMediaItemID: mediaItem.id) {
                hasFailedToLoad = false
                showLoadedImage(cachedImage, from: mediaCache)
                return
            }
            if let savedImageData = await mediaCache.savedMedia.cachedImageData(forMediaItemID: mediaItem.id) {
                if let savedImage = await Self.decodeImage(savedImageData) {
                    hasFailedToLoad = false
                    mediaCache.savedMedia.markFilesUsedInBackground(forMediaItemID: mediaItem.id)
                    mediaCache.storeLoadedImage(savedImage, forMediaItemID: mediaItem.id)
                    showLoadedImage(savedImage, from: mediaCache)
                    return
                }
                Self.logger.error("A saved image couldn't be decoded, so it downloads again")
                mediaCache.savedMedia.removeFiles(forMediaItemID: mediaItem.id)
            }
            guard let imageURL = mediaItem.url else { return }
            hasFailedToLoad = false
            do {
                let failureLogLevel = mediaCache.loadFailureLogLevel(for: mediaItem)
                let imageData = try await Self.downloadImageData(from: imageURL, failureLogLevel: failureLogLevel)
                guard let downloadedImage = await Self.decodeImage(imageData) else {
                    Self.logger.log(level: failureLogLevel, "Pull request media response is not an image")
                    throw CocoaError(.fileReadCorruptFile)
                }
                mediaCache.storeDownloadedImage(downloadedImage, imageData: imageData, forMediaItemID: mediaItem.id)
                showLoadedImage(downloadedImage, from: mediaCache)
            } catch {
                guard !Task.isCancelled else { return }
                handleLoadFailure()
            }
        }
    }

    private func showLoadedImage(_ image: LoadedPullRequestImage, from mediaCache: FeedViewerMediaCache) {
        mediaCache.recordLoadSuccess(of: mediaItem)
        loadedImage = image
        recordNaturalSize(image.pixelSize)
    }

    // A video that failed to load has no size to read, so the size is read only once it is ready to play.
    private func handleVideoReadyToPlay() async {
        guard let videoPlayback, videoPlayback.isReadyToPlay else { return }
        feedViewerMediaCache?.recordLoadSuccess(of: mediaItem)
        defer { hasReadVideoNaturalSize = true }
        do {
            guard let naturalDisplaySize = try await videoPlayback.loadNaturalDisplaySize() else { return }
            recordNaturalSize(naturalDisplaySize)
        } catch {
            guard !Task.isCancelled else { return }
            let sizeLoadError = error as NSError
            Self.logger.error("Reading a video's display size failed: \(sizeLoadError.domain, privacy: .public) \(sizeLoadError.code)")
        }
    }

    private func recordNaturalSize(_ resolvedNaturalSize: CGSize) {
        guard naturalSize == nil, resolvedNaturalSize.width > 0, resolvedNaturalSize.height > 0 else { return }
        naturalSize = resolvedNaturalSize
    }

    // The card in focus or the deck's current page, in the foreground with nothing over it, so cards beside it, under Settings or outside the deck's page never count.
    private var isWatchedPresentation: Bool {
        isPlaybackActive && scenePhase == .active && !isOccludedForAnalytics
    }

    // A signed-in person's token that couldn't be had says nothing about the video, so it keeps the loading look and loads again a few seconds later, only while someone is watching it (AGENTS.md, "Signed Media URLs").
    private func loadAgainAfterGitHubAccessTokenWait() async {
        guard isWaitingForGitHubAccessToken, isWatchedPresentation else { return }
        do {
            try await Task.sleep(for: Self.gitHubAccessTokenRetryDelay)
        } catch {
            return
        }
        guard isWaitingForGitHubAccessToken, isWatchedPresentation else { return }
        await loadUnlessAlreadyLoaded()
    }

    // An expiring signed URL is renewed by the feed's refetch; any other URL renews by being requested again, once, before the failure is reported. A video refused to this viewer is reported at once, since no renewal changes that answer, and one that waited on the person's GitHub token isn't a failure of the media at all (AGENTS.md, "Signed Media URLs").
    private func handleLoadFailure() {
        guard let mediaCache = feedViewerMediaCache, !hasFailedToLoad else { return }
        hasFailedToLoad = true
        if videoPlayback?.videoResourceLoader.lackedGitHubAccessToken == true {
            isWaitingForGitHubAccessToken = true
            return
        }
        let wasRefusedToViewer = videoPlayback?.videoResourceLoader.wasRefusedToViewer == true
        hasTerminalPlaybackFailure = wasRefusedToViewer
            || (mediaCache.loadFailureLogLevel(for: mediaItem) == .error && !mediaCache.hasExpiringSignedURLFailed(for: mediaItem))
        mediaCache.recordLoadFailure(of: mediaItem, wasRefusedToViewer: wasRefusedToViewer)
        if !wasRefusedToViewer, !mediaItem.hasExpiringSignedURL, renewalRequestCount == 0 {
            hasTerminalPlaybackFailure = false
            renewalRequestCount += 1
            return
        }
        reportVisiblePlaybackFailure()
        onLoadFailure(wasRefusedToViewer)
    }

    private static func decodeImage(_ imageData: Data) async -> LoadedPullRequestImage? {
        if let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
           CGImageSourceGetType(imageSource) as String? == UTType.gif.identifier,
           CGImageSourceGetCount(imageSource) > 1 {
            return .animatedGIF(imageData)
        }
        return await decodeStillImageForDisplay(imageData).map(LoadedPullRequestImage.still)
    }

    // UIKit's prepare-for-display decoder logs "Error -17102 decompressing image -- possibly corrupt" for PNG, the usual screenshot format, so ImageIO decodes stills, off the main actor.
    @concurrent
    private nonisolated static func decodeStillImageForDisplay(_ imageData: Data) async -> UIImage? {
        let decodingOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let decodedImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, decodingOptions)
        else { return nil }
        return UIImage(cgImage: decodedImage)
    }

    private static func downloadImageData(from imageURL: URL, failureLogLevel: OSLogType) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var attemptNumber = 1
        while true {
            let transientFailureDescription: String
            do {
                let (imageData, response) = try await session.data(from: imageURL)
                let httpStatusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(httpStatusCode) {
                    return imageData
                }
                guard httpStatusCode == 408 || httpStatusCode == 429 || httpStatusCode >= 500 else {
                    logger.log(level: failureLogLevel, "Pull request image rejected with HTTP status \(httpStatusCode)")
                    throw MediaDownloadRejectedError(httpStatusCode: httpStatusCode)
                }
                transientFailureDescription = "HTTP status \(httpStatusCode)"
            } catch let rejection as MediaDownloadRejectedError {
                throw rejection
            } catch {
                if Task.isCancelled { throw error }
                let requestError = error as NSError
                transientFailureDescription = "\(requestError.domain) \(requestError.code)"
            }
            guard attemptNumber < imageDownloadAttemptLimit else {
                logger.log(level: failureLogLevel, "Pull request image failed after \(attemptNumber) attempts: \(transientFailureDescription, privacy: .public)")
                throw URLError(.cannotLoadFromNetwork)
            }
            try await Task.sleep(for: .seconds(attemptNumber))
            attemptNumber += 1
        }
    }
}

private struct MediaLoadRequest: Equatable {
    let mediaURL: URL?
    let renewalRequestCount: Int
}

extension View {
    // Held past a tap's length without moving, so a tap still pauses and a swipe still swipes (AGENTS.md, "Swipe Gestures"), then held wherever the finger
    // goes until it lifts. A SwiftUI long press here stops every single tap from pausing, so it's UIKit's, which needs iOS 18.
    func fastPlaybackHold(isHeld: Binding<Bool>) -> some View {
        modifier(FastPlaybackHoldModifier(isHeld: isHeld))
    }
}

private struct FastPlaybackHoldModifier: ViewModifier {
    @Binding var isHeld: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.gesture(FastPlaybackHoldRecognizer(isHeld: $isHeld))
        } else {
            content
        }
    }
}

@available(iOS 18.0, *)
private struct FastPlaybackHoldRecognizer: UIGestureRecognizerRepresentable {
    @Binding var isHeld: Bool

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.3
        recognizer.allowableMovement = 10
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began: isHeld = true
        case .ended, .cancelled, .failed: isHeld = false
        default: break
        }
    }
}

private extension PullRequestMediaItemView.Presentation {
    var loggedPlace: String {
        switch self {
        case .hero: "feed"
        case .deckPage: "deck"
        }
    }
}

// While scrubbed it follows the finger rather than the seek, and thickens without moving what's laid out around it.
private struct VideoPlaybackProgressBar: View {
    let player: AVPlayer
    let thicknessPoints: CGFloat
    let scrubFraction: CGFloat?

    private static let scrubbingThicknessScale: CGFloat = 3

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white.opacity(0.9))
                        .frame(width: geometry.size.width * (scrubFraction ?? playedFraction))
                }
            }
        }
        .frame(height: thicknessPoints)
        .scaleEffect(x: 1, y: scrubFraction == nil ? 1 : Self.scrubbingThicknessScale, anchor: .bottom)
        .animation(.easeOut(duration: 0.15), value: scrubFraction == nil)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var playedFraction: CGFloat {
        guard let durationSeconds = player.currentItem?.duration.seconds, durationSeconds.isFinite, durationSeconds > 0 else { return 0 }
        return CGFloat(min(max(player.currentTime().seconds / durationSeconds, 0), 1))
    }
}
