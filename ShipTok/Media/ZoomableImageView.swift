import SwiftUI
import UIKit

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomableImageScrollView {
        ZoomableImageScrollView(image: image)
    }

    func updateUIView(_ scrollView: ZoomableImageScrollView, context: Context) {
        scrollView.showImage(image)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ZoomableImageScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

final class ZoomableImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var fittedBoundsSize = CGSize.zero
    private static let doubleTapZoomScale: CGFloat = 2.5

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        imageView.image = image
        addSubview(imageView)
        let doubleTapRecognizer = UITapGestureRecognizer(target: self, action: #selector(toggleZoomAtTap(_:)))
        doubleTapRecognizer.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTapRecognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("ZoomableImageScrollView is created in code")
    }

    func showImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        fittedBoundsSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedBoundsSize {
            refitImageKeepingZoom()
        }
        centerImageView()
    }

    // A fold resizes the page, so the zoom and the spot in view carry over instead of snapping back to fit.
    private func refitImageKeepingZoom() {
        guard let imageSize = imageView.image?.size, imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let keptZoomScale = fittedBoundsSize == .zero ? minimumZoomScale : zoomScale
        let keptVisibleCenterInImage = visibleCenterAsFractionOfImage()
        fittedBoundsSize = bounds.size
        zoomScale = minimumZoomScale
        let fitScale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        imageView.frame = CGRect(
            x: 0,
            y: 0,
            width: min(imageSize.width * fitScale, bounds.width),
            height: min(imageSize.height * fitScale, bounds.height)
        )
        contentSize = imageView.frame.size
        guard keptZoomScale > minimumZoomScale else { return }
        zoomScale = keptZoomScale
        centerImageView()
        let keptVisibleCenter = imageView.convert(
            CGPoint(x: keptVisibleCenterInImage.x * imageView.bounds.width, y: keptVisibleCenterInImage.y * imageView.bounds.height),
            to: self
        )
        contentOffset = CGPoint(
            x: min(max(keptVisibleCenter.x - bounds.width / 2, 0), max(contentSize.width - bounds.width, 0)),
            y: min(max(keptVisibleCenter.y - bounds.height / 2, 0), max(contentSize.height - bounds.height, 0))
        )
    }

    private func visibleCenterAsFractionOfImage() -> CGPoint {
        guard imageView.bounds.width > 0, imageView.bounds.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let visibleCenter = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: imageView)
        return CGPoint(x: visibleCenter.x / imageView.bounds.width, y: visibleCenter.y / imageView.bounds.height)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageView()
    }

    private func centerImageView() {
        var centeredFrame = imageView.frame
        centeredFrame.origin.x = max(0, (bounds.width - centeredFrame.width) / 2)
        centeredFrame.origin.y = max(0, (bounds.height - centeredFrame.height) / 2)
        imageView.frame = centeredFrame
    }

    @objc private func toggleZoomAtTap(_ doubleTapRecognizer: UITapGestureRecognizer) {
        guard zoomScale == minimumZoomScale else {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let tapPoint = doubleTapRecognizer.location(in: imageView)
        let zoomedVisibleSize = CGSize(width: bounds.width / Self.doubleTapZoomScale, height: bounds.height / Self.doubleTapZoomScale)
        zoom(
            to: CGRect(
                x: tapPoint.x - zoomedVisibleSize.width / 2,
                y: tapPoint.y - zoomedVisibleSize.height / 2,
                width: zoomedVisibleSize.width,
                height: zoomedVisibleSize.height
            ),
            animated: true
        )
    }
}
