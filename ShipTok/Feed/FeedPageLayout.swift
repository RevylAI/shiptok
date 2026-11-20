import SwiftUI

// Where a feed page puts its card, rail, top row and navigation (AGENTS.md, "Card Layout"): an inset card above a floating tab bar wherever one fits
// between two rail columns, and otherwise a card that fills the window, so the video keeps the screen's height, with inbox and settings in the status
// strip or the top row's corner. It reads only the window's size, its safe area and the regions the system reserves, never the device or its orientation.
struct FeedPageLayout: Equatable {
    enum NavigationPlacement: Equatable {
        case floatingTabBar
        case statusStripButtons(column: CGRect)
        case topCornerButtons
    }

    static let railWidth: CGFloat = 54
    static let topRowHeight: CGFloat = 34
    static let captionBottomInset: CGFloat = 32
    static let statusStripButtonDiameter: CGFloat = 48
    static let statusStripButtonSpacing: CGFloat = 13

    let card: CGRect
    let rail: CGRect
    let isRailBesideCard: Bool
    let topRow: CGRect
    let navigationPlacement: NavigationPlacement
    // How much of the card's bottom the home indicator covers; the caption, rail and progress line stay above it.
    let homeIndicatorInsetInCard: CGFloat
    // What the tab bar and its gap, or else the home indicator, take from the bottom of the page.
    let bottomChromeHeight: CGFloat
    let heroProgressLineInsets: EdgeInsets
    // Where a hero that doesn't fill the card shows whole: below the top row and above the home indicator, so no edge of it runs through either.
    let wholeHeroMediaInsets: EdgeInsets

    private static let cardMargin: CGFloat = 8
    private static let cardMaximumTopInset: CGFloat = 30
    private static let cardToTabBarSpacing: CGFloat = 30
    private static let railColumnMinimumWidth: CGFloat = 84
    private static let minimumStatusStripWidth: CGFloat = 56
    private static let reelsVideoWidthToHeightRatio: CGFloat = 9.0 / 16.0
    private static let railTopInsetInCard: CGFloat = 16
    private static let railBottomInsetInColumn: CGFloat = 8
    private static let railBottomInsetOverCard: CGFloat = 28
    private static let railTrailingInsetOverCard: CGFloat = 4
    private static let railGapBelowNavigation: CGFloat = 12
    private static let topRowGapBelowSafeArea: CGFloat = 8
    private static let topRowMinimumTop: CGFloat = 32
    private static let topRowHorizontalInset: CGFloat = 16
    private static let heroProgressLineBottomInset: CGFloat = 15
    private static let heroProgressLineHorizontalInsetInInsetCard: CGFloat = 8
    private static let videoScrubZoneDepthBelowInsetCard: CGFloat = 12

    var isTabBarShown: Bool {
        navigationPlacement == .floatingTabBar
    }

    var contentBottom: CGFloat {
        card.maxY - homeIndicatorInsetInCard
    }

    // The strip around the hero's progress line where a sideways drag scrubs the video instead of casting a vibe; it reaches neither the tab bar nor
    // the home indicator (AGENTS.md, "Swipe Gestures").
    var videoScrubZone: CGRect {
        let depthBelowContent = homeIndicatorInsetInCard > 0 ? 0 : Self.videoScrubZoneDepthBelowInsetCard
        return CGRect(
            x: card.minX,
            y: contentBottom - Self.captionBottomInset,
            width: card.width,
            height: Self.captionBottomInset + depthBelowContent
        )
    }

