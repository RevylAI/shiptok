import AVFoundation
import SwiftUI

// How far a pinch has zoomed a video or image and where one finger has panned it, in the coordinates of the viewport that shows the media at its
// normal fit: the media scales around the viewport's center, then moves by the offset. As in Photos, a pinch zooms around the point where the fingers
// first met, past either end of the zoom range it gives way less and less, and once the fingers lift the media covers as much of the viewport as it can
// (AGENTS.md, "Swipe Gestures").
struct MediaZoom: Equatable {
    struct Pinch: Equatable {
        let startZoom: MediaZoom
        let anchor: CGPoint
    }

    private(set) var scale: CGFloat = 1
    private(set) var offset: CGSize = .zero

    static let normalFit = MediaZoom()
    static let maximumScale: CGFloat = 4
    static var settleAnimation: Animation { .smooth(duration: 0.35) }
    // A pinch that ends barely past the normal fit reads as a slip, and a zoom that small would hold the feed's swipes for nothing.
    private static let smallestKeptScale: CGFloat = 1.15
    private static let rubberBandStiffness: CGFloat = 0.55

    var isZoomed: Bool {
        scale > 1
    }

    func pinched(by magnification: CGFloat, around anchor: CGPoint, in viewportSize: CGSize) -> MediaZoom {
        scaled(to: Self.resistedScale(scale * magnification), around: anchor, in: viewportSize)
    }

    func pinchEnded(by magnification: CGFloat, around anchor: CGPoint, mediaFrame: CGRect, in viewportSize: CGSize) -> MediaZoom {
        let endedScale = Self.resistedScale(scale * magnification)
        guard endedScale >= Self.smallestKeptScale else { return .normalFit }
        return scaled(to: min(endedScale, Self.maximumScale), around: anchor, in: viewportSize)
            .keptInBounds(mediaFrame: mediaFrame, viewportSize: viewportSize)
    }

    func panned(by translation: CGSize, mediaFrame: CGRect, in viewportSize: CGSize) -> MediaZoom {
        let offsetBounds = offsetBounds(mediaFrame: mediaFrame, viewportSize: viewportSize)
        return MediaZoom(scale: scale, offset: CGSize(
            width: Self.rubberBanded(offset.width + translation.width, within: offsetBounds.horizontal, dimension: viewportSize.width),
            height: Self.rubberBanded(offset.height + translation.height, within: offsetBounds.vertical, dimension: viewportSize.height)
        ))
    }

    // A flicked finger carries the media on to where the drag predicts it would stop, never past the media's edge.
    func panEnded(by predictedTranslation: CGSize, mediaFrame: CGRect, in viewportSize: CGSize) -> MediaZoom {
        MediaZoom(scale: scale, offset: CGSize(width: offset.width + predictedTranslation.width, height: offset.height + predictedTranslation.height))
            .keptInBounds(mediaFrame: mediaFrame, viewportSize: viewportSize)
    }

    // A fold or rotation resizes the viewport, so the zoom and the spot in view carry over instead of snapping back to the normal fit.
    func refitted(from previousMediaFrame: CGRect, in previousViewportSize: CGSize, to mediaFrame: CGRect, in viewportSize: CGSize) -> MediaZoom {
        guard isZoomed, previousMediaFrame.width > 0, previousMediaFrame.height > 0 else { return self }
        let visibleCenterInMedia = CGPoint(
            x: (previousViewportSize.width / 2 - offset.width / scale - previousMediaFrame.minX) / previousMediaFrame.width,
            y: (previousViewportSize.height / 2 - offset.height / scale - previousMediaFrame.minY) / previousMediaFrame.height
        )
        let visibleCenter = CGPoint(
            x: mediaFrame.minX + visibleCenterInMedia.x * mediaFrame.width,
            y: mediaFrame.minY + visibleCenterInMedia.y * mediaFrame.height
        )
        return MediaZoom(scale: scale, offset: CGSize(
            width: -scale * (visibleCenter.x - viewportSize.width / 2),
            height: -scale * (visibleCenter.y - viewportSize.height / 2)
        ))
        .keptInBounds(mediaFrame: mediaFrame, viewportSize: viewportSize)
    }

