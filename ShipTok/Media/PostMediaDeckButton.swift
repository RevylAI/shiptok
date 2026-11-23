import SwiftUI

struct PostMediaDeckButton: View {
    let mediaItems: [ShipTokPostMedia]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                fannedMediaCards
                    .frame(width: 44, height: 40)
                    .actionRailGlyphStyle()
                Text(mediaItems.count.formatted(.number.notation(.compactName)))
                    .actionRailCountStyle()
            }
        }
        .buttonStyle(.swipeYielding)
        .accessibilityLabel("Every photo and video on this pull request")
        .accessibilityValue(mediaItems.count == 1 ? "1 item" : "\(mediaItems.count) items")
    }

    private var fannedMediaCards: some View {
        let fanAnglesInDegrees: [Double] = switch mediaItems.count {
        case ...1: [0]
        case 2: [-14, 0]
        default: [-18, 18, 0]
        }
        return ZStack {
            ForEach(fanAnglesInDegrees.indices, id: \.self) { cardIndex in
                let isFrontCard = cardIndex == fanAnglesInDegrees.count - 1
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(isFrontCard ? RevylBrandColor.textPrimary : RevylBrandColor.surfaceFloating)
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(RevylBrandColor.textPrimary, lineWidth: 1.5))
                    .overlay {
                        if isFrontCard {
                            Image(systemName: mediaItems.first?.kind == .video ? "play.fill" : "photo.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(RevylBrandColor.canvas)
                        }
                    }
                    .frame(width: 18, height: 24)
                    .rotationEffect(.degrees(fanAnglesInDegrees[cardIndex]), anchor: .bottom)
            }
        }
    }
}
