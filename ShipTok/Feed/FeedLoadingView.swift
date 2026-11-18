import SwiftUI

struct FeedLoadingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(RevylBrandColor.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