    static func arranged(
        pageSize: CGSize,
        safeAreaInsets: EdgeInsets,
        floatingTabBarHeightWithBottomGap: CGFloat,
        systemOcclusionFrames: [CGRect]
    ) -> FeedPageLayout {
        let insetCardTop = max(cardMargin, min(safeAreaInsets.top, cardMaximumTopInset))
        let insetCardHeight = max(pageSize.height - floatingTabBarHeightWithBottomGap - cardToTabBarSpacing - insetCardTop, 0)
        let railColumnWidth = max(safeAreaInsets.trailing, railColumnMinimumWidth)
        let centeredCardLeading = max(safeAreaInsets.leading, railColumnWidth)
        let centeredCardWidth = pageSize.width - centeredCardLeading - railColumnWidth
        let topRowTop = max(safeAreaInsets.top + topRowGapBelowSafeArea, topRowMinimumTop)

        let card: CGRect
        let railColumnLeading: CGFloat?
        let navigationPlacement: NavigationPlacement
        let homeIndicatorInsetInCard: CGFloat
        let bottomChromeHeight: CGFloat
        let railTopMinimum: CGFloat
        if centeredCardWidth >= insetCardHeight * reelsVideoWidthToHeightRatio {
            card = CGRect(x: centeredCardLeading, y: insetCardTop, width: centeredCardWidth, height: insetCardHeight)
            railColumnLeading = pageSize.width - railColumnWidth
            navigationPlacement = .floatingTabBar
            homeIndicatorInsetInCard = 0
            bottomChromeHeight = floatingTabBarHeightWithBottomGap
            railTopMinimum = card.minY + railTopInsetInCard
        } else {
            let statusStripWidth = safeAreaInsets.trailing >= minimumStatusStripWidth ? safeAreaInsets.trailing : nil
            card = CGRect(x: 0, y: 0, width: max(pageSize.width - (statusStripWidth ?? 0), 0), height: pageSize.height)
            homeIndicatorInsetInCard = safeAreaInsets.bottom
            bottomChromeHeight = safeAreaInsets.bottom
            if let statusStripWidth {
                let statusStripLeading = pageSize.width - statusStripWidth
                railColumnLeading = statusStripLeading
                let buttonsTop = top(
                    below: card.minY + railTopInsetInCard,
                    clearOf: systemOcclusionFrames,
                    acrossX: statusStripLeading...pageSize.width
                )
                let buttonsColumn = CGRect(
                    x: statusStripLeading,
                    y: buttonsTop,
                    width: statusStripWidth,
                    height: 2 * statusStripButtonDiameter + statusStripButtonSpacing
                )
                navigationPlacement = .statusStripButtons(column: buttonsColumn)
                railTopMinimum = buttonsColumn.maxY + railGapBelowNavigation
            } else {
                railColumnLeading = nil
                navigationPlacement = .topCornerButtons
                railTopMinimum = topRowTop + topRowHeight + railGapBelowNavigation
            }
        }

        let railX: CGFloat
        let railBottom: CGFloat
        if let railColumnLeading {
            railX = railColumnLeading + (pageSize.width - railColumnLeading - railWidth) / 2
            railBottom = card.maxY - homeIndicatorInsetInCard - railBottomInsetInColumn
        } else {
            railX = card.maxX - railTrailingInsetOverCard - railWidth
            railBottom = card.maxY - homeIndicatorInsetInCard - railBottomInsetOverCard
        }
        // The Duo's status strip (its clock, battery and an expanded island) lies inside the safe area, so only the regions the system reserves say
        // where the rail can start.
        let railTop = top(below: railTopMinimum, clearOf: systemOcclusionFrames, acrossX: railX...(railX + railWidth))
        let progressLineHorizontalInset = navigationPlacement == .floatingTabBar ? heroProgressLineHorizontalInsetInInsetCard : 0
        let topRowBottom = topRowTop + topRowHeight
        return FeedPageLayout(
            card: card,
            rail: CGRect(x: railX, y: railTop, width: railWidth, height: max(railBottom - railTop, 0)),
            isRailBesideCard: railColumnLeading != nil,
            topRow: CGRect(
                x: card.minX + topRowHorizontalInset,
                y: topRowTop,
                width: max(card.width - 2 * topRowHorizontalInset, 0),
                height: topRowHeight
            ),
            navigationPlacement: navigationPlacement,
            homeIndicatorInsetInCard: homeIndicatorInsetInCard,
            bottomChromeHeight: bottomChromeHeight,
            heroProgressLineInsets: EdgeInsets(
                top: 0,
                leading: progressLineHorizontalInset,
                bottom: heroProgressLineBottomInset + homeIndicatorInsetInCard,
                trailing: progressLineHorizontalInset
            ),
            wholeHeroMediaInsets: EdgeInsets(top: max(topRowBottom - card.minY, 0), leading: 0, bottom: homeIndicatorInsetInCard, trailing: 0)
        )
    }

    func videoScrubFraction(atX fingerX: CGFloat) -> CGFloat {
        let progressLineWidth = max(card.width - heroProgressLineInsets.leading - heroProgressLineInsets.trailing, 1)
        return min(max((fingerX - card.minX - heroProgressLineInsets.leading) / progressLineWidth, 0), 1)
    }

    // Each reserved region that starts at or above the running top within the given columns pushes it below itself.
    private static func top(below startTop: CGFloat, clearOf systemOcclusionFrames: [CGRect], acrossX horizontalRange: ClosedRange<CGFloat>) -> CGFloat {
        systemOcclusionFrames
            .filter { $0.minX < horizontalRange.upperBound && $0.maxX > horizontalRange.lowerBound }
            .sorted { $0.minY < $1.minY }
            .reduce(startTop) { runningTop, occlusionFrame in
                occlusionFrame.minY <= runningTop ? max(runningTop, occlusionFrame.maxY) : runningTop
            }
    }
}
