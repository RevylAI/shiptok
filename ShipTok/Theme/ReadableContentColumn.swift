import SwiftUI

enum ReadableContentColumn {
    static let maximumWidthPoints: CGFloat = 600
}

extension View {
    func centeredInReadableContentColumn() -> some View {
        frame(maxWidth: ReadableContentColumn.maximumWidthPoints)
            .frame(maxWidth: .infinity)
    }

    func scrollContentCenteredInReadableContentColumn() -> some View {
        modifier(ReadableContentColumnScrollContentInset())
    }
}

private struct ReadableContentColumnScrollContentInset: ViewModifier {
    @State private var containerWidthPoints: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.horizontal, max(0, (containerWidthPoints - ReadableContentColumn.maximumWidthPoints) / 2))
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.width
            } action: { measuredWidthPoints in
                containerWidthPoints = measuredWidthPoints
            }
    }
}
