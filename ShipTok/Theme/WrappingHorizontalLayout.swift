import SwiftUI

struct WrappingHorizontalLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrangeRows(maximumWidth: proposal.width ?? .infinity, subviews: subviews)
        let widestRowWidth = rows.map(\.width).max() ?? 0
        let totalHeight = rows.map(\.height).reduce(0, +) + verticalSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? widestRowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var rowOriginY = bounds.minY
        for row in arrangeRows(maximumWidth: bounds.width, subviews: subviews) {
            var subviewOriginX = bounds.minX
            for subviewIndex in row.subviewIndices {
                let subviewSize = subviews[subviewIndex].sizeThatFits(.unspecified)
                subviews[subviewIndex].place(at: CGPoint(x: subviewOriginX, y: rowOriginY), proposal: ProposedViewSize(subviewSize))
                subviewOriginX += subviewSize.width + horizontalSpacing
            }
            rowOriginY += row.height + verticalSpacing
        }
    }

    private struct Row {
        var subviewIndices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrangeRows(maximumWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var currentRow = Row()
        for subviewIndex in subviews.indices {
            let subviewSize = subviews[subviewIndex].sizeThatFits(.unspecified)
            let widthWithSubview = currentRow.subviewIndices.isEmpty
                ? subviewSize.width
                : currentRow.width + horizontalSpacing + subviewSize.width
            if widthWithSubview > maximumWidth, !currentRow.subviewIndices.isEmpty {
                rows.append(currentRow)
                currentRow = Row(subviewIndices: [subviewIndex], width: subviewSize.width, height: subviewSize.height)
            } else {
                currentRow.subviewIndices.append(subviewIndex)
                currentRow.width = widthWithSubview
                currentRow.height = max(currentRow.height, subviewSize.height)
            }
        }
        if !currentRow.subviewIndices.isEmpty {
            rows.append(currentRow)
        }
        return rows
    }
}
