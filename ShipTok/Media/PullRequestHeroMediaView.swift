import SwiftUI

struct PullRequestHeroMediaView: View {
    let mediaItem: PullRequestMediaItem
    let analyticsSubject: ShipTokAnalyticsSubject
    let mediaPosition: Int
    let isPlaybackActive: Bool
    let isUnloadable: Bool
    let isOccludedForAnalytics: Bool
    let pauseToggleTrigger: Int
    let isFastPlaybackHeld: Bool
    let videoScrubFraction: CGFloat?
    let progressLineInsets: EdgeInsets
    let wholeMediaInsets: EdgeInsets
    let captionBackdrop: FeedCaptionBackdrop
    let onLoadFailure: (_ wasRefusedToViewer: Bool) -> Void

    var body: some View {
        PullRequestMediaItemView(
            mediaItem: mediaItem,
            presentation: .hero,
            analyticsMedia: ShipTokAnalyticsMedia(subject: analyticsSubject, surface: .feed, mediaItem: mediaItem, mediaPosition: mediaPosition),
            isMuted: HeroVideoMuteChoice.shared.isMuted,
            isPlaybackActive: isPlaybackActive,
            isUnloadable: isUnloadable,
            isOccludedForAnalytics: isOccludedForAnalytics,
            pauseToggleTrigger: pauseToggleTrigger,
            isFastPlaybackHeld: isFastPlaybackHeld,
            videoScrubFraction: videoScrubFraction,
            heroProgressLineInsets: progressLineInsets,
            wholeHeroMediaInsets: wholeMediaInsets,
            heroCaptionBackdrop: captionBackdrop,
            onLoadFailure: onLoadFailure
        )
        .id(mediaItem.id)
    }
}
