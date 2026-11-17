import SwiftUI

// Rail glyphs and counts are plain like Instagram's, and on a phone they sit over media of any brightness, so a tight dark edge, drawn twice to close around thin strokes, outlines them and a soft halo darkens the media around it, keeping them legible even over white.
private extension View {
    func actionRailShadow() -> some View {
        shadow(color: .black.opacity(0.9), radius: 0.75)
            .shadow(color: .black.opacity(0.9), radius: 0.75)
            .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
    }
}

extension View {
    func actionRailGlyphStyle() -> some View {
        actionRailShadow()
    }

    func actionRailCountStyle() -> some View {
        font(.footnote.weight(.semibold))
            .foregroundStyle(RevylBrandColor.textPrimary)
            .lineLimit(1)
            .actionRailShadow()
    }
}