    // The point of the media under the anchor stays under it.
    private func scaled(to newScale: CGFloat, around anchor: CGPoint, in viewportSize: CGSize) -> MediaZoom {
        let scaleRatio = newScale / scale
        return MediaZoom(scale: newScale, offset: CGSize(
            width: (anchor.x - viewportSize.width / 2) * (1 - scaleRatio) + offset.width * scaleRatio,
            height: (anchor.y - viewportSize.height / 2) * (1 - scaleRatio) + offset.height * scaleRatio
        ))
    }

    private func keptInBounds(mediaFrame: CGRect, viewportSize: CGSize) -> MediaZoom {
        let offsetBounds = offsetBounds(mediaFrame: mediaFrame, viewportSize: viewportSize)
        return MediaZoom(scale: scale, offset: CGSize(
            width: min(max(offset.width, offsetBounds.horizontal.lowerBound), offsetBounds.horizontal.upperBound),
            height: min(max(offset.height, offsetBounds.vertical.lowerBound), offsetBounds.vertical.upperBound)
        ))
    }

    // Along an axis where the zoomed media is longer than the viewport it must cover the viewport, and where it's shorter it must stay inside it.
    private func offsetBounds(mediaFrame: CGRect, viewportSize: CGSize) -> (horizontal: ClosedRange<CGFloat>, vertical: ClosedRange<CGFloat>) {
        func bounds(mediaMinimum: CGFloat, mediaMaximum: CGFloat, viewportLength: CGFloat) -> ClosedRange<CGFloat> {
            let viewportCenter = viewportLength / 2
            let offsetAligningMinimumEdges = -viewportCenter - scale * (mediaMinimum - viewportCenter)
            let offsetAligningMaximumEdges = viewportLength - viewportCenter - scale * (mediaMaximum - viewportCenter)
            return min(offsetAligningMinimumEdges, offsetAligningMaximumEdges)...max(offsetAligningMinimumEdges, offsetAligningMaximumEdges)
        }
        return (
            bounds(mediaMinimum: mediaFrame.minX, mediaMaximum: mediaFrame.maxX, viewportLength: viewportSize.width),
            bounds(mediaMinimum: mediaFrame.minY, mediaMaximum: mediaFrame.maxY, viewportLength: viewportSize.height)
        )
    }

    private static func resistedScale(_ pinchedScale: CGFloat) -> CGFloat {
        if pinchedScale < 1 {
            return 1 - rubberBandDistance(overshoot: 1 - pinchedScale, dimension: 1)
        }
        if pinchedScale > maximumScale {
            return maximumScale + rubberBandDistance(overshoot: pinchedScale - maximumScale, dimension: maximumScale)
        }
        return pinchedScale
    }

    private static func rubberBanded(_ value: CGFloat, within bounds: ClosedRange<CGFloat>, dimension: CGFloat) -> CGFloat {
        if value < bounds.lowerBound {
            return bounds.lowerBound - rubberBandDistance(overshoot: bounds.lowerBound - value, dimension: dimension)
        }
        if value > bounds.upperBound {
            return bounds.upperBound + rubberBandDistance(overshoot: value - bounds.upperBound, dimension: dimension)
        }
        return value
    }

    // UIScrollView's bounce: the further past the edge, the less each point of finger travel moves the media, never more than the dimension.
    private static func rubberBandDistance(overshoot: CGFloat, dimension: CGFloat) -> CGFloat {
        guard dimension > 0 else { return 0 }
        return (1 - 1 / (overshoot * rubberBandStiffness / dimension + 1)) * dimension
    }
}

struct MediaZoomPan: Equatable {
    let startZoom: MediaZoom
    let startTranslation: CGSize

    func translation(from dragTranslation: CGSize) -> CGSize {
        CGSize(width: dragTranslation.width - startTranslation.width, height: dragTranslation.height - startTranslation.height)
    }
}

