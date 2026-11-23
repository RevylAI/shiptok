import SwiftUI

struct AvatarView: View {
    let avatarURL: URL?
    let diameter: CGFloat

    var body: some View {
        AsyncImage(url: avatarURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Circle().fill(RevylBrandColor.surfaceFloating)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(Circle().stroke(RevylBrandColor.surface, lineWidth: 2))
    }
}
