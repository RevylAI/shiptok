import Observation
import SwiftUI

struct PullRequestHeroMediaView: View {
    let mediaItem: PullRequestMediaItem
    let analyticsSubject: ShipTokAnalyticsSubject
    let mediaPosition: Int
    let isPlaybackActive: Bool
    let isOccludedForAnalytics: Bool
    let pauseToggleTrigger: Int
    let isFastPlaybackHeld: Bool
    let videoScrubFraction: CGFloat?
    let onLoadFailure: () -> Void

    var body: some View {
        PullRequestMediaItemView(
            mediaItem: mediaItem,
            presentation: .hero,
            analyticsMedia: ShipTokAnalyticsMedia(subject: analyticsSubject, surface: .feed, mediaItem: mediaItem, mediaPosition: mediaPosition),
            isMuted: HeroVideoMuteChoice.shared.isMuted,
            isPlaybackActive: isPlaybackActive,
            isOccludedForAnalytics: isOccludedForAnalytics,
            pauseToggleTrigger: pauseToggleTrigger,
            isFastPlaybackHeld: isFastPlaybackHeld,
            videoScrubFraction: videoScrubFraction,
            onLoadFailure: onLoadFailure
        )
        .id(mediaItem.id)
    }
}

@MainActor
@Observable
final class HeroVideoMuteChoice {
    static let shared = HeroVideoMuteChoice()
    var isMuted = true

    private init() {}
}
