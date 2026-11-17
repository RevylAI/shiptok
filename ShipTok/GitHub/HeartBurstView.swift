import SwiftUI

struct HeartBurstView: View {
    let trigger: Int

    private struct BurstFrame {
        var scale: CGFloat = 0.4
        var opacity: Double = 0
    }

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 110))
            .foregroundStyle(RevylBrandColor.danger)
            .shadow(color: .black.opacity(0.4), radius: 12)
            .keyframeAnimator(initialValue: BurstFrame(), trigger: trigger) { heart, frame in
                heart
                    .scaleEffect(frame.scale)
                    .opacity(frame.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.15, duration: 0.22)
                    SpringKeyframe(1.0, duration: 0.15)
                    LinearKeyframe(1.0, duration: 0.3)
                    LinearKeyframe(1.35, duration: 0.2)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.08)
                    LinearKeyframe(1, duration: 0.6)
                    LinearKeyframe(0, duration: 0.2)
                }
            }
            .allowsHitTesting(false)
    }
}