extension View {
    // Pinch-to-zoom for media this view shows whole at its normal fit, on a surface with no swipes of its own but the pager's: a zoomed pan holds the
    // pager, a double-tap returns to the normal fit, and the zoom resets whenever isActive changes. The feed's hero zooms through the feed's own drag instead.
    func zoomableMedia(mediaSize: CGSize?, isActive: Bool, onZoomIn: @escaping () -> Void) -> some View {
        modifier(ZoomableMediaModifier(mediaSize: mediaSize, isActive: isActive, onZoomIn: onZoomIn))
    }
}

private struct ZoomableMediaModifier: ViewModifier {
    let mediaSize: CGSize?
    let isActive: Bool
    let onZoomIn: () -> Void
    @State private var zoom = MediaZoom.normalFit
    @State private var pinch: MediaZoom.Pinch?
    @State private var pan: MediaZoomPan?
    @State private var viewportSize: CGSize = .zero
    private static let panMinimumDistance: CGFloat = 10

    private func mediaFrame(in viewportSize: CGSize) -> CGRect? {
        guard let mediaSize, mediaSize.width > 0, mediaSize.height > 0, viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        return AVMakeRect(aspectRatio: mediaSize, insideRect: CGRect(origin: .zero, size: viewportSize))
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { viewportGeometry in
                viewportGeometry.size
            } action: { measuredViewportSize in
                if let previousMediaFrame = mediaFrame(in: viewportSize), let measuredMediaFrame = mediaFrame(in: measuredViewportSize) {
                    zoom = zoom.refitted(from: previousMediaFrame, in: viewportSize, to: measuredMediaFrame, in: measuredViewportSize)
                }
                viewportSize = measuredViewportSize
            }
            .scaleEffect(zoom.scale)
            .offset(zoom.offset)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(pinchGesture)
            .gesture(panGesture, including: zoom.isZoomed ? .all : .subviews)
            .gesture(
                TapGesture(count: 2).onEnded {
                    withAnimation(MediaZoom.settleAnimation) { zoom = .normalFit }
                },
                including: zoom.isZoomed ? .all : .subviews
            )
            .onChange(of: isActive) {
                zoom = .normalFit
                pinch = nil
                pan = nil
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { magnifyValue in
                guard mediaFrame(in: viewportSize) != nil else { return }
                let activePinch = pinch ?? MediaZoom.Pinch(startZoom: zoom, anchor: magnifyValue.startLocation)
                pinch = activePinch
                pan = nil
                zoom = activePinch.startZoom.pinched(by: magnifyValue.magnification, around: activePinch.anchor, in: viewportSize)
            }
            .onEnded { magnifyValue in
                guard let endedPinch = pinch, let mediaFrame = mediaFrame(in: viewportSize) else { return }
                pinch = nil
                let settledZoom = endedPinch.startZoom.pinchEnded(by: magnifyValue.magnification, around: endedPinch.anchor, mediaFrame: mediaFrame, in: viewportSize)
                withAnimation(MediaZoom.settleAnimation) { zoom = settledZoom }
                if !endedPinch.startZoom.isZoomed, settledZoom.isZoomed { onZoomIn() }
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: Self.panMinimumDistance)
            .onChanged { dragValue in
                guard pinch == nil, let mediaFrame = mediaFrame(in: viewportSize) else { return }
                let activePan = pan ?? MediaZoomPan(startZoom: zoom, startTranslation: dragValue.translation)
                pan = activePan
                zoom = activePan.startZoom.panned(by: activePan.translation(from: dragValue.translation), mediaFrame: mediaFrame, in: viewportSize)
            }
            .onEnded { dragValue in
                guard let endedPan = pan, let mediaFrame = mediaFrame(in: viewportSize) else { return }
                pan = nil
                withAnimation(MediaZoom.settleAnimation) {
                    zoom = endedPan.startZoom.panEnded(by: endedPan.translation(from: dragValue.predictedEndTranslation), mediaFrame: mediaFrame, in: viewportSize)
                }
            }
    }
}
