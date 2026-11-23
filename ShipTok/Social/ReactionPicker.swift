import SwiftUI

struct ReactionPicker: View {
    static let defaultCellSidePoints: CGFloat = 44
    static let fittedSize: CGSize = fittedSize(cellSidePoints: defaultCellSidePoints)

    let viewerReactions: Set<ShipTokReaction>
    var cellSidePoints = Self.defaultCellSidePoints
    let onToggleReaction: (ShipTokReaction) -> Void

    private static let reactionsPerRow = 4
    private static let reactionRows: [[ShipTokReaction]] = stride(from: 0, to: ShipTokReaction.allCases.count, by: reactionsPerRow).map { rowStartIndex in
        Array(ShipTokReaction.allCases[rowStartIndex..<min(rowStartIndex + reactionsPerRow, ShipTokReaction.allCases.count)])
    }
    private static let cellSpacingPoints: CGFloat = 2
    private static let edgePaddingPoints: CGFloat = 6

    static func fittedSize(cellSidePoints: CGFloat) -> CGSize {
        CGSize(
            width: CGFloat(reactionsPerRow) * cellSidePoints + CGFloat(reactionsPerRow - 1) * cellSpacingPoints + edgePaddingPoints * 2,
            height: CGFloat(reactionRows.count) * cellSidePoints + CGFloat(reactionRows.count - 1) * cellSpacingPoints + edgePaddingPoints * 2
        )
    }

    var body: some View {
        Grid(horizontalSpacing: Self.cellSpacingPoints, verticalSpacing: Self.cellSpacingPoints) {
            ForEach(Self.reactionRows, id: \.self) { reactionRow in
                GridRow {
                    ForEach(reactionRow, id: \.self) { reaction in
                        Button {
                            onToggleReaction(reaction)
                        } label: {
                            Text(reaction.emoji)
                                .font(.system(size: 26))
                                .frame(width: cellSidePoints, height: cellSidePoints)
                                .background(
                                    Circle().fill(viewerReactions.contains(reaction) ? RevylBrandColor.brand.opacity(0.35) : .clear)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.swipeYielding)
                        .accessibilityLabel(reaction.accessibilityName)
                        .accessibilityAddTraits(viewerReactions.contains(reaction) ? .isSelected : [])
                    }
                }
            }
        }
        .padding(Self.edgePaddingPoints)
        .frame(width: Self.fittedSize(cellSidePoints: cellSidePoints).width, height: Self.fittedSize(cellSidePoints: cellSidePoints).height)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(RevylBrandColor.surfaceFloating))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(RevylBrandColor.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
    }
}
