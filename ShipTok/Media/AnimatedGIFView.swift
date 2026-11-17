import ImageIO
import OSLog
import SwiftUI
import UIKit

struct AnimatedGIFView: UIViewRepresentable {
    let gifData: Data
    let isAnimating: Bool
    let contentMode: ContentMode

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView(image: UIImage(data: gifData))
        imageView.clipsToBounds = true
        return imageView
    }

    func updateUIView(_ imageView: UIImageView, context: Context) {
        imageView.contentMode = contentMode == .fill ? .scaleAspectFill : .scaleAspectFit
        if isAnimating {
            context.coordinator.startAnimating(gifData, in: imageView)
        } else {
            context.coordinator.stopAnimating()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    static func dismantleUIView(_ imageView: UIImageView, coordinator: GIFFrameAnimator) {
        coordinator.stopAnimating()
    }

    func makeCoordinator() -> GIFFrameAnimator {
        GIFFrameAnimator()
    }
}

@MainActor
final class GIFFrameAnimator {
    private final class AnimationRun {
        var isStopped = false
    }

    private var runningAnimation: AnimationRun?
    private static let logger = Logger(subsystem: "ai.revyl.shiptok", category: "pull-request-media")

    func startAnimating(_ gifData: Data, in imageView: UIImageView) {
        guard runningAnimation == nil else { return }
        let animationRun = AnimationRun()
        runningAnimation = animationRun
        // ImageIO calls the block on the main queue.
        let animationStatus = CGAnimateImageDataWithBlock(gifData as CFData, nil) { [weak imageView] _, frameImage, shouldStop in
            guard !animationRun.isStopped, let imageView else {
                shouldStop.pointee = true
                return
            }
            imageView.image = UIImage(cgImage: frameImage)
        }
        if animationStatus != OSStatus(noErr) {
            Self.logger.error("Animating a GIF failed with status \(animationStatus)")
            runningAnimation = nil
        }
    }

    func stopAnimating() {
        runningAnimation?.isStopped = true
        runningAnimation = nil
    }
}
