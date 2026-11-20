import SwiftUI

struct VibeStampView: View {
    let horizontalDragProgress: CGFloat

    var body: some View {
        let castVibe = FeedSwipeGestureMapping.action(for: horizontalDragProgress >= 0 ? .right : .left).castVibe
        // Built only mid-drag: the feed's accessibilityHidden(false) would expose an invisible stamp to VoiceOver, overriding a hidden modifier here.
        if let castVibe, horizontalDragProgress != 0 {
            Text(castVibe.displayName.uppercased())
                .font(.system(size: 34, weight: .black))
                .tracking(2)
                .foregroundStyle(castVibe.tintColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(castVibe.tintColor, lineWidth: 5))
                .rotationEffect(.degrees(horizontalDragProgress >= 0 ? -14 : 14))
                .opacity(min(1, Double(abs(horizontalDragProgress)) * 3))
                .allowsHitTesting(false)
        }
    }
}
