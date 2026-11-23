import SwiftUI

struct PostMediaDeckView: View {
    let mediaItems: [ShipTokPostMedia]
    let unloadableMediaItemIDs: Set<String>
    let analyticsSubject: ShipTokAnalyticsSubject?
    // Reports and hides the post's author; nil when there's nobody to report, such as a deleted GitHub account (AGENTS.md, "Report And Hide").
    let moderation: ContentModeration?
    let onLoadFailure: (ShipTokPostMedia) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.shipTokAnalytics) private var analytics
    @Environment(VideoPlaybackRateChoice.self) private var playbackRateChoice
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedMediaItemID: String?
    @State private var isMuted = false

    private var currentMediaItem: ShipTokPostMedia? {
        mediaItems.first { $0.id == selectedMediaItemID } ?? mediaItems.first
    }

    private var isCurrentMediaItemLoadableVideo: Bool {
        guard let currentMediaItem else { return false }
        return currentMediaItem.kind == .video && !unloadableMediaItemIDs.contains(currentMediaItem.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            deckControls
            // A page TabView whose pages ignore the safe area stops paging in a window with side insets, such as a foldable's wide inner screen, so the pager stays inside it.
            TabView(selection: $selectedMediaItemID) {
                ForEach(mediaItems) { mediaItem in
                    PostMediaView(
                        mediaItem: mediaItem,
                        presentation: .deckPage,
                        analyticsMedia: analyticsSubject.map {
                            ShipTokAnalyticsMedia(subject: $0, surface: .mediaDeck, mediaItem: mediaItem,
                                                  mediaPosition: mediaItems.firstIndex(of: mediaItem) ?? 0)
                        },
                        isMuted: isMuted,
                        isPlaybackActive: scenePhase == .active && mediaItem.id == currentMediaItem?.id,
                        isUnloadable: unloadableMediaItemIDs.contains(mediaItem.id),
                        onLoadFailure: { onLoadFailure(mediaItem) }
                    )
                    .tag(Optional(mediaItem.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden()
        .onAppear {
            if selectedMediaItemID == nil {
                selectedMediaItemID = mediaItems.first?.id
            }
        }
        .onDisappear { AppAudioSession.returnToAmbientCategoryForMutedVideoAutoplay() }
    }

    // The position stays centered over the deck whatever the two sides hold.
    private var deckControls: some View {
        HStack(spacing: 8) {
            deckControlButton(systemImageName: "xmark", accessibilityLabel: "Close") { dismiss() }
            if let moderation, !moderation.reportableContents.isEmpty {
                ContentModerationMenu(moderation: moderation) {
                    deckControlIcon(systemImageName: "ellipsis")
                }
                .accessibilityLabel("More")
                .accessibilityHint("Report on GitHub or hide a person")
            }
            Spacer(minLength: 0)
            Button {
                let previousRate = playbackRateChoice.chosenPlaybackRate
                playbackRateChoice.chooseNextOfferedPlaybackRate()
                analytics?.capture(.speedChanged(analyticsSubject, control: .mediaDeck, previousRate: previousRate,
                                                  playbackRate: playbackRateChoice.chosenPlaybackRate))
            } label: {
                Text(verbatim: playbackRateChoice.chosenPlaybackRateText)
                    .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .frame(minWidth: 40, minHeight: 40)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(.white.opacity(0.14)))
                    .frame(height: 44)
                    .contentShape(Rectangle())
                    .animation(.snappy(duration: 0.2), value: playbackRateChoice.chosenPlaybackRate)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Playback speed")
            .accessibilityValue(playbackRateChoice.chosenPlaybackRateText)
            .accessibilityHint("Changes the speed of every video")
            .opacity(isCurrentMediaItemLoadableVideo ? 1 : 0)
            .disabled(!isCurrentMediaItemLoadableVideo)
            deckControlButton(
                systemImageName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                accessibilityLabel: isMuted ? "Unmute" : "Mute"
            ) { isMuted.toggle() }
            .opacity(isCurrentMediaItemLoadableVideo ? 1 : 0)
            .disabled(!isCurrentMediaItemLoadableVideo)
        }
        .overlay {
            HStack(spacing: 8) {
                if let currentMediaItem, let currentPosition = mediaItems.firstIndex(of: currentMediaItem) {
                    Text("\(currentPosition + 1) of \(mediaItems.count)")
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.white.opacity(0.14)))
                }
                if currentMediaItem?.isShipTokVideo == true {
                    Text(verbatim: "ShipTok")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(RevylBrandColor.brandGradient))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func deckControlButton(systemImageName: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            deckControlIcon(systemImageName: systemImageName)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func deckControlIcon(systemImageName: String) -> some View {
        Image(systemName: systemImageName)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Circle().fill(.white.opacity(0.14)))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}
