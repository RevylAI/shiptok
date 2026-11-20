import SwiftUI

// The red count of unseen inbox items, on the inbox glyph wherever it shows.
struct UnseenInboxCountBadge: View {
    let unseenItemCount: Int

    var body: some View {
        if unseenItemCount > 0 {
            Text(unseenItemCount > 99 ? "99+" : "\(unseenItemCount)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .contentTransition(.numericText(value: Double(unseenItemCount)))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(RevylBrandColor.danger))
                .offset(x: 10, y: -8)
                .transition(.scale.combined(with: .opacity))
        }
    }
}
