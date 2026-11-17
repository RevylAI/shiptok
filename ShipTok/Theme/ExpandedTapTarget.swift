import SwiftUI

extension View {
    // Grows only the tappable area, so a small control reaches the minimum height without moving its neighbors.
    func expandingTapTargetVertically(toMinimumHeight minimumTapTargetHeightPoints: CGFloat) -> some View {
        background {
            Color.clear
                .frame(minHeight: minimumTapTargetHeightPoints)
                .contentShape(Rectangle())
        }
    }
}
