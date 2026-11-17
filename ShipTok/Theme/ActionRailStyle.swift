import SwiftUI

// Rail glyphs and counts are plain like Instagram's, and on a phone they sit over media of any brightness, so a soft shadow keeps them legible.
private enum ActionRailShadow {
    static let color = Color.black.opacity(0.45)
    static let radius: CGFloat = 3
    static let offsetY: CGFloat = 1
}

extension View {
    func actionRailGlyphStyle() -> some View {
        shadow(color: ActionRailShadow.color, radius: ActionRailShadow.radius, y: ActionRailShadow.offsetY)
    }

    func actionRailCountStyle() -> some View {
        font(.footnote.weight(.semibold))
            .foregroundStyle(RevylBrandColor.textPrimary)
            .lineLimit(1)
            .shadow(color: ActionRailShadow.color, radius: ActionRailShadow.radius, y: ActionRailShadow.offsetY)
    }
}
