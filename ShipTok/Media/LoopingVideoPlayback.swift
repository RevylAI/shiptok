import AVFoundation
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class LoopingVideoPlayback {
    let player: AVQueuePlayer
    private(set) var isReadyToPlay = false
    private(set) var hasStartedPlaying = false
    private(set) var hasFailed = false
    // AVAssetResourceLoader holds its delegate weakly, so the playback keeps the loader alive.
    let videoResourceLoader: SingleRequestVideoResourceLoader
    private let videoAsset: AVURLAsset
    private let playerLooper: AVPlayerLooper
    @ObservationIgnored private var currentItemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var playerLooperStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeControlStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var playbackRateObservation: NSKeyValueObservation?
    @ObservationIgnored private var videoWatch: ShipTokVideoWatch?
    private var isVisibleForAnalytics = false

    init(videoResourceLoader: SingleRequestVideoResourceLoader, isMuted: Bool) {
        let videoAsset = AVURLAsset(url: videoResourceLoader.assetURL)
        videoAsset.resourceLoader.setDelegate(videoResourceLoader, queue: videoResourceLoader.delegateQueue)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = isMuted
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = !isMuted
        self.videoResourceLoader = videoResourceLoader
        self.videoAsset = videoAsset
        player = queuePlayer
        playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: AVPlayerItem(asset: videoAsset))
        currentItemStatusObservation = queuePlayer.observe(
            \.currentItem?.status,
            options: [.initial, .new],
            changeHandler: Self.makeCurrentItemStatusHandler(reportingTo: self)
        )
        playerLooperStatusObservation = playerLooper.observe(
            \.status,
            options: [.initial, .new],
            changeHandler: Self.makePlayerLooperStatusHandler(reportingTo: self)
        )
        timeControlStatusObservation = queuePlayer.observe(
            \.timeControlStatus,
            options: [.initial, .new],
            changeHandler: Self.makeTimeControlStatusHandler(reportingTo: self)
        )
        playbackRateObservation = queuePlayer.observe(\.rate, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updateWatchPlayback() }
        }
    }

    var isMuted: Bool {
        get { player.isMuted }
        set {
            player.isMuted = newValue
            player.preventsDisplaySleepDuringVideoPlayback = !newValue
            if !newValue, player.timeControlStatus != .paused {
                AppAudioSession.usePlaybackCategoryForVideoWithSound()
            }
        }
    }

    // play() starts at the default rate, so a rate set while paused, or before a loop or restart, carries over.
    var playbackRate: Float {
        get { player.defaultRate }
        set {
            videoWatch?.update(isPlaying: false, playbackRate: player.rate)
            player.defaultRate = newValue
            if player.timeControlStatus != .paused {
                player.rate = newValue
            }
            updateWatchPlayback()
        }
    }

    func attachVideoWatch(_ videoWatch: ShipTokVideoWatch) {
        self.videoWatch = videoWatch
    }

    func setAnalyticsVisibility(_ isVisible: Bool, endReason: ShipTokAnalyticsEvent.WatchEndReason = .hidden) {
        isVisibleForAnalytics = isVisible
        if isVisible {
            updateWatchPlayback()
        } else {
            videoWatch?.finish(durationSeconds: durationSeconds, reason: endReason)
        }
    }

    private func updateWatchPlayback() {
        videoWatch?.update(isPlaying: isVisibleForAnalytics && player.timeControlStatus == .playing,
                           playbackRate: player.rate)
    }

    var durationSeconds: Double? {
        guard let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    func seek(toSeconds seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func play(fromBeginning: Bool) {
        guard !hasFailed else { return }
        if player.isMuted {
            AppAudioSession.useAmbientCategoryIfStillSystemDefault()
        } else {
            AppAudioSession.usePlaybackCategoryForVideoWithSound()
        }
        if fromBeginning {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
    }

    func pause() {
        videoWatch?.update(isPlaying: false, playbackRate: player.rate)
        player.pause()
    }

    func loadNaturalDisplaySize() async throws -> CGSize? {
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else { return nil }
        let (naturalSize, preferredTransform) = try await videoTrack.load(.naturalSize, .preferredTransform)
        let displayedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return CGSize(width: abs(displayedRect.width), height: abs(displayedRect.height))
    }

    private func markReadyToPlay() {
        guard !isReadyToPlay else { return }
        isReadyToPlay = true
    }

    private func markStartedPlaying() {
        guard !hasStartedPlaying else { return }
        hasStartedPlaying = true
    }

    private func markFailed() {
        guard !hasFailed else { return }
        hasFailed = true
        setAnalyticsVisibility(false, endReason: .playbackFailed)
        playerLooper.disableLooping()
        player.pause()
    }

    private nonisolated static func makeCurrentItemStatusHandler(
        reportingTo playback: LoopingVideoPlayback
    ) -> @Sendable (AVQueuePlayer, NSKeyValueObservedChange<AVPlayerItem.Status?>) -> Void {
        { [weak playback] player, _ in
            switch player.currentItem?.status {
            case .readyToPlay:
                Task { @MainActor [playback] in
                    playback?.markReadyToPlay()
                }
            case .failed:
                Task { @MainActor [playback] in
                    playback?.markFailed()
                }
            default:
                return
            }
        }
    }

    private nonisolated static func makeTimeControlStatusHandler(
        reportingTo playback: LoopingVideoPlayback
    ) -> @Sendable (AVQueuePlayer, NSKeyValueObservedChange<AVPlayer.TimeControlStatus>) -> Void {
        { [weak playback] player, _ in
            Task { @MainActor [playback] in
                guard let playback else { return }
                if playback.player.timeControlStatus == .playing { playback.markStartedPlaying() }
                playback.updateWatchPlayback()
            }
        }
    }

    private nonisolated static func makePlayerLooperStatusHandler(
        reportingTo playback: LoopingVideoPlayback
    ) -> @Sendable (AVPlayerLooper, NSKeyValueObservedChange<AVPlayerLooper.Status>) -> Void {
        { [weak playback] playerLooper, _ in
            guard playerLooper.status == .failed else { return }
            Task { @MainActor [playback] in
                playback?.markFailed()
            }
        }
    }
}

struct VideoPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let contentMode: ContentMode

    func makeUIView(context: Context) -> PlayerLayerHostView {
        let hostView = PlayerLayerHostView()
        hostView.isUserInteractionEnabled = false
        hostView.clipsToBounds = true
        updateUIView(hostView, context: context)
        return hostView
    }

    func updateUIView(_ hostView: PlayerLayerHostView, context: Context) {
        let videoGravity: AVLayerVideoGravity = contentMode == .fill ? .resizeAspectFill : .resizeAspect
        if hostView.playerLayer.videoGravity != videoGravity {
            hostView.playerLayer.videoGravity = videoGravity
        }
        if hostView.playerLayer.player !== player {
            hostView.playerLayer.player = player
        }
    }
}

final class PlayerLayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        guard let playerLayer = layer as? AVPlayerLayer else {
            preconditionFailure("PlayerLayerHostView's layerClass is AVPlayerLayer")
        }
        return playerLayer
    }
}
