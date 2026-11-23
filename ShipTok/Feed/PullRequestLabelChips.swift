import SwiftUI

struct PullRequestLabelChips: View {
    let labels: [ShipTokLabel]

    var body: some View {
        WrappingHorizontalLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(labels, id: \.name) { label in
                let labelColor = Color(rgbHex: label.rgbHex)
                Text(verbatim: label.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RevylBrandColor.textPrimary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(labelColor.opacity(0.25)))
                    .overlay(Capsule().stroke(labelColor, lineWidth: 1))
            }
        }
    }
}
