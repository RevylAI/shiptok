import SwiftUI

struct FeedEndPageView: View {
    let repositoryFullName: String
    let feedLoadFailureMessage: String?
    let isFeedWindowLoaded: Bool
    let onRetry: () -> Void

    var body: some View {
        Group {
            if let feedLoadFailureMessage {
                RevylContentUnavailableView(
                    systemImageName: "exclamationmark.triangle",
                    title: "Couldn't load the rest of the last two weeks",
                    message: feedLoadFailureMessage,
                    actionTitle: "Try again",
                    action: onRetry
                )
            } else if !isFeedWindowLoaded {
                FeedLoadingView(message: "Loading the rest of the last two weeks…")
            } else {
                RevylContentUnavailableView(
                    systemImageName: "checkmark.seal.fill",
                    title: "That's the last two weeks",
                    message: "You've seen every pull request merged into \(repositoryFullName) in the last two weeks with a video, screenshot or GIF, plus every ShipTok video."
                )
            }
        }
        .background(RevylBrandColor.canvas)
    }
}
