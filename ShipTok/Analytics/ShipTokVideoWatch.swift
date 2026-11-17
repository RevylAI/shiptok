import Foundation

@MainActor
final class ShipTokVideoWatch {
    private let analytics: ShipTokAnalytics
    private let media: ShipTokAnalyticsMedia
    private var watchID: UUID?
    private var playingSince: ContinuousClock.Instant?
    private var playbackRate: Double = 1
    private var playbackSeconds: Double = 0
    private var playedMediaSeconds: Double = 0

    init(analytics: ShipTokAnalytics, media: ShipTokAnalyticsMedia) {
        self.analytics = analytics
        self.media = media
    }

    func update(isPlaying: Bool, playbackRate: Float) {
        accumulatePlayback()
        guard isPlaying, playbackRate > 0 else { return }
        if watchID == nil {
            let watchID = UUID()
            self.watchID = watchID
            analytics.capture(.watchStarted(media, watchID: watchID))
        }
        self.playbackRate = Double(playbackRate)
        playingSince = .now
    }

    func finish(durationSeconds: Double?, reason: ShipTokAnalyticsEvent.WatchEndReason) {
        accumulatePlayback()
        guard let watchID else { return }
        analytics.capture(.watchCompleted(media, watchID: watchID, playbackSeconds: playbackSeconds,
                                         mediaSeconds: playedMediaSeconds, durationSeconds: durationSeconds, reason: reason))
        self.watchID = nil
        playbackSeconds = 0
        playedMediaSeconds = 0
    }

    private func accumulatePlayback() {
        guard let playingSince else { return }
        let elapsedSeconds = (ContinuousClock.now - playingSince) / .seconds(1)
        playbackSeconds += elapsedSeconds
        playedMediaSeconds += elapsedSeconds * playbackRate
        self.playingSince = nil
    }
}
